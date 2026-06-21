#!/bin/sh
# display-freeze-soak.sh
#
# Long idle-soak watcher for the display/scanout freeze, now that the
# audiofs storm is gone (AD-50 ratified) and the log is quiet. The
# question this answers: with the storm confound removed, does the
# display/input freeze still happen on a clean idle system, and if so,
# what does the kernel say at the moment it does?
#
# DESIGN NOTE (why no instrument flag): semadrawd's heavy frame/gate
# instrument (UTF_COMPOSITOR_INSTRUMENT) is read at compositor
# construction, so it can only be enabled by restarting semadrawd, and
# a restart clears the freeze. To have it on at freeze time it would
# have to run continuously at ~240 lines/s, which floods the log and
# adds steady CPU load: the exact confound we just removed. So this
# watcher deliberately does NOT use it. It samples only cheap,
# non-perturbing signals and pulls full thread stacks (procstat -kk)
# on demand, which name where a daemon is wedged with no flood.
#
# WHAT IT SAMPLES (every INTERVAL seconds, append-only, light):
#   - audio clock samples_written (offset 12 in /var/run/sema/clock)
#     and clock_valid (offset 4). This is the pacing source semadrawd
#     runs on; if it advances, the system heartbeat is alive.
#   - dev.audiofs.0.underflow_count (must stay flat; confirms the
#     storm has not returned to re-confound the test).
#   - liveness of semadrawd / pgsd-sessiond / semasound (pgrep) and inputfs (kldstat).
#
# WHEN IT CAPTURES the full kernel state (vt, console, dmesg,
# procstat -kk for the display+input daemons, clock, plus the recent
# liveness run-up):
#   - AUTO: the audio clock stalls (pacing source died), a watched
#     daemon disappears, or underflow runs away.
#   - MANUAL: you SEE the screen/input freeze and trigger a capture by
#     either  kill -USR1 <this pid>  or  touch /tmp/freeze-now
#     Headless sampling cannot perfectly detect "panel frozen but
#     system alive", so the human observation is the ground truth; the
#     watcher captures the run-up plus the kernel state at that instant.
#
# Usage (run over SSH; leave the bench's display idle and untouched):
#   sudo sh display-freeze-soak.sh [duration_s] [interval_s]
# Defaults: 3600 s (1 h) duration, 15 s interval.
# Stop early with Ctrl-C; it summarizes what it saw.

set -u

DURATION="${1:-3600}"
INTERVAL="${2:-15}"
CLOCK="/var/run/sema/clock"
UNDERFLOW_OID="dev.audiofs.0.underflow_count"
SENTINEL="/tmp/freeze-now"
RUNDIR="/var/tmp/awase-soak/$(date +%Y%m%d-%H%M%S)"
LIVELOG="$RUNDIR/liveness.log"
RUNUP_LINES=40          # how many recent samples to bundle into a capture
CAPTURE_HELPER="$(dirname "$0")/display-freeze-capture.sh"

mkdir -p "$RUNDIR" || { echo "cannot create $RUNDIR" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root (procstat/dmesg/sysctl need privilege): sudo sh $0" >&2
    exit 2
fi

# --- cheap samplers --------------------------------------------------
# samples_written: 8-byte LE unsigned at offset 12. od -tu8 is portable.
clock_samples() {
    dd if="$CLOCK" bs=1 skip=12 count=8 2>/dev/null | od -An -tu8 2>/dev/null | tr -d ' '
}
# clock_valid: 1 byte at offset 4.
clock_valid() {
    dd if="$CLOCK" bs=1 skip=4 count=1 2>/dev/null | od -An -tu1 2>/dev/null | tr -d ' '
}
underflow() { sysctl -n "$UNDERFLOW_OID" 2>/dev/null || echo "?"; }
pid_of() { pgrep -f "$1" 2>/dev/null | head -1; }
alive() { [ -n "$(pid_of "$1")" ] && echo 1 || echo 0; }

# --- full capture on trigger ----------------------------------------
capture() {
    reason="$1"
    ts="$(date +%H%M%S)"
    cdir="$RUNDIR/capture-$ts-$reason"
    mkdir -p "$cdir"
    echo "" ; echo ">>> CAPTURE fired ($reason) at $(date +%H:%M:%S) -> $cdir"

    # Prefer the dedicated capture helper if it is alongside this script.
    if [ -x "$CAPTURE_HELPER" ] || [ -f "$CAPTURE_HELPER" ]; then
        ( cd "$cdir" && sh "$CAPTURE_HELPER" freeze ) > "$cdir/freeze-capture.txt" 2>&1
    fi

    # Always grab these directly too (self-contained, helper or not).
    { dmesg | tail -40; } > "$cdir/dmesg.txt" 2>&1
    sysctl kern.vt > "$cdir/kern-vt.txt" 2>&1
    { conscontrol status 2>&1; echo "--"; sysctl kern.consmute 2>&1; } > "$cdir/console.txt" 2>&1
    sysctl hw.drawfs > "$cdir/hw-drawfs.txt" 2>&1
    for svc in semadrawd pgsd-sessiond semasound; do
        p="$(pid_of "/usr/local/bin/$svc")"; [ -z "$p" ] && p="$(pid_of "$svc")"
        if [ -n "$p" ]; then
            { echo "## $svc pid $p threads"; procstat -t "$p" 2>&1; \
              echo "## $svc kernel stacks"; procstat -kk "$p" 2>&1; } > "$cdir/threads-$svc.txt" 2>&1
        else
            echo "$svc not running" > "$cdir/threads-$svc.txt"
        fi
    done
    # The run-up: last RUNUP_LINES liveness samples leading into this.
    tail -n "$RUNUP_LINES" "$LIVELOG" > "$cdir/runup-liveness.txt" 2>&1
    echo ">>> capture written. continuing to watch (the freeze, if present, persists)."
}

# Manual trigger via signal.
trap 'capture usr1' USR1
# Clean summary on exit.
SUMMARY_DONE=0
finish() {
    [ "$SUMMARY_DONE" -eq 1 ] && return
    SUMMARY_DONE=1
    echo ""
    echo "==== soak summary -> $RUNDIR ===="
    echo "samples taken     : $SAMPLES"
    echo "clock advanced    : $([ "$CLOCK_EVER_STALLED" -eq 0 ] && echo 'always (pacing source stayed alive)' || echo "STALLED $CLOCK_STALLS time(s)")"
    echo "underflow         : $([ "$UF_RUNAWAY" -eq 0 ] && echo 'stayed flat (no storm)' || echo 'RAN AWAY (storm returned)')"
    echo "daemon drops      : $DAEMON_DROPS"
    echo "captures fired    : $CAPTURES"
    echo ""
    if [ "$CAPTURES" -eq 0 ] && [ "$CLOCK_EVER_STALLED" -eq 0 ] && [ "$DAEMON_DROPS" -eq 0 ]; then
        echo "RESULT: clean soak. Over ${ELAPSED}s the pacing clock kept"
        echo "advancing, audio stayed flat, daemons stayed up, and no freeze"
        echo "was observed or triggered. Consistent with the freeze having"
        echo "been storm-coupled (a downstream effect of the audiofs storm"
        echo "load), not an independent display bug. Re-run longer to harden."
    else
        echo "RESULT: something fired. Inspect the capture dir(s) under"
        echo "$RUNDIR. Key reads: threads-semadrawd.txt / threads-pgsd-sessiond.txt"
        echo "(where is the wedged thread blocked), kern-vt.txt + console.txt"
        echo "(vt/efifb ownership, AD-10), dmesg.txt (kernel words on a quiet log)."
    fi
    echo ""
    echo "to capture manually next time you SEE a freeze:"
    echo "  kill -USR1 $$    (this pid)   or   touch $SENTINEL"
}
trap 'finish; exit 0' INT TERM

# --- baseline + watch loop ------------------------------------------
echo "==== display-freeze idle soak ===="
echo "duration ${DURATION}s, interval ${INTERVAL}s, run dir $RUNDIR"
echo "manual capture: kill -USR1 $$   or   touch $SENTINEL"
echo "leave the bench display idle and untouched. watching..."
echo ""

START=$(date +%s)
SAMPLES=0; CAPTURES=0; DAEMON_DROPS=0
CLOCK_STALLS=0; CLOCK_EVER_STALLED=0; UF_RUNAWAY=0
PREV_SAMPLES=""; PREV_UF=""; PREV_DMN=""; ELAPSED=0
printf '%-8s %-12s %-18s %-9s %-6s %s\n' "elapsed" "underflow" "clk_samples" "clk_valid" "dmn" "note" > "$LIVELOG"
echo "# dmn field = semadrawd,pgsd-sessiond,semasound,inputfs(kld); 1111 = all up" >> "$LIVELOG"

while :; do
    now=$(date +%s); ELAPSED=$((now - START))
    [ "$ELAPSED" -ge "$DURATION" ] && break

    cs="$(clock_samples)"; cv="$(clock_valid)"; uf="$(underflow)"
    d_draw="$(alive '/usr/local/bin/semadrawd')"
    d_sess="$(alive '/usr/local/bin/pgsd-sessiond')"
    d_snd="$(alive '/usr/local/bin/semasound')"
    # input is the inputfs KERNEL MODULE plus semainput linked into the
    # compositor, not a standalone daemon. Match either name form via a
    # plain kldstat grep (most robust across FreeBSD versions; kldstat -n
    # with a bare name is not reliably accepted).
    if kldstat 2>/dev/null | grep -q inputfs; then d_in=1; else d_in=0; fi
    dmn="${d_draw}${d_sess}${d_snd}${d_in}"
    note=""

    # --- auto triggers ---
    # clock stall: samples_written did not advance since last sample.
    if [ -n "$PREV_SAMPLES" ] && [ -n "$cs" ] && [ "$cs" = "$PREV_SAMPLES" ]; then
        note="CLOCK-STALL"; CLOCK_STALLS=$((CLOCK_STALLS + 1)); CLOCK_EVER_STALLED=1
    fi
    # underflow runaway: storm returned.
    if [ -n "$PREV_UF" ] && [ "$uf" != "?" ] && [ "$PREV_UF" != "?" ] && [ "$uf" != "$PREV_UF" ]; then
        note="${note} UNDERFLOW-MOVING"; UF_RUNAWAY=1
    fi
    # daemon drop: EDGE-triggered. Only flag a daemon that was up on the
    # previous sample and is now missing. This makes a matcher that never
    # matches sit at a steady 0 (no transition, no fire) rather than
    # producing a permanent false DAEMON-DOWN. PREV_DMN seeds from the
    # first sample so a check that is wrong from t0 never trips.
    if [ -n "$PREV_DMN" ] && [ "$dmn" != "$PREV_DMN" ]; then
        i=1
        while [ "$i" -le 4 ]; do
            pc=$(printf '%s' "$PREV_DMN" | cut -c"$i")
            nc=$(printf '%s' "$dmn" | cut -c"$i")
            if [ "$pc" = "1" ] && [ "$nc" = "0" ]; then
                nm=$(echo "semadrawd pgsd-sessiond semasound inputfs" | cut -d' ' -f"$i")
                note="${note} DROP:$nm"; DAEMON_DROPS=$((DAEMON_DROPS + 1))
            fi
            i=$((i + 1))
        done
    fi

    printf '%-8s %-12s %-18s %-9s %-4s %s\n' "$ELAPSED" "$uf" "$cs" "$cv" "$dmn" "$note" >> "$LIVELOG"
    SAMPLES=$((SAMPLES + 1))

    # Fire a capture on any auto trigger (clock stall while daemons up is
    # the "system alive but stuck" signature; daemon down / storm return
    # are their own findings).
    case "$note" in
        *CLOCK-STALL*|*DROP:*|*UNDERFLOW-MOVING*)
            CAPTURES=$((CAPTURES + 1)); capture "auto" ;;
    esac

    # Manual sentinel-file trigger (alternative to SIGUSR1).
    if [ -f "$SENTINEL" ]; then
        rm -f "$SENTINEL"; CAPTURES=$((CAPTURES + 1)); capture "manual"
    fi

    PREV_SAMPLES="$cs"; PREV_UF="$uf"; PREV_DMN="$dmn"
    sleep "$INTERVAL"
done

finish
exit 0
