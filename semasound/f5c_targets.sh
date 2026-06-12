#!/bin/sh
#
# f5c_targets.sh -- F.5.c criteria: targets and routing (ADR 0025). TEST ONLY.
#
#   1  topology logged at startup (default -> device, null -> discard)
#   2  routing: named and unnamed clients play on default; F.5.b election
#      spot-check unchanged (lone 44.1k opener elects natively)
#   3  null routing: paced (a 3s client takes ~3s), accepted on null, silent
#   4  unknown target rejected, broker survives
#   5  v1 hello rejected
#   6  concurrent default+null: independent domains (ear: only default tone)
#   7  stall isolation: gapping null client never perturbs default audio
#   8  election isolation invariant: a persistent null client across default
#      session boundaries neither triggers nor suppresses SET_FORMATs
#   9  fd/RSS stable across mixed-target cycles
#
# Criterion 8 strong form: run f5b_election.sh with a long null client in the
# background; it must pass unchanged.
#
# Prereq: broker running (bench_setup.sh). Usage: sudo sh f5c_targets.sh

set -u
TONE="./zig-out/bin/semasound-tone"
BIN="${SEMASOUND_BIN:-./zig-out/bin/semasound}"
LOG="${SEMASOUND_LOG:-/tmp/semasound.log}"   # f5prod.sh overrides for the supervised broker
fails=0

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -x "$TONE" ] || { echo "missing $TONE (zig build)" >&2; exit 1; }
pgrep -x semasound >/dev/null || { echo "semasound not running (bench_setup.sh first)" >&2; exit 1; }
BPID=$(pgrep -x semasound)

# Preflight (stale-binary discipline, carried from f5b_election.sh).
if ! grep -qa "paced discard sink" "$BIN"; then
	echo "ABORT: $BIN lacks F.5.c target code. Copy sources, rm -rf .zig-cache, rebuild."
	exit 1
fi
bin_age=$(( $(date +%s) - $(stat -f %m "$BIN") ))
broker_up=$(ps -o etimes= -p "$BPID" | tr -d ' ')
if [ "$broker_up" -gt "$bin_age" ]; then
	echo "ABORT: running broker (up ${broker_up}s) predates the binary (built ${bin_age}s ago)."
	echo "       sudo pkill -x semasound && sudo sh bench_setup.sh"
	exit 1
fi
if ! grep -q "target null -> paced discard sink" "$LOG"; then
	echo "ABORT: no F.5.c topology line in $LOG; restart via bench_setup.sh."
	exit 1
fi

settle() { sleep 1.5; }
mark() { wc -l < "$LOG"; }
setfmt_since() { tail -n +"$(($1 + 1))" "$LOG" | grep -c "election: SET_FORMAT"; }
check() {
	if [ "$3" = "$2" ]; then printf "  %-50s ok (%s)\n" "$1" "$3"
	else printf "  %-50s FAIL (got %s, want %s)\n" "$1" "$3" "$2"; fails=$((fails+1)); fi
}
yes_if() { # name cond
	if [ "$2" -eq 0 ]; then printf "  %-50s ok\n" "$1"
	else printf "  %-50s FAIL\n" "$1"; fails=$((fails+1)); fi
}

echo "F.5.c: targets and routing"

# 1: topology logged.
grep -q "target default -> /dev/audiofs0" "$LOG"; yes_if "1: topology logged (default -> device)" $?
grep -q "target null -> paced discard sink" "$LOG"; yes_if "1: topology logged (null -> discard)" $?

# Normalize default's rest rate.
"$TONE" 1 440 120 >/dev/null 2>&1
settle

# 2: routing to default, named and unnamed; election spot-check.
m=$(mark)
"$TONE" 2 440 150 --target default >/dev/null 2>&1; r1=$?
settle
"$TONE" 3 440 150 --rate 44100 >/dev/null 2>&1; r2=$?
settle
yes_if "2: named --target default plays (exit 0)" "$r1"
yes_if "2: unnamed client plays (exit 0)" "$r2"
check "2: lone 44.1k opener still elects (1 SET_FORMAT)" 1 "$(setfmt_since "$m")"
if tail -n +"$((m + 1))" "$LOG" | grep "accepted" | grep "rate=44100" | grep -q "on default.*hw=44100.*passthrough"; then
	echo "  2: F.5.b passthrough on default unchanged          ok"
else
	echo "  2: F.5.b passthrough on default unchanged          FAIL"; fails=$((fails+1))
fi

# 3: null routing is paced and accepted on null.
m=$(mark)
t0=$(date +%s)
"$TONE" 3 660 150 --target null >/dev/null 2>&1; r=$?
t1=$(date +%s)
settle
yes_if "3: --target null streams to completion (exit 0)" "$r"
el=$((t1 - t0))
if [ "$el" -ge 2 ]; then
	echo "  3: null is PACED (3s client took ${el}s)            ok"
else
	echo "  3: null NOT paced (3s client took ${el}s)           FAIL"; fails=$((fails+1))
fi
if tail -n +"$((m + 1))" "$LOG" | grep "accepted" | grep -q "on null"; then
	echo "  3: accepted on target null                          ok"
else
	echo "  3: accepted on target null                          FAIL"; fails=$((fails+1))
fi
check "3: null client caused no SET_FORMAT" 0 "$(setfmt_since "$m")"

# 4: unknown target rejected.
"$TONE" 1 440 150 --target hdmi >/dev/null 2>&1
rc=$?
check "4: unknown target rejected (exit 2)" 2 "$rc"

# 5: v1 hello rejected.
"$TONE" 1 440 150 --version 1 >/dev/null 2>&1
rc=$?
check "5: v1 hello rejected (exit 2)" 2 "$rc"

# 6: concurrent default + null, independent domains. EAR: only 440 audible.
m=$(mark)
"$TONE" 5 440 150 >/dev/null 2>&1 &
P1=$!
"$TONE" 5 660 150 --target null >/dev/null 2>&1 &
P2=$!
wait "$P1"; wait "$P2"
settle
if tail -n +"$((m + 1))" "$LOG" | grep -q "playing\[default\], 1 client"; then
	echo "  6: default domain mixed 1 client                    ok"
else
	echo "  6: default domain mixed 1 client                    FAIL"; fails=$((fails+1))
fi
if tail -n +"$((m + 1))" "$LOG" | grep -q "playing\[null\], 1 client"; then
	echo "  6: null domain drained 1 client                     ok"
else
	echo "  6: null domain drained 1 client                     FAIL"; fails=$((fails+1))
fi
echo "  6: EAR CHECK: only the 440 Hz tone should have been audible"

# 7: stall isolation across targets: gapping null client + default tone.
"$TONE" 6 440 150 >/dev/null 2>&1 &
P1=$!
"$TONE" 6 660 150 --target null --gap 800 >/dev/null 2>&1 &
P2=$!
wait "$P1"; wait "$P2"
settle
pgrep -x semasound >/dev/null; yes_if "7: broker alive after cross-target stall" $?
echo "  7: EAR CHECK: 440 Hz must have been continuous and clean"

# 8: election isolation invariant: persistent null client across default
# session boundaries; SET_FORMAT counts must match the no-null baseline.
"$TONE" 14 660 120 --target null >/dev/null 2>&1 &
PNULL=$!
sleep 1
m=$(mark)
"$TONE" 2 440 150 --rate 44100 >/dev/null 2>&1   # 0->1 on default: elect 44100
settle
"$TONE" 2 440 150 >/dev/null 2>&1                 # 0->1 on default: elect 48000
settle
check "8: two default sessions under null = 2 SET_FORMATs" 2 "$(setfmt_since "$m")"
kill -0 "$PNULL" 2>/dev/null; yes_if "8: null client persisted across both boundaries" $?
wait "$PNULL" 2>/dev/null
settle

# 9: leak across mixed-target cycles.
fd0=$(procstat -f "$BPID" 2>/dev/null | wc -l | tr -d ' ')
rss0=$(ps -o rss= -p "$BPID" | tr -d ' ')
i=0
while [ "$i" -lt 8 ]; do
	"$TONE" 1 440 120 --rate 44100 >/dev/null 2>&1
	sleep 1.2
	"$TONE" 1 660 120 --target null >/dev/null 2>&1
	sleep 1.2
	i=$((i + 1))
done
sleep 2
fd1=$(procstat -f "$BPID" 2>/dev/null | wc -l | tr -d ' ')
rss1=$(ps -o rss= -p "$BPID" | tr -d ' ')
check "9: fd count stable across mixed cycles" "$fd0" "$fd1"
drss=$((rss1 - rss0))
if [ "$drss" -lt 2048 ] && [ "$drss" -gt -2048 ]; then
	echo "  9: RSS stable (delta ${drss} KiB)                   ok"
else
	echo "  9: RSS delta ${drss} KiB                            FAIL"; fails=$((fails+1))
fi
pgrep -x semasound >/dev/null; yes_if "9: broker alive" $?

echo ""
if [ "$fails" -eq 0 ]; then
	echo "F.5.c: ALL SCRIPTED CASES PASS (plus the two EAR CHECKs above)"
	echo "Strong criterion 8: run 'sudo sh f5b_election.sh' with a background"
	echo "null client:  ./zig-out/bin/semasound-tone 120 660 120 --target null &"
else
	echo "F.5.c: $fails FAILURE(S)"
fi
