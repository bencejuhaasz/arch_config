#!/bin/bash
set -e
ukify build \
  --linux=/boot/vmlinuz-linux-surface \
  --initrd=/boot/initramfs-linux-surface.img \
  --cmdline=@/etc/kernel/cmdline_rescue \
  --output=/efi/EFI/Linux/arch-linux-rescue.efi

sbctl sign-all
