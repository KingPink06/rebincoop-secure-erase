#!/bin/sh
# /home/kiosk/.xinitrc
# Launched by startx as the kiosk user.
# Sets up a minimal X environment and starts Chromium in kiosk mode.

# ── X settings ─────────────────────────────────────────────────────────────────
xset s off          # Disable screen saver
xset -dpms          # Disable power management
xset s noblank      # Don't blank the screen
xset r rate 500 30  # Key repeat rate (doesn't matter for kiosk, but clean)

# ── Minimal window manager ──────────────────────────────────────────────────────
# openbox handles WM duties so Chromium can go fullscreen properly
openbox &

# ── Wait for the backend ───────────────────────────────────────────────────────
# (10-rebincoop.start already waited, but add a safety check here)
TRIES=0
until wget -qO /dev/null http://127.0.0.1:8420/ 2>/dev/null; do
    sleep 1
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -ge 20 ]; then
        break
    fi
done

# ── Chromium kiosk ─────────────────────────────────────────────────────────────
# Alpine 3.17+ installs as 'chromium-browser'; older as 'chromium'
CHROMIUM_BIN=""
for candidate in /usr/bin/chromium-browser /usr/bin/chromium chromium-browser chromium; do
    if command -v "$candidate" > /dev/null 2>&1; then
        CHROMIUM_BIN="$candidate"
        break
    fi
done
if [ -z "$CHROMIUM_BIN" ]; then
    echo "ERROR: No se encontró Chromium" | tee /tmp/chromium-error.txt
    sleep 30
    exit 1
fi

exec "$CHROMIUM_BIN" \
    --no-sandbox \
    --kiosk \
    --disable-dev-shm-usage \
    --disable-restore-session-state \
    --disable-translate \
    --no-first-run \
    --disable-infobars \
    --disable-features=TranslateUI \
    --disable-session-crashed-bubble \
    --disable-component-update \
    --autoplay-policy=no-user-gesture-required \
    --disable-background-networking \
    --disable-default-apps \
    --disable-extensions \
    --disable-sync \
    --disable-web-security \
    --allow-running-insecure-content \
    --disk-cache-dir=/tmp/chromium-cache \
    --user-data-dir=/tmp/chromium-data \
    --window-size=1920,1080 \
    --start-fullscreen \
    "http://localhost:8420"
