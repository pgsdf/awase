#!/bin/sh
# d-verify.sh: Stage D acceptance test for inputfs.
#
# Verifies the deliverables of Stage D.0a through D.5 against
# their specifications:
#
#   D.0a: descriptor-driven pointer events
#   D.0b: descriptor-driven keyboard events
#         (D.0a/D.0b are exercised structurally by C.5; this
#         script does not duplicate that. The manual checklist
#         in D_VERIFICATION.md exercises them under live input.)
#   D.1:  kernel-side focus reader
#         (verified by the focus file open attempt being made
#         at module load and the kthread refresh log behaviour
#         when the file is absent.)
#   D.2:  display geometry sysctls from drawfs
#         (verified by hw.drawfs.efifb.* sysctl presence and
#         inputfs's geometry-known dmesg line.)
#   D.3:  coordinate transform
#         (verified by transform_active byte at state offset 48
#         and pointer seed position when geometry is known.)
#   D.5:  hw.inputfs.enable tunable
#         (verified by toggling the sysctl and observing
#         valid-byte transitions in both publication files plus
#         dmesg messages.)
#
# D.4 routing requires either a live compositor or a synthetic
# focus writer to exercise. This script does not include the
# synthetic focus writer; D.4 verification is deferred to the
# manual checklist in inputfs/docs/D_VERIFICATION.md.
#
# Stage C invariants (regions exist, sizes match spec, headers
# valid) remain in scope: this script reuses them as
# preconditions rather than re-asserting them, but C.5 must
# still pass for D.6 to be meaningful.
#
# Usage:
#   sudo sh d-verify.sh
#
# Exit codes:
#   0 all checks passed
#   1 one or more checks failed
#   2 precondition failure (missing tool, build artefact, etc.)
#   3 user aborted

set -u

D_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "${D_SELF_DIR}/d-fixtures.sh"

# --------------------------------------------------------------------
# Phase 0: preconditions
# --------------------------------------------------------------------

c_step "Phase 0: preconditions"

c_check_root || exit 2
c_check_inputdump_built || exit 2
c_check_module_built || exit 2
c_check_tmpfs || exit 2

# Stage C must have passed before Stage D verification runs.
# We do not run C.5 from here; we require the operator to have
# run it. The marker we look for is C.5 leaves the publication
# files in place after its second unload, but that is fragile.
# A simpler precondition: the kernel module must build cleanly,
# which c_check_module_built already verified.

c_say "all preconditions met"

# --------------------------------------------------------------------
# Phase 1: clean slate, load drawfs (if available), load inputfs
# --------------------------------------------------------------------
#
# We start by ensuring inputfs is unloaded so the module-load
# transitions we test below are observable. drawfs is loaded
# first if its .ko is reachable; otherwise we run the
# geometry-unknown variants of D.2 and D.3.

c_step "Phase 1: module load"

if c_module_loaded; then
    if ! c_unload_module; then
        c_check_fail "could not unload pre-existing inputfs"
        exit 1
    fi
fi

D_DRAWFS_AVAILABLE=0
if d_drawfs_load_attempt; then
    D_DRAWFS_AVAILABLE=1
    c_check_pass "drawfs loaded (geometry tests will use active path)"
else
    c_info "drawfs not available; D.2 and D.3 will run geometry-unknown variants"
fi

if c_load_module; then
    c_check_pass "kldload inputfs"
else
    c_check_fail "kldload inputfs"
    exit 1
fi

# Give the kthread a tick to open files and apply geometry.
sleep 1

# --------------------------------------------------------------------
# Phase 2: D.2 geometry sysctls
# --------------------------------------------------------------------

c_step "Phase 2: D.2 display geometry"

if [ "${D_DRAWFS_AVAILABLE}" = 1 ]; then
    GEOM_W=$(d_sysctl_get hw.drawfs.efifb.width)
    GEOM_H=$(d_sysctl_get hw.drawfs.efifb.height)
    if [ -n "${GEOM_W}" ] && [ -n "${GEOM_H}" ] && \
       [ "${GEOM_W}" -gt 0 ] && [ "${GEOM_H}" -gt 0 ]; then
        c_check_pass "drawfs geometry sysctls readable (${GEOM_W}x${GEOM_H})"
    else
        c_check_fail "drawfs geometry sysctls present but values invalid"
    fi

    if d_dmesg_has "display geometry from drawfs"; then
        c_check_pass "inputfs dmesg confirms geometry read"
    else
        c_check_fail "inputfs did not log geometry-from-drawfs message"
    fi
else
    if d_dmesg_has "hw.drawfs.efifb.* sysctls unavailable"; then
        c_check_pass "inputfs dmesg confirms geometry-unknown fallback"
    else
        c_check_fail "drawfs not loaded but inputfs did not log unavailable-sysctl message"
    fi
    GEOM_W=""
    GEOM_H=""
fi

# --------------------------------------------------------------------
# Phase 3: D.3 coordinate transform
# --------------------------------------------------------------------

c_step "Phase 3: D.3 coordinate transform"

TRANSFORM_BYTE=$(d_state_byte "${D_STATE_OFF_TRANSFORM_ACTIVE}")
PTR_X=$(d_state_i32_le "${D_STATE_OFF_PTR_X}")
PTR_Y=$(d_state_i32_le "${D_STATE_OFF_PTR_Y}")

if [ "${D_DRAWFS_AVAILABLE}" = 1 ]; then
    # Geometry known: transform_active=1, pointer seeded at center.
    if [ "${TRANSFORM_BYTE}" = "1" ]; then
        c_check_pass "transform_active = 1 (geometry known)"
    else
        c_check_fail "transform_active = ${TRANSFORM_BYTE}, expected 1"
    fi

    EXPECTED_X=$((GEOM_W / 2))
    EXPECTED_Y=$((GEOM_H / 2))
    if [ "${PTR_X}" = "${EXPECTED_X}" ]; then
        c_check_pass "pointer_x seeded at geom_width/2 (${EXPECTED_X})"
    else
        c_check_fail "pointer_x = ${PTR_X}, expected ${EXPECTED_X}"
    fi
    if [ "${PTR_Y}" = "${EXPECTED_Y}" ]; then
        c_check_pass "pointer_y seeded at geom_height/2 (${EXPECTED_Y})"
    else
        c_check_fail "pointer_y = ${PTR_Y}, expected ${EXPECTED_Y}"
    fi

    if d_dmesg_has "D.3 transform active"; then
        c_check_pass "dmesg confirms D.3 transform active"
    else
        c_check_fail "dmesg missing D.3 transform-active message"
    fi
else
    # Geometry unknown: transform_active=0, pointer at (0, 0).
    if [ "${TRANSFORM_BYTE}" = "0" ]; then
        c_check_pass "transform_active = 0 (geometry unknown)"
    else
        c_check_fail "transform_active = ${TRANSFORM_BYTE}, expected 0"
    fi
    if d_dmesg_has "D.3 transform inactive"; then
        c_check_pass "dmesg confirms D.3 transform inactive"
    else
        c_check_fail "dmesg missing D.3 transform-inactive message"
    fi
fi

# --------------------------------------------------------------------
# Phase 4: D.1 focus reader infrastructure
# --------------------------------------------------------------------
#
# The focus file is created by a userspace compositor. During
# verification, no compositor is running, so the focus open will
# fail and inputfs will log the absent-with-retry message. This
# is the structural test: the kthread attempted the open and
# logged the expected diagnostic.

c_step "Phase 4: D.1 focus reader"

if d_dmesg_has "focus file"; then
    if d_dmesg_has "compositor not running"; then
        c_check_pass "focus open attempted; absent-and-retry message logged"
    else
        # File was found and opened. Unusual on a verification
        # bench; treat as informational.
        c_check_pass "focus file present and opened (compositor running?)"
    fi
else
    c_check_fail "no focus-related dmesg output; kthread may not have started"
fi

# --------------------------------------------------------------------
# Phase 5: D.5 enable tunable
# --------------------------------------------------------------------
#
# Toggle hw.inputfs.enable from 1 to 0 and back, verifying the
# valid bytes in the publication file headers flip correspondingly
# and the kthread logs the transition messages.

c_step "Phase 5: D.5 enable tunable"

ENABLE_INITIAL=$(d_sysctl_get hw.inputfs.enable)
if [ "${ENABLE_INITIAL}" = "1" ]; then
    c_check_pass "hw.inputfs.enable = 1 at start"
else
    c_check_fail "hw.inputfs.enable = ${ENABLE_INITIAL} at start, expected 1"
fi

STATE_VALID_PRE=$(d_state_byte "${D_STATE_OFF_VALID}")
EVENTS_VALID_PRE=$(d_events_byte "${D_EVENTS_OFF_VALID}")
if [ "${STATE_VALID_PRE}" = "1" ] && [ "${EVENTS_VALID_PRE}" = "1" ]; then
    c_check_pass "state and events valid bytes = 1 before toggle"
else
    c_check_fail "state.valid=${STATE_VALID_PRE}, events.valid=${EVENTS_VALID_PRE} (expected 1/1)"
fi

# Disable
if d_sysctl_set hw.inputfs.enable 0; then
    c_check_pass "hw.inputfs.enable set to 0"
else
    c_check_fail "could not set hw.inputfs.enable=0"
fi
sleep 1

STATE_VALID_OFF=$(d_state_byte "${D_STATE_OFF_VALID}")
EVENTS_VALID_OFF=$(d_events_byte "${D_EVENTS_OFF_VALID}")
if [ "${STATE_VALID_OFF}" = "0" ] && [ "${EVENTS_VALID_OFF}" = "0" ]; then
    c_check_pass "state and events valid bytes flipped to 0"
else
    c_check_fail "state.valid=${STATE_VALID_OFF}, events.valid=${EVENTS_VALID_OFF} (expected 0/0)"
fi

if d_dmesg_has "D.5 publication gated off"; then
    c_check_pass "dmesg confirms gated-off transition"
else
    c_check_fail "dmesg missing gated-off transition message"
fi

# Re-enable
if d_sysctl_set hw.inputfs.enable 1; then
    c_check_pass "hw.inputfs.enable set to 1"
else
    c_check_fail "could not set hw.inputfs.enable=1"
fi
sleep 1

STATE_VALID_ON=$(d_state_byte "${D_STATE_OFF_VALID}")
EVENTS_VALID_ON=$(d_events_byte "${D_EVENTS_OFF_VALID}")
if [ "${STATE_VALID_ON}" = "1" ] && [ "${EVENTS_VALID_ON}" = "1" ]; then
    c_check_pass "state and events valid bytes flipped back to 1"
else
    c_check_fail "state.valid=${STATE_VALID_ON}, events.valid=${EVENTS_VALID_ON} (expected 1/1)"
fi

if d_dmesg_has "D.5 publication gated on"; then
    c_check_pass "dmesg confirms gated-on transition"
else
    c_check_fail "dmesg missing gated-on transition message"
fi

# --------------------------------------------------------------------
# Phase 6: D.4 routing (informational)
# --------------------------------------------------------------------
#
# D.4 routing requires a live compositor or a synthetic focus
# writer to exercise. Without those, all events arrive with
# session_id = 0 (unrouted) and no leave/enter is synthesised.
# This phase does not run automated checks; it only prints a
# pointer to the manual procedure.

c_step "Phase 6: D.4 routing"

c_info "D.4 routing tests require a live compositor or a"
c_info "synthetic focus writer (not bundled in this script)."
c_info "See inputfs/docs/D_VERIFICATION.md for the manual"
c_info "procedure: write a focus file, generate input, observe"
c_info "session_id stamping and leave/enter synthesis."

# --------------------------------------------------------------------
# Phase 7: clean module unload
# --------------------------------------------------------------------

c_step "Phase 7: module unload"

if c_unload_module; then
    c_check_pass "kldunload inputfs"
else
    c_check_fail "kldunload inputfs"
fi

# --------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------

printf '\n========================================================\n'
printf '[d6 SUMMARY] %d passed, %d failed\n' \
    "${D_PASS_COUNT}" "${D_FAIL_COUNT}"
printf '========================================================\n'

if [ "${D_FAIL_COUNT}" = 0 ]; then
    c_say "Stage D automated checks passed."
    c_say "Now run the manual checklist in"
    c_say "inputfs/docs/D_VERIFICATION.md to complete verification,"
    c_say "in particular the D.4 routing tests with a live focus writer."
    exit 0
fi
exit 1
