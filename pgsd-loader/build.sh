#!/bin/sh
# build.sh: canonical pgsd-loader build (ADR 0003 criterion 1).
#
# Pins SOURCE_DATE_EPOCH so the PE COFF TimeDateStamp and its debug
# directory duplicate are constant, making clean-cache builds
# byte-identical (bench finding F4: those two wall-clock stamps were
# the only nondeterminism in the binary). Byte-reproducibility is
# what content-addressed deployment and the future manifest and
# signing story stand on. Uses the vendored toolchain.
#
# Usage: sh build.sh [zig build args...]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ZIG="$SCRIPT_DIR/../sdk/zig/current/zig"
[ -x "$ZIG" ] || ZIG=zig
cd "$SCRIPT_DIR"
exec env SOURCE_DATE_EPOCH=0 "$ZIG" build "$@"
