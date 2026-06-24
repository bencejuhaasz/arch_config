#!/usr/bin/env bash

PID=$(pgrep -x wvkbd-deskintl)

if [ -z "$PID" ]; then
    # Start hidden-capable keyboard
    wvkbd-deskintl \
        --hidden \
        -H 280 \
        --fn "DejaVu Sans 20" &
else
    # Toggle visibility using SIGUSR2
    pkill -USR2 wvkbd-deskintl
fi
