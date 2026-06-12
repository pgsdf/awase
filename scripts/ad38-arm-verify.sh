#!/bin/sh
#
# ad38-arm-verify.sh -- verify every link of the instrumentation
# arming chain, one verdict per link.
#
# Background: the AD-38 capture produced zero pump_diagnostic
# events. The binary contains the emitter (strings confirms), the
# source chain reads correct end to end, and a manual probe found
# the env var absent from the daemon's environment after an armed
# restart. This script repeats the experiment with every previously
# unverified assumption made explicit: the arm is verified in the
# file, the restart is verified by pid change, the environment is
# verified by procstat, and the emission is verified by event-count
# delta. The disarm runs on every exit path.
#
# Usage: sudo sh scripts/ad38-arm-verify.sh

set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

RUN=/var/service/utf/semadrawd/run
LOG=/var/log/utf/semadrawd/current
SVC=/var/service/utf/semadrawd
MARK="export UTF_PUMP_INSTRUMENT=1 # ad38-armverify"
WINDOW_S=10

cleanup() {
	if grep -qF "$MARK" "$RUN" 2>/dev/null; then
		grep -vF "$MARK" "$RUN" > "$RUN.new" && mv "$RUN.new" "$RUN" && chmod 755 "$RUN"
		s6-svc -r "$SVC"
		echo "   (disarmed, daemon restarted)"
	fi
}
trap cleanup EXIT INT TERM

echo "== AD-38 arming-chain verification, $(date)"
echo ""

echo "== Link 0: starting state"
LEFTOVER=$(grep -c "ad38" "$RUN" 2>/dev/null); LEFTOVER=${LEFTOVER:-0}
echo "   leftover ad38 lines in run: ${LEFTOVER} (comment at line 69 region counts; export lines should be 0)"
grep -n "ad38\|UTF_PUMP" "$RUN" | sed 's/^/     /'
s6-svstat "$SVC" | sed 's/^/   /'

echo ""
echo "== Link 1: arm, verified in the file"
grep -qF "$MARK" "$RUN" && { echo "   marker already present; aborting"; exit 1; }
awk -v m="$MARK" '/^exec \/usr\/local\/bin\/semadrawd/ { print m } { print }' "$RUN" > "$RUN.new"
if grep -qF "$MARK" "$RUN.new"; then
	mv "$RUN.new" "$RUN" && chmod 755 "$RUN"
	echo "   armed at line $(grep -nF "$MARK" "$RUN" | cut -d: -f1)"
else
	rm -f "$RUN.new"
	echo "   FAIL: awk insert did not land (exec line shape changed?); aborting"
	exit 1
fi

echo ""
echo "== Link 2: restart, verified by pid"
OLDPID=$(pgrep -x semadrawd || echo none)
s6-svc -r "$SVC"
sleep 6
NEWPID=$(pgrep -x semadrawd || echo none)
echo "   pid ${OLDPID} -> ${NEWPID}"
if [ "$OLDPID" = "$NEWPID" ]; then
	echo "   FAIL: RESTART REGRESSION. semadrawd did not die on s6-svc -r."
	echo "   Every zero today inherits from this. Investigate the daemon's"
	echo "   TERM handling and the supervisor's signal delivery; truss of"
	echo "   the live daemon during another s6-svc -r names which."
	exit 1
fi

echo ""
echo "== Link 3: environment, verified by procstat"
ENVHIT=$(procstat -e "$NEWPID" 2>/dev/null | grep -o "UTF_PUMP_INSTRUMENT=[^ ]*" || true)
if [ -n "$ENVHIT" ]; then
	echo "   PASS: ${ENVHIT} present in pid ${NEWPID}"
else
	echo "   FAIL: env var ABSENT from the fresh process despite the armed"
	echo "   file. The supervisor spawned from something other than the"
	echo "   file edited, or scrubbed the environment. Capture for analysis:"
	procstat -e "$NEWPID" 2>/dev/null | head -3 | sed 's/^/     /'
	ls -li "$RUN" | sed 's/^/     /'
	exit 1
fi

echo ""
echo "== Link 4: emission, verified by count delta over ${WINDOW_S}s"
C0=$(grep -c '"type":"pump_diagnostic"' "$LOG" 2>/dev/null); C0=${C0:-0}
sleep "$WINDOW_S"
C1=$(grep -c '"type":"pump_diagnostic"' "$LOG" 2>/dev/null); C1=${C1:-0}
DELTA=$((C1 - C0))
echo "   ${C0} -> ${C1} (+${DELTA}) in ${WINDOW_S}s"
if [ "$DELTA" -gt 0 ]; then
	echo "   PASS: the daemon emits. Earlier zeros were settle-time or"
	echo "   capture artifacts; rerun scripts/ad38-pump-capture.sh for the"
	echo "   two-phase closure evidence."
else
	echo "   FAIL: gate armed, env present, pump running, emitter in the"
	echo "   binary, yet silent. The suspect is the emit path's silent"
	echo "   failure modes (the catch-return swallows in emitWithSamples)."
fi
