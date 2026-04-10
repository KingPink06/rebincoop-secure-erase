#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# REBINCOOP Secure Erase — Flash USB
# Writes the ISO to a USB drive. Must run as root on Linux.
#
# Usage:
#   sudo bash flash-usb.sh /dev/sdX
#   make flash-usb USB=/dev/sdX
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${SCRIPT_DIR}/../dist"
ISO="${DIST_DIR}/rebincoop-secure-erase.iso"

# ── Argument check ─────────────────────────────────────────────────────────────
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    echo "Uso: $0 <dispositivo_usb>"
    echo "Ejemplo: $0 /dev/sdb"
    echo ""
    echo "Dispositivos USB detectados:"
    lsblk -o NAME,SIZE,TYPE,TRAN,MOUNTPOINT | grep -E "disk|usb" || lsblk
    exit 1
fi

# ── Safety checks ──────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Este script debe ejecutarse como root."
    echo "  sudo bash scripts/flash-usb.sh $TARGET"
    exit 1
fi

if [ ! -b "$TARGET" ]; then
    echo "ERROR: $TARGET no es un dispositivo de bloque."
    exit 1
fi

if [ ! -f "$ISO" ]; then
    echo "ERROR: ISO no encontrada en $ISO"
    echo "Ejecuta primero: make build-iso"
    exit 1
fi

ISO_SIZE=$(du -sh "$ISO" | cut -f1)
DEVICE_SIZE=$(lsblk -dn -o SIZE "$TARGET")

echo "══════════════════════════════════════════════"
echo "  REBINCOOP Secure Erase — Flashear USB"
echo "══════════════════════════════════════════════"
echo "  ISO:         $ISO ($ISO_SIZE)"
echo "  Dispositivo: $TARGET ($DEVICE_SIZE)"
echo ""

# Show what's currently on the device
lsblk "$TARGET" 2>/dev/null || true
echo ""

# Confirm
read -r -p "⚠ ADVERTENCIA: Esto borrará TODOS los datos en $TARGET. ¿Continuar? [s/N] " CONFIRM
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    echo "Operación cancelada."
    exit 0
fi

# Unmount any partitions on the device
echo ""
echo "Desmontando particiones..."
umount "${TARGET}"?* 2>/dev/null || umount "$TARGET" 2>/dev/null || true

# Flash
echo "Flashing $ISO → $TARGET ..."
echo "(Esto puede tardar 2-5 minutos según la velocidad del USB)"
echo ""

dd if="$ISO" of="$TARGET" \
    bs=4M \
    status=progress \
    oflag=sync \
    conv=fsync

sync

echo ""
echo "════════════════════════════════════════════"
echo "  ✓ USB flasheado correctamente"
echo "  Puedes extraer el USB de forma segura."
echo ""
echo "  Para arrancar:"
echo "    1. Inserta el USB en el PC a borrar"
echo "    2. Entra en la BIOS/UEFI (F2, F12, DEL...)"
echo "    3. Selecciona el USB como dispositivo de arranque"
echo "    4. El sistema arrancará en ~60s"
echo "════════════════════════════════════════════"
