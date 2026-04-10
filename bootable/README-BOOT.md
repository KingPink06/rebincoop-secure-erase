# REBINCOOP Secure Erase — Versión Booteable

ISO booteable basada en Alpine Linux 3.19 con Chromium en modo kiosko.  
Sin instalación. Arranca desde USB en cualquier PC x86_64.

---

## Requisitos para construir la ISO

| Herramienta | Versión mínima | Notas |
|---|---|---|
| Docker | 20.x+ | Necesita soporte `--privileged` |
| GNU Make | 4.x | `make` en Linux/macOS |
| Internet | — | Para descargar Alpine ISO y paquetes |
| Espacio libre | ~4 GB | Para descarga + build |

> **Windows**: usa WSL2 + Docker Desktop. Ejecuta los comandos desde dentro de WSL2.

---

## Construir la ISO

```bash
# Desde el directorio bootable/
cd bootable

# Construir imagen Docker de build + generar ISO
# (la primera vez tarda 10-20 min por las descargas)
make build-iso

# La ISO queda en:
#   ../dist/rebincoop-secure-erase.iso   (~700 MB)
```

### Qué hace el build internamente

```
Dockerfile.builder
 └─ Alpine 3.19 + xorriso + py3-pip + descarga wheels
      └─ scripts/build-iso.sh
           ├─ 1. Descarga Alpine extended ISO
           ├─ 2. Extrae ISO
           ├─ 3. Descarga ~80 paquetes APK → caché offline en /apks/
           ├─ 4. Empaqueta apkovl.tar.gz
           │       ├─ etc/inittab          (auto-login kiosko)
           │       ├─ etc/local.d/         (startup scripts)
           │       ├─ home/kiosk/          (.xinitrc, openbox)
           │       ├─ opt/rebincoop/       (app + wheels pip)
           │       └─ etc/runlevels/       (servicios openrc)
           ├─ 5. Parchea GRUB (menú REBINCOOP)
           ├─ 6. Reempaqueta ISO con boot records originales
           └─ 7. SHA-256 del ISO de salida
```

---

## Flashear al USB

### Linux (recomendado)

```bash
# Identifica tu USB (¡cuidado, no confundas con tu disco!)
lsblk -o NAME,SIZE,TYPE,TRAN

# Flashear (como root, cambia /dev/sdX por tu dispositivo)
make flash-usb USB=/dev/sdX

# O manualmente con dd:
sudo dd if=../dist/rebincoop-secure-erase.iso \
        of=/dev/sdX \
        bs=4M status=progress oflag=sync
```

### Windows

Usa **Rufus** (gratis):
1. Descarga Rufus: https://rufus.ie
2. Selecciona el USB
3. Selecciona `rebincoop-secure-erase.iso`
4. Modo: **DD Image** (no ISO Image)
5. Click **Start**

O usa **Balena Etcher** (multiplataforma, más simple).

> ⚠️ **Un USB de 2 GB o más** es suficiente (~700 MB la ISO).

---

## Arrancar en un PC

1. Inserta el USB en el PC a borrar
2. Enciende el PC y entra a la BIOS/UEFI:
   - **F2** / **DEL** (la mayoría de placas)
   - **F12** / **F10** (HP, Lenovo, Dell)
   - **ESC** (algunas ASUS)
3. En el Boot Menu, selecciona el USB
4. Aparece el menú GRUB:
   ```
   REBINCOOP Secure Erase          ← seleccionar este
   REBINCOOP Secure Erase (verbose)
   Shell de emergencia
   ```
5. El sistema arranca en ~60 segundos:
   - Alpine se carga en RAM (~5s)
   - `00-setup.start` instala paquetes desde caché offline (~30s)
   - `10-rebincoop.start` levanta uvicorn en `:8420` (~5s)
   - X11 + Chromium abre automáticamente la app (~10s)

---

## Secuencia de arranque detallada

```
BIOS/UEFI
  └─ GRUB (cargado desde MBR del USB)
       └─ vmlinuz-lts + initramfs-lts (Alpine kernel)
            └─ Alpine initrd
                 ├─ Detecta USB como boot device
                 ├─ Extrae rebincoop.apkovl.tar.gz → /
                 └─ openrc runlevel 'default'
                      ├─ dbus.start
                      ├─ 00-setup.start
                      │    ├─ apk add --allow-untrusted [paquetes offline]
                      │    ├─ pip install --no-index [wheels en /opt/rebincoop/wheels/]
                      │    ├─ adduser kiosk (grupos: disk, video, input)
                      │    └─ rc-update add local dbus
                      └─ 10-rebincoop.start
                           └─ uvicorn main:app --host 0.0.0.0 --port 8420 &

inittab: tty1::respawn:/bin/login -f kiosk
  └─ /home/kiosk/.bash_profile
       └─ exec startx /home/kiosk/.xinitrc -- :0 vt1
            ├─ xset s off / -dpms   (sin apagado de pantalla)
            ├─ openbox &            (WM mínimo, sin decoraciones)
            └─ chromium-browser --kiosk http://localhost:8420
```

---

## Estructura de archivos

```
bootable/
├── Makefile                   ← Orquestación: build-iso, flash-usb
├── Dockerfile.builder         ← Entorno Docker Alpine con build tools
├── scripts/
│   ├── build-iso.sh           ← Script principal de construcción
│   └── flash-usb.sh           ← Flashear ISO al USB
└── apkovl/                    ← Overlay que Alpine aplica al arrancar
    ├── etc/
    │   ├── hostname            → rebincoop-kiosk
    │   ├── inittab             → auto-login usuario 'kiosk'
    │   ├── local.d/
    │   │   ├── 00-setup.start  → instala paquetes + crea usuario
    │   │   └── 10-rebincoop.start → arranca uvicorn
    │   ├── profile.d/
    │   │   └── kiosk-env.sh    → variables de entorno X11/Chromium
    │   ├── runlevels/
    │   │   └── default/
    │   │       ├── local       → symlink /etc/init.d/local
    │   │       └── dbus        → symlink /etc/init.d/dbus
    │   └── X11/xorg.conf.d/
    │       └── 10-screen.conf  → resolución + drivers X11
    ├── home/kiosk/
    │   ├── .bash_profile       → exec startx automático en tty1
    │   ├── .xinitrc            → openbox + chromium --kiosk
    │   └── .config/openbox/
    │       └── rc.xml          → sin menús, chromium fullscreen
    └── opt/rebincoop/
        ├── main.py             ← (copiado en build)
        ├── disk_manager.py     ← (copiado en build)
        ├── erase_engine.py     ← (copiado en build)
        ├── pdf_generator.py    ← (copiado en build)
        ├── system_info.py      ← (copiado en build)
        ├── index.html          ← (copiado en build)
        └── wheels/             ← (rellenado en build con .whl)
```

---

## Solución de problemas

### El USB no arranca
- Verifica que flasheaste en modo **DD** (no como unidad FAT)
- Prueba desactivar **Secure Boot** en la BIOS
- Prueba en modo **Legacy BIOS** si EFI falla (o viceversa)

### La pantalla se queda negra tras GRUB
- Selecciona "REBINCOOP Secure Erase (verbose)" para ver logs
- Puede ser un problema de driver de vídeo — prueba añadir `nomodeset` a la línea `linux` en GRUB (pulsa `e`)

### El kiosko no abre / Chromium no arranca
- En tty2 (Ctrl+Alt+F2), revisa:
  ```sh
  cat /var/log/rebincoop-setup.log
  cat /var/log/rebincoop-app.log
  ```

### Sin internet en el primer arranque
Los paquetes APK y wheels pip vienen en la ISO (caché offline).  
Si alguno falta, el script intentará descargarlo por red.  
Para uso completamente offline, asegúrate de que el build tuvo internet.

### Añadir paquetes extra a la ISO
Edita `PACKAGES` en `scripts/build-iso.sh` y reconstruye:
```bash
make clean && make build-iso
```

---

## Notas de seguridad

- El usuario `kiosk` tiene acceso al grupo `disk` (necesario para borrar discos físicos)
- El backend uvicorn corre como **root** para poder abrir `/dev/sdX` con `O_WRONLY`
- Chromium corre con `--no-sandbox` (requerido en Alpine sin user namespaces)
- El sistema es **stateless**: cada arranque parte de cero desde la RAM
- No hay contraseña de root por defecto — añade una en `00-setup.start` si el entorno lo requiere

---

## Compatibilidad BIOS / EFI

| Firmware | Soporte | Notas |
|---|---|---|
| BIOS Legacy | ✓ | Via isolinux/syslinux (incluido en Alpine extended) |
| UEFI 64-bit | ✓ | Via GRUB EFI (incluido en Alpine extended) |
| UEFI 32-bit | ✗ | No soportado |
| Secure Boot | ✗ | Requiere desactivarlo en BIOS |
| Mac (Intel) | ~ | Puede funcionar con boot USB via Option |
| Mac (ARM) | ✗ | No soportado |
