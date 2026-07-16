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
# Usage:
#   sh tools/bench-multiwindow.sh run       # in the session, two terms up
#   sh tools/bench-multiwindow.sh greeter   # from the out-of-band shell,
#                                           # at the login screen, after run
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
field() { printf '%s' "$1" | sed -n "s/.*$2=\([^ ,]*\).*/\1/p"; }

report() {
    say ""
    say "==== $PASS passed, $FAIL failed; log: $LOG ===="
    exit "$FAIL"
}

greeter_phase() {
    say "bench-multiwindow GREETER phase; log: $LOG"
    [ -f "$STATE" ] || { say "no state file from the run phase ($STATE); aborting"; exit 1; }
    . "$STATE"   # provides ORPHAN1 ORPHAN2

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

# ---- Phase 0: deploy sanity + suite -------------------------------
step "deploy sanity: repository HEAD"
head=$(cd /usr/local/src/awase && git log --format=%s -1)
say "   HEAD: $head"
ok "HEAD recorded (operator confirms it is the intended deploy)"

step "full unit suite on the bench"
if (cd /usr/local/src/awase/semadraw && ../tools/zig build test >>"$LOG" 2>&1); then
    ok "zig build test green (first bench run of the five new suites counts here)"
else
    bad "zig build test failed; see $LOG"
fi

# ---- Phase 1: surfaces + scale inheritance ------------------------
step "surface census (expect cursor + two terms; second launched as bare 'semadraw-term &')"
out=$(surfaces); say "$out"
CURSOR=$(printf '%s\n' "$out" | grep 'owner=4294967295' | head -1); CURSOR=$(field "$CURSOR" id)
T1=$(printf '%s\n' "$out" | grep '^  id=' | grep -v 'owner=4294967295' | sed -n 1p); T1=$(field "$T1" id)
T2=$(printf '%s\n' "$out" | grep '^  id=' | grep -v 'owner=4294967295' | sed -n 2p); T2=$(field "$T2" id)
if [ -n "$CURSOR" ] && [ -n "$T1" ] && [ -n "$T2" ]; then
    ok "derived ids: cursor=$CURSOR terms=$T1,$T2 (nothing hardcoded)"
else
    bad "need cursor + two client surfaces; launch the second term first"; report
fi

step "scale inheritance (patch 18)"
printf '   In the NEW term, run: stty size   -- enter its output here: '
read -r stty_out
say "   operator entered: $stty_out"
if [ "$stty_out" = "44 160" ]; then
    ok "44 160: scale 3 inherited with no flag"
else
    bad "expected '44 160' (scale-1 fallback would read '134 480'); got '$stty_out'"
fi

# ---- Phase 2: placement -------------------------------------------
run_expect "configure $T1 to the left half"  "configure: serial=" sudo "$CTL" configure "$T1" 1920 2160
run_expect "configure $T2 to the right half" "configure: serial=" sudo "$CTL" configure "$T2" 1920 2160
run_expect "move $T2 to (1920,0)"            "ok"                 sudo "$CTL" move "$T2" 1920 0

step "placement verified in the listing"
out=$(surfaces); say "$out"
l1=$(printf '%s\n' "$out" | grep "id=$T1 "); l2=$(printf '%s\n' "$out" | grep "id=$T2 ")
if printf '%s' "$l1" | grep -q 'size=1920x2160 pos=0,0' && printf '%s' "$l2" | grep -q 'size=1920x2160 pos=1920,0'; then
    ok "T1 at 0,0 and T2 at 1920,0, both 1920x2160 (acked: $(field "$l1" acked_serial)/$(field "$l2" acked_serial))"
else
    bad "listing does not show the expected placement"
fi
LEFT=$T1; RIGHT=$T2

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
    printf 'ORPHAN1=%s\nORPHAN2=%s\n' "$ORPHAN1" "$ORPHAN2" > "$STATE"
else
    bad "double-fork orphan pid not captured"
fi

say ""
say ">>> RUN phase complete: $PASS passed, $FAIL failed so far."
say ">>> Now LOG OUT of the session, and from the out-of-band shell run:"
say ">>>     sh /usr/local/src/awase/tools/bench-multiwindow.sh greeter"
report
