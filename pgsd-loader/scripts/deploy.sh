#!/bin/sh
# deploy.sh: the sanctioned writer of the bench ESP and boot
# variables for pgsd-loader metal runs. It implements ADR 0005
# Decision 4 (as amended): the transfer is armed through the
# firmware's supported mechanism on this bench (an activated
# boot-order-head entry) for EXACTLY ONE CYCLE, with the prior
# BootOrder restored and the entry reaped so a failure cannot recur.
#
# This is the only script here that writes the real ESP and touches
# NVRAM boot variables, and the only one that needs privilege. It is
# deliberately split into subcommands so the dangerous transitions
# are explicit and a manual runsheet cannot omit a safety step (F2
# recorded exactly such an omission).
#
# Subcommands:
#   stage          copy loader/launcher/kernel into the bench ESP and
#                  build the BAS slot+manifest+selector. Writes files
#                  only; no boot variables, no arming. Safe to repeat.
#   arm-once       create + ACTIVATE a boot entry for the armed
#                  transfer loader, save the current BootOrder, and
#                  place the entry at the order head for ONE cycle.
#                  Prints the exact reboot-and-then-recover steps.
#                  Does NOT reboot.
#   recover        restore the saved BootOrder and delete the armed
#                  entry. Run this BEFORE inspecting results and
#                  BEFORE any second cycle. Idempotent.
#   readback       print the NVRAM breadcrumb and markers from the
#                  last armed cycle (PgsdBasVerdict). Read-only.
#   status         show current BootOrder, the armed entry if present,
#                  and whether a saved order is pending recovery.
#
# Normal one-cycle metal attempt:
#   sudo sh deploy.sh stage
#   sudo sh deploy.sh arm-once      # prints reboot instructions
#   (reboot the bench once, let it attempt, it returns to firmware)
#   sudo sh deploy.sh recover       # restore order, reap entry
#   sudo sh deploy.sh readback      # read the evidence
#
# The arm-once/recover split is intentional: arming and disarming are
# separate deliberate acts, and recover is safe to run at any time
# (idempotent), so the bench is never more than one command from its
# normal boot path.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
B="$PROJ_DIR/zig-out/bin"

# --- configuration (override via environment) ---
ESP_MNT="${ESP_MNT:-/boot/efi}"                # bench ESP mount point
ESP_DISK="${ESP_DISK:-}"                        # e.g. ada0p1 (for -c)
PGSD_REAL_KERNEL="${PGSD_REAL_KERNEL:-/boot/kernel/kernel}"
ENTRY_LABEL="${ENTRY_LABEL:-PGSD-loader armed (one-shot)}"
SAVED_ORDER_FILE="${SAVED_ORDER_FILE:-/var/db/pgsd-loader-saved-bootorder}"
PGSD_GUID="50475344-6261-4c33-8a01-706773646261"

need_root() {
    [ "$(id -u)" -eq 0 ] || { echo "deploy.sh: $1 needs root (writes ESP/NVRAM)" >&2; exit 1; }
}

hashf() { sha256 -q "$1" 2>/dev/null || sha256sum "$1" | awk '{print $1}'; }

esp() { printf '%s/%s' "$ESP_MNT" "$1"; }

cmd_stage() {
    need_root stage
    [ -x "$B/pgsd-loader.efi" ] || { echo "deploy.sh: build first (no $B/pgsd-loader.efi)" >&2; exit 1; }
    [ -f "$PGSD_REAL_KERNEL" ] || { echo "deploy.sh: kernel not found: $PGSD_REAL_KERNEL" >&2; exit 1; }
    mkdir -p "$(esp EFI/BOOT)" "$(esp EFI/pgsd/bas/slots/1)" "$(esp EFI/freebsd)"
    # boot-launcher is the BOOTX64 that starts the armed -boot.efi name.
    cp "$B/boot-launcher.efi"     "$(esp EFI/BOOT/BOOTX64.EFI)"
    cp "$B/pgsd-loader.efi"       "$(esp EFI/pgsd/pgsd-loader-boot.efi)"
    # stock loader stays the fallback; never overwrite if present.
    if [ ! -f "$(esp EFI/freebsd/loader.efi)" ]; then
        echo "deploy.sh: note: no EFI/freebsd/loader.efi present as fallback" >&2
    fi
    cp "$PGSD_REAL_KERNEL" "$(esp EFI/pgsd/bas/slots/1/kernel)"
    ksum=$(hashf "$(esp EFI/pgsd/bas/slots/1/kernel)")
    ksize=$(wc -c < "$(esp EFI/pgsd/bas/slots/1/kernel)" | tr -d ' ')
    {
        echo "PGSD-BAS-MANIFEST 1"
        echo "$ksum $ksize kernel"
    } > "$(esp EFI/pgsd/bas/slots/1/manifest)"
    "$B/bas-selector" init "$(esp EFI/pgsd/bas/selector)" >/dev/null 2>&1 || true
    "$B/bas-selector" commit "$(esp EFI/pgsd/bas/selector)" 1 \
        "$(hashf "$(esp EFI/pgsd/bas/slots/1/manifest)")" >/dev/null
    echo "deploy.sh: staged armed transfer loader and BAS slot 1 into $ESP_MNT"
    echo "deploy.sh: next: sudo sh deploy.sh arm-once"
}

cmd_arm_once() {
    need_root arm-once
    if [ -f "$SAVED_ORDER_FILE" ]; then
        echo "deploy.sh: a saved BootOrder already exists ($SAVED_ORDER_FILE)." >&2
        echo "deploy.sh: run 'recover' first; refusing to arm twice without recovery." >&2
        exit 1
    fi
    [ -n "$ESP_DISK" ] || { echo "deploy.sh: set ESP_DISK to the ESP partition (e.g. ada0p1) for entry creation" >&2; exit 1; }

    # Save the current BootOrder so recover can restore it exactly.
    cur=$(efibootmgr | awk -F': ' '/BootOrder/{print $2}')
    [ -n "$cur" ] || { echo "deploy.sh: could not read current BootOrder" >&2; exit 1; }
    printf '%s\n' "$cur" > "$SAVED_ORDER_FILE"
    echo "deploy.sh: saved BootOrder $cur -> $SAVED_ORDER_FILE"

    # Create the entry pointing at the launcher, then ACTIVATE it (F2:
    # entries are created inactive and an inactive head is skipped).
    efibootmgr -c -l "$(esp EFI/BOOT/BOOTX64.EFI)" -L "$ENTRY_LABEL" >/dev/null
    # Find the just-created entry number by its unique label.
    bn=$(efibootmgr | awk -v L="$ENTRY_LABEL" '$0 ~ L {gsub(/[^0-9]/,"",$1); print $1; exit}')
    [ -n "$bn" ] || { echo "deploy.sh: could not find created entry '$ENTRY_LABEL'" >&2; exit 1; }
    efibootmgr -a -b "$bn" >/dev/null
    # Place it at the order head for exactly one cycle.
    efibootmgr -o "$bn,$cur" >/dev/null
    echo "deploy.sh: armed entry Boot$bn (active) at the order head for ONE cycle."
    echo ""
    echo "  NEXT, in order:"
    echo "    1. reboot the bench ONCE."
    echo "    2. it will attempt the armed transfer, then return to firmware"
    echo "       (the entry is one-shot only if you run recover; do that next)."
    echo "    3. sudo sh deploy.sh recover     # restore order, reap entry"
    echo "    4. sudo sh deploy.sh readback    # read the evidence"
    echo ""
    echo "  If anything looks wrong BEFORE rebooting, run recover now to disarm."
}

cmd_recover() {
    need_root recover
    # Restore the saved BootOrder if we have one.
    if [ -f "$SAVED_ORDER_FILE" ]; then
        saved=$(cat "$SAVED_ORDER_FILE")
        if [ -n "$saved" ]; then
            efibootmgr -o "$saved" >/dev/null 2>&1 || \
                echo "deploy.sh: warning: could not restore BootOrder $saved" >&2
            echo "deploy.sh: restored BootOrder $saved"
        fi
        rm -f "$SAVED_ORDER_FILE"
    else
        echo "deploy.sh: no saved BootOrder pending (already recovered or never armed)"
    fi
    # Reap any entry with our label (idempotent).
    for bn in $(efibootmgr | awk -v L="$ENTRY_LABEL" '$0 ~ L {gsub(/[^0-9]/,"",$1); print $1}'); do
        efibootmgr -B -b "$bn" >/dev/null 2>&1 || true
        echo "deploy.sh: reaped Boot$bn"
    done
    echo "deploy.sh: recover complete; bench is on its normal boot path."
}

cmd_readback() {
    # Read-only; root only needed if efivar requires it.
    if efivar --print "$PGSD_GUID-PgsdBasVerdict" 2>/dev/null; then
        :
    else
        echo "deploy.sh: could not read PgsdBasVerdict (try sudo, or no armed cycle has run)" >&2
    fi
}

cmd_status() {
    echo "== BootOrder =="
    efibootmgr | grep -E 'BootOrder|BootCurrent' || true
    echo "== armed entry =="
    efibootmgr | grep -F "$ENTRY_LABEL" || echo "(none)"
    echo "== pending recovery =="
    if [ -f "$SAVED_ORDER_FILE" ]; then
        echo "YES: saved order $(cat "$SAVED_ORDER_FILE") -> run recover"
    else
        echo "no"
    fi
}

case "${1:-}" in
    stage)     cmd_stage ;;
    arm-once)  cmd_arm_once ;;
    recover)   cmd_recover ;;
    readback)  cmd_readback ;;
    status)    cmd_status ;;
    *)
        echo "usage: sh deploy.sh <stage|arm-once|recover|readback|status>" >&2
        echo "  see the header for the one-cycle metal attempt sequence" >&2
        exit 2
        ;;
esac
