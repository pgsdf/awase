#!/bin/sh
#
# ad43-freeze-stack.sh -- capture semadrawd's stack DURING the freeze.
#
# Three reproductions of the AD-43.3a/AD-46 freeze (2026-05-27 and
# both 2026-06-05 benches) were observed only by their absence: zero
# log emission across a 10-second mouse-motion window, with a healthy
# poll-parked stack found AFTERWARDS. This script samples the stack
# DURING the window, every 2 seconds, plus one procstat -kk kernel
# stack, so the blocking call is caught in the act and named.
#
# Usage: sudo sh scripts/ad43-freeze-stack.sh
# Move the mouse continuously when prompted.

set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
PID=$(pgrep -x semadrawd) || { echo "semadrawd not running" >&2; exit 1; }
LOG=/var/log/utf/semadrawd/current
OUT="/tmp/ad43-freeze-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

pre_lines=$(wc -l < "$LOG")
echo "semadrawd pid $PID; pre log lines: $pre_lines"
echo "Output dir: $OUT"
echo ""
echo "MOVE THE MOUSE continuously for the next 12 seconds."
sleep 2

i=0
while [ $i -lt 6 ]; do
	lldb -p "$PID" -o "thread backtrace" -o detach -o quit \
		> "$OUT/stack-$i.txt" 2>&1
	if [ $i -eq 2 ]; then
		procstat -kk "$PID" > "$OUT/procstat-kk.txt" 2>&1
	fi
	i=$((i + 1))
	sleep 1
done

post_lines=$(wc -l < "$LOG")
echo ""
echo "post log lines: $post_lines (delta $((post_lines - pre_lines)))"
echo ""
echo "Userspace frames seen across the 6 samples:"
grep -h "frame #[0-9]*: 0x" "$OUT"/stack-*.txt \
	| grep "semadrawd\`" \
	| sed 's/.*semadrawd`/  /' | sort | uniq -c | sort -rn | head -15
echo ""
echo "Innermost frame per sample:"
for f in "$OUT"/stack-*.txt; do
	printf "  %s  " "$(basename "$f")"
	grep -m1 "frame #0" "$f" | sed 's/.*frame #0: //'
done
echo ""
if [ "$post_lines" -eq "$pre_lines" ]; then
	echo "FREEZE REPRODUCED (zero log lines during window)."
	echo "The stacks above name the blocking call."
else
	echo "No freeze this run (log advanced); stacks show normal operation."
fi
echo "Full captures in $OUT"
