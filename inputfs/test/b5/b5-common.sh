#!/bin/sh
# b5-common.sh: shared functions for B.5 verification scripts.
# POSIX sh. Sourced by b5-verify-vm.sh and b5-verify-baremetal.sh.

# Exit codes:
#   0 = signal passed
#   1 = signal failed (acceptance criteria not met)
#   2 = precondition failure (build, missing tool, etc.)
#   3 = user aborted

set -u

# Where logs land. Caller may override before sourcing.
: "${B5_LOGDIR:=$(pwd)}"

# Repo root, derived from this file's location.
B5_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
B5_REPO_ROOT=$(cd "${B5_SCRIPT_DIR}/../.." && pwd)
B5_MODULE_DIR="${B5_REPO_ROOT}/sys/modules/inputfs"
B5_SOURCE_FILE="${B5_REPO_ROOT}/sys/dev/inputfs/inputfs.c"

# --- Output helpers --------------------------------------------------

b5_say()  { printf '[b5] %s\n' "$*"; }
b5_warn() { printf '[b5 WARN] %s\n' "$*" >&2; }
b5_fail() { printf '[b5 FAIL] %s\n' "$*" >&2; }
b5_pass() { printf '[b5 PASS] %s\n' "$*"; }
b5_step() {
    printf '\n========================================================\n'
    printf '[b5 STEP] %s\n' "$*"
    printf '========================================================\n'
}

b5_pause() {
    # Prompt the user and wait for confirmation. $1 is the prompt.
    # Returns 0 on yes/enter, 3 on quit.
    printf '\n[b5 ACTION REQUIRED] %s\n' "$1"
    printf '    Press <enter> to continue, q<enter> to abort: '
    read ans
    case "$ans" in
        q|Q|quit|abort) return 3 ;;
        *) return 0 ;;
    esac
}

b5_confirm() {
    # Yes/no prompt. $1 is the question. Returns 0 yes, 1 no, 3 abort.
    printf '\n[b5] %s [y/n/q]: ' "$1"
    read ans
    case "$ans" in
        y|Y|yes) return 0 ;;
        q|Q) return 3 ;;
        *) return 1 ;;
    esac
}

# --- Precondition checks --------------------------------------------

b5_check_patch_applied() {
    b5_step "P.1: Checking that the B.5 patch is applied"
    if [ ! -f "${B5_SOURCE_FILE}" ]; then
        b5_fail "Source file not found: ${B5_SOURCE_FILE}"
        return 2
    fi
    missing=0
    for pat in INPUTFS_ROLE_POINTER INPUTFS_ROLE_KEYBOARD \
               INPUTFS_ROLE_TOUCH INPUTFS_ROLE_PEN \
               INPUTFS_ROLE_LIGHTING sc_roles \
               'roles=%s' inputfs_classify_roles; do
        if ! grep -q "${pat}" "${B5_SOURCE_FILE}"; then
            b5_fail "Pattern not found in inputfs.c: ${pat}"
            missing=1
        fi
    done
    if [ "${missing}" -ne 0 ]; then
        b5_fail "B.5 patch is incomplete or not applied."
        return 2
    fi
    b5_pass "All B.5 patch markers present."
    return 0
}

b5_check_build() {
    b5_step "P.2: Building the kernel module"
    if [ ! -d "${B5_MODULE_DIR}" ]; then
        b5_fail "Module directory not found: ${B5_MODULE_DIR}"
        return 2
    fi
    cd "${B5_MODULE_DIR}" || return 2
    if ! make clean >/dev/null 2>&1; then
        b5_warn "make clean returned nonzero; continuing"
    fi
    if ! make 2>&1 | tee "${B5_LOGDIR}/b5-build.log"; then
        b5_fail "Build failed. See ${B5_LOGDIR}/b5-build.log"
        return 2
    fi
    if [ ! -f "${B5_MODULE_DIR}/inputfs.ko" ]; then
        b5_fail "inputfs.ko not produced by build"
        return 2
    fi
    b5_pass "Build clean. ${B5_MODULE_DIR}/inputfs.ko produced."
    return 0
}

b5_check_no_prior_load() {
    b5_step "P.3: Checking that inputfs is not already loaded"
    if kldstat | grep -q inputfs; then
        b5_warn "inputfs is currently loaded:"
        kldstat | grep inputfs
        if b5_confirm "Attempt to unload it?"; then
            if ! sudo kldunload inputfs; then
                b5_fail "kldunload refused. Detach any USB device and re-run."
                return 2
            fi
        else
            return 3
        fi
    fi
    b5_pass "inputfs not loaded."
    return 0
}

b5_install_module() {
    b5_step "Installing freshly built module"
    cd "${B5_MODULE_DIR}" || return 2
    if ! sudo make install 2>&1 | tee "${B5_LOGDIR}/b5-install.log"; then
        b5_fail "make install failed. See ${B5_LOGDIR}/b5-install.log"
        return 2
    fi
    if [ ! -f /boot/modules/inputfs.ko ]; then
        b5_fail "/boot/modules/inputfs.ko missing after install"
        return 2
    fi
    b5_pass "Module installed to /boot/modules/inputfs.ko"
    return 0
}

# --- dmesg capture --------------------------------------------------

b5_dmesg_clear() {
    sudo dmesg -c >/dev/null 2>&1 || true
}

b5_dmesg_capture() {
    # Capture inputfs lines from dmesg into the named log file.
    # $1 = output file path
    sudo dmesg | grep inputfs > "$1" || true
}

# --- Signal-level acceptance checks ---------------------------------

b5_check_roles_line() {
    # Look for "roles=<expected>" on its own (no extra junk after).
    # $1 = log file, $2 = expected role string (e.g. "pointer")
    log="$1"
    expected="$2"
    if ! grep -q "roles=${expected}\$" "${log}"; then
        # Try without the end-of-line anchor in case there's a CR or
        # trailing space, but flag it as suspect.
        if grep -q "roles=${expected}" "${log}"; then
            b5_warn "roles=${expected} found but not on its own line. Format may be off."
            return 1
        fi
        b5_fail "Expected 'roles=${expected}' not found in ${log}"
        return 1
    fi
    return 0
}

b5_check_attach_sequence() {
    # Verify B.2/B.3/B.4 lines are present and in order before the
    # roles= line. Returns 0 if the sequence looks right.
    # $1 = log file
    log="$1"
    line_attached=$(grep -n 'attached HID' "${log}" | head -1 | cut -d: -f1)
    line_descriptor=$(grep -n 'descriptor.*bytes.*input items' "${log}" | head -1 | cut -d: -f1)
    line_buffer=$(grep -n 'report buffer.*registering interrupt' "${log}" | head -1 | cut -d: -f1)
    line_roles=$(grep -n 'roles=' "${log}" | head -1 | cut -d: -f1)

    for v in line_attached line_descriptor line_buffer line_roles; do
        eval "val=\${${v}:-}"
        if [ -z "${val}" ]; then
            b5_fail "Missing attach-sequence line: ${v}"
            return 1
        fi
    done

    if [ "${line_attached}" -ge "${line_roles}" ] || \
       [ "${line_descriptor}" -ge "${line_roles}" ] || \
       [ "${line_buffer}" -ge "${line_roles}" ]; then
        b5_fail "roles= line appears before the B.2/B.3/B.4 lines (wrong order)"
        return 1
    fi
    return 0
}

b5_check_report_lines() {
    # $1 = log file, $2 = minimum count
    log="$1"
    minimum="$2"
    count=$(grep -c 'report id=0x' "${log}" || true)
    if [ "${count}" -lt "${minimum}" ]; then
        b5_fail "Only ${count} 'report id=' lines found, expected at least ${minimum}"
        return 1
    fi
    # Look for at least one report with non-zero data.
    if ! grep -E 'report id=0x.*data=00 ([1-9a-f][0-9a-f]?|0[1-9a-f])' "${log}" >/dev/null; then
        # Best-effort check; don't fail if pattern doesn't catch it
        b5_warn "Could not auto-detect non-zero motion deltas; please verify manually"
    fi
    return 0
}

b5_check_clean_unload() {
    # $1 = log file
    log="$1"
    if ! grep -q 'inputfs0:.*detached' "${log}"; then
        b5_fail "Missing 'detached' line"
        return 1
    fi
    if ! grep -q 'inputfs: unloaded' "${log}"; then
        b5_fail "Missing 'unloaded' line"
        return 1
    fi
    if kldstat | grep -q inputfs; then
        b5_fail "inputfs still in kldstat after unload"
        return 1
    fi
    # Check broader dmesg tail for warnings.
    if sudo dmesg | tail -50 | grep -iE 'warning|witness|leak|use[ -]after' >/dev/null; then
        b5_warn "Found warning/witness/leak text in recent dmesg. Review b5-pass*.log full capture."
        return 1
    fi
    return 0
}

# --- Lifecycle helpers -----------------------------------------------

b5_load() {
    b5_say "Loading inputfs"
    if ! sudo kldload inputfs; then
        b5_fail "kldload inputfs failed"
        return 1
    fi
    return 0
}

b5_unload() {
    b5_say "Unloading inputfs"
    if ! sudo kldunload inputfs; then
        b5_fail "kldunload inputfs failed"
        return 1
    fi
    return 0
}

b5_rescan() {
    # Trigger inputfs to bind. Bus name is system-dependent.
    b5_say "Triggering devctl rescan"
    if sudo devctl rescan usbhid1 2>/dev/null; then
        return 0
    fi
    if sudo devctl rescan hidbus1 2>/dev/null; then
        return 0
    fi
    # Try discovering the right bus name.
    if command -v devinfo >/dev/null 2>&1; then
        bus=$(devinfo -v 2>/dev/null | awk '/hidbus/ {print $1; exit}')
        if [ -n "${bus}" ]; then
            b5_say "Trying ${bus}"
            if sudo devctl rescan "${bus}" 2>/dev/null; then
                return 0
            fi
        fi
    fi
    b5_warn "devctl rescan did not succeed on usbhid1, hidbus1, or auto-discovered bus"
    b5_warn "The device may have already attached on its own. Continuing."
    return 0
}

# Print final summary for a pass.
b5_pass_summary() {
    # $1 = pass label (e.g. "Pass 1: VM"), $2 = result (0/1)
    label="$1"
    result="$2"
    printf '\n========================================================\n'
    if [ "${result}" -eq 0 ]; then
        printf '[b5] %s: ALL SIGNALS PASSED\n' "${label}"
    else
        printf '[b5] %s: FAILED. Review logs in %s\n' "${label}" "${B5_LOGDIR}"
    fi
    printf '========================================================\n'
}
