#!/bin/sh
#
# F.3.b bench verification: tests 5 (back-pressure), 6a (double-open EBUSY),
# 6b (SIGKILL cleanup).
#
# Lives at audiofs/bench-f3b.sh alongside build.sh.
#
# Run as root (or with sudo). Auto-cds to its own directory, so it
# works from any cwd:
#   sudo ./audiofs/bench-f3b.sh            # from UTF/
#   cd audiofs && sudo ./bench-f3b.sh      # from audiofs/
#
# Assumes:
#   - audiofs module is BUILT but may or may not be loaded.
#   - playtone is built at tools/playtone/playtone.
#
# The script saves a transcript to audiofs/bench-f3b.log including all
# dmesg captures, command outputs, and pass/fail judgments. Each
# test runs in isolation: dmesg buffer cleared, writer_seq snapshot
# taken before and after.
#
# Safety: the trap handler ensures test_tone is reset to 0 on any
# exit path (success, failure, signal), so the iMac speaker cannot
# be left singing if a test misbehaves.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGFILE="${SCRIPT_DIR}/bench-f3b.log"
PLAYTONE="${SCRIPT_DIR}/tools/playtone/playtone"
EVENTS="/var/run/sema/audio/events"

# Run from the script's own directory so `./build.sh` resolves
# correctly. The script lives at audiofs/bench-f3b.sh alongside
# build.sh, which is what we cd to.
cd "$SCRIPT_DIR" || {
	echo "ERROR: cannot cd to $SCRIPT_DIR" >&2
	exit 2
}

PASS=0
FAIL=0
WARN=0

# -------- output helpers --------

# Two streams: stdout (terminal) and the log file. Everything goes
# to the log; what's worth seeing on the terminal gets printed too.

tee_log() {
	# Append to log AND echo to stdout.
	tee -a "$LOGFILE"
}

log() {
	# Quiet log (no terminal echo, just file).
	printf '%s\n' "$*" >> "$LOGFILE"
}

say() {
	# Echo to terminal AND log.
	printf '%s\n' "$*" | tee_log
}

banner() {
	say ""
	say "============================================================"
	say "  $*"
	say "============================================================"
}

pass() {
	say "  PASS: $*"
	PASS=$((PASS + 1))
}

fail() {
	say "  FAIL: $*"
	FAIL=$((FAIL + 1))
}

warn() {
	say "  WARN: $*"
	WARN=$((WARN + 1))
}

# -------- safety --------

cleanup() {
	# Run on EVERY exit path. Idempotent.
	say ""
	say "[cleanup] resetting hw.audiofs.test_tone=0 (safety)"
	sysctl hw.audiofs.test_tone=0 >/dev/null 2>&1 || true
	# Kill any background processes we might have spawned and lost
	# track of. Their PIDs are recorded in $TRACKED_PIDS.
	if [ -n "${TRACKED_PIDS:-}" ]; then
		for pid in $TRACKED_PIDS; do
			kill -KILL "$pid" 2>/dev/null || true
		done
	fi
	say "[cleanup] done"
}

trap cleanup EXIT INT TERM HUP

TRACKED_PIDS=""

track() {
	TRACKED_PIDS="$TRACKED_PIDS $1"
}

untrack() {
	# Remove $1 from $TRACKED_PIDS.
	new=""
	for pid in $TRACKED_PIDS; do
		[ "$pid" = "$1" ] || new="$new $pid"
	done
	TRACKED_PIDS="$new"
}

# -------- writer_seq reader --------
#
# Read the F.2 events ring's writer_seq field (8-byte little-endian
# uint64 at offset EV_OFF_WRITER_SEQ=16 of /var/run/sema/audio/events).
# Returns the value on stdout as decimal. For F.3.b bench session
# values, only the low 32 bits matter (we never approach 2^32 events).
#
# Portable: uses dd + od, no gawk-specific functions.

read_writer_seq() {
	if [ ! -e "$EVENTS" ]; then
		echo 0
		return
	fi
	# Eight bytes at offset 16, decoded as little-endian uint32 (low 4 bytes)
	set -- $(dd if="$EVENTS" bs=1 count=4 skip=16 2>/dev/null | \
		od -An -t u1)
	# $1 $2 $3 $4 are the four bytes; combine little-endian
	echo $(( $1 + ($2 << 8) + ($3 << 16) + ($4 << 24) ))
}



if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: must run as root (or via sudo)" >&2
	exit 2
fi

if [ ! -x "$PLAYTONE" ]; then
	echo "ERROR: playtone not found or not executable: $PLAYTONE" >&2
	echo "Build it: cd tools/playtone && make" >&2
	exit 2
fi

# Fresh log file for this run.
: > "$LOGFILE"

say "F.3.b bench-verification run at $(date)"
say "Tree: $(cd "$SCRIPT_DIR/.." && git log --oneline -1 2>/dev/null || echo unknown)"
say "Log: $LOGFILE"

# -------- ensure clean module state --------

say ""
say "[preflight] ensuring audiofs is loaded fresh"
kldunload audiofs 2>/dev/null || true   # unload if loaded
dmesg -c >/dev/null
if ! ./build.sh load >> "$LOGFILE" 2>&1; then
	fail "preflight: ./build.sh load failed; see $LOGFILE"
	exit 1
fi
sleep 0.5   # let attach finish

# Capture baseline dmesg
say ""
say "[preflight] baseline dmesg after load:"
dmesg | tee_log

# Baseline writer_seq snapshot
seq_after_load=$(read_writer_seq)
say ""
say "[preflight] writer_seq after fresh load: $seq_after_load"

# -------- test 5: back-pressure --------

banner "Test 5: Back-pressure (slow writer through full ring)"

say ""
say "Goal: playtone writes 3 sec of audio (576000 bytes) in 4KB chunks."
say "Ring is 32KB, so write(2) will block ~6 times/sec. If back-pressure"
say "works, playtone takes ~3 sec wall clock. If broken, deadlock or instant."

# Snapshot writer_seq before
seq_before=$(read_writer_seq)
say "writer_seq before test: $seq_before"

dmesg -c >/dev/null
say ""
say "Running: ./tools/playtone/playtone /dev/audiofs0 3"
say "(listen for ~3 seconds of quiet sine)"

# Capture timing
t_start=$(date +%s.%N)
"$PLAYTONE" /dev/audiofs0 3 > /tmp/playtone-test5.out 2>&1
playtone_rc=$?
t_end=$(date +%s.%N)
elapsed=$(echo "$t_end $t_start" | awk '{printf "%.3f", $1 - $2}')

say ""
say "playtone exit code: $playtone_rc"
say "playtone output: $(cat /tmp/playtone-test5.out)"
say "elapsed wall clock: ${elapsed} sec"

# Test 5 checks
if [ "$playtone_rc" -eq 0 ]; then
	pass "playtone exit code 0"
else
	fail "playtone exit code $playtone_rc (expected 0)"
fi

# Wall clock should be 2.5-4 seconds (real-time playback, plus a bit for
# close drain timing). If <0.5, back-pressure is broken (writes returning
# instantly). If >5, something is sluggish.
elapsed_int=$(echo "$elapsed" | awk -F. '{print $1}')
if [ "$elapsed_int" -ge 2 ] && [ "$elapsed_int" -le 4 ]; then
	pass "wall clock ${elapsed} sec is in expected 2-4 sec range (back-pressure working)"
elif [ "$elapsed_int" -lt 1 ]; then
	fail "wall clock ${elapsed} sec is < 1 sec - back-pressure may be broken (writes returning instantly)"
else
	warn "wall clock ${elapsed} sec is outside expected 2-4 sec range"
fi

# dmesg for stream events
say ""
say "dmesg after test 5:"
dmesg | tee_log
say ""

# Check for panic/LOR/deadlock indicators
if dmesg | grep -qE "panic|LOR|deadlock|audwrite.*stuck"; then
	fail "dmesg contains panic/LOR/deadlock indicators"
else
	pass "dmesg clean (no panic/LOR/deadlock)"
fi

# Writer_seq advance
seq_after=$(read_writer_seq)
seq_delta=$((seq_after - seq_before))
say "writer_seq after test 5: $seq_after (delta +$seq_delta)"

# Expect +2 (one stream_begin, one stream_end) on audiofs0.
# If audiofs1 is also emitting events, could be +4.
if [ "$seq_delta" -ge 2 ]; then
	pass "writer_seq advanced by $seq_delta (expected at least +2 for stream_begin/end)"
else
	fail "writer_seq advanced by only $seq_delta (expected at least +2)"
fi

# Extract frames_total from stream_end
ftotal=$(dmesg | grep -oE "stream_end: stream_id=1 frames_total=[0-9]+" | \
	head -1 | awk -F= '{print $NF}')
if [ -n "$ftotal" ]; then
	say "audiofs0 frames_total: $ftotal"
	# 3 sec at 48000 = 144000 frames. close-doesn't-drain may lose ~30-50k.
	# Anything between 100000 and 150000 is healthy.
	if [ "$ftotal" -ge 100000 ] && [ "$ftotal" -le 150000 ]; then
		pass "frames_total $ftotal in expected range 100000-150000 (3 sec less drain loss)"
	else
		warn "frames_total $ftotal outside expected range; check by hand"
	fi
else
	warn "could not extract frames_total from dmesg"
fi

# -------- test 6a: double-open EBUSY --------

banner "Test 6a: Double-open returns EBUSY"

say ""
say "Goal: while one process holds /dev/audiofs0 open, a second open"
say "      should fail with EBUSY."

dmesg -c >/dev/null
seq_before=$(read_writer_seq)
say "writer_seq before test: $seq_before"

# Hold the device open for 5 seconds with no writes. The shell
# redirection opens the cdev; sh -c 'sleep 5' holds it.
sh -c 'sleep 5' >/dev/audiofs0 &
HOLDER=$!
track $HOLDER
say "Holder PID: $HOLDER (will hold /dev/audiofs0 open for 5 sec)"
sleep 1   # give the open() time to land

# Verify holder is alive
if ! kill -0 $HOLDER 2>/dev/null; then
	fail "Holder process $HOLDER died before second open attempt"
else
	say "Holder confirmed alive"
fi

# Verify cdev_open fired in dmesg
if dmesg | grep -q "cdev_open"; then
	pass "first open recorded in dmesg"
else
	warn "first cdev_open NOT in dmesg; holder may not have opened"
fi

# Try second open
say ""
say "Attempting second open (expected to fail with EBUSY):"
"$PLAYTONE" /dev/audiofs0 1 > /tmp/playtone-test6a.out 2>&1
playtone_rc=$?
say "playtone exit code: $playtone_rc"
say "playtone output: $(cat /tmp/playtone-test6a.out)"

if [ "$playtone_rc" -ne 0 ] && grep -qiE "busy|EBUSY" /tmp/playtone-test6a.out; then
	pass "second open correctly failed with EBUSY"
else
	fail "second open did NOT fail with EBUSY (exit=$playtone_rc)"
fi

# Wait for holder to finish
say ""
say "Waiting for holder to release the cdev..."
wait $HOLDER 2>/dev/null
untrack $HOLDER

sleep 0.5   # give close handler time to settle

# Now playtone should succeed
say ""
say "Attempting open after holder released (expected to succeed):"
"$PLAYTONE" /dev/audiofs0 1 > /tmp/playtone-test6a2.out 2>&1
playtone_rc=$?
say "playtone exit code: $playtone_rc"
say "playtone output: $(cat /tmp/playtone-test6a2.out)"

if [ "$playtone_rc" -eq 0 ]; then
	pass "open after holder released succeeded"
else
	fail "open after holder released failed (exit=$playtone_rc)"
fi

say ""
say "dmesg from test 6a:"
dmesg | tee_log
say ""

seq_after=$(read_writer_seq)
seq_delta=$((seq_after - seq_before))
say "writer_seq after test 6a: $seq_after (delta +$seq_delta)"

# Expected: 4 events total (2 stream_begin/end pairs - one for holder
# open/close, one for the post-holder playtone).
if [ "$seq_delta" -ge 4 ]; then
	pass "writer_seq advanced by $seq_delta (expected at least +4)"
else
	warn "writer_seq advanced by only $seq_delta (expected at least +4)"
fi

# -------- test 6b: SIGKILL cleanup --------

banner "Test 6b: SIGKILL on writer triggers clean cdev teardown"

say ""
say "Goal: SIGKILL a process that holds /dev/audiofs0 open; D_TRACKCLOSE"
say "      should clean up cdev_open state; subsequent open() should succeed."

dmesg -c >/dev/null
seq_before=$(read_writer_seq)
say "writer_seq before test: $seq_before"

# Start a playtone with a 10 sec duration; we'll kill it after ~1 sec.
"$PLAYTONE" /dev/audiofs0 10 > /tmp/playtone-test6b.out 2>&1 &
VICTIM=$!
track $VICTIM
say "Victim PID: $VICTIM (10-sec playtone, will be SIGKILL'd at ~1 sec)"
sleep 1   # let it start writing

if ! kill -0 $VICTIM 2>/dev/null; then
	fail "Victim died before SIGKILL test could run (exit code: $(wait $VICTIM 2>/dev/null; echo $?))"
	untrack $VICTIM
else
	say "Victim alive; sending SIGKILL"
	kill -KILL $VICTIM
	wait $VICTIM 2>/dev/null
	untrack $VICTIM
	sleep 0.5   # give close handler time to fire via D_TRACKCLOSE
	pass "SIGKILL sent and reaped"
fi

# Verify cdev is reusable
say ""
say "Attempting open after SIGKILL (expected to succeed if D_TRACKCLOSE worked):"
"$PLAYTONE" /dev/audiofs0 1 > /tmp/playtone-test6b2.out 2>&1
playtone_rc=$?
say "playtone exit code: $playtone_rc"
say "playtone output: $(cat /tmp/playtone-test6b2.out)"

if [ "$playtone_rc" -eq 0 ]; then
	pass "open after SIGKILL succeeded - D_TRACKCLOSE worked"
elif grep -qiE "busy|EBUSY" /tmp/playtone-test6b2.out; then
	fail "open after SIGKILL returned EBUSY - D_TRACKCLOSE did NOT fire on signal"
else
	fail "open after SIGKILL failed (exit=$playtone_rc, neither success nor EBUSY)"
fi

say ""
say "dmesg from test 6b:"
dmesg | tee_log
say ""

# Check kthread / lock state still healthy
if dmesg | grep -qE "panic|LOR|deadlock|abandoned"; then
	fail "dmesg contains panic/LOR/deadlock/abandoned-kthread indicators"
else
	pass "dmesg clean (no panic/LOR/abandoned)"
fi

seq_after=$(read_writer_seq)
seq_delta=$((seq_after - seq_before))
say "writer_seq after test 6b: $seq_after (delta +$seq_delta)"

# Expected: 4 events (victim's stream_begin/end via SIGKILL+TRACKCLOSE,
# then recovery playtone's stream_begin/end).
if [ "$seq_delta" -ge 4 ]; then
	pass "writer_seq advanced by $seq_delta (expected at least +4)"
else
	warn "writer_seq advanced by only $seq_delta (expected at least +4)"
fi

# -------- post-test: capture audiofs1 state --------

banner "Post-test: full audiofs1 dmesg lines (audiofs1 anomaly investigation)"

say ""
say "Filtering full session dmesg for audiofs1 mentions only..."
say "(grepping the live buffer, which may have rolled over)"
dmesg | grep -E "audiofs1:" | tee_log

# -------- post-test: clean unload --------

banner "Post-test: clean unload"

if ./build.sh unload >> "$LOGFILE" 2>&1; then
	pass "kldunload clean"
else
	fail "kldunload failed; see $LOGFILE"
fi

# Final dmesg check for any straggler issues
say ""
say "Final dmesg sanity check:"
dmesg | tail -30 | tee_log

if dmesg | grep -qE "panic|LOR|deadlock|abandoned"; then
	fail "final dmesg shows panic/LOR/deadlock/abandoned indicators"
fi

# -------- summary --------

banner "Summary"
say ""
say "PASS: $PASS"
say "FAIL: $FAIL"
say "WARN: $WARN"
say ""
say "Full transcript: $LOGFILE"

if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0
