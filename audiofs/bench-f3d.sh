#!/bin/sh
#
# audiofs F.3.d bench-and-diagnostic script.
#
# Verifies xrun event publish per ADR 0017. Parallel in shape to
# bench-f3b.sh: read-only checks first, then progressively more
# invasive bench tests. Each test prints a clear PASS or FAIL line.
#
# Usage:
#   ./audiofs/bench-f3d.sh                          # run all tests
#   ./audiofs/bench-f3d.sh --device /dev/audiofs0   # explicit device
#
# Requires:
#   - audiofs.ko loaded with the F.3.d kernel patch
#   - playtone built with --stall support
#   - audiofs_events_dump built
#   - root for the playtone invocations (run script with sudo, or
#     it will sudo each playtone call individually)

set -u

DEVICE="/dev/audiofs0"
UNIT="0"  # sysctl unit suffix (dev.audiofs.<UNIT>.*)

while [ $# -gt 0 ]; do
    case "$1" in
        --device)
            shift
            DEVICE="$1"
            # Extract the unit number from /dev/audiofsN.
            UNIT=$(echo "$DEVICE" | sed 's|/dev/audiofs||')
            ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unexpected argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PLAYTONE="$REPO_ROOT/audiofs/tools/playtone/playtone"
DUMP="$REPO_ROOT/audiofs/tools/audiofs_events_dump/audiofs_events_dump"

pass=0
fail=0

ok()   { printf "  [PASS] %s\n" "$1"; pass=$((pass + 1)); }
bad()  { printf "  [FAIL] %s\n" "$1"; fail=$((fail + 1)); }
note() { printf "         %s\n" "$1"; }

section() {
    printf "\n=== %s\n" "$1"
}

# ----------------------------------------------------------------
# 0. Preconditions
# ----------------------------------------------------------------

section "0. Preconditions"

if ! kldstat | grep -q audiofs; then
    bad "audiofs.ko is not loaded"
    note "load it with: sudo $REPO_ROOT/audiofs/build.sh load"
    note "cannot run bench tests; aborting"
    exit 1
fi
ok "audiofs.ko is loaded"

if [ ! -c "$DEVICE" ]; then
    bad "$DEVICE does not exist or is not a character device"
    note "cannot run bench tests; aborting"
    exit 1
fi
ok "$DEVICE present"

if [ ! -x "$PLAYTONE" ]; then
    bad "$PLAYTONE not found or not executable"
    note "build it with: (cd $REPO_ROOT/audiofs/tools/playtone && make)"
    exit 1
fi
ok "playtone present"

if [ ! -x "$DUMP" ]; then
    bad "$DUMP not found or not executable"
    note "build it with: (cd $REPO_ROOT/audiofs/tools/audiofs_events_dump && make)"
    exit 1
fi
ok "audiofs_events_dump present"

# ----------------------------------------------------------------
# 1. Static-symbol presence in the loaded module
# ----------------------------------------------------------------
#
# This test answers the diagnostic question: is the F.3.d
# kernel patch actually compiled into the loaded audiofs.ko?
# We check several known static functions; if ALL of them are
# absent from `nm` output, then the .ko has its symbol table
# stripped (in which case `nm` is a flawed diagnostic and we
# rely on behaviour tests instead). If some are present but
# audiofs_xrun_task is absent, the F.3.d patch did not compile in.

section "1. Symbol-table diagnostic"

KO="/boot/modules/audiofs.ko"
if [ ! -r "$KO" ]; then
    bad "$KO not readable; cannot check symbols"
else
    intr_present=$(nm "$KO" 2>/dev/null | grep -c "audiofs_intr_thread" || true)
    stream_present=$(nm "$KO" 2>/dev/null | grep -c "audiofs_stream_begin" || true)
    xrun_present=$(nm "$KO" 2>/dev/null | grep -c "audiofs_xrun_task" || true)

    note "audiofs_intr_thread:  $intr_present occurrence(s)"
    note "audiofs_stream_begin: $stream_present occurrence(s)"
    note "audiofs_xrun_task:    $xrun_present occurrence(s)"

    if [ "$intr_present" -eq 0 ] && [ "$stream_present" -eq 0 ]; then
        note "all static symbols absent: .ko has its symbol table stripped;"
        note "nm-based diagnostic is not useful here. Behaviour tests below"
        note "will tell us whether F.3.d is actually running."
        ok "symbol-table diagnostic skipped (stripped .ko)"
    elif [ "$xrun_present" -eq 0 ]; then
        bad "audiofs_xrun_task is NOT in the loaded .ko"
        note "other static symbols ARE present, so the .ko is not stripped;"
        note "the F.3.d patch did not compile into this module."
        note "rebuild and reload: sudo $REPO_ROOT/audiofs/build.sh all"
    else
        ok "audiofs_xrun_task symbol present in loaded .ko"
    fi
fi

# ----------------------------------------------------------------
# 2. Baseline sysctl state
# ----------------------------------------------------------------

section "2. Baseline sysctl state"

if ! sysctl -N "dev.audiofs.$UNIT.underflow_count" >/dev/null 2>&1; then
    bad "dev.audiofs.$UNIT.underflow_count sysctl not registered"
    note "audiofs is loaded but does not expose this sysctl; the loaded"
    note "module is older than F.3.c. cannot meaningfully test F.3.d."
    exit 1
fi
BASELINE_UFC=$(sysctl -n "dev.audiofs.$UNIT.underflow_count")
ok "dev.audiofs.$UNIT.underflow_count = $BASELINE_UFC (baseline)"

# Snapshot the events ring writer_seq.
BASELINE_SEQ=$("$DUMP" --header-only 2>&1 | grep writer_seq | sed 's/.*writer_seq=\([0-9]*\).*/\1/')
if [ -z "$BASELINE_SEQ" ]; then
    bad "could not parse writer_seq from audiofs_events_dump output"
    exit 1
fi
ok "events ring writer_seq = $BASELINE_SEQ (baseline)"

# ----------------------------------------------------------------
# 3. Regression: normal playback still works
# ----------------------------------------------------------------

section "3. Regression: normal playback (no stall)"

if sudo "$PLAYTONE" "$DEVICE" 1 >/tmp/playtone-normal.log 2>&1; then
    ok "playtone --no-stall succeeded"
    note "$(grep -E '^playtone:' /tmp/playtone-normal.log | head -1)"
else
    bad "playtone failed during normal-playback regression test"
    cat /tmp/playtone-normal.log | sed 's/^/         /'
    note "aborting; stall tests are meaningless if normal play is broken"
    exit 1
fi

POSTREG_UFC=$(sysctl -n "dev.audiofs.$UNIT.underflow_count")
note "underflow_count after normal play: $POSTREG_UFC"
if [ "$POSTREG_UFC" -gt "$BASELINE_UFC" ]; then
    note "underflow_count rose during normal play; this is unexpected"
    note "but not necessarily a F.3.d failure. continuing."
fi

# ----------------------------------------------------------------
# 4. Brief underrun (--stall 500)
# ----------------------------------------------------------------

section "4. Brief underrun test (--stall 500, 2 sec total)"

PREV_UFC=$(sysctl -n "dev.audiofs.$UNIT.underflow_count")
PREV_SEQ=$("$DUMP" --header-only 2>&1 | grep writer_seq | sed 's/.*writer_seq=\([0-9]*\).*/\1/')

if sudo "$PLAYTONE" --stall 500 "$DEVICE" 2 >/tmp/playtone-stall500.log 2>&1; then
    ok "playtone --stall 500 succeeded"
    grep -E '^playtone:' /tmp/playtone-stall500.log | sed 's/^/         /'
else
    bad "playtone --stall 500 failed"
    cat /tmp/playtone-stall500.log | sed 's/^/         /'
fi

POST_UFC=$(sysctl -n "dev.audiofs.$UNIT.underflow_count")
DELTA_UFC=$((POST_UFC - PREV_UFC))

if [ "$DELTA_UFC" -gt 0 ]; then
    ok "underflow_count increased by $DELTA_UFC (FIFOE fired)"
else
    bad "underflow_count did NOT increase (was $PREV_UFC, still $POST_UFC)"
    note "either the controller's FIFO did not underrun, OR the F.3.c"
    note "FIFOE-detection path is not active. without FIFOE, there is"
    note "nothing for F.3.d to publish."
fi

POST_SEQ=$("$DUMP" --header-only 2>&1 | grep writer_seq | sed 's/.*writer_seq=\([0-9]*\).*/\1/')
NEW_EVENTS=$((POST_SEQ - PREV_SEQ))
note "events ring writer_seq: $PREV_SEQ -> $POST_SEQ (+$NEW_EVENTS events)"

section "4a. All events from brief-underrun test"
"$DUMP" --since "$PREV_SEQ" | sed 's/^/  /'

section "4b. xrun events only from brief-underrun test"
XRUN_COUNT=$("$DUMP" --type xrun --since "$PREV_SEQ" 2>&1 | grep -c "^seq=" || true)
"$DUMP" --type xrun --since "$PREV_SEQ" | sed 's/^/  /'

if [ "$XRUN_COUNT" -gt 0 ]; then
    ok "$XRUN_COUNT xrun event(s) published"
else
    bad "no xrun events were published"
    if [ "$DELTA_UFC" -gt 0 ]; then
        note "FIFOE fired (underflow_count rose) but no xrun event reached"
        note "the ring. The F.3.d ithread-to-taskqueue path did not run."
        note "Likely cause: the loaded audiofs.ko does not contain F.3.d."
    fi
fi

# ----------------------------------------------------------------
# 5. Sustained underrun (--stall 1500)
# ----------------------------------------------------------------

section "5. Sustained-underrun test (--stall 1500, 3 sec total)"

PREV_UFC=$(sysctl -n "dev.audiofs.$UNIT.underflow_count")
PREV_SEQ=$("$DUMP" --header-only 2>&1 | grep writer_seq | sed 's/.*writer_seq=\([0-9]*\).*/\1/')

if sudo "$PLAYTONE" --stall 1500 "$DEVICE" 3 >/tmp/playtone-stall1500.log 2>&1; then
    ok "playtone --stall 1500 succeeded"
    grep -E '^playtone:' /tmp/playtone-stall1500.log | sed 's/^/         /'
else
    bad "playtone --stall 1500 failed"
    cat /tmp/playtone-stall1500.log | sed 's/^/         /'
fi

POST_UFC=$(sysctl -n "dev.audiofs.$UNIT.underflow_count")
DELTA_UFC=$((POST_UFC - PREV_UFC))

if [ "$DELTA_UFC" -gt 0 ]; then
    ok "underflow_count increased by $DELTA_UFC (sustained FIFOE fired)"
else
    bad "underflow_count did NOT increase"
fi

POST_SEQ=$("$DUMP" --header-only 2>&1 | grep writer_seq | sed 's/.*writer_seq=\([0-9]*\).*/\1/')
NEW_EVENTS=$((POST_SEQ - PREV_SEQ))
note "events ring writer_seq: $PREV_SEQ -> $POST_SEQ (+$NEW_EVENTS events)"

section "5a. xrun events from sustained-underrun test"
"$DUMP" --type xrun --since "$PREV_SEQ" | sed 's/^/  /'

# Check for coalesced flag in any of the new xrun events.
COALESCED=$("$DUMP" --type xrun --since "$PREV_SEQ" 2>&1 | grep -c "coalesced" || true)
SUSTAINED_XRUN=$("$DUMP" --type xrun --since "$PREV_SEQ" 2>&1 | grep -c "^seq=" || true)

if [ "$SUSTAINED_XRUN" -gt 0 ]; then
    ok "$SUSTAINED_XRUN xrun event(s) published"
    # Coalescing is opportunistic. The taskqueue's pending-bit folds
    # repeated enqueues into one task invocation only if the previous
    # task hasn't finished yet. On a fast system with ~21 ms between
    # BCIS interrupts (the fragment rate), task dispatch typically
    # completes well within that window and coalescing does not occur.
    # Per the post-bench amendment in ADR 0017, that is acceptable:
    # one event per shortfall with sample-accurate gap_frames is more
    # informative than coalesced events with summed gaps.
    if [ "$COALESCED" -gt 0 ]; then
        ok "$COALESCED event(s) have AUDIOFS_EVFLAG_COALESCED set"
        if [ "$DELTA_UFC" -gt "$SUSTAINED_XRUN" ]; then
            note "coalescing factor: $DELTA_UFC underflows -> $SUSTAINED_XRUN events"
        fi
    else
        note "no coalesced events (each shortfall drained before next arrived)"
        note "this is acceptable; coalescing is opportunistic, not required"
    fi
else
    bad "no xrun events from sustained-underrun test"
fi

# ----------------------------------------------------------------
# 6. dmesg sanity check
# ----------------------------------------------------------------

section "6. dmesg sanity"

DMESG_TAIL=$(dmesg | tail -30)
if echo "$DMESG_TAIL" | grep -q -E "panic|WITNESS|DESE|trap"; then
    bad "dmesg shows suspicious entries (panic, WITNESS, DESE, or trap)"
    echo "$DMESG_TAIL" | sed 's/^/         /'
else
    ok "no panics, WITNESS complaints, DESE errors, or traps in recent dmesg"
fi

# ----------------------------------------------------------------
# Summary
# ----------------------------------------------------------------

section "Summary"
printf "  passed: %d\n" "$pass"
printf "  failed: %d\n" "$fail"

if [ "$fail" -eq 0 ]; then
    printf "\nF.3.d bench: PASS\n"
    printf "Per ADR 0017 closure criterion 7: mark AD-3 F.3.d [x] in BACKLOG.\n"
    exit 0
else
    printf "\nF.3.d bench: FAIL (%d test(s) failed)\n" "$fail"
    printf "F.3.d is NOT closed. See per-test output for diagnostics.\n"
    exit 1
fi
