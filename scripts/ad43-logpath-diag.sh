#!/bin/sh
#
# ad43-logpath-diag.sh -- find where structured events die.
#
# Established so far (2026-06-05): the loop is alive and fast (5/6
# in-window samples parked in poll under motion); the new clip
# binary is running (stack line numbers match); std.log info lines
# reach current through the same pipe object; yet ZERO structured
# events (including ungated client_connected) landed this boot.
# The discriminating question is whether semadrawd is issuing
# writev on fd 1 at all. ktrace answers it directly; the fd table
# and the log directory state bound the remaining hypotheses.
#
# Usage: sudo sh scripts/ad43-logpath-diag.sh

set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
PID=$(pgrep -x semadrawd) || { echo "semadrawd not running" >&2; exit 1; }
LOGDIR=/var/log/utf/semadrawd
OUT="/tmp/ad43-logpath-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "semadrawd pid $PID; output dir $OUT"
echo ""

echo "== 1. fd table (where stdout/stderr actually point)"
procstat -f "$PID" > "$OUT/procstat-f.txt" 2>&1
awk '$3 ~ /^[012]$/ || NR <= 2' "$OUT/procstat-f.txt"
echo ""

echo "== 2. log directory state (rotation history, sizes, times)"
ls -laT "$LOGDIR" | tee "$OUT/logdir.txt"
df -h "$LOGDIR" | tee -a "$OUT/logdir.txt"
echo ""

echo "== 3. s6-log process state"
ps -axo pid,ppid,stat,etime,command | grep -E "s6-log|s6-supervise" | grep -v grep | tee "$OUT/s6-procs.txt"
echo ""

echo "== 4. structured-event census, current + archives"
for f in "$LOGDIR"/current "$LOGDIR"/@*.s; do
	[ -f "$f" ] || continue
	total=$(wc -l < "$f")
	structured=$(grep -c '"type":' "$f" 2>/dev/null || echo 0)
	last_seq=$(grep '"seq":' "$f" | tail -1 | sed 's/.*"seq":\([0-9]*\).*/\1/')
	printf "  %-50s lines %-8s structured %-8s last-seq %s\n" \
		"$(basename "$f")" "$total" "$structured" "${last_seq:-none}"
done | tee "$OUT/census.txt"
echo ""

echo "== 5. THE PROBE: 5 seconds of ktrace on write/writev"
echo "   (move the mouse during these 5 seconds)"
# trpoints: c = syscalls. (The first version passed -t w, which
# traces context switches; section 5 of both 2026-06-05 runs was
# therefore vacuous. The June 5 conclusion stood on the seq census,
# which was independently valid.)
ktrace -p "$PID" -t c -f "$OUT/ktrace.out"
sleep 5
ktrace -C
kdump -f "$OUT/ktrace.out" > "$OUT/kdump.txt" 2>&1
wv_fd1=$(grep -cE "CALL  (pwritev|writev|write)\(0x1," "$OUT/kdump.txt" || true)
wv_fd2=$(grep -cE "CALL  (pwritev|writev|write)\(0x2," "$OUT/kdump.txt" || true)
wv_err=$(grep -A1 -E "CALL  (pwritev|writev|write)\(0x[12]," "$OUT/kdump.txt" | grep -cE "RET.*-1" || true)
echo "  write/writev on fd 1 (structured events): $wv_fd1"
echo "  write/writev on fd 2 (std.log):           $wv_fd2"
echo "  failed returns on fd 1/2:                 $wv_err"
grep -E "RET.*(pwritev|writev|write).*-1" "$OUT/kdump.txt" | head -3
echo ""

echo "== 6. current growth during the probe window"
pre=$(wc -l < "$LOGDIR/current")
sleep 2
post=$(wc -l < "$LOGDIR/current")
echo "  current: $pre -> $post (delta $((post - pre)))"
echo ""

echo "== Verdict guide"
echo "  fd1 writes 0, fd2 writes >0   -> emitters not being called:"
echo "     instrument flags or call sites; inspect daemon env via"
echo "     procstat -e $PID"
echo "  fd1 writes >0, failed 0, no   -> s6-log consuming but not"
echo "  growth in current                writing where we look"
echo "  fd1 writes >0, failed >0      -> the write error names the"
echo "                                   failure; see kdump.txt"
procstat -e "$PID" > "$OUT/procstat-e.txt" 2>&1
echo ""
echo "Full captures in $OUT  (tar -cf results.tar -C $OUT .)"
