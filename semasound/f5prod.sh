#!/bin/sh
#
# f5prod.sh -- run an F.5 suite against the PRODUCTION supervised broker
# (ADR 0030 Decision 5: the suites' production mode).
#
# Bench mode (the default when running a suite directly) tests the
# freshly built tree broker started by bench_setup.sh. This wrapper
# instead points a suite at the s6-supervised installed broker: the
# binary the system actually runs, logging to s6-log.
#
# Usage:  sudo sh f5prod.sh f5b_election.sh
#         sudo sh f5prod.sh f5c_targets.sh   (etc.)
#
# What it does:
#   1. verifies s6-supervise is running on the semasound service
#   2. verifies the installed broker is not stale relative to
#      /usr/local/bin/semasound (remedy: service semasound restart)
#   3. points the suite at /var/log/utf/semasound/current and
#      /usr/local/bin/semasound via SEMASOUND_LOG / SEMASOUND_BIN
#   4. guards against s6-log rotation mid-run (line-count deltas
#      inside the suites assume a stable file)
#
# The suites' own client side (semasound-tone from ./zig-out/bin) is
# unchanged: the broker under test is what differs, not the client.

set -u
SVC=/var/service/utf/semasound
PLOG=/var/log/utf/semasound/current
PBIN=/usr/local/bin/semasound

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: sudo sh f5prod.sh <suite.sh>" >&2; exit 1; }

command -v s6-svok >/dev/null 2>&1 || PATH="$PATH:/usr/local/bin"
s6-svok "$SVC" 2>/dev/null || {
	echo "ABORT: semasound is not under supervision ($SVC)." >&2
	echo "       Production mode tests the supervised broker; start it:" >&2
	echo "       sudo service utf-supervisor start && sudo s6-svc -u $SVC" >&2
	exit 1
}
[ -x "$PBIN" ] || { echo "ABORT: $PBIN missing (sudo sh install.sh)" >&2; exit 1; }
[ -r "$PLOG" ] || { echo "ABORT: $PLOG missing or unreadable" >&2; exit 1; }

BPID=$(pgrep -x semasound) || { echo "ABORT: broker not running" >&2; exit 1; }
bin_age=$(( $(date +%s) - $(stat -f %m "$PBIN") ))
broker_up=$(ps -o etimes= -p "$BPID" | tr -d ' ')
if [ "$broker_up" -gt "$bin_age" ]; then
	echo "ABORT: supervised broker (up ${broker_up}s) predates the installed" >&2
	echo "       binary (built ${bin_age}s ago). Refresh it:" >&2
	echo "       sudo service semasound restart" >&2
	exit 1
fi

# The startup "election:" line may have rotated out of current on a
# long-running broker; accept it from the newest archive too.
if ! grep -q "election:" "$PLOG" 2>/dev/null; then
	newest_archive=$(ls -t /var/log/utf/semasound/@* 2>/dev/null | head -1)
	if [ -z "$newest_archive" ] || ! grep -q "election:" "$newest_archive"; then
		echo "ABORT: no 'election:' startup line in $PLOG (or archives)." >&2
		echo "       Restart the broker to get a fresh log epoch:" >&2
		echo "       sudo service semasound restart" >&2
		exit 1
	fi
	echo "NOTE: startup line found only in the rotated archive; restarting"
	echo "      the broker first is recommended for a clean log epoch:"
	echo "      sudo service semasound restart"
fi

inode_before=$(stat -f %i "$PLOG")

echo "=== production mode: $1 against the supervised broker (pid $BPID) ==="
SEMASOUND_LOG="$PLOG" SEMASOUND_BIN="$PBIN" sh "$1"
rc=$?

inode_after=$(stat -f %i "$PLOG" 2>/dev/null || echo 0)
if [ "$inode_before" != "$inode_after" ]; then
	echo "WARNING: s6-log rotated $PLOG during the run; line-count deltas" >&2
	echo "         inside the suite are unreliable for this run. Rerun" >&2
	echo "         (rotation twice in a row is unlikely at suite volume)." >&2
	[ $rc -eq 0 ] && rc=2
fi
exit $rc
