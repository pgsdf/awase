#!/bin/sh
#
# f5f_super.sh -- F.5.f supervision (ADR 0028). TEST ONLY.
#
# Runs a TRANSIENT s6-svscan over /tmp/f5f-scan with a test service
# directory whose run script execs the LOCAL bench binary and appends the
# broker's output to /tmp/semasound.log (so the existing suites' log greps
# keep working; the canonical in-tree service uses s6-log, exercised by the
# documented enablement instead). System scan dirs are untouched.
#
#   1  service up under supervision; client plays; heartbeat advancing
#   2  cold start: run script loads audiofs
#   3  s6-svc -d stops <2 s with an active client; -u restores
#   4  SIGTERM: clean prompt exit, socket unlinked, supervise restarts
#   5  kill -9: restart after finish delay; new client served; seq restarted
#   6  death observability while down: stale publish_ts readable; dump works
#   8  10 down/up + 10 kill cycles: no litter, working broker
#
# Criterion 7 (suites against the supervised broker) and 9 (doc transcript)
# print as follow-ups. Usage: sudo sh f5f_super.sh
# NOTE: stops any bench broker; rerun bench_setup.sh afterward for bench work.

set -u
TONE="./zig-out/bin/semasound-tone"
BIN="$(pwd)/zig-out/bin/semasound"
DUMP="./zig-out/bin/semasound-dump"
LOG=/tmp/semasound.log
SOCK=/var/run/sema/audio.sock
RUN=/var/run/sema/audio
SCAN=/tmp/f5f-scan
SVC="$SCAN/semasound"
fails=0

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
for b in s6-svscan s6-svc s6-svstat; do
	command -v "$b" >/dev/null 2>&1 || { echo "ABORT: $b not found (pkg install s6)"; exit 1; }
done
[ -x "$BIN" ] || { echo "missing $BIN (zig build)" >&2; exit 1; }
grep -qa "signal received, shutting down" "$BIN" || {
	echo "ABORT: $BIN lacks F.5.f signal handling. Copy sources, rebuild clean."
	exit 1
}

cleanup() {
	s6-svc -dx "$SVC" 2>/dev/null
	sleep 0.5
	[ -n "${SVPID:-}" ] && kill "$SVPID" 2>/dev/null
	pkill -x semasound 2>/dev/null
	rm -rf "$SCAN"
}
trap cleanup EXIT INT TERM

check() {
	if [ "$3" = "$2" ]; then printf "  %-52s ok (%s)\n" "$1" "$3"
	else printf "  %-52s FAIL (got %s, want %s)\n" "$1" "$3" "$2"; fails=$((fails+1)); fi
}
yes_if() {
	if [ "$2" -eq 0 ]; then printf "  %-52s ok\n" "$1"
	else printf "  %-52s FAIL\n" "$1"; fails=$((fails+1)); fi
}
broker_pid() { pgrep -x semasound | head -1; }
wait_up() { # wait for a broker pid different from $1, up to ~10 s
	k=0
	while [ "$k" -lt 50 ]; do
		np=$(broker_pid)
		[ -n "$np" ] && [ "$np" != "${1:-}" ] && { echo "$np"; return 0; }
		sleep 0.2; k=$((k+1))
	done
	echo ""; return 1
}

echo "F.5.f: supervision (transient s6-svscan over $SCAN)"

# Setup: stop any bench broker; build the test service dir.
pkill -x semasound 2>/dev/null; sleep 1; rm -f "$SOCK"; : > "$LOG"
rm -rf "$SCAN"; mkdir -p "$SVC"
# The test run script loads the IN-TREE module (the bench's truth, same as
# bench_setup.sh), not an installed copy; canonical run uses the installed
# module per SUPERVISION.md.
KO="$(cd .. && pwd)/audiofs/sys/modules/audiofs/audiofs.ko"
[ -f "$KO" ] || { echo "ABORT: $KO missing (bench_setup.sh builds it)"; exit 1; }
cat > "$SVC/run" << EOF
#!/bin/sh
kldstat -q -n audiofs || kldload "$KO"
install -d -m 0755 /var/run/sema /var/run/sema/audio
exec "$BIN" >> "$LOG" 2>&1
EOF
cat > "$SVC/finish" << 'EOF'
#!/bin/sh
sleep 2
EOF
chmod +x "$SVC/run" "$SVC/finish"

# 2 first (cold): unload audiofs before the very first start.
kldunload audiofs 2>/dev/null
s6-svscan "$SCAN" >/dev/null 2>&1 &
SVPID=$!
P0=$(wait_up "")
[ -n "$P0" ]; yes_if "2: cold start: run script loaded audiofs, broker up" $?
[ -c /dev/audiofs0 ]; yes_if "2: device node present (module loaded)" $?
sleep 1

# 1: supervised up; status; client; heartbeat; log captured.
s6-svstat "$SVC" | grep -q "^up"; yes_if "1: s6-svstat reports up" $?
"$TONE" 1 440 120 >/dev/null 2>&1; yes_if "1: client plays under supervision" $?
sleep 2.5
h1=$(sed -n 's/^publish_seq=//p' "$RUN/default/state"); sleep 2
h2=$(sed -n 's/^publish_seq=//p' "$RUN/default/state")
[ "${h2:-0}" -gt "${h1:-0}" ]; yes_if "1: heartbeat advancing" $?
grep -q "output open" "$LOG"; yes_if "1: broker log captured" $?

# 3: prompt stop with an active client.
"$TONE" 6 440 120 >/dev/null 2>&1 &
PC=$!
sleep 1
t0=$(date +%s)
s6-svc -d "$SVC"
k=0; while pgrep -x semasound >/dev/null && [ "$k" -lt 20 ]; do sleep 0.1; k=$((k+1)); done
t1=$(date +%s)
! pgrep -x semasound >/dev/null; yes_if "3: broker stopped on s6-svc -d" $?
[ $((t1 - t0)) -le 2 ]; yes_if "3: stop took <=2 s with active client" $?
wait "$PC" 2>/dev/null
s6-svstat "$SVC" | grep -q "^down"; yes_if "3: s6-svstat reports down" $?
s6-svc -u "$SVC"
P1=$(wait_up "")
[ -n "$P1" ]; yes_if "3: s6-svc -u restores service" $?
sleep 1

# 4: SIGTERM direct: prompt exit, socket unlinked, supervise restarts.
"$TONE" 6 440 120 >/dev/null 2>&1 &
PC=$!
sleep 1
kill -TERM "$P1"
k=0; while kill -0 "$P1" 2>/dev/null && [ "$k" -lt 20 ]; do sleep 0.1; k=$((k+1)); done
! kill -0 "$P1" 2>/dev/null; yes_if "4: SIGTERM exited broker <=2 s" $?
[ ! -e "$SOCK" ]; yes_if "4: socket unlinked by handler" $?
grep -q "signal received, shutting down" "$LOG"; yes_if "4: shutdown notice logged" $?
wait "$PC" 2>/dev/null
P2=$(wait_up "$P1")
[ -n "$P2" ]; yes_if "4: s6-supervise restarted after finish delay" $?
sleep 1

# 5: kill -9: restart, new client served, publish_seq restarted.
# Let the running broker accumulate publish cycles first so the
# runtime-instance comparison has room (pre >> post-restart values).
sleep 8
pre=$(sed -n 's/^publish_seq=//p' "$RUN/default/state")
kill -9 "$P2"
P3=$(wait_up "$P2")
[ -n "$P3" ]; yes_if "5: restarted after kill -9" $?
sleep 1
"$TONE" 1 440 120 >/dev/null 2>&1; yes_if "5: new client served post-crash" $?
sleep 2.5
post=$(sed -n 's/^publish_seq=//p' "$RUN/default/state")
[ "${post:-999999}" -lt "${pre:-0}" ]; yes_if "5: publish_seq restarted (runtime-instance)" $?

# 6: death observability while down.
s6-svc -d "$SVC"
sleep 1
ts1=$(sed -n 's/^publish_ts=//p' "$RUN/default/state"); sleep 2
ts2=$(sed -n 's/^publish_ts=//p' "$RUN/default/state")
[ -n "$ts1" ] && [ "$ts1" = "$ts2" ]; yes_if "6: state readable, publish_ts stale while down" $?
"$DUMP" 2>&1 | grep -q "== target default =="; yes_if "6: dump works on a dead broker" $?
s6-svc -u "$SVC"
P4=$(wait_up "")
sleep 1

# 8: cycles, then litter and function check.
i=0
while [ "$i" -lt 10 ]; do
	s6-svc -d "$SVC"; sleep 0.5
	s6-svc -u "$SVC"
	P4=$(wait_up "")
	i=$((i + 1))
done
i=0
while [ "$i" -lt 10 ]; do
	kill -9 "$(broker_pid)" 2>/dev/null
	P4=$(wait_up "$P4")
	i=$((i + 1))
done
[ -n "$P4" ]; yes_if "8: broker alive after 10 down/up + 10 kill cycles" $?
nsock=$(find /var/run/sema -name "*.sock" | wc -l | tr -d ' ')
check "8: exactly one socket (no litter)" 1 "$nsock"
sleep 1
"$TONE" 1 440 120 >/dev/null 2>&1; yes_if "8: broker functional after the storm" $?
fdn=$(procstat -f "$(broker_pid)" 2>/dev/null | wc -l | tr -d ' ')
echo "  8: final broker fd count: $fdn (nominal ~11)"

echo ""
if [ "$fails" -eq 0 ]; then
	# Leave the supervised broker RUNNING for criterion 7: disarm the trap.
	trap - EXIT INT TERM
	echo "F.5.f: ALL SCRIPTED CASES PASS"
	echo "Criterion 7: the s6-supervised broker is left running; now run:"
	echo "  sudo sh f5b_election.sh && sudo sh f5c_targets.sh && sudo sh f5d_policy.sh && sudo sh f5e_state.sh"
	echo "Criterion 9: perform docs/SUPERVISION.md on the canonical paths and"
	echo "compare the transcript (pkg s6, svscan enablement, /var/service install)."
	echo "Teardown when done (then bench_setup.sh for normal bench work):"
	echo "  sudo s6-svc -dx $SVC; sudo kill $SVPID; sudo rm -rf $SCAN"
else
	echo "F.5.f: $fails FAILURE(S)"
fi
