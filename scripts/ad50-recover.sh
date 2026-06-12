#!/bin/sh
#
# ad50-recover.sh -- restore the semasound slot, revive the real
# semadrawd slot, and verify every step by process identity.
#
# Background (AD-50): /var/service/utf/semasound/run was found to
# be semadrawd's run script. Its semadrawd won the socket at
# 13:31:10; the real semadrawd slot's respawns exited 1 against
# the bind conflict and flap protection gave up, correctly. This
# script repairs the file from the repo, terminates the usurper,
# brings the real slot up into the freed socket, and verifies
# each slot's process identity afterward, the lesson this incident
# taught. The desktop collapses once at the -t step; run from ssh
# and relog after.
#
# Usage: sudo sh scripts/ad50-recover.sh

set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SND=/var/service/utf/semasound
DRW=/var/service/utf/semadrawd
FAILS=0

slot_child() {
	# the binary name of the process directly under a slot's supervisor
	sup=$(pgrep -fx "s6-supervise $1" | head -1)
	[ -n "$sup" ] && pgrep -P "$sup" -l | awk '{print $2}' | head -1
}

echo "== AD-50 recovery, $(date)"
echo ""

echo "== Evidence: the corrupt file, for the record"
ls -l "$SND/run" | sed 's/^/   /'
TARGET=$(grep "^exec /usr/local/bin/" "$SND/run" | head -1)
echo "   exec target: ${TARGET:-none found}"
case "$TARGET" in
*semasound*)
	echo "   slot run already execs semasound; repair not needed, continuing to slot checks"
	;;
*)
	echo "== Repair: deploying $REPO/s6/utf/semasound/run"
	# AD-50 hardening: verify the SOURCE before writing it. The repo
	# copy was itself corrupt once this evening; deploying it
	# unchecked just refreshed the corruption.
	if ! grep -q "^exec /usr/local/bin/semasound" "$REPO/s6/utf/semasound/run"; then
		echo "   ERROR: repo source does not exec semasound either; fix the repo first" >&2
		echo "   (git checkout -- s6/utf/semasound/run). Aborting without writing." >&2
		exit 1
	fi
	cp "$REPO/s6/utf/semasound/run" "$SND/run" && chmod 755 "$SND/run"
	grep -q "^exec /usr/local/bin/semasound" "$SND/run" || { echo "   FAIL: repaired file does not exec semasound; aborting"; exit 1; }
	echo "   repaired and verified"
	;;
esac

echo ""
echo "== Terminate the usurper (-t semasound; desktop collapses here)"
s6-svc -t "$SND"
sleep 4
CHILD=$(slot_child semasound || true)
echo "   semasound slot now runs: ${CHILD:-nothing}"
[ "$CHILD" = "semasound" ] || { echo "   FAIL: slot identity wrong after respawn"; FAILS=$((FAILS + 1)); }

echo ""
echo "== Revive the real semadrawd slot (-u; giveup cleared)"
s6-svc -u "$DRW"
sleep 4
STAT=$(s6-svstat "$DRW")
echo "   $STAT"
case "$STAT" in
up*) : ;;
*)
	echo "   slot not up yet; waiting 6 more seconds (bind retry window)"
	sleep 6
	STAT=$(s6-svstat "$DRW")
	echo "   $STAT"
	case "$STAT" in up*) : ;; *) echo "   FAIL: semadrawd slot did not come up; paste this output"; FAILS=$((FAILS + 1));; esac
	;;
esac
CHILD=$(slot_child semadrawd || true)
echo "   semadrawd slot now runs: ${CHILD:-nothing}"
[ "$CHILD" = "semadrawd" ] || FAILS=$((FAILS + 1))

echo ""
echo "== Final state, gated, not just printed"
INSTANCES=$(pgrep -x semadrawd | wc -l | tr -d ' ')
echo "   semadrawd instances: $INSTANCES (must be 1)"
[ "$INSTANCES" = "1" ] || FAILS=$((FAILS + 1))
s6-svstat "$SND" "$DRW" | sed 's/^/   /'

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "== RECOVERY COMPLETE: one compositor under its own supervisor, real"
	echo "   semasound back after an afternoon of silence. Relog at the"
	echo "   machine; semasound-tone 2 440 confirms audio. Paste this output"
	echo "   with the mtime line above to close AD-50."
else
	echo "== ${FAILS} check(s) failed; paste this output before touching anything."
fi
