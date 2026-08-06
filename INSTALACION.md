# Instalación de Odoo 19 en LXC de Proxmox

Dos scripts, y solo ejecutas uno:

| Script | Dónde corre | Quién lo lanza |
|---|---|---|
| `proxmox/odoo19-all-in-one.sh` | En el **nodo Proxmox** | **Tú** |
| `lxc/install-odoo19-pro.sh` | **Dentro del contenedor** | El anterior, solo |

El primero crea el LXC, se descarga el segundo desde GitHub y lo ejecuta dentro.
Por eso **los dos ficheros tienen que estar en la misma rama de GitHub**: es la
única diferencia entre los dos casos de abajo.

---

## Antes de empezar

- Acceso al nodo Proxmox VE como **root** (por SSH o por la consola del panel).
- El nodo necesita: `pct`, `pveam`, `curl`, `wget`, `openssl` (vienen de serie en Proxmox).
- Que Proxmox ya ofrezca la plantilla **Debian 13**. Compruébalo con:

```bash
pveam update && pveam available | grep debian-13-standard
```

Si no sale nada, tu Proxmox aún no la tiene y el script se parará avisando.

- Espacio libre en el storage del rootfs (por defecto pide 100 GB).

---

 — Instalación normal (ficheros ya en `main`)

Es el caso definitivo, una vez hayas fusionado los cambios a `main`.

**1. Entra en el nodo Proxmox como root** y descarga el instalador:

```bash
wget -O odoo19-all-in-one.sh \
  https://raw.githubusercontent.com/jsanz2020/proxmox-lxc/main/proxmox/odoo19-all-in-one.sh
chmod +x odoo19-all-in-one.sh
```

**2. Ejecútalo:**

```bash
./odoo19-all-in-one.sh
```

**3. Responde las preguntas** (ver tabla más abajo). Pulsa ENTER para aceptar
los valores por defecto.

**4. Espera.** Tarda un rato largo — orientativamente **entre 10 y 30 minutos**
según CPU y red: clona el código de Odoo y compila dependencias de Python.
Verás mensajes `[INFO]` y `[ODOO-SETUP]` conforme avanza.

**5. Crea la base de datos** desde el navegador (paso 5 detallado abajo).


> **Por qué `refs/heads/`**: esta rama lleva barras en el nombre
> (`claude/revisar-...`), y en una URL de `raw.githubusercontent.com` eso es
> ambiguo — GitHub no puede saber dónde acaba el nombre de la rama y dónde
> empieza la ruta del fichero. El prefijo `refs/heads/` lo deja sin ambigüedad.
> Para una rama sin barras (`pruebas`, por ejemplo) basta con `GITHUB_BRANCH=pruebas`.

Si te equivocas de rama, el script lo detecta: comprueba que lo descargado
empieza por `#!` y aborta con un aviso claro en lugar de intentar ejecutar una
página de error 404.

---

## Qué preguntas te hará

En este orden. ENTER = valor por defecto.

| Pregunta | Por defecto | Notas |
|---|---|---|
| Storage para la plantilla | `local` | Donde se guarda la plantilla Debian 13 |
| **CTID** | *(sin defecto)* | ID del contenedor, ej. `199`. Debe ser ≥ 100 y estar libre |
| Hostname | `odoo19` | |
| Bridge de red | `vmbr0` | |
| IP/CIDR | *(vacío = DHCP)* | Ej. `192.168.1.186/24` |
| Gateway | *(vacío)* | Solo lo pregunta si pusiste IP fija |
| Disco (GB) | `100` | |
| RAM (MB) | `8192` | |
| Swap (MB) | `2048` | |
| vCPUs | `4` | De aquí salen los *workers* de Odoo: (vCPUs × 2) + 1 |
| Storage del rootfs | `local-lvm` | |
| Dominio | *(vacío = usar IP)* | Ej. `odoo.midominio.com` |
| Nombre de la base | `odoo19` | Solo una sugerencia; la base la creas tú después |
| Contraseña de PostgreSQL | *(ENTER = genera una segura)* | |
| Contraseña de admin de Odoo | *(ENTER = genera una segura)* | Es la *master password* |

Si dejas las contraseñas en blanco, se generan solas y quedan guardadas en el
fichero de credenciales. **Recomendado.**

El CTID y la IP se validan al vuelo: si el ID ya está en uso o el formato de la
IP está mal, te lo vuelve a preguntar en lugar de fallar a mitad de la creación.

---

## Paso 5 — Crear la base de datos

El script **no crea la base**, a propósito: la creas tú desde el asistente web.

1. Abre en el navegador `http://IP_DEL_CONTENEDOR/`
   (o `http://tu-dominio/` si configuraste dominio).
2. Te sale el asistente **Create Database**.
3. Rellena:
   - **Master Password**: la contraseña de admin (está en el fichero de credenciales).
   - **Database Name**: el nombre que elegiste, p. ej. `odoo19`.
   - Email y contraseña del usuario administrador de Odoo — **esto es distinto**
     de la master password: son tus credenciales para entrar al ERP.
4. Dale a *Create database* y espera a que inicialice.

Para ver las credenciales generadas:

```bash
pct exec CTID -- cat /root/odoo19-credentials.txt
```

(sustituye `CTID` por el que elegiste, p. ej. `199`)

---

## Paso 6 — Asegurar la instalación (recomendado)

Una vez creada la base, **desactiva el gestor de bases de datos** para que no
quede expuesto en internet:

```bash
pct exec CTID -- sed -i 's/^list_db = True/list_db = False/' /etc/odoo19.conf
pct exec CTID -- systemctl restart odoo19
```

**Sobre HTTPS**: la instalación deja Nginx sirviendo en **HTTP (puerto 80), sin
cifrado**. Si vas a exponer esto fuera de tu red local, monta un certificado —
lo habitual es Certbot dentro del contenedor:

```bash
pct exec CTID -- apt-get install -y certbot python3-certbot-nginx
pct exec CTID -- certbot --nginx -d tu-dominio.com
```

Certbot ajusta solo la configuración de Nginx que ha dejado el instalador.

---

## Qué queda instalado

| Cosa | Dónde |
|---|---|
| Código de Odoo | `/opt/odoo19/src/odoo` |
| Tus módulos propios | `/opt/odoo19/custom-addons` |
| Entorno virtual Python | `/opt/odoo19/venv` |
| Configuración | `/etc/odoo19.conf` |
| Servicio systemd | `odoo19.service` |
| Log de Odoo | `/var/log/odoo/odoo19.log` (rota semanalmente) |
| Logs de Nginx | `/var/log/nginx/odoo19-{access,error}.log` |
| Credenciales | `/root/odoo19-credentials.txt` (permisos 600) |

Puertos internos: **8069** (HTTP) y **8072** (websocket del bus, para
Conversaciones y notificaciones en vivo). Nginx hace de proxy delante, en el 80.

---

## Comandos útiles del día a día

Todo desde el nodo Proxmox, sustituyendo `CTID`:

```bash
# Entrar al contenedor
pct enter CTID

# Estado y logs del servicio
pct exec CTID -- systemctl status odoo19
pct exec CTID -- journalctl -u odoo19 -n 100 --no-pager
pct exec CTID -- tail -f /var/log/odoo/odoo19.log

# Reiniciar Odoo (tras tocar la configuración)
pct exec CTID -- systemctl restart odoo19

# Ver la IP real (útil con DHCP)
pct exec CTID -- hostname -I
```

Para instalar módulos propios, déjalos en `/opt/odoo19/custom-addons` dentro del
contenedor y reinicia el servicio.

---

## Si algo falla

**El script se para nada más empezar**
- *"debe ejecutarse en un nodo Proxmox VE"* → no estás en el nodo, o `pveversion` falla.
- *"debe ejecutarse como root"* → usa `sudo -i` primero.
- *"No se encontró plantilla debian-13-standard"* → tu Proxmox aún no ofrece Debian 13.

**"El contenedor no tiene conectividad/DNS tras 90s"**
El LXC arrancó pero no sale a internet. Revisa el bridge, y si pusiste IP fija,
que el gateway sea correcto. Con DHCP, que haya servidor DHCP en esa VLAN.

**"El fichero descargado no parece un script"**
La rama o la ruta no existen en GitHub. Revisa `GITHUB_BRANCH` — si la rama
lleva barras, necesitas el prefijo `refs/heads/` (ver Caso B).

**"El instalador interno terminó con error"**
El contenedor **se queda creado** para que puedas mirar qué pasó:

```bash
pct exec CTID -- journalctl -u odoo19 -n 100 --no-pager
pct exec CTID -- tail -n 100 /var/log/odoo/odoo19.log
```

Se puede volver a lanzar el instalador interno sin recrear el contenedor: es
idempotente (no re-clona el código, no re-crea el venv, y si el rol de
PostgreSQL ya existe le actualiza la contraseña en vez de fallar).

**Los informes PDF fallan**
`wkhtmltopdf` no está en Debian 13, así que se instala desde el paquete oficial
del proyecto y **puede fallar** sin detener la instalación. Si viste ese aviso,
instálalo a mano desde https://github.com/wkhtmltopdf/packaging/releases

**Conversaciones (chat) no conecta**
Es el websocket. Comprueba que Nginx tiene la sección `/websocket` y que Odoo
escucha en el 8072:

```bash
pct exec CTID -- grep -A3 'location /websocket' /etc/nginx/sites-available/odoo19.conf
pct exec CTID -- ss -lntp | grep 8072
```

---

## Empezar de cero

Si quieres repetir la instalación desde el principio:

```bash
pct stop CTID && pct destroy CTID
```

Esto **borra el contenedor y todos sus datos**. Asegúrate del CTID antes.
