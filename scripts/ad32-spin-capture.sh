#!/bin/sh
#
# ad32-spin-capture.sh -- name the fd driving the semadrawd busy-spin.
#
# Run this WHILE the spin is live (seq advancing by hundreds of
# thousands per second, log rotating every second or two). It
# measures the event rate from the stream, samples three userspace
# stacks, and ktraces two seconds of syscalls, then histograms the
# syscall mix and poll return values. A loop that spins because one
# pollfd is permanently readable (the AD-37 hypothesis) shows poll
# returning nonzero instantly on every call, and the fd named in the
# read/ioctl calls that follow each wakeup is the culprit.
#
# Usage: sudo sh scripts/ad32-spin-capture.sh

set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
PID=$(pgrep -x semadrawd) || { echo "semadrawd not running" >&2; exit 1; }
LOG=/var/log/utf/semadrawd/current
OUT="/tmp/ad32-spin-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "semadrawd pid $PID; output dir $OUT"

echo ""
echo "== 1. event rate from the stream (2 s sample)"
s1=$(tail -1 "$LOG" 2>/dev/null | sed -n 's/.*"seq":\([0-9]*\).*/\1/p')
sleep 2
s2=$(tail -1 "$LOG" 2>/dev/null | sed -n 's/.*"seq":\([0-9]*\).*/\1/p')
if [ -n "$s1" ] && [ -n "$s2" ]; then
	echo "  seq $s1 -> $s2  (~$(( (s2 - s1) / 2 )) events/s)"
else
	echo "  could not read seq (rotation race); rate from ktrace below"
fi

echo ""
echo "== 2. three userspace stacks"
i=0
while [ $i -lt 3 ]; do
	lldb -p "$PID" -o "thread backtrace" -o detach -o quit \
		> "$OUT/stack-$i.txt" 2>&1
	printf "  stack-%s innermost: " "$i"
	grep -m1 "frame #0" "$OUT/stack-$i.txt" | sed 's/.*frame #0: //'
	i=$((i + 1))
done

echo ""
echo "== 3. two seconds of syscalls"
ktrace -p "$PID" -t c -f "$OUT/ktrace.out"
sleep 2
ktrace -C
kdump -f "$OUT/ktrace.out" > "$OUT/kdump.txt" 2>&1

echo "  syscall histogram:"
awk '/ CALL  /{ sub(/\(.*/,"",$4); h[$4]++ } END { for (k in h) printf "    %-12s %d\n", k, h[k] }' "$OUT/kdump.txt" | sort -k2 -rn | head -10

echo "  poll return values (0 = timeout, >0 = fds ready):"
awk '/ RET   poll/{ h[$5]++ } END { for (k in h) printf "    ret %-4s %d\n", k, h[k] }' "$OUT/kdump.txt" | sort -k3 -rn | head -5

echo "  fds touched by read/ioctl after wakeups:"
awk '/ CALL  (read|ioctl)\(/{ split($4,a,"("); split(a[2],b,","); h[a[1]" fd "b[1]]++ } END { for (k in h) printf "    %-22s %d\n", k, h[k] }' "$OUT/kdump.txt" | sort -k3 -rn | head -8

echo ""
echo "Full captures in $OUT  (tar -cf results.tar -C $OUT .)"
