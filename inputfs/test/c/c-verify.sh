#!/bin/sh
# c-verify.sh: Stage C acceptance test for inputfs.
#
# Verifies the deliverables of Stage C.1 through C.4 against
# their specifications:
#
#   C.1: shared/src/input.zig publication-region library
#        (verified via the in-tree unit tests, run separately;
#        this script does not duplicate that.)
#   C.2: kernel state region writer
#        (state file at correct size, header matches spec,
#        device inventory matches dmesg attach lines)
#   C.3: kernel event ring writer
#        (events file at correct size, header matches spec,
#        lifecycle.attach events one per device, seqs monotonic)
#   C.4: inputdump CLI
#        (binary builds, all four subcommands run, throwaway
#        is gone)
#
# Manual mouse / button verification is described in
# inputfs/docs/C_VERIFICATION.md and not run automatically.
#
# Usage:
#   sudo sh c-verify.sh
#
# Exit codes:
#   0 all checks passed
#   1 one or more checks failed
#   2 precondition failure (missing tool, build artifact, etc.)
#   3 user aborted

set -u

C_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "${C_SELF_DIR}/c-fixtures.sh"

# --------------------------------------------------------------------
# Phase 0: preconditions
# --------------------------------------------------------------------

c_step "Phase 0: preconditions"

c_check_root || exit 2
c_check_inputdump_built || exit 2
c_check_throwaway_absent || exit 2
c_check_module_built || exit 2
c_check_tmpfs || exit 2

c_say "all preconditions met"

# --------------------------------------------------------------------
# Phase 1: clean module load
# --------------------------------------------------------------------

c_step "Phase 1: module load"

# Capture pre-load M_INPUTFS allocation. If the module was already
# loaded and we just unloaded it, residual bytes here would indicate
# a leak in the unload path; we'll re-check after our own unload at
# the end.
c_unload_module || exit 1
pre_load_bytes=$(c_inputfs_malloc_bytes)
c_info "M_INPUTFS bytes before load: ${pre_load_bytes:-0}"

if c_load_module; then
    c_check_pass "kldload inputfs"
else
    c_check_fail "kldload inputfs"
    exit 1
fi

# Give the kthread time to open both files and run an initial sync.
# 250 ms is generous; the kthread typically opens within a few ms.
sleep 1

# --------------------------------------------------------------------
# Phase 2: publication regions exist with correct sizes and magics
# --------------------------------------------------------------------

c_step "Phase 2: publication region files"

c_expect_files_present || true
c_expect_file_size "${C_STATE_PATH}" "${C_STATE_SIZE}" || true
c_expect_file_size "${C_EVENTS_PATH}" "${C_EVENTS_SIZE}" || true
c_expect_magic "${C_STATE_PATH}" "INST" 0 || true
c_expect_magic "${C_EVENTS_PATH}" "INVE" 0 || true
c_expect_version_byte "${C_STATE_PATH}" 1 4 || true
c_expect_version_byte "${C_EVENTS_PATH}" 1 4 || true

# --------------------------------------------------------------------
# Phase 3: state region content via inputdump
# --------------------------------------------------------------------

c_step "Phase 3: state region content"

# At least one device must have attached. The bare-metal test bench
# has six (ELECOM mouse, HAILUCK touchpad x2, Broadcom Bluetooth x2,
# Apple Keyboard); we accept any non-zero count to keep this script
# portable to other hardware.
c_expect_device_count_at_least 1 || true

# Sanity check on inputdump itself: state, devices, events all
# return without error and produce non-empty output.
if "${C_INPUTDUMP}" state >/dev/null 2>&1; then
    c_check_pass "inputdump state runs"
else
    c_check_fail "inputdump state failed"
fi

if "${C_INPUTDUMP}" devices >/dev/null 2>&1; then
    c_check_pass "inputdump devices runs"
else
    c_check_fail "inputdump devices failed"
fi

# --------------------------------------------------------------------
# Phase 4: event ring content
# --------------------------------------------------------------------

c_step "Phase 4: event ring content"

# At module load time, one lifecycle.attach event is published per
# attaching device. We expect attaches == device_count.
c_expect_lifecycle_attach_per_device || true

# Sequence numbers must be strictly monotonic across the ring's
# current contents.
c_expect_seq_monotonic || true

# inputdump events should run without error.
if "${C_INPUTDUMP}" events >/dev/null 2>&1; then
    c_check_pass "inputdump events runs"
else
    c_check_fail "inputdump events failed"
fi

# --------------------------------------------------------------------
# Phase 5: liveness (last_sequence advances under real input)
# --------------------------------------------------------------------
#
# This phase is only meaningful when there is ongoing input. We
# run it but treat a flat last_sequence as informational, not a
# hard failure: the test bench may be idle when the script runs.

c_step "Phase 5: liveness"

c_expect_writer_seq_advances || c_info \
    "(no advance observed in 1s; this is OK if no input is being driven.)"

# --------------------------------------------------------------------
# Phase 6: clean module unload
# --------------------------------------------------------------------

c_step "Phase 6: module unload"

if c_unload_module; then
    c_check_pass "kldunload inputfs"
else
    c_check_fail "kldunload inputfs"
fi

# Files should be gone (or at least re-created on next load).
# tmpfs preserves them across module unload only because the
# module does not delete them in MOD_UNLOAD; we treat their
# presence-or-absence as informational.
if [ -e "${C_STATE_PATH}" ] || [ -e "${C_EVENTS_PATH}" ]; then
    c_info "publication files still present after unload (expected on tmpfs)"
fi

# Memory-leak check: M_INPUTFS bytes should return to the pre-load
# baseline. A growing baseline across many load/unload cycles would
# indicate a leak; a single mismatch can still be a bug.
post_unload_bytes=$(c_inputfs_malloc_bytes)
c_info "M_INPUTFS bytes after unload: ${post_unload_bytes:-0}"

if [ "${post_unload_bytes:-0}" = "${pre_load_bytes:-0}" ]; then
    c_check_pass "M_INPUTFS bytes returned to baseline"
else
    c_check_fail "M_INPUTFS bytes: ${pre_load_bytes:-0} -> ${post_unload_bytes:-0}"
fi

# --------------------------------------------------------------------
# Phase 7: reload sanity
# --------------------------------------------------------------------
#
# Verify the module survives a load/unload/reload cycle. State and
# events files should be re-initialised on reload, devices should
# re-attach, lifecycle events should fire again with seq=1..N.

c_step "Phase 7: reload sanity"

if c_load_module; then
    c_check_pass "kldload inputfs (second time)"
else
    c_check_fail "kldload inputfs (second time)"
    exit 1
fi
sleep 1

c_expect_files_present || true
c_expect_file_size "${C_STATE_PATH}" "${C_STATE_SIZE}" || true
c_expect_file_size "${C_EVENTS_PATH}" "${C_EVENTS_SIZE}" || true
c_expect_lifecycle_attach_per_device || true
c_expect_seq_monotonic || true

if c_unload_module; then
    c_check_pass "kldunload inputfs (second time)"
else
    c_check_fail "kldunload inputfs (second time)"
fi

# --------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------

printf '\n========================================================\n'
printf '[c5 SUMMARY] %d passed, %d failed\n' \
    "${C_PASS_COUNT}" "${C_FAIL_COUNT}"
printf '========================================================\n'

if [ "${C_FAIL_COUNT}" = 0 ]; then
    c_say "Stage C automated checks passed."
    c_say "Now run the manual mouse/button checklist in"
    c_say "inputfs/docs/C_VERIFICATION.md to complete verification."
    exit 0
fi
exit 1
