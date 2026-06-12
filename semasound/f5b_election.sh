#!/bin/sh
#
# f5b_election.sh -- F.5.b criteria 5 and 9: hardware-rate election. TEST ONLY.
#
# Exercises the ratified Stage 2 semantics (ADR 0024, Decision 2 Stage 2
# realization):
#   A. lone 44.1k client session: election to 44100, client [passthrough]
#   B. 48k client JOINS mid-session: NO SET_FORMAT, joiner [resampling] to
#      44100 (Decision 2 overlap)
#   C. next session starts with TWO clients: exactly one deferred SET_FORMAT
#      to 48000 at the session boundary
#   D. lone 48k session right after: rate already 48000, NO SET_FORMAT (no-op)
#   E. lone 44.1k again: exactly one SET_FORMAT back to 44100
#   F. criterion 9: fd count and RSS stable across many election cycles
#
# Prereq: broker running (bench_setup.sh). Usage: sudo sh f5b_election.sh

set -u
TONE="./zig-out/bin/semasound-tone"
LOG="${SEMASOUND_LOG:-/tmp/semasound.log}"   # f5prod.sh overrides for the supervised broker
fails=0

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -x "$TONE" ] || { echo "missing $TONE (zig build)" >&2; exit 1; }
pgrep -x semasound >/dev/null || { echo "semasound not running (bench_setup.sh first)" >&2; exit 1; }
BPID=$(pgrep -x semasound)

# PREFLIGHT: refuse to measure a stale setup. Every prior all-negative run of
# this harness was a stale binary or stale broker, not an election bug.
BIN="${SEMASOUND_BIN:-./zig-out/bin/semasound}"
if ! grep -qa "election: SET_FORMAT" "$BIN"; then
	echo "ABORT: $BIN does not contain Stage 2 election code."
	echo "       Copy election.zig/main.zig/output.zig/build.zig, then:"
	echo "       rm -rf .zig-cache && zig build test && zig build"
	exit 1
fi
bin_age=$(( $(date +%s) - $(stat -f %m "$BIN") ))
broker_up=$(ps -o etimes= -p "$BPID" | tr -d ' ')
if [ "$broker_up" -gt "$bin_age" ]; then
	echo "ABORT: running broker (up ${broker_up}s) predates the binary"
	echo "       (built ${bin_age}s ago). Restart it:"
	echo "       sudo pkill -x semasound && sudo sh bench_setup.sh"
	exit 1
fi
if ! grep -q "election:" "$LOG"; then
	echo "ABORT: no 'election:' startup line in $LOG. The running broker is"
	echo "       not the Stage 2 binary. Restart via bench_setup.sh."
	exit 1
fi

mark() { wc -l < "$LOG"; }
setfmt_since() { tail -n +"$(($1 + 1))" "$LOG" | grep -c "election: SET_FORMAT"; }
accepted_since() { tail -n +"$(($1 + 1))" "$LOG" | grep "client .* accepted"; }

check() { # name expected actual
	if [ "$3" = "$2" ]; then printf "  %-44s ok (%s)\n" "$1" "$3"
	else printf "  %-44s FAIL (got %s, want %s)\n" "$1" "$3" "$2"; fails=$((fails+1)); fi
}

echo "F.5.b criterion 5: hardware-rate election (and criterion 9 leak check)"

# Sessions are separated by settling sleeps: a finished client's slot stays
# active until its ring drains (~370 ms) and the reaper frees it, and the
# 0-to-1 election condition requires a genuinely empty set. Back-to-back
# sessions are ONE session from election's point of view.
settle() { sleep 1.5; }

# Normalize: the lazy rest state means the device may rest at 44100 from a
# previous run. A lone 48k session elects 48000 (or no-ops), giving every
# case below a known starting rate.
"$TONE" 1 440 120 >/dev/null 2>&1
settle

# A: lone 44.1k session.
m=$(mark)
"$TONE" 4 440 150 --rate 44100 >/dev/null 2>&1
settle
check "A: lone 44.1k -> one SET_FORMAT (to 44100)" 1 "$(setfmt_since "$m")"
if accepted_since "$m" | grep -q "hw=44100.*passthrough"; then
	echo "  A: client passthrough at hw=44100              ok"
else
	echo "  A: client passthrough at hw=44100              FAIL"; fails=$((fails+1))
fi

# B: 48k joins mid-session: no SET_FORMAT, joiner resampled to 44100.
m=$(mark)
"$TONE" 8 440 150 --rate 44100 >/dev/null 2>&1 &
P1=$!
sleep 2
"$TONE" 3 660 150 >/dev/null 2>&1   # 48k stereo joiner
wait "$P1"
settle
check "B: mid-session join -> NO SET_FORMAT" 0 "$(setfmt_since "$m")"
if accepted_since "$m" | grep "rate=48000" | grep -q "hw=44100.*resampling"; then
	echo "  B: joiner resampled to 44100 (overlap)         ok"
else
	echo "  B: joiner resampled to 44100 (overlap)         FAIL"; fails=$((fails+1))
fi

# C: session OPENED by a non-hardware-rate client (Decision 1 else-branch):
# exactly one SET_FORMAT to 48000 (rate rests at 44100 after B), opener
# resampling; a hardware-rate joiner then resamples to 48000 with no further
# SET_FORMAT. (Two-clients-from-idle semantics pend the Decision 1 /
# criterion 5 ruling: under 0-to-1 election the session rate is the
# OPENER's election.)
m=$(mark)
"$TONE" 5 440 150 --rate 22050 >/dev/null 2>&1 &
P1=$!
sleep 1.5
"$TONE" 2 660 150 --rate 44100 >/dev/null 2>&1
wait "$P1"
settle
check "C: non-hw-rate opener -> one SET_FORMAT (48000)" 1 "$(setfmt_since "$m")"
if tail -n +"$((m + 1))" "$LOG" | grep "election: SET_FORMAT" | grep -q "48000"; then
	echo "  C: SET_FORMAT target is 48000                  ok"
else
	echo "  C: SET_FORMAT target is 48000                  FAIL"; fails=$((fails+1))
fi
if accepted_since "$m" | grep "rate=44100" | grep -q "hw=48000.*resampling"; then
	echo "  C: hw-rate joiner resampled to 48000           ok"
else
	echo "  C: hw-rate joiner resampled to 48000           FAIL"; fails=$((fails+1))
fi

# D: lone 48k session, rate already 48000: no-op, no SET_FORMAT.
m=$(mark)
"$TONE" 3 440 150 >/dev/null 2>&1
settle
check "D: lone 48k at 48000 -> NO SET_FORMAT (no-op)" 0 "$(setfmt_since "$m")"

# E: lone 44.1k again: exactly one SET_FORMAT back to 44100.
m=$(mark)
"$TONE" 3 440 150 --rate 44100 >/dev/null 2>&1
settle
check "E: lone 44.1k -> one SET_FORMAT back (44100)" 1 "$(setfmt_since "$m")"

# F: criterion 9: fds and RSS stable across many election cycles.
fd0=$(procstat -f "$BPID" 2>/dev/null | wc -l | tr -d ' ')
rss0=$(ps -o rss= -p "$BPID" | tr -d ' ')
i=0
while [ "$i" -lt 12 ]; do
	"$TONE" 1 440 120 --rate 44100 >/dev/null 2>&1   # elects 44100
	sleep 1.2
	"$TONE" 1 440 120 >/dev/null 2>&1                 # elects 48000
	sleep 1.2
	i=$((i + 1))
done
sleep 2  # let the final client fully drain before the fd/RSS snapshot
fd1=$(procstat -f "$BPID" 2>/dev/null | wc -l | tr -d ' ')
rss1=$(ps -o rss= -p "$BPID" | tr -d ' ')
check "F: fd count stable across 24 election cycles" "$fd0" "$fd1"
drss=$((rss1 - rss0))
if [ "$drss" -lt 2048 ] && [ "$drss" -gt -2048 ]; then
	echo "  F: RSS stable (delta ${drss} KiB)              ok"
else
	echo "  F: RSS delta ${drss} KiB                       FAIL"; fails=$((fails+1))
fi
pgrep -x semasound >/dev/null && echo "  broker alive after all cycles                  ok" || { echo "  broker DIED"; fails=$((fails+1)); }

echo ""
if [ "$fails" -eq 0 ]; then
	echo "criteria 5+9: ALL CASES PASS"
else
	echo "criteria 5+9: $fails FAILURE(S)"
fi
