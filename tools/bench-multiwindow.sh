#!/bin/sh
# bench-multiwindow.sh: the multi-window verification sitting.
#
# Covers, with per-step expectations and a tallied report:
#   Phase 0  deploy sanity + full unit suite on the bench
#   Phase 1  scale inheritance (patch 18: bare semadraw-term &)
#   Phase 2  placement (configure + move; recreates the two-window state)
#   Phase 3  focus routing (F-D7-1) via operator observation prompts
#   Phase 4  move/focus error grammar + off-screen clip, with capture
#   Phase 5  F-SESSION-1 setup (orphans), then, after logout, the
#            greeter assertions via the `greeter` entry point
#
# Usage (BOTH phases from the out-of-band shell, ssh or a spare vt,
# never from inside a semadraw-term: phase 3 moves keyboard focus
# between the terms, and a script running inside one could not read
# its own prompts the moment focus left it):
#   sh tools/bench-multiwindow.sh run       # with a session logged in
#   sh tools/bench-multiwindow.sh greeter   # at the login screen, after run
#
# The run phase drives its own setup: when the second terminal is
# missing it tells the operator exactly what to type in the console
# term (the launch must come from the session environment, because
# scale inheritance is itself under test) and polls the surface
# census until the new surface appears.
#
# Commands are executed and asserted automatically; what only eyes and
# the bench keyboard can verify becomes a recorded [y/n] prompt. Every
# step logs to $LOG; the exit code is the number of failures.

set -u
CTL="semadraw-ctl"
LOG="/tmp/bench-multiwindow.$(date +%Y%m%d-%H%M%S).log"
STATE="/tmp/bench-multiwindow.state"
PASS=0; FAIL=0; STEP=0

say()  { printf '%s\n' "$*" | tee -a "$LOG"; }
step() { STEP=$((STEP+1)); say ""; say "== step $STEP: $* =="; }
ok()   { PASS=$((PASS+1)); say "   PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); say "   FAIL: $*"; }

# run_expect <description> <expected-substring> <cmd...>
run_expect() {
    desc="$1"; want="$2"; shift 2
    step "$desc"
    say "   \$ $*"
    out=$("$@" 2>&1); rc=$?
    say "   -> [$rc] $out"
    case "$out" in
        *"$want"*) ok "output contains '$want'" ;;
        *)         bad "expected '$want', got '$out'" ;;
    esac
}

# ask <description> <question>   (operator observation, y = pass)
ask() {
    step "$1"
    printf '   %s [y/n] ' "$2"
    read -r ans
    say "   operator answered: $ans  ($2)"
    case "$ans" in y|Y) ok "$2" ;; *) bad "$2" ;; esac
}

surfaces() { sudo "$CTL" surfaces 2>&1; }

# Field extraction from a surfaces line: id=N ... pos=X,Y ...
# The key is anchored at a field boundary (start of line or a space):
# the first version used a bare greedy match, and uid=1002 satisfied
# id=..., which fed uids to every ctl command of the first full run
# and produced sixteen correct errors to sixteen wrong questions.
field() { printf '%s' "$1" | sed -n "s/.*[[:space:]]$2=\([^ ,]*\).*/\1/p"; }

report() {
    say ""
    say "==== $PASS passed, $FAIL failed; log: $LOG ===="
    exit "$FAIL"
}

greeter_phase() {
    say "bench-multiwindow GREETER phase; log: $LOG"
    [ -f "$STATE" ] || { say "no state file from the run phase ($STATE); aborting"; exit 1; }
    . "$STATE"   # provides ORPHAN1 ORPHAN2 SESSIOND_PID

    step "sessiond continuity (the reaper that acquired is the one reaping)"
    now_pid=$(pgrep -x pgsd-sessiond | head -1)
    if [ -n "${SESSIOND_PID:-}" ] && [ "$now_pid" = "$SESSIOND_PID" ]; then
        ok "sessiond pid unchanged ($now_pid) across the logout boundary"
    else
        bad "sessiond pid changed ('$SESSIOND_PID' -> '$now_pid'): it restarted or crashed during logout; the teardown verdict below is about THAT, not the escalation ladder"
    fi

    step "greeter surface census"
    out=$(surfaces); say "$out"
    n=$(printf '%s\n' "$out" | grep -c '^  id=')
    clients=$(printf '%s\n' "$out" | grep '^  id=' | grep -cv 'owner=4294967295')
    if [ "$n" -eq 2 ] && [ "$clients" -eq 1 ]; then
        ok "exactly cursor + one (sessiond) surface at the greeter"
    else
        bad "expected 2 surfaces (cursor + sessiond); listing shows $n with $clients client-owned"
    fi

    step "orphans are dead (reaper proof: $ORPHAN1 plain, $ORPHAN2 double-forked)"
    alive=0
    for p in $ORPHAN1 $ORPHAN2; do
        if kill -0 "$p" 2>/dev/null; then alive=$((alive+1)); say "   pid $p STILL ALIVE"; fi
    done
    if [ "$alive" -eq 0 ]; then ok "both orphan pids gone"; else bad "$alive orphan(s) survived logout"; fi

    ask "greeter display integrity" "Is the login screen whole, nothing overlaying it?"
    ask "greeter input (type at the console now)" "Do keystrokes appear in the login prompt?"

    rm -f "$STATE"
    report
}

[ "${1:-}" = "greeter" ] && greeter_phase
[ "${1:-}" = "run" ] || { say "usage: $0 run | greeter"; exit 1; }

say "bench-multiwindow RUN phase; log: $LOG"

if [ "${SEMADRAW_TERM:-}" = "1" ] && [ "${BENCH_FORCE:-}" != "1" ]; then
    say "REFUSING to run inside a semadraw-term: phase 3 moves keyboard"
    say "focus between the terms and would take the keyboard away from"
    say "this script's own prompts; two contaminated runs proved a"
    say "warning is not enough. Run from ssh or a spare vt."
    exit 1
fi

# ---- Phase 0: deploy sanity + suite -------------------------------
step "deploy sanity: binaries must postdate the HEAD commit"
head=$(cd /usr/local/src/awase && git log --format=%s -1)
# Newest commit touching binary-affecting paths, not bare HEAD: a
# tools-only or docs-only commit must not demand a reinstall (the
# first run of this check failed a perfectly coherent deploy against
# a script-only HEAD).
head_ct=$(cd /usr/local/src/awase && git log --format=%ct -1 -- semadraw/src semadraw/build.zig shared pgsd-sessiond/src pgsd-sessiond/build.zig install.sh)
say "   HEAD: $head"
stale=0
for b in semadrawd semadraw-term pgsd-sessiond semadraw-ctl; do
    f="/usr/local/bin/$b"
    if [ ! -x "$f" ]; then say "   $b: MISSING"; stale=1; continue; fi
    bm=$(stat -f %m "$f")
    if [ "$bm" -lt "$head_ct" ]; then
        say "   $b: installed $(stat -f %Sm "$f") PREDATES the newest binary-affecting commit"
        stale=1
    else
        say "   $b: installed $(stat -f %Sm "$f") (fresh)"
    fi
done
if [ "$stale" -eq 0 ]; then
    ok "all four binaries postdate the HEAD commit: coherent deploy, computed"
else
    bad "stale or missing binaries: run sh install.sh; nothing below is trustworthy"
    report
fi

step "full unit suite on the bench"
if (cd /usr/local/src/awase/semadraw && ../tools/zig build test >>"$LOG" 2>&1); then
    ok "zig build test green (first bench run of the five new suites counts here)"
else
    bad "zig build test failed; see $LOG"
fi

# ---- Phase 1: surfaces + scale inheritance ------------------------
step "surface census, driving setup if the second term is missing"
clients=$(surfaces | grep '^  id=' | grep -cv 'owner=4294967295')
if [ "$clients" -lt 1 ]; then
    bad "no client surfaces at all: is a session logged in?"; report
fi
if [ "$clients" -lt 2 ]; then
    say "   Second terminal not running. In the CONSOLE term, type:"
    say "       semadraw-term &"
    say "   (bare, no --scale: the launch from the session environment"
    say "   IS the scale-inheritance test). Waiting up to 60s..."
    waited=0
    while [ "$waited" -lt 60 ]; do
        clients=$(surfaces | grep '^  id=' | grep -cv 'owner=4294967295')
        [ "$clients" -ge 2 ] && break
        sleep 2; waited=$((waited+2))
    done
    if [ "$clients" -lt 2 ]; then
        bad "second terminal surface never appeared within 60s"; report
    fi
    say "   second surface appeared after ~${waited}s"
fi
out=$(surfaces); say "$out"
CURSOR=$(printf '%s\n' "$out" | grep 'owner=4294967295' | head -1); CURSOR=$(field "$CURSOR" id)
T1=$(printf '%s\n' "$out" | grep '^  id=' | grep -v 'owner=4294967295' | sed -n 1p); T1=$(field "$T1" id)
T2=$(printf '%s\n' "$out" | grep '^  id=' | grep -v 'owner=4294967295' | sed -n 2p); T2=$(field "$T2" id)
# Self-check the derivation: three DISTINCT ids, each of which the
# listing actually contains as a surface id. A wrong extraction must
# abort here, never masquerade as PASS and cascade.
selfcheck_ok=1
[ -n "$CURSOR" ] && [ -n "$T1" ] && [ -n "$T2" ] || selfcheck_ok=0
[ "$T1" != "$T2" ] && [ "$T1" != "$CURSOR" ] && [ "$T2" != "$CURSOR" ] || selfcheck_ok=0
for i in $CURSOR $T1 $T2; do
    printf '%s\n' "$out" | grep -q "^  id=$i " || selfcheck_ok=0
done
if [ "$selfcheck_ok" -eq 1 ]; then
    ok "derived ids: cursor=$CURSOR terms=$T1,$T2 (distinct, all present in the listing)"
else
    bad "id derivation failed self-check (cursor=$CURSOR t1=$T1 t2=$T2); aborting before the cascade"; report
fi
# The newer term has the higher id (ids are monotonic): it becomes
# RIGHT, so after placement the operator can identify it by position.
if [ "$T1" -gt "$T2" ]; then NEW=$T1; OLDT=$T2; else NEW=$T2; OLDT=$T1; fi
say "   newer term is id=$NEW (will be placed RIGHT)"

# ---- Phase 2: placement (before any prompt about "the new term",
# so the operator can identify it by position: the newer one goes
# RIGHT; two fullscreen terms overlap exactly and are otherwise
# indistinguishable on the glass, which is also why "I did not see
# the second window open" was the census disagreeing with the eye) --
run_expect "configure $OLDT to the left half"  "configure: serial=" sudo "$CTL" configure "$OLDT" 1920 2160
run_expect "configure $NEW to the right half"  "configure: serial=" sudo "$CTL" configure "$NEW" 1920 2160
run_expect "move $NEW to (1920,0)"             "ok"                 sudo "$CTL" move "$NEW" 1920 0

step "placement verified in the listing (poll: move stages, promotion lands at the client's next commit)"
tries=0; placed=0
while [ "$tries" -lt 5 ]; do
    out=$(surfaces)
    l1=$(printf '%s\n' "$out" | grep "id=$OLDT "); l2=$(printf '%s\n' "$out" | grep "id=$NEW ")
    if printf '%s' "$l1" | grep -q 'size=1920x2160 pos=0,0' && printf '%s' "$l2" | grep -q 'size=1920x2160 pos=1920,0'; then
        placed=1; break
    fi
    tries=$((tries+1)); sleep 1
done
say "$out"
if [ "$placed" -eq 1 ]; then
    ok "placement promoted within ${tries}s (acked: $(field "$l1" acked_serial)/$(field "$l2" acked_serial)); the ADR 0022 model owns the latency"
else
    bad "placement not promoted after 5s"
fi
LEFT=$OLDT; RIGHT=$NEW

step "scale environment and geometry, read from the processes (no prompts)"
# procstat penv reads the environment AS EXEC'D; runtime setenv is
# invisible to it. So the sessiond-launched root term correctly shows
# <absent> (it receives --scale 3 as an argument and exports at
# startup where procstat cannot see), and a CHILD term showing 3 in
# its exec-time environment is the proof the export chain works: the
# variable can only be there because the parent term put it in the
# shells the child was launched from. The first run of this check
# failed the architecture for behaving correctly.
inherited=0; wrong=0; geom_note=""
for pid in $(pgrep -x semadraw-term); do
    val=$(procstat penv "$pid" 2>/dev/null | tr ' ' '\n' | sed -n 's/^SEMADRAW_TERM_SCALE=//p')
    shellpid=$(pgrep -P "$pid" | head -1)
    tty=$(ps -o tty= -p "$shellpid" 2>/dev/null | tr -d ' ')
    dims=$(sudo stty -f "/dev/$tty" size 2>/dev/null)
    say "   term pid $pid: exec-env SCALE='${val:-<absent>}' shell=$shellpid tty=$tty stty='$dims'"
    case "$val" in
        3) inherited=$((inherited+1)) ;;
        "") ;; # the sessiond-launched root: absent at exec, by design
        *) wrong=$((wrong+1)) ;;
    esac
    geom_note="$geom_note $dims;"
done
if [ "$wrong" -gt 0 ]; then
    bad "a term was exec'd with a wrong SEMADRAW_TERM_SCALE (not 3)"
elif [ "$inherited" -ge 1 ]; then
    ok "$inherited term(s) exec'd with inherited scale 3: the export chain works"
else
    bad "no term carries the inherited scale in its exec environment: launch the second term from inside the session and rerun, or the patch 18 export is broken"
fi

step "geometry cross-check: each 1920x2160 half at scale 3 is 44 rows 80 cols"
case "$geom_note" in
    *"44 80;"*"44 80;"*) ok "both terms report 44 80 through their own ptys" ;;
    *"134 240"*) bad "a term reports 134 240: the scale-1 signature (geom:$geom_note)" ;;
    *) bad "unexpected geometry readings:$geom_note" ;;
esac

step "reaper jurisdiction: this session must be forked by the RUNNING sessiond"
sessiond_pid=$(pgrep -x pgsd-sessiond | head -1)
sessiond_age=$(ps -o etimes= -p "$sessiond_pid" | tr -d ' ')
oldest_term_age=0
for pid in $(pgrep -x semadraw-term); do
    a=$(ps -o etimes= -p "$pid" | tr -d ' ')
    [ "$a" -gt "$oldest_term_age" ] && oldest_term_age=$a
done
say "   sessiond pid $sessiond_pid age ${sessiond_age}s; oldest term age ${oldest_term_age}s"
if [ "$oldest_term_age" -lt "$sessiond_age" ]; then
    ok "session is younger than sessiond: forked by it, reaper has jurisdiction"
    printf 'SESSIOND_PID=%s\n' "$sessiond_pid" >> /tmp/bench-multiwindow.jurisdiction
else
    bad "session PREDATES the running sessiond: the reaper never acquired it; log out/in and rerun before trusting the greeter phase"
fi

# ---- Phase 3: focus routing (F-D7-1) ------------------------------
run_expect "focus LEFT ($LEFT)" "ok" sudo "$CTL" focus "$LEFT"
ask "keys follow focus to LEFT" "Type on the console: do keys land in the LEFT term ONLY?"
run_expect "focus RIGHT ($RIGHT)" "ok" sudo "$CTL" focus "$RIGHT"
ask "keys follow focus to RIGHT" "Type: do keys land in the RIGHT term ONLY?"
run_expect "focus back to LEFT (both directions)" "ok" sudo "$CTL" focus "$LEFT"
ask "keys follow focus back" "Type: LEFT again?"
run_expect "focus 0 clears to the fallback" "ok" sudo "$CTL" focus 0
step "fallback observation (defined-indeterminate: registry order picks the target)"
printf '   Type once: which side received? [l/r] '
read -r side
say "   operator observed fallback target: $side"
ok "fallback target recorded ($side); judged by no one, by design"
run_expect "restore a defined focus (LEFT)" "ok" sudo "$CTL" focus "$LEFT"

# ---- Phase 4: error grammar + clip --------------------------------
run_expect "focus unknown id"        "focus_unknown_surface"     sudo "$CTL" focus 9999
run_expect "focus the cursor ($CURSOR)" "focus_not_client_surface" sudo "$CTL" focus "$CURSOR"
run_expect "move unknown id"         "move_unknown_surface"      sudo "$CTL" move 9999 100 100
run_expect "move the cursor"         "move_not_client_surface"   sudo "$CTL" move "$CURSOR" 50 50
run_expect "move with a non-finite coordinate" "move_invalid_position" sudo "$CTL" move "$RIGHT" nan 0
run_expect "move RIGHT partially off-screen" "ok" sudo "$CTL" move "$RIGHT" 3500 1500
ask "clip on the glass" "Is RIGHT clipped cleanly at the panel edges (no wrap, no crash)?"
step "capture the clip evidence"
sudo "$CTL" capture /tmp/verify-clip.ppm >>"$LOG" 2>&1 && ok "wrote /tmp/verify-clip.ppm" || bad "capture failed"
run_expect "restore RIGHT to (1920,0)" "ok" sudo "$CTL" move "$RIGHT" 1920 0

# ---- Phase 5: F-SESSION-1 setup -----------------------------------
step "spawn the orphan pair"
sleep 1000 & ORPHAN1=$!
sh -c '(sleep 2000 & echo $! > /tmp/bench-orphan2.pid) &'
sleep 1
ORPHAN2=$(cat /tmp/bench-orphan2.pid 2>/dev/null); rm -f /tmp/bench-orphan2.pid
if [ -n "$ORPHAN2" ]; then
    ok "orphans: plain=$ORPHAN1 double-forked=$ORPHAN2"
    sess_pid=$(sed -n 's/^SESSIOND_PID=//p' /tmp/bench-multiwindow.jurisdiction 2>/dev/null | tail -1)
    rm -f /tmp/bench-multiwindow.jurisdiction
    printf 'ORPHAN1=%s\nORPHAN2=%s\nSESSIOND_PID=%s\n' "$ORPHAN1" "$ORPHAN2" "$sess_pid" > "$STATE"
else
    bad "double-fork orphan pid not captured"
fi

say ""
say ">>> RUN phase complete: $PASS passed, $FAIL failed so far."
say ">>> Now LOG OUT of the session, and from the out-of-band shell run:"
say ">>>     sh /usr/local/src/awase/tools/bench-multiwindow.sh greeter"
report
