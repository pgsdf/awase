#!/bin/sh
#
# f5e_state.sh -- F.5.e state publication (ADR 0027). TEST ONLY.
#
#   1  static surfaces written with specified contents
#   2  state/clients track admissions and reaps within 2 s
#   3  events: monotonic seq, kinds, last-event == tail of events
#   4  parity content: denied/election/preempted event details
#   5  atomicity + liveness under churn (no torn reads; publish_seq moves)
#   6  heartbeat while idle (publish_seq advances with no traffic)
#   8  semasound-dump prints surfaces; -f follows an admission live
#   9  fd/RSS stable across churn
#
# Criteria 6 (audio inertness) and 7 (mini-soak) are separate runs; the
# reminder prints at the end. Writes and REMOVES policy files.
# Prereq: broker running (bench_setup.sh). Usage: sudo sh f5e_state.sh

set -u
TONE="./zig-out/bin/semasound-tone"
DUMP="./zig-out/bin/semasound-dump"
BIN="${SEMASOUND_BIN:-./zig-out/bin/semasound}"
LOG="${SEMASOUND_LOG:-/tmp/semasound.log}"   # f5prod.sh overrides for the supervised broker
RUN=/var/run/sema/audio
ETC=/usr/local/etc/semasound
fails=0

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -x "$TONE" ] || { echo "missing $TONE (zig build)" >&2; exit 1; }
[ -x "$DUMP" ] || { echo "missing $DUMP (zig build)" >&2; exit 1; }
pgrep -x semasound >/dev/null || { echo "semasound not running" >&2; exit 1; }
BPID=$(pgrep -x semasound)

if ! grep -qa "publish_seq" "$BIN"; then
	echo "ABORT: $BIN lacks F.5.e publication code. Copy sources, rebuild clean."
	exit 1
fi
bin_age=$(( $(date +%s) - $(stat -f %m "$BIN") ))
broker_up=$(ps -o etimes= -p "$BPID" | tr -d ' ')
if [ "$broker_up" -gt "$bin_age" ]; then
	echo "ABORT: running broker predates the binary. pkill + bench_setup.sh."
	exit 1
fi

mkdir -p "$ETC"
cleanup() { rm -f "$ETC/default.policy" "$ETC/null.policy"; }
trap cleanup EXIT INT TERM
cleanup

settle() { sleep 1.5; }
check() {
	if [ "$3" = "$2" ]; then printf "  %-52s ok (%s)\n" "$1" "$3"
	else printf "  %-52s FAIL (got %s, want %s)\n" "$1" "$3" "$2"; fails=$((fails+1)); fi
}
yes_if() {
	if [ "$2" -eq 0 ]; then printf "  %-52s ok\n" "$1"
	else printf "  %-52s FAIL\n" "$1"; fails=$((fails+1)); fi
}

echo "F.5.e: state publication"

# 1: static surfaces.
[ "$(cat "$RUN/default/identity" 2>/dev/null)" = "semasound default" ]; yes_if "1: identity[default]" $?
[ "$(cat "$RUN/default/backend" 2>/dev/null)" = "audiofs" ]; yes_if "1: backend[default]=audiofs" $?
[ "$(cat "$RUN/default/device" 2>/dev/null)" = "/dev/audiofs0" ]; yes_if "1: device[default]" $?
[ "$(cat "$RUN/null/backend" 2>/dev/null)" = "discard" ]; yes_if "1: backend[null]=discard" $?
grep -q "election=true" "$RUN/default/capabilities" 2>/dev/null; yes_if "1: capabilities[default] election=true" $?
grep -q "election=false" "$RUN/null/capabilities" 2>/dev/null; yes_if "1: capabilities[null] election=false" $?
grep -q "mixing=true" "$RUN/default/capabilities" 2>/dev/null; yes_if "1: capabilities mixing=true" $?

# 2: state/clients track admission and reap within 2 s.
"$TONE" 5 440 130 --label trk1 --class music >/dev/null 2>&1 &
P1=$!
sleep 2.5
grep -q "label=trk1 class=music" "$RUN/default/clients" 2>/dev/null; yes_if "2: clients shows admitted client" $?
grep -q "status=playing" "$RUN/default/state" 2>/dev/null; yes_if "2: state playing during stream" $?
grep -q "clients=1" "$RUN/default/state" 2>/dev/null; yes_if "2: state clients=1" $?
wait "$P1"
settle
sleep 2.5
[ ! -s "$RUN/default/clients" ]; yes_if "2: clients empty after reap" $?
grep -q "clients=0" "$RUN/default/state" 2>/dev/null; yes_if "2: state clients=0 after reap" $?

# 3: events seq monotonic; kinds; last-event == tail.
grep -q "kind=admitted" "$RUN/default/events"; yes_if "3: admitted event present" $?
grep -q "kind=reaped" "$RUN/default/events"; yes_if "3: reaped event present" $?
mono=$(awk -F'seq=| ' '/^seq=/{s=$2; if (s+0 <= last+0) bad=1; last=s} END{print bad+0}' "$RUN/default/events")
check "3: seq strictly monotonic" 0 "$mono"
[ "$(tail -1 "$RUN/default/events")" = "$(cat "$RUN/default/last-event")" ]; yes_if "3: last-event == tail of events" $?

# 4: parity event content. Denied:
printf 'version=1\ndeny_class=blockedc\n' > "$ETC/default.policy"
"$TONE" 1 440 100 --label dlab --class blockedc >/dev/null 2>&1
rm -f "$ETC/default.policy"
sleep 2
grep "kind=denied" "$RUN/default/events" | grep -q "label=dlab class=blockedc"; yes_if "4: denied event carries label+class" $?
# Election:
"$TONE" 1 440 120 >/dev/null 2>&1; settle   # normalize to 48000
"$TONE" 2 440 130 --rate 44100 >/dev/null 2>&1
settle
sleep 2
grep "kind=election" "$RUN/default/events" | grep -q "from=48000 to=44100"; yes_if "4: election event carries transition" $?
# Preemption (group):
printf 'version=1\ngroup=g1\noverride_class=alert\n' > "$ETC/default.policy"
printf 'version=1\ngroup=g1\n' > "$ETC/null.policy"
"$TONE" 6 660 110 --target null >/dev/null 2>&1 &
PN=$!
sleep 1
"$TONE" 1 880 130 --class alert >/dev/null 2>&1
wait "$PN" 2>/dev/null
rm -f "$ETC/default.policy" "$ETC/null.policy"
sleep 2
grep "kind=preempted" "$RUN/null/events" | grep -q "group=g1"; yes_if "4: preempted event on the peer target" $?
settle

# 5: atomicity + liveness under churn.
( i=0; while [ "$i" -lt 12 ]; do "$TONE" 1 440 90 --label churn >/dev/null 2>&1; i=$((i+1)); done ) &
CH=$!
torn=0
j=0
while [ "$j" -lt 50 ]; do
	s=$(cat "$RUN/default/state" 2>/dev/null)
	[ -z "$s" ] && torn=$((torn+1))
	echo "$s" | grep -q "publish_seq=" || torn=$((torn+1))
	cat "$RUN/default/clients" >/dev/null 2>&1
	cat "$RUN/default/events" >/dev/null 2>&1
	sleep 0.2
	j=$((j+1))
done
wait "$CH"
check "5: no torn/empty state reads under churn (50 reads)" 0 "$torn"

# 6 (liveness): publish_seq advances while idle.
settle
s1=$(sed -n 's/^publish_seq=//p' "$RUN/default/state")
sleep 3
s2=$(sed -n 's/^publish_seq=//p' "$RUN/default/state")
[ "$s2" -gt "$s1" ]; yes_if "6: publish_seq advances while idle (heartbeat)" $?

# 8: dump tool.
"$DUMP" > /tmp/f5e_dump.txt 2>&1
grep -q "== target default ==" /tmp/f5e_dump.txt; yes_if "8: dump prints default target" $?
grep -q "== target null ==" /tmp/f5e_dump.txt; yes_if "8: dump prints null target" $?
grep -q "identity: semasound default" /tmp/f5e_dump.txt; yes_if "8: dump prints surface contents" $?
"$DUMP" -f > /tmp/f5e_follow.txt 2>&1 &
DF=$!
sleep 1
"$TONE" 1 440 110 --label followme >/dev/null 2>&1
sleep 3
kill "$DF" 2>/dev/null
grep "kind=admitted" /tmp/f5e_follow.txt | grep -q "label=followme"; yes_if "8: dump -f follows a live admission" $?

# 9: leak across churn.
fd0=$(procstat -f "$BPID" 2>/dev/null | wc -l | tr -d ' ')
rss0=$(ps -o rss= -p "$BPID" | tr -d ' ')
i=0
while [ "$i" -lt 10 ]; do
	"$TONE" 1 440 90 >/dev/null 2>&1
	sleep 1.2
	i=$((i + 1))
done
sleep 2
fd1=$(procstat -f "$BPID" 2>/dev/null | wc -l | tr -d ' ')
rss1=$(ps -o rss= -p "$BPID" | tr -d ' ')
check "9: fd count stable across publication churn" "$fd0" "$fd1"
drss=$((rss1 - rss0))
if [ "$drss" -lt 2048 ] && [ "$drss" -gt -2048 ]; then
	echo "  9: RSS stable (delta ${drss} KiB)                    ok"
else
	echo "  9: RSS delta ${drss} KiB                             FAIL"; fails=$((fails+1))
fi
pgrep -x semasound >/dev/null; yes_if "9: broker alive" $?

echo ""
if [ "$fails" -eq 0 ]; then
	echo "F.5.e: ALL SCRIPTED CASES PASS"
	echo "Criterion 6 (audio inertness): sudo sh f5b_election.sh && sudo sh f5c_targets.sh && sudo sh f5d_policy.sh"
	echo "Criterion 7 (mini-soak under publication): sudo sh f5b_soak.sh 900"
else
	echo "F.5.e: $fails FAILURE(S)"
fi
