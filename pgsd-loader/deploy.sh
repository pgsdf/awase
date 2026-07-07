#!/bin/sh
# deploy.sh: stage L0 deployment (ADR 0003 Decisions 3 and 4).
#
# Deploys pgsd-loader.efi to every ESP on the machine and maintains
# the two firmware boot entries: the primary (pgsd-loader) and the
# fallback (stock loader.efi, untouched). The fallback invariant is
# mechanical here: the fallback is verified BEFORE anything changes,
# and a deploy that cannot verify it aborts without touching the
# boot order. Publication style writes (new file, then rename) per
# the ADR 0002 publication lifecycle. Idempotent: a second
# consecutive run is a no-op.
#
# The beginning of this subproject's absorption of
# pgsd-boot/deploy-loader.sh (parent ADR 0001 Decision 1).
#
# Usage: sudo sh deploy.sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOADER="$SCRIPT_DIR/zig-out/bin/pgsd-loader.efi"
STOCK_REL="EFI/freebsd/loader.efi"
PGSD_REL="EFI/pgsd/pgsd-loader.efi"
MNT="/tmp/pgsd-deploy-esp.$$"

[ "$(id -u)" -eq 0 ] || { echo "deploy.sh: run as root" >&2; exit 1; }
[ -f "$LOADER" ] || {
    echo "deploy.sh: $LOADER missing; run the vendored zig build first" >&2
    exit 1
}

# Enumerate ESP partitions (gpart type "efi") as provider names.
esps=$(gpart show -p 2>/dev/null | awk '$4 == "efi" { print $3 }')
[ -n "$esps" ] || { echo "deploy.sh: no ESP partitions found" >&2; exit 1; }

mkdir -p "$MNT"
cleanup() { umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null; }
trap cleanup EXIT INT TERM

# entry_num LABEL: print the Boot#### number for LABEL, empty if none.
entry_num() {
    efibootmgr | awk -v l="$1" '
        $0 ~ ("[ +*]" l "$") { sub("^Boot", "", $1); sub("[*+]$", "", $1);
                               print $1; exit }'
}

changed=0
idx=0
for esp in $esps; do
    idx=$((idx + 1))
    suffix=""
    [ "$(echo "$esps" | wc -w)" -gt 1 ] && suffix="-$idx"

    echo "=== ESP /dev/$esp ==="
    mount_msdosfs "/dev/$esp" "$MNT" || {
        echo "deploy.sh: cannot mount /dev/$esp; aborting" >&2
        exit 1
    }

    # 1. Fallback invariant, verified FIRST. The stock loader must be
    #    present and readable, and its boot entry must exist, before
    #    the primary path changes in any way.
    if [ ! -r "$MNT/$STOCK_REL" ]; then
        echo "deploy.sh: fallback $STOCK_REL missing on /dev/$esp; ABORTING" >&2
        echo "deploy.sh: no changes made to this member or the boot order" >&2
        exit 1
    fi
    fb_label="PGSD-fallback$suffix"
    fb=$(entry_num "$fb_label")
    if [ -z "$fb" ]; then
        efibootmgr -c -l "$MNT/$STOCK_REL" -L "$fb_label" >/dev/null || {
            echo "deploy.sh: cannot create fallback entry; ABORTING" >&2
            exit 1
        }
        fb=$(entry_num "$fb_label")
        [ -n "$fb" ] || { echo "deploy.sh: fallback entry not visible after create; ABORTING" >&2; exit 1; }
        echo "  created  $fb_label (Boot$fb)"
        changed=1
    else
        echo "  present  $fb_label (Boot$fb)"
    fi
    efibootmgr -a -b "$fb" >/dev/null 2>&1 || true

    # 2. Publication write of pgsd-loader.efi (skip when identical).
    mkdir -p "$MNT/EFI/pgsd"
    if [ -f "$MNT/$PGSD_REL" ] && cmp -s "$LOADER" "$MNT/$PGSD_REL"; then
        echo "  unchanged $PGSD_REL"
    else
        cp "$LOADER" "$MNT/$PGSD_REL.new"
        mv "$MNT/$PGSD_REL.new" "$MNT/$PGSD_REL"
        echo "  published $PGSD_REL"
        changed=1
    fi

    # 3. Primary entry, only after 1 and 2 succeeded on this member.
    pr_label="PGSD$suffix"
    pr=$(entry_num "$pr_label")
    if [ -z "$pr" ]; then
        efibootmgr -c -l "$MNT/$PGSD_REL" -L "$pr_label" >/dev/null || {
            echo "deploy.sh: cannot create primary entry; fallback remains default" >&2
            exit 1
        }
        pr=$(entry_num "$pr_label")
        echo "  created  $pr_label (Boot$pr)"
        changed=1
    else
        echo "  present  $pr_label (Boot$pr)"
    fi
    efibootmgr -a -b "$pr" >/dev/null 2>&1 || true

    umount "$MNT"
done

# 4. Boot order: primaries first, fallbacks after, existing entries
#    retained behind them. Only rewritten when it differs.
primaries=""
fallbacks=""
idx=0
for esp in $esps; do
    idx=$((idx + 1))
    suffix=""
    [ "$(echo "$esps" | wc -w)" -gt 1 ] && suffix="-$idx"
    p=$(entry_num "PGSD$suffix"); f=$(entry_num "PGSD-fallback$suffix")
    [ -n "$p" ] && primaries="$primaries $p"
    [ -n "$f" ] && fallbacks="$fallbacks $f"
done
want=$(echo $primaries $fallbacks | tr ' ' ',')
cur=$(efibootmgr | awk -F': ' '/^BootOrder/ { gsub(/ /, "", $2); print $2; exit }')
if [ "$cur" = "$want" ] || case "$cur" in "$want",*) true ;; *) false ;; esac; then
    echo "boot order already begins $want"
else
    # Desired entries first, everything else retained behind them.
    rest=$(echo "$cur" | awk -v w="$want" 'BEGIN { FS="," }
        { n = split($0, a, ",")
          for (i = 1; i <= n; i++)
              if (("," w ",") !~ ("," a[i] ",")) printf ",%s", a[i] }')
    if efibootmgr -o "$want$rest" >/dev/null; then
        echo "boot order set: $want$rest"
        changed=1
    else
        echo "deploy.sh: could not set boot order; entries exist, order unchanged" >&2
        exit 1
    fi
fi

[ "$changed" -eq 0 ] && echo "deploy.sh: no-op (already deployed)"
echo "deploy.sh: done"
