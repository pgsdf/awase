#!/bin/sh
# gdb-transfer.sh: run the real-kernel transfer pass under a QEMU gdb
# stub and single-step the trampoline, for diagnosing an F7-class
# stop that the NVRAM markers localize to "past ExitBootServices"
# (ADR 0005: MARK_EXITED_BOOTSERVICES present, no kernel banner).
#
# The markers narrow the fault to the four trampoline instructions
# (cli; mov cr3; mov rsp; jmp entry) plus the kernel's first
# instructions. This harness lets an operator watch that transition:
# it boots the transfer-armed loader against PGSD_REAL_KERNEL under
# qemu -s -S (gdb stub, CPU halted at reset), and drives gdb with a
# script that breaks at the trampoline runtime address and single
# steps across the cr3 load and the jump, dumping registers and the
# fault state at each step.
#
# The trampoline address is not known until the loader runs (PE
# images load where the firmware places them), and the loader
# records it in the BOOT_ATTEMPT NVRAM breadcrumb as tramp=0x...
# So this is a two-phase tool:
#
#   phase 1 (discover): sh scripts/gdb-transfer.sh discover
#       runs the transfer pass once, then prints the tramp= address
#       from the emulated NVRAM. No gdb.
#
#   phase 2 (step): sh scripts/gdb-transfer.sh step 0x<tramp>
#       reruns under the gdb stub, breaks at that address, and single
#       steps the trampoline with register dumps. Needs gdb with
#       x86-64 support.
#
# PGSD_REAL_KERNEL must point at the kernel ELF (bench: the pinned
# /boot/kernel/kernel). Emulation only; the bench remains sole
# authority (parent ADR 0001 Decision 7).
set -eu

[ "$(id -u)" -ne 0 ] || { echo "gdb-transfer: do not run as root" >&2; exit 1; }

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

MODE="${1:-}"
[ -n "$MODE" ] || { echo "usage: sh scripts/gdb-transfer.sh <discover|step [0xTRAMP]>" >&2; exit 2; }

probe() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }
OVMF_CODE="${OVMF_CODE:-$(probe \
    /usr/local/share/edk2-qemu/QEMU_UEFI_CODE-x86_64.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd || true)}"
OVMF_VARS="${OVMF_VARS:-$(probe \
    /usr/local/share/edk2-qemu/QEMU_UEFI_VARS-x86_64.fd \
    /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd || true)}"
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || { echo "gdb-transfer: set OVMF_CODE and OVMF_VARS" >&2; exit 1; }
QEMU="${QEMU:-qemu-system-x86_64}"
[ -n "${PGSD_REAL_KERNEL:-}" ] || { echo "gdb-transfer: set PGSD_REAL_KERNEL" >&2; exit 2; }
[ -f "$PGSD_REAL_KERNEL" ] || { echo "gdb-transfer: PGSD_REAL_KERNEL not found: $PGSD_REAL_KERNEL" >&2; exit 2; }

ESP="/tmp/pgsd-gdb-esp.$$"
VARS="/tmp/pgsd-gdb.vars"
LOG="/tmp/pgsd-gdb.log"
B="$PROJ_DIR/zig-out/bin"

sh "$PROJ_DIR/build.sh" >/dev/null
sh "$PROJ_DIR/build.sh" test-target >/dev/null
sh "$PROJ_DIR/build.sh" tools >/dev/null

hashf() { sha256 -q "$1" 2>/dev/null || sha256sum "$1" | awk '{print $1}'; }

stage() {
    rm -rf "$ESP"
    mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/pgsd/bas/slots/1" "$ESP/EFI/freebsd"
    cp "$B/boot-launcher.efi" "$ESP/EFI/BOOT/BOOTX64.EFI"
    cp "$B/pgsd-loader.efi" "$ESP/EFI/pgsd/pgsd-loader-boot.efi"
    cp "$B/chainload-target.efi" "$ESP/EFI/freebsd/loader.efi"
    cp "$PGSD_REAL_KERNEL" "$ESP/EFI/pgsd/bas/slots/1/kernel"
    {
        echo "PGSD-BAS-MANIFEST 1"
        echo "$(hashf "$ESP/EFI/pgsd/bas/slots/1/kernel") $(wc -c < "$ESP/EFI/pgsd/bas/slots/1/kernel" | tr -d ' ') kernel"
    } > "$ESP/EFI/pgsd/bas/slots/1/manifest"
    "$B/bas-selector" init "$ESP/EFI/pgsd/bas/selector" >/dev/null
    "$B/bas-selector" commit "$ESP/EFI/pgsd/bas/selector" 1 \
        "$(hashf "$ESP/EFI/pgsd/bas/slots/1/manifest")" >/dev/null
    cp "$OVMF_VARS" "$VARS"
}

cleanup() { rm -rf "$ESP"; }
trap cleanup EXIT INT TERM

case "$MODE" in
    discover)
        stage
        echo "gdb-transfer: running transfer pass to discover the trampoline address..."
        timeout 60 "$QEMU" -machine q35 -m 256 -nographic -no-reboot -boot menu=off \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
            -drive if=pflash,format=raw,file="$VARS" \
            -drive format=raw,file=fat:rw:"$ESP" \
            -net none 2>&1 | tr -d '\r' > "$LOG" || true
        echo "gdb-transfer: markers this run:"
        strings "$VARS" | grep -aE 'BOOT_ATTEMPT|MARK_' | tail -6 || true
        TRAMP=$(strings "$VARS" | grep -aoE 'tramp=0x[0-9a-f]+' | tail -1 | cut -d= -f2)
        echo ""
        [ -n "$TRAMP" ] && echo "gdb-transfer: trampoline address = $TRAMP" \
            && echo "gdb-transfer: next: sh scripts/gdb-transfer.sh step $TRAMP" \
            || echo "gdb-transfer: no tramp= recorded (transfer path not reached?)"
        ;;
    step)
        TRAMP="${2:-}"
        [ -n "$TRAMP" ] || { echo "gdb-transfer: step needs the trampoline address (run discover first)" >&2; exit 2; }
        command -v gdb >/dev/null 2>&1 || { echo "gdb-transfer: gdb not found; pkg install gdb" >&2; exit 1; }
        stage
        cat > /tmp/pgsd-gdb.cmds << GDBEOF
# Single-step the trampoline. TRAMP is the runtime address of
# transferToKernel: cli / mov %cr3 / mov %rsp / jmpq *entry.
set pagination off
set confirm off
target remote localhost:1234
# Hardware breakpoint: the address is not in any file symbol table
# (it is the running PE image), so break by raw address.
hbreak *$TRAMP
continue
echo \n=== reached trampoline entry ===\n
info registers rip rsp cr3
x/4i $TRAMP
echo \n=== step 1: after cli ===\n
stepi
info registers rip
echo \n=== step 2: after mov->cr3 (now on kernel page tables) ===\n
stepi
info registers rip cr3
echo \n(if rip advanced past here, the post-cr3 instruction fetch succeeded)\n
echo \n=== step 3: after mov->rsp ===\n
stepi
info registers rip rsp
echo \n=== step 4: the jmp to kernel entry ===\n
stepi
info registers rip
echo \n=== now at kernel first instruction; step a few ===\n
stepi
stepi
stepi
info registers rip rsp rdi rsi
echo \n=== done. if rip is 0 or nonsense, the fault is here ===\n
detach
quit
GDBEOF
        echo "gdb-transfer: launching qemu (halted) + gdb; break at $TRAMP"
        "$QEMU" -machine q35 -m 256 -nographic -no-reboot -boot menu=off \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
            -drive if=pflash,format=raw,file="$VARS" \
            -drive format=raw,file=fat:rw:"$ESP" \
            -net none -S -gdb tcp::1234 > "$LOG" 2>&1 &
        QPID=$!
        sleep 1
        gdb -q -x /tmp/pgsd-gdb.cmds || true
        kill "$QPID" 2>/dev/null || true
        echo "gdb-transfer: serial log at $LOG"
        ;;
    *)
        echo "gdb-transfer: unknown mode '$MODE' (discover|step)" >&2
        exit 2
        ;;
esac
