#!/bin/sh
# bas-publish.sh: publish an artifact set into a BAS slot per the
# section 7.4 protocol of BOOT-ARTIFACT-STORE 0.3. The slot must
# not be the active one (invariant I1: only the selector's commit
# changes reachability; live state is never written).
#
# Manifest v1 (mechanism layer): first line "PGSD-BAS-MANIFEST 1",
# then one line per artifact, "<sha256> <size> <name>", sorted by
# name, newline-terminated. The selector's manifest hash is the
# SHA-256 of this file's bytes.
#
# Usage: sh bas-publish.sh [-e ESP] <slot> <kernel> [module ...]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ESP="/boot/efi"
[ "${1:-}" = "-e" ] && { ESP="$2"; shift 2; }
[ $# -ge 2 ] || { echo "usage: bas-publish.sh [-e ESP] <slot> <kernel> [module ...]" >&2; exit 1; }
SLOT="$1"; shift
BAS="$ESP/EFI/pgsd/bas"
SEL="$BAS/selector"
TOOL="$SCRIPT_DIR/../zig-out/bin/bas-selector"
LOG="/var/log/pgsd-bas.log"
[ -x "$TOOL" ] || { echo "bas-publish: build tools first (sh build.sh tools)" >&2; exit 1; }
[ -f "$SEL" ] || { echo "bas-publish: no selector; run bas-provision.sh first" >&2; exit 1; }

hashf() { sha256 -q "$1" 2>/dev/null || sha256sum "$1" | awk '{print $1}'; }
# wc -c, not stat: GNU stat treats -f as filesystem mode and exits
# zero with garbage, so a bsd-or-gnu stat fallback silently poisons
# the manifest. wc -c is POSIX and identical everywhere.
sizef() { wc -c < "$1" | tr -d ' '; }
blog()  { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG" 2>/dev/null || true; }

# Refuse the active slot (I1).
active=$("$TOOL" show "$SEL" | awk '/^winner: gen/ { sub("slot=", "", $3); print $3 }')
if [ -n "$active" ] && [ "$active" = "$SLOT" ]; then
    echo "bas-publish: slot $SLOT is the ACTIVE slot; refusing (I1)" >&2
    exit 1
fi

SLOTDIR="$BAS/slots/$SLOT"
# A same-numbered non-active slot is by definition unreferenced:
# clearing it is GC, permitted at any time (section 9).
rm -rf "$SLOTDIR"
mkdir -p "$SLOTDIR"

# 7.4 steps 1 and 2: artifacts, then manifest.
names=""
for f in "$@"; do
    [ -f "$f" ] || { echo "bas-publish: no such artifact: $f" >&2; exit 1; }
    n=$(basename "$f")
    cp "$f" "$SLOTDIR/$n"
    names="$names $n"
done
MAN="$SLOTDIR/manifest"
{
    echo "PGSD-BAS-MANIFEST 1"
    for n in $(echo $names | tr ' ' '\n' | sort); do
        echo "$(hashf "$SLOTDIR/$n") $(sizef "$SLOTDIR/$n") $n"
    done
} > "$MAN"

# Step 3: durability before verification and commit (8.1/8.2).
sync

# Step 4: read back and verify every artifact against the manifest.
fail=0
while read -r h sz n; do
    [ "$h" = "PGSD-BAS-MANIFEST" ] && continue
    gh=$(hashf "$SLOTDIR/$n"); gs=$(sizef "$SLOTDIR/$n")
    if [ "$gh" != "$h" ] || [ "$gs" != "$sz" ]; then
        echo "bas-publish: VERIFY FAILED for $n" >&2
        blog "publish_verify_FAILED slot=$SLOT artifact=$n"
        fail=1
    fi
done < "$MAN"
[ "$fail" -eq 0 ] || exit 1
MSHA=$(hashf "$MAN")

# Steps 5 and 6: commit (tool fsyncs and post-verifies), then settle.
"$TOOL" commit "$SEL" "$SLOT" "$MSHA"
sync

# Step 7: success is only now reportable; record provenance.
blog "published slot=$SLOT manifest_sha256=$MSHA artifacts=$(echo $names | tr ' ' ',') prev_active=${active:-none}"
echo "bas-publish: slot $SLOT published and active (manifest $MSHA)"
echo "bas-publish: step 8 (GC) left to the operator for now; unreferenced slots are listed by: ls $BAS/slots"
