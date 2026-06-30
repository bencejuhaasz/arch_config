sudo xboxdrv \
  --evdev /dev/input/event18 \
  --evdev-absmap ABS_X=x1,ABS_Y=y1,ABS_Z=x2,ABS_RZ=y2,ABS_GAS=rt,ABS_BRAKE=lt,ABS_HAT0X=DPAD_X,ABS_HAT0Y=DPAD_Y \
  --evdev-keymap BTN_SOUTH=a,BTN_EAST=b,BTN_NORTH=x,BTN_WEST=y,BTN_TL=lb,BTN_TR=rb,BTN_SELECT=back,BTN_START=start,BTN_MODE=guide,BTN_THUMBR=TR,BTN_THUMBL=TL \
  --mimic-xpad \
  --axismap "-y2=y2,-y1=y1"
