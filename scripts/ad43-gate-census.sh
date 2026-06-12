#!/bin/sh
#
# ad43-gate-census.sh -- quantify the compose gate, idle vs motion.
#
# AD-43.3a's code reading established: shouldComposite() is
# now >= next_deadline_ns, and the deadline advances only when a
# composite runs, so it parks in the past at idle and the gate
# degenerates to has_damage alone (immediate wake, paced under
# load). This census puts numbers on it and, as a side effect,
# measures the idle loop rate, which rules AD-32's 67 kHz
# busy-wait in or out on current code.
#
# Usage: sudo sh scripts/ad43-gate-census.sh
# Phase 1: 30 seconds HANDS OFF. Phase 2: 30 seconds of motion.

set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
LOG=/var/log/utf/semadrawd/current
[ -r "$LOG" ] || { echo "$LOG not readable" >&2; exit 1; }

# Rotation-proof capture (2026-06-06 revision): under instrument
# fire-hose rates s6-log rotates current every second or two, so
# line-count windows over the file are meaningless (both all-zero
# census runs were this artifact). Each phase now captures the
# stream itself via tail -F into a temp file and counts that.

capture() {
	_out=$1; _secs=$2
	tail -F -n 0 "$LOG" > "$_out" 2>/dev/null &
	_tp=$!
	sleep "$_secs"
	kill "$_tp" 2>/dev/null
	wait "$_tp" 2>/dev/null
}

census() {
	_label=$1; _file=$2; _secs=$3
	awk -v secs="$_secs" -v label="$_label" '
	{
		if (/"type":"composite_gate_diagnostic"/) {
			gates++
			if (/"has_damage":true/) dmg++
			if (/"should_composite":true/) sched++
			if (/"state_valid":false/) invalid++
		}
		if (/"type":"frame_complete"/) frames++
		if (/"type":"pump_diagnostic"/) pumps++
	}
	END {
		printf "  %s (%ds window, stream-captured)\n", label, secs
		if (gates == 0) printf "    (no gate/pump lines: instrument flags are off; iteration\n     legs unavailable, composite counts remain valid)\n"
		printf "    loop iterations (gate lines)  : %d  (%.1f/s)\n", gates, gates/secs
		printf "    has_damage true               : %d  (%.1f%%)\n", dmg, gates ? 100*dmg/gates : 0
		printf "    should_composite true         : %d  (%.1f%%)\n", sched, gates ? 100*sched/gates : 0
		printf "    composites (frame_complete)   : %d  (%.1f/s)\n", frames, frames/secs
		printf "    pump lines                    : %d\n", pumps
		printf "    state_valid false             : %d\n", invalid
	}' "$_file"
}

T1=$(mktemp) ; T2=$(mktemp)
echo "Phase 1: HANDS OFF for 30 seconds (idle census)."
capture "$T1" 30
echo "Phase 2: MOVE THE MOUSE continuously for 30 seconds."
capture "$T2" 30

echo ""
echo "== AD-43.3a gate census, $(date)"
census "IDLE" "$T1" 30
echo ""
census "MOTION" "$T2" 30
rm -f "$T1" "$T2"
echo ""
echo "Reading guide:"
echo "  Idle iterations near 10/s = poll pacing the loop. Tens of"
echo "  thousands per second = the AD-32 busy-spin, live."
echo "  should_composite near 100 percent at idle = the parked"
echo "  deadline, the documented by-construction behaviour."
echo "  Composites near 0/s idle and bounded under motion = the"
echo "  damage gate doing the arbitration."
