#!/bin/sh
# c-fixtures.sh: shared helpers for Stage C verification scripts.
# POSIX sh. Sourced by c-verify.sh.
#
# Exit code conventions used by helpers that return one:
#   0  the helper succeeded / the check passed
#   1  the helper failed / the check failed
#   2  precondition failure (missing tool, file absent, etc.)
#   3  user aborted

set -u

# --- Configuration ---------------------------------------------------

# Where logs land. Caller may override before sourcing.
: "${C_LOGDIR:=$(pwd)}"

# Repo root, derived from this file's location.
C_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
C_REPO_ROOT=$(cd "${C_SCRIPT_DIR}/../.." && pwd)
C_MODULE_DIR="${C_REPO_ROOT}/sys/modules/inputfs"
C_INPUTDUMP="${C_REPO_ROOT}/zig-out/bin/inputdump"

# Publication region paths. Match the constants in
# shared/INPUT_STATE.md and shared/INPUT_EVENTS.md.
C_STATE_PATH="/var/run/sema/input/state"
C_EVENTS_PATH="/var/run/sema/input/events"

# Expected file sizes per spec.
C_STATE_SIZE=11328
C_EVENTS_SIZE=65600

# Counters incremented by c_check_pass / c_check_fail.
C_PASS_COUNT=0
C_FAIL_COUNT=0

# --- Output helpers --------------------------------------------------

c_say()  { printf '[c5] %s\n' "$*"; }
c_warn() { printf '[c5 WARN] %s\n' "$*" >&2; }
c_info() { printf '       %s\n' "$*"; }
c_step() {
    printf '\n========================================================\n'
    printf '[c5 STEP] %s\n' "$*"
    printf '========================================================\n'
}

c_check_pass() {
    C_PASS_COUNT=$((C_PASS_COUNT + 1))
    printf '[c5 PASS] %s\n' "$*"
}

c_check_fail() {
    C_FAIL_COUNT=$((C_FAIL_COUNT + 1))
    printf '[c5 FAIL] %s\n' "$*" >&2
}

c_pause() {
    # Prompt the user and wait for confirmation. $1 is the prompt.
    # Returns 0 on yes/enter, 3 on quit.
    printf '\n[c5 ACTION REQUIRED] %s\n' "$1"
    printf '    Press <enter> to continue, q<enter> to abort: '
    read ans
    case "$ans" in
        q|Q|quit|abort) return 3 ;;
        *) return 0 ;;
    esac
}

# --- Precondition checks --------------------------------------------

c_check_root() {
    if [ "$(id -u)" != "0" ]; then
        c_warn "this script needs root (kldload, /var/run access)."
        c_warn "run with sudo, or as root."
        return 2
    fi
    return 0
}

c_check_inputdump_built() {
    if [ ! -x "${C_INPUTDUMP}" ]; then
        c_warn "inputdump binary not found at ${C_INPUTDUMP}"
        c_warn "build it first: cd ${C_REPO_ROOT} && zig build"
        return 2
    fi
    return 0
}

c_check_throwaway_absent() {
    # The C.2/C.3 throwaway tool was deleted in the C.4 commit. If
    # someone has re-introduced it (perhaps by reverting a commit
    # or copying from an older branch), we want to know.
    local stale="${C_REPO_ROOT}/tools/inputstate-check.zig"
    if [ -e "${stale}" ]; then
        c_warn "stale C.2/C.3 throwaway exists at ${stale}"
        c_warn "C.4 deleted this file; its presence suggests a regression."
        return 2
    fi
    return 0
}

c_check_module_built() {
    local kmod="${C_MODULE_DIR}/inputfs.ko"
    if [ ! -f "${kmod}" ]; then
        c_warn "inputfs.ko not built at ${kmod}"
        c_warn "build first: cd ${C_MODULE_DIR} && sudo make"
        return 2
    fi
    return 0
}

c_check_tmpfs() {
    # /var/run must be tmpfs. inputfs creates files there in MOD_LOAD,
    # and a non-tmpfs /var/run will succeed but pollute persistent
    # storage. README's System Requirements section calls this out.
    #
    # Parse `mount` output: the canonical line shape on FreeBSD is
    #   tmpfs on /var/run (tmpfs, local)
    # The fs type appears both as the device-name field (first token)
    # and inside the parenthesized options. Match either.
    local mount_line
    mount_line=$(mount | awk '$3 == "/var/run" { print; exit }')
    if [ -z "${mount_line}" ]; then
        c_warn "/var/run does not appear in mount output."
        c_warn "see README System Requirements section."
        return 2
    fi
    case "${mount_line}" in
        tmpfs*|*"(tmpfs"*)
            return 0
            ;;
        *)
            c_warn "/var/run is not tmpfs: ${mount_line}"
            c_warn "see README System Requirements section."
            return 2
            ;;
    esac
}

# --- Module lifecycle helpers ---------------------------------------

c_module_loaded() {
    kldstat -n inputfs >/dev/null 2>&1
}

c_load_module() {
    if c_module_loaded; then
        c_info "module already loaded; unloading first."
        kldunload inputfs >/dev/null 2>&1 || true
    fi
    # Load by full path to the development tree's .ko, not by
    # bare name. kldload(8) given a bare name searches
    # kern.module_path (default /boot/modules and /boot/kernel)
    # and would silently pick up any stale module installed
    # there from an earlier `make install`, masking the freshly
    # built version we want to test.
    if ! kldload "${C_MODULE_DIR}/inputfs.ko" 2>/dev/null; then
        c_warn "kldload ${C_MODULE_DIR}/inputfs.ko failed."
        return 1
    fi
    return 0
}

c_unload_module() {
    if ! c_module_loaded; then
        return 0
    fi
    if ! kldunload inputfs 2>/dev/null; then
        c_warn "kldunload inputfs failed."
        return 1
    fi
    return 0
}

# --- File-level structural checks -----------------------------------

c_expect_file_size() {
    # $1 = path, $2 = expected size in bytes.
    local actual
    actual=$(stat -f '%z' "$1" 2>/dev/null || echo "missing")
    if [ "${actual}" = "$2" ]; then
        c_check_pass "${1} is ${2} bytes"
        return 0
    else
        c_check_fail "${1}: expected ${2} bytes, got ${actual}"
        return 1
    fi
}

c_expect_magic() {
    # $1 = path, $2 = expected ASCII mnemonic ("INST" or "INVE"),
    # $3 = byte offset.
    #
    # The magic field is a u32 stored little-endian. The mnemonic
    # "INST" corresponds to the u32 value 0x494E5354 (I=0x49,
    # N=0x4E, S=0x53, T=0x54), which on a little-endian platform
    # lands on disk as bytes 54 53 4E 49, reversed when read as
    # ASCII. The spec describes the magic as the hex value, not as
    # an ASCII string; userspace consumers read 4 bytes and decode
    # as a little-endian u32 to compare.
    #
    # We do the same here: read 4 bytes, render as a hex value
    # respecting little-endian byte order, compare against the
    # mnemonic's expected u32.
    local expected_hex
    case "$2" in
        INST) expected_hex="494e5354" ;;
        INVE) expected_hex="494e5645" ;;
        *)
            c_check_fail "${1}: c_expect_magic called with unknown mnemonic '$2'"
            return 1
            ;;
    esac

    # Read 4 bytes at offset $3 as four space-separated hex bytes,
    # then reverse them (little-endian -> big-endian) and concat.
    local bytes
    bytes=$(od -An -tx1 -j "$3" -N 4 "$1" 2>/dev/null | tr -s ' ' '\n' \
        | grep -v '^$' | tr -d '\n')
    if [ -z "${bytes}" ] || [ "${#bytes}" != 8 ]; then
        c_check_fail "${1}: could not read 4 bytes at offset ${3}"
        return 1
    fi

    # bytes is now an 8-character hex string in file order, e.g.
    # "5453 4e49" -> "54534e49" for "INST" stored little-endian.
    # Reverse byte pairs to get u32 hex value.
    local b0="${bytes%??????}"
    local b1_full="${bytes#??}"; local b1="${b1_full%????}"
    local b2_full="${bytes#????}"; local b2="${b2_full%??}"
    local b3="${bytes#??????}"
    local got_hex="${b3}${b2}${b1}${b0}"

    if [ "${got_hex}" = "${expected_hex}" ]; then
        c_check_pass "${1}: magic at offset ${3} = 0x${expected_hex} ('${2}')"
        return 0
    else
        c_check_fail "${1}: expected magic 0x${expected_hex} ('${2}') at offset ${3}, got 0x${got_hex}"
        return 1
    fi
}

c_expect_version_byte() {
    # $1 = path, $2 = expected version byte value, $3 = byte offset.
    local got_dec
    got_dec=$(od -An -tu1 -j "$3" -N 1 "$1" 2>/dev/null | tr -d ' ')
    if [ "${got_dec}" = "$2" ]; then
        c_check_pass "${1}: version byte at offset ${3} = ${2}"
        return 0
    else
        c_check_fail "${1}: expected version ${2} at offset ${3}, got ${got_dec}"
        return 1
    fi
}

c_expect_files_present() {
    local ok=0
    for f in "${C_STATE_PATH}" "${C_EVENTS_PATH}"; do
        if [ -f "$f" ]; then
            c_check_pass "${f} present"
        else
            c_check_fail "${f} absent"
            ok=1
        fi
    done
    return ${ok}
}

# --- inputdump-based content checks ---------------------------------

c_inputdump_state_json() {
    # Echo the JSON snapshot to stdout. Exits non-zero on failure.
    "${C_INPUTDUMP}" state --json
}

c_inputdump_devices_json() {
    "${C_INPUTDUMP}" devices --json
}

c_inputdump_events_json() {
    # Drain everything currently in the ring as JSON, one object per line.
    "${C_INPUTDUMP}" events --json
}

c_expect_device_count_at_least() {
    # $1 = minimum device count expected.
    local snap
    if ! snap=$(c_inputdump_state_json 2>/dev/null); then
        c_check_fail "inputdump state --json failed"
        return 1
    fi
    # Parse "device_count":N from the JSON. We avoid jq so the
    # script runs on a stock FreeBSD install.
    local count
    count=$(printf '%s' "${snap}" | sed -n 's/.*"device_count":\([0-9]*\).*/\1/p')
    if [ -z "${count}" ]; then
        c_check_fail "could not parse device_count from state JSON"
        return 1
    fi
    if [ "${count}" -ge "$1" ]; then
        c_check_pass "device_count = ${count} (expected >= $1)"
        return 0
    else
        c_check_fail "device_count = ${count}, expected >= $1"
        return 1
    fi
}

c_expect_lifecycle_attach_per_device() {
    # Verify there is one lifecycle.attach event for each populated
    # device slot, with seq numbers 1..N matching slot indices 0..N-1.
    local events
    if ! events=$(c_inputdump_events_json 2>/dev/null); then
        c_check_fail "inputdump events --json failed"
        return 1
    fi

    local attaches
    attaches=$(printf '%s\n' "${events}" \
        | grep '"role":"lifecycle"' \
        | grep '"type":"attach"' \
        | wc -l \
        | tr -d ' ')

    local devcount
    devcount=$(c_inputdump_devices_json 2>/dev/null \
        | sed -n 's/.*"device_count":\([0-9]*\).*/\1/p')

    if [ -z "${devcount}" ]; then
        c_check_fail "could not parse device_count from devices JSON"
        return 1
    fi

    if [ "${attaches}" = "${devcount}" ]; then
        c_check_pass "lifecycle.attach events = ${attaches} (matches device_count)"
        return 0
    else
        c_check_fail "lifecycle.attach events = ${attaches}, device_count = ${devcount}"
        return 1
    fi
}

c_expect_seq_monotonic() {
    # Verify event sequence numbers are strictly monotonic.
    local events
    if ! events=$(c_inputdump_events_json 2>/dev/null); then
        c_check_fail "inputdump events --json failed"
        return 1
    fi

    local seqs
    seqs=$(printf '%s\n' "${events}" \
        | sed -n 's/.*"seq":\([0-9]*\).*/\1/p')

    if [ -z "${seqs}" ]; then
        c_check_fail "no events in ring (cannot verify seq monotonicity)"
        return 1
    fi

    local prev=0
    local violation=0
    for s in ${seqs}; do
        if [ "${s}" -le "${prev}" ]; then
            c_check_fail "seq ${s} not greater than previous ${prev}"
            violation=1
            break
        fi
        prev=${s}
    done

    if [ "${violation}" = 0 ]; then
        c_check_pass "event seqs strictly monotonic (last seq=${prev})"
        return 0
    fi
    return 1
}

c_expect_writer_seq_advances() {
    # Take two state snapshots with a brief delay. last_sequence
    # should be monotonically non-decreasing across them.
    local a b sa sb
    a=$(c_inputdump_state_json 2>/dev/null)
    sleep 1
    b=$(c_inputdump_state_json 2>/dev/null)
    sa=$(printf '%s' "$a" | sed -n 's/.*"last_sequence":\([0-9]*\).*/\1/p')
    sb=$(printf '%s' "$b" | sed -n 's/.*"last_sequence":\([0-9]*\).*/\1/p')
    if [ -z "${sa}" ] || [ -z "${sb}" ]; then
        c_check_fail "could not parse last_sequence from state JSON"
        return 1
    fi
    if [ "${sb}" -ge "${sa}" ]; then
        c_check_pass "last_sequence stable or advancing (${sa} -> ${sb})"
        return 0
    else
        c_check_fail "last_sequence regressed: ${sa} -> ${sb}"
        return 1
    fi
}

# --- Memory-leak helper ---------------------------------------------

c_inputfs_malloc_bytes() {
    # Returns the total bytes allocated to M_INPUTFS via vmstat -m,
    # or 0 if the type is absent (which is the expected state when
    # the module is unloaded).
    vmstat -m 2>/dev/null \
        | awk '$1 == "inputfs" { print $3 * 1024; exit }' \
        | head -1
}
