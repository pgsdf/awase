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
# OVMF firmware paths are probed from known locations, bench
# (FreeBSD edk2 port) first, then Linux packaging; override via
# environment (OVMF_CODE, OVMF_VARS) if the probe misses.
# Usage: sh qemu-smoke.sh
set -eu

# Builds and emulation never need root, and a root run poisons the
# zig caches and /tmp scratch for later user runs (field lesson,
# first bench day). deploy.sh is the only script here that earns
# sudo.
[ "$(id -u)" -ne 0 ] || { echo "qemu-smoke: do not run as root" >&2; exit 1; }

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

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
[ -n "$OVMF_CODE" ] || { echo "qemu-smoke: no OVMF code image found; set OVMF_CODE" >&2; exit 1; }
[ -n "$OVMF_VARS" ] || { echo "qemu-smoke: no OVMF vars image found; set OVMF_VARS" >&2; exit 1; }
QEMU="${QEMU:-qemu-system-x86_64}"
ESP="/tmp/pgsd-l0-smoke-esp.$$"
LOG="/tmp/pgsd-l0-smoke.$$.log"

[ -f "$OVMF_CODE" ] || { echo "qemu-smoke: OVMF_CODE not found: $OVMF_CODE" >&2; exit 1; }

# Build through build.sh so smoke binaries are the canonical
# byte-reproducible ones (SOURCE_DATE_EPOCH pinned there).
sh "$PROJ_DIR/build.sh"
sh "$PROJ_DIR/build.sh" test-target
sh "$PROJ_DIR/build.sh" tools

run() {
    cp "$OVMF_VARS" "$ESP.vars"
    timeout 60 "$QEMU" -machine q35 -m 256 -nographic \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$ESP.vars" \
        -drive format=raw,file=fat:rw:"$ESP" \
        -net none 2>/dev/null | tr -d '\r' > "$LOG" || true
}

cleanup() { rm -rf "$ESP" "$ESP.vars" "$LOG"; }
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

# Pass 3: load-option forwarding (ADR 0003 criterion 5). The
# launcher starts pgsd-loader with a known option string, standing
# in for a firmware entry carrying options (FreeBSD efibootmgr
# cannot set them); the chainload target echoes what arrived.
rm -rf "$ESP"
mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/pgsd" "$ESP/EFI/freebsd"
cp "$PROJ_DIR/zig-out/bin/option-launcher.efi" "$ESP/EFI/BOOT/BOOTX64.EFI"
cp "$PROJ_DIR/zig-out/bin/pgsd-loader.efi" "$ESP/EFI/pgsd/pgsd-loader.efi"
cp "$PROJ_DIR/zig-out/bin/chainload-target.efi" "$ESP/EFI/freebsd/loader.efi"
run
check "options reached loader"    "pgsd-loader .* (L0"
check "options forwarded intact"  "LOAD OPTIONS: pgsd-opt-test alpha beta"

hashf() { sha256 -q "$1" 2>/dev/null || sha256sum "$1" | awk '{print $1}'; }

# Pass 4: BAS verification mode, valid slot (L3a.2 increment 1).
# The launcher starts the loader under its ARMED name; the loader
# must verify the active slot through all three integrity layers,
# report, and still chainload (increment 1 is verify-only).
rm -rf "$ESP"
mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/pgsd/bas/slots/1" "$ESP/EFI/freebsd"
cp "$PROJ_DIR/zig-out/bin/bas-launcher.efi" "$ESP/EFI/BOOT/BOOTX64.EFI"
cp "$PROJ_DIR/zig-out/bin/pgsd-loader.efi" "$ESP/EFI/pgsd/pgsd-loader-bas.efi"
cp "$PROJ_DIR/zig-out/bin/chainload-target.efi" "$ESP/EFI/freebsd/loader.efi"
"$PROJ_DIR/zig-out/bin/mk-fake-kernel" "$ESP/EFI/pgsd/bas/slots/1/kernel"
{
    echo "PGSD-BAS-MANIFEST 1"
    echo "$(hashf "$ESP/EFI/pgsd/bas/slots/1/kernel") $(wc -c < "$ESP/EFI/pgsd/bas/slots/1/kernel" | tr -d ' ') kernel"
} > "$ESP/EFI/pgsd/bas/slots/1/manifest"
"$PROJ_DIR/zig-out/bin/bas-selector" init "$ESP/EFI/pgsd/bas/selector" >/dev/null
"$PROJ_DIR/zig-out/bin/bas-selector" commit "$ESP/EFI/pgsd/bas/selector" 1 \
    "$(hashf "$ESP/EFI/pgsd/bas/slots/1/manifest")" >/dev/null
run
check "BAS mode armed"            "BAS verification mode"
check "manifest identity"         "manifest identity verified"
check "artifact verified"         "artifact kernel verified"
check "elf segments loaded"       "ELF: segment paddr=0x200000"
check "elf image loaded"          "ELF: LOADED entry=0xffffffff80200000 base=0x200000 end=0x204100"
check "metadata chain built"      "META: modulep=0x"
check "handoff state prepared"    "HO: pml4=0x"
check "page tables coherent"      "pt_ok=true"
check "slot verified"             "active slot VERIFIED"
check "still chainloads"          "CHAINLOAD TARGET REACHED"

# Pass 5: BAS refusal, corrupted artifact. The slot must be
# refused with the failure named, and the boot must still reach
# the chainload target (fail-visible, boot-safe).
printf 'corrupted' >> "$ESP/EFI/pgsd/bas/slots/1/kernel"
run
check "corruption refused"        "artifact kernel FAILED verification"
check "failure reported"          "verification FAILED"
check "refusal still chainloads"  "CHAINLOAD TARGET REACHED"

# Pass 6: ELF refusal. A truncated ELF published with a CORRECT
# manifest passes all three integrity layers (the hash is of the
# truncated bytes) and must fail at the ELF layer, still
# chainloading (increment 2 is verify-only).
"$PROJ_DIR/zig-out/bin/mk-fake-kernel" "$ESP/EFI/pgsd/bas/slots/1/kernel" truncate
{
    echo "PGSD-BAS-MANIFEST 1"
    echo "$(hashf "$ESP/EFI/pgsd/bas/slots/1/kernel") $(wc -c < "$ESP/EFI/pgsd/bas/slots/1/kernel" | tr -d ' ') kernel"
} > "$ESP/EFI/pgsd/bas/slots/1/manifest"
"$PROJ_DIR/zig-out/bin/bas-selector" commit "$ESP/EFI/pgsd/bas/selector" 1 \
    "$(hashf "$ESP/EFI/pgsd/bas/slots/1/manifest")" >/dev/null
run
check "layers pass on truncated"  "artifact kernel verified"
check "elf refuses truncated"     "ELF: FAIL"
check "elf refusal chainloads"    "CHAINLOAD TARGET REACHED"

[ "$fails" -eq 0 ] && echo "qemu-smoke: all checks passed" || { echo "qemu-smoke: $fails check(s) FAILED"; exit 1; }
