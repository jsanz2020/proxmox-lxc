#!/usr/bin/env bash
# Odoo 19 Pro Installer for Proxmox LXC (Debian 13)
# One-shot: crea el LXC, instala Odoo19 + PostgreSQL + Nginx + websocket (8069/8072)
# Pensado para entorno de laboratorio o producción controlada.

set -euo pipefail

########################
# FUNCIONES AUXILIARES #
########################

msg()  { echo -e "\n[INFO] $*\n"; }
err()  { echo -e "\n[ERROR] $*\n" >&2; }
ask()  { read -r -p "$1" REPLY; echo "$REPLY"; }

gen_pass() {
  # 24 bytes base64 (~32 caracteres)
  openssl rand -base64 24 | tr -d '\n'
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { err "Comando requerido no encontrado: $c"; exit 1; }
  done
}

########################
# PRE-CHECKS PROXMOX   #
########################

require_cmd pct pveam curl wget openssl

if ! pveversion >/dev/null 2>&1; then
  err "Este script debe ejecutarse en un nodo Proxmox VE."
  exit 1
fi

msg "Comprobando plantilla Debian para LXC (Debian 13 o similar)..."
if ! pveam list local | grep -qi "debian-13"; then
  msg "No se encontró plantilla Debian 13 en 'local'."
  msg "Ejemplo para descargar (ajusta si tu storage no es 'local'):"
  echo "  pveam update"
  echo "  pveam available | grep debian"
  echo "  pveam download local debian-13-standard_13.*_amd64.tar.zst"
  exit 1
fi

TEMPLATE=$(pveam list local | awk '/debian-13/ && /amd64/ {print $2; exit}')
if [[ -z "${TEMPLATE:-}" ]]; then
  err "No se pudo determinar la plantilla Debian 13 en 'local'."
  exit 1
fi

########################
# PREGUNTAS AL USUARIO #
########################

msg "=== Parámetros del LXC Odoo 19 ==="

CTID=$(ask "CTID del contenedor (ej. 199): ")
HOSTNAME=$(ask "Hostname del contenedor (ej. odoo19): ")
BRIDGE=$(ask "Bridge de red (default: vmbr0): ")
BRIDGE=${BRIDGE:-vmbr0}
IPADDR=$(ask "IP/CIDR para el contenedor (ej. 192.168.1.186/24) o vacío para DHCP: ")
GATEWAY=$(ask "Gateway (ej. 192.168.1.1) o vacío si usas DHCP: ")

DISK_GB=$(ask "Tamaño de disco (GB, ej. 40): ")
RAM_MB=$(ask "RAM en MB (ej. 4096): ")
CPUS=$(ask "Número de vCPUs (ej. 2): ")

STORAGE=$(ask "Storage para disco rootfs (ej. local-lvm): ")

msg "=== Parámetros de Odoo 19 ==="

ODOO_DOMAIN=$(ask "Dominio completo para Odoo (ej. odoo.midominio.com, puede dejarse vacío y usar IP): ")
ODOO_DB_NAME=$(ask "Nombre base de datos Odoo (default: odoo19): ")
ODOO_DB_NAME=${ODOO_DB_NAME:-odoo19}

# Contraseña DB
DB_PASS=$(ask "Contraseña para el usuario de PostgreSQL 'odoo19' (ENTER para generar automática): ")
if [[ -z "$DB_PASS" ]]; then
  DB_PASS=$(gen_pass)
  msg "Generada contraseña DB segura."
fi

# Contraseña admin Odoo
ADMIN_PASS=$(ask "Contraseña para administrador de Odoo (ENTER para generar automática): ")
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS=$(gen_pass)
  msg "Generada contraseña admin segura."
fi

########################
# CREACIÓN DEL LXC     #
########################

msg "Creando contenedor LXC Debian 13 (CTID: $CTID)..."

NETCONF=""
if [[ -n "$IPADDR" ]]; then
  NETCONF="name=eth0,bridge=${BRIDGE},ip=${IPADDR}"
  [[ -n "$GATEWAY" ]] && NETCONF="${NETCONF},gw=${GATEWAY}"
else
  NETCONF="name=eth0,bridge=${BRIDGE},ip=dhcp"
fi

pct create "$CTID" "local:${TEMPLATE}" \
  -hostname "$HOSTNAME" \
  -memory "$RAM_MB" \
  -cores "$CPUS" \
  -rootfs "${STORAGE}:${DISK_GB}" \
  -net0 "$NETCONF" \
  -ostype debian \
  -features nesting=1 \
  -onboot 1

msg "Arrancando contenedor..."
pct start "$CTID"

# Espera breve
sleep 10

########################
# SCRIPT INTERNO LXC   #
########################

msg "Creando script de instalación interna dentro del LXC..."

LXC_SCRIPT="/root/install-odoo19-pro.sh"

pct exec "$CTID" -- bash -c "cat > $LXC_SCRIPT" << 'EOF_INNER'
#!/usr/bin/env bash
set -euo pipefail

msg() { echo -e "\n[ODOO-SETUP] $*\n"; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "[ERROR] Falta comando: $c" >&2; exit 1; }
  done
}

require_cmd apt-get curl wget openssl git python3 python3-venv python3-pip

ODOO_DOMAIN="${ODOO_DOMAIN:-}"
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
WKHTML_PKG="wkhtmltopdf"

if [[ -z "$ODOO_DB_PASS" || -z "$ODOO_ADMIN_PASS" ]]; then
  echo "[ERROR] Variables ODOO_DB_PASS y ODOO_ADMIN_PASS no pueden estar vacías."
  exit 1
fi

msg "Actualizando sistema..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y full-upgrade

msg "Instalando paquetes base..."
apt-get install -y sudo gnupg2 ca-certificates lsb-release locales curl wget git \
  python3 python3-venv python3-pip build-essential \
  libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
  libjpeg-dev libpq-dev libffi-dev libssl-dev \
  postgresql postgresql-contrib \
  nginx ${WKHTML_PKG}

msg "Configurando locale..."
sed -i 's/^# *es_ES.UTF-8/es_ES.UTF-8/' /etc/locale.gen
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=es_ES.UTF-8

msg "Configurando PostgreSQL y usuario de DB..."
systemctl enable postgresql
systemctl start postgresql

sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${ODOO_DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE ${ODOO_DB_USER} WITH LOGIN PASSWORD '${ODOO_DB_PASS}' NOSUPERUSER NOCREATEDB NOCREATEROLE;"

sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${ODOO_DB_NAME}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE DATABASE ${ODOO_DB_NAME} OWNER ${ODOO_DB_USER} ENCODING 'UTF8';"

msg "Creando usuario de sistema y directorios..."
id -u "${ODOO_USER}" >/dev/null 2>&1 || adduser --system --home "${ODOO_HOME}" --group "${ODOO_USER}"
mkdir -p "${ODOO_HOME}"/{custom-addons,src}
chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_HOME}"

msg "Clonando código de Odoo 19 (rama ${ODOO_BRANCH})..."
sudo -u "${ODOO_USER}" git clone --depth 1 -b "${ODOO_BRANCH}" "${ODOO_REPO}" "${ODOO_HOME}/src/odoo"

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
; Puerto HTTP interno de Odoo
http_port = 8069
; Modo proxy (detrás de Nginx)
proxy_mode = True

; DB
db_host = False
db_port = False
db_user = ${ODOO_DB_USER}
db_password = ${ODOO_DB_PASS}
db_name = ${ODOO_DB_NAME}

; admin_password para creación de bases
admin_passwd = ${ODOO_ADMIN_PASS}

; rutas
addons_path = ${ODOO_HOME}/src/odoo/addons,${ODOO_HOME}/custom-addons

; workers y tiempo real
workers = 4
limit_time_cpu = 120
limit_time_real = 120

; logging
logfile = ${LOG_DIR}/odoo19.log
log_level = info

; seguridad
limit_time_real_cron = 120
max_cron_threads = 2
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

systemctl daemon-reload
systemctl enable odoo19
systemctl start odoo19

msg "Configurando Nginx como proxy para Odoo19 (8069 + websocket/event)..."

rm -f /etc/nginx/sites-enabled/default || true

SERVER_NAME="${ODOO_DOMAIN}"
if [[ -z "${SERVER_NAME}" ]]; then
  SERVER_NAME="_"
fi

cat > /etc/nginx/sites-available/odoo19.conf <<EOF_NGINX
upstream odoo19_backend {
    server 127.0.0.1:8069;
}

server {
    listen 80;
    server_name ${SERVER_NAME};

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;
    keepalive_timeout 120s;

    # Cabeceras proxy
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;

    # Websocket / Conversaciones (Odoo 19 usa event/websocket)
    location /websocket {
        proxy_pass http://127.0.0.1:8069/websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Resto de tráfico HTTP
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
systemctl restart nginx

msg "Instalación de Odoo19 finalizada."

IP=$(hostname -I | awk '{print $1}')
CRED_FILE="/root/odoo19-credentials.txt"

cat > "${CRED_FILE}" <<EOF_CREDS
Odoo 19 instalado correctamente.

Acceso:
  URL (IP):     http://${IP}/
  URL (dominio): http://${ODOO_DOMAIN}/

Base de datos:
  Nombre DB:    ${ODOO_DB_NAME}
  Usuario DB:   ${ODOO_DB_USER}
  Password DB:  ${ODOO_DB_PASS}

Odoo admin:
  Usuario:      admin
  Password:     ${ODOO_ADMIN_PASS}

Ficheros importantes:
  Config:       ${ODOO_CONF}
  Servicio:     ${ODOO_SERVICE}
  Logs Odoo:    ${LOG_DIR}/odoo19.log
  Logs Nginx:   /var/log/nginx/odoo19-access.log, /var/log/nginx/odoo19-error.log
EOF_CREDS

chmod 600 "${CRED_FILE}"

msg "Credenciales guardadas en ${CRED_FILE}"
EOF_INNER

pct exec "$CTID" -- chmod +x "$LXC_SCRIPT"

########################
# EJECUTAR INSTALADOR  #
########################

msg "Ejecutando instalador interno de Odoo 19 dentro del LXC..."

pct exec "$CTID" -- bash -c "
  export ODOO_DOMAIN='${ODOO_DOMAIN}'
  export ODOO_DB_NAME='${ODOO_DB_NAME}'
  export ODOO_DB_PASS='${DB_PASS}'
  export ODOO_ADMIN_PASS='${ADMIN_PASS}'
  $LXC_SCRIPT
"

########################
# RESUMEN FINAL        #
########################

msg "=== INSTALACIÓN COMPLETADA ==="
LXC_IP=${IPADDR:-"(DHCP, revisa con 'pct exec ${CTID} -- hostname -I')"}
echo "CTID:           ${CTID}"
echo "Hostname:       ${HOSTNAME}"
echo "IP configurada: ${LXC_IP}"
echo "Dominio Odoo:   ${ODOO_DOMAIN:-(no configurado, usar IP)}"
echo
echo "Dentro del LXC, credenciales en: /root/odoo19-credentials.txt"
echo "Para ver IP real del LXC: pct exec ${CTID} -- hostname -I"
echo
echo "Acceso (cuando resuelva el DNS o por IP):"
echo "  http://IP_DEL_LXC/"
[[ -n "${ODOO_DOMAIN}" ]] && echo "  http://${ODOO_DOMAIN}/"
echo
msg "Listo. Ya deberías poder activar Conversaciones en Odoo 19 (websocket/event) de forma 'pro'."

