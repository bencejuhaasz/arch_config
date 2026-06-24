#!/bin/bash

DIR="$HOME/Pictures/Screenshots"
FILE="$DIR/$(date +'%Y-%m-%d_%H-%M-%S').png"

# kijelölés + mentés + clipboard
grim -g "$(slurp)" "$FILE"
wl-copy < "$FILE"
