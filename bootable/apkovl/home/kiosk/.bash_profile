#!/bin/sh
# /home/kiosk/.bash_profile
# Auto-start X11 when logging in on tty1 (inittab runs login -f kiosk → this file).
# On any other terminal (tty2, SSH), just give a normal shell.

export HOME=/home/kiosk
export USER=kiosk

# Only auto-start X on tty1 and if not already running
if [ "$(tty)" = "/dev/tty1" ] && [ -z "$DISPLAY" ]; then
    # Small delay to let 10-rebincoop.start finish starting uvicorn
    sleep 2
    exec startx /home/kiosk/.xinitrc -- :0 vt1 2>/dev/null
fi
