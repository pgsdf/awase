#!/bin/sh
# b5-verify-baremetal.sh: B.5 verification, bare-metal pass.
#
# Runs the four signals from B5_VERIFICATION.md on bare-metal
# GhostBSD. Differs from the VM version in three ways:
#   1. No VirtualBox pass-through; physical plug/unplug instead.
#   2. Resolves the hms/hkbd conflict (those drivers claim USB
#      mouse/keyboard at boot, blocking inputfs from attaching).
#   3. Logs go to b5-pass2-baremetal.log and per-signal b5-2.N.log.
#
# IMPORTANT: this script will unload hms and hkbd. If your console
# input is via USB, your mouse and keyboard will stop working
# during the test. Run from a serial console, an SSH session whose
# input is not USB-bound, or a graphical terminal that survives
# without keyboard echo. The script will pause and remind you.
#
# Usage:   ./b5-verify-baremetal.sh
# Output:  b5-pass2-baremetal.log and per-signal b5-2.N.log files.
# Exit:    0 if all passed, 1 if any failed, 2 if precondition
#          failed, 3 if user aborted.

set -u

B5_LOGDIR=$(pwd)
. "$(dirname "$0")/b5-common.sh"

result=0
trap 'echo "Aborted."; exit 3' INT

# --- Bare-metal-specific helpers ------------------------------------

b5_resolve_hms_hkbd_conflict() {
    b5_step "Resolving hms/hkbd conflict"

    hms_loaded=0
    hkbd_loaded=0
    kldstat | grep -q '^.*hms\.ko' && hms_loaded=1
    kldstat | grep -q '^.*hkbd\.ko' && hkbd_loaded=1

    if [ "${hms_loaded}" -eq 0 ] && [ "${hkbd_loaded}" -eq 0 ]; then
        b5_pass "hms and hkbd are not loaded. inputfs will be free to claim devices."
        # Could be statically compiled into the kernel; warn.
        if grep -q hms /sys/dev/hid/* 2>/dev/null \
           || sysctl -a 2>/dev/null | grep -q hms; then
            b5_warn "hms may be compiled into the kernel. If devices fail to bind to inputfs, that is the cause."
        fi
        return 0
    fi

    cat <<EOF

WARNING: hms and/or hkbd are loaded. They are claiming the USB
mouse and keyboard, blocking inputfs from attaching.

Two options:

  A. Permanently blacklist them by adding the following to
     /boot/loader.conf and rebooting:

         hms_load="NO"
         hkbd_load="NO"

  B. Unload them now for this session only.

If you have not prepared a fallback console (serial, SSH not
relying on USB, or a remote graphical terminal), choose A,
reboot, and re-run this script.

EOF

    if ! b5_confirm "Unload hms and hkbd now (option B)?"; then
        b5_say "Aborting. Configure /boot/loader.conf and reboot, then re-run."
        return 3
    fi

    b5_pause "Last chance to abort. After this prompt, your USB mouse and keyboard will stop responding to the system until inputfs claims them. Are you on a non-USB console?"

    if [ "${hms_loaded}" -eq 1 ]; then
        b5_say "Unloading hms"
        if ! sudo kldunload hms; then
            b5_fail "Failed to unload hms"
            return 2
        fi
    fi
    if [ "${hkbd_loaded}" -eq 1 ]; then
        b5_say "Unloading hkbd"
        if ! sudo kldunload hkbd; then
            b5_fail "Failed to unload hkbd"
            return 2
        fi
    fi
    b5_pass "hms/hkbd unloaded. inputfs is now free to claim USB HID devices."
    return 0
}

# --- Preconditions ---------------------------------------------------

b5_check_patch_applied      || exit 2
b5_check_build              || exit 2
b5_check_no_prior_load      || exit 2
b5_install_module           || exit 2
b5_resolve_hms_hkbd_conflict || exit $?

# --- Signal 2.1 ------------------------------------------------------

b5_step "Signal 2.1: mouse classifies as pointer"

b5_pause "Confirm the USB mouse is plugged in. If it is not, plug it in now."

b5_dmesg_clear
b5_load || { result=1; }
b5_rescan
sleep 1
b5_dmesg_capture "${B5_LOGDIR}/b5-2.1.log"

b5_say "Captured log b5-2.1.log:"
cat "${B5_LOGDIR}/b5-2.1.log"

if b5_check_attach_sequence "${B5_LOGDIR}/b5-2.1.log" \
   && b5_check_roles_line "${B5_LOGDIR}/b5-2.1.log" pointer; then
    b5_pass "Signal 2.1: roles=pointer present, attach sequence ordered correctly."
else
    b5_fail "Signal 2.1 failed. See b5-2.1.log"
    result=1
fi

# --- Signal 2.2 ------------------------------------------------------

b5_step "Signal 2.2: mouse motion still produces raw reports"

b5_dmesg_clear
b5_pause "Move the mouse for at least 5 seconds: in different directions, click a button at least once, scroll the wheel if it has one."

b5_dmesg_capture "${B5_LOGDIR}/b5-2.2.log"
report_count=$(grep -c 'report id=0x' "${B5_LOGDIR}/b5-2.2.log" || true)
b5_say "Captured ${report_count} report lines."

if b5_check_report_lines "${B5_LOGDIR}/b5-2.2.log" 10; then
    b5_pass "Signal 2.2: report stream verified."
else
    b5_fail "Signal 2.2 failed. See b5-2.2.log"
    result=1
fi

# --- Signal 2.3 ------------------------------------------------------

b5_step "Signal 2.3: keyboard classifies as keyboard"

b5_unload || { result=1; }

b5_pause "Unplug the mouse. Plug in the USB keyboard. Wait a moment for USB enumeration to complete."

b5_dmesg_clear
b5_load || { result=1; }
b5_rescan
sleep 1
b5_dmesg_capture "${B5_LOGDIR}/b5-2.3.log"

b5_say "Captured log b5-2.3.log:"
cat "${B5_LOGDIR}/b5-2.3.log"

if b5_check_attach_sequence "${B5_LOGDIR}/b5-2.3.log" \
   && b5_check_roles_line "${B5_LOGDIR}/b5-2.3.log" keyboard; then
    b5_pass "Signal 2.3: roles=keyboard present."
else
    b5_fail "Signal 2.3 failed. See b5-2.3.log"
    result=1
fi

# --- Signal 2.4 ------------------------------------------------------

b5_step "Signal 2.4: clean unload"

b5_dmesg_clear
b5_unload || { result=1; }
b5_dmesg_capture "${B5_LOGDIR}/b5-2.4.log"

b5_say "Captured log b5-2.4.log:"
cat "${B5_LOGDIR}/b5-2.4.log"

if b5_check_clean_unload "${B5_LOGDIR}/b5-2.4.log"; then
    b5_pass "Signal 2.4: clean unload verified."
else
    b5_fail "Signal 2.4 failed. See b5-2.4.log"
    result=1
fi

# --- Restore hms/hkbd if we unloaded them ---------------------------

b5_step "Optional: restore hms and hkbd"

if b5_confirm "Reload hms and hkbd to restore normal mouse/keyboard?"; then
    sudo kldload hms 2>/dev/null && b5_say "hms reloaded"
    sudo kldload hkbd 2>/dev/null && b5_say "hkbd reloaded"
fi

# --- Concatenate ----------------------------------------------------

cat "${B5_LOGDIR}/b5-2.1.log" \
    "${B5_LOGDIR}/b5-2.2.log" \
    "${B5_LOGDIR}/b5-2.3.log" \
    "${B5_LOGDIR}/b5-2.4.log" \
    > "${B5_LOGDIR}/b5-pass2-baremetal.log"
b5_say "Combined transcript: b5-pass2-baremetal.log"

b5_pass_summary "Pass 2 (bare metal)" "${result}"
exit "${result}"
