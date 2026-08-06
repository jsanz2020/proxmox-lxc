#!/usr/bin/env bash
# Odoo 19 Pro Installer for Proxmox LXC (Debian 13)
# - Descarga la última plantilla Debian 13 desde repos oficiales (pveam)
# - Crea un LXC Debian 13 (no privilegiado)
# - Descarga instalador interno desde tu repo GitHub
# - Lanza el instalador interno (Odoo 19 + PostgreSQL + Nginx + websocket)

set -euo pipefail

###############################
# CONFIG: REPO GITHUB INTERNO #
###############################
GITHUB_USER="${GITHUB_USER:-jsanz2020}"       # <-- tu usuario
GITHUB_REPO="${GITHUB_REPO:-proxmox-lxc}"     # <-- tu repo
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"        # exportable para probar otra rama
LXC_SCRIPT_PATH="lxc/install-odoo19-pro.sh"

RAW_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}/${LXC_SCRIPT_PATH}"
################################

msg()  { echo -e "\n[INFO] $*\n"; }
err()  { echo -e "\n[ERROR] $*\n" >&2; }

# Si stdin es un terminal se lee de stdin (uso normal). Si no lo es -- caso
# típico de `curl ... | bash`, donde stdin es el propio script -- se lee del
# terminal de control para no consumir el código fuente como respuestas.
# Si tampoco hay terminal (automatización), se vuelve a stdin.
ask() {
  local reply=""
  if [[ -t 0 ]]; then
    read -r -p "$1" reply
  elif [[ -r /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; then
    read -r -p "$1" reply < /dev/tty
  else
    read -r -p "$1" reply
  fi
  echo "$reply"
}

gen_pass() { openssl rand -base64 24 | tr -d '\n'; }

host_require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { err "Comando requerido no encontrado: $c"; exit 1; }
  done
}

vmid_in_use() {
  pct status "$1" >/dev/null 2>&1 || qm status "$1" >/dev/null 2>&1
}

cleanup() {
  [[ -n "${ENV_TMP:-}" && -f "${ENV_TMP}" ]] && rm -f "${ENV_TMP}"
  return 0
}
trap cleanup EXIT

########################
# PRE-CHECKS PROXMOX   #
########################

host_require_cmd pct pveam curl wget openssl

if ! pveversion >/dev/null 2>&1; then
  err "Este script debe ejecutarse en un nodo Proxmox VE."
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  err "Este script debe ejecutarse como root."
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
if ! pveam list "$TPL_STORAGE" | awk '{print $1}' | grep -q "vztmpl/${AVAILABLE_TPL}\$"; then
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

# El límite de intentos evita un bucle infinito si se agota la entrada (EOF).
CTID=""
for _ in $(seq 1 10); do
  CTID=$(ask "CTID del contenedor (ej. 199): ")
  if [[ ! "$CTID" =~ ^[0-9]+$ ]] || (( CTID < 100 )); then
    err "El CTID debe ser un número igual o mayor que 100."
    CTID=""
    continue
  fi
  if vmid_in_use "$CTID"; then
    err "El ID ${CTID} ya está en uso por otro contenedor o VM."
    CTID=""
    continue
  fi
  break
done

if [[ -z "$CTID" ]]; then
  err "No se obtuvo un CTID válido. Abortando."
  exit 1
fi

HOSTNAME=$(ask "Hostname del contenedor (default: odoo19): ")
HOSTNAME=${HOSTNAME:-odoo19}
BRIDGE=$(ask "Bridge de red (default: vmbr0): ")
BRIDGE=${BRIDGE:-vmbr0}

while :; do
  IPADDR=$(ask "IP/CIDR para el contenedor (ej. 192.168.1.186/24) o vacío para DHCP: ")
  [[ -z "$IPADDR" ]] && break
  if [[ "$IPADDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
    break
  fi
  err "Formato no válido. Usa IP/CIDR, por ejemplo 192.168.1.186/24."
done

GATEWAY=""
if [[ -n "$IPADDR" ]]; then
  while :; do
    GATEWAY=$(ask "Gateway (ej. 192.168.1.1), vacío para omitir: ")
    [[ -z "$GATEWAY" ]] && break
    if [[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      break
    fi
    err "Formato de gateway no válido."
  done
fi

# Defaults orientados a producción pequeña / media
DISK_GB=$(ask "Tamaño de disco (GB, default: 100): ")
DISK_GB=${DISK_GB:-100}

RAM_MB=$(ask "RAM en MB (default: 8192): ")
RAM_MB=${RAM_MB:-8192}

SWAP_MB=$(ask "Swap en MB (default: 2048): ")
SWAP_MB=${SWAP_MB:-2048}

CPUS=$(ask "Número de vCPUs (default: 4): ")
CPUS=${CPUS:-4}

STORAGE=$(ask "Storage para disco rootfs del LXC (ej. local-lvm, default: local-lvm): ")
STORAGE=${STORAGE:-local-lvm}

for pair in "DISK_GB:$DISK_GB" "RAM_MB:$RAM_MB" "SWAP_MB:$SWAP_MB" "CPUS:$CPUS"; do
  name="${pair%%:*}"; value="${pair#*:}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    err "${name} debe ser un número entero (recibido: '${value}')."
    exit 1
  fi
done

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
  -swap "$SWAP_MB" \
  -cores "$CPUS" \
  -rootfs "${STORAGE}:${DISK_GB}" \
  -net0 "$NETCONF" \
  -ostype debian \
  -unprivileged 1 \
  -features nesting=1 \
  -onboot 1

msg "Arrancando contenedor..."
pct start "$CTID"

msg "Esperando a que el contenedor tenga red y resolución DNS..."
NET_OK=0
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
    NET_OK=1
    break
  fi
  sleep 3
done

if [[ "$NET_OK" -ne 1 ]]; then
  err "El contenedor ${CTID} no tiene conectividad/DNS tras 90s. Revisa la configuración de red (bridge ${BRIDGE}, IP ${IPADDR:-DHCP})."
  exit 1
fi

########################
# DESCARGAR INSTALADOR #
########################

msg "Descargando instalador interno desde GitHub:"
echo "  ${RAW_URL}"

LXC_SCRIPT="/root/install-odoo19-pro.sh"
LXC_ENV_FILE="/root/.odoo19-install.env"

# Paquetes mínimos para poder descargar el instalador (git, curl, wget, etc.)
pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y curl wget ca-certificates git"

if ! pct exec "$CTID" -- bash -c "wget -qO ${LXC_SCRIPT} '${RAW_URL}' || curl -fsSL '${RAW_URL}' -o ${LXC_SCRIPT}"; then
  err "No se pudo descargar el instalador desde ${RAW_URL}. Comprueba usuario/repo/rama."
  exit 1
fi

# El instalador debe ser un script, no una página de error 404 de GitHub.
if ! pct exec "$CTID" -- head -n1 "${LXC_SCRIPT}" | grep -q '^#!'; then
  err "El fichero descargado no parece un script (¿ruta o rama incorrecta?): ${RAW_URL}"
  exit 1
fi

pct exec "$CTID" -- bash -c "chmod +x ${LXC_SCRIPT}"

########################
# EJECUTAR INSTALADOR  #
########################

# Workers de Odoo según las vCPUs asignadas al LXC: (vCPUs * 2) + 1.
# Se calcula aquí porque dentro del contenedor 'nproc' ve las CPUs del host.
ODOO_WORKERS=$(( CPUS * 2 + 1 ))
if (( ODOO_WORKERS > 16 )); then
  ODOO_WORKERS=16
fi

# Las credenciales viajan en un fichero de entorno en lugar de interpoladas en
# la línea de comandos: evita romper el quoting con contraseñas que contengan
# comillas y no deja las contraseñas visibles en la tabla de procesos.
ENV_TMP="$(mktemp)"
chmod 600 "${ENV_TMP}"
{
  printf "ODOO_DOMAIN=%q\n"     "${ODOO_DOMAIN}"
  printf "ODOO_DB_NAME=%q\n"    "${ODOO_DB_NAME}"
  printf "ODOO_DB_PASS=%q\n"    "${DB_PASS}"
  printf "ODOO_ADMIN_PASS=%q\n" "${ADMIN_PASS}"
  printf "ODOO_WORKERS=%q\n"    "${ODOO_WORKERS}"
  printf "export ODOO_DOMAIN ODOO_DB_NAME ODOO_DB_PASS ODOO_ADMIN_PASS ODOO_WORKERS\n"
} > "${ENV_TMP}"

pct push "$CTID" "${ENV_TMP}" "${LXC_ENV_FILE}" --perms 600

msg "Ejecutando instalador interno de Odoo 19 dentro del LXC..."

INSTALL_RC=0
pct exec "$CTID" -- bash -c ". ${LXC_ENV_FILE}; ${LXC_SCRIPT}" || INSTALL_RC=$?

# El fichero con contraseñas no debe quedarse dentro del contenedor.
pct exec "$CTID" -- rm -f "${LXC_ENV_FILE}" || true

if [[ "${INSTALL_RC}" -ne 0 ]]; then
  err "El instalador interno terminó con error (código ${INSTALL_RC}).
Revisa dentro del contenedor:
  pct exec ${CTID} -- journalctl -u odoo19 -n 100 --no-pager
  pct exec ${CTID} -- tail -n 100 /var/log/odoo/odoo19.log"
  exit "${INSTALL_RC}"
fi

########################
# RESUMEN FINAL        #
########################

msg "=== INSTALACIÓN COMPLETADA ==="

if [[ -n "$IPADDR" ]]; then
  LXC_IP="${IPADDR%%/*}"
else
  LXC_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "$LXC_IP" ]]; then
    LXC_IP="(DHCP sin IP todavía, consulta: pct exec ${CTID} -- hostname -I)"
  fi
fi

echo "CTID:           ${CTID}"
echo "Hostname:       ${HOSTNAME}"
echo "IP configurada: ${LXC_IP}"
echo "Dominio Odoo:   ${ODOO_DOMAIN:-(no configurado, usar IP)}"
echo
echo "Dentro del LXC, credenciales en: /root/odoo19-credentials.txt"
echo "  pct exec ${CTID} -- cat /root/odoo19-credentials.txt"
echo
echo "Acceso:"
echo "  http://${LXC_IP}/   --> asistente 'Create Database' (usa la DB ${ODOO_DB_NAME} y master password del fichero de credenciales)"
[[ -n "${ODOO_DOMAIN}" ]] && echo "  http://${ODOO_DOMAIN}/"
echo
msg "Listo. Odoo 19 preparado para crear la base desde el asistente y activar Conversaciones (websocket)."
