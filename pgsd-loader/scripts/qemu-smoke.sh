#!/bin/sh
# qemu-smoke.sh: L0 emulation smoke run (parent ADR 0001 Decision 7:
# emulation for iteration; the bench remains sole authority).
#
# Builds a scratch ESP directory with pgsd-loader as the default
# boot application and the chainload-target stand-in at the stock
# loader path, boots it under qemu/OVMF headless, and checks the
# serial log for the banner and the chainload marker. Also runs the
# failure path: with the target removed, pgsd-loader must report and
# fall through.
#
# OVMF firmware paths are host-specific; override via environment.
# FreeBSD (port edk2): OVMF_CODE=/usr/local/share/edk2-qemu/QEMU_UEFI_CODE-x86_64.fd
# Usage: sh qemu-smoke.sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
QEMU="${QEMU:-qemu-system-x86_64}"
ESP="/tmp/pgsd-l0-smoke-esp.$$"
LOG="/tmp/pgsd-l0-smoke.log"

[ -f "$OVMF_CODE" ] || { echo "qemu-smoke: OVMF_CODE not found: $OVMF_CODE" >&2; exit 1; }

( cd "$PROJ_DIR" && zig build && zig build test-target )

run() {
    cp "$OVMF_VARS" "$ESP.vars"
    timeout 60 "$QEMU" -machine q35 -m 256 -nographic \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$ESP.vars" \
        -drive format=raw,file=fat:rw:"$ESP" \
        -net none 2>/dev/null | tr -d '\r' > "$LOG" || true
}

cleanup() { rm -rf "$ESP" "$ESP.vars"; }
trap cleanup EXIT INT TERM

fails=0
check() {
    if grep -qa "$2" "$LOG"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi
}

# Pass 1: chainload succeeds.
mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/freebsd"
cp "$PROJ_DIR/zig-out/bin/pgsd-loader.efi" "$ESP/EFI/BOOT/BOOTX64.EFI"
cp "$PROJ_DIR/zig-out/bin/chainload-target.efi" "$ESP/EFI/freebsd/loader.efi"
run
check "banner printed"            "pgsd-loader .* (L0"
check "chainload target reached"  "CHAINLOAD TARGET REACHED"

# Pass 2: target absent, must report and fall through.
rm "$ESP/EFI/freebsd/loader.efi"
run
check "failure reported"          "LoadImage failed"
check "fall-through announced"    "falling through to firmware boot order"

[ "$fails" -eq 0 ] && echo "qemu-smoke: all checks passed" || { echo "qemu-smoke: $fails check(s) FAILED"; exit 1; }
