#!/bin/sh
#
# f5b_reject.sh -- F.5.b criterion 7: unsupported-format rejection. TEST ONLY.
#
# Each unsupported Hello (non-16-bit format code standing in for 24-bit and
# float, >2 channels, unsupported rate) must be REJECTED with a clear status,
# and the broker must SURVIVE: after all rejection attempts, a good client
# plays clean. The tone client exits 2 on rejection, 0 on a clean run.
#
# Prereq: broker running (bench_setup.sh). Usage: sudo sh f5b_reject.sh

set -u
TONE="./zig-out/bin/semasound-tone"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -x "$TONE" ] || { echo "missing $TONE (zig build)" >&2; exit 1; }
pgrep -x semasound >/dev/null || { echo "semasound not running (bench_setup.sh first)" >&2; exit 1; }

fails=0

expect_reject() {
	name="$1"; shift
	"$TONE" 1 440 150 "$@" >/dev/null 2>&1
	rc=$?
	if [ "$rc" -eq 2 ]; then
		printf "  %-28s REJECTED (exit 2)  ok\n" "$name"
	else
		printf "  %-28s exit %s  FAIL (expected rejection)\n" "$name" "$rc"
		fails=$((fails + 1))
	fi
}

echo "F.5.b criterion 7: unsupported-format rejection"
expect_reject "format 2 (24-bit)"      --format 2
expect_reject "format 3 (float)"       --format 3
expect_reject "channels 4 (>2)"        --channels 4
expect_reject "channels 0"             --channels 0
expect_reject "rate 96000"             --rate 96000
expect_reject "badrate (96000)"        --badrate

# Broker survival: a good client must still play clean after the abuse.
echo "  broker survival: good client after rejections..."
if pgrep -x semasound >/dev/null && "$TONE" 2 440 150 >/dev/null 2>&1; then
	echo "  good client played clean      ok"
else
	echo "  good client FAILED (broker dead or rejecting good Hellos)"
	fails=$((fails + 1))
fi

echo ""
if [ "$fails" -eq 0 ]; then
	echo "criterion 7: ALL CASES PASS (rejected cleanly, broker survived)"
else
	echo "criterion 7: $fails FAILURE(S)"
fi
