#!/bin/sh
# d-fixtures.sh: shared helpers for Stage D verification scripts.
# POSIX sh. Sourced by d-verify.sh.
#
# Stage D builds on Stage C: the publication regions, kthread,
# and module lifecycle from Stage C are inherited unchanged. Stage
# D adds focus routing (D.1, D.4), display-geometry awareness
# (D.2), the coordinate transform (D.3), and the publication
# enable tunable (D.5). The D.6 verification protocol exercises
# what is mechanically testable from a script: structural state
# of the publication regions, the new sysctls, the transform_active
# byte, and the enable-toggle transitions.
#
# Behavioural verification of focus routing (D.4) requires a live
# compositor or a synthetic focus writer; that is deferred to the
# manual checklist in inputfs/docs/D_VERIFICATION.md.
#
# This script sources c-fixtures.sh for the common module-load
# helpers and overrides the output-prefix functions so reports
# read [d6 ...] rather than [c5 ...]. D-specific helpers are
# defined below the override block.

set -u

# --- Configuration ---------------------------------------------------

# Where logs land. Caller may override before sourcing.
: "${D_LOGDIR:=$(pwd)}"

# Repo root, derived from this file's location.
D_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
D_REPO_ROOT=$(cd "${D_SCRIPT_DIR}/../.." && pwd)
D_MODULE_DIR="${D_REPO_ROOT}/sys/modules/inputfs"
D_INPUTDUMP="${D_REPO_ROOT}/zig-out/bin/inputdump"
D_DRAWFS_KO="${HOME}/Development/UTF/drawfs/sys/modules/drawfs/drawfs.ko"

# Publication region paths.
D_STATE_PATH="/var/run/sema/input/state"
D_EVENTS_PATH="/var/run/sema/input/events"

# State and events region byte offsets we test directly.
D_STATE_OFF_VALID=5
D_STATE_OFF_PTR_X=32
D_STATE_OFF_PTR_Y=36
D_STATE_OFF_TRANSFORM_ACTIVE=48
D_EVENTS_OFF_VALID=5

# D.6 counters.
D_PASS_COUNT=0
D_FAIL_COUNT=0

# --- Source c-fixtures for module-load helpers ----------------------

# c-fixtures.sh provides c_check_root, c_check_module_built,
# c_load_module, c_unload_module, etc. We use these directly.
# Then we override the c_check_pass / c_check_fail / c_say / c_step
# functions to use the [d6 ...] prefix and increment D-side
# counters.
. "${D_SCRIPT_DIR}/../c/c-fixtures.sh"

# --- Override output prefix to [d6 ...] -----------------------------

c_say()  { printf '[d6] %s\n' "$*"; }
c_warn() { printf '[d6 WARN] %s\n' "$*" >&2; }
c_info() { printf '       %s\n' "$*"; }
c_step() {
    printf '\n========================================================\n'
    printf '[d6 STEP] %s\n' "$*"
    printf '========================================================\n'
}

c_check_pass() {
    D_PASS_COUNT=$((D_PASS_COUNT + 1))
    printf '[d6 PASS] %s\n' "$*"
}

c_check_fail() {
    D_FAIL_COUNT=$((D_FAIL_COUNT + 1))
    printf '[d6 FAIL] %s\n' "$*" >&2
}

# --- D-specific helpers --------------------------------------------

# d_check_drawfs_loadable: drawfs is required for D.2 and D.3
# active-path tests. The script attempts to load it from the
# expected path if not already loaded; if neither the kldstat
# entry nor the .ko file is present, we run the inactive-path
# variants of those tests.
d_drawfs_loaded() {
    if kldstat | grep -q '\bdrawfs\b'; then
        return 0
    fi
    return 1
}

d_drawfs_load_attempt() {
    if d_drawfs_loaded; then
        return 0
    fi
    if [ -f "${D_DRAWFS_KO}" ]; then
        if kldload "${D_DRAWFS_KO}" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# d_state_byte: read a single byte from the state file at the
# given offset and print it as a decimal integer.
d_state_byte() {
    local off="$1"
    dd if="${D_STATE_PATH}" bs=1 count=1 skip="${off}" 2>/dev/null \
        | od -An -tu1 | tr -d ' \n'
}

# d_events_byte: same, for the events file.
d_events_byte() {
    local off="$1"
    dd if="${D_EVENTS_PATH}" bs=1 count=1 skip="${off}" 2>/dev/null \
        | od -An -tu1 | tr -d ' \n'
}

# d_state_i32_le: read a 4-byte little-endian signed integer
# from the state file at the given offset and print it as a
# decimal integer.
d_state_i32_le() {
    local off="$1"
    local b0 b1 b2 b3 raw
    raw=$(dd if="${D_STATE_PATH}" bs=1 count=4 skip="${off}" 2>/dev/null \
        | od -An -tu1)
    set -- $raw
    b0="$1"; b1="$2"; b2="$3"; b3="$4"
    # Compose little-endian. b3 is the high byte; sign-extend if
    # set. Awk handles the arithmetic to avoid shell-integer
    # overflow on 32-bit signed boundaries.
    awk -v b0="${b0}" -v b1="${b1}" -v b2="${b2}" -v b3="${b3}" '
        BEGIN {
            v = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216;
            if (v >= 2147483648) v = v - 4294967296;
            printf "%d", v;
        }'
}

# d_sysctl_get: read a sysctl by name and print its value, or
# empty string if absent.
d_sysctl_get() {
    sysctl -n "$1" 2>/dev/null
}

# d_sysctl_set: set a sysctl. Returns 0 on success, 1 on failure.
d_sysctl_set() {
    sysctl "$1=$2" >/dev/null 2>&1
}

# d_dmesg_recent: print the last N lines of dmesg.
d_dmesg_recent() {
    local n="${1:-50}"
    dmesg | tail -n "${n}"
}

# d_dmesg_has: returns 0 if recent dmesg contains the given
# string, 1 otherwise.
d_dmesg_has() {
    d_dmesg_recent 200 | grep -q -- "$1"
}
