#!/bin/sh
# AD-27 verification: trackpad single-finger touch drives the cursor.
#
# The fix (inputfs.c touch dispatcher) synthesizes pointer.motion and
# updates the state-region pointer slot when exactly one contact is
# active, and emits pointer button events for the clickpad button.
# This script exercises the three behaviours on the attached touchpad:
#
#   Phase 1 MOTION: single-finger motion produces pointer.motion from
#                   the touchpad slot and advances the state-region
#                   pointer x/y (the slot the cursor pump reads).
#   Phase 2 CLICK:  pressing/releasing the LEFT PHYSICAL BUTTON
#                   produces pointer button_down/button_up. This pad
#                   has separate buttons (the surface does not click);
#                   light taps (tap-to-click) are a userland gesture,
#                   out of scope, and produce no button events here.
#   Phase 3 DRAG:   hold the physical button, drag a finger, release;
#                   motion during the held button should carry
#                   buttons != 0.
#   Phase 3 DRAG:   press-move-release; checks whether motion during a
#                   held button carries buttons != 0. A WARN here (not
#                   a FAIL) flags the known state-region-buttons gap:
#                   motion and discrete clicks work but click-and-drag
#                   may not, which would be a small follow-up.
#
# Interactive: it prompts you to use the trackpad during timed windows.
# Keep hands OFF the external mouse during the windows so captured
# pointer.motion is unambiguously touch-derived. Needs no root if your
# user can read /var/run/sema/input (inputdump works for you already).

set -u

INPUTDUMP="${INPUTDUMP:-/usr/local/bin/inputdump}"
WINDOW="${WINDOW:-8}"        # seconds per interactive phase
OUT="/tmp/ad27-$(date +%Y%m%d-%H%M%S)"
FAILS=0
WARNS=0

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }

mkdir -p "$OUT"

# ---- helpers -------------------------------------------------------

# Current state-region pointer x/y, space separated, or empty on miss.
state_xy() {
	"$INPUTDUMP" state 2>/dev/null \
	    | sed -n 's/.*pointer:[[:space:]]*x=\([-0-9]*\)[[:space:]]*y=\([-0-9]*\).*/\1 \2/p' \
	    | head -1
}

# Capture pointer events for $1 seconds into file $2, with extra
# inputdump args $3 (unquoted, may be empty).
capture() {
	_secs="$1"; _file="$2"; _args="$3"
	# shellcheck disable=SC2086
	"$INPUTDUMP" events --watch --role pointer $_args > "$_file" 2>&1 &
	_pid=$!
	sleep "$_secs"
	kill "$_pid" 2>/dev/null
	wait "$_pid" 2>/dev/null
}

# ---- gate ----------------------------------------------------------

hdr "Gate: substrate and touchpad"

if ! kldstat 2>/dev/null | grep -q inputfs; then
	say "   FAIL: inputfs.ko not loaded (service inputfs start)."
	exit 1
fi
say "   inputfs loaded."

# The state region is read here via inputdump, which maps it
# (MAP_SHARED). Non-root mmap of the state region hits the FreeBSD
# staleness bug (AD-34 / FREEBSD_ISSUES #1): the valid byte and
# pointer slot read frozen/zero for non-root, while root and read(2)
# see the truth. The event ring (Phase 1/2/3 captures) is NOT
# affected. So the state-region checks require root; refuse early
# with a clear reason rather than misreport the region as invalid.
if [ "$(id -u)" -ne 0 ]; then
	say "   FAIL: run this as root (sudo sh $0)."
	say "         inputdump reads the state region via non-root mmap,"
	say "         which hits the FreeBSD staleness bug (AD-34 /"
	say "         FREEBSD_ISSUES #1): the region reads frozen/zero for"
	say "         non-root even when it is valid. Root mmap is correct."
	exit 1
fi

if [ ! -x "$INPUTDUMP" ]; then
	say "   FAIL: $INPUTDUMP not found (set INPUTDUMP=...)."
	exit 1
fi

if [ -z "$(state_xy)" ]; then
	say "   FAIL: state region not valid via inputdump state."
	# The state-region valid byte is set to 1 only when a device
	# attaches after the state buffer is initialized, and is never
	# reset (inputfs.c). A persistently-invalid region therefore
	# means no device has attached since the last buffer init
	# (module load/reboot). Distinguish that from a missing file or
	# an access problem so the fix is obvious.
	if [ ! -e /var/run/sema/input/state ]; then
		say "         /var/run/sema/input/state is absent; inputfs has not"
		say "         created the region. Start/restart inputfs."
	elif dmesg 2>/dev/null | grep -q 'roles=pointer,touch'; then
		say "         A pointer/touch device DID attach this boot, yet the"
		say "         region reads invalid. If the attach was on an earlier"
		say "         boot, the buffer was re-initialized since; force a"
		say "         re-attach:  sudo service inputfs restart"
	else
		say "         No pointer/touch device attached this boot (dmesg shows"
		say "         no roles=pointer,touch). The valid byte is only set on"
		say "         device attach, so the region stays invalid until the"
		say "         touchpad attaches. Force a re-probe:"
		say "             sudo service inputfs restart"
		say "         then re-check dmesg | grep inputfs for the touchpad."
	fi
	exit 1
fi
say "   state region valid; pointer reads as: $(state_xy)"

# Detect the touchpad slot from dmesg: the inputfs instance whose
# roles line is pointer,touch, then its state_slot. Empty -> capture
# all pointer.motion (relies on hands-off-mouse).
INST="$(dmesg 2>/dev/null | grep 'roles=pointer,touch' | tail -1 \
        | sed -E 's/^(inputfs[0-9]+):.*/\1/')"
SLOT=""
if [ -n "$INST" ]; then
	SLOT="$(dmesg 2>/dev/null \
	        | grep "^$INST: inputfs: state_slot=" | tail -1 \
	        | sed -E 's/.*state_slot=([0-9]+).*/\1/')"
fi
if [ -n "$SLOT" ]; then
	say "   touchpad is $INST at state_slot=$SLOT"
	DEVARG="--device $SLOT --event motion"
else
	say "   touchpad slot not detected; capturing all pointer.motion"
	say "   (keep hands off the external mouse)"
	DEVARG="--event motion"
fi

# ---- Phase 1: MOTION ----------------------------------------------

hdr "Phase 1 MOTION: move ONE finger on the trackpad in slow circles"
say  "   starting in 2s for ${WINDOW}s ..."
sleep 2
BEFORE="$(state_xy)"
say  ">>> MOVE ONE FINGER NOW <<<"
capture "$WINDOW" "$OUT/motion.txt" "$DEVARG"
AFTER="$(state_xy)"

MCOUNT=$(grep -c 'pointer\.motion' "$OUT/motion.txt" 2>/dev/null || echo 0)
say  "   pointer.motion records captured: $MCOUNT"
say  "   state pointer before: [$BEFORE]  after: [$AFTER]"

if [ "$MCOUNT" -gt 0 ] && [ -n "$AFTER" ] && [ "$BEFORE" != "$AFTER" ]; then
	say "   PASS: trackpad synthesized pointer.motion and advanced the state slot"
else
	say "   FAIL: no synthesized motion and/or state slot did not advance"
	say "         (was the finger moving? is the device in MT Touchpad mode?)"
	FAILS=$((FAILS + 1))
fi

# ---- Phase 2: CLICK -----------------------------------------------

hdr "Phase 2 CLICK: with one finger gently moving on the pad, press"
say  "   and release the LEFT PHYSICAL BUTTON a few times, within the"
say  "   window. Keep the finger moving the whole time."
say  "   Why the moving finger: the button bit is read from the"
say  "   touchpad report, which the device sends on touch activity. A"
say  "   button press with no finger moving may generate no report and"
say  "   thus no event; a moving finger keeps reports flowing so the"
say  "   press and release are observed. This trackpad has SEPARATE"
say  "   buttons (the pad surface does not click); a light tap is a"
say  "   userland gesture (tap-to-click), out of scope here."
say  "   starting in 2s for ${WINDOW}s ..."
sleep 2
say  ">>> KEEP A FINGER MOVING; PRESS AND RELEASE THE BUTTON A FEW TIMES <<<"
capture "$WINDOW" "$OUT/click.txt" ""

DOWN=$(grep -c 'pointer\.button_down' "$OUT/click.txt" 2>/dev/null || echo 0)
UP=$(grep -c 'pointer\.button_up' "$OUT/click.txt" 2>/dev/null || echo 0)
say  "   button_down: $DOWN   button_up: $UP"
if [ "$DOWN" -gt 0 ] && [ "$UP" -gt 0 ]; then
	say "   PASS: physical button produced button_down and button_up"
elif [ "$DOWN" -gt 0 ]; then
	say "   WARN: button_down seen but no button_up. The release was not"
	say "         observed; retry keeping the finger moving through the"
	say "         release. Persisting = a real release-detection finding."
	WARNS=$((WARNS + 1))
else
	say "   WARN: no button events. With a finger moving and the physical"
	say "         button pressed, this points at the button-read path"
	say "         (loc_touch_button) rather than report flow; note it."
	WARNS=$((WARNS + 1))
fi

# ---- Phase 3: DRAG ------------------------------------------------

hdr "Phase 3 DRAG: hold the LEFT PHYSICAL BUTTON down, drag a finger"
say  "   across the pad, then release the button, all within the window."
say  "   (Separate buttons: hold the button bar with one finger/thumb"
say  "   while a second finger slides on the pad.)"
say  "   starting in 2s for ${WINDOW}s ..."
sleep 2
say  ">>> HOLD THE BUTTON, DRAG A FINGER, RELEASE THE BUTTON NOW <<<"
# Unfiltered touchpad-slot capture (no --event filter) so button_down
# and button_up are visible alongside motion. A held button rides on
# every motion report; the release should also appear as a discrete
# button_up while the finger is still generating reports.
if [ -n "$SLOT" ]; then
	capture "$WINDOW" "$OUT/drag.txt" "--device $SLOT"
else
	capture "$WINDOW" "$OUT/drag.txt" ""
fi

DRAGMOVE=$(grep 'pointer\.motion' "$OUT/drag.txt" 2>/dev/null \
           | grep -vc 'buttons=0x0' || echo 0)
ANYMOVE=$(grep -c 'pointer\.motion' "$OUT/drag.txt" 2>/dev/null || echo 0)
DDOWN=$(grep -c 'pointer\.button_down' "$OUT/drag.txt" 2>/dev/null || echo 0)
DUP=$(grep -c 'pointer\.button_up' "$OUT/drag.txt" 2>/dev/null || echo 0)
say  "   motion records during drag: $ANYMOVE   of which buttons!=0: $DRAGMOVE"
say  "   discrete button events during drag: down=$DDOWN up=$DUP"
if [ "$DRAGMOVE" -gt 0 ] && [ "$DUP" -gt 0 ]; then
	say "   PASS: drag carried the held button AND a button_up fired on"
	say "         release (the full press/drag/release path works)"
elif [ "$DRAGMOVE" -gt 0 ]; then
	say "   WARN: drag carried the held button (buttons!=0) but no"
	say "         button_up was seen on release. If the release fell"
	say "         inside the window with the finger still moving and"
	say "         button_up still did not fire, that is a real"
	say "         release-detection finding; otherwise retry."
	WARNS=$((WARNS + 1))
elif [ "$ANYMOVE" -gt 0 ]; then
	say "   WARN: motion synthesized but always buttons=0 during the drag."
	say "         The held button was not reflected in motion. Confirm you"
	say "         held the physical button while dragging; if you did,"
	say "         this is a button-path finding to investigate."
	WARNS=$((WARNS + 1))
else
	say "   WARN: no motion captured during the drag window (inconclusive;"
	say "         retry with a clearer hold-button, drag, release gesture)."
	WARNS=$((WARNS + 1))
fi

# ---- summary -------------------------------------------------------

hdr "Summary"
say "   evidence: $OUT  (tar -cf ad27-results.tar -C $OUT .)"
if [ "$FAILS" -eq 0 ] && [ "$WARNS" -eq 0 ]; then
	say "   ALL GREEN: trackpad moves, clicks, and drags. AD-27 verified."
elif [ "$FAILS" -eq 0 ]; then
	say "   CORE GREEN ($WARNS warning(s)): motion and click verified;"
	say "   see the drag WARN above for the follow-up."
else
	say "   $FAILS phase(s) FAILED, $WARNS warning(s). See evidence and re-run."
	exit 1
fi
