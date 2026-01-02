#!/usr/bin/env bash
set -e

# Leer variables de entorno (las pondrá el script de Proxmox)
ODOO_DOMAIN="${ODOO_DOMAIN:-odoo19.local}"
ODOO_DB_PASS="${ODOO_DB_PASS:-$(openssl rand -base64 24)}"
ODOO_ADMIN_PASS="${ODOO_ADMIN_PASS:-$(openssl rand -base64 24)}"

# Aquí irán todos los pasos de instalación que ya hemos ido diseñando:
# - apt update / full-upgrade
# - locales, ssh
# - postgresql, python/venv, git, nginx, wkhtmltopdf
# - odoo.conf, systemd, nginx 8069/8072, etc.

# De momento, solo para probar flujo:
echo "Dominio: $ODOO_DOMAIN"
echo "DB pass: $ODOO_DB_PASS"
echo "Admin pass: $ODOO_ADMIN_PASS"

# Guardar credenciales
cat > /root/odoo19-credentials.txt <<EOF
Dominio Odoo: $ODOO_DOMAIN
DB user: odoo
DB pass: $ODOO_DB_PASS
admin_passwd: $ODOO_ADMIN_PASS
EOF
chmod 600 /root/odoo19-credentials.txt

