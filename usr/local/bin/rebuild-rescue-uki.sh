#!/bin/bash
set -e

echo "Rebuilding the RESCUE UKI."
echo "This is deliberately manual — run it yourself, on purpose, only when"
echo "you have a specific reason to (cmdline_rescue changed, or you've"
echo "decided it's time to move the rescue kernel forward). It is never"
echo "triggered by a pacman hook or any other automation, so a bad build"
echo "can't take down your one guaranteed-independent fallback at the same"
echo "moment something else breaks normal boot."
echo ""

ukify build \
  --linux=/boot/vmlinuz-linux-zen \
  --initrd=/boot/initramfs-linux-zen.img \
  --cmdline=@/etc/kernel/cmdline_rescue \
  --output=/efi/EFI/Linux/arch-linux-rescue.efi

sbctl sign -s /efi/EFI/Linux/arch-linux-rescue.efi

echo "Done. Verify before trusting it:"
echo "  sbctl verify"
