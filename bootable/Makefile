# ══════════════════════════════════════════════════════════════════════════════
# REBINCOOP Secure Erase — Bootable ISO Build System
#
# Requirements (on the build host):
#   - Docker (with --privileged support)
#   - GNU make
#   - Root access (for flash-usb target)
#
# Quick start:
#   make build-iso          # Build the ISO (~10-20 min first time)
#   make flash-usb USB=/dev/sdX   # Flash to USB (as root)
# ══════════════════════════════════════════════════════════════════════════════

SHELL     := /bin/bash
DIST_DIR  := $(abspath ../dist)
APP_DIR   := $(abspath ..)
ISO_NAME  := rebincoop-secure-erase.iso
IMAGE_TAG := rebincoop-builder

.PHONY: all build-image build-iso flash-usb clean help

all: build-iso

# ── help ──────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  REBINCOOP Secure Erase — Build System"
	@echo ""
	@echo "  Targets:"
	@echo "    make build-image       Build the Docker builder image"
	@echo "    make build-iso         Build the bootable ISO (runs build-image first)"
	@echo "    make flash-usb USB=... Flash ISO to USB drive"
	@echo "    make clean             Remove build artifacts"
	@echo ""
	@echo "  Examples:"
	@echo "    make build-iso"
	@echo "    make flash-usb USB=/dev/sdb"
	@echo ""

# ── build-image ───────────────────────────────────────────────────────────────
build-image:
	@echo "==> Building Docker builder image '$(IMAGE_TAG)'..."
	@# Create a temporary build context that includes the app sources
	@TMPCTX=$$(mktemp -d) && \
	cp -r . "$$TMPCTX/bootable" && \
	mkdir -p "$$TMPCTX/bootable/app" && \
	for f in main.py disk_manager.py erase_engine.py pdf_generator.py system_info.py index.html; do \
	    [ -f "$(APP_DIR)/$$f" ] && cp "$(APP_DIR)/$$f" "$$TMPCTX/bootable/app/" && echo "  → $$f" || true; \
	done && \
	docker build \
	    -f "$$TMPCTX/bootable/Dockerfile.builder" \
	    -t "$(IMAGE_TAG)" \
	    "$$TMPCTX/bootable" && \
	rm -rf "$$TMPCTX"
	@echo "==> Image '$(IMAGE_TAG)' built."

# ── build-iso ────────────────────────────────────────────────────────────────
build-iso: build-image
	@echo "==> Building bootable ISO..."
	@mkdir -p "$(DIST_DIR)"
	docker run \
	    --rm \
	    --privileged \
	    -v "$(DIST_DIR)":/dist \
	    -e DIST_DIR=/dist \
	    "$(IMAGE_TAG)"
	@echo ""
	@echo "==> ISO ready: $(DIST_DIR)/$(ISO_NAME)"
	@ls -lh "$(DIST_DIR)/$(ISO_NAME)" 2>/dev/null || true

# ── flash-usb ─────────────────────────────────────────────────────────────────
flash-usb:
	@if [ -z "$(USB)" ]; then \
	    echo "ERROR: Especifica el dispositivo USB:  make flash-usb USB=/dev/sdX"; \
	    echo ""; \
	    echo "Dispositivos disponibles:"; \
	    lsblk -o NAME,SIZE,TYPE,TRAN,MOUNTPOINT 2>/dev/null || true; \
	    exit 1; \
	fi
	@if [ ! -f "$(DIST_DIR)/$(ISO_NAME)" ]; then \
	    echo "ERROR: $(DIST_DIR)/$(ISO_NAME) no existe. Ejecuta 'make build-iso' primero."; \
	    exit 1; \
	fi
	sudo bash scripts/flash-usb.sh "$(USB)"

# ── clean ─────────────────────────────────────────────────────────────────────
clean:
	@echo "==> Limpiando artefactos de build..."
	rm -f "$(DIST_DIR)/$(ISO_NAME)"
	docker rmi "$(IMAGE_TAG)" 2>/dev/null || true
	@echo "==> Listo."
