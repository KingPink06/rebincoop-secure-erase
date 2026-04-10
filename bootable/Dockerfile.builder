# ══════════════════════════════════════════════════════════════════════════════
# REBINCOOP Secure Erase — ISO Builder
#
# Builds a bootable Alpine Linux ISO with the kiosk pre-configured.
#
# Usage (from the bootable/ directory):
#   docker build -f Dockerfile.builder -t rebincoop-builder .
#   docker run --rm --privileged -v $(pwd)/../dist:/dist rebincoop-builder
#
# Output: ../dist/rebincoop-secure-erase.iso
# ══════════════════════════════════════════════════════════════════════════════

FROM alpine:3.19

LABEL maintainer="REBINCOOP" \
      description="ISO builder for REBINCOOP Secure Erase kiosk"

# ── Build tools ────────────────────────────────────────────────────────────────
RUN apk add --no-cache \
        bash \
        wget \
        curl \
        xorriso \
        squashfs-tools \
        tar \
        gzip \
        python3 \
        py3-pip \
        apk-tools \
        coreutils \
        findutils \
        util-linux \
        grub \
        grub-bios \
        grub-efi \
        syslinux \
        mtools \
        dosfstools \
        ca-certificates \
        openssl \
        gnupg

# ── Pre-download pip wheels that will be bundled in the ISO ───────────────────
# (pure-Python wheels work across all Python 3.x)
RUN mkdir -p /wheels && \
    pip3 download --dest /wheels --no-deps \
        "fastapi>=0.110.0" \
        "uvicorn>=0.29.0" \
        "websockets>=12.0" \
        "fpdf2>=2.7.9" \
        "python-multipart>=0.0.9" \
        "anyio>=4.0" \
        "starlette>=0.36" \
        "click>=8.0" \
        "h11>=0.14" \
        "idna>=3.0" \
        "sniffio>=1.0" \
        "exceptiongroup" \
        "typing_extensions"

# ── Copy build context ─────────────────────────────────────────────────────────
COPY . /build/

# App source (parent directory) is expected to be bind-mounted or copied in.
# The build script copies from /app → overlay/opt/rebincoop/
# We default to the bundled copy in /build/app if it exists.

WORKDIR /build

ENTRYPOINT ["/bin/bash", "/build/scripts/build-iso.sh"]
