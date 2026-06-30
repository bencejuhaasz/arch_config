export WLR_DRM_DEVICES=/dev/dri/card1
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export WLR_NO_HARDWARE_CURSORS=1

sway --unsupported-gpu
