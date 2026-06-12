#!/bin/sh
# ad36-harvest-diag.sh: localise the break in semadrawd's
# inputfs-event harvest path.
#
# Context
#
#   ad36-bench.sh established that:
#     - inputfs publishes pointer.motion events at the ring layer
#       (inputdump sees them)
#     - semadrawd's pump_diagnostic events all show
#       state_valid=false, meaning Daemon.last_motion_seen never
#       flips true
#     - The pump IS running (events are emitted) and the cursor
#       surface IS owned by the daemon
#
#   The remaining question is: where does the inputfs event flow
#   break between "in the kernel ring" and "harvested into
#   Daemon.last_motion_x/y" at semadrawd.zig:1135?
#
#   The candidate breaks, in order along the path:
#
#     1. semadrawd's InputfsInput failed to attach (no drain runs)
#     2. drain runs but consistently returns 0 events
#     3. drain returns events but no source_role match at the
#        harvest (semadrawd.zig:1135-1140)
#
# What this script samples
#
#   Across all semadrawd log files under /var/log/utf/semadrawd/
#   (`current` plus all `@*.s`/`@*.u` archives, which together cover
#   the full lifetime of the running daemon plus older sessions):
#
#     - inputfs attach evidence ("ring opened, starting from seq N")
#     - inputfs attach failures ("ring at ... unavailable")
#     - drain overrun warnings ("inputfs ring overrun")
#     - pump_diagnostic counts, split by state_valid
#     - daemon-state markers: cursor surface created, privileges
#       dropped, listening on socket
#     - client connection counts (handshake completions)
#
#   For each marker the script reports both totals and per-archive
#   counts so a careful reader can correlate with rotation
#   timestamps.
#
# Usage
#
#   sudo sh scripts/ad36-harvest-diag.sh
#   AD36_DIAG_OUTDIR=/var/log/ad36-diag sudo sh scripts/ad36-harvest-diag.sh
#   AD36_DIAG_LOGDIR=/var/log/utf/semadrawd sudo sh scripts/ad36-harvest-diag.sh
#
#   sudo is required: log files are owned root.
#
#   The script writes a report to the outdir; it does NOT modify
#   any log file, restart any daemon, or change any system state.

set -eu

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------

LOGDIR="${AD36_DIAG_LOGDIR:-/var/log/utf/semadrawd}"
OUTDIR_ROOT="${AD36_DIAG_OUTDIR_ROOT:-/tmp}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTDIR="${OUTDIR_ROOT}/ad36-harvest-diag-${TIMESTAMP}"

# ----------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    printf 'ad36-harvest-diag.sh: must run with sudo (log files are root-owned).\n' >&2
    exit 2
fi

if [ ! -d "$LOGDIR" ]; then
    printf 'ad36-harvest-diag.sh: log directory not found: %s\n' "$LOGDIR" >&2
    printf 'Override with AD36_DIAG_LOGDIR=<path>\n' >&2
    exit 2
fi

mkdir -p "$OUTDIR"
chmod 0755 "$OUTDIR"

REPORT="${OUTDIR}/REPORT.txt"

# Collect the file list once. We want archives sorted by name
# (s6-log archive names are TAI64N timestamps, so lexical sort is
# chronological), then `current` last.
LOGFILES=""
for f in "$LOGDIR"/@*.s "$LOGDIR"/@*.u; do
    [ -f "$f" ] && LOGFILES="$LOGFILES $f"
done
[ -f "$LOGDIR/current" ] && LOGFILES="$LOGFILES $LOGDIR/current"

if [ -z "$LOGFILES" ]; then
    printf 'ad36-harvest-diag.sh: no log files found under %s\n' "$LOGDIR" >&2
    exit 2
fi

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

heading() {
    {
        printf '\n========================================================================\n'
        printf '%s\n' "$1"
        printf '========================================================================\n'
    } | tee -a "$REPORT"
}

kv() {
    printf '  %-44s : %s\n' "$1" "$2" | tee -a "$REPORT"
}

# Count occurrences of a regex across all log files. After the
# call, the shell global LAST_TOTAL holds the total.
#
# Implementation note: an earlier version of this function used a
# temporary file (.last_total) as the channel between this
# function and the caller. That approach reliably failed on
# FreeBSD's /bin/sh: variable updates inside the inner brace-grouped
# pipe `{ ... } | tee` happen in a subshell, but the file write
# AFTER the pipe was meant to be in the parent shell. Empirically,
# FreeBSD's sh appears to write the file but the next subshell's
# command-substitution read came back zero. Setting a global
# variable directly works the same on every shell because the
# function body itself runs in the parent shell when invoked
# without a pipe; only the inner `{ ... } | tee` is the
# subshell.
LAST_TOTAL=0
count_marker() {
    label="$1"
    pattern="$2"

    total=0
    body=""
    for f in $LOGFILES; do
        n=$(grep -cE "$pattern" "$f" 2>/dev/null || true)
        n=${n:-0}
        total=$((total + n))
        short=$(basename "$f")
        body=$(printf '%s\n    %-50s : %d' "$body" "$short" "$n")
    done

    {
        printf '\n  %s\n' "$label"
        printf '    pattern: %s\n' "$pattern"
        printf '%s\n' "$body"
        printf '    %-50s : %d\n' "TOTAL" "$total"
    } | tee -a "$REPORT"
    LAST_TOTAL="$total"
}

# ----------------------------------------------------------------------
# Report header
# ----------------------------------------------------------------------

{
    printf 'AD-36 harvest-path diagnostic report\n'
    printf 'Generated %s\n' "$(date)"
    printf 'Host: %s\n' "$(hostname)"
    printf 'Kernel: %s\n' "$(uname -sr)"
    printf '\n'
} > "$REPORT"

heading "Inputs"

kv "log directory" "$LOGDIR"
kv "output dir" "$OUTDIR"
printf '\n  Log files (chronological):\n' | tee -a "$REPORT"
for f in $LOGFILES; do
    sz=$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f" 2>/dev/null || echo "?")
    mt=$(stat -f '%Sm' "$f" 2>/dev/null || stat -c '%y' "$f" 2>/dev/null || echo "?")
    printf '    %-50s  %12s bytes   %s\n' "$(basename "$f")" "$sz" "$mt" | tee -a "$REPORT"
done

# ----------------------------------------------------------------------
# Step 1: daemon-state markers (did the daemon get past init?)
# ----------------------------------------------------------------------

heading "Daemon-state markers"

count_marker "Daemon startup banner (env-detection line)" \
    'info\(semadrawd\): SEMADRAW_PRIVILEGED_UID'
startup_count=$LAST_TOTAL

count_marker "/dev/draw open success" \
    'opened /dev/draw'
draw_open_count=$LAST_TOTAL

count_marker "Cursor surface created" \
    'cursor surface created'
cursor_count=$LAST_TOTAL

count_marker "Cursor surface init failure" \
    'cursor surface init failed'
cursor_fail_count=$LAST_TOTAL

count_marker "Privilege drop completed" \
    'dropped privileges'
privdrop_count=$LAST_TOTAL

count_marker "Listening on socket" \
    'semadrawd starting on'
listening_count=$LAST_TOTAL

count_marker "Client handshake completions" \
    'client [0-9]+ completed handshake'
handshake_count=$LAST_TOTAL

# ----------------------------------------------------------------------
# Step 2: inputfs attach evidence
# ----------------------------------------------------------------------

heading "inputfs attach evidence"

count_marker "inputfs ring opened" \
    'inputfs_input.*ring opened, starting from seq'
ring_open_count=$LAST_TOTAL

count_marker "inputfs ring unavailable (init failed)" \
    'inputfs_input.*ring at .* unavailable'
ring_unavail_count=$LAST_TOTAL

# Capture the latest "ring opened" line specifically so we know
# what seq the current daemon started from.
{
    printf '\n  Latest "ring opened" lines (one per session):\n'
    grep -hE 'inputfs_input.*ring opened, starting from seq' $LOGFILES 2>/dev/null | tail -5 | sed 's/^/    /'
} | tee -a "$REPORT"

# ----------------------------------------------------------------------
# Step 3: harvest activity evidence
# ----------------------------------------------------------------------

heading "Harvest activity evidence"

count_marker "inputfs ring overrun warnings (drain advancing)" \
    'inputfs ring overrun'
overrun_count=$LAST_TOTAL

count_marker "gesture_recognizer.handleEvent failures" \
    'gesture_recognizer\.handleEvent failed'
gesture_fail_count=$LAST_TOTAL

# ----------------------------------------------------------------------
# Step 4: pump_diagnostic counts
# ----------------------------------------------------------------------

heading "pump_diagnostic counts"

count_marker "pump_diagnostic total" \
    'pump_diagnostic'
pump_total=$LAST_TOTAL

count_marker "pump_diagnostic with state_valid:true" \
    '"state_valid":true'
state_valid_true=$LAST_TOTAL

count_marker "pump_diagnostic with state_valid:false" \
    '"state_valid":false'
state_valid_false=$LAST_TOTAL

# ----------------------------------------------------------------------
# Step 5: pump rate sanity check
# ----------------------------------------------------------------------

heading "Pump rate sanity check"

# Pull first and last pump_diagnostic ts_wall_ns across the whole
# log set. If they bracket a wide window with thousands of events,
# we can compute average rate. If they bracket nothing, the pump
# never ran.
first_ts=$(grep -hoE '"ts_wall_ns":[0-9]+' $LOGFILES 2>/dev/null \
    | sed 's/"ts_wall_ns"://' | head -1)
last_ts=$(grep -hoE '"ts_wall_ns":[0-9]+' $LOGFILES 2>/dev/null \
    | sed 's/"ts_wall_ns"://' | tail -1)

if [ -n "$first_ts" ] && [ -n "$last_ts" ] && [ "$first_ts" != "$last_ts" ]; then
    # Wall-time delta in seconds (ns / 1e9). Integer arithmetic in /bin/sh
    # so we lose some precision; that's fine for an at-a-glance rate.
    delta_ns=$((last_ts - first_ts))
    delta_s=$((delta_ns / 1000000000))
    if [ "$delta_s" -gt 0 ] && [ "$pump_total" -gt 0 ]; then
        rate=$((pump_total / delta_s))
    else
        rate=0
    fi
    kv "first ts_wall_ns" "$first_ts"
    kv "last ts_wall_ns"  "$last_ts"
    kv "window (ns)"      "$delta_ns"
    kv "window (s)"       "$delta_s"
    kv "pump events / s (avg)" "$rate"
else
    kv "first ts_wall_ns" "(none)"
    kv "last ts_wall_ns"  "(none)"
    kv "pump events / s"  "(undefined)"
fi

# ----------------------------------------------------------------------
# Step 6: diagnosis
# ----------------------------------------------------------------------

heading "Diagnosis"

{
printf '\n'

# Layer 1: did the daemon get up?
if [ "$startup_count" -eq 0 ]; then
    printf 'STARTUP: no startup banner found across any log file.\n'
    printf '         Either the daemon never started under s6 supervision,\n'
    printf '         or all archives predate s6-log capture. Cannot diagnose\n'
    printf '         further without log evidence.\n'
    exit 0
fi

if [ "$cursor_count" -eq 0 ]; then
    if [ "$cursor_fail_count" -gt 0 ]; then
        printf 'STARTUP: cursor surface init FAILED (count=%d). pumpCursorPosition\n' "$cursor_fail_count"
        printf '         will silently no-op (line 684 early return on null\n'
        printf '         cursor_surface_id). The break is in initCursorSurface.\n'
        exit 0
    else
        printf 'STARTUP: no cursor-creation log line found. Either the daemon\n'
        printf '         never reached initCompositor line 956, or all the\n'
        printf '         relevant archives have been rotated out.\n'
        printf '         Check the oldest @*.s archives manually.\n'
    fi
fi

# Layer 2: did inputfs attach?
if [ "$ring_open_count" -eq 0 ]; then
    printf 'INPUTFS: "ring opened" never logged.\n'
    if [ "$ring_unavail_count" -gt 0 ]; then
        printf '         InputfsInput.init returned null %d time(s); the daemon\n' "$ring_unavail_count"
        printf '         is in the retry path with quiet=true and may never\n'
        printf '         latch. Check /var/run/sema/input/events permissions\n'
        printf '         and the inputfs kernel module load order.\n'
    else
        printf '         No init failures logged either. Possibly the\n'
        printf '         InputfsInput.init code path was not even reached.\n'
    fi
    exit 0
fi

# Layer 3: is drain advancing?
if [ "$pump_total" -eq 0 ]; then
    printf 'PUMP:    no pump_diagnostic events logged across any file.\n'
    printf '         pumpCursorPosition is not being reached, or\n'
    printf '         UTF_PUMP_INSTRUMENT=1 was not in the daemon environment.\n'
    exit 0
fi

if [ "$state_valid_true" -gt 0 ]; then
    printf 'AD-36:   state_valid=true seen %d time(s). The harvest works\n' "$state_valid_true"
    printf '         at least intermittently. If the bench-script run showed\n'
    printf '         only state_valid=false in its specific window, that may\n'
    printf '         be a timing artifact of when the daemon attached vs when\n'
    printf '         the mouse was moved. AD-36 may be effectively working.\n'
    exit 0
fi

# state_valid=true is zero across the whole log set; the harvest
# never updated last_motion_seen.
printf 'AD-36:   state_valid=true count is ZERO across the entire log\n'
printf '         set (state_valid=false count: %d). The harvest never\n' "$state_valid_false"
printf '         assigned last_motion_seen=true.\n'
printf '\n'

if [ "$overrun_count" -gt 0 ]; then
    printf 'HARVEST: ring overrun warning fired %d time(s). drain IS\n' "$overrun_count"
    printf '         running and advancing through the ring. Either:\n'
    printf '\n'
    printf '         (a) the events drain returns do not match the type\n'
    printf '             filter at semadrawd.zig:1135-1140 (source_role\n'
    printf '             != SOURCE_POINTER or event_type != POINTER_MOTION).\n'
    printf '             Possible cause: events dispatched to the typed\n'
    printf '             mouse pipeline correctly but the side-channel\n'
    printf '             append produces a different shape, or the source\n'
    printf '             constants disagree between this drain path and the\n'
    printf '             harvest.\n'
    printf '\n'
    printf '         (b) drain returns 0 events even when the writer is\n'
    printf '             ahead. The torn-write check at shared/src/input.zig\n'
    printf '             line 894 (seq1 != next) may be failing consistently\n'
    printf '             because the slots have been overwritten between\n'
    printf '             the overrun fast-forward and the actual read.\n'
    printf '\n'
    printf '         Next step: instrument drain() and dispatch() with\n'
    printf '         per-event counters to discriminate.\n'
else
    printf 'HARVEST: no ring overrun warnings logged. drain may not be\n'
    printf '         running, or it is running but the writer has not yet\n'
    printf '         exceeded the ring capacity in any single drain gap.\n'
    printf '\n'
    printf '         For the AD-36 bench scenario, inputdump observed seq\n'
    printf '         1147..3139 (1993 events) over 10 seconds. With a\n'
    printf '         1024-slot ring, the writer is well past the wrap\n'
    printf '         distance. The absence of overrun warnings means\n'
    printf '         either:\n'
    printf '\n'
    printf '         (a) drain is not being called at all, or\n'
    printf '         (b) the overrun branch is not firing because\n'
    printf '             earliest_seq is still 1 (writer is updating it\n'
    printf '             incorrectly), or\n'
    printf '         (c) drain is called but pollEvents takes the\n'
    printf '             "inputfs == null" retry branch consistently\n'
    printf '             (the InputfsInput never latched in the current\n'
    printf '             session).\n'
    printf '\n'
    printf '         Check: does the LATEST "ring opened" line correspond\n'
    printf '         to the current daemon session? If yes, latching\n'
    printf '         worked but drain is not being called. If no, the\n'
    printf '         current daemon is in the retry path.\n'
fi
} | tee -a "$REPORT"

# ----------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------

heading "Outputs"
kv "Report" "$REPORT"

exit 0
