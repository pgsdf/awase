#!/bin/sh
#
# f5d_policy.sh -- F.5.d policy (ADR 0026). TEST ONLY.
#
#   1  surfaces written; absent policy = valid, default allow
#   2  live reload: a deny added to the file denies the NEXT connection
#   3  precedence: deny_label > deny_class > allow_class > default
#   4  validation parity: exact diagnostics; malformed policy never fatal
#   5  ducking: override-class client ducks music, restores on exit (EAR)
#   6  unity spot-check: lone 44.1k passthrough unchanged, no override
#   7  group exclusivity + protocol-visible preemption (exit 3)
#   8  inertness: with no policy files, f5b/f5c suites pass unchanged (run
#      them after this script; reminder printed)
#   9  no leak across policy cycles
#
# Writes and REMOVES /usr/local/etc/semasound/{default,null}.policy.
# Prereq: broker running (bench_setup.sh). Usage: sudo sh f5d_policy.sh

set -u
TONE="./zig-out/bin/semasound-tone"
BIN="${SEMASOUND_BIN:-./zig-out/bin/semasound}"
LOG="${SEMASOUND_LOG:-/tmp/semasound.log}"   # f5prod.sh overrides for the supervised broker
ETC=/usr/local/etc/semasound
RUN=/var/run/sema/audio
fails=0

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -x "$TONE" ] || { echo "missing $TONE (zig build)" >&2; exit 1; }
pgrep -x semasound >/dev/null || { echo "semasound not running (bench_setup.sh first)" >&2; exit 1; }
BPID=$(pgrep -x semasound)

# Preflight (stale-binary discipline).
if ! grep -qa "denied by policy" "$BIN"; then
	echo "ABORT: $BIN lacks F.5.d policy code. Copy sources, rm -rf .zig-cache, rebuild."
	exit 1
fi
bin_age=$(( $(date +%s) - $(stat -f %m "$BIN") ))
broker_up=$(ps -o etimes= -p "$BPID" | tr -d ' ')
if [ "$broker_up" -gt "$bin_age" ]; then
	echo "ABORT: running broker predates the binary. pkill + bench_setup.sh."
	exit 1
fi
if ! grep -q "policy\[default\]" "$LOG"; then
	echo "ABORT: no F.5.d policy line in $LOG; restart via bench_setup.sh."
	exit 1
fi

mkdir -p "$ETC"
cleanup() { rm -f "$ETC/default.policy" "$ETC/null.policy"; }
trap cleanup EXIT INT TERM
cleanup   # start inert

settle() { sleep 1.5; }
check() {
	if [ "$3" = "$2" ]; then printf "  %-52s ok (%s)\n" "$1" "$3"
	else printf "  %-52s FAIL (got %s, want %s)\n" "$1" "$3" "$2"; fails=$((fails+1)); fi
}
yes_if() {
	if [ "$2" -eq 0 ]; then printf "  %-52s ok\n" "$1"
	else printf "  %-52s FAIL\n" "$1"; fails=$((fails+1)); fi
}

echo "F.5.d: policy"

# 1: absent policy = valid, surfaces present (a connection refreshes them).
"$TONE" 1 440 120 >/dev/null 2>&1
settle
[ -f "$RUN/default/policy-valid" ]; yes_if "1: policy-valid surface exists" $?
[ "$(cat "$RUN/default/policy-valid" 2>/dev/null)" = "true" ]; yes_if "1: absent policy file is valid" $?
[ ! -s "$RUN/default/policy-errors" ]; yes_if "1: policy-errors empty" $?

# 2: live reload, no restart.
"$TONE" 1 440 120 --class blocked >/dev/null 2>&1
yes_if "2: class allowed before the rule (exit 0)" $?
printf 'version=1\ndeny_class=blocked\n' > "$ETC/default.policy"
"$TONE" 1 440 120 --class blocked >/dev/null 2>&1
rc=$?
check "2: live deny_class denies next connection" 2 "$rc"
rm -f "$ETC/default.policy"

# 3: precedence on a crafted policy.
cat > "$ETC/default.policy" << 'EOF'
version=1
default=deny
deny_label=badapp
deny_class=ads
allow_class=music
EOF
"$TONE" 1 440 120 --label badapp --class music >/dev/null 2>&1
check "3: deny_label beats allow_class" 2 "$?"
"$TONE" 1 440 120 --class ads >/dev/null 2>&1
check "3: deny_class denies" 2 "$?"
"$TONE" 1 440 120 --class music >/dev/null 2>&1
check "3: allow_class admits under default=deny" 0 "$?"
"$TONE" 1 440 120 --class podcast >/dev/null 2>&1
check "3: default=deny is the fallthrough" 2 "$?"
rm -f "$ETC/default.policy"
settle

# 4: validation parity diagnostics; malformed policy never fatal.
printf 'version=2\nfrobnicate=yes\ndeny_class=ads\n' > "$ETC/default.policy"
"$TONE" 1 440 120 >/dev/null 2>&1
r_admit=$?
settle
[ "$(cat "$RUN/default/policy-valid" 2>/dev/null)" = "false" ]; yes_if "4: policy-valid=false on bad policy" $?
grep -q "^unsupported policy version$" "$RUN/default/policy-errors"; yes_if "4: 'unsupported policy version' diagnostic" $?
grep -q "^unknown directive: frobnicate=yes$" "$RUN/default/policy-errors"; yes_if "4: 'unknown directive' diagnostic exact" $?
yes_if "4: client still admitted with what parsed (exit 0)" "$r_admit"
"$TONE" 1 440 120 --class ads >/dev/null 2>&1
check "4: parsed deny_class still enforced" 2 "$?"
pgrep -x semasound >/dev/null; yes_if "4: broker alive on malformed policy" $?
rm -f "$ETC/default.policy"
settle

# 5: ducking (EAR). music 7s; alert joins at t=2 for 2s. duck_gain=0.25.
printf 'version=1\noverride_class=alert\nduck_gain=0.25\n' > "$ETC/default.policy"
m=$(wc -l < "$LOG")
"$TONE" 7 440 150 --class music >/dev/null 2>&1 &
P1=$!
sleep 2
"$TONE" 2 880 150 --class alert >/dev/null 2>&1
wait "$P1"
settle
if tail -n +"$((m + 1))" "$LOG" | grep "accepted" | grep "class=alert" | grep -q "\[override\]"; then
	echo "  5: alert admitted as [override]                      ok"
else
	echo "  5: alert admitted as [override]                      FAIL"; fails=$((fails+1))
fi
echo "  5: EAR CHECK: 440 Hz ducks while 880 Hz plays, then returns to full"
rm -f "$ETC/default.policy"
settle

# 6: unity spot-check, no override active: F.5.b passthrough unchanged.
m=$(wc -l < "$LOG")
"$TONE" 2 440 150 --rate 44100 >/dev/null 2>&1
settle
if tail -n +"$((m + 1))" "$LOG" | grep "accepted" | grep "rate=44100" | grep -q "hw=44100.*passthrough"; then
	echo "  6: lone 44.1k passthrough unchanged                  ok"
else
	echo "  6: lone 44.1k passthrough unchanged                  FAIL"; fails=$((fails+1))
fi

# 7: group exclusivity + protocol-visible preemption.
printf 'version=1\ngroup=g1\noverride_class=alert\n' > "$ETC/default.policy"
printf 'version=1\ngroup=g1\n' > "$ETC/null.policy"
"$TONE" 8 660 120 --target null >/dev/null 2>&1 &
PN=$!
sleep 1
"$TONE" 1 440 120 >/dev/null 2>&1
check "7: group-busy denies a normal client" 2 "$?"
"$TONE" 2 880 150 --class alert >/dev/null 2>&1 &
PA=$!
wait "$PN"
rn=$?
wait "$PA"
check "7: grouped peer PREEMPTED (tone exit 3)" 3 "$rn"
grep -q "policy: preempted client" "$LOG"; yes_if "7: preemption logged" $?
pgrep -x semasound >/dev/null; yes_if "7: broker alive after preemption" $?
rm -f "$ETC/default.policy" "$ETC/null.policy"
settle

# 9: leak across policy cycles (deny + allow + preempt mixed above; here a
# tight loop of deny/allow reload cycles).
printf 'version=1\ndeny_class=blocked\n' > "$ETC/default.policy"
fd0=$(procstat -f "$BPID" 2>/dev/null | wc -l | tr -d ' ')
rss0=$(ps -o rss= -p "$BPID" | tr -d ' ')
i=0
while [ "$i" -lt 10 ]; do
	"$TONE" 1 440 100 --class blocked >/dev/null 2>&1   # denied
	"$TONE" 1 440 100 --class music >/dev/null 2>&1     # allowed
	sleep 1.2
	i=$((i + 1))
done
sleep 2
fd1=$(procstat -f "$BPID" 2>/dev/null | wc -l | tr -d ' ')
rss1=$(ps -o rss= -p "$BPID" | tr -d ' ')
check "9: fd count stable across policy cycles" "$fd0" "$fd1"
drss=$((rss1 - rss0))
if [ "$drss" -lt 2048 ] && [ "$drss" -gt -2048 ]; then
	echo "  9: RSS stable (delta ${drss} KiB)                    ok"
else
	echo "  9: RSS delta ${drss} KiB                             FAIL"; fails=$((fails+1))
fi
rm -f "$ETC/default.policy"

echo ""
if [ "$fails" -eq 0 ]; then
	echo "F.5.d: ALL SCRIPTED CASES PASS (plus the EAR CHECK in case 5)"
	echo "Criterion 8 (inertness): policy files are now removed; run"
	echo "  sudo sh f5b_election.sh && sudo sh f5c_targets.sh"
	echo "both must pass unchanged."
else
	echo "F.5.d: $fails FAILURE(S)"
fi
