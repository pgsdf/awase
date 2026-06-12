#!/bin/sh
#
# bench_setup.sh  --  one-command bench setup. TEST ONLY, DO NOT COMMIT.
#
# From a fresh shell to a ready bench: rebuild everything (audiofs.ko, the
# userland tools, semasound), reload the module in place, start the broker,
# and verify the device nodes, event region, and socket are actually present
# before declaring ready. Idempotent and safe to re-run; it clears whatever
# is holding the device first (the EBUSY-from-leftover-semasound trap).
#
# The module is run IN PLACE from audiofs/sys/modules/audiofs/audiofs.ko,
# loaded by explicit path. Nothing is installed to /usr/local or /boot.
#
# Usage (from anywhere inside the UTF tree, as root):
#   sudo sh bench_setup.sh
#
# Rebuilds, by design, every run (no staleness). Leaves semasound running
# and logging to /tmp/semasound.log; you drive the per-test clients yourself.

set -u

# --- locate the UTF root from wherever we were invoked ---------------------
find_root() {
	d=$(pwd)
	while [ "$d" != "/" ]; do
		if [ -d "$d/audiofs/sys/modules/audiofs" ] && [ -d "$d/semasound" ]; then
			echo "$d"; return 0
		fi
		d=$(dirname "$d")
	done
	return 1
}

ROOT=$(find_root) || { echo "error: not inside a UTF tree (need audiofs/ and semasound/)" >&2; exit 1; }
MODDIR="$ROOT/audiofs/sys/modules/audiofs"
KO="$MODDIR/audiofs.ko"
PLAYTONE_DIR="$ROOT/audiofs/tools/playtone"
SEMASOUND_DIR="$ROOT/semasound"
DEV=/dev/audiofs0
NOTIFY=/dev/audiofs_notify
EVENTS=/var/run/sema/audio/events
SOCK=/var/run/sema/audio.sock
LOG=/tmp/semasound.log

if [ "$(id -u)" -ne 0 ]; then echo "error: run as root (sudo sh $0)" >&2; exit 1; fi

step() { printf "\n=== %s ===\n" "$1"; }
die()  { echo "FAIL: $1" >&2; exit 1; }

echo "UTF bench setup"
echo "  root: $ROOT"

# --- 1. clear anything holding the device ----------------------------------
step "clearing leftover processes"
# semasound holds the device for its lifetime; playtone holds it per-run. A
# leftover of either causes EBUSY on the next open. SIGCONT first in case one
# is stopped (a SIGSTOPped stall-test client), then kill.
# F.6 era: the machine may be running the PRODUCTION supervised broker
# (AD-20). Down it via s6 FIRST, or s6-supervise respawns whatever we
# pkill and its run script reloads the installed /boot/modules module
# behind our backs during the build window below.
SVC=/var/service/utf/semasound
if command -v s6-svok >/dev/null 2>&1 && s6-svok "$SVC" 2>/dev/null; then
	s6-svc -dwd -T 5000 "$SVC" 2>/dev/null || s6-svc -d "$SVC" 2>/dev/null
	echo "  downed supervised semasound (restore after bench work:"
	echo "    sudo s6-svc -u $SVC)"
fi

for name in semasound semasound-tone playtone; do
	pkill -CONT -x "$name" 2>/dev/null
	pkill -x "$name" 2>/dev/null
done
sleep 1
rm -f "$SOCK"
echo "  cleared semasound / semasound-tone / playtone, removed stale socket"

# --- 2. unload the module (clean slate) ------------------------------------
step "unloading audiofs (if loaded)"
if kldstat -n audiofs >/dev/null 2>&1; then
	kldunload audiofs || {
		echo "  holder of $DEV (if any):" >&2
		fstat "$DEV" 2>/dev/null >&2
		die "kldunload audiofs failed (still in use?)"
	}
	echo "  unloaded"
else
	echo "  not loaded"
fi

# --- 3. rebuild the module -------------------------------------------------
step "building audiofs.ko"
( cd "$MODDIR" && make ) || die "audiofs.ko build failed"
[ -f "$KO" ] || die "audiofs.ko not produced at $KO"
echo "  built $KO"

# --- 4. load the freshly built module in place -----------------------------
step "loading audiofs.ko"
if kldstat -n audiofs >/dev/null 2>&1; then
	die "audiofs reappeared during the build (supervised respawn?). Down it: sudo s6-svc -d /var/service/utf/semasound, then rerun."
fi
kldload "$KO" || die "kldload $KO failed"
kldstat -n audiofs >/dev/null 2>&1 || die "audiofs not present after load"
echo "  loaded"

# --- 5. verify the kernel surfaces -----------------------------------------
step "verifying device nodes and event region"
[ -e "$DEV" ]     || die "$DEV not created"
[ -e "$NOTIFY" ]  || die "$NOTIFY not created"
[ -e "$EVENTS" ]  || die "$EVENTS not created (state publish?)"
echo "  $DEV, $NOTIFY, $EVENTS all present"
echo "  refill counters: miss=$(sysctl -n dev.audiofs.0.refill_miss_count) multi=$(sysctl -n dev.audiofs.0.refill_multi_count) underflow=$(sysctl -n dev.audiofs.0.underflow_count)"

# --- 6. build the userland tools -------------------------------------------
step "building playtone"
( cd "$PLAYTONE_DIR" && make ) || die "playtone build failed"
echo "  built $PLAYTONE_DIR/playtone"

step "building semasound + semasound-tone"
( cd "$SEMASOUND_DIR" && rm -rf .zig-cache zig-out && zig build ) || die "semasound build failed"
[ -x "$SEMASOUND_DIR/zig-out/bin/semasound" ]      || die "semasound binary missing"
[ -x "$SEMASOUND_DIR/zig-out/bin/semasound-tone" ] || die "semasound-tone binary missing (stale build.zig?)"
echo "  built semasound and semasound-tone"
# confirm the diagnostic/test modes actually made it into the binary.
# Check the flag literals themselves (the arg parser compares against
# them, so they are in rodata); the old "non-canonical" message grep
# was a proxy that broke when message wording moved.
if strings "$SEMASOUND_DIR/zig-out/bin/semasound-tone" 2>/dev/null | grep -q -- "--badrate" \
   && strings "$SEMASOUND_DIR/zig-out/bin/semasound-tone" 2>/dev/null | grep -q -- "--gap"; then
	echo "  semasound-tone has --badrate/--gap modes"
else
	echo "  WARNING: semasound-tone lacks --badrate/--gap (source behind?)"
fi

# --- 7. start the broker ---------------------------------------------------
step "starting semasound"
: > "$LOG"
"$SEMASOUND_DIR/zig-out/bin/semasound" > "$LOG" 2>&1 &
i=0
while ! grep -q "output open" "$LOG" 2>/dev/null; do
	sleep 0.3; i=$((i+1))
	if [ "$i" -ge 20 ]; then
		echo "  semasound did not come up; log:"; sed 's/^/    /' "$LOG"
		die "semasound startup"
	fi
done
[ -S "$SOCK" ] || die "socket $SOCK not created"
echo "  semasound up (log: $LOG)"
sed 's/^/    /' "$LOG"

# --- ready -----------------------------------------------------------------
step "READY"
echo "audiofs loaded (BDL depth $(sysctl -n dev.audiofs.0.refill_miss_count >/dev/null 2>&1 && echo ok)), tools built, broker running."
echo ""
echo "Tools (run from $SEMASOUND_DIR):"
echo "  ./zig-out/bin/semasound-tone 5 750            single clean tone"
echo "  ./zig-out/bin/semasound-tone 8 440 & ./zig-out/bin/semasound-tone 8 660 &   mix"
echo "  ./zig-out/bin/semasound-tone 2 440 --badrate  rejection (criterion 4)"
echo "  ./zig-out/bin/semasound-tone 10 440 --gap 800 induce xrun (criterion 7)"
echo "  playtone:  $PLAYTONE_DIR/playtone --freq 440 $DEV 8"
echo ""
echo "Broker log: tail -f $LOG"
echo "When done:  sudo pkill -x semasound; sudo rm -f $SOCK"
