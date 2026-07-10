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
        TRAMP=$(strings "$VARS" | grep -aoE 'clipc=0x[0-9a-f]+' | tail -1 | cut -d= -f2)
        echo ""
        [ -n "$TRAMP" ] && echo "gdb-transfer: trampoline address = $TRAMP" \
            && echo "gdb-transfer: next: sh scripts/gdb-transfer.sh step $TRAMP" \
            || echo "gdb-transfer: no tramp= recorded (transfer path not reached?)"
        ;;
    step)
        command -v gdb >/dev/null 2>&1 || { echo "gdb-transfer: gdb not found; pkg install gdb" >&2; exit 1; }
        # Self-discovering: the trampoline runtime address depends on
        # where the firmware placed the PE image this boot, so an
        # address from an earlier run can be stale. Discover it now,
        # in this invocation, then break at it. If the breakpoint does
        # not land on the cli that opens the trampoline, the image
        # relocated between the discover boot and the step boot;
        # retry a few times before giving up.
        TRAMP="${2:-}"
        tries=0
        while [ "$tries" -lt 4 ]; do
            tries=$((tries + 1))
            if [ -z "$TRAMP" ]; then
                stage
                timeout 60 "$QEMU" -machine q35 -m 256 -nographic -no-reboot -boot menu=off \
                    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
                    -drive if=pflash,format=raw,file="$VARS" \
                    -drive format=raw,file=fat:rw:"$ESP" \
                    -net none >/dev/null 2>&1 || true
                TRAMP=$(strings "$VARS" | grep -aoE 'clipc=0x[0-9a-f]+' | tail -1 | cut -d= -f2)
                [ -n "$TRAMP" ] || { echo "gdb-transfer: transfer path not reached (no tramp); check PGSD_REAL_KERNEL and arming" >&2; exit 1; }
                echo "gdb-transfer: discovered trampoline = $TRAMP (attempt $tries)"
            fi
            stage
            cat > /tmp/pgsd-gdb.cmds << GDBEOF
set pagination off
set confirm off
target remote localhost:1234
hbreak *$TRAMP
continue
echo \n=== reached breakpoint; first instruction must be 'cli' ===\n
x/1i $TRAMP
info registers rip rsp cr3
echo \n=== step: cli ===\n
stepi
echo \n=== step: mov->cr3 (watch cr3 change) ===\n
stepi
info registers rip cr3
echo \n=== step: mov->rsp ===\n
stepi
info registers rip rsp
echo \n=== step: jmp to kernel entry (rip should become the kernel entry) ===\n
stepi
info registers rip
echo \n=== kernel first instructions ===\n
x/4i \$rip
stepi
stepi
stepi
stepi
info registers rip rsp rdi rsi rcx rdx
echo \n=== if rip is 0/nonsense or unchanged, the fault is at the step above ===\n
detach
quit
GDBEOF
            echo "gdb-transfer: qemu (halted) + gdb; break at $TRAMP"
            "$QEMU" -machine q35 -m 256 -nographic -no-reboot -boot menu=off \
                -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
                -drive if=pflash,format=raw,file="$VARS" \
                -drive format=raw,file=fat:rw:"$ESP" \
                -net none -S -gdb tcp::1234 > "$LOG" 2>&1 &
            QPID=$!
            sleep 1
            gdb -q -x /tmp/pgsd-gdb.cmds 2>&1 | tee /tmp/pgsd-gdb.out
            kill "$QPID" 2>/dev/null || true
            # Did the breakpoint land on cli? cli is opcode fa; gdb
            # prints it as "cli" in the x/1i line.
            if grep -qaE ':\s+cli' /tmp/pgsd-gdb.out || grep -qaE '\bcli\b$' /tmp/pgsd-gdb.out; then
                echo "gdb-transfer: breakpoint landed on the trampoline (cli confirmed)"
                break
            fi
            echo "gdb-transfer: breakpoint did NOT land on cli (image relocated?); rediscovering..."
            TRAMP=""
        done
        echo "gdb-transfer: serial log at $LOG"
        ;;
    deepstep)
        # Single-step many instructions from the kernel entry, showing
        # each rip, to find the instruction where free execution would
        # fault. trace showed rip pinned at the entry across free-run
        # samples: a reset loop (fault a few instructions in ->
        # triple-fault -> reset -> firmware -> loader -> re-enter). The
        # step mode stopped at 4 instructions, before the faulting one.
        # This walks far enough to see it. Single-stepping suppresses
        # async triggers, so a fault here is a synchronous one (a bad
        # memory access, a bad descriptor load); if deepstep runs clean
        # to N instructions but free-run resets, the trigger is async
        # (an interrupt/NMI/SMI through an IDT not yet installed).
        command -v gdb >/dev/null 2>&1 || { echo "gdb-transfer: gdb not found; pkg install gdb" >&2; exit 1; }
        stage
        timeout 60 "$QEMU" -machine q35 -m 256 -nographic -no-reboot -boot menu=off \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
            -drive if=pflash,format=raw,file="$VARS" \
            -drive format=raw,file=fat:rw:"$ESP" \
            -net none >/dev/null 2>&1 || true
        TRAMP=$(strings "$VARS" | grep -aoE 'clipc=0x[0-9a-f]+' | tail -1 | cut -d= -f2)
        [ -n "$TRAMP" ] || { echo "gdb-transfer: no clipc discovered" >&2; exit 1; }
        echo "gdb-transfer: deepstep from cli=$TRAMP"
        stage
        cat > /tmp/pgsd-gdb.cmds << GDBEOF
set pagination off
set confirm off
target remote localhost:1234
hbreak *$TRAMP
continue
# into the kernel: cli/cr3/rsp/jmp
stepi
stepi
stepi
stepi
echo \n=== stepping kernel locore; watch for rip leaving the kernel range ===\n
set \$k = 0
while \$k < 60
  set \$k = \$k + 1
  printf "%02d rip=0x%lx  ", \$k, \$rip
  x/1i \$rip
  stepi
end
echo \n=== end of deepstep ===\n
info registers rip rsp rax rbx rcx rdx rsi rdi
detach
quit
GDBEOF
        "$QEMU" -machine q35 -m 256 -nographic -no-reboot -boot menu=off \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
            -drive if=pflash,format=raw,file="$VARS" \
            -drive format=raw,file=fat:rw:"$ESP" \
            -net none -S -gdb tcp::1234 > "$LOG" 2>&1 &
        QPID=$!
        sleep 1
        gdb -q -x /tmp/pgsd-gdb.cmds 2>&1 | grep -aE 'rip=|===|:\t' || true
        kill "$QPID" 2>/dev/null || true
        echo "gdb-transfer: serial log at $LOG"
        ;;
    trace)
        # Like step, but after reaching the kernel entry, let it run
        # under gdb and periodically sample rip to see where early
        # kernel bring-up wedges. A stuck or resetting rip means an
        # early fault (candidate: the kernel's physical-memory setup
        # against our no-copy staging layout); an rip parked in a spin
        # or wait means it reached a later stage that is blocking. This
        # is the loader/kernel boundary diagnostic.
        command -v gdb >/dev/null 2>&1 || { echo "gdb-transfer: gdb not found; pkg install gdb" >&2; exit 1; }
        stage
        timeout 60 "$QEMU" -machine q35 -m 256 -nographic -no-reboot -boot menu=off \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
            -drive if=pflash,format=raw,file="$VARS" \
            -drive format=raw,file=fat:rw:"$ESP" \
            -net none >/dev/null 2>&1 || true
        TRAMP=$(strings "$VARS" | grep -aoE 'clipc=0x[0-9a-f]+' | tail -1 | cut -d= -f2)
        ENTRY=$(strings "$VARS" | grep -aoE 'entry=0x[0-9a-f]+' | tail -1 | cut -d= -f2)
        [ -n "$TRAMP" ] || { echo "gdb-transfer: no clipc discovered" >&2; exit 1; }
        echo "gdb-transfer: trace; cli=$TRAMP entry=$ENTRY"
        KERNEL_ELF="$PGSD_REAL_KERNEL"
        stage
        cat > /tmp/pgsd-gdb.cmds << GDBEOF
set pagination off
set confirm off
target remote localhost:1234
hbreak *$TRAMP
continue
echo \n=== at trampoline; stepping into kernel entry ===\n
stepi
stepi
stepi
stepi
info registers rip
echo \n=== kernel entered; setting landmark breakpoints ===\n
# Load the kernel's symbols so we can break at named early-boot
# functions and see how far hammer_time gets. The kernel runs a long
# silent stretch before cninit (console init), so "no serial" alone
# does not localize the stop; these landmarks do. Breakpoints that
# are hit print progress; the last one reached before the machine
# faults/resets is the boundary.
file $KERNEL_ELF
break hammer_time
break native_parse_preload_data
break getmemsize
break init_param1
break cninit
# temporary breakpoints so a hit does not require continue plumbing
commands
silent
printf "LANDMARK: reached %s\n", \$pc
continue
end
continue
echo \n=== if no LANDMARK lines printed, the fault is before hammer_time in btext locore ===\n
info registers rip
detach
quit
detach
quit
GDBEOF
        "$QEMU" -machine q35 -m 256 -nographic -no-reboot -boot menu=off \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
            -drive if=pflash,format=raw,file="$VARS" \
            -drive format=raw,file=fat:rw:"$ESP" \
            -net none -S -gdb tcp::1234 > "$LOG" 2>&1 &
        QPID=$!
        sleep 1
        gdb -q -x /tmp/pgsd-gdb.cmds 2>&1 | grep -aE 'sample|rip|===' || true
        kill "$QPID" 2>/dev/null || true
        echo "gdb-transfer: serial log at $LOG"
        ;;
    run)
        # Free run: boot the transfer-armed real kernel and let it run
        # without gdb, serial captured, to see how far kernel bring-up
        # gets past the (proven-correct) handoff. The step mode freezes
        # the kernel four instructions in; this lets it reach cninit
        # and the copyright banner if it is going to.
        stage
        echo "gdb-transfer: free run; serial to $LOG"
        echo "------------------------------------------------------------"
        timeout 90 "$QEMU" -machine q35 -m 256 -nographic -no-reboot -boot menu=off \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
            -drive if=pflash,format=raw,file="$VARS" \
            -drive format=raw,file=fat:rw:"$ESP" \
            -net none 2>&1 | tr -d '\r' | tee "$LOG" || true
        echo "------------------------------------------------------------"
        if grep -qa "Copyright (c) 1992" "$LOG"; then
            echo "gdb-transfer: FreeBSD banner reached"
        else
            echo "gdb-transfer: no banner; markers:"
            strings "$VARS" | grep -aE 'MARK_|BOOT_ATTEMPT' | tail -4 || true
        fi
        ;;
    *)
        echo "gdb-transfer: unknown mode '$MODE' (discover|step|run)" >&2
        exit 2
        ;;
esac
