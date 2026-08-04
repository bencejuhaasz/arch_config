#!/bin/bash
set -e

kver=$(uname -r 2>/dev/null || cat /usr/lib/modules/*/pkgbase 2>/dev/null | tail -n1)
ts=$(date +%s)

ukify build \
  --linux=/boot/vmlinuz-linux-surface \
  --initrd=/boot/initramfs-linux-surface.img \
  --cmdline=@/etc/kernel/cmdline \
  --pcr-private-key=/etc/tpm2-pcr-signing/private.pem \
  --pcr-public-key=/etc/tpm2-pcr-signing/public.pem \
  --pcr-banks=sha256 \
  --output=/efi/EFI/Linux/arch-linux.efi

sbctl sign -s /efi/EFI/Linux/arch-linux.efi

# Archive a copy of the (already-signed) normal UKI INSIDE @, so that any
# future btrfs snapshot of @ automatically captures the exact UKI that was
# live at that moment — no separate tagging or snapshot-ID coordination
# needed. Rescue just finds the newest file in this directory, inside
# whichever root state you pick, and restores it. See Phase 1's rescue hook.
#
# This depends on /var staying inside @ rather than becoming its own
# subvolume — a common tweak elsewhere for keeping logs/cache out of
# snapshots. Reviewed and accepted: /var stays in @ on this system. If
# that ever changes, this path must move with it, or archiving silently
# stops working (rescue would just report "no archived UKI found").
mkdir -p /var/lib/uki-archive
cp /efi/EFI/Linux/arch-linux.efi "/var/lib/uki-archive/arch-linux-${kver}-${ts}.efi"
