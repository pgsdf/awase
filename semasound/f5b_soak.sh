#!/bin/sh
#
# f5b_soak.sh -- F.5.b criterion 8 long-duration soak. TEST ONLY.
#
# Runs the bench-validated default envelope (no env overrides) against a
# sustained drifting client for a long time (hours), and reports occupancy
# and trim stability in successive time buckets. Purpose is NOT tuning: it is
# to confirm no slow-timescale behavior emerges that shorter runs missed
# (we have twice been surprised by long-horizon effects). Pass = across every
# bucket: fill stays off the rails, mean trim stays near the injected ppm, and
# nothing trends across buckets.
#
# Uses the compiled-in defaults (KP/KI/EPS/TAU), so it validates exactly what
# ships. Drifting resampled client at 44100 + DRIFT ppm.
#
# Usage: sudo sh f5b_soak.sh [total_seconds] [drift_ppm]
#   defaults: 7200 s (2 h), 1000 ppm.

set -u

BROKER="./zig-out/bin/semasound"
TONE="./zig-out/bin/semasound-tone"
LOG=/tmp/semasound.log
SOCK=/var/run/sema/audio.sock
SECS="${1:-7200}"
DRIFT="${2:-1000}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -x "$BROKER" ] || { echo "missing $BROKER (zig build)" >&2; exit 1; }
[ -x "$TONE" ] || { echo "missing $TONE" >&2; exit 1; }
[ -e /dev/audiofs0 ] || { echo "/dev/audiofs0 absent (load audiofs)" >&2; exit 1; }

pkill -x semasound 2>/dev/null; pkill -x semasound-tone 2>/dev/null
pkill -CONT -x semasound-tone 2>/dev/null
sleep 1; rm -f "$SOCK"; : > "$LOG"

echo "F.5.b soak: ${SECS}s (~$(( (SECS+1800)/3600 ))h), +${DRIFT} ppm, compiled-in defaults"
echo "starting broker (no env overrides, validates what ships)..."
"$BROKER" > "$LOG" 2>&1 &
bpid=$!
i=0
while ! grep -q "output open" "$LOG" 2>/dev/null; do
	kill -0 "$bpid" 2>/dev/null || { echo "broker died: $(tail -1 "$LOG")"; exit 1; }
	sleep 0.3; i=$((i+1)); [ "$i" -ge 27 ] && { echo "broker no-open"; kill "$bpid"; exit 1; }
done

# Stage 2 note: a LONE 44.1k client is now elected natively (passthrough,
# no resampler, estimator correctly idle), so the soak must reproduce the
# originally verified RESAMPLED configuration: a 48k ANCHOR client opens the
# session (electing 48000), and the drift client joins mid-session as a
# resampled 44.1k joiner (ADR 0024 Decision 2 overlap semantics). The anchor
# is near-silent (amp 5) and runs the full duration.
echo "broker up; starting 48k anchor (elects 48000), then ${SECS}s drift client..."
"$TONE" $((SECS + 10)) 440 5 >/dev/null 2>&1 &
ANCHOR=$!
sleep 2
"$TONE" "$SECS" 440 150 --rate 44100 --drift-ppm "$DRIFT" >/dev/null 2>&1
wait "$ANCHOR" 2>/dev/null

pkill -x semasound 2>/dev/null; rm -f "$SOCK"

# Analyze in time buckets. Split the drift-raw lines into N buckets and report
# per-bucket fill range, mean trim, and trim std, so slow drift across buckets
# is visible.
raw=$(grep "drift raw:" "$LOG")
n=$(printf "%s\n" "$raw" | grep -c "drift raw:")
[ "$n" -eq 0 ] && { echo "NO TRACE"; exit 1; }
echo ""
echo "windows captured: $n. Per-bucket stability (watch for trends across buckets):"
printf "%-8s %-14s %-14s %-10s\n" "bucket" "fill range %" "mean trim ppm" "trim std"

buckets=8
per=$(( (n + buckets - 1) / buckets ))
b=0
while [ "$b" -lt "$buckets" ]; do
	start=$(( b * per + 1 ))
	seg=$(printf "%s\n" "$raw" | sed -n "${start},$((start+per-1))p")
	[ -z "$seg" ] && break
	fmin=$(printf "%s\n" "$seg" | sed -n 's/.*fill \([0-9]*\)%.*/\1/p' | sort -n | head -1)
	fmax=$(printf "%s\n" "$seg" | sed -n 's/.*fill \([0-9]*\)%.*/\1/p' | sort -n | tail -1)
	tmean=$(printf "%s\n" "$seg" | sed -n 's/.*trim \(-\{0,1\}[0-9.]*\) ppm.*/\1/p' \
		| awk '{s+=$1;c++} END{printf "%.0f", c?s/c:0}')
	tstd=$(printf "%s\n" "$seg" | sed -n 's/.*trim \(-\{0,1\}[0-9.]*\) ppm.*/\1/p' \
		| awk '{s+=$1;sq+=$1*$1;c++} END{m=c?s/c:0;v=c?sq/c-m*m:0;if(v<0)v=0;printf "%.0f",sqrt(v)}')
	printf "%-8s %2s..%-10s %-14s %-10s\n" "$((b+1))" "$fmin" "${fmax}%" "$tmean" "$tstd"
	b=$((b+1))
done
echo ""
echo "PASS if, across ALL buckets: fill stays off rails (no approach to 0/100),"
echo "mean trim stays near ${DRIFT}, trim std stays bounded, and NO monotone"
echo "trend in fill or mean trim from first bucket to last (no slow drift)."
