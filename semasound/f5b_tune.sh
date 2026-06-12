#!/bin/sh
#
# f5b_tune.sh -- F.5.b criterion 8 bench system-ID harness. TEST ONLY.
#
# This is a FEASIBILITY search, not an optimization. For each (KP,EPS,TAU)
# config it checks the two HARD CONSTRAINTS that define criterion 8:
#   C1 (acquisition): ring fill stays off BOTH rails [<=2%, >=98%] for the
#      entire run, including the acquisition transient.
#   C2 (steady state): in the final third of the run, the drift is corrected
#      -- the filtered rate error sits near the injected ppm and fill is not
#      trending (mean fill change across the last third is small).
# A config PASSES only if BOTH hold. The goal is to find the smallest region
# of configs that pass, not the "best" numbers.
#
# Co-tuned envelope (do not treat as independent knobs):
#   KP responsiveness, EPS stability/level term, TAU noise shaping.
#
# Starts/stops the broker per config (handles env + root redirect correctly,
# the thing that is awkward by hand). Drifting resampled client: 44100,
# +DRIFT_PPM, low amplitude.
#
# Usage: sudo sh f5b_tune.sh [seconds_per_config] [drift_ppm]
#   defaults: 240 s, 1000 ppm. Edit the CONFIGS list below to set the sweep.

set -u

BROKER="./zig-out/bin/semasound"
TONE="./zig-out/bin/semasound-tone"
LOG=/tmp/semasound.log
SOCK=/var/run/sema/audio.sock
SECS="${1:-240}"
DRIFT="${2:-1000}"

# Instrumentation round: prove which term drives trim variance via per-
# component std. Hypothesis: the level term (eps * fill_dev) injects the
# fill-quantization noise into trim. Test directly by varying EPS at a fixed,
# well-behaved KP/TAU: if std(level) and std(trim) fall together as EPS drops
# while std(p) stays small, the level term is the dominant variance source.
# (EPS=0 isolates the rate path entirely; expect low trim std but watch C1,
# since with no level term fill should begin to diffuse.)
CONFIGS="
0.2 0.02 120 0.05
0.2 0.01 120 0.05
0.2 0.005 120 0.05
0.2 0.0 120 0.05
"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -x "$BROKER" ] || { echo "missing $BROKER (zig build)" >&2; exit 1; }
[ -x "$TONE" ] || { echo "missing $TONE" >&2; exit 1; }
[ -e /dev/audiofs0 ] || { echo "/dev/audiofs0 absent (load audiofs)" >&2; exit 1; }

cleanup() {
	pkill -x semasound 2>/dev/null
	pkill -x semasound-tone 2>/dev/null
	pkill -CONT -x semasound-tone 2>/dev/null
	sleep 1
	rm -f "$SOCK"
}

test_config() {
	kp="$1"; eps="$2"; tau="$3"; ki="$4"
	cleanup
	: > "$LOG"
	# root does the redirect, env reaches the broker.
	SEMASOUND_KP="$kp" SEMASOUND_EPS="$eps" SEMASOUND_EMA_TAU_S="$tau" SEMASOUND_KI="$ki" \
		"$BROKER" > "$LOG" 2>&1 &
	bpid=$!
	i=0
	while ! grep -q "output open" "$LOG" 2>/dev/null; do
		if ! kill -0 "$bpid" 2>/dev/null; then
			printf "KP=%-4s EPS=%-5s TAU=%-4s KI=%-4s  broker died: %s\n" \
				"$kp" "$eps" "$tau" "$ki" "$(tail -1 "$LOG")"; return
		fi
		sleep 0.3; i=$((i+1)); [ "$i" -ge 27 ] && { echo "broker no-open"; kill "$bpid"; return; }
	done

	"$TONE" "$SECS" 440 150 --rate 44100 --drift-ppm "$DRIFT" >/dev/null 2>&1

	raw=$(grep "drift raw:" "$LOG" | tail -n +2)
	n=$(printf "%s\n" "$raw" | grep -c "drift raw:")
	[ "$n" -eq 0 ] && { printf "KP=%-4s EPS=%-5s TAU=%-4s KI=%-4s  NO TRACE\n" "$kp" "$eps" "$tau" "$ki"; return; }

	fills=$(printf "%s\n" "$raw" | sed -n 's/.*fill \([0-9]*\)%.*/\1/p')
	fmin=$(printf "%s\n" "$fills" | sort -n | head -1)
	fmax=$(printf "%s\n" "$fills" | sort -n | tail -1)

	# C2: final third. The CONTROLLED output is the trim; it should settle
	# NEAR the injected ppm (convergence) with LOW variance (the real
	# remaining problem). filt is the residual rate error and correctly trends
	# to ~0, so it is NOT the convergence target -- judging trim, not filt.
	third=$((n / 3)); [ "$third" -lt 1 ] && third=1
	tail3=$(printf "%s\n" "$raw" | tail -n "$third")
	trims=$(printf "%s\n" "$tail3" | sed -n 's/.*trim \(-\{0,1\}[0-9.]*\) ppm.*/\1/p')
	# mean and population std of trim over the final third (separate awk calls
	# to avoid nested-heredoc fragility inside the outer read loop).
	trim_mean=$(printf "%s\n" "$trims" | awk '{s+=$1; c++} END{printf "%.0f", c?s/c:0}')
	trim_std=$(printf "%s\n" "$trims" | awk '{s+=$1; sq+=$1*$1; c++} END{m=c?s/c:0; v=c?sq/c-m*m:0; if(v<0)v=0; printf "%.0f", sqrt(v)}')
	# Per-component std (proof of which term drives trim variance). p/i/level
	# are each a ppm contribution in the trace. Patterns match the exact
	# space-delimited token to avoid substring collisions (the 'i' of filt etc).
	stdof() { printf "%s\n" "$tail3" | sed -n "s/.* $1 \(-\{0,1\}[0-9.]*\) .*/\1/p" \
		| awk '{s+=$1; sq+=$1*$1; c++} END{m=c?s/c:0; v=c?sq/c-m*m:0; if(v<0)v=0; printf "%.0f", sqrt(v)}'; }
	p_std=$(stdof "p")
	i_std=$(stdof "i")
	lvl_std=$(stdof "level")
	# convergence error: |mean trim - injected ppm|
	conv=$(awk -v m="$trim_mean" -v d="$DRIFT" 'BEGIN{e=m-d; if(e<0)e=-e; printf "%.0f", e}')
	# fill trend across the final third
	f_first=$(printf "%s\n" "$tail3" | head -1 | sed -n 's/.*fill \([0-9]*\)%.*/\1/p')
	f_last=$(printf "%s\n" "$tail3" | tail -1 | sed -n 's/.*fill \([0-9]*\)%.*/\1/p')
	trend=$((f_last - f_first))
	atrend=$( [ "$trend" -lt 0 ] && echo $((-trend)) || echo "$trend" )

	# Verdicts. C1: fill off both rails. C2: trim mean near target (conv),
	# trim variance low (std), fill not trending. All three are reported so
	# variance and mean separation are visible, not collapsed into one number.
	c1="ok"
	if [ "$fmin" -le 2 ] || [ "$fmax" -ge 98 ]; then c1="WALL"; fi
	c2="ok"
	[ "$conv" -gt 200 ] && c2="mean"          # mean trim > 200 ppm off target
	[ "$trim_std" -gt 500 ] && c2="VAR"       # trim std > 500 ppm: oscillating
	[ "$atrend" -gt 10 ] && c2="trend"        # fill still moving > 10%
	pass="PASS"; { [ "$c1" = "ok" ] && [ "$c2" = "ok" ]; } || pass="fail"

	printf "KP=%-4s EPS=%-5s TAU=%-4s KI=%-4s  fill %2s..%-3s%% C1=%-4s | trim mean %5s std %5s (conv %4s) | std p=%-5s i=%-5s lvl=%-5s | C2=%-5s | %s\n" \
		"$kp" "$eps" "$tau" "$ki" "$fmin" "$fmax" "$c1" "$trim_mean" "$trim_std" "$conv" "$p_std" "$i_std" "$lvl_std" "$c2" "$pass"
}

echo "F.5.b criterion-8 feasibility search (${SECS}s/config, +${DRIFT} ppm)"
echo "C1: fill off both rails all run. C2: trim mean near target, trim std low, fill not trending."
echo "Goal: smallest region where BOTH hold. Not an optimization."
echo ""
printf "%s\n" "$CONFIGS" | while read kp eps tau ki; do
	[ -z "${kp:-}" ] && continue
	test_config "$kp" "$eps" "$tau" "$ki"
done
cleanup
echo ""
echo "PASS = bounded fill during acquisition AND corrected in steady state."
