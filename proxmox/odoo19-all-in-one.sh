#!/usr/bin/env bash
# Odoo 19 Pro Installer for Proxmox LXC (Debian 13)
# - Descarga la última plantilla Debian 13 desde repos oficiales (pveam)
# - Crea un LXC Debian 13
# - Dentro del LXC instala Odoo 19 + PostgreSQL + Nginx + websocket (8069/8072)
# - Crea usuario systemd, servicio odoo19.service, reverse proxy Nginx y credenciales

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
# 
