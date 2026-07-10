#!/bin/sh
# one-pass.sh: stage one smoke pass's ESP and run it in the
# FOREGROUND with full serial visible, for diagnosing a pass that
# fails under qemu-smoke.sh's captured (headless, redirected) run.
#
# qemu-smoke.sh runs every pass and greps a redirected log; when a
# pass fails there, this script reproduces exactly one pass with the
# serial on the terminal and teed to a log, so firmware boot
# selection and launcher behavior are observable. It shares the
# OVMF probe, build step, and ESP staging with qemu-smoke.sh so the
# environment is identical; only the run is foreground.
#
# Usage: sh scripts/one-pass.sh <pass> [logfile]
#   pass:    chainload | options | bas-valid | contract | real
#   logfile: defaults to /tmp/pgsd-onepass.log
#
#   chainload  pgsd-loader at BOOTX64.EFI, L0 chainload (smoke 1)
#   options    option-launcher starts nested loader (smoke 3)
#   bas-valid  bas-launcher, armed, valid slot, KOK kernel (smoke 4)
#   contract   bas-launcher, armed, contract kernel -> HOK (smoke 8)
#   real       bas-launcher, armed, PGSD_REAL_KERNEL -> FreeBSD banner
set -eu

[ "$(id -u)" -ne 0 ] || { echo "one-pass: do not run as root" >&2; exit 1; }

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

PASS="${1:-}"
LOG="${2:-/tmp/pgsd-onepass.log}"
[ -n "$PASS" ] || { echo "usage: sh scripts/one-pass.sh <chainload|options|bas-valid|contract|real> [logfile]" >&2; exit 2; }

probe() {
    for f in "$@"; do
        if [ -f "$f" ]; then echo "$f"; return 0; fi
    done
    return 1
}
OVMF_CODE="${OVMF_CODE:-$(probe \
    /usr/local/share/edk2-qemu/QEMU_UEFI_CODE-x86_64.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd || true)}"
OVMF_VARS="${OVMF_VARS:-$(probe \
    /usr/local/share/edk2-qemu/QEMU_UEFI_VARS-x86_64.fd \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd || true)}"
[ -n "$OVMF_CODE" ] || { echo "one-pass: no OVMF code image found; set OVMF_CODE" >&2; exit 1; }
[ -n "$OVMF_VARS" ] || { echo "one-pass: no OVMF vars image found; set OVMF_VARS" >&2; exit 1; }
QEMU="${QEMU:-qemu-system-x86_64}"
ESP="/tmp/pgsd-onepass-esp.$$"
B="$PROJ_DIR/zig-out/bin"

sh "$PROJ_DIR/build.sh"
sh "$PROJ_DIR/build.sh" test-target
sh "$PROJ_DIR/build.sh" tools

hashf() { sha256 -q "$1" 2>/dev/null || sha256sum "$1" | awk '{print $1}'; }

stage_bas() {
    # $1 = kernel builder invocation target (path); caller has
    # already produced the kernel file. Writes manifest + selector.
    {
        echo "PGSD-BAS-MANIFEST 1"
        echo "$(hashf "$ESP/EFI/pgsd/bas/slots/1/kernel") $(wc -c < "$ESP/EFI/pgsd/bas/slots/1/kernel" | tr -d ' ') kernel"
    } > "$ESP/EFI/pgsd/bas/slots/1/manifest"
    "$B/bas-selector" init "$ESP/EFI/pgsd/bas/selector" >/dev/null
    "$B/bas-selector" commit "$ESP/EFI/pgsd/bas/selector" 1 \
        "$(hashf "$ESP/EFI/pgsd/bas/slots/1/manifest")" >/dev/null
}

rm -rf "$ESP"
case "$PASS" in
    chainload)
        mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/freebsd"
        cp "$B/pgsd-loader.efi" "$ESP/EFI/BOOT/BOOTX64.EFI"
        cp "$B/chainload-target.efi" "$ESP/EFI/freebsd/loader.efi"
        ;;
    options)
        mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/pgsd" "$ESP/EFI/freebsd"
        cp "$B/option-launcher.efi" "$ESP/EFI/BOOT/BOOTX64.EFI"
        cp "$B/pgsd-loader.efi" "$ESP/EFI/pgsd/pgsd-loader.efi"
        cp "$B/chainload-target.efi" "$ESP/EFI/freebsd/loader.efi"
        ;;
    bas-valid|contract)
        mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/pgsd/bas/slots/1" "$ESP/EFI/freebsd"
        cp "$B/bas-launcher.efi" "$ESP/EFI/BOOT/BOOTX64.EFI"
        cp "$B/pgsd-loader.efi" "$ESP/EFI/pgsd/pgsd-loader-bas.efi"
        cp "$B/chainload-target.efi" "$ESP/EFI/freebsd/loader.efi"
        if [ "$PASS" = "contract" ]; then
            "$B/mk-fake-kernel" "$ESP/EFI/pgsd/bas/slots/1/kernel" contract
        else
            "$B/mk-fake-kernel" "$ESP/EFI/pgsd/bas/slots/1/kernel"
        fi
        stage_bas
        ;;
    real)
        [ -n "${PGSD_REAL_KERNEL:-}" ] || { echo "one-pass: set PGSD_REAL_KERNEL for the real pass" >&2; exit 2; }
        [ -f "$PGSD_REAL_KERNEL" ] || { echo "one-pass: PGSD_REAL_KERNEL not found: $PGSD_REAL_KERNEL" >&2; exit 2; }
        mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/pgsd/bas/slots/1" "$ESP/EFI/freebsd"
        cp "$B/bas-launcher.efi" "$ESP/EFI/BOOT/BOOTX64.EFI"
        cp "$B/pgsd-loader.efi" "$ESP/EFI/pgsd/pgsd-loader-bas.efi"
        cp "$B/chainload-target.efi" "$ESP/EFI/freebsd/loader.efi"
        cp "$PGSD_REAL_KERNEL" "$ESP/EFI/pgsd/bas/slots/1/kernel"
        stage_bas
        ;;
    *)
        echo "one-pass: unknown pass '$PASS'" >&2
        echo "  known: chainload options bas-valid contract real" >&2
        exit 2
        ;;
esac

cp "$OVMF_VARS" "$ESP.vars"
cleanup() { rm -rf "$ESP" "$ESP.vars"; }
trap cleanup EXIT INT TERM

echo "one-pass: $PASS  (OVMF_CODE=$OVMF_CODE)"
echo "one-pass: serial below, also teed to $LOG"
echo "------------------------------------------------------------"
# Foreground: serial on the terminal AND teed. No 2>/dev/null, so
# QEMU's own errors (firmware load, accel) are visible too.
timeout 60 "$QEMU" -machine q35 -m 256 -nographic -no-reboot -boot menu=off \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$ESP.vars" \
    -drive format=raw,file=fat:rw:"$ESP" \
    -net none 2>&1 | tee "$LOG" || true
echo "------------------------------------------------------------"
echo "one-pass: done; log at $LOG"
