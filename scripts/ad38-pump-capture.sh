#!/bin/sh
#
# ad38-pump-capture.sh -- the two-phase pump_diagnostic capture.
# REWRITTEN 2026-06-07 after the first version's two failures:
#   - capture used tail -F redirected to a file, whose block
#     buffering discarded unflushed lines on kill; capture now
#     extracts events by their own ts_wall_ns within recorded
#     phase bounds, from current and the newest archives, immune
#     to buffering and to mid-phase rotation;
#   - the script assumed the slot it was arming held the process
#     it meant to instrument (AD-50's lesson); it now gates on
#     slot state and slot process identity before arming.
#
# Phase 1 (idle, hands off): pump_diagnostic continues at loop
# cadence with pos_changed:false throughout. Phase 2 (steady
# motion at the physical machine): pos_changed at approximately
# the motion-event rate (~130 Hz Round 2 reference) against the
# stale-view era's 1 in 9,998, ps_x/ps_y tracking real coords.
#
# Restarts semadrawd twice (arm, disarm): the login session
# collapses. Run from ssh; relog after.
#
# Usage: sudo sh scripts/ad38-pump-capture.sh

set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

RUN=/var/service/utf/semadrawd/run
LOGDIR=/var/log/utf/semadrawd
SVC=/var/service/utf/semadrawd
OUT="/tmp/ad38-$(date +%Y%m%d-%H%M%S)"
MARK="export UTF_PUMP_INSTRUMENT=1 # ad38-capture"
IDLE_S=20
MOTION_S=20
mkdir -p "$OUT"

cleanup() {
	if grep -qF "$MARK" "$RUN" 2>/dev/null; then
		grep -vF "$MARK" "$RUN" > "$RUN.new" && mv "$RUN.new" "$RUN" && chmod 755 "$RUN"
		s6-svc -r "$SVC"
		echo "   (instrument flag removed, daemon restarted)"
	fi
}
trap cleanup EXIT INT TERM

slot_child() {
	sup=$(pgrep -fx "s6-supervise semadrawd" | head -1)
	[ -n "$sup" ] && pgrep -P "$sup" -l | awk '{print $2}' | head -1
}

# Extract pump_diagnostic events with a <= ts_wall_ns <= b from
# current plus the two newest archives, into $3.
extract() {
	files="$LOGDIR/current $(ls -t "$LOGDIR"/@*.s 2>/dev/null | head -2)"
	awk -v a="$1" -v b="$2" '
		/"type":"pump_diagnostic"/ {
			if (match($0, /"ts_wall_ns":[0-9]+/)) {
				ts = substr($0, RSTART + 13, RLENGTH - 13) + 0
				if (ts >= a && ts <= b) print
			}
		}' $files > "$3" 2>/dev/null || true
}

echo "== AD-38 pump capture (ts-bounded), $(date)"
echo "   output dir $OUT"
echo ""

echo "== Gate: slot state and identity (AD-50's lesson)"
STAT=$(s6-svstat "$SVC")
echo "   $STAT"
case "$STAT" in up*) : ;; *) echo "   GATE FAILED: slot not up; recover before benching"; exit 1;; esac
CHILD=$(slot_child || true)
echo "   slot runs: ${CHILD:-nothing}"
[ "$CHILD" = "semadrawd" ] || { echo "   GATE FAILED: slot does not run semadrawd"; exit 1; }

echo ""
grep -qF "$MARK" "$RUN" && { echo "flag already present; aborting"; exit 1; }
awk -v m="$MARK" '/^exec \/usr\/local\/bin\/semadrawd/ { print m } { print }' "$RUN" > "$RUN.new"
grep -qF "$MARK" "$RUN.new" || { echo "failed to arm run script"; rm -f "$RUN.new"; exit 1; }
mv "$RUN.new" "$RUN" && chmod 755 "$RUN"
s6-svc -r "$SVC"
sleep 5
CHILD=$(slot_child || true)
[ "$CHILD" = "semadrawd" ] || { echo "post-arm identity check failed (${CHILD:-nothing}); aborting"; exit 1; }
echo "== armed and restarted, identity verified"

echo ""
echo "== Phase 1: IDLE. Hands off everything for ${IDLE_S}s."
T0="$(date +%s)000000000"
sleep "$IDLE_S"
T1="$(date +%s)999999999"
extract "$T0" "$T1" "$OUT/idle.pump"
I_ALL=$(wc -l < "$OUT/idle.pump" | tr -d ' ')
I_CHG=$(grep -c '"pos_changed":true' "$OUT/idle.pump" 2>/dev/null); I_CHG=${I_CHG:-0}
I_RATE=$((I_ALL / IDLE_S))
echo "   ${I_ALL} emissions in ${IDLE_S}s (~${I_RATE}/s), pos_changed:true count ${I_CHG}"

echo ""
echo "== Phase 2: MOTION. Move the cursor steadily in circles for ${MOTION_S}s, starting NOW."
T0="$(date +%s)000000000"
sleep "$MOTION_S"
T1="$(date +%s)999999999"
extract "$T0" "$T1" "$OUT/motion.pump"
M_ALL=$(wc -l < "$OUT/motion.pump" | tr -d ' ')
M_CHG=$(grep -c '"pos_changed":true' "$OUT/motion.pump" 2>/dev/null); M_CHG=${M_CHG:-0}
M_RATE=$((M_CHG / MOTION_S))
XMIN=$(sed -n 's/.*"ps_x":\(-\{0,1\}[0-9]*\).*/\1/p' "$OUT/motion.pump" | sort -n | head -1)
XMAX=$(sed -n 's/.*"ps_x":\(-\{0,1\}[0-9]*\).*/\1/p' "$OUT/motion.pump" | sort -n | tail -1)
echo "   ${M_ALL} emissions, ${M_CHG} pos_changed:true (~${M_RATE}/s)"
echo "   ps_x range [${XMIN:-?}, ${XMAX:-?}]"

echo ""
echo "== Verdicts"
FAILS=0
if [ "$I_ALL" -gt 0 ] && [ "$I_CHG" -eq 0 ]; then
	echo "   PASS idle: heartbeat present (~${I_RATE}/s), pos_changed false throughout"
else
	echo "   FAIL idle: emissions ${I_ALL}, pos_changed:true ${I_CHG} (expected >0 and 0)"
	FAILS=$((FAILS + 1))
fi
if [ "$M_RATE" -ge 50 ]; then
	echo "   PASS motion: pos_changed at ~${M_RATE}/s, the observation gap is bridged"
elif [ "$M_RATE" -ge 5 ]; then
	echo "   MARGINAL motion: ~${M_RATE}/s, above the stale-view era but well under"
	echo "   the ~130/s reference; paste before closing"
	FAILS=$((FAILS + 1))
else
	echo "   FAIL motion: ~${M_RATE}/s; the gap is NOT bridged; back to the AD-25 class"
	FAILS=$((FAILS + 1))
fi
echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "== BOTH PHASES PASS: AD-36's path functions, AD-38's evidence in hand."
else
	echo "== ${FAILS} verdict(s) not green; paste and tar."
fi
echo "   Evidence in $OUT  (tar -cf ad38-results.tar -C $OUT .)"
