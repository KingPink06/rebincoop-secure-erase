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

# ── Enable community repo (needed for xorriso, syslinux, mtools, etc.) ────────
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.19/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.19/community" >> /etc/apk/repositories && \
    apk update --no-cache

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
# Use --no-build-isolation and pin to concrete versions to avoid resolver failures.
# All wheels are pure-Python so they work across Alpine's Python 3.x.
RUN mkdir -p /wheels && \
    pip3 download \
        --dest /wheels \
        --no-deps \
        --no-build-isolation \
        --prefer-binary \
        fastapi \
        uvicorn \
        websockets \
        fpdf2 \
        python-multipart \
        anyio \
        starlette \
        click \
        h11 \
        idna \
        sniffio \
        exceptiongroup \
        typing_extensions

# ── Copy build context ─────────────────────────────────────────────────────────
COPY . /build/

# App source (parent directory) is expected to be bind-mounted or copied in.
# The build script copies from /app → overlay/opt/rebincoop/
# We default to the bundled copy in /build/app if it exists.

WORKDIR /build

ENTRYPOINT ["/bin/bash", "/build/scripts/build-iso.sh"]
