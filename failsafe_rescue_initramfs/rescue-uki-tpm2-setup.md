# Failsafe Rescue UKI with sbctl Secure Boot + Signed TPM2 PCR11 Policy

**Do this in order. Do not remove your existing working boot/unlock method until Phase 5 (testing) passes.** Every phase includes a rollback note — if it's not written, don't skip ahead.

---

## Phase -1 — Move the swapfile out of `@` (prerequisite)

**Do this before everything else.** A swapfile cannot tolerate living inside a subvolume that ever gets snapshotted — this is a documented btrfs limitation, not something introduced by the rescue design. Every `btrfs subvolume snapshot` the rescue hook performs shares extents with the source, including the swapfile's, and btrfs correctly refuses true NOCOW swap once extents are shared. Symptom: `BTRFS warning (device dm-0): swapfile must not be copy-on-write` in dmesg, repeated warnings before (sometimes) eventually succeeding.

This is worse in this design specifically because manual pruning is permanent here — `@prev-*` and old snapshots are never auto-deleted, so whatever a snapshot's source was never goes away, and the cross-reference never clears on its own. Left alone, this recurs on every future rescue action indefinitely.

### -1.1 Deactivate current swap

```bash
sudo swapoff /swap/swapfile
```

### -1.2 Create a dedicated, never-snapshotted sibling subvolume

```bash
mkdir -p /rescue-mnt-tmp
sudo mount -t btrfs -o subvolid=5 /dev/mapper/root /rescue-mnt-tmp
sudo btrfs subvolume create /rescue-mnt-tmp/@swap
sudo umount /rescue-mnt-tmp
```

### -1.3 Mount it and recreate the swapfile fresh

Retroactively `chattr +C`-ing the old swapfile does not undo extents that are already shared — recreate it clean instead.
```bash
sudo mkdir -p /swap
echo 'UUID=<your-root-uuid>  /swap  btrfs  rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=/@swap  0 0' | sudo tee -a /etc/fstab
sudo mount /swap
sudo rm -f /swap/swapfile   # if the old one got carried along accidentally — should not exist yet on a fresh subvolume
sudo btrfs filesystem mkswapfile --size 8G /swap/swapfile
```
Adjust `8G` to match your current swap size (`8388604k` ≈ 8G, per your log).

### -1.4 Recompute the hibernation resume offset

You're using hibernate/resume (`resume_offset=2904650` in your current cmdline) — moving the file changes its physical offset.
```bash
sudo btrfs inspect-internal map-swapfile -r /swap/swapfile
```
Put the new value into `/etc/kernel/cmdline`, replacing the old `resume_offset=...`.

### -1.5 Activate and verify

```bash
sudo swapon /swap/swapfile
sudo dmesg | grep -i swap   # should show no "must not be copy-on-write" warning now
```

### -1.6 Rebuild and re-sign — cmdline changed

The resume offset is embedded in the UKI's cmdline, which is PCR11-signed — this isn't optional cleanup.
```bash
sudo /usr/local/bin/rebuild-normal-uki.sh
```
(If Phase 6 isn't set up yet, use the manual `ukify build` commands from Phase 3 instead, once you reach that point.)

### -1.7 Known limitation — doesn't apply retroactively

Your existing snapshots (1, 189–194) still have the old fstab and in-`@` swapfile layout frozen inside them. Rolling back to any of those will still hit this bug — the fix only protects states created *after* you apply it. Take one fresh snapshot once this is done, so you have at least one clean candidate going forward.

**Rollback for this phase:** if anything here goes wrong, your original `/swap/swapfile` inside `@` still exists untouched until you explicitly delete it (step -1.3 only removes it if accidentally carried into the new subvolume) — you can `swapoff` the new one and `swapon` the old path again while you sort out the issue.

---

## Phase 0 — Safety net before touching anything

```bash
# Back up your LUKS header (covers header corruption, independent of everything below)
cryptsetup luksHeaderBackup /dev/sdXY --header-backup-file /root/luks-header-backup.img
# Copy this file off the machine (USB, other host). If you lose it and the header
# gets corrupted, no passphrase or recovery key will save you.

# Make sure you have a working recovery key BEFORE any TPM2 changes
systemd-cryptenroll /dev/sdXY   # lists current enrolled slots — confirm what's there
```

If you don't already have a recovery key slot:
```bash
systemd-cryptenroll --recovery-key /dev/sdXY
```
It will print a recovery key **once**. Write it down physically (paper), store offline. This is your ejector seat for every step that follows — if any TPM2 enrollment step below leaves the machine unbootable, this key gets you in.

---

## Phase 1 — Rescue hook (systemd-in-initramfs)

This uses a **systemd oneshot service inside the initramfs**, not a busybox/ash `run_hook()` — correct, since `sd-encrypt` already means your initramfs is systemd-based rather than pure busybox, so nothing here can assume busybox applets exist. This is also a real improvement over an ash hook: unit ordering (`After=`/`Before=`) is more precise than mkinitcpio's `HOOKS=()` array position, and the cmdline gate uses systemd's own `ConditionKernelCommandLine=` instead of a manual `grep /proc/cmdline`.

### 1.1 The mkinitcpio install hook

`/etc/initcpio/install/rescue`:
```bash
#!/bin/bash
build() {
    # Shell and core utils — nothing here can assume busybox is present
    add_binary /usr/bin/bash
    add_binary btrfs
    add_binary find
    add_binary sort
    add_binary cp
    add_binary mv
    add_binary sync
    add_binary reboot
    add_binary mount
    add_binary umount
    add_binary mkdir
    add_binary ls
    add_binary grep
    add_binary date
    add_binary sleep

    # Kernel modules for the FAT ESP
    add_module vfat
    add_module nls_cp437
    add_module nls_ascii

    # The actual rescue script that the service unit runs
    add_file /usr/lib/systemd/scripts/rescue-root-selector

    # Install the service unit explicitly — add_systemd_unit's file
    # search proved unreliable, so the path is given directly instead.
    add_file /etc/initcpio/systemd/rescue-selector.service /usr/lib/systemd/system/rescue-selector.service

    # Enable it so it runs automatically — there's no live systemctl
    # daemon-reload at initramfs-build time, so the WantedBy symlink
    # has to be created by hand.
    add_symlink "/usr/lib/systemd/system/initrd.target.wants/rescue-selector.service" "/usr/lib/systemd/system/rescue-selector.service"
}

help() {
    cat <<HELPEOF
This hook drops into an interactive root-state selector when the kernel
cmdline contains rd.rescue_selector. Designed for systemd-based initramfs.
HELPEOF
}
```

### 1.2 The service unit

`/etc/initcpio/systemd/rescue-selector.service`:
```ini
[Unit]
Description=Btrfs root state selector
DefaultDependencies=no
# Must run AFTER the LUKS device appears but BEFORE systemd mounts it
# as sysroot. Ordering against the mount unit directly (not just the
# target) prevents the parallel-start race.
After=dev-mapper-root.device
Before=sysroot.mount

# Only activate when rd.rescue_selector is on the kernel cmdline
ConditionKernelCommandLine=rd.rescue_selector

[Service]
Type=oneshot
RemainAfterExit=yes
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/console
ExecStart=/usr/lib/systemd/scripts/rescue-root-selector
```
`StandardInput=tty` / `TTYPath=/dev/console` matter more than they look — without them, the script's interactive `read choice` has nothing to read from, since a bare service unit has no console wired up by default.

### 1.3 The actual selector script

`/usr/lib/systemd/scripts/rescue-root-selector`:
```bash
#!/bin/bash
# Rescue root-state selector — systemd initramfs edition.
# Invoked by rescue-selector.service; ConditionKernelCommandLine already
# confirmed rd.rescue_selector, so no manual cmdline check is needed here.

echo "=== RESCUE MODE: root state selector ==="
mkdir -p /rescue-mnt

if ! mount -t btrfs -o subvolid=5 /dev/mapper/root /rescue-mnt; then
    echo "Could not mount root btrfs volume. Continuing normal boot."
    exit 0
fi
sync
clear   # start from a blank screen — anything printed before this point is now gone

echo ""
echo "A snapshot is not a guaranteed-good state, just a guess."
echo "Nothing you pick here is destroyed — every prior root state"
echo "stays available to come back to."
echo ""
echo "-- Snapshots (@snapshots/<ID>/snapshot) --"
btrfs subvolume list -s /rescue-mnt | grep '@snapshots/'
echo ""
echo "-- Previous root states --"
ls -1 /rescue-mnt | grep '^@prev-' | sort
echo ""
echo "Enter one of:"
echo "  a snapshot ID (e.g. 194)          -> try that snapshot as new root"
echo "  a full @prev-<timestamp> name     -> go back to that earlier state"
echo "  blank                             -> skip, boot current @ as-is"

# Brief pause + redraw of just the decision line — belt-and-suspenders
# in case anything (a mount warning, a udev message loglevel=3 still
# lets through) slipped in above despite the cmdline quieting. This is
# the one line that has to be unambiguous no matter what else happened.
sleep 1
echo ""
echo ">>> snapshot ID, @prev-<timestamp>, or blank to skip <<<"
printf "> "
read choice

if [ -z "$choice" ]; then
    echo "No change. Continuing normal boot in 3s..."
    umount /rescue-mnt
    sleep 3
    exit 0
fi

if echo "$choice" | grep -q '^@prev-'; then
    target="/rescue-mnt/$choice"
else
    target="/rescue-mnt/@snapshots/${choice}/snapshot"
fi

if [ ! -d "$target" ]; then
    echo "Not found: $choice. No change made."
    umount /rescue-mnt
    sleep 3
    exit 0
fi

ts=$(date +%s)
echo "Setting current @ aside as @prev-$ts (not deleted — still selectable next time)"
mv /rescue-mnt/@ "/rescue-mnt/@prev-$ts"

btrfs subvolume snapshot "$target" /rescue-mnt/@

# Restore matching UKI from the chosen state's archive
archive_dir="/rescue-mnt/@/var/lib/uki-archive"
uki_to_restore=$(find "$archive_dir" -name '*.efi' 2>/dev/null | sort | tail -n1)

if [ -n "$uki_to_restore" ]; then
    mkdir -p /rescue-esp
    # UPDATE THIS to your actual ESP partition (check your fstab)
    if mount -t vfat /dev/nvme0n1p1 /rescue-esp; then
        echo "Restoring matching UKI: $uki_to_restore"
        cp "$uki_to_restore" /rescue-esp/EFI/Linux/arch-linux.efi.new
        sync
        mv /rescue-esp/EFI/Linux/arch-linux.efi.new /rescue-esp/EFI/Linux/arch-linux.efi
        sync
        umount /rescue-esp
    else
        echo "WARNING: could not mount ESP — UKI NOT restored."
        echo "The root state was still switched; the kernel/initramfs"
        echo "on /efi may not match it. Check manually before rebooting."
    fi
else
    echo "WARNING: no archived UKI found inside this state — likely"
    echo "predates the archiving setup. /efi is left untouched; you"
    echo "may be pairing an old root with a newer kernel."
fi

echo "New root: $choice"
echo "Reboot normally to try it. If it fails, come back here — your"
echo "previous state (@prev-$ts) and every earlier one will still be listed."
umount /rescue-mnt
sleep 2
reboot -f
```

**On the `clear` and redraw:** this addresses the reported problem of systemd/kernel messages non-deterministically interleaving with the prompt at exactly the moment you need to read it. The cmdline quieting (1.5) removes most of the noise at the source; `clear` plus the redrawn decision line right before `read` is the fallback for whatever gets through anyway — the goal is that the very last thing on screen is always the same unambiguous line, regardless of what happened above it.

**Why nothing is ever deleted here:** the whole premise is "a snapshot is a guess, not a guarantee" — so the script must never assume the state you just picked is good. It only finds out if you tell it, by coming back to rescue. Every `@prev-*` it creates is a full, real root filesystem, not a marker — so if attempt #1 (snapshot 190) fails to boot, you go back to rescue, see `@prev-<ts1>` (your original) and can either try a different snapshot or go straight back to `@prev-<ts1>`. If attempt #2 also fails, both remain listed — you're never worse off than before.

**Getting back to the literal original:** the first `@prev-*` timestamp ever created (chronologically earliest) is your pristine pre-rescue state, untouched by any rollback attempt. Never auto-removed, so always your ultimate fallback alongside the recovery-key/USB path.

**Disk space:** every attempt accumulates. Cleanup is manual and deliberate:
```bash
btrfs subvolume delete /@prev-<timestamp>
```
Do this only for attempts you're confident you'll never want back, from normal boot once things are stable — never automatically, and never from inside the rescue script itself.

**Note on scope:** this only manipulates `@` (root). `@home` and `@snapshots` are untouched.

**Note on snapper bookkeeping:** this bypasses snapper's own metadata via raw `btrfs` calls — `snapper list` will still show its own history unchanged after a rollback, cosmetic only.

```bash
chmod +x /etc/initcpio/install/rescue
chmod +x /usr/lib/systemd/scripts/rescue-root-selector
```

### 1.4 Add to mkinitcpio.conf

Edit `/etc/mkinitcpio.conf`, add `rescue` to `HOOKS=()` — since ordering is now handled by the unit's own `After=`/`Before=` directives rather than array position, it just needs to be present alongside `systemd` and `sd-encrypt`:
```
# Example — yours may differ, keep everything else as-is
HOOKS=(base systemd autodetect modconf kms keyboard sd-encrypt rescue block filesystems fsck)
```

### 1.5 Separate cmdlines

`/etc/kernel/cmdline` (your existing normal one — leave as-is), and new file `/etc/kernel/cmdline_rescue`:
```bash
cp /etc/kernel/cmdline /etc/kernel/cmdline_rescue
echo -n " rd.rescue_selector quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3" >> /etc/kernel/cmdline_rescue
```
The extra params beyond `rd.rescue_selector` matter for a real reason: without them, other initrd units' own status output (and udev device-event chatter, likely from LUKS/btrfs device probing) share the same console as your interactive prompt with nothing serializing the two — which is exactly the non-deterministic interleaving you'd hit at the worst possible moment. `systemd.show_status=auto` suppresses routine successful-unit messages while still surfacing genuine failures (rather than `=false`, which would hide those too) — this is the Arch wiki's own documented combination for a quiet systemd-in-initramfs boot, applied only to the rescue path so your normal boot's verbosity is untouched.

Verify it's one line, no trailing newline weirdness:
```bash
cat /etc/kernel/cmdline_rescue
```

**Rollback for this phase:** if the service misbehaves, remove `rescue` from `HOOKS=()` and rebuild the normal initramfs. Nothing here touches disk encryption or boot signing yet.

---

## Phase 2 — sbctl setup (if not already done)

Skip 2.1–2.2 if `sbctl status` already shows Secure Boot enabled with your own keys.

### 2.1 Create and enroll your own keys

```bash
sbctl status
sbctl create-keys
sbctl enroll-keys -m   # -m keeps Microsoft certs enrolled — needed for some firmware update paths
```
Reboot into UEFI setup, confirm Secure Boot is set to **enabled** (not just "setup mode").

### 2.2 Verify

```bash
sbctl status
# Should show: Setup Mode: disabled, Secure Boot: enabled
```

**Rollback:** `sbctl` keeps your original keys backed up under `/usr/share/secureboot/`; you can re-enter setup mode from firmware if needed to restore vendor keys.

---

## Phase 3 — Build both UKIs with signed PCR11 policy + sbctl signing

This is the part that combines everything: `ukify` builds and signs the PCR11 prediction (TPM policy), then `sbctl` signs the resulting binary (Secure Boot). Two different signatures, two different purposes, both needed.

### 3.1 Generate the PCR-signing keypair (once, separate from your sbctl keys)

```bash
mkdir -p /etc/tpm2-pcr-signing
openssl genrsa -out /etc/tpm2-pcr-signing/private.pem 2048
openssl rsa -in /etc/tpm2-pcr-signing/private.pem -pubout -out /etc/tpm2-pcr-signing/public.pem
chmod 600 /etc/tpm2-pcr-signing/private.pem
```
This key proves "this PCR11 value came from a UKI I built," it does not itself decrypt anything. Losing it only means future kernel builds need re-enrollment — it's not a secondary LUKS secret, so root-readable storage is acceptable.

### 3.2 Build the **normal** UKI, signed for PCR11

```bash
ukify build \
  --linux=/boot/vmlinuz-linux \
  --initrd=/boot/initramfs-linux.img \
  --cmdline=@/etc/kernel/cmdline \
  --pcr-private-key=/etc/tpm2-pcr-signing/private.pem \
  --pcr-public-key=/etc/tpm2-pcr-signing/public.pem \
  --pcr-banks=sha256 \
  --output=/efi/EFI/Linux/arch-linux.efi
```

### 3.3 Build the **rescue** UKI — deliberately unsigned for PCR

```bash
ukify build \
  --linux=/boot/vmlinuz-linux \
  --initrd=/boot/initramfs-linux.img \
  --cmdline=@/etc/kernel/cmdline_rescue \
  --output=/efi/EFI/Linux/arch-linux-rescue.efi
```
No `--pcr-private-key` here — its PCR11 will never validate against your enrolled public key. That's the whole point.

### 3.4 Sign both with sbctl (Secure Boot)

```bash
sbctl sign -s /efi/EFI/Linux/arch-linux.efi
sbctl sign -s /efi/EFI/Linux/arch-linux-rescue.efi
```
`-s` saves them to sbctl's tracking list so future `sbctl sign-all` (e.g. after a pacman hook) re-signs both automatically.

### 3.5 Verify signatures

```bash
sbctl verify
```
Should list both files as signed.

**Rollback for this phase:** the old single UKI (if it exists) is untouched unless you overwrote its filename — keep a copy (`cp /efi/EFI/Linux/arch-linux.efi /efi/EFI/Linux/arch-linux.efi.bak`) until Phase 5 passes.

---

## Phase 4 — TPM2 enrollment

**Do not wipe your existing TPM2 slot until you've confirmed the new one works.** Enroll a *new* slot first, test it, only then remove the old one.

### 4.1 Enroll against the signed public key + PCR7

```bash
systemd-cryptenroll \
  --tpm2-device=auto \
  --tpm2-public-key=/etc/tpm2-pcr-signing/public.pem \
  --tpm2-public-key-pcrs=11 \
  --tpm2-pcrs=7 \
  /dev/sdXY
```
This adds a **new** slot without touching your existing one yet.

### 4.2 List slots, confirm the new one exists

```bash
systemd-cryptenroll /dev/sdXY
```
You should now see: your recovery-key slot, your **old** tpm2 slot, and the **new** tpm2 slot.

### 4.3 Reboot and test normal boot

Boot the normal (`arch-linux.efi`) entry. It should auto-unlock with no prompt, same as before — now via the new slot's policy.

If it fails and falls to a passphrase/recovery prompt: **do not panic, do not wipe anything.** Use your recovery key from Phase 0 to get in, then check `journalctl -b` for `systemd-cryptsetup` or TPM-related errors before retrying.

### 4.4 Only after 4.3 succeeds — remove the old raw-PCR tpm2 slot

```bash
systemd-cryptenroll --wipe-slot=tpm2 /dev/sdXY
```
Careful: `--wipe-slot=tpm2` removes **all** tpm2 slots. If step 4.1's new slot and the old slot are both type `tpm2`, this could remove both. Check slot types first:
```bash
cryptsetup luksDump /dev/sdXY | grep -A2 tpm2
```
If needed, wipe by specific slot number instead:
```bash
systemd-cryptenroll --wipe-slot=<old-slot-number> /dev/sdXY
```

**Rollback for this phase:** your recovery key (Phase 0) always works regardless of what happens to TPM2 slots — that's exactly what it's for.

---

## Phase 5 — Full test before trusting this daily

This isn't "does it boot once" — it needs to exercise the retry logic, both archive outcomes, and the non-destruction guarantee, since those are the actual point of the design.

### 5.0 Seed the archive for your current state

Your existing snapshots (1, 189–194) all predate Phase 6 — none of them have an archive entry, by construction. Right now, "go back to however things currently are" has nothing to restore either, since that only gets populated going forward. Fix this once, right after Phase 6 is in place:
```bash
sudo /usr/local/bin/rebuild-normal-uki.sh
```

### 5.1 Baseline

Reboot normally → confirm silent auto-unlock. Repeat once.

### 5.2 Rescue boot refuses TPM auto-unlock

Boot the rescue entry → confirm the TPM does **not** unlock silently, and you're prompted for a passphrase/recovery key.

### 5.3 Recovery key unlocks, candidate selector appears

Enter the recovery key → confirm the root-state selector lists your snapshots. No `@prev-*` entries yet — nothing's happened.

### 5.4 Trigger the "missing archive" warning — safely

Pick **snapshot 194** (your newest, from Aug 1) — not 1 or 189. All your existing snapshots equally predate archiving, so any of them would trigger the warning, but 194 is only ~1 day of package drift from current; 1 is 4+ months on a rolling release, which risks a genuinely broken boot for reasons that have nothing to do with what you're testing. Confirm you see `WARNING: no archived UKI found...`, confirm the root swap still completed, then reboot.

### 5.5 Return via `@prev-*`, confirm the retry/chaining logic

Reboot into rescue again → confirm the list now shows **both** the original snapshots **and** a new `@prev-<ts>` (your pre-5.4 state). Select that `@prev-<ts>` → confirm it restores correctly and boots normally. This is the part that matters most: a candidate created *by a previous rescue action* has to be just as selectable as an original snapshot.

### 5.6 Trigger the "found archive" happy path

Take one fresh snapshot now (`sudo snapper -c root create`, or wait for the next scheduled one) so it includes the entry seeded in 5.0. Reboot into rescue, select that new snapshot, confirm the message reads `Restoring matching UKI: ...` (not the warning), confirm `uname -r` after reboot matches what was archived.

### 5.7 Confirm nothing was ever destroyed

From normal boot:
```bash
sudo btrfs subvolume list -s /
ls /var/lib/uki-archive
```
Confirm every `@prev-*` from 5.4–5.6 and every archived UKI are still present. This is the actual safety property under test — not "did it boot," but "did anything get thrown away that shouldn't have been."

### 5.8 Suspend/resume

Confirm auto-unlock still works after waking from sleep, not just on cold boot (Surface Pro 7 fTPM has had S3 quirks historically).

Only after all of 5.1–5.8 pass should you consider the old raw-PCR fallback (Phase 4.4) safe to have removed.

---

## Phase 6 — Automate the normal UKI only; rescue stays manual on purpose

Two separate scripts, not one. The **normal** UKI needs to track every kernel update, so it's automated. The **rescue** UKI must never be touched by anything automatic — if a bad `ukify` version, a script bug, or some other automated failure ever corrupts a build, it should only be able to take down the thing that's already got the passphrase-protected TPM policy and Secure Boot as backstops, not the one thing designed to have no shared failure mode with normal boot. A rescue image that quietly regenerates itself on every kernel bump is a rescue image that can break at exactly the same moment normal boot does.

### 6.1 Normal UKI — automated

`/usr/local/bin/rebuild-normal-uki.sh`:
```bash
#!/bin/bash
set -e

kver=$(uname -r 2>/dev/null || cat /usr/lib/modules/*/pkgbase 2>/dev/null | tail -n1)
ts=$(date +%s)

ukify build \
  --linux=/boot/vmlinuz-linux \
  --initrd=/boot/initramfs-linux.img \
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
```
```bash
chmod +x /usr/local/bin/rebuild-normal-uki.sh
```

`/etc/pacman.d/hooks/95-rebuild-normal-uki.hook`:
```ini
[Trigger]
Operation = Upgrade
Operation = Install
Type = Package
Target = linux

[Action]
Description = Rebuild and sign the normal UKI after kernel update
When = PostTransaction
Exec = /usr/local/bin/rebuild-normal-uki.sh
```

No re-enrollment needed on future kernel updates — the signing key stays constant, only the PCR11 measurement (which the signature covers) changes per build.

**Why this avoids the earlier snap-pac/race discussion entirely:** because the archive lives inside `@`, it's captured by whatever snapshot mechanism you use — periodic timeline, manual, anything — with no coordination required. A snapshot taken mid-build could in principle catch the archive directory between "file copied in" and "deployed to ESP," but that window is a single `cp`, not a whole pacman transaction — much narrower than the risk discussed earlier, and if it does happen, rescue's "no archived UKI found, /efi left untouched" fallback (Phase 1) tells you plainly rather than silently pairing the wrong thing.

**Archive growth:** each entry is one UKI (tens of MB), much smaller than a full root snapshot, but it still grows unbounded on its own. Prune old entries manually from normal boot once you're confident you won't roll back that far:
```bash
rm /var/lib/uki-archive/arch-linux-<kver>-<timestamp>.efi
```
Automated pruning is deliberately not provided — manual review of what's safe to delete is the intended, permanent behavior here, same reasoning as `@prev-*` cleanup in Phase 1: neither one should ever silently decide something is safe to remove.

### 6.2 Rescue UKI — deliberately manual, never hooked into anything

`/usr/local/bin/rebuild-rescue-uki.sh`:
```bash
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
  --linux=/boot/vmlinuz-linux \
  --initrd=/boot/initramfs-linux.img \
  --cmdline=@/etc/kernel/cmdline_rescue \
  --output=/efi/EFI/Linux/arch-linux-rescue.efi

sbctl sign -s /efi/EFI/Linux/arch-linux-rescue.efi

echo "Done. Verify before trusting it:"
echo "  sbctl verify"
```
```bash
chmod +x /usr/local/bin/rebuild-rescue-uki.sh
```

**No pacman hook exists for this script, and none should.** Run it by hand:
- Right after initial setup (Phase 3), to have a real rescue image in place.
- Whenever you deliberately change `/etc/kernel/cmdline_rescue` — for instance, the quieting parameters added earlier for the console-noise fix require a manual rebuild to actually take effect; nothing does this for you.
- Periodically, as a conscious decision, if you want the rescue kernel to track newer kernel versions rather than drift indefinitely behind — but only when you choose to, ideally followed by re-running Phase 5's test checklist before trusting the new build.

Rescue's PCR11 is deliberately never signed (see Phase 3.3) — that's what makes it distinguishable from normal boot to the TPM. Nothing about splitting the scripts changes that; `sbctl sign` here only covers the Secure Boot signature, same as always.

---

## Phase 7 — PCR-signing key rotation

Do this if you suspect the private key was exposed (e.g., something got root on a running system), or as periodic hygiene. Same principle as everywhere else in this doc: never remove a working enrollment before a new one is confirmed.

### 7.1 Set the old keypair aside (don't delete yet)

```bash
mv /etc/tpm2-pcr-signing/private.pem /etc/tpm2-pcr-signing/private.pem.rotated-$(date +%Y%m%d)
mv /etc/tpm2-pcr-signing/public.pem /etc/tpm2-pcr-signing/public.pem.rotated-$(date +%Y%m%d)
```

### 7.2 Generate the new keypair at the same canonical path

Same path as before, so `rebuild-normal-uki.sh` needs no changes — only the content rotates.
```bash
openssl genrsa -out /etc/tpm2-pcr-signing/private.pem 2048
openssl rsa -in /etc/tpm2-pcr-signing/private.pem -pubout -out /etc/tpm2-pcr-signing/public.pem
chmod 600 /etc/tpm2-pcr-signing/private.pem
```

### 7.3 Rebuild and re-sign the normal UKI under the new key

```bash
sudo /usr/local/bin/rebuild-normal-uki.sh
```

### 7.4 Enroll a new TPM2 slot against the new public key — alongside the old one

Same safe pattern as Phase 4: add, don't replace yet.
```bash
systemd-cryptenroll \
  --tpm2-device=auto \
  --tpm2-public-key=/etc/tpm2-pcr-signing/public.pem \
  --tpm2-public-key-pcrs=11 \
  --tpm2-pcrs=7 \
  /dev/sdXY
```

### 7.5 Reboot, confirm normal boot still auto-unlocks silently

Now via the new-key slot. If it fails, your old slot and recovery key are both still intact — nothing was removed yet.

### 7.6 Optional grace period, then remove the old-key slot

Keeping the old-key slot around for a while means pre-rotation snapshots (and their old-key-signed archived UKIs) still auto-unlock if you ever roll back to one. When you're ready to close that off, remove it by specific slot number — never a blanket `--wipe-slot=tpm2`, which would take the new slot with it:
```bash
cryptsetup luksDump /dev/sdXY | grep -A2 tpm2
systemd-cryptenroll --wipe-slot=<old-slot-number> /dev/sdXY
```

### 7.7 What changes after the old slot is gone

Rolling back to a pre-rotation snapshot will no longer auto-unlock — its archived UKI is signed under a key the TPM policy no longer accepts, so it falls to your recovery key instead. That's expected, not a bug; worth remembering mid-emergency rather than being confused by it.

### 7.8 On the old key file itself

The security guarantee comes from step 7.6 (revoking the old key's TPM2 enrollment), not from how thoroughly the old private key file is erased. Once that enrollment is gone, anyone holding the old private key can no longer produce anything that unseals your volume — so there's no need to `shred` the `.rotated-*` backup, and it wouldn't reliably help anyway: btrfs is copy-on-write, so overwriting a file's blocks in place doesn't guarantee the old data isn't still sitting elsewhere on disk until reclaimed. A plain `rm` once you're done referencing it is enough.

---

## Summary of what protects what

| Layer | Protects against |
|---|---|
| Secure Boot + sbctl keys | Attacker replacing/tampering with either UKI at the boot-chain level |
| PCR7 in TPM policy | Attacker disabling Secure Boot or altering enrolled keys |
| Signed PCR11 policy | Distinguishes normal UKI (auto-unlocks) from rescue UKI (does not) — without needing re-enrollment per kernel update |
| Key rotation (Phase 7) | Limits exposure if the PCR-signing private key is ever compromised |
| Recovery key (offline, physical) | Universal fallback: TPM failure, rescue boot, forgotten passphrase, this whole procedure going wrong |
| LUKS header backup (offline) | Header corruption — independent of all of the above |

An attacker who steals the device and boots normally gets in silently (accepted risk of passwordless TPM2 — reconsider if your threat model is more than opportunistic theft). But they cannot trigger a rollback: the rescue path always demands the recovery key, which never touches the machine.
