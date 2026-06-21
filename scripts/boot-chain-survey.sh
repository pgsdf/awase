#!/bin/sh
# boot-chain-survey.sh  (AD-56 Phase 0, criterion 2: boot-chain document)
#
# Read-only survey of the bench's current UEFI boot chain. Touches
# nothing; every command here only reads. Produces a timestamped report
# that becomes the boot-chain document, and the factual basis for the
# fallback-entry and ABI-bridge work.
#
# Run on the bench:  sudo sh boot-chain-survey.sh
# Output: /var/tmp/awase-boot-survey/<timestamp>/ plus a printed summary.

set -u
TS="$(date +%Y%m%d-%H%M%S)"
OUT="/var/tmp/awase-boot-survey/${TS}"
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] && { echo "run as root: sudo sh $0" >&2; exit 2; }

cap() { echo "## $1"; shift; "$@" 2>&1; echo; }

# --- firmware boot entries (the heart of the fallback question) -------
{
  cap "efibootmgr -v (current UEFI boot entries and order)" efibootmgr -v
  cap "efivar list (raw EFI variables, if efibootmgr is thin)" sh -c 'efivar -l 2>/dev/null | head -40'
} > "$OUT/10-firmware-boot-entries.txt"

# --- ESP: what loader the firmware actually runs ----------------------
{
  cap "ESP mount + filesystem" sh -c 'mount | grep -iE "msdos|efi|/boot/efi" || echo "ESP not currently mounted; see gpart below"'
  cap "gpart show (partition scheme; find the efi partition)" gpart show
  # Try to locate and list the ESP contents.
  esp="$(mount | awk "/msdos|efi/ {print \$3; exit}")"
  if [ -z "$esp" ]; then
    cap "ESP not mounted; candidate efi partitions" sh -c 'gpart show | grep -i efi'
  else
    cap "ESP tree at $esp" find "$esp" -maxdepth 3 -type f
    cap "EFI/BOOT and EFI/freebsd contents" sh -c "ls -la $esp/EFI/BOOT $esp/EFI/freebsd 2>/dev/null"
  fi
} > "$OUT/20-esp-contents.txt"

# --- /boot layout: Lua vs Forth menu, loader binaries, config ---------
{
  cap "/boot loader binaries (which loader.efi variants exist)" sh -c 'ls -la /boot/*.efi /boot/loader* 2>/dev/null'
  cap "menu engine: Lua present?" sh -c 'ls -la /boot/lua/ 2>/dev/null && echo "=> Lua menu" || echo "no /boot/lua"'
  cap "menu engine: Forth present? (legacy)" sh -c 'ls -la /boot/*.4th 2>/dev/null && echo "=> Forth menu present" || echo "no Forth .4th"'
  cap "loader.conf (local)" sh -c 'cat /boot/loader.conf 2>/dev/null'
  cap "loader.conf.local" sh -c 'cat /boot/loader.conf.local 2>/dev/null || echo "(none)"'
  cap "beastie / delay knobs in effect" sh -c 'grep -hE "beastie|autoboot_delay|loader_logo|boot_mute" /boot/loader.conf /boot/defaults/loader.conf 2>/dev/null'
} > "$OUT/30-boot-layout.txt"

# --- kernel + boot environment (what the loader hands off today) ------
{
  cap "uname (kernel ident)" uname -a
  cap "kernel config in use" sh -c 'sysctl -n kern.conftxt 2>/dev/null | head -5; echo "..."'
  cap "loaded modules at runtime (what got preloaded)" kldstat -v
  cap "boot environments (ZFS BE, the existing known-good rollback)" sh -c 'bectl list 2>/dev/null || echo "no bectl / not ZFS-boot"'
  cap "EFI framebuffer the loader passed (GOP handoff drawfs consumes)" sh -c 'sysctl hw.drawfs 2>/dev/null | grep -iE "efifb|geom|width|height|stride|bpp" || echo "hw.drawfs efifb sysctls not present"'
} > "$OUT/40-kernel-handoff.txt"

# --- summary ----------------------------------------------------------
echo "==== boot-chain survey -> $OUT ===="
echo
echo "-- firmware boot order (the fallback question) --"
grep -iE 'BootOrder|BootCurrent|Boot[0-9]' "$OUT/10-firmware-boot-entries.txt" | head -12
echo
echo "-- loader the firmware runs --"
grep -iE 'BOOT(X64|AA64)|freebsd|loader\.efi' "$OUT/20-esp-contents.txt" | head -6
echo
echo "-- menu engine --"
grep -E '=> (Lua|Forth)|no /boot/lua' "$OUT/30-boot-layout.txt"
echo
echo "-- known-good rollback available? --"
grep -iE 'BE_|no bectl|bootonce|nextboot' "$OUT/40-kernel-handoff.txt" | head -4 || true
echo
echo "report files:"; ls -1 "$OUT"
echo
echo "Next (Phase 0): use 10-firmware-boot-entries.txt to plan the"
echo "permanent fallback boot entry (criterion 1) and the tested,"
echo "no-external-media recovery path (criteria 4 and 5)."
