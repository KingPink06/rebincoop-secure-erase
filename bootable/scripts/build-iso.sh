#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# REBINCOOP Secure Erase — ISO Build Script
# Runs inside the Docker builder container (FROM alpine:3.19, --privileged).
#
# Boot flow of the produced ISO:
#   GRUB (BIOS+EFI) ──► Alpine vmlinuz-lts + initramfs-lts
#     └─ initramfs mounts USB, finds rebincoop.apkovl.tar.gz
#        └─ openrc default runlevel
#             ├─ local.d/00-setup.start  → install APKs & pip wheels
#             └─ local.d/10-rebincoop.start → uvicorn :8420
#                └─ inittab: auto-login kiosk → startx → Chromium kiosk
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
ALPINE_VER="3.19.4"
ALPINE_BRANCH="v${ALPINE_VER%.*}"   # v3.19
ALPINE_ARCH="x86_64"
ALPINE_FLAVOR="extended"
ALPINE_ISO="${ALPINE_FLAVOR}-${ALPINE_VER}-${ALPINE_ARCH}.iso"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/alpine-${ALPINE_ISO}"
ALPINE_REPO="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}"

DIST_DIR="${DIST_DIR:-/dist}"
BUILD_DIR="${BUILD_DIR:-/build}"
WHEELS_DIR="${WHEELS_DIR:-/wheels}"
STAGING="/tmp/staging"
ISO_WORK="/tmp/iso-work"
APK_CACHE="/tmp/apkcache"
ISO_PATH="/tmp/alpine-${ALPINE_ISO}"
OUTPUT_ISO="${DIST_DIR}/rebincoop-secure-erase.iso"

# Packages to bake into the offline APK cache
PACKAGES=(
    python3 py3-pip
    smartmontools hdparm nvme-cli
    util-linux lsblk e2fsprogs dosfstools
    pciutils usbutils dmidecode
    chromium
    xorg-server xf86-video-fbdev xf86-video-vesa xf86-video-modesetting
    xf86-input-libinput xf86-input-keyboard xf86-input-mouse
    xinit openbox dbus dbus-openrc
    mesa-dri-gallium
    font-dejavu
    shadow bash
    libxrandr xrandr
)

# ── Helpers ────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\033[1;36m────\033[0m %s\n' "$*"; }

mkdir -p "$DIST_DIR" "$ISO_WORK" "$APK_CACHE" "$STAGING"

# ══════════════════════════════════════════════════════
# STEP 1 — Download Alpine ISO
# ══════════════════════════════════════════════════════
step "1/7  Descargando Alpine Linux ${ALPINE_VER} (${ALPINE_FLAVOR})..."

if [ -f "$ISO_PATH" ]; then
    warn "ISO ya en caché: $ISO_PATH"
else
    wget -q --show-progress "$ALPINE_URL" -O "$ISO_PATH" \
        || die "No se pudo descargar la ISO"
fi

# Verify checksum
CHECKSUM_URL="${ALPINE_URL}.sha256"
if wget -qO /tmp/alpine.sha256 "$CHECKSUM_URL" 2>/dev/null; then
    # The downloaded sha256 file has "hash  alpine-flavor-ver-arch.iso"
    # We need to check against our local file
    EXPECTED=$(awk '{print $1}' /tmp/alpine.sha256)
    ACTUAL=$(sha256sum "$ISO_PATH" | awk '{print $1}')
    if [ "$EXPECTED" = "$ACTUAL" ]; then
        ok "SHA-256 verificado"
    else
        warn "SHA-256 no coincide — continuando de todas formas"
    fi
fi

# ══════════════════════════════════════════════════════
# STEP 2 — Extract ISO
# ══════════════════════════════════════════════════════
step "2/7  Extrayendo ISO..."

rm -rf "${ISO_WORK:?}"/*
xorriso -osirrox on -indev "$ISO_PATH" -extract / "$ISO_WORK/" 2>/dev/null \
    || die "xorriso falló al extraer la ISO"
chmod -R u+w "$ISO_WORK/"
ok "ISO extraída en $ISO_WORK ($(du -sh "$ISO_WORK" | cut -f1))"

# ══════════════════════════════════════════════════════
# STEP 3 — Offline APK cache
# ══════════════════════════════════════════════════════
step "3/7  Descargando paquetes APK (caché offline)..."

if command -v apk > /dev/null 2>&1; then
    # Configure Alpine repos — works as root (Docker) or non-root (GitHub runner w/ sudo)
    if [ "$(id -u)" = "0" ]; then
        printf '%s\n' "${ALPINE_REPO}/main" "${ALPINE_REPO}/community" \
            > /etc/apk/repositories
    else
        printf '%s\n' "${ALPINE_REPO}/main" "${ALPINE_REPO}/community" \
            | sudo tee /etc/apk/repositories > /dev/null 2>&1 || true
    fi
    apk update -q 2>/dev/null || true

    # Fetch packages and all dependencies
    mkdir -p "$APK_CACHE"
    apk fetch --recursive --output "$APK_CACHE" \
        --allow-untrusted \
        "${PACKAGES[@]}" 2>/dev/null \
        || warn "Algunos paquetes no se pudieron descargar — se instalarán desde internet en el primer arranque"

    PKG_COUNT=$(find "$APK_CACHE" -name '*.apk' | wc -l)
    ok "${PKG_COUNT} paquetes descargados"

    if [ "$PKG_COUNT" -gt 0 ]; then
        # Merge APK cache into the ISO's /apks directory
        mkdir -p "${ISO_WORK}/apks/${ALPINE_ARCH}"
        find "$APK_CACHE" -name '*.apk' -exec cp -n {} "${ISO_WORK}/apks/${ALPINE_ARCH}/" \;

        # Rebuild APKINDEX (unsigned — installer uses --allow-untrusted)
        log "  → Regenerando APKINDEX..."
        apk index \
            --no-warnings \
            --output "${ISO_WORK}/apks/${ALPINE_ARCH}/APKINDEX.tar.gz" \
            "${ISO_WORK}/apks/${ALPINE_ARCH}"/*.apk 2>/dev/null \
            || warn "No se pudo regenerar APKINDEX — se usará el índice original"
        ok "Caché APK lista en ISO ($(du -sh "${ISO_WORK}/apks" | cut -f1))"
    fi
else
    warn "apk no disponible — caché offline omitida (se instalará desde internet al primer arranque)"
fi

# ══════════════════════════════════════════════════════
# STEP 4 — Build apkovl
# ══════════════════════════════════════════════════════
step "4/7  Construyendo apkovl.tar.gz..."

# Start from our overlay template
rm -rf "$STAGING"
cp -r "${BUILD_DIR}/apkovl" "$STAGING"

# ── Copy pip wheels ──
WHEEL_DST="${STAGING}/opt/rebincoop/wheels"
mkdir -p "$WHEEL_DST"
if ls "$WHEELS_DIR"/*.whl > /dev/null 2>&1; then
    cp "$WHEELS_DIR"/*.whl "$WHEEL_DST/"
    WHEEL_COUNT=$(ls "$WHEEL_DST"/*.whl | wc -l)
    ok "  ${WHEEL_COUNT} wheels incluidos"
else
    warn "  No se encontraron wheels — pip usará red en primer arranque"
fi

# ── Copy app source ──
APP_FILES=(main.py disk_manager.py erase_engine.py pdf_generator.py system_info.py index.html)
APP_DST="${STAGING}/opt/rebincoop"
mkdir -p "$APP_DST"

for f in "${APP_FILES[@]}"; do
    # Look in /build/app/ first, then /build/../ (monorepo root)
    for src in "${BUILD_DIR}/app/${f}" "${BUILD_DIR}/../${f}" "${BUILD_DIR}/${f}"; do
        if [ -f "$src" ]; then
            cp "$src" "$APP_DST/"
            ok "  → $f"
            break
        fi
    done
done

# ── Create openrc runlevel symlinks ──
# These tell openrc which services to start in the 'default' runlevel.
# We create them as proper symlinks inside the staging dir.
mkdir -p "${STAGING}/etc/runlevels/sysinit"
mkdir -p "${STAGING}/etc/runlevels/boot"
mkdir -p "${STAGING}/etc/runlevels/default"
mkdir -p "${STAGING}/etc/runlevels/shutdown"

# Default runlevel: local (runs local.d scripts) + dbus
for svc in local dbus; do
    ln -sf "/etc/init.d/${svc}" "${STAGING}/etc/runlevels/default/${svc}"
done

# ── Permissions ──
chmod 755 "${STAGING}/etc/local.d/"*.start 2>/dev/null || true
chmod 755 "${STAGING}/home/kiosk/.xinitrc" 2>/dev/null || true
chmod 644 "${STAGING}/home/kiosk/.bash_profile" 2>/dev/null || true
chmod 644 "${STAGING}/home/kiosk/.config/openbox/rc.xml" 2>/dev/null || true

# ── Pack apkovl ──
APKOVL_TAR="/tmp/rebincoop.apkovl.tar.gz"
( cd "$STAGING" && tar czf "$APKOVL_TAR" . )
APKOVL_SIZE=$(du -sh "$APKOVL_TAR" | cut -f1)
ok "apkovl.tar.gz listo (${APKOVL_SIZE})"

# Copy into ISO root — Alpine initrd scans the boot device root for *.apkovl.tar.gz
cp "$APKOVL_TAR" "${ISO_WORK}/rebincoop.apkovl.tar.gz"

# ══════════════════════════════════════════════════════
# STEP 5 — Patch GRUB menu
# ══════════════════════════════════════════════════════
step "5/7  Personalizando menú de arranque..."

# Find GRUB config (location varies by Alpine version)
GRUB_CFG=""
for candidate in \
    "${ISO_WORK}/boot/grub/grub.cfg" \
    "${ISO_WORK}/grub/grub.cfg" \
    "${ISO_WORK}/EFI/boot/grub.cfg"; do
    if [ -f "$candidate" ]; then
        GRUB_CFG="$candidate"
        break
    fi
done

if [ -n "$GRUB_CFG" ]; then
    cp "$GRUB_CFG" "${GRUB_CFG}.orig"
    cat > "$GRUB_CFG" <<'GRUBEOF'
# ── REBINCOOP Secure Erase ──────────────────────────────────────────────────
set default=0
set timeout=5
set timeout_style=menu

if loadfont /boot/grub/fonts/unicode.pf2; then
    set gfxmode=1920x1080,1280x720,auto
    insmod all_video
    insmod gfxterm
    terminal_output gfxterm
fi

menuentry "REBINCOOP Secure Erase" --class rebincoop {
    linux  /boot/vmlinuz-lts \
           modules=loop,squashfs,sd-mod,usb-storage \
           alpine_dev=usb quiet loglevel=0 \
           nomodeset=0
    initrd /boot/initramfs-lts
}

menuentry "REBINCOOP Secure Erase (verbose)" --class rebincoop {
    linux  /boot/vmlinuz-lts \
           modules=loop,squashfs,sd-mod,usb-storage \
           alpine_dev=usb loglevel=5
    initrd /boot/initramfs-lts
}

menuentry "Shell de emergencia" --class alpine {
    linux  /boot/vmlinuz-lts \
           modules=loop,squashfs,sd-mod,usb-storage \
           alpine_dev=usb
    initrd /boot/initramfs-lts
}
GRUBEOF
    ok "GRUB personalizado: $GRUB_CFG"
else
    warn "grub.cfg no encontrado — se usa el menú por defecto de Alpine"
fi

# Patch syslinux config if present (BIOS alternative)
SYSLINUX_CFG="${ISO_WORK}/syslinux/syslinux.cfg"
if [ ! -f "$SYSLINUX_CFG" ]; then
    SYSLINUX_CFG="${ISO_WORK}/boot/syslinux/syslinux.cfg"
fi
if [ -f "$SYSLINUX_CFG" ]; then
    # Inject our label at the top
    sed -i '1s/^/DEFAULT rebincoop\nLABEL rebincoop\n  MENU LABEL REBINCOOP Secure Erase\n  KERNEL \/boot\/vmlinuz-lts\n  INITRD \/boot\/initramfs-lts\n  APPEND modules=loop,squashfs,sd-mod,usb-storage alpine_dev=usb quiet\n\n/' \
        "$SYSLINUX_CFG" 2>/dev/null || true
    ok "syslinux.cfg personalizado"
fi

# ══════════════════════════════════════════════════════
# STEP 6 — Create final ISO
# ══════════════════════════════════════════════════════
step "6/7  Creando ISO final (puede tardar unos minutos)..."

mkdir -p "$DIST_DIR"

# Extract the exact boot options from the original Alpine ISO.
# xorriso -report_el_torito as_mkisofs outputs something like:
#   -b isolinux/isolinux.bin -no-emul-boot -boot-load-size 4 ...
#   -eltorito-alt-boot -e efi.img -no-emul-boot -isohybrid-gpt-basdat
BOOT_OPTS_RAW=$(xorriso -indev "$ISO_PATH" -report_el_torito as_mkisofs 2>/dev/null || true)

if [ -n "$BOOT_OPTS_RAW" ]; then
    log "  → Usando boot record del ISO Alpine original"
    # Build the command as an array to preserve quoting
    # shellcheck disable=SC2206
    BOOT_OPTS_ARR=( $BOOT_OPTS_RAW )
    xorriso -as mkisofs \
        "${BOOT_OPTS_ARR[@]}" \
        -o "$OUTPUT_ISO" \
        -V "REBINCOOP" \
        -r -J --joliet-long \
        "$ISO_WORK/" 2>&1 | tail -5
else
    warn "  → No se pudo leer el boot record — creando ISO híbrida desde cero"
    # Fallback: create a BIOS-bootable ISO using isolinux if available
    if [ -f "${ISO_WORK}/boot/syslinux/isolinux.bin" ] || \
       [ -f "${ISO_WORK}/syslinux/isolinux.bin" ]; then
        ISOLINUX_BIN=$(find "$ISO_WORK" -name 'isolinux.bin' | head -1)
        ISOLINUX_REL="${ISOLINUX_BIN#${ISO_WORK}/}"
        BOOT_CAT="${ISOLINUX_REL%/*}/boot.cat"
        xorriso -as mkisofs \
            -o "$OUTPUT_ISO" \
            -V "REBINCOOP" \
            -r -J --joliet-long \
            -b "$ISOLINUX_REL" \
            -c "$BOOT_CAT" \
            -no-emul-boot -boot-load-size 4 -boot-info-table \
            "$ISO_WORK/" 2>&1 | tail -5
    else
        # Last resort: plain ISO (no boot — user can still dd it as Alpine handles its own boot)
        xorriso -as mkisofs \
            -o "$OUTPUT_ISO" \
            -V "REBINCOOP" \
            -r -J --joliet-long \
            "$ISO_WORK/" 2>&1 | tail -5
        warn "  → ISO creada sin MBR bootable (puede requerir Rufus/Ventoy)"
    fi
fi

# Make the image hybrid (bootable when dd'd to USB)
if command -v isohybrid > /dev/null 2>&1; then
    isohybrid "$OUTPUT_ISO" 2>/dev/null && ok "  → isohybrid aplicado" || true
fi

ISO_SIZE=$(du -sh "$OUTPUT_ISO" | cut -f1)
ok "ISO creada: $OUTPUT_ISO (${ISO_SIZE})"

# ══════════════════════════════════════════════════════
# STEP 7 — Checksum of output
# ══════════════════════════════════════════════════════
step "7/7  Generando checksum..."
sha256sum "$OUTPUT_ISO" > "${OUTPUT_ISO}.sha256"
ok "SHA-256: $(cat "${OUTPUT_ISO}.sha256" | awk '{print $1}')"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   REBINCOOP Secure Erase — ISO lista ✓              ║"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Tamaño : %-42s║\n" "${ISO_SIZE}"
printf "║  Ruta   : %-42s║\n" "$OUTPUT_ISO"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Flashear al USB (Linux, como root):                ║"
echo "║    make flash-usb USB=/dev/sdX                      ║"
echo "║  O con Rufus (Windows) / Etcher (cualquier OS)      ║"
echo "╚══════════════════════════════════════════════════════╝"
