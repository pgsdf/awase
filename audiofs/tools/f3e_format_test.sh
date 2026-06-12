#!/bin/sh
#
# f3e_format_test.sh - F.3.e (ADR 0019) format-negotiation bench test.
#
# Exercises the ADR 0019 closure criteria using the tools in
# this directory tree:
#
#   playtone   --setrate R   mid-stream reconfigure with audio
#   setfmt                   GET / no-op / EINVAL / --seq cycling
#   clock_dump               watch sample_rate + samples_written
#   audiofs_events_dump      count and decode format_change events
#
# Coverage:
#   crit 1  GET returns 48000 / 16 / 2 and the DAC's supported mask
#   crit 2  SET 44100 reconfigures: clock flips, monotonic, 1 event
#   crit 3  SET 32000 reconfigures likewise
#   crit 4  cycle 44100 -> 48000 -> 32000 in one open (reconfigure
#           back to 48000 from a non-default rate), 3 events
#   crit 5  SET to the current rate is a no-op: no event, no restart
#   crit 6  unadvertised rate / non-16-bit / non-stereo -> EINVAL,
#           stream left unchanged, no event
#   crit 7  each real change emits exactly one format_change with the
#           correct new_rate
#   crit 9  dmesg free of panic / WITNESS / trap across the run
#
# Aural checks (crit 2/3 pitch) and the clean-unload check (crit 8)
# are called out as manual steps; this script does not kldunload.
#
# Run as root from the tools directory (it opens the device and
# issues ioctls). The module must already be loaded.
#
#   sudo ./f3e_format_test.sh [device]
#
# Override the device with the first argument or $DEV
# (default /dev/audiofs0).

set -u

DEV="${1:-${DEV:-/dev/audiofs0}}"
TOOLS="$(cd "$(dirname "$0")" && pwd)"
PLAYTONE="$TOOLS/playtone/playtone"
SETFMT="$TOOLS/setfmt/setfmt"
CLOCK_DUMP="$TOOLS/clock_dump/clock_dump"
EVENTS_DUMP="$TOOLS/audiofs_events_dump/audiofs_events_dump"

WORK="$(mktemp -d /tmp/f3e.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
note() { echo "  note: $*"; }

# ---- preflight -------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root (device open + ioctls)"; exit 1
fi
for t in "$PLAYTONE" "$SETFMT" "$CLOCK_DUMP" "$EVENTS_DUMP"; do
	if [ ! -x "$t" ]; then
		echo "missing tool: $t"
		echo "build it first (cd to its dir; make)."
		exit 1
	fi
done
if [ ! -c "$DEV" ]; then
	echo "no device $DEV (is audiofs loaded?)"; exit 1
fi

echo "=== F.3.e format negotiation test on $DEV ==="
dmesg > "$WORK/dmesg.before" 2>/dev/null || true

# count of format_change events currently in the ring
count_fc() {
	"$EVENTS_DUMP" --type format_change 2>/dev/null \
	    | grep -c 'type=format_change'
}

# last decoded new_rate among format_change events
last_new_rate() {
	"$EVENTS_DUMP" --type format_change 2>/dev/null \
	    | sed -n 's/.*new_rate=\([0-9][0-9]*\).*/\1/p' | tail -1
}

# distinct sample_rate values seen in a clock_dump capture
dump_rates() {
	sed -n 's/.*sample_rate=\([0-9][0-9]*\).*/\1/p' "$1" \
	    | sort -un | tr '\n' ' '
}

# OK if samples_written never decreases across the capture
dump_monotonic() {
	awk -F'samples_written=' 'NF > 1 {
		split($2, a, " "); v = a[1] + 0
		if (seen && v < prev) { print "BAD"; exit }
		prev = v; seen = 1
	} END { print "OK" }' "$1"
}

# does the space-joined rate list contain $2 ?
has_rate() {
	case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

# ---- criterion 1: GET + supported mask -------------------------------
echo "--- crit 1: GET_FORMAT ---"
out="$("$SETFMT" "$DEV" 2>&1)"; echo "$out" | sed 's/^/    /'
rate="$(echo "$out" | sed -n 's/.*GET_FORMAT: rate=\([0-9][0-9]*\).*/\1/p')"
[ "$rate" = "48000" ] && pass "default rate 48000" \
	|| fail "default rate is '$rate', expected 48000"
if echo "$out" | grep -q '48000'; then
	pass "supported mask advertises 48000"
else
	fail "supported mask missing 48000"
fi
echo "$out" | grep -q '44100' && note "DAC advertises 44100" \
	|| note "DAC does not advertise 44100 (44.1k tests will be EINVAL)"
echo "$out" | grep -q '32000' && note "DAC advertises 32000" \
	|| note "DAC does not advertise 32000 (32k tests will be EINVAL)"

# ---- crit 2/3/7: mid-stream reconfigure with audio -------------------
# 12 s tone, switch at the 6 s byte midpoint; sample the clock across it.
run_switch() {
	R="$1"
	echo "--- crit reconfigure -> $R (listen for a pitch change) ---"
	fc0="$(count_fc)"
	"$PLAYTONE" --setrate "$R" "$DEV" 12 > "$WORK/play.$R" 2>&1 &
	pt=$!
	sleep 1
	"$CLOCK_DUMP" 40 250 > "$WORK/dump.$R" 2>&1
	wait "$pt"
	grep -E 'SET_FORMAT|GET_FORMAT' "$WORK/play.$R" | sed 's/^/    /'

	rates="$(dump_rates "$WORK/dump.$R")"
	note "clock sample_rate values seen: $rates"
	if has_rate "$rates" 48000 && has_rate "$rates" "$R"; then
		pass "clock flipped 48000 -> $R during the stream"
	else
		fail "did not see both 48000 and $R in the clock (saw: $rates)"
	fi
	[ "$(dump_monotonic "$WORK/dump.$R")" = "OK" ] \
		&& pass "samples_written monotonic across the change" \
		|| fail "samples_written regressed across the change"

	fc1="$(count_fc)"; dfc=$((fc1 - fc0))
	[ "$dfc" -eq 1 ] && pass "exactly one format_change event" \
		|| fail "expected 1 format_change event, got $dfc"
	nr="$(last_new_rate)"
	[ "$nr" = "$R" ] && pass "format_change new_rate=$R" \
		|| fail "format_change new_rate is '$nr', expected $R"
}
run_switch 44100
run_switch 32000

# ---- crit 4: cycle in one open (reconfigure back to 48000) -----------
# Each SET's GET in --seq proves it took effect; the middle 48000 (after
# 44100) is the reconfigure-back-to-default case. This is deterministic,
# unlike sampling sub-second transitions through the clock file, so crit 4
# asserts on the GET sequence and the event count, not on clock_dump.
echo "--- crit 4: cycle 44100 -> 48000 -> 32000 in one open ---"
fc0="$(count_fc)"
"$SETFMT" --seq "$DEV" 44100 48000 32000 > "$WORK/seq" 2>&1
grep -E 'SET_FORMAT|GET_FORMAT' "$WORK/seq" | sed 's/^/    /'
gets="$(sed -n 's/.*GET_FORMAT: rate=\([0-9][0-9]*\).*/\1/p' "$WORK/seq" \
    | tr '\n' ' ')"
note "GET rate after each SET: $gets"
if [ "$gets" = "44100 48000 32000 " ]; then
	pass "each SET took effect in order, including back to 48000"
else
	fail "GET sequence was '$gets', expected '44100 48000 32000 '"
fi
fc1="$(count_fc)"; dfc=$((fc1 - fc0))
[ "$dfc" -eq 3 ] && pass "three format_change events for the cycle" \
	|| fail "expected 3 format_change events, got $dfc"

# ---- crit 5: no-op SET -----------------------------------------------
echo "--- crit 5: SET to current rate (no-op) ---"
fc0="$(count_fc)"
out="$("$SETFMT" "$DEV" 48000 2>&1)"; echo "$out" | sed 's/^/    /'
echo "$out" | grep -q 'SET_FORMAT:.* ok' \
	&& pass "SET 48000 returned ok" \
	|| fail "SET 48000 did not return ok"
fc1="$(count_fc)"; dfc=$((fc1 - fc0))
[ "$dfc" -eq 0 ] && pass "no format_change event for the no-op" \
	|| fail "no-op emitted $dfc format_change event(s)"

# ---- crit 6: EINVAL paths --------------------------------------------
echo "--- crit 6: rejected requests (expect errno=22, unchanged) ---"
einval_case() {
	desc="$1"; shift
	fc0="$(count_fc)"
	out="$("$SETFMT" "$DEV" "$@" 2>&1)"; echo "$out" | sed 's/^/    /'
	if echo "$out" | grep -q 'errno=22'; then
		pass "$desc rejected with EINVAL"
	else
		fail "$desc not rejected (expected errno=22)"
	fi
	gr="$(echo "$out" | sed -n 's/.*GET_FORMAT: rate=\([0-9][0-9]*\).*/\1/p')"
	[ "$gr" = "48000" ] && pass "$desc left stream at 48000" \
		|| fail "$desc changed stream to '$gr'"
	fc1="$(count_fc)"; dfc=$((fc1 - fc0))
	[ "$dfc" -eq 0 ] && pass "$desc emitted no format_change" \
		|| fail "$desc emitted $dfc format_change event(s)"
}
einval_case "unadvertised rate 96000" 96000
einval_case "non-16-bit (24)" 48000 24 2
einval_case "non-stereo (1 ch)" 48000 16 1

# ---- crit 9: dmesg scan ----------------------------------------------
echo "--- crit 9: dmesg trouble scan ---"
dmesg > "$WORK/dmesg.after" 2>/dev/null || true
PAT='panic|WITNESS|[Ll]ock order|trap [0-9]|page fault|Duplicate free|Memory modified|use-after-free|negative ref|vm_map.*fail'
diff "$WORK/dmesg.before" "$WORK/dmesg.after" 2>/dev/null \
    | sed -n 's/^> //p' > "$WORK/dmesg.new" || true
if grep -E -i "$PAT" "$WORK/dmesg.new" > "$WORK/hits" 2>/dev/null; then
	fail "trouble lines in dmesg:"; sed 's/^/      /' "$WORK/hits"
else
	pass "dmesg clean (no panic/WITNESS/trap)"
fi

# ---- verdict ---------------------------------------------------------
echo ""
echo "=== verdict: $PASS passed, $FAIL failed ==="
echo "Manual checks not automatable here:"
echo "  - crit 2/3: confirm the tone's pitch dropped at each switch."
echo "  - crit 8:   sudo kldunload audiofs; confirm clean detach"
echo "              (re-run clock_integrity.sh to reconfirm F.4)."
[ "$FAIL" -eq 0 ] && echo "RESULT: PASS (pending the two manual checks)" \
	|| echo "RESULT: FAIL; see failures above."
exit "$FAIL"
