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
#
# Overriding a config variable under sudo: sudo scrubs the
# environment, so "VAR=val sudo sh deploy.sh ..." does NOT pass VAR.
# Put the assignment AFTER sudo ("sudo VAR=val sh deploy.sh ...") or
# use "sudo -E". The defaults below fit the bench, so overrides are
# rarely needed; arm-once no longer requires any variable to be set.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
B="$PROJ_DIR/zig-out/bin"

# --- configuration (override via environment) ---
ESP_MNT="${ESP_MNT:-/boot/efi}"                # bench ESP mount point
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
    loader_path="$(esp EFI/BOOT/BOOTX64.EFI)"
    [ -f "$loader_path" ] || { echo "deploy.sh: staged loader not found ($loader_path); run stage first" >&2; exit 1; }

    # Save the current BootOrder so recover can restore it exactly.
    cur=$(efibootmgr | awk -F': ' '/BootOrder/{print $2}')
    [ -n "$cur" ] || { echo "deploy.sh: could not read current BootOrder" >&2; exit 1; }
    printf '%s\n' "$cur" > "$SAVED_ORDER_FILE"
    echo "deploy.sh: saved BootOrder $cur -> $SAVED_ORDER_FILE"

    # From this point on, an entry may exist in NVRAM. Any failure
    # must reap it and restore the order rather than leave the bench
    # armed. Disable errexit here and check each step explicitly, and
    # trap any unexpected exit to run recover. This is the safety
    # invariant the one-cycle discipline depends on: arm-once never
    # returns with an armed entry present unless the full head
    # placement succeeded.
    set +e
    trap 'echo "deploy.sh: arm-once failed mid-way; disarming..." >&2; cmd_recover; exit 1' EXIT

    # Create + activate. -p resolves the ESP device from the path.
    # efibootmgr prints the new entry ("Boot0004* label"); capture the
    # bootnum from that output directly rather than re-parsing the
    # full list with a regex (the label contains parens, which are
    # regex metacharacters). -c also prepends the entry to BootOrder.
    create_out=$(efibootmgr -c -a -p -l "$loader_path" -L "$ENTRY_LABEL" 2>&1)
    # efibootmgr prints created/listed entries as "BootXXXX* label"
    # (format "Boot%04X"). Extract the 4 hex digits by stripping the
    # literal "Boot" prefix and any "*" suffix. Do NOT gsub out
    # non-hex characters: "B" in "Boot" is itself a hex digit, so a
    # hex-class strip leaves "B0005" (the bug that failed head
    # placement and forced a disarm).
    bn=$(printf '%s\n' "$create_out" | while IFS= read -r line; do
        for tok in $line; do
            case "$tok" in
                Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]|Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]\*)
                    t=${tok#Boot}; t=${t%\*}; printf '%s\n' "$t"; break ;;
            esac
        done
    done | head -1)
    if [ -z "$bn" ]; then
        # Fall back to a literal (non-regex) scan of the full list.
        bn=$(efibootmgr | while IFS= read -r line; do
            case "$line" in
                *"$ENTRY_LABEL"*)
                    set -- $line
                    b=$1; b=${b#Boot}; b=${b%\*}
                    printf '%s\n' "$b"; break ;;
            esac
        done)
    fi
    if [ -z "$bn" ]; then
        echo "deploy.sh: entry create did not yield a bootnum; output was:" >&2
        printf '%s\n' "$create_out" >&2
        # trap will disarm (reap by label) and restore order
        exit 1
    fi

    # Ensure active (F2) and place at the order head for one cycle.
    efibootmgr -a -b "$bn" >/dev/null 2>&1
    efibootmgr -o "$bn,$cur" >/dev/null 2>&1
    # Verify the head is our active entry before declaring success.
    # Normalize case: efibootmgr prints Boot%04X / BootOrder %04X
    # (uppercase), but normalize both sides so a bootnum containing a
    # hex letter (e.g. 000A) can never spuriously mismatch.
    newhead=$(efibootmgr | awk -F': ' '/BootOrder/{print $2}' | awk -F', *' '{print $1}')
    newhead_u=$(printf '%s' "$newhead" | tr 'a-f' 'A-F')
    bn_u=$(printf '%s' "$bn" | tr 'a-f' 'A-F')
    if [ "$newhead_u" != "$bn_u" ]; then
        echo "deploy.sh: could not place Boot$bn at the order head; disarming." >&2
        exit 1   # trap disarms
    fi

    # Success: keep the entry, clear the trap.
    trap - EXIT
    set -e
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
    # Reap any entry with our label (idempotent). Match the label
    # literally, not as a regex: the label contains parens, which are
    # regex metacharacters and can defeat a "$0 ~ L" match. Also match
    # the fixed BOOTX64 loader path as a fallback in case the label
    # was altered.
    efibootmgr | while IFS= read -r line; do
        case "$line" in
            *"$ENTRY_LABEL"*)
                set -- $line
                b=$1; b=${b#Boot}; b=${b%\*}
                efibootmgr -B -b "$b" >/dev/null 2>&1 || true
                echo "deploy.sh: reaped Boot$b" ;;
        esac
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
