#!/bin/sh
# Kiosk environment variables — sourced for all users at login

export XDG_RUNTIME_DIR=/tmp/runtime-kiosk
export DISPLAY=:0
export HOME=/home/kiosk

# Chromium flags (also read by /home/kiosk/.xinitrc)
export CHROMIUM_FLAGS="
  --no-sandbox
  --kiosk
  --disable-dev-shm-usage
  --disable-restore-session-state
  --disable-translate
  --no-first-run
  --disable-infobars
  --disable-features=TranslateUI
  --disable-session-crashed-bubble
  --disable-component-update
  --autoplay-policy=no-user-gesture-required
  --disk-cache-dir=/tmp/chromium-cache
  --user-data-dir=/tmp/chromium-data
"
