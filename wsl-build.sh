#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# REBINCOOP Secure Erase — WSL Build Script
#
# Ejecutar desde WSL (Ubuntu):
#   cd /mnt/c/Users/Utilisateur/Documents/Proyectos\ Code/rebincoop-secure-erase
#   bash wsl-build.sh
#
# Requisitos: Docker Desktop con integración WSL activada
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Colores ───────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m══════ %s ══════\033[0m\n' "$*"; }

# ── Rutas ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
DIST_DIR="$PROJECT_ROOT/dist"
BUILD_DIR="$PROJECT_ROOT/bootable"
APK_CACHE="/tmp/rebincoop-apkcache"
WHEELS_DIR="/tmp/rebincoop-wheels"
OUTPUT_ISO="$DIST_DIR/rebincoop-secure-erase.iso"

mkdir -p "$DIST_DIR" "$APK_CACHE" "$WHEELS_DIR"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   REBINCOOP Secure Erase — WSL Builder              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ══════════════════════════════════════════════════════
# PASO 0 — Verificar prerequisitos
# ══════════════════════════════════════════════════════
step "0  Verificando prerequisitos"

# Verificar Docker
if ! command -v docker &>/dev/null; then
    die "Docker no encontrado. Instala Docker Desktop y activa la integración WSL."
fi
if ! docker info &>/dev/null 2>&1; then
    die "Docker no está corriendo. Abre Docker Desktop primero."
fi
ok "Docker disponible"

# Instalar herramientas del sistema si faltan
MISSING_TOOLS=""
for tool in xorriso wget isohybrid; do
    command -v "$tool" &>/dev/null || MISSING_TOOLS="$MISSING_TOOLS $tool"
done

if [ -n "$MISSING_TOOLS" ]; then
    log "Instalando herramientas faltantes:$MISSING_TOOLS"
    sudo apt-get update -qq
    sudo apt-get install -y xorriso wget mtools dosfstools syslinux-utils ca-certificates 2>/dev/null
fi
ok "Herramientas del sistema listas"

# ══════════════════════════════════════════════════════
# PASO 1 — Descargar paquetes APK con Alpine en Docker
# ══════════════════════════════════════════════════════
step "1  Descargando paquetes Alpine (puede tardar 3-5 min)"

# Reusar caché si ya existe y tiene paquetes
if ls "$APK_CACHE"/*.apk &>/dev/null 2>&1 && \
   [ -f "$APK_CACHE/APKINDEX.tar.gz" ]; then
    PKG_COUNT=$(ls "$APK_CACHE"/*.apk | wc -l)
    warn "Usando caché existente: ${PKG_COUNT} paquetes (borra $APK_CACHE para refrescar)"
else
    log "Descargando desde Alpine 3.19 en Docker..."
    docker run --rm \
        -v "${APK_CACHE}:/out" \
        alpine:3.19 /bin/sh -c '
            set -e
            printf "%s\n" \
                "https://dl-cdn.alpinelinux.org/alpine/v3.19/main" \
                "https://dl-cdn.alpinelinux.org/alpine/v3.19/community" \
                > /etc/apk/repositories
            apk update -q

            echo "Descargando paquetes APK con dependencias..."
            apk fetch -q --recursive --output /out \
                python3 py3-pip \
                smartmontools hdparm nvme-cli \
                util-linux lsblk pciutils usbutils dmidecode \
                e2fsprogs dosfstools \
                chromium \
                xorg-server \
                xf86-video-fbdev xf86-video-vesa xf86-video-modesetting \
                xf86-input-libinput \
                xinit openbox dbus dbus-openrc \
                mesa-dri-gallium font-dejavu \
                shadow bash libxrandr xrandr

            echo "Generando APKINDEX local..."
            cd /out
            apk index --no-warnings --output APKINDEX.tar.gz *.apk
            echo "Paquetes descargados: $(ls *.apk | wc -l)"
        '
    ok "APK cache listo: $(ls "$APK_CACHE"/*.apk | wc -l) paquetes"
fi

# ══════════════════════════════════════════════════════
# PASO 2 — Descargar wheels Python
# ══════════════════════════════════════════════════════
step "2  Descargando wheels Python"

if ls "$WHEELS_DIR"/*.whl &>/dev/null 2>&1; then
    warn "Usando wheels existentes: $(ls "$WHEELS_DIR"/*.whl | wc -l) wheels"
else
    docker run --rm \
        -v "${WHEELS_DIR}:/wheels" \
        alpine:3.19 /bin/sh -c '
            set -e
            printf "%s\n" \
                "https://dl-cdn.alpinelinux.org/alpine/v3.19/main" \
                "https://dl-cdn.alpinelinux.org/alpine/v3.19/community" \
                > /etc/apk/repositories
            apk update -q
            apk add --no-cache python3 py3-pip

            pip3 download \
                --dest /wheels \
                --no-deps \
                --prefer-binary \
                fastapi uvicorn websockets fpdf2 python-multipart \
                anyio starlette click h11 idna sniffio \
                exceptiongroup typing_extensions
            echo "Wheels: $(ls /wheels/*.whl | wc -l)"
        '
    ok "Wheels listos: $(ls "$WHEELS_DIR"/*.whl | wc -l)"
fi

# ══════════════════════════════════════════════════════
# PASO 3 — Preparar archivos de la app
# ══════════════════════════════════════════════════════
step "3  Preparando archivos de la app"

mkdir -p "$BUILD_DIR/app"
for f in main.py disk_manager.py erase_engine.py pdf_generator.py system_info.py index.html; do
    if [ -f "$PROJECT_ROOT/$f" ]; then
        cp "$PROJECT_ROOT/$f" "$BUILD_DIR/app/"
        ok "→ $f"
    else
        warn "No encontrado: $f"
    fi
done

# ══════════════════════════════════════════════════════
# PASO 4 — Construir el ISO
# ══════════════════════════════════════════════════════
step "4  Construyendo ISO (puede tardar 2-5 min)"

export DIST_DIR
export BUILD_DIR
export WHEELS_DIR
export APKCACHE_DIR="$APK_CACHE"

bash "$BUILD_DIR/scripts/build-iso.sh"

# ══════════════════════════════════════════════════════
# PASO 5 — Verificar estructura del ISO
# ══════════════════════════════════════════════════════
step "5  Verificando estructura del ISO"

VERIFY_MNT="/tmp/rebincoop-verify"
mkdir -p "$VERIFY_MNT"

if sudo mount -o loop,ro "$OUTPUT_ISO" "$VERIFY_MNT" 2>/dev/null; then
    # Verificar archivos críticos de arranque
    ERRORS=0

    check_file() {
        if [ -f "$VERIFY_MNT/$1" ]; then
            SIZE=$(du -sh "$VERIFY_MNT/$1" 2>/dev/null | cut -f1)
            ok "$1 (${SIZE})"
        else
            warn "FALTA: $1"
            ERRORS=$((ERRORS + 1))
        fi
    }

    check_file "boot/vmlinuz-lts"
    check_file "boot/initramfs-lts"
    check_file "boot/modloop-lts"
    check_file "rebincoop.apkovl.tar.gz"

    # Verificar que el modloop es un squashfs válido
    if [ -f "$VERIFY_MNT/boot/modloop-lts" ]; then
        MODLOOP_MAGIC=$(xxd "$VERIFY_MNT/boot/modloop-lts" | head -1 | awk '{print $2$3}')
        if [[ "$MODLOOP_MAGIC" == "73717368"* ]] || [[ "$MODLOOP_MAGIC" == "68737173"* ]]; then
            ok "modloop-lts es squashfs válido ✓"
        else
            warn "modloop-lts magic bytes: $MODLOOP_MAGIC (esperado: squashfs)"
        fi
    fi

    # Verificar GRUB config
    GRUB_CFG=""
    for c in "$VERIFY_MNT/boot/grub/grub.cfg" "$VERIFY_MNT/grub/grub.cfg"; do
        [ -f "$c" ] && GRUB_CFG="$c" && break
    done

    if [ -n "$GRUB_CFG" ]; then
        ok "GRUB config encontrado"
        if grep -q 'modloop=' "$GRUB_CFG"; then
            ok "modloop= presente en GRUB ✓"
        else
            warn "modloop= NO está en GRUB config — puede fallar el boot"
        fi
        if grep -q 'apkovl=' "$GRUB_CFG"; then
            ok "apkovl= presente en GRUB ✓"
        else
            warn "apkovl= NO está en GRUB config"
        fi
    else
        warn "GRUB config no encontrado en el ISO"
        ERRORS=$((ERRORS + 1))
    fi

    # Verificar APK cache
    APK_COUNT=$(ls "$VERIFY_MNT/apks/" 2>/dev/null | wc -l || echo 0)
    ok "APK cache: ${APK_COUNT} entradas"

    sudo umount "$VERIFY_MNT" 2>/dev/null || true

    if [ "$ERRORS" -eq 0 ]; then
        ok "ISO verificado correctamente ✓"
    else
        warn "ISO tiene ${ERRORS} problema(s) — revisa los warnings arriba"
    fi
else
    warn "No se pudo montar el ISO para verificar (normal si no hay permisos de loop)"
    ok "ISO creado en: $OUTPUT_ISO"
fi

# ══════════════════════════════════════════════════════
# PASO 6 — Copiar al escritorio de Windows
# ══════════════════════════════════════════════════════
step "6  Copiando ISO al escritorio de Windows"

# Intentar detectar el escritorio de Windows
WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n' || echo "")
if [ -n "$WIN_USER" ] && [ -d "/mnt/c/Users/$WIN_USER/Desktop" ]; then
    cp "$OUTPUT_ISO" "/mnt/c/Users/$WIN_USER/Desktop/"
    ok "ISO copiado al escritorio: C:\\Users\\${WIN_USER}\\Desktop\\rebincoop-secure-erase.iso"
else
    ok "ISO listo en: $OUTPUT_ISO"
    log "Copia manual al escritorio:"
    log "  cp \"$OUTPUT_ISO\" /mnt/c/Users/Utilisateur/Desktop/"
fi

ISO_SIZE=$(du -sh "$OUTPUT_ISO" | cut -f1)
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ISO LISTO ✓                                       ║"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Tamaño : %-42s║\n" "$ISO_SIZE"
printf "║  Ruta   : %-42s║\n" "$(basename "$OUTPUT_ISO")"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Flashear con Rufus (Windows):                      ║"
echo "║    → Modo: ISO Image (recomendado)                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
