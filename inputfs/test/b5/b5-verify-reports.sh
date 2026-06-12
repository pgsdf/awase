#!/bin/sh
# b5-verify-reports.sh: B.5 report-flow standalone verification.
#
# Confirms that inputfs's interrupt path delivers HID reports to
# dmesg when input devices are exercised. This is the same check
# that Signal 2.2 performs in b5-verify-baremetal.sh, but without
# the build/install/unload precondition stack: it runs on whatever
# state the system is currently in, gives the operator a generous
# timing window, and restores the original load state on exit.
#
# Use this when:
#   - The full bare-metal pass produced a 2.2 timing miss and you
#     want to retake just that signal, without redoing 2.1, 2.3,
#     2.4 or rebuilding the module.
#   - You want to confirm that report flow still works after some
#     change that should not have affected it.
#
# Do NOT use this in place of the full bare-metal verification.
# This script does not check classification, attach sequences, or
# clean unload. It checks one thing: reports flow.
#
# Usage:   ./b5-verify-reports.sh
# Output:  b5-reports.log in $PWD.
# Exit:    0 if reports flowed, 1 if not, 2 on precondition error,
#          3 if user aborted.

set -u

B5_LOGDIR=$(pwd)
. "$(dirname "$0")/b5-common.sh"

result=0
trap 'echo "Aborted."; exit 3' INT

# Track whether we loaded inputfs so we can unload at the end if so.
b5_we_loaded_inputfs=0

# --- Preconditions ---------------------------------------------------

if ! kldstat -q -n inputfs 2>/dev/null; then
    b5_step "inputfs not loaded; loading"
    if [ ! -f /boot/modules/inputfs.ko ]; then
        b5_fail "/boot/modules/inputfs.ko does not exist."
        b5_fail "Build and install inputfs first, e.g. by running"
        b5_fail "b5-verify-baremetal.sh (which leaves the module installed)."
        exit 2
    fi
    if ! sudo kldload inputfs 2>&1; then
        b5_fail "kldload inputfs failed."
        exit 2
    fi
    b5_we_loaded_inputfs=1
    b5_pass "inputfs loaded."
    sleep 1
else
    b5_pass "inputfs already loaded; will leave it loaded on exit."
fi

# Confirm at least one inputfs softc exists (i.e. inputfs bound to
# at least one device). Without this, there is nothing to produce
# reports.
if ! sysctl -N dev.inputfs 2>/dev/null | grep -q '^dev\.inputfs\.[0-9]'; then
    # Fall back to checking dmesg for an attach line, since the sysctl
    # tree may not include unit-numbered children on all systems.
    if ! sudo dmesg 2>/dev/null | grep -q "inputfs[0-9].* attached HID"; then
        b5_fail "No inputfs softc detected. inputfs is loaded but did not"
        b5_fail "bind to any device. Cannot test report flow."
        if [ "${b5_we_loaded_inputfs}" = "1" ]; then
            sudo kldunload inputfs 2>/dev/null
        fi
        exit 2
    fi
fi

b5_pass "At least one inputfs softc is attached."

# --- The test --------------------------------------------------------

b5_step "Capturing report flow"

cat <<EOF

This test will:
  1. Clear the dmesg buffer.
  2. Wait for you to drive input from a USB device bound to inputfs
     (move a mouse, press keys on a keyboard, etc.).
  3. Capture the resulting dmesg output and count "report id=" lines.

Drive input continuously for at least 5 seconds after you continue,
then press <enter> a second time when you are done.

EOF

b5_pause "Ready to start? Press <enter> to clear dmesg and begin." || {
    if [ "${b5_we_loaded_inputfs}" = "1" ]; then
        sudo kldunload inputfs 2>/dev/null
    fi
    exit 3
}

b5_dmesg_clear
b5_say "dmesg cleared. Drive input now."

b5_pause "Press <enter> when you are done driving input." || {
    if [ "${b5_we_loaded_inputfs}" = "1" ]; then
        sudo kldunload inputfs 2>/dev/null
    fi
    exit 3
}

b5_dmesg_capture "${B5_LOGDIR}/b5-reports.log"
report_count=$(grep -c 'report id=0x' "${B5_LOGDIR}/b5-reports.log" 2>/dev/null; true)
b5_say "Captured ${report_count} report lines into b5-reports.log."

# --- Acceptance ------------------------------------------------------

if b5_check_report_lines "${B5_LOGDIR}/b5-reports.log" 10; then
    b5_pass "Report flow verified."
    result=0
else
    b5_fail "Fewer than 10 report lines captured. See b5-reports.log."
    b5_fail "Possible causes: no input was driven during the window,"
    b5_fail "the device that received input was not bound to inputfs,"
    b5_fail "or the report path is broken."
    result=1
fi

# --- Restore ---------------------------------------------------------

if [ "${b5_we_loaded_inputfs}" = "1" ]; then
    b5_step "Unloading inputfs (restoring original state)"
    if sudo kldunload inputfs 2>&1; then
        b5_pass "inputfs unloaded."
    else
        b5_warn "kldunload inputfs failed. You may need to unload manually."
    fi
fi

exit "${result}"
