#!/bin/sh
# b5-verify-vm.sh: B.5 verification, VM pass.
#
# Runs the four signals from B5_VERIFICATION.md inside a GhostBSD VM
# with USB pass-through. The script orchestrates build, install,
# load/unload, dmesg capture, and per-signal acceptance checks. The
# human handles VirtualBox USB pass-through actions when prompted.
#
# Usage:   ./b5-verify-vm.sh
# Output:  b5-pass1-vm.log and per-signal b5-1.N.log files in $PWD.
# Exit:    0 if all four signals passed, 1 if any failed, 2 if a
#          precondition failed, 3 if user aborted.

set -u

B5_LOGDIR=$(pwd)
. "$(dirname "$0")/b5-common.sh"

result=0
trap 'echo "Aborted."; exit 3' INT

# --- Preconditions ---------------------------------------------------

b5_check_patch_applied   || exit 2
b5_check_build           || exit 2
b5_check_no_prior_load   || exit 2
b5_install_module        || exit 2

# --- Signal 1.1 ------------------------------------------------------

b5_step "Signal 1.1: mouse classifies as pointer"

b5_pause "Confirm the mouse is NOT currently passed through to the VM (VirtualBox menu Devices > USB, no mouse entry checked)." || exit 3

b5_dmesg_clear
b5_load || { result=1; }

b5_pause "Pass the USB mouse through to the VM via VirtualBox menu Devices > USB. Check the mouse entry."  || exit 3

if command -v usbconfig >/dev/null 2>&1; then
    b5_say "usbconfig output:"
    usbconfig | grep -i mouse || b5_warn "No mouse seen in usbconfig output. Continuing anyway."
fi

b5_rescan
sleep 1
b5_dmesg_capture "${B5_LOGDIR}/b5-1.1.log"

b5_say "Captured log b5-1.1.log:"
cat "${B5_LOGDIR}/b5-1.1.log"

if b5_check_attach_sequence "${B5_LOGDIR}/b5-1.1.log" \
   && b5_check_roles_line "${B5_LOGDIR}/b5-1.1.log" pointer; then
    b5_pass "Signal 1.1: roles=pointer present, attach sequence ordered correctly."
else
    b5_fail "Signal 1.1 failed. See b5-1.1.log"
    result=1
fi

# --- Signal 1.2 ------------------------------------------------------

b5_step "Signal 1.2: mouse motion still produces raw reports"

b5_dmesg_clear
b5_pause "Move the mouse for at least 5 seconds: in different directions, click a button at least once, scroll the wheel if it has one." || exit 3

b5_dmesg_capture "${B5_LOGDIR}/b5-1.2.log"
report_count=$(grep -c 'report id=0x' "${B5_LOGDIR}/b5-1.2.log" || true)
b5_say "Captured ${report_count} report lines."

if b5_check_report_lines "${B5_LOGDIR}/b5-1.2.log" 10; then
    b5_pass "Signal 1.2: report stream verified."
else
    b5_fail "Signal 1.2 failed. See b5-1.2.log"
    result=1
fi

# --- Signal 1.3 ------------------------------------------------------

b5_step "Signal 1.3: keyboard classifies as keyboard"

b5_unload || { result=1; }

b5_pause "Detach the mouse from the VM (VirtualBox Devices > USB, uncheck the mouse). Pass the USB keyboard through (Devices > USB, check the keyboard)." || exit 3

if command -v usbconfig >/dev/null 2>&1; then
    b5_say "usbconfig output:"
    usbconfig | grep -i keyboard || b5_warn "No keyboard seen in usbconfig. Continuing anyway."
fi

b5_dmesg_clear
b5_load || { result=1; }
b5_rescan
sleep 1
b5_dmesg_capture "${B5_LOGDIR}/b5-1.3.log"

b5_say "Captured log b5-1.3.log:"
cat "${B5_LOGDIR}/b5-1.3.log"

if b5_check_attach_sequence "${B5_LOGDIR}/b5-1.3.log" \
   && b5_check_roles_line "${B5_LOGDIR}/b5-1.3.log" keyboard; then
    b5_pass "Signal 1.3: roles=keyboard present."
else
    b5_fail "Signal 1.3 failed. See b5-1.3.log"
    result=1
fi

# --- Signal 1.4 ------------------------------------------------------

b5_step "Signal 1.4: clean unload"

b5_dmesg_clear
b5_unload || { result=1; }
b5_dmesg_capture "${B5_LOGDIR}/b5-1.4.log"

b5_say "Captured log b5-1.4.log:"
cat "${B5_LOGDIR}/b5-1.4.log"

if b5_check_clean_unload "${B5_LOGDIR}/b5-1.4.log"; then
    b5_pass "Signal 1.4: clean unload verified."
else
    b5_fail "Signal 1.4 failed. See b5-1.4.log"
    result=1
fi

# --- Concatenate ---------------------------------------------------

cat "${B5_LOGDIR}/b5-1.1.log" \
    "${B5_LOGDIR}/b5-1.2.log" \
    "${B5_LOGDIR}/b5-1.3.log" \
    "${B5_LOGDIR}/b5-1.4.log" \
    > "${B5_LOGDIR}/b5-pass1-vm.log"
b5_say "Combined transcript: b5-pass1-vm.log"

b5_pass_summary "Pass 1 (VM)" "${result}"
exit "${result}"
