#!/bin/sh
# bas-provision.sh: create the BAS layout and the preallocated
# selector (BOOT-ARTIFACT-STORE 0.3 sections 3 and 7.1). Idempotent.
# Usage: sh bas-provision.sh [ESP-mountpoint]   (default /boot/efi)
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ESP="${1:-/boot/efi}"
BAS="$ESP/EFI/pgsd/bas"
SEL="$BAS/selector"
TOOL="$SCRIPT_DIR/../zig-out/bin/bas-selector"
[ -x "$TOOL" ] || { echo "bas-provision: build tools first (sh build.sh tools)" >&2; exit 1; }
[ -d "$ESP/EFI" ] || { echo "bas-provision: $ESP does not look like a mounted ESP" >&2; exit 1; }

mkdir -p "$BAS/slots"
if [ -f "$SEL" ]; then
    sz=$(wc -c < "$SEL" | tr -d ' ')
    [ "$sz" -eq 1024 ] || { echo "bas-provision: selector exists with wrong size $sz" >&2; exit 1; }
    echo "present  $SEL"
else
    "$TOOL" init "$SEL"
fi
sync
echo "bas-provision: done ($BAS)"
