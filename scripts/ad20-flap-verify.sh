#!/bin/sh
#
# ad20-flap-verify.sh -- flap protection's first operational test.
#
# Background: AD-20's finish scripts resolved the service dir via
# "${3:-$(pwd)}"; $3 is never set and pwd is the scan dir, so the
# early-boot guard fired on every death, flap accounting was
# skipped every time, and the machinery never ran once between
# AD-20 shipping and the 2026-06-07 fix (SVCDIR from dirname "$0").
# This script verifies the fixed machinery end to end against
# semasound, the harmless self-recovering service (AD-47's device
# layer restores audio after every bounce).
#
# Three legs, ~75 s total (mostly one deliberate 50 s wait):
#   1. one bounce: lifetime is the true seconds since start, and
#      the "supervise/ missing" guard stays silent;
#   2. two bounces 3 s apart: the fast-crash counter climbs 1/5
#      then 2/5 and the crash log holds two epochs. THE SCRIPT
#      STOPS AT TWO: three more fast crashes would trip the
#      giveup and down the service until a manual s6-svc -u;
#   3. a 50 s wait then one bounce: the long-lived death resets
#      the crash log to empty.
#
# Usage: sudo sh scripts/ad20-flap-verify.sh

set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

SVC=/var/service/utf/semasound
LOG=/var/log/utf/semasound/current
MARKER="$SVC/supervise/awase_run_started"
CLOG="$SVC/supervise/awase_crash_log"
FAILS=0

# Precheck: the fixed finish must be deployed.
if ! grep -qF 'SVCDIR="$(cd "$(dirname "$0")" && pwd)"' "$SVC/finish"; then
	echo "PRECHECK FAILED: $SVC/finish is not the fixed version."
	echo "Deploy first:"
	echo '  for s in semasound semadrawd pgsd-sessiond; do'
	echo '    sudo cp s6/utf/$s/finish /var/service/utf/$s/finish'
	echo '  done'
	exit 1
fi

# AD-50 hardening: verify the slot actually runs semasound before
# bouncing it. This bench restarts the semasound slot repeatedly;
# if that slot held a different daemon (the AD-50 failure: a
# compositor in the semasound slot), these bounces would TERM the
# wrong process. A slot-identity check makes that impossible.
slot_child() {
	sup=$(pgrep -fx "s6-supervise semasound" | head -1)
	[ -n "$sup" ] && pgrep -P "$sup" -l | awk '{print $2}' | head -1
}
SLOT_RUNS=$(slot_child || true)
if [ "$SLOT_RUNS" != "semasound" ]; then
	echo "PRECHECK FAILED: semasound slot runs '${SLOT_RUNS:-nothing}', not semasound."
	echo "Refusing to bounce a mis-slotted service (see AD-50). Recover first."
	exit 1
fi

count() { n=$(grep -c "$1" "$LOG" 2>/dev/null); echo "${n:-0}"; }
last_lifetime() { grep "finish:" "$LOG" | tail -1 | sed -n 's/.*lifetime=\([0-9]*\)s.*/\1/p'; }

echo "== AD-20 flap verification, $(date)"
echo ""

echo "== Leg 1: true lifetime, guard silent"
MISS_0=$(count "supervise/ missing")
started=$(cat "$MARKER" 2>/dev/null || echo 0)
expected=$(( $(date +%s) - started ))
s6-svc -r "$SVC"
sleep 2
got=$(last_lifetime)
MISS_1=$(count "supervise/ missing")
delta=$(( got - expected )); [ "$delta" -lt 0 ] && delta=$(( -delta ))
if [ -n "$got" ] && [ "$delta" -le 3 ] && [ "$MISS_1" -eq "$MISS_0" ]; then
	echo "   PASS: lifetime=${got}s (expected ~${expected}s), no guard line"
else
	echo "   FAIL: lifetime=${got:-none}s (expected ~${expected}s), guard lines ${MISS_0} -> ${MISS_1}"
	FAILS=$((FAILS + 1))
fi

echo ""
echo "== Leg 2: fast-crash counter climbs to 2/5, then STOPS"
FC_0=$(count "fast crash")
s6-svc -r "$SVC"; sleep 3
s6-svc -r "$SVC"; sleep 2
FC_1=$(count "fast crash")
EPOCHS=$(wc -l < "$CLOG" 2>/dev/null | tr -d ' ' || echo 0)
GAVE_UP=$(count "giving up")
grep "fast crash" "$LOG" | tail -2 | sed 's/^/   /'
if [ "$FC_1" -ge $((FC_0 + 2)) ] && [ "$EPOCHS" -ge 2 ] && [ "$GAVE_UP" -eq 0 ]; then
	echo "   PASS: counter climbed (+$((FC_1 - FC_0))), crash log holds ${EPOCHS} epochs, no giveup"
else
	echo "   FAIL: fast-crash lines ${FC_0} -> ${FC_1}, epochs ${EPOCHS}, giveup lines ${GAVE_UP}"
	FAILS=$((FAILS + 1))
fi

echo ""
echo "== Leg 3: long-lived death resets the crash log (50 s wait)"
sleep 50
s6-svc -r "$SVC"
sleep 2
SIZE=$(wc -c < "$CLOG" 2>/dev/null | tr -d ' ' || echo missing)
got=$(last_lifetime)
if [ "$SIZE" = "0" ]; then
	echo "   PASS: crash log truncated to empty (last lifetime ${got}s)"
else
	echo "   FAIL: crash log size ${SIZE} (expected 0); last lifetime ${got:-none}s"
	FAILS=$((FAILS + 1))
fi

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "== ALL THREE LEGS PASS: flap protection is operational for the"
	echo "   first time since AD-20 shipped. The 45 s prune branch remains"
	echo "   verified by inspection (same arithmetic shape as the reset)."
else
	echo "== ${FAILS} LEG(S) FAILED; paste this output."
fi
echo "   Audio self-recovers from every bounce (AD-47); confirm by ear if desired."
