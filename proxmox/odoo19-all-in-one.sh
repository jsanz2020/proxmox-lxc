#!/usr/bin/env bash
# Odoo 19 Pro Installer for Proxmox LXC (Debian 13)
# - Descarga la última plantilla Debian 13 desde repos oficiales (pveam)
# - Crea un LXC Debian 13
# - Descarga instalador interno desde tu repo GitHub
# - Instala Odoo 19 + PostgreSQL + Nginx + websocket (8069/8072)

set -euo pipefail

###############################
# CONFIG: REPO GITHUB INTERNO #
###############################
GITHUB_USER="jsanz2020"             # <-- tu usuario
GITHUB_REPO="proxmox-lxc"           # <-- tu repo
GITHUB_BRANCH="main"
LXC_SCRIPT_PATH="lxc/install-odoo19-pro.sh"

RAW_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}/${LXC_SCRIPT_PATH}"
################################

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
# DESCARGAR INSTALADOR #
########################

msg "Descargando instalador interno desde GitHub:"
echo "  ${RAW_URL}"

LXC_SCRIPT="/root/install-odoo19-pro.sh"

# IMPORTANTE: aquí añadimos git para el instalador interno
pct exec "$CTID" -- bash -c "apt-get update && apt-get install -y curl wget ca-certificates git"

pct exec "$CTID" -- bash -c "wget -qO ${LXC_SCRIPT} '${RAW_URL}' || curl -fsSL '${RAW_URL}' -o ${LXC_SCRIPT}"

pct exec "$CTID" -- bash -c "chmod +x ${LXC_SCRIPT}"

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
echo "Acceso (cuando resuelva el DNS o por IP):"
echo "  http://IP_DEL_LXC/"
[[ -n "${ODOO_DOMAIN}" ]] && echo "  http://${ODOO_DOMAIN}/"
echo
msg "Listo. Entorno Odoo 19 'pro' con Conversaciones (websocket/event) preparado."
