#!/bin/sh
# ad36-bench.sh: capture data for the AD-36 / AD-38 bench
# verification.
#
# Purpose
#
#   AD-36 changed pumpCursorPosition to read pointer position from
#   Daemon.last_motion_x/y, populated by the main-loop harvest from
#   inputfs event-ring pointer.motion events. The closure criterion
#   is that pump_diagnostic events show state_valid=true with non-
#   stale ps_x, ps_y under cursor motion.
#
#   2026-05-24 bench observed: all pump_diagnostic events show
#   state_valid=false, ps_x=0, ps_y=0, even with cursor motion
#   happening. This script captures structured evidence to localise
#   the break in the chain:
#
#     - Does inputfs publish pointer.motion events to its ring?
#       (inputdump answers this directly.)
#     - Does the pump_diagnostic event stream show any state_valid
#       transitions during the same window?
#       (semadrawd's s6-log answers this.)
#
#   Outputs are saved under /tmp/ad36-bench-<timestamp>/ for later
#   inspection. The script writes nothing to the system, touches
#   no sysctls, restarts no daemons.
#
# Usage
#
#   sudo sh scripts/ad36-bench.sh                # default 10s window
#   AD36_DURATION_S=20 sudo sh scripts/ad36-bench.sh
#   AD36_OUTDIR=/var/log/ad36 sudo sh scripts/ad36-bench.sh
#
#   Requires sudo because /var/log/utf/ and /dev/inputfs are owned
#   by root / _semadraw with restrictive perms. The script does not
#   need write access to anything other than its own outdir.
#
# Procedure
#
#   1. Verifies the supervised daemons are up (semadrawd at
#      minimum).
#   2. Snapshots pre-capture counters from
#      /var/log/utf/semadrawd/current.
#   3. Prompts the operator to start moving the mouse.
#   4. Runs inputdump events --watch --role pointer for
#      $AD36_DURATION_S seconds, capturing all pointer.motion
#      events visible at the kernel ring layer.
#   5. Snapshots post-capture counters.
#   6. Extracts the pump_diagnostic events emitted during the
#      window.
#   7. Prints a structured summary that names which layer in the
#      chain (inputfs ring vs semadrawd harvest vs pump output)
#      observed motion.

set -eu

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------

DURATION_S="${AD36_DURATION_S:-10}"
OUTDIR_ROOT="${AD36_OUTDIR:-/tmp}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTDIR="${OUTDIR_ROOT}/ad36-bench-${TIMESTAMP}"

INPUTDUMP="${INPUTDUMP:-/usr/local/bin/inputdump}"
SEMADRAWD_LOG="${SEMADRAWD_LOG:-/var/log/utf/semadrawd/current}"
SEMADRAWD_SVC="${SEMADRAWD_SVC:-/var/service/utf/semadrawd}"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# Print a heading; goes to both terminal and the report file.
heading() {
    msg="$1"
    printf '\n========================================================================\n'
    printf '%s\n' "$msg"
    printf '========================================================================\n'
}

# Append a key=value pair to the report.
report_kv() {
    printf '%-32s : %s\n' "$1" "$2" >> "${OUTDIR}/REPORT.txt"
}

# Print and tee to report.
report_say() {
    printf '%s\n' "$1" | tee -a "${OUTDIR}/REPORT.txt"
}

# ----------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------

heading "Preflight"

if [ "$(id -u)" -ne 0 ]; then
    printf 'ad36-bench.sh: must be run with sudo (needs read access to /var/log/utf/semadrawd/current and /dev/inputfs).\n' >&2
    exit 2
fi

if [ ! -x "$INPUTDUMP" ]; then
    printf 'ad36-bench.sh: inputdump not found at %s. Set INPUTDUMP=/path/to/inputdump or run install.sh first.\n' "$INPUTDUMP" >&2
    exit 2
fi

if [ ! -r "$SEMADRAWD_LOG" ]; then
    printf 'ad36-bench.sh: semadrawd log not readable at %s. Is utf-supervisor up?\n' "$SEMADRAWD_LOG" >&2
    exit 2
fi

# Check that semadrawd is supervised and up. s6-svstat exits 0 iff
# it can read the supervise directory and the service has been
# brought up; we further parse the output for the "up" token.
if ! command -v s6-svstat >/dev/null 2>&1; then
    printf 'ad36-bench.sh: s6-svstat not in PATH. Is s6 installed?\n' >&2
    exit 2
fi

svstat_out=$(s6-svstat "$SEMADRAWD_SVC" 2>&1) || {
    printf 'ad36-bench.sh: s6-svstat against %s failed:\n%s\n' "$SEMADRAWD_SVC" "$svstat_out" >&2
    exit 2
}

case "$svstat_out" in
    up\ *)
        ;;
    *)
        printf 'ad36-bench.sh: semadrawd is not up; current state:\n  %s\n' "$svstat_out" >&2
        printf 'Bring it up first with: sudo service utf-supervisor start\n' >&2
        exit 2
        ;;
esac

mkdir -p "$OUTDIR"
chmod 0755 "$OUTDIR"

# Initial report header.
{
    printf 'AD-36 bench capture report\n'
    printf 'Generated %s\n' "$(date)"
    printf 'Host: %s\n' "$(hostname)"
    printf 'Kernel: %s\n' "$(uname -sr)"
    printf 'Duration: %ss\n' "$DURATION_S"
    printf '\n'
} > "${OUTDIR}/REPORT.txt"

report_kv 'inputdump'         "$INPUTDUMP"
report_kv 'semadrawd log'     "$SEMADRAWD_LOG"
report_kv 'semadrawd svstat'  "$svstat_out"
report_kv 'output dir'        "$OUTDIR"

# ----------------------------------------------------------------------
# Pre-capture snapshot
# ----------------------------------------------------------------------

heading "Pre-capture snapshot"

# Total log line count and pump_diagnostic count at start. Recording
# these lets us slice out exactly the events emitted during the
# capture window.
pre_log_lines=$(wc -l < "$SEMADRAWD_LOG")
pre_pump_count=$(grep -c pump_diagnostic "$SEMADRAWD_LOG" || true)
pre_state_valid=$(grep -c '"state_valid":true' "$SEMADRAWD_LOG" || true)

report_kv 'pre log lines'        "$pre_log_lines"
report_kv 'pre pump_diagnostic'  "$pre_pump_count"
report_kv 'pre state_valid:true' "$pre_state_valid"

# ----------------------------------------------------------------------
# Capture window
# ----------------------------------------------------------------------

heading "Capture window"

cat <<EOF

Starting capture in 3 seconds.

When the capture starts, MOVE THE MOUSE on the local iMac for the
next ${DURATION_S} seconds. Drawing small circles is enough; the
event ring will record every motion delta the device produces.

The capture stops automatically after ${DURATION_S} seconds; there
is nothing to press.

EOF

# Brief countdown so the operator can switch to the iMac.
sleep 1; printf '  3...\n'
sleep 1; printf '  2...\n'
sleep 1; printf '  1...\n'
printf '  GO -- move the mouse\n\n'

CAPTURE_START_NS=$(date +%s%N 2>/dev/null || date +%s)

# Run inputdump events with role=pointer for the duration.
# --watch keeps it streaming; we bound the lifetime with the OS
# timeout(1) command. timeout exits with the program's exit code or
# 124 if it killed the process; either way we capture stdout/stderr.
#
# inputdump's "events --watch" requires no further input; it polls
# the ring and prints arrivals.
timeout "${DURATION_S}" "$INPUTDUMP" events --watch --role pointer \
    > "${OUTDIR}/inputdump.txt" 2> "${OUTDIR}/inputdump.stderr" || true

CAPTURE_END_NS=$(date +%s%N 2>/dev/null || date +%s)
report_kv 'capture start (ns)' "$CAPTURE_START_NS"
report_kv 'capture end (ns)'   "$CAPTURE_END_NS"

# ----------------------------------------------------------------------
# Post-capture snapshot
# ----------------------------------------------------------------------

heading "Post-capture snapshot"

post_log_lines=$(wc -l < "$SEMADRAWD_LOG")
post_pump_count=$(grep -c pump_diagnostic "$SEMADRAWD_LOG" || true)
post_state_valid=$(grep -c '"state_valid":true' "$SEMADRAWD_LOG" || true)

report_kv 'post log lines'        "$post_log_lines"
report_kv 'post pump_diagnostic'  "$post_pump_count"
report_kv 'post state_valid:true' "$post_state_valid"

# Slice the semadrawd log to just the lines written during the
# capture window. wc -l on a file that is actively being written
# is approximate, but adequate for this purpose (the supervisor
# log writes monotonically; we just want the new tail).
new_lines=$((post_log_lines - pre_log_lines))
if [ "$new_lines" -gt 0 ]; then
    tail -n "$new_lines" "$SEMADRAWD_LOG" > "${OUTDIR}/semadrawd-window.txt"
else
    : > "${OUTDIR}/semadrawd-window.txt"
fi

# Extract just the pump_diagnostic events from the window.
grep pump_diagnostic "${OUTDIR}/semadrawd-window.txt" \
    > "${OUTDIR}/pump_diagnostic-window.txt" || true

# Counts derived from the window file.
window_pump_count=$(wc -l < "${OUTDIR}/pump_diagnostic-window.txt")
window_state_valid=$(grep -c '"state_valid":true' "${OUTDIR}/pump_diagnostic-window.txt" || true)
window_state_valid_false=$(grep -c '"state_valid":false' "${OUTDIR}/pump_diagnostic-window.txt" || true)

report_kv 'window log lines (new)'      "$new_lines"
report_kv 'window pump_diagnostic'      "$window_pump_count"
report_kv 'window state_valid:true'     "$window_state_valid"
report_kv 'window state_valid:false'    "$window_state_valid_false"

# inputdump motion event count: each event line begins "pointer.motion"
# (per inputdump's events subcommand format).
inputdump_motion=$(grep -c 'pointer\.motion\|POINTER_MOTION' "${OUTDIR}/inputdump.txt" || true)
inputdump_total=$(wc -l < "${OUTDIR}/inputdump.txt")
report_kv 'inputdump total lines'       "$inputdump_total"
report_kv 'inputdump pointer.motion'    "$inputdump_motion"

# ----------------------------------------------------------------------
# Diagnosis
# ----------------------------------------------------------------------

heading "Diagnosis"

# Three-cell truth table determines what we observed.
ring_has_motion="no"
[ "$inputdump_motion" -gt 0 ] && ring_has_motion="yes"

pump_saw_motion="no"
[ "$window_state_valid" -gt 0 ] && pump_saw_motion="yes"

report_kv 'inputfs ring has motion?' "$ring_has_motion"
report_kv 'semadrawd pump saw motion?' "$pump_saw_motion"

printf '\n' | tee -a "${OUTDIR}/REPORT.txt"

if [ "$ring_has_motion" = "yes" ] && [ "$pump_saw_motion" = "yes" ]; then
    report_say "RESULT: AD-36 chain works end-to-end."
    report_say "        Motion reached the inputfs ring; pump consumed it."
    report_say "        Closes AD-36 (and AD-25 contingent on AD-36)."
elif [ "$ring_has_motion" = "yes" ] && [ "$pump_saw_motion" = "no" ]; then
    report_say "RESULT: BUG IN SEMADRAWD HARVEST."
    report_say "        Motion reached the inputfs ring (inputdump saw"
    report_say "        ${inputdump_motion} pointer.motion events), but semadrawd's"
    report_say "        getInputfsEvents harvest did not surface them: the"
    report_say "        pump emitted ${window_pump_count} events with"
    report_say "        state_valid:false on every one."
    report_say ""
    report_say "        Next step: inspect semadrawd's input backend"
    report_say "        (semadraw/src/backend/inputfs_input.zig and"
    report_say "        semadraw/src/backend/drawfs.zig getInputfsEventsImpl)"
    report_say "        for a wiring or filter issue that drops pointer"
    report_say "        events before the harvest at semadrawd.zig:1117."
elif [ "$ring_has_motion" = "no" ] && [ "$pump_saw_motion" = "no" ]; then
    report_say "RESULT: NO MOTION REACHED USERSPACE."
    report_say "        inputdump saw zero pointer.motion events in the"
    report_say "        window; the pump correctly stayed in the no-motion"
    report_say "        branch."
    report_say ""
    report_say "        This could mean:"
    report_say "          (a) the operator did not move the mouse during"
    report_say "              the capture window, or"
    report_say "          (b) the pointing device is not attaching to"
    report_say "              inputfs (check 'sudo inputdump devices' to"
    report_say "              confirm device inventory)."
    report_say ""
    report_say "        If (b), the AD-36 implementation is not the cause"
    report_say "        of state_valid=false; the device path itself is"
    report_say "        broken."
else
    report_say "RESULT: UNEXPECTED -- pump claims motion but ring does not."
    report_say "        ring_has_motion=$ring_has_motion, pump_saw_motion=$pump_saw_motion"
    report_say "        This combination should not happen and warrants a"
    report_say "        closer look at both data sources."
fi

# ----------------------------------------------------------------------
# Output summary
# ----------------------------------------------------------------------

heading "Outputs"

printf 'Report:        %s\n'  "${OUTDIR}/REPORT.txt"          | tee -a "${OUTDIR}/REPORT.txt"
printf 'inputdump:     %s\n'  "${OUTDIR}/inputdump.txt"       | tee -a "${OUTDIR}/REPORT.txt"
printf 'pump events:   %s\n'  "${OUTDIR}/pump_diagnostic-window.txt" | tee -a "${OUTDIR}/REPORT.txt"
printf 'semadrawd log: %s\n'  "${OUTDIR}/semadrawd-window.txt"        | tee -a "${OUTDIR}/REPORT.txt"

printf '\n'
printf 'For an at-a-glance view of pump events:\n'
printf '  awk -F\\\" \\\047/state_valid/{for(i=1;i<=NF;i++)if($i==\"state_valid\")print $(i+2),$(i+6),$(i+10)}\\\047 %s | sort -u\n' "${OUTDIR}/pump_diagnostic-window.txt"
printf '\n'

exit 0
