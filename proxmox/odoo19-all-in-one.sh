#!/usr/bin/env bash
set -e

TEMPLATE_STORAGE="local"
TEMPLATE="debian-13-standard_13.0-1_amd64.tar.zst"

read -p "CTID (ej 190): " CTID
read -p "Hostname (ej odoo19): " HOST
read -p "Disk size en GB (ej 32): " DISK
read -p "RAM en MB (ej 4096): " RAM
read -p "vCPU (ej 2): " CPU
read -p "Dominio Odoo (ej erp.midominio.com): " DOMAIN

# Generar passwords seguros
ODOO_DB_PASS=$(openssl rand -base64 24)
ODOO_ADMIN_PASS=$(openssl rand -base64 24)

echo "Creando LXC ${CTID} (${HOST})..."

pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  -hostname "${HOST}" \
  -rootfs "${TEMPLATE_STORAGE}:${DISK}" \
  -cores "${CPU}" \
  -memory "${RAM}" \
  -swap 512 \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp \
  -features nesting=1 \
  -unprivileged 1

pct start "${CTID}"

echo "Ejecutando instalador dentro del LXC..."
pct exec "${CTID}" -- bash -c "
  apt update && apt install -y curl
  curl -fsSL https://raw.githubusercontent.com/<TU_USUARIO>/<TU_REPO>/main/lxc/install-odoo19-pro.sh -o /root/install-odoo19-pro.sh
  chmod +x /root/install-odoo19-pro.sh
  export ODOO_DOMAIN='${DOMAIN}'
  export ODOO_DB_PASS='${ODOO_DB_PASS}'
  export ODOO_ADMIN_PASS='${ODOO_ADMIN_PASS}'
  /root/install-odoo19-pro.sh
"

echo "Contraseñas generadas:"
echo " DB pass: ${ODOO_DB_PASS}"
echo " admin_passwd: ${ODOO_ADMIN_PASS}"
echo "Dentro del LXC se guardan también en /root/odoo19-credentials.txt"

