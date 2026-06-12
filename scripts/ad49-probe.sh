#!/bin/sh
#
# ad49-probe.sh v2 -- accept starvation, observed during the act.
#
# v1 established the condition: nc connects (exit 0), the daemon
# survives with the same pid, and NO client_connected event is
# emitted across the ~2 s the connection sits queued. v2 adds the
# two captures that discriminate the remaining fork:
#   - procstat -f maps fd numbers to objects, so the listen fd is
#     KNOWN, not inferred from truss ordering;
#   - a truss spans the nc window, so we see whether poll ever
#     returns ready while the connection is queued, and whether an
#     accept ever follows.
# Verdicts: poll ready without accept is a userspace dispatch bug;
# poll silent throughout with the listener provably in the set is
# kernel-side or a queue-semantics surprise; an accept appearing
# means v1's result does not reproduce and the condition is
# intermittent.
#
# Usage: sudo sh scripts/ad49-probe.sh

set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

SVC=/var/service/utf/semadrawd
LOG=/var/log/utf/semadrawd/current
SOCK=/var/run/semadraw.sock
OUT="/tmp/ad49-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

svstat_line() { s6-svstat "$SVC" 2>/dev/null || echo "svstat failed"; }
pid_of()      { echo "$1" | sed -n 's/.*pid \([0-9]*\).*/\1/p'; }

echo "== AD-49 probe v2, $(date)"
echo "   output dir $OUT"
echo ""

BEFORE=$(svstat_line); PID=$(pid_of "$BEFORE")
[ -n "$PID" ] || { echo "semadrawd not up: $BEFORE" >&2; exit 1; }
CONNS_B=$(grep -c '"type":"client_connected"' "$LOG" 2>/dev/null || echo 0)
echo "== A. before: $BEFORE"
echo "   client_connected events: $CONNS_B"

echo ""
echo "== B. the fd map (definitive, not inferred)"
procstat -f "$PID" > "$OUT/fdmap.txt" 2>&1
awk '$3 ~ /^[0-9]+$/ { printf "   fd %-3s %-4s %s\n", $3, $4, $NF }' "$OUT/fdmap.txt" | head -14
LISTEN_FD=$(awk '$NF == "/var/run/semadraw.sock" && $4 == "s" { print $3; exit }' "$OUT/fdmap.txt")
echo "   unix listen fd per procstat: ${LISTEN_FD:-NOT FOUND (read $OUT/fdmap.txt by hand)}"

echo ""
echo "== C. truss armed across one connect-and-EOF window"
truss -o "$OUT/truss.txt" -p "$PID" &
TRUSS_PID=$!
sleep 0.3
nc -w 2 -U "$SOCK" < /dev/null
NC_RC=$?
sleep 0.5
kill "$TRUSS_PID" 2>/dev/null
wait "$TRUSS_PID" 2>/dev/null
echo "   nc exit code: $NC_RC"

sleep 1
AFTER=$(svstat_line); PID_A=$(pid_of "$AFTER")
CONNS_A=$(grep -c '"type":"client_connected"' "$LOG" 2>/dev/null || echo 0)
echo "   after:  $AFTER"
echo "   client_connected events: $CONNS_A (delta $((CONNS_A - CONNS_B)))"

echo ""
echo "== D. what the daemon did during the window"
TOTAL_POLLS=$(grep -c "^poll" "$OUT/truss.txt" 2>/dev/null || echo 0)
READY_POLLS=$(grep "^poll" "$OUT/truss.txt" | grep -vc "= 0 (0x0)" || true)
ACCEPTS=$(grep -cE "^accept" "$OUT/truss.txt" 2>/dev/null || echo 0)
echo "   polls: $TOTAL_POLLS total, $READY_POLLS returned ready, $ACCEPTS accept calls"
if [ "$READY_POLLS" -gt 0 ]; then
	echo "   first ready poll and what followed:"
	grep -n "^poll" "$OUT/truss.txt" | grep -v "= 0 (0x0)" | head -1 | cut -d: -f1 | {
		read ln
		sed -n "${ln},$((ln + 8))p" "$OUT/truss.txt" | sed 's/^/     /'
	}
fi

echo ""
echo "== Verdict"
if [ "$PID" != "${PID_A}" ]; then
	echo "   DAEMON DIED across the probe (pid $PID -> ${PID_A:-down})."
elif [ "$ACCEPTS" -gt 0 ]; then
	echo "   HEALTHY: the daemon accepted the probe ($ACCEPTS accept call(s) in"
	echo "   the trace) and survived. NOTE: structured client_connected events"
	echo "   carry handshake data and fire only after a HELLO, which nc never"
	echo "   sends; their delta is NOT an accept signal (the v1 verdict made"
	echo "   that mistake and reported false starvation)."
elif [ "$READY_POLLS" -gt 0 ]; then
	echo "   DISPATCH BUG: poll reported readiness $READY_POLLS time(s), the loop"
	echo "   never called accept. The fault is in the revents dispatch in"
	echo "   semadrawd.zig; the listen fd is ${LISTEN_FD:-unknown}."
elif [ -n "${LISTEN_FD}" ]; then
	echo "   POLL SILENT: the listener (fd ${LISTEN_FD}) never reported ready"
	echo "   while a connection sat queued. Check whether fd ${LISTEN_FD}"
	echo "   appears in the polled set in truss.txt at all."
else
	echo "   INCONCLUSIVE: read $OUT/truss.txt and $OUT/fdmap.txt by hand."
fi
echo ""
echo "   Note the screen state with the paste."
echo "   Evidence in $OUT  (tar -cf results.tar -C $OUT .)"
