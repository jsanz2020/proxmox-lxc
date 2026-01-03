#!/usr/bin/env bash
# Odoo 19 Pro Installer for Proxmox LXC (Debian 13)
# - Descarga la última plantilla Debian 13 (pveam)
# - Crea un LXC Debian 13
# - Dentro del LXC instala Odoo 19 + PostgreSQL + Nginx + websocket (8069/8072)
# - Crea usuario systemd, servicio odoo19.service, reverse proxy Nginx y credenciales
# - Deja la base odoo19 creada en PostgreSQL, pero Odoo la inicializa desde el asistente (no se fija db_name)

set -euo pipefail

msg()  { echo -e "\n[INFO] $*\n"; }
err()  { echo -e "\n[ERROR] $*\n" >&2; }
ask()  { read -r -p "$1" REPLY; echo "$REPLY"; }

gen_pass() { openssl rand -base64 24 | tr -d '\n'; }

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

msg "Actualizando índice de plantillas (pveam update)..."
pveam update

# Storage donde se descargará la plantilla (por defecto 'local')
TPL_STORAGE_DEFAULT="local"
TPL_STORAGE=$(ask "Storage para la plantilla Debian 13 (default: ${TPL_STORAGE_DEFAULT}): ")
TPL_STORAGE=${TPL_STORAGE:-$TPL_STORAGE_DEFAULT}

msg "Buscando la última plantilla Debian 13 estándar disponible..."
AVAILABLE_TPL=$(pveam available | awk '/debian-13-standard/ && /amd64/ {print $2}' | sort -V | tail -n1)

if [[ -z "${AVAILABLE_TPL:-}" ]]; then
  err "No se encontró plantilla 'debian-13-standard' en pveam available. Revisa que Proxmox ya ofrezca Debian 13."
  exit 1
fi

msg "Plantilla disponible encontrada: ${AVAILABLE_TPL}"

# Comprobar si ya está descargada en el storage
if ! pveam list "$TPL_STORAGE" | awk '{print $2}' | grep -q "^${AVAILABLE_TPL}\$"; then
  msg "Descargando plantilla en storage '${TPL_STORAGE}'..."
  pveam download "$TPL_STORAGE" "$AVAILABLE_TPL"
else
  msg "La plantilla ya está descargada en '${TPL_STORAGE}'."
fi

TEMPLATE="${TPL_STORAGE}:vztmpl/${AVAILABLE_TPL}"

########################
# PREGUNTAS AL USUARIO #
########################

msg "=== Parámetros del LXC Odoo 19 (producción) ==="

CTID=$(ask "CTID del contenedor (ej. 199): ")
HOSTNAME=$(ask "Hostname del contenedor (default: odoo19): ")
HOSTNAME=${HOSTNAME:-odoo19}
BRIDGE=$(ask "Bridge de red (default: vmbr0): ")
BRIDGE=${BRIDGE:-vmbr0}
IPADDR=$(ask "IP/CIDR para el contenedor (ej. 192.168.1.186/24) o vacío para DHCP: ")
GATEWAY=$(ask "Gateway (ej. 192.168.1.1) o vacío si usas DHCP: ")

# Defaults orientados a producción pequeña / media
DISK_GB=$(ask "Tamaño de disco (GB, default: 100): ")
DISK_GB=${DISK_GB:-100}

RAM_MB=$(ask "RAM en MB (default: 8192): ")
RAM_MB=${RAM_MB:-8192}

CPUS=$(ask "Número de vCPUs (default: 4): ")
CPUS=${CPUS:-4}

STORAGE=$(ask "Storage para disco rootfs del LXC (ej. local-lvm, default: local-lvm): ")
STORAGE=${STORAGE:-local-lvm}

msg "=== Parámetros de Odoo 19 ==="

ODOO_DOMAIN=$(ask "Dominio completo para Odoo (ej. odoo.midominio.com, puede dejarse vacío y usar IP): ")
ODOO_DB_NAME=$(ask "Nombre base de datos Odoo (default: odoo19): ")
ODOO_DB_NAME=${ODOO_DB_NAME:-odoo19}

DB_PASS=$(ask "Contraseña para el usuario de PostgreSQL 'odoo19' (ENTER para generar automática): ")
if [[ -z "$DB_PASS" ]]; then
  DB_PASS=$(gen_pass)
  msg "Generada contraseña DB segura."
fi

ADMIN_PASS=$(ask "Contraseña para administrador de Odoo (ENTER para generar automática): ")
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS=$(gen_pass)
  msg "Generada contraseña admin segura."
fi

########################
# CREACIÓN DEL LXC     #
########################

msg "Creando contenedor LXC Debian 13 (CTID: $CTID) usando plantilla:"
echo "  ${TEMPLATE}"

NETCONF=""
if [[ -n "$IPADDR" ]]; then
  NETCONF="name=eth0,bridge=${BRIDGE},ip=${IPADDR}"
  [[ -n "$GATEWAY" ]] && NETCONF="${NETCONF},gw=${GATEWAY}"
else
  NETCONF="name=eth0,bridge=${BRIDGE},ip=dhcp"
fi

pct create "$CTID" "$TEMPLATE" \
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
sleep 10

########################
# SCRIPT INTERNO LXC   #
########################

msg "Creando script de instalación interna dentro del LXC..."

LXC_SCRIPT="/root/install-odoo19-pro.sh"

pct exec "$CTID" -- bash -c "cat > ${LXC_SCRIPT}" << 'EOF_INNER'
#!/usr/bin/env bash
# Instalador interno Odoo 19 (Debian 13 LXC)
# - Crea usuario de sistema odoo19
# - Crea servicio systemd odoo19.service
# - Configura Nginx como reverse proxy (80 -> Odoo 8069 + /websocket)
# - Crea la base odoo19 en PostgreSQL usando template0; Odoo la inicializa vía asistente (sin db_name fijado)

set -euo pipefail

msg() { echo -e "\n[ODOO-SETUP] $*\n"; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "[ERROR] Falta comando: $c" >&2; exit 1; }
  done
}

# El propio script se asegura de tener todo lo necesario
require_cmd apt-get curl wget openssl git

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

sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${ODOO_DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE ${ODOO_DB_USER} WITH LOGIN PASSWORD '${ODOO_DB_PASS}' NOSUPERUSER NOCREATEDB NOCREATEROLE;"

sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${ODOO_DB_NAME}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE DATABASE ${ODOO_DB_NAME} OWNER ${ODOO_DB_USER} ENCODING 'UTF8' TEMPLATE template0;"

msg "Creando usuario de sistema y directorios para Odoo..."
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
; db_name = ${ODOO_DB_NAME}

; admin_password para creación de bases
admin_passwd = ${ODOO_ADMIN_PASS}

; rutas
addons_path = ${ODOO_HOME}/src/odoo/addons,${ODOO_HOME}/custom-addons

; workers y tiempo real (producción pequeña/mediana)
workers = 4
limit_time_cpu = 120
limit_time_real = 120
max_cron_threads = 2

; logging
logfile = ${LOG_DIR}/odoo19.log
log_level = info

; seguridad
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

msg "Configurando Nginx como reverse proxy para Odoo19 (8069 + websocket/event)..."

rm -f /etc/nginx/sites-enabled/default || true

SERVER_NAME="${ODOO_DOMAIN}"
if [[ -z "${SERVER_NAME}" ]]; then
  SERVER_NAME="_"
fi

cat > /etc/nginx/sites-available/odoo19.conf <<EOF_NGINX
upstream odoo19_backend {
    server 127.0.0.1:8069;
}

# Odoo 19 con websocket (Conversaciones) en el mismo puerto interno
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

    # Websocket / Conversaciones (Odoo 19)
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
  URL (IP):      http://${IP}/
  URL (dominio): http://${ODOO_DOMAIN}/

Base de datos:
  Nombre DB:    ${ODOO_DB_NAME} (crear desde asistente web)
  Usuario DB:   ${ODOO_DB_USER}
  Password DB:  ${ODOO_DB_PASS}

Odoo admin (master password):
  admin_passwd (odoo.conf): ${ODOO_ADMIN_PASS}

Ficheros importantes:
  Config:       ${ODOO_CONF}
  Servicio:     ${ODOO_SERVICE}
  Logs Odoo:    ${LOG_DIR}/odoo19.log
  Logs Nginx:   /var/log/nginx/odoo19-access.log, /var/log/nginx/odoo19-error.log
EOF_CREDS

chmod 600 "${CRED_FILE}"

msg "Credenciales guardadas en ${CRED_FILE}"
EOF_INNER

pct exec "$CTID" -- chmod +x "${LXC_SCRIPT}"

########################
# EJECUTAR INSTALADOR  #
########################

msg "Ejecutando instalador interno de Odoo 19 dentro del LXC..."

pct exec "$CTID" -- bash -c "
  export ODOO_DOMAIN='${ODOO_DOMAIN}'
  export ODOO_DB_NAME='${ODOO_DB_NAME}'
  export ODOO_DB_PASS='${DB_PASS}'
  export ODOO_ADMIN_PASS='${ADMIN_PASS}'
  ${LXC_SCRIPT}
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
echo "Acceso:"
echo "  http://IP_DEL_LXC/   --> asistente 'Create Database' (usa la DB ${ODOO_DB_NAME} y master password del fichero de credenciales)"
[[ -n "${ODOO_DOMAIN}" ]] && echo "  http://${ODOO_DOMAIN}/"
echo
msg "Listo. Odoo 19 preparado para crear la base desde el asistente y activar Conversaciones (websocket) de forma profesional."

