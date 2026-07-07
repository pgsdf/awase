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
DEPLOY_LOG="/var/log/pgsd-deploy.log"

# Machine-kept deploy record (bench lesson: operator recall is not
# an evidence source). Each run appends what was deployed and what
# it hashed to, so binary-provenance questions are answerable from
# the log rather than from memory.
dlog() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$DEPLOY_LOG" 2>/dev/null || true
}
STOCK_REL="EFI/freebsd/loader.efi"
PGSD_REL="EFI/pgsd/pgsd-loader.efi"
MNT="/tmp/pgsd-deploy-esp.$$"

[ "$(id -u)" -eq 0 ] || { echo "deploy.sh: run as root" >&2; exit 1; }
[ -f "$LOADER" ] || {
    echo "deploy.sh: $LOADER missing; run sh build.sh first" >&2
    exit 1
}
LOADER_SHA=$(sha256 -q "$LOADER" 2>/dev/null || sha256sum "$LOADER" | awk '{print $1}')
dlog "run start loader_sha256=$LOADER_SHA"

# Enumerate ESP partitions (gpart type "efi") as provider names.
esps=$(gpart show -p 2>/dev/null | awk '$4 == "efi" { print $3 }')
[ -n "$esps" ] || { echo "deploy.sh: no ESP partitions found" >&2; exit 1; }

mkdir -p "$MNT"
cleanup() { umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null; }
trap cleanup EXIT INT TERM

# Parse efibootmgr entry lines robustly. The first field carries
# decorations that shift between boots: a "+" prefix on the
# BootNext/current entry and a "*" suffix on active ones, so the
# field may read "+Boot0003*", " Boot0002", or "Boot0003*". Extract
# the 4-hex-digit number positionally and compare the label exactly
# (so PGSD never matches PGSD-fallback). Field-one string surgery is
# what produced the Boot+Boot0003 corruption on the bench.

# entry_all LABEL: print every Boot number whose label is exactly
# LABEL, one per line (duplicates included, for reaping).
entry_all() {
    efibootmgr | awk -v l="$1" '
        {
            if (match($0, /Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][*+]? /)) {
                num = substr($0, RSTART + 4, 4)
                lbl = substr($0, RSTART + RLENGTH)
                sub(/^[ \t]+/, "", lbl)
                sub(/[ \t\r]+$/, "", lbl)
                if (lbl == l) print num
            }
        }'
}

# entry_num LABEL: the first such number, empty if none.
entry_num() {
    entry_all "$1" | head -n 1
}

# all_entry_nums: every existing Boot entry number, any label.
all_entry_nums() {
    efibootmgr | awk '
        {
            if (match($0, /Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][*+]? /))
                print substr($0, RSTART + 4, 4)
        }'
}

# reap_duplicates LABEL: delete all but the first entry with LABEL.
# Self-healing for boot orders damaged by the parser defect above:
# a duplicate created by a bad lookup is removed on the next run.
reap_duplicates() {
    for n in $(entry_all "$1" | awk 'NR > 1'); do
        if efibootmgr -B -b "$n" >/dev/null 2>&1; then
            echo "  reaped   duplicate $1 (Boot$n)"
            changed=1
        fi
    done
}

changed=0
idx=0
for esp in $esps; do
    idx=$((idx + 1))
    suffix=""
    [ "$(echo "$esps" | wc -w)" -gt 1 ] && suffix="-$idx"

    echo "=== ESP /dev/$esp ==="

    # Reuse an existing mount (e.g. /boot/efi from fstab): a second
    # open of the same provider fails, and fighting the system's
    # own mount is exactly the fragility this script exists to
    # retire. Mount ourselves only when nothing else has, and
    # unmount only what we mounted.
    #
    # The member may be mounted under a GEOM alias rather than the
    # raw partition name gpart reports: on the bench, gpart says
    # ada0p1 while fstab mounts /dev/gpt/efiboot0, the GPT label of
    # the same partition, and GEOM withers the other aliases while
    # one is open (the raw device then fails with EPERM). Resolve
    # msdosfs mounts through glabel to the underlying provider
    # before concluding the member is unmounted.
    existing=""
    while read -r mdev mpoint mtype _; do
        [ "$mtype" = "msdosfs" ] || continue
        dev=${mdev#/dev/}
        if [ "$dev" = "$esp" ]; then existing="$mpoint"; break; fi
        real=$(glabel status -s 2>/dev/null | awk -v l="$dev" '$1 == l { print $3; exit }')
        if [ "$real" = "$esp" ]; then existing="$mpoint"; break; fi
    done << MOUNTS
$(mount -p)
MOUNTS
    if [ -n "$existing" ]; then
        ESPDIR="$existing"
        we_mounted=0
        echo "  mounted  at $ESPDIR (existing; reusing)"
    else
        mount_msdosfs "/dev/$esp" "$MNT" || {
            echo "deploy.sh: cannot mount /dev/$esp; aborting" >&2
            exit 1
        }
        ESPDIR="$MNT"
        we_mounted=1
    fi

    # 1. Fallback invariant, verified FIRST. The stock loader must be
    #    present and readable, and its boot entry must exist, before
    #    the primary path changes in any way.
    if [ ! -r "$ESPDIR/$STOCK_REL" ]; then
        echo "deploy.sh: fallback $STOCK_REL missing on /dev/$esp; ABORTING" >&2
        echo "deploy.sh: no changes made to this member or the boot order" >&2
        exit 1
    fi
    fb_label="PGSD-fallback$suffix"
    reap_duplicates "$fb_label"
    fb=$(entry_num "$fb_label")
    if [ -z "$fb" ]; then
        efibootmgr -c -l "$ESPDIR/$STOCK_REL" -L "$fb_label" >/dev/null || {
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
    mkdir -p "$ESPDIR/EFI/pgsd"
    if [ -f "$ESPDIR/$PGSD_REL" ] && cmp -s "$LOADER" "$ESPDIR/$PGSD_REL"; then
        echo "  unchanged $PGSD_REL"
        dlog "esp=$esp unchanged sha256=$LOADER_SHA"
    else
        prev="none"
        [ -f "$ESPDIR/$PGSD_REL" ] && prev=$(sha256 -q "$ESPDIR/$PGSD_REL" 2>/dev/null || sha256sum "$ESPDIR/$PGSD_REL" | awk '{print $1}')
        cp "$LOADER" "$ESPDIR/$PGSD_REL.new"
        mv "$ESPDIR/$PGSD_REL.new" "$ESPDIR/$PGSD_REL"
        # Verify after publish (bench finding F8): a publish is not a
        # publish until the installed bytes hash correctly. sync(8)
        # pushes dirty msdosfs buffers toward the disk so an
        # immediately following poweroff has the smallest possible
        # window; the read-back catches everything short of that.
        sync
        got=$(sha256 -q "$ESPDIR/$PGSD_REL" 2>/dev/null || sha256sum "$ESPDIR/$PGSD_REL" | awk '{print $1}')
        if [ "$got" != "$LOADER_SHA" ]; then
            echo "deploy.sh: PUBLISH VERIFICATION FAILED on /dev/$esp" >&2
            echo "deploy.sh: expected $LOADER_SHA" >&2
            echo "deploy.sh: read back $got" >&2
            dlog "esp=$esp publish_verify_FAILED expected=$LOADER_SHA got=$got"
            exit 1
        fi
        echo "  published $PGSD_REL (verified)"
        dlog "esp=$esp published sha256=$LOADER_SHA replaced=$prev verified=yes"
        changed=1
    fi

    # 3. Primary entry, only after 1 and 2 succeeded on this member.
    pr_label="PGSD$suffix"
    reap_duplicates "$pr_label"
    pr=$(entry_num "$pr_label")
    if [ -z "$pr" ]; then
        efibootmgr -c -l "$ESPDIR/$PGSD_REL" -L "$pr_label" >/dev/null || {
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

    [ "$we_mounted" -eq 1 ] && umount "$MNT"
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
valid=",$(all_entry_nums | tr '\n' ',')"

# Desired order: our entries first, then every other EXISTING entry
# in current relative order. Dangling tokens (entries deleted but
# still referenced, shown as MISSING by efibootmgr -v) are dropped,
# and repeats are de-duplicated. Literal membership via index(),
# never regex match: entry tokens must not be interpreted as
# patterns. Compare the FULL order, not a prefix: an order can
# begin correctly while carrying a corrupt tail, and healing must
# own the whole string (bench finding F5).
rest=$(echo "$cur" | awk -v w="$want" -v v="$valid" 'BEGIN { FS="," }
    { n = split($0, a, ",")
      for (i = 1; i <= n; i++) {
          if (a[i] == "") continue
          if (index("," w ",", "," a[i] ",") > 0) continue
          if (index(v, "," a[i] ",") == 0) continue
          if (seen[a[i]]++) continue
          printf ",%s", a[i]
      } }')
desired="$want$rest"
if [ "$cur" = "$desired" ]; then
    echo "boot order already $desired"
else
    if efibootmgr -o "$desired" >/dev/null; then
        echo "boot order set: $desired (was: $cur)"
        changed=1
    else
        echo "deploy.sh: could not set boot order; entries exist, order unchanged" >&2
        exit 1
    fi
fi

if [ "$changed" -eq 0 ]; then
    echo "deploy.sh: no-op (already deployed)"
    dlog "run end no-op"
else
    dlog "run end changed"
fi
echo "deploy.sh: done"
