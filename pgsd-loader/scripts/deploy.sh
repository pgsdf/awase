#!/bin/sh
# ======================================================================
# DANGEROUS. ARMS PHYSICAL HARDWARE. READ ADR 0005 DECISION 7 FIRST.
#
# This path was retired by Decision 6 (2026-07-11) after the transfer
# that booted in emulation failed twice on this bench's Apple firmware,
# each attempt costing a full FreeBSD reinstall.
#
# Decision 7 (2026-07-12) unblocks it. Three source-identified defects
# in the EFI handoff have since been found against the working
# reference (FreeBSD's own loader.efi), corrected, and verified in
# emulation:
#
#   F7  the boot environment was incomplete: no serial console binding,
#       no ACPI RSDP. Now published.
#   F9  the EFI runtime map was never given to the kernel: virtual_start
#       was zero in the map we passed, so the kernel could not locate
#       the runtime services and refused to attach efirt. Now
#       identity-mapped in place, and SetVirtualAddressMap is called.
#       efirt now attaches: "efirtc0: registered as a time-of-day clock".
#   F8  the window between GetMemoryMap and ExitBootServices contained
#       two SetVariable calls. The reference keeps that window empty by
#       construction, because firmware has been observed changing the
#       memory map during ExitBootServices. Now empty.
#
# The artifact is therefore materially different from the one that
# bricked the bench. It is NOT proven on metal, and cannot be:
# emulation success does not imply metal success (Decision 2), and F8's
# fix in particular repairs a hazard OVMF does not even exercise.
#
# Arming remains a real risk of a third reinstall. Before using this:
# exercise deploy.sh against the mock efibootmgr harness, have a
# FreeBSD USB installer and a known-good ESP restore to hand, and
# accept that outcome before you start.
# ======================================================================
#
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

# The PERSISTENT entry's label is deliberately DIFFERENT from the
# one-shot's. recover reaps entries by label, and it must never reap the
# persistent boot path: recover is run after every armed cycle, and a
# recover that removed the permanent entry would silently return the bench
# to the stock FreeBSD loader without anyone noticing.
PERSIST_LABEL="${PERSIST_LABEL:-PGSD-loader (persistent)}"
SAVED_ORDER_FILE="${SAVED_ORDER_FILE:-/var/db/pgsd-loader-saved-bootorder}"

# Backup of the ESP's firmware-fallback loader.
#
# stage overwrites \EFI\BOOT\BOOTX64.EFI with the armed boot-launcher.
# That path is the UEFI removable-media fallback: it is what firmware
# boots when it has no valid NVRAM entry to use. Overwriting it and not
# restoring it means an NVRAM reset does not recover the machine, it
# re-arms it: the firmware finds no boot entries, falls back to
# BOOTX64.EFI, and runs the transfer that just failed.
#
# That is almost certainly what happened on the second brick. The
# NVRAM reset (Option-Cmd-P-R) was tried and "did not help", and the
# machine was declared unrecoverable. It was not: the reset was booting
# the armed loader from the fallback path.
#
# The backup lives on the ESP, not on the root filesystem, deliberately.
# If the machine will not boot, the ESP is reachable from a USB
# installer or another machine with nothing more than a FAT mount; a
# ZFS root may not be. Recovery data belongs where recovery happens.
BOOTX64_BACKUP="EFI/BOOT/BOOTX64.EFI.pgsd-orig"
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
    # F11: \EFI\BOOT\BOOTX64.EFI is NOT touched, deliberately.
    #
    # Unnecessary: pgsd-loader triggers its armed path from its own
    # FILENAME (bas_boot.bootArmed matches "pgsd-loader-boot.efi"), not
    # from a load-options string. boot-launcher exists only to pass an
    # option string that FreeBSD's efibootmgr cannot attach to a boot
    # entry, and its own header says "emulation-only harness ... Never
    # deployed to hardware." It was being deployed to hardware.
    #
    # And dangerous: BOOTX64.EFI is the UEFI removable-media fallback,
    # and on this bench the Option-key picker boots it in preference to
    # the NVRAM entry (F11). Overwriting it armed every recovery route
    # the operator had: the picker, and an NVRAM reset. Both metal
    # attempts were made with a recovery path that ran through the armed
    # artifact, which is why the second "brick" could not be recovered.
    # The machine was never broken.
    #
    # The armed loader lives at \EFI\pgsd\pgsd-loader-boot.efi, the
    # NVRAM entry points straight at it, and BOOTX64.EFI stays stock.
    cp "$B/pgsd-loader.efi"       "$(esp EFI/pgsd/pgsd-loader-boot.efi)"
    # stock loader stays the fallback; never overwrite if present.
    if [ ! -f "$(esp EFI/freebsd/loader.efi)" ]; then
        echo "deploy.sh: note: no EFI/freebsd/loader.efi present as fallback" >&2
    fi
    cp "$PGSD_REAL_KERNEL" "$(esp EFI/pgsd/bas/slots/1/kernel)"
    ksum=$(hashf "$(esp EFI/pgsd/bas/slots/1/kernel)")
    ksize=$(wc -c < "$(esp EFI/pgsd/bas/slots/1/kernel)" | tr -d ' ')

    # ADR 0006: zfs.ko goes in the ATTESTED SLOT, not beside it.
    #
    # The root filesystem is ZFS and ZFS is a module: it is not in the
    # PGSD kernel and not in GENERIC either. The stock loader preloads it
    # from loader.conf; pgsd-loader cannot read loader.conf and could not
    # preload anything at all, so the kernel booted, could not mount root,
    # dropped to an invisible mountroot> prompt, and showed a blank screen
    # (campaign finding F15).
    #
    # It is in the slot rather than a side file because once the loader is
    # responsible for preloading a module, there is no meaningful
    # distinction between the kernel image and the module: both execute
    # with kernel privilege before the system is up. Attesting one but not
    # the other would weaken the trust model for almost no gain. deploy.sh
    # constructs a complete boot slot; the loader consumes a complete boot
    # slot; there are no external dependencies and no special cases.
    #
    # Fail CLOSED. A missing module is a blank screen on a machine with no
    # console, discovered after a reboot. Refuse to stage instead.
    PGSD_ZFS_KO="${PGSD_ZFS_KO:-/boot/kernel/zfs.ko}"
    if [ ! -f "$PGSD_ZFS_KO" ]; then
        echo "deploy.sh: FATAL: $PGSD_ZFS_KO not found." >&2
        echo "deploy.sh: The root filesystem is ZFS, ZFS is a module, and" >&2
        echo "deploy.sh: pgsd-loader must preload it (ADR 0006). Without it" >&2
        echo "deploy.sh: the kernel cannot mount root and the screen stays" >&2
        echo "deploy.sh: dark. Refusing to stage a slot that cannot boot." >&2
        exit 1
    fi
    cp "$PGSD_ZFS_KO" "$(esp EFI/pgsd/bas/slots/1/zfs.ko)"
    zsum=$(hashf "$(esp EFI/pgsd/bas/slots/1/zfs.ko)")
    zsize=$(wc -c < "$(esp EFI/pgsd/bas/slots/1/zfs.ko)" | tr -d ' ')

    {
        echo "PGSD-BAS-MANIFEST 1"
        echo "$ksum $ksize kernel"
        echo "$zsum $zsize zfs.ko"
    } > "$(esp EFI/pgsd/bas/slots/1/manifest)"
    "$B/bas-selector" init "$(esp EFI/pgsd/bas/selector)" >/dev/null 2>&1 || true
    "$B/bas-selector" commit "$(esp EFI/pgsd/bas/selector)" 1 \
        "$(hashf "$(esp EFI/pgsd/bas/slots/1/manifest)")" >/dev/null
    echo "deploy.sh: staged armed transfer loader and BAS slot 1 into $ESP_MNT"
    echo "deploy.sh:   kernel  $ksize bytes"
    echo "deploy.sh:   zfs.ko  $zsize bytes  (preloaded; ADR 0006)"
    echo "deploy.sh: next: sudo sh deploy.sh arm-once"
}

cmd_arm_once() {
    # Enforced deprecation (ADR 0005 Decision 6). Metal arming is
    # retired after F7 reproduced twice on this bench's firmware. The
    # header explains why; this guard makes the retirement more than a
    # comment so the bench cannot be armed by habit or by skipping the
    # header. Overriding requires deliberately setting the variable
    # below, which is itself a signal to re-read Decision 6 first.
    if [ "${PGSD_DEPLOY_ACK:-}" != "i-have-read-adr-0005-decision-7" ]; then
        echo "deploy.sh: arm-once requires acknowledging ADR 0005 Decision 7." >&2
        echo "deploy.sh:" >&2
        echo "deploy.sh: Metal arming was retired (Decision 6) after the" >&2
        echo "deploy.sh: transfer failed twice on this bench, each costing a" >&2
        echo "deploy.sh: full FreeBSD reinstall. Decision 7 unblocks it: three" >&2
        echo "deploy.sh: source-identified defects in the EFI handoff (F7 boot" >&2
        echo "deploy.sh: environment, F9 EFI runtime map, F8 firmware calls in" >&2
        echo "deploy.sh: the exit window) have been corrected against the" >&2
        echo "deploy.sh: reference loader and verified in emulation." >&2
        echo "deploy.sh:" >&2
        echo "deploy.sh: This does NOT prove the metal transfer will boot." >&2
        echo "deploy.sh: A third reinstall remains a possible outcome." >&2
        echo "deploy.sh:" >&2
        echo "deploy.sh: If you accept that, set:" >&2
        echo "deploy.sh:   PGSD_DEPLOY_ACK=i-have-read-adr-0005-decision-7" >&2
        exit 1
    fi
    need_root arm-once
    if [ -f "$SAVED_ORDER_FILE" ]; then
        echo "deploy.sh: a saved BootOrder already exists ($SAVED_ORDER_FILE)." >&2
        echo "deploy.sh: run 'recover' first; refusing to arm twice without recovery." >&2
        exit 1
    fi
    # F11: point the boot entry at the armed loader directly, NOT at
    # BOOTX64.EFI, which must stay stock so the Option picker and an
    # NVRAM reset remain real recovery routes.
    loader_path="$(esp EFI/pgsd/pgsd-loader-boot.efi)"
    [ -f "$loader_path" ] || { echo "deploy.sh: armed loader not found ($loader_path); run stage first" >&2; exit 1; }

    # Refuse a stale artifact. An armed cycle exists to test what you just
    # built; arming last week's ESP binary tests nothing and reads as a
    # result. stage failing and arm proceeding anyway is how that happens.
    built="$B/pgsd-loader.efi"
    if [ -f "$built" ] && ! cmp -s "$built" "$loader_path"; then
        echo "deploy.sh: the staged loader does NOT match the built one." >&2
        echo "deploy.sh: Run stage first, or you will be testing a stale binary." >&2
        exit 1
    fi

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

# Make pgsd-loader the PERMANENT boot path.
#
# Distinct from arm-once in three ways, and each difference is the point:
#
#   1. No saved BootOrder. There is nothing to restore, because this is
#      not a one-shot experiment; it is the boot path.
#   2. A different entry label, so recover (which reaps by label) never
#      removes it. recover runs after every armed cycle, and a recover
#      that quietly reverted the machine to the stock loader would be a
#      trap.
#   3. The stock FreeBSD entry is LEFT IN THE ORDER, behind ours.
#
# That third point is what makes this safe rather than reckless. The
# resulting order is:
#
#     BootOrder: <pgsd>, 0000, ...
#                  ^       ^
#           pgsd-loader   stock FreeBSD, as fallback
#
# If pgsd-loader fails to boot, the firmware falls through to the stock
# loader and the machine comes up. A loader regression is then
# self-healing rather than a brick, which is STRICTLY SAFER than an armed
# one-shot cycle, where recover is mandatory and must be run from a
# machine that booted.
#
# The Option-key escape hatch also survives, because \EFI\BOOT\BOOTX64.EFI
# stays stock (F11): stage does not touch it.
cmd_arm_persistent() {
    if [ "${PGSD_PERSIST_ACK:-}" != "i-want-pgsd-loader-as-the-permanent-boot-path" ]; then
        echo "deploy.sh: arm-persistent makes pgsd-loader the PERMANENT boot path." >&2
        echo "deploy.sh:" >&2
        echo "deploy.sh: Every boot will go through your loader, not just the" >&2
        echo "deploy.sh: ones you arm. The stock FreeBSD entry is left in the" >&2
        echo "deploy.sh: order BEHIND it, so a loader that fails to boot falls" >&2
        echo "deploy.sh: through to FreeBSD and the machine still comes up." >&2
        echo "deploy.sh: The Option-key picker also still reaches the stock" >&2
        echo "deploy.sh: loader, because BOOTX64.EFI is untouched (F11)." >&2
        echo "deploy.sh:" >&2
        echo "deploy.sh: What this costs: a loader regression (a bad kernel, a" >&2
        echo "deploy.sh: stale ESP artifact, a zfs.ko that will not lay out)" >&2
        echo "deploy.sh: now affects EVERY boot rather than one you chose. The" >&2
        echo "deploy.sh: fallback makes that recoverable, not invisible." >&2
        echo "deploy.sh:" >&2
        echo "deploy.sh: Undo with: sudo sh deploy.sh disarm-persistent" >&2
        echo "deploy.sh:" >&2
        echo "deploy.sh: If you accept that, set:" >&2
        echo "deploy.sh:   PGSD_PERSIST_ACK=i-want-pgsd-loader-as-the-permanent-boot-path" >&2
        exit 1
    fi
    need_root arm-persistent

    loader_path="$(esp EFI/pgsd/pgsd-loader-boot.efi)"
    [ -f "$loader_path" ] || {
        echo "deploy.sh: armed loader not found ($loader_path); run stage first" >&2
        exit 1
    }

    # Refuse a STALE artifact.
    #
    # The staged loader existing is not the same as the staged loader
    # being the one you just built. This bit immediately: `stage` failed
    # (the loader had not been built), and arm-persistent happily armed
    # the previous cycle's ESP binary, making a stale artifact the
    # machine's PERMANENT boot path. For a one-shot that is survivable.
    # For the permanent path it is not: you would boot, every day, a
    # loader nobody chose.
    built="$B/pgsd-loader.efi"
    if [ ! -f "$built" ]; then
        echo "deploy.sh: no built loader ($built)." >&2
        echo "deploy.sh: Build it, then stage, then arm. Refusing to make an" >&2
        echo "deploy.sh: unverifiable ESP artifact the permanent boot path." >&2
        exit 1
    fi
    if ! cmp -s "$built" "$loader_path"; then
        echo "deploy.sh: the staged loader does NOT match the built one." >&2
        echo "deploy.sh:   built:  $built" >&2
        echo "deploy.sh:   staged: $loader_path" >&2
        echo "deploy.sh: Run stage first. Refusing to make a stale artifact the" >&2
        echo "deploy.sh: permanent boot path." >&2
        exit 1
    fi

    # Refuse to stack duplicates. Re-running this must be idempotent, not
    # a way to accumulate boot entries.
    if efibootmgr | grep -qF "$PERSIST_LABEL"; then
        echo "deploy.sh: already persistent; nothing to do."
        echo "deploy.sh: (disarm-persistent to revert to the stock loader)"
        return 0
    fi

    cur=$(efibootmgr | awk -F': ' '/BootOrder/{print $2}')
    [ -n "$cur" ] || { echo "deploy.sh: could not read current BootOrder" >&2; exit 1; }

    # PGSD_PERSIST_PURE=1 removes the FreeBSD entries from the order,
    # leaving pgsd-loader as the ONLY boot entry.
    #
    # The default keeps them behind ours as an automatic fallback. Pure
    # mode is a deliberate operator decision, and the reasoning is
    # recorded rather than assumed: the FreeBSD loader in the boot order
    # is a temporary crutch standing in for infrastructure that ADR 0001
    # already specifies (the OE/RE/ME environment-selection model, L1),
    # and which pgsd-loader will provide. Declining to depend on a
    # component you are replacing is not the same as dropping recovery.
    #
    # What pure mode costs, stated plainly: a loader regression (a bad
    # kernel, a stale ESP artifact, a zfs.ko that will not lay out) no
    # longer falls through to a machine that boots. Recovery becomes
    # MANUAL: hold Option, select the disk, and the firmware boots
    # \EFI\BOOT\BOOTX64.EFI, which stage deliberately leaves stock (F11).
    # That path is real and has been exercised, but it requires a human at
    # the machine.
    #
    # Until OE/RE/ME lands, pure mode means the operator IS the recovery
    # path.
    create_out=$(efibootmgr -c -a -p -l "$loader_path" -L "$PERSIST_LABEL" 2>&1)
    bn=$(printf '%s\n' "$create_out" | while IFS= read -r line; do
        for tok in $line; do
            case "$tok" in
                Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]|Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]\*)
                    t=${tok#Boot}; t=${t%\*}; printf '%s\n' "$t"; break ;;
            esac
        done
    done | head -1)

    if [ -z "$bn" ]; then
        echo "deploy.sh: could not determine the new boot entry number" >&2
        exit 1
    fi

    if [ "${PGSD_PERSIST_PURE:-0}" = "1" ]; then
        neworder="$bn"
    else
        neworder="$bn,$cur"
    fi

    if ! efibootmgr -o "$neworder" >/dev/null 2>&1; then
        echo "deploy.sh: could not set the boot order; removing the entry" >&2
        efibootmgr -B -b "$bn" >/dev/null 2>&1 || true
        exit 1
    fi

    echo "deploy.sh: pgsd-loader is now the PERMANENT boot path."
    echo "deploy.sh:   BootOrder: $neworder"
    echo "deploy.sh:   Boot$bn  = pgsd-loader"
    if [ "${PGSD_PERSIST_PURE:-0}" = "1" ]; then
        echo "deploy.sh:   PURE: no FreeBSD entry in the order."
        echo ""
        echo "  pgsd-loader is the only boot entry. If it fails, the firmware"
        echo "  has nothing to fall through to: recovery is MANUAL. Hold"
        echo "  Option at power-on, select the disk, and the firmware boots"
        echo "  the stock loader from the ESP, which stage leaves untouched."
        echo ""
        echo "  Until the OE/RE/ME environment model lands (ADR 0001, L1),"
        echo "  you are the recovery path."
    else
        echo "deploy.sh:   $cur = the previous order, kept as FALLBACK"
        echo ""
        echo "  Every boot goes through your loader. If it fails, the firmware"
        echo "  falls through to the entries behind it and the machine still"
        echo "  comes up."
    fi
    echo ""
    echo "  Revert with: sudo sh deploy.sh disarm-persistent"
}

# Revert to the stock boot path.
cmd_disarm_persistent() {
    need_root disarm-persistent

    efibootmgr | while IFS= read -r line; do
        case "$line" in
            *"$PERSIST_LABEL"*)
                set -- $line
                b=$1; b=${b#Boot}; b=${b%\*}
                efibootmgr -B -b "$b" >/dev/null 2>&1 || true
                echo "deploy.sh: removed Boot$b (persistent pgsd-loader)" ;;
        esac
    done

    if efibootmgr | grep -qF "$PERSIST_LABEL"; then
        echo "deploy.sh: WARNING: the persistent entry is still present." >&2
        echo "deploy.sh: Remove it by hand: efibootmgr -B -b <num>" >&2
        exit 1
    fi

    # In PURE mode the persistent entry was the ONLY one in the order, so
    # removing it leaves an EMPTY BootOrder and a machine the firmware has
    # no instruction to boot. Put a FreeBSD entry back.
    #
    # This is not a repudiation of pure mode. It is disarm doing its job:
    # its whole purpose is to return the bench to a bootable stock path,
    # and it cannot do that by leaving the order empty.
    remaining=$(efibootmgr | awk -F': ' '/BootOrder/{print $2}')
    if [ -z "$remaining" ]; then
        # Find a FreeBSD entry that still EXISTS (pure mode removed them
        # from the order, not from NVRAM).
        # NOTE the pattern. Real efibootmgr prints entries with a LEADING
        # SPACE (" Boot0008* FreeBSD"), so an anchored /^Boot/ never
        # matches. The first version used one, found no FreeBSD entry, and
        # left the operator with an EMPTY BootOrder on a machine that then
        # had nothing to boot. Match anywhere on the line.
        fb=$(efibootmgr | awk '/Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]\*? / && /FreeBSD/ {
                 for (i = 1; i <= NF; i++) {
                     if ($i ~ /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]\*?$/) {
                         e = $i; sub(/^Boot/, "", e); sub(/\*$/, "", e);
                         print e; exit
                     }
                 }
             }')
        if [ -n "$fb" ]; then
            efibootmgr -o "$fb" >/dev/null 2>&1 && \
                echo "deploy.sh: BootOrder was empty; restored Boot$fb (FreeBSD)"
        else
            echo "deploy.sh: WARNING: BootOrder is EMPTY and no FreeBSD entry" >&2
            echo "deploy.sh: was found. The firmware has nothing to boot." >&2
            echo "deploy.sh: Recover with the Option key, then recreate an entry:" >&2
            echo "deploy.sh:   efibootmgr -c -a -l /boot/efi/efi/freebsd/loader.efi -L FreeBSD" >&2
            exit 1
        fi
    fi

    echo "deploy.sh: disarmed; the bench is back on its stock boot path."
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

    # Restore the firmware-fallback loader.
    #
    # This is the half that actually saves the machine, and it was
    # missing. recover restored NVRAM and left \EFI\BOOT\BOOTX64.EFI
    # overwritten with the armed launcher, so the ESP stayed armed even
    # after a "successful" recover, and an NVRAM reset would boot the
    # failing transfer instead of recovering from it.
    #
    # Restoring this is what makes the Option-Cmd-P-R escape hatch real.
    if [ -f "$(esp $BOOTX64_BACKUP)" ]; then
        if cp "$(esp $BOOTX64_BACKUP)" "$(esp EFI/BOOT/BOOTX64.EFI)"; then
            rm -f "$(esp $BOOTX64_BACKUP)"
            echo "deploy.sh: restored the firmware-fallback loader (BOOTX64.EFI)"
        else
            echo "deploy.sh: WARNING: could not restore BOOTX64.EFI." >&2
            echo "deploy.sh: The ESP is STILL ARMED: an NVRAM reset would boot" >&2
            echo "deploy.sh: the transfer. Restore it by hand from:" >&2
            echo "deploy.sh:   $(esp $BOOTX64_BACKUP)" >&2
        fi
    elif [ -f "$(esp EFI/BOOT/BOOTX64.EFI.pgsd-none)" ]; then
        # There was no BOOTX64.EFI before we staged. Remove ours rather
        # than leave an armed fallback path behind.
        rm -f "$(esp EFI/BOOT/BOOTX64.EFI)"
        rm -f "$(esp EFI/BOOT/BOOTX64.EFI.pgsd-none)"
        echo "deploy.sh: removed our BOOTX64.EFI (there was none before staging)"
    else
        echo "deploy.sh: no firmware-fallback backup found (never staged, or"
        echo "deploy.sh: already restored). Check with: status"
    fi

    echo "deploy.sh: recover complete; bench is on its normal boot path."
}

cmd_readback() {
    # Read-only; root only needed if efivar requires it.
    echo "== boot verdict (last marker before the jump) =="
    if efivar --print "$PGSD_GUID-PgsdBasVerdict" 2>/dev/null; then
        :
    else
        echo "deploy.sh: could not read PgsdBasVerdict (try sudo, or no armed cycle has run)" >&2
    fi

    # ADR 0006: the module-preload outcome, in its own variable.
    #
    # PgsdBasVerdict is overwritten by every marker, so it only ever holds
    # the last one (MARK_VMAP_ATTEMPT on every armed boot so far). The
    # module outcome was printed to a UEFI console on a machine whose
    # screen goes dark, and recorded nowhere: evidence produced into a
    # channel nobody can read, which is a mistake this campaign has made
    # more than once. This variable survives.
    echo ""
    echo "== module preload (ADR 0006) =="
    if efivar --print "$PGSD_GUID-PgsdModules" 2>/dev/null; then
        :
    else
        echo "  (not set: no armed cycle has run since module preloading landed,"
        echo "   or the loader did not reach the module read)"
    fi
}

cmd_status() {
    echo "== BootOrder =="
    efibootmgr | grep -E 'BootOrder|BootCurrent' || true
    # The PERSISTENT entry, reported separately and first, because it is
    # the more consequential state: it means every boot goes through
    # pgsd-loader, not just an armed one. status not reporting a state is
    # how the ESP stayed armed through two bricks (F10); the same mistake
    # is not repeated here.
    echo "== permanent boot path =="
    if efibootmgr | grep -F "$PERSIST_LABEL"; then
        echo "  pgsd-loader is the PERMANENT boot path."

        # Report the fallback HONESTLY, by reading the order rather than
        # assuming. The first version hardcoded "the stock entries remain
        # behind it as fallback", which is FALSE in pure mode. A status
        # that reports a safety net you do not have is worse than no
        # status at all: it is the F10 failure (the ESP stayed armed
        # through two bricks because status only reported NVRAM), repeated
        # in the tool built to avoid it.
        _order=$(efibootmgr | awk -F': ' '/BootOrder/{print $2}')
        _behind=$(printf '%s' "$_order" | cut -s -d, -f2-)
        if [ -n "$_behind" ]; then
            echo "  Fallback: $_behind (the firmware falls through if we fail)"
        else
            echo "  NO FALLBACK: pgsd-loader is the only entry in the order."
            echo "  If it fails to boot, recovery is MANUAL: hold Option at"
            echo "  power-on and select the disk. Until OE/RE/ME lands"
            echo "  (ADR 0001, L1), you are the recovery path."
        fi
        echo "  Revert with: disarm-persistent"
    else
        echo "(not persistent: the stock loader boots this machine)"
    fi

    echo "== armed entry (one-shot) =="
    efibootmgr | grep -F "$ENTRY_LABEL" || echo "(none)"
    echo "== pending recovery =="
    if [ -f "$SAVED_ORDER_FILE" ]; then
        echo "YES: saved order $(cat "$SAVED_ORDER_FILE") -> run recover"
    else
        echo "no"
    fi

    # The ESP's firmware-fallback path, reported separately from NVRAM
    # because they are armed and disarmed independently and because this
    # is the one that decides whether an NVRAM reset recovers the machine
    # or re-arms it. Reporting only NVRAM is how the ESP stayed armed
    # through two bricks without anyone noticing.
    echo "== ESP firmware-fallback (\\EFI\\BOOT\\BOOTX64.EFI) =="
    if [ -f "$(esp $BOOTX64_BACKUP)" ] || [ -f "$(esp EFI/BOOT/BOOTX64.EFI.pgsd-none)" ]; then
        echo "ARMED: BOOTX64.EFI is the pgsd boot-launcher."
        echo "       An NVRAM reset would boot the TRANSFER, not recover."
        echo "       Run recover to restore it."
    elif [ -f "$(esp EFI/BOOT/BOOTX64.EFI)" ]; then
        echo "not armed: BOOTX64.EFI present and not staged by us."
    else
        echo "not armed: no BOOTX64.EFI present."
    fi
}

case "${1:-}" in
    stage)              cmd_stage ;;
    arm-once)           cmd_arm_once ;;
    arm-persistent)     cmd_arm_persistent ;;
    disarm-persistent)  cmd_disarm_persistent ;;
    recover)            cmd_recover ;;
    readback)           cmd_readback ;;
    status)             cmd_status ;;
    *)
        echo "usage: sh deploy.sh <stage|arm-once|recover|readback|status>" >&2
        echo "  see the header for the one-cycle metal attempt sequence" >&2
        exit 2
        ;;
esac
