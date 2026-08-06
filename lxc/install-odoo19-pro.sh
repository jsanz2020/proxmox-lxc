#!/usr/bin/env bash
# Instalador interno Odoo 19 (Debian 13 LXC)
# - Crea usuario de sistema odoo19
# - Crea rol de PostgreSQL para Odoo (CON CREATEDB, sin crear ninguna base)
# - Crea servicio systemd odoo19.service
# - Configura Nginx como reverse proxy:
#     * HTTP normal -> 8069
#     * WebSocket / bus (Conversaciones) -> 8072
# - La base de datos se crea SIEMPRE desde el asistente web de Odoo 19

set -euo pipefail

msg()  { echo -e "\n[ODOO-SETUP] $*\n"; }
warn() { echo -e "\n[AVISO] $*\n" >&2; }

inner_require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "[ERROR] Comando requerido no encontrado: $c" >&2; exit 1; }
  done
}

# Solo apt-get es imprescindible de partida: el resto de herramientas
# (curl, wget, git, openssl...) se instalan más abajo.
inner_require_cmd apt-get

if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] Este script debe ejecutarse como root dentro del LXC." >&2
  exit 1
fi

ODOO_DOMAIN="${ODOO_DOMAIN:-}"
# Solo referencia humana/sugerencia en el fichero de credenciales
ODOO_DB_NAME="${ODOO_DB_NAME:-odoo19}"
ODOO_DB_PASS="${ODOO_DB_PASS:-}"
ODOO_ADMIN_PASS="${ODOO_ADMIN_PASS:-}"

# Instalar wkhtmltopdf (informes PDF). No existe en Debian 13 main, se intenta
# con el paquete oficial del proyecto. Poner a 0 para omitirlo.
INSTALL_WKHTMLTOPDF="${INSTALL_WKHTMLTOPDF:-1}"

ODOO_DB_USER="odoo19"
ODOO_USER="odoo19"
ODOO_HOME="/opt/odoo19"
ODOO_REPO="https://github.com/odoo/odoo.git"
ODOO_BRANCH="19.0"
ODOO_CONF="/etc/odoo19.conf"
ODOO_SERVICE="/etc/systemd/system/odoo19.service"
LOG_DIR="/var/log/odoo"

GEVENT_PORT=8072
HTTP_PORT=8069

if [[ -z "$ODOO_DB_PASS" || -z "$ODOO_ADMIN_PASS" ]]; then
  echo "[ERROR] Variables ODOO_DB_PASS y ODOO_ADMIN_PASS no pueden estar vacías." >&2
  exit 1
fi

msg "Actualizando sistema dentro del LXC..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y full-upgrade

msg "Instalando paquetes base y dependencias Odoo 19..."
# Nota: python3-dev y pkg-config son necesarios para compilar las ruedas de
# psycopg2 / gevent / greenlet cuando pip no encuentra wheel para la versión
# de Python de Debian 13.
apt-get install -y sudo gnupg2 ca-certificates lsb-release locales \
  curl wget git \
  python3 python3-dev python3-venv python3-pip build-essential pkg-config \
  libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
  libjpeg-dev libfreetype-dev libpq-dev libffi-dev libssl-dev zlib1g-dev \
  fontconfig fonts-liberation \
  postgresql postgresql-contrib \
  nginx

########################
# WKHTMLTOPDF (PDF)    #
########################
# Debian 13 no incluye wkhtmltopdf, y Odoo lo necesita para generar informes
# PDF (facturas, albaranes...). Se intenta instalar el .deb oficial parcheado
# con Qt. Si falla, la instalación continúa: Odoo funciona, pero sin PDF.
if [[ "${INSTALL_WKHTMLTOPDF}" == "1" ]] && ! command -v wkhtmltopdf >/dev/null 2>&1; then
  msg "Instalando wkhtmltopdf (paquete oficial parcheado)..."
  WKHTML_VER="0.12.6.1-3"
  WKHTML_DEB="wkhtmltox_${WKHTML_VER}.bookworm_amd64.deb"
  WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTML_VER}/${WKHTML_DEB}"
  WKHTML_TMP="$(mktemp -d)"
  if wget -qO "${WKHTML_TMP}/${WKHTML_DEB}" "${WKHTML_URL}" \
     && apt-get install -y "${WKHTML_TMP}/${WKHTML_DEB}"; then
    msg "wkhtmltopdf instalado: $(wkhtmltopdf --version 2>/dev/null | head -n1)"
  else
    warn "No se pudo instalar wkhtmltopdf. Odoo funcionará, pero los informes PDF fallarán.
Instálalo manualmente desde https://github.com/wkhtmltopdf/packaging/releases"
  fi
  rm -rf "${WKHTML_TMP}"
fi

msg "Configurando locale..."
sed -i 's/^# *es_ES.UTF-8/es_ES.UTF-8/' /etc/locale.gen
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=es_ES.UTF-8

msg "Configurando PostgreSQL y usuario de DB..."
systemctl enable postgresql
systemctl start postgresql

# Crear solo el rol/usuario para Odoo, con permiso CREATEDB (sin crear BDs).
# Si el rol ya existe (re-ejecución del script), se sincroniza la contraseña
# para que coincida con la del fichero de credenciales.
# La contraseña se pasa como variable de psql y se interpola con :'pass', que
# aplica el entrecomillado correcto aunque contenga comillas simples.
# Importante: psql solo sustituye variables leyendo por stdin o con -f,
# NUNCA con -c, por eso se usa un heredoc.
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${ODOO_DB_USER}'" | grep -q 1; then
  msg "El rol '${ODOO_DB_USER}' ya existe: actualizando contraseña."
  sudo -u postgres psql -v ON_ERROR_STOP=1 -v pass="${ODOO_DB_PASS}" <<EOSQL
ALTER ROLE ${ODOO_DB_USER} WITH LOGIN PASSWORD :'pass' NOSUPERUSER CREATEDB NOCREATEROLE;
EOSQL
else
  sudo -u postgres psql -v ON_ERROR_STOP=1 -v pass="${ODOO_DB_PASS}" <<EOSQL
CREATE ROLE ${ODOO_DB_USER} WITH LOGIN PASSWORD :'pass' NOSUPERUSER CREATEDB NOCREATEROLE;
EOSQL
fi

msg "Creando usuario de sistema y directorios para Odoo..."
id -u "${ODOO_USER}" >/dev/null 2>&1 || adduser --system --home "${ODOO_HOME}" --group "${ODOO_USER}"
mkdir -p "${ODOO_HOME}"/{custom-addons,src}
chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_HOME}"

msg "Clonando código de Odoo 19 (rama ${ODOO_BRANCH})..."
if [[ ! -d "${ODOO_HOME}/src/odoo" ]]; then
  sudo -u "${ODOO_USER}" git clone --depth 1 -b "${ODOO_BRANCH}" "${ODOO_REPO}" "${ODOO_HOME}/src/odoo"
else
  msg "El código ya está clonado, se omite el clone."
fi

msg "Creando entorno virtual Python..."
if [[ ! -x "${ODOO_HOME}/venv/bin/python" ]]; then
  sudo -u "${ODOO_USER}" python3 -m venv "${ODOO_HOME}/venv"
fi
sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/pip" install --upgrade pip wheel setuptools
sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/pip" install -r "${ODOO_HOME}/src/odoo/requirements.txt"

msg "Creando directorio de logs..."
mkdir -p "${LOG_DIR}"
chown "${ODOO_USER}:${ODOO_USER}" "${LOG_DIR}"

# Rotación de logs: sin esto odoo19.log crece sin límite.
cat > /etc/logrotate.d/odoo19 <<EOF_LOGROTATE
${LOG_DIR}/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ${ODOO_USER} ${ODOO_USER}
    copytruncate
}
EOF_LOGROTATE

# Workers recomendados por Odoo: (nº de CPUs * 2) + 1.
# Ojo: dentro de un LXC 'nproc' suele devolver las CPUs del HOST (Proxmox
# limita por cuota de cgroup, no por cpuset), lo que dispararía el número de
# workers. Se prefiere el valor que pasa el script del host y, en su defecto,
# /proc/cpuinfo (que lxcfs sí filtra por contenedor). Además se acota.
if [[ -z "${ODOO_WORKERS:-}" ]]; then
  CPU_COUNT="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 2)"
  [[ "${CPU_COUNT}" =~ ^[0-9]+$ ]] || CPU_COUNT=2
  ODOO_WORKERS=$(( CPU_COUNT * 2 + 1 ))
fi
if [[ ! "${ODOO_WORKERS}" =~ ^[0-9]+$ ]]; then
  ODOO_WORKERS=5
fi
if (( ODOO_WORKERS < 2 )); then
  ODOO_WORKERS=2
elif (( ODOO_WORKERS > 16 )); then
  ODOO_WORKERS=16
fi

msg "Creando fichero de configuración de Odoo (workers=${ODOO_WORKERS})..."
cat > "${ODOO_CONF}" <<EOF_CONF
[options]
; Puertos
http_port = ${HTTP_PORT}
proxy_mode = True
; gevent_port sustituye al antiguo longpolling_port (Odoo >= 16).
; Es el canal de websocket usado por Conversaciones/notificaciones.
gevent_port = ${GEVENT_PORT}

; Base de datos (conexión por socket unix local, autenticación peer)
db_host = False
db_port = False
db_user = ${ODOO_DB_USER}
db_password = ${ODOO_DB_PASS}
db_maxconn = 32
; La base se crea SIEMPRE desde el asistente web, no fijamos db_name aquí.
; db_name = ${ODOO_DB_NAME}

; Master password (para crear bases desde la web)
admin_passwd = ${ODOO_ADMIN_PASS}
; Tras crear la base, se recomienda poner list_db = False y reiniciar
; el servicio para ocultar el gestor de bases de datos.
list_db = True

; Rutas de addons
addons_path = ${ODOO_HOME}/src/odoo/addons,${ODOO_HOME}/custom-addons

; Modo producción
workers = ${ODOO_WORKERS}
max_cron_threads = 2
limit_time_cpu = 120
limit_time_real = 120
limit_time_real_cron = 300
limit_memory_soft = 2147483648
limit_memory_hard = 2684354560

; Logs
logfile = ${LOG_DIR}/odoo19.log
log_level = info
EOF_CONF

# root propietario, odoo solo lectura: el fichero contiene la master password.
chown root:"${ODOO_USER}" "${ODOO_CONF}"
chmod 640 "${ODOO_CONF}"

msg "Creando servicio systemd para Odoo19..."
cat > "${ODOO_SERVICE}" <<EOF_SERVICE
[Unit]
Description=Odoo 19 Open Source ERP and CRM
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=${ODOO_USER}
Group=${ODOO_USER}
ExecStart=${ODOO_HOME}/venv/bin/python ${ODOO_HOME}/src/odoo/odoo-bin \\
  --config ${ODOO_CONF}
Restart=always
RestartSec=5
LimitNOFILE=65535
SyslogIdentifier=odoo19

[Install]
WantedBy=multi-user.target
EOF_SERVICE

chmod 644 "${ODOO_SERVICE}"
systemctl daemon-reload
systemctl enable odoo19
systemctl restart odoo19

msg "Configurando Nginx como reverse proxy (HTTP ${HTTP_PORT} + websocket ${GEVENT_PORT})..."

rm -f /etc/nginx/sites-enabled/default || true

SERVER_NAME="${ODOO_DOMAIN}"
if [[ -z "${SERVER_NAME}" ]]; then
  SERVER_NAME="_"
fi

cat > /etc/nginx/sites-available/odoo19.conf <<EOF_NGINX
upstream odoo19_backend {
    server 127.0.0.1:${HTTP_PORT};
}

upstream odoo19_websocket {
    server 127.0.0.1:${GEVENT_PORT};
}

# Necesario para que el proxy negocie el upgrade a websocket.
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name ${SERVER_NAME};

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;
    keepalive_timeout 120s;

    # Importaciones, adjuntos y copias de seguridad superan el 1M por defecto.
    client_max_body_size 200M;

    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;

    gzip on;
    gzip_types text/css text/plain text/xml application/xml application/json application/javascript;
    gzip_min_length 1100;

    # Canal websocket del bus (Conversaciones, notificaciones en vivo).
    location /websocket {
        proxy_pass http://odoo19_websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout 720s;
        proxy_connect_timeout 720s;
    }

    # Compatibilidad con el antiguo endpoint de longpolling.
    location /longpolling {
        proxy_pass http://odoo19_websocket;
        proxy_redirect off;
        proxy_read_timeout 360s;
        proxy_connect_timeout 360s;
    }

    # Cacheo de recursos estáticos servidos por Odoo.
    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo19_backend;
    }

    # Tráfico HTTP normal (interfaz Odoo)
    location / {
        proxy_pass http://odoo19_backend;
        proxy_redirect off;
    }

    access_log /var/log/nginx/odoo19-access.log;
    error_log  /var/log/nginx/odoo19-error.log;
}
EOF_NGINX

ln -sf /etc/nginx/sites-available/odoo19.conf /etc/nginx/sites-enabled/odoo19.conf
nginx -t
systemctl enable nginx
systemctl restart nginx

msg "Comprobando que el servicio Odoo19 está activo..."
for _ in $(seq 1 30); do
  systemctl is-active --quiet odoo19 && break
  sleep 2
done

if ! systemctl is-active --quiet odoo19; then
  warn "El servicio odoo19 no está activo. Revisa:
  systemctl status odoo19
  journalctl -u odoo19 -n 100 --no-pager
  tail -n 100 ${LOG_DIR}/odoo19.log"
else
  msg "Servicio odoo19 activo."
fi

msg "Instalación de Odoo19 finalizada."

IP=$(hostname -I | awk '{print $1}')
CRED_FILE="/root/odoo19-credentials.txt"

cat > "${CRED_FILE}" <<EOF_CREDS
Odoo 19 instalado correctamente.

Acceso:
  URL (IP):      http://${IP}/
  URL (dominio): http://${ODOO_DOMAIN:-no configurado}/

Base de datos (crear desde asistente web de Odoo):
  Nombre sugerido: ${ODOO_DB_NAME}
  Usuario DB:      ${ODOO_DB_USER}  (rol con permiso CREATEDB)
  Password DB:     ${ODOO_DB_PASS}

Odoo admin (master password):
  admin_passwd (${ODOO_CONF}): ${ODOO_ADMIN_PASS}

Puertos internos:
  HTTP:          ${HTTP_PORT}
  WebSocket:     ${GEVENT_PORT}  (gevent_port)

Ficheros importantes:
  Config:       ${ODOO_CONF}
  Servicio:     ${ODOO_SERVICE}
  Logs Odoo:    ${LOG_DIR}/odoo19.log
  Logs Nginx:   /var/log/nginx/odoo19-access.log, /var/log/nginx/odoo19-error.log

Recomendaciones post-instalación:
  1. Crea la base desde http://${IP}/web/database/manager
  2. Edita ${ODOO_CONF} y pon list_db = False
  3. systemctl restart odoo19
EOF_CREDS

chmod 600 "${CRED_FILE}"

msg "Credenciales guardadas en ${CRED_FILE}"

