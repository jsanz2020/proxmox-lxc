#!/usr/bin/env bash
# Instalador interno Odoo 19 (Debian 13 LXC)
# - Crea usuario de sistema odoo19
# - Crea rol de PostgreSQL para Odoo (CON CREATEDB, sin crear ninguna base)
# - Crea servicio systemd odoo19.service
# - Configura Nginx como reverse proxy:
#     * HTTP normal -> 8069
#     * Longpolling / bus -> 8072
# - La base de datos se crea SIEMPRE desde el asistente web de Odoo 19

set -euo pipefail

msg() { echo -e "\n[ODOO-SETUP] $*\n"; }

inner_require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "[ERROR] Comando requerido no encontrado: $c" >&2; exit 1; }
  done
}

inner_require_cmd apt-get curl wget openssl git

ODOO_DOMAIN="${ODOO_DOMAIN:-}"
# Solo referencia humana/sugerencia en el fichero de credenciales
ODOO_DB_NAME="${ODOO_DB_NAME:-odoo19}"
ODOO_DB_PASS="${ODOO_DB_PASS:-}"
ODOO_ADMIN_PASS="${ODOO_ADMIN_PASS:-}"

ODOO_DB_USER="odoo19"
ODOO_USER="odoo19"
ODOO_HOME="/opt/odoo19"
ODOO_REPO="https://github.com/odoo/odoo.git"
ODOO_BRANCH="19.0"
ODOO_CONF="/etc/odoo19.conf"
ODOO_SERVICE="/etc/systemd/system/odoo19.service"
LOG_DIR="/var/log/odoo"

LONGPOLLING_PORT=8072
HTTP_PORT=8069

if [[ -z "$ODOO_DB_PASS" || -z "$ODOO_ADMIN_PASS" ]]; then
  echo "[ERROR] Variables ODOO_DB_PASS y ODOO_ADMIN_PASS no pueden estar vacías."
  exit 1
fi

msg "Actualizando sistema dentro del LXC..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y full-upgrade

msg "Instalando paquetes base y dependencias Odoo 19..."
apt-get install -y sudo gnupg2 ca-certificates lsb-release locales \
  curl wget git \
  python3 python3-venv python3-pip build-essential \
  libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
  libjpeg-dev libpq-dev libffi-dev libssl-dev zlib1g-dev \
  postgresql postgresql-contrib \
  nginx

msg "Configurando locale..."
sed -i 's/^# *es_ES.UTF-8/es_ES.UTF-8/' /etc/locale.gen
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=es_ES.UTF-8

msg "Configurando PostgreSQL y usuario de DB..."
systemctl enable postgresql
systemctl start postgresql

# Crear solo el rol/usuario para Odoo, con permiso CREATEDB (sin crear BDs)
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${ODOO_DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE ${ODOO_DB_USER} WITH LOGIN PASSWORD '${ODOO_DB_PASS}' NOSUPERUSER CREATEDB NOCREATEROLE;"

msg "Creando usuario de sistema y directorios para Odoo..."
id -u "${ODOO_USER}" >/dev/null 2>&1 || adduser --system --home "${ODOO_HOME}" --group "${ODOO_USER}"
mkdir -p "${ODOO_HOME}"/{custom-addons,src}
chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_HOME}"

msg "Clonando código de Odoo 19 (rama ${ODOO_BRANCH})..."
if [[ ! -d "${ODOO_HOME}/src/odoo" ]]; then
  sudo -u "${ODOO_USER}" git clone --depth 1 -b "${ODOO_BRANCH}" "${ODOO_REPO}" "${ODOO_HOME}/src/odoo"
fi

msg "Creando entorno virtual Python..."
sudo -u "${ODOO_USER}" python3 -m venv "${ODOO_HOME}/venv"
sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/pip" install --upgrade pip wheel
sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/pip" install -r "${ODOO_HOME}/src/odoo/requirements.txt"

msg "Creando directorio de logs..."
mkdir -p "${LOG_DIR}"
chown "${ODOO_USER}:${ODOO_USER}" "${LOG_DIR}"

msg "Creando fichero de configuración de Odoo..."
cat > "${ODOO_CONF}" <<EOF_CONF
[options]
; Puertos
http_port = ${HTTP_PORT}
proxy_mode = True
longpolling_port = ${LONGPOLLING_PORT}

; Base de datos
db_host = False
db_port = False
db_user = ${ODOO_DB_USER}
db_password = ${ODOO_DB_PASS}
; La base se crea SIEMPRE desde el asistente web, no fijamos db_name aquí.
; db_name = ${ODOO_DB_NAME}

; Master password (para crear bases desde la web)
admin_passwd = ${ODOO_ADMIN_PASS}

; Rutas de addons
addons_path = ${ODOO_HOME}/src/odoo/addons,${ODOO_HOME}/custom-addons

; Modo producción
workers = 4
limit_time_cpu = 120
limit_time_real = 120
max_cron_threads = 2

; Logs
logfile = ${LOG_DIR}/odoo19.log
log_level = info
limit_time_real_cron = 120
EOF_CONF

chown "${ODOO_USER}:${ODOO_USER}" "${ODOO_CONF}"
chmod 640 "${ODOO_CONF}"

msg "Creando servicio systemd para Odoo19..."
cat > "${ODOO_SERVICE}" <<EOF_SERVICE
[Unit]
Description=Odoo 19 Open Source ERP and CRM
After=network.target postgresql.service

[Service]
Type=simple
User=${ODOO_USER}
Group=${ODOO_USER}
ExecStart=${ODOO_HOME}/venv/bin/python ${ODOO_HOME}/src/odoo/odoo-bin \\
  --config ${ODOO_CONF}
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_SERVICE

chmod 644 "${ODOO_SERVICE}"
systemctl daemon-reload
systemctl enable odoo19
systemctl start odoo19

msg "Configurando Nginx como reverse proxy (HTTP 8069 + longpolling 8072)..."

rm -f /etc/nginx/sites-enabled/default || true

SERVER_NAME="${ODOO_DOMAIN}"
if [[ -z "${SERVER_NAME}" ]]; then
  SERVER_NAME="_"
fi

cat > /etc/nginx/sites-available/odoo19.conf <<EOF_NGINX
upstream odoo19_backend {
    server 127.0.0.1:${HTTP_PORT};
}

upstream odoo19_longpolling {
    server 127.0.0.1:${LONGPOLLING_PORT};
}

server {
    listen 80;
    server_name ${SERVER_NAME};

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;
    keepalive_timeout 120s;

    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;

    # Tráfico HTTP normal (interfaz Odoo)
    location / {
        proxy_pass http://odoo19_backend;
        proxy_redirect off;
    }

    # Canal de longpolling / bus para notificaciones y conversaciones
    location /longpolling {
        proxy_pass http://odoo19_longpolling;
        proxy_read_timeout 360s;
        proxy_connect_timeout 360s;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    access_log /var/log/nginx/odoo19-access.log;
    error_log  /var/log/nginx/odoo19-error.log;
}
EOF_NGINX

ln -sf /etc/nginx/sites-available/odoo19.conf /etc/nginx/sites-enabled/odoo19.conf
nginx -t
systemctl restart nginx

msg "Instalación de Odoo19 finalizada."

IP=$(hostname -I | awk '{print $1}')
CRED_FILE="/root/odoo19-credentials.txt"

cat > "${CRED_FILE}" <<EOF_CREDS
Odoo 19 instalado correctamente.

Acceso:
  URL (IP):      http://${IP}/
  URL (dominio): http://${ODOO_DOMAIN}/

Base de datos (crear desde asistente web de Odoo):
  Nombre sugerido: ${ODOO_DB_NAME}
  Usuario DB:      ${ODOO_DB_USER}  (rol con permiso CREATEDB)
  Password DB:     ${ODOO_DB_PASS}

Odoo admin (master password):
  admin_passwd (odoo.conf): ${ODOO_ADMIN_PASS}

Puertos internos:
  HTTP:          ${HTTP_PORT}
  Longpolling:   ${LONGPOLLING_PORT}

Ficheros importantes:
  Config:       ${ODOO_CONF}
  Servicio:     ${ODOO_SERVICE}
  Logs Odoo:    ${LOG_DIR}/odoo19.log
  Logs Nginx:   /var/log/nginx/odoo19-access.log, /var/log/nginx/odoo19-error.log
EOF_CREDS

chmod 600 "${CRED_FILE}"

msg "Credenciales guardadas en ${CRED_FILE}"
