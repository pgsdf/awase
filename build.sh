#!/bin/sh
# Awase build wrapper: runs zig build and tees output to a log file.
#
# Usage:
#   sh build.sh                    # build all subprojects
#   sh build.sh -Dx11=true         # pass flags to zig build
#   sh build.sh test               # run all test suites
#   sh build.sh --check            # verify dependencies only, do not build
#
# Log file: build-YYYYMMDD-HHMMSS.log in the Awase root directory.
# Symlink:  build-latest.log always points to the most recent log.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Every build path goes through the vendored, pinned toolchain. tools/zig
# resolves sdk/zig/current and bootstraps it on first use (tools/bootstrap.sh);
# the pinned version authority stays in tools/bootstrap.sh.
ZIG="$SCRIPT_DIR/tools/zig"

# Handle --check before setting up the log
if [ "${1:-}" = "--check" ]; then
    echo "=== UTF dependency check ==="
    OK=1
    if [ -x "$ZIG" ] && ZIG_VER=$("$ZIG" version 2>/dev/null | head -1) && [ -n "$ZIG_VER" ]; then
        echo "  ok  vendored zig $ZIG_VER (sdk/zig/current)"
    else
        echo "  MISSING  tools/zig could not provide a working compiler"
        echo "           (it bootstraps sdk/zig/current on first use; needs network)"
        OK=0
    fi
    if [ -f "$SCRIPT_DIR/.config" ]; then
        echo "  ok  .config found"
        cat "$SCRIPT_DIR/.config"
    else
        echo "  --  .config not found (run: sh configure.sh)"
    fi
    [ "$OK" -eq 1 ] && echo "All dependencies present." || echo "Missing dependencies."
    exit $((1 - OK))
fi
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$SCRIPT_DIR/build-${TIMESTAMP}.log"
LATEST="$SCRIPT_DIR/build-latest.log"

# Read configuration from .config if present and no args given
CONFIG="$SCRIPT_DIR/.config"
BUILD_FLAGS=""
if [ -f "$CONFIG" ] && [ $# -eq 0 ]; then
    . "$CONFIG"
    [ "${SEMADRAW_VULKAN:-false}"  = "true" ] && BUILD_FLAGS="$BUILD_FLAGS -Dvulkan=true"
    [ "${SEMADRAW_VULKAN:-false}"  = "false" ] && BUILD_FLAGS="$BUILD_FLAGS -Dvulkan=false"
    [ "${SEMADRAW_X11:-false}"     = "true" ] && BUILD_FLAGS="$BUILD_FLAGS -Dx11=true"
    [ "${SEMADRAW_WAYLAND:-false}" = "true" ] && BUILD_FLAGS="$BUILD_FLAGS -Dwayland=true"
    [ "${SEMADRAW_BSDINPUT:-false}" = "true" ] && BUILD_FLAGS="$BUILD_FLAGS -Dbsdinput=true"
    [ "${SEMADRAW_BSDINPUT:-false}" = "false" ] && BUILD_FLAGS="$BUILD_FLAGS -Dbsdinput=false"
fi

echo "Awase build, $(date)"
echo "Log: $LOG"
echo ""

# Run zig build, tee stdout+stderr to log file
{
    echo "=== Awase build ==="
    echo "Date:      $(date)"
    echo "Host:      $(uname -n)"
    echo "OS:        $(uname -sr)"
    echo "Zig:       $("$ZIG" version 2>/dev/null || echo 'not found')"
    echo "Config:    ${CONFIG} ($([ -f "$CONFIG" ] && echo found || echo not found))"
    echo "Flags:     ${BUILD_FLAGS:-none}"
    echo "Args:      $*"
    echo ""

    cd "$SCRIPT_DIR"

    # Build semasound, semainput, chronofs without flags
    for sub in semasound semainput chronofs; do
        echo "--- Building $sub ---"
        "$ZIG" build --build-file "$sub/build.zig" 2>&1 || exit 1
    done

    # Build semadraw with backend flags
    echo "--- Building semadraw ---"
    echo "DRAWFS_DRM:${DRAWFS_DRM:-false}"
    ( cd semadraw && "$ZIG" build $BUILD_FLAGS "$@" 2>&1 ) || exit 1

    # Build pgsd-loader through its own build.sh, which is the
    # canonical byte-reproducible path (SOURCE_DATE_EPOCH pinned
    # there, single home for the pin; ADR 0003 criterion 1).
    echo "--- Building pgsd-loader ---"
    sh pgsd-loader/build.sh 2>&1 || exit 1
    STATUS=0

    echo ""
    if [ $STATUS -eq 0 ]; then
        echo "=== BUILD SUCCEEDED ==="
    else
        echo "=== BUILD FAILED (exit $STATUS) ==="
    fi
    exit $STATUS
} | tee "$LOG"

STATUS=${PIPESTATUS:-$?}

# Update symlink to latest log
ln -sf "$LOG" "$LATEST"

echo ""
echo "Full log: $LOG"
exit $STATUS
