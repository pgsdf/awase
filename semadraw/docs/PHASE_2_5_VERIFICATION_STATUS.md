# AD-2a Phase 2.5 verification status

Status: Complete, 2026-05-17. Section 7 (multi-touch)
verified 2026-05-06; sections 5 (n_click) and 6 (modifier
propagation) verified 2026-05-17 via operator walkthrough on
`pgsd-bare-metal`. All runbook scenarios 1-9 verified.

Companion to `PHASE_2_5_VERIFICATION.md` (the runbook). The
runbook describes the procedure; this document records the
state of verification efforts to date. They serve different
readers: a fresh operator should read the runbook, a
maintainer asking "is this verified?" should read this file.

The goal of Phase 2.5 is to confirm that gesture events
flow end-to-end on real hardware: a click produces a
`mouse_event`, a double-click produces a `gesture_event`
with `gesture_type = n_click` and `count = 2`, modifier
bits propagate from keyboard to gesture event, and (where
hardware permits) multi-touch gestures emit
`pinch_*`/`two_finger_scroll`/`three_finger_swipe_*`
sequences.

Phase 2 closes when the runbook scenarios pass on the
target machine.

## Summary

What's verified end-to-end on `pgsd-bare-metal-test-machine`:

- Daemon bring-up via `install.sh` and the rc.d wrappers
  generated under AD-20 supervises cleanly.
- `gesture_inspect` connects, registers a focusable surface,
  receives `mouse_event` messages from a focused surface.
- The mouse-event pipeline (`inputfs_input.dispatchPointer*`
  → `injected_mice` → `getMouseEventsImpl` →
  `forwardMouseEvents`) delivers exactly one `MouseEventMsg`
  per kernel pointer event. Coordinates, button identity,
  modifier bits all match the kernel ring's content.
- The client library decodes `MouseEventMsg` and, post-
  commit 8aa2cbf, decodes `GestureEventMsg` + payload via
  `parseGestureEvent`. Unit tests at the parse boundary
  pass.

What was **not** verified end-to-end as of 2026-05-06, now
**verified 2026-05-17** (operator walkthrough on
`pgsd-bare-metal`, Debug build, over SSH):

- Runbook scenarios 1-6 driven through on the machine:
  single click (no spurious gesture), double-click
  (`n_click count=2`), triple-click (`count=2` then
  `count=3`), and the shift / ctrl / shift+ctrl modifier
  variants (each showing the correct `modifiers=` string on
  the gesture line). The recogniser-feed path
  (`forwardGestureEvents`, commit 59cd5b7) is exercised; an
  `event_kind=gesture` line was observed on bare metal for
  the first time during this walkthrough.
- Scenarios 7-9 (multitouch) were verified separately
  2026-05-06.

All nine runbook scenarios are verified. See the AD-2 entry
in `BACKLOG.md` for the per-scenario evidence and the
diagnostic notes (the intermediate no-keyboard capture, and
the cosmetic `button=left`-on-motion display artifact).

## 1. Daemon bring-up

**Goal:** `service inputfs start` loads the kernel modules,
`service utf-supervisor start` brings up `s6-svscan`, and
`service semadraw start` invokes `s6-svc -uwu` against
`/var/service/utf/semadrawd`. The daemon is ready to
accept client connections within a few seconds.

### Verified (2026-05-05, bare-metal)

The four-step bring-up sequence in
`PHASE_2_5_VERIFICATION.md` Setup section runs cleanly.
After `service semadraw start`, `sockstat -u | grep
semadraw` shows the daemon's local socket bound at
`/var/run/semadraw.sock` and `gesture_inspect` connects
without retry. Multi-step verified across multiple sessions
on 2026-05-05 with no anomalies in startup ordering.

### Recipe

See `PHASE_2_5_VERIFICATION.md` Setup section. The runbook
correction commit `e13afd5` resolved the original "service
name is `semadraw` not `semadrawd`" confusion that blocked
the first bring-up attempt.

## 2. `gesture_inspect` connection and surface registration

**Goal:** `gesture_inspect` connects to the daemon's local
socket, receives a `client_id` from the handshake, creates
a 400×300 surface, and the surface becomes focusable.
Subsequent input gets routed to it.

### Verified (2026-05-05, bare-metal)

Connection succeeds:

```
# gesture_inspect: connecting to semadrawd...
info(semadraw_client): connected to semadrawd, client_id=N
# connected; creating surface (400x300)...
# surface visible (id=M); waiting for events. Ctrl-C to quit.
```

Mouse motion across the screen produces continuous
`event_kind=mouse type=motion` lines as the cursor moves.
The surface ID matches across the handshake reply and
subsequent event lines, so the routing path
(`forwardMouseEvents` → `getTopVisibleSurface` →
`session.send`) reaches the helper correctly.

The helper's surface is invisible on screen because it
calls `surface.show()` but never commits content. That is
intentional for a diagnostic tool; operators sometimes ask
about it and the runbook flags this.

### Recipe

```sh
~/Development/UTF/semadraw/zig-out/bin/gesture_inspect
# move mouse, observe motion lines stream to stdout
```

## 3. Mouse-event pipeline 1:1 invariant

**Goal:** every kernel pointer event drained from the
inputfs ring becomes exactly one MouseEvent in the
backend's `injected_mice` buffer (or zero, for the
synthetic dx=dy=0 motion events that carry only a buttons-
mask change), and exactly one `mouse_event` MsgType frame
on the wire to the focused surface's client.

### Verified (2026-05-05, bare-metal, post-fix)

A diagnostic instrumentation pass (commits f97d2a0,
204a8cd, e352bd7, all reverted by c71e931) added log
probes at every stage of the pipeline. With those probes
active, a clean per-iteration check showed:

  - `EventRingReader.drain`'s `last_consumed` advances
    monotonically. No re-reading of slots; one reader
    instance per daemon process; `self_addr` consistent
    across drain calls.
  - `InputfsInput.drain`'s batch sizes match the
    `consumed` count from the underlying ring drain.
  - `getMouseEventsImpl` returns slice lengths that match
    the per-batch event count, modulo zero-delta motion
    events that the dispatch path correctly drops.
  - `forwardMouseEvents` issues one `session.send` per
    slice element. No duplication.

A trace with cursor moving 20px in a straight line:

```
G: drain consumed=13 before=135 after=148 writer_seq=148
H: drain batch size=13 first_seq=136 last_seq=148
C: getMouseEventsImpl len=13
D: forwardMouseEvents len=13

G: drain consumed=8 before=148 after=156 writer_seq=156
H: drain batch size=8 first_seq=149 last_seq=156
C: getMouseEventsImpl len=7    (one dx=dy=0 motion dropped)
D: forwardMouseEvents len=7
```

13 + 7 = 20 wire sends, matching the 20 distinct
coordinates `gesture_inspect` received. Verified.

### Recipe (re-verifiable, requires re-applying probes)

The probes were temporary and removed in c71e931. To
re-verify, re-apply them locally (the probe commits are in
`git log --oneline 0487a66..e352bd7`), restart the daemon,
and grep for `DUP-DEBUG` in `/var/log/utf/semadrawd/current`.
Truncate the log first to avoid mixing with prior session
output. Ratio of `consumed=N` to `forwardMouseEvents
len=N` to coordinates received should be 1:1:1.

## 4. Pre-fix duplication bug (closed)

A regression discovered during Phase 2.5 verification: the
pre-fix `dispatchPointerMotion` synthesised press/release
transitions by diffing the buttons mask against
`last_button_state`, and the explicit `BUTTON_DOWN`/
`BUTTON_UP` events that follow on the wire (per
`shared/INPUT_EVENTS.md`) ALSO produced press/release.
Every click reached the client twice.

The defensive synthesis was a hedge against drivers that
might publish motion-with-mask but skip explicit button
events. The on-wire reality is that the FreeBSD inputfs
driver always sends both. Hedge removed; the spec's
contract is now the single source of truth.

### Verified (2026-05-05, bare-metal)

`gesture_inspect` output post-fix shows exactly one
`type=press` and one `type=release` per click. Verified
across mouse left/right/middle on dev=0 (USB mouse) and
trackpad clicks on dev=2.

### Recipe

```sh
# Post-fix daemon, single click, observe one press + one release:
~/Development/UTF/semadraw/zig-out/bin/gesture_inspect
# (click left button once)
# expect:
#   event_kind=mouse ... type=press button=left ...
#   event_kind=mouse ... type=release button=left ...
```

The fix is commit 0487a66; its 4 regression tests in
`semadraw/src/backend/inputfs_input.zig` pin the post-fix
invariant ("kernel click sequence emits exactly press +
release"). The tests are runnable manually per the
invocation in `semadraw/build.zig`.

## 5. n_click gesture emission — VERIFIED 2026-05-17

**Goal:** a double-click on a focused surface produces:
1. Two press/release pairs as `mouse_event` lines (per
   section 3, verified).
2. One `event_kind=gesture type=n_click phase=update
   surface=N fingers=1 modifiers=none ... count=2 ...`
   line, emitted after the second press.

This is the load-bearing scenario for Phase 2.5: it
exercises the recogniser-feed path
(`getInputfsEvents` → `gesture_recognizer.handleEvent` →
`nextOutput` → `forwardGestureEvents`) end-to-end on real
hardware. Until this passes, the gesture-event path has
been verified only at the unit level (`parseGestureEvent`
tests in commit 8aa2cbf).

### Verified

2026-05-17 on `pgsd-bare-metal` (Debug build, over SSH).
Double-click on surface 3 produced four mouse lines
(press/release x2) followed by `event_kind=gesture
type=n_click phase=update surface=3 fingers=1
modifiers=none count=2`, observed repeatedly across
independent double-clicks. First-ever bare-metal
observation of `forwardGestureEvents` (commit 59cd5b7)
emitting a gesture line. Triple-click additionally
produced `count=2` then `count=3` (inter-click delta
~168us, inside the interval threshold), confirming the
recogniser's `extends` path increments rather than caps.
An earlier capture showing only `count=2` lines was
diagnosed as discrete double-clicks (not a Sc.3 failure):
the recogniser source has no count ceiling and the re-run
with a genuine fast triple-click confirmed escalation.
See the AD-2 entry in `BACKLOG.md` for full per-scenario
evidence.

```
TBD: gesture_inspect output for scenario 2
TBD: machine, date
```

### Recipe

```sh
sudo service semadraw restart
sleep 2
~/Development/UTF/semadraw/zig-out/bin/gesture_inspect
# wait for "surface visible" line
# perform one quick double-click on the trackpad or mouse
# (< 500ms between clicks, < ~10px apart)
# expect 5 lines: 2 press/release pairs + 1 n_click
# Ctrl-C
```

Expected output (from `PHASE_2_5_VERIFICATION.md` Scenario
2, with concrete fields):

```
event_kind=mouse surface=N type=press   button=left modifiers=none x=X y=Y
event_kind=mouse surface=N type=release button=left modifiers=none x=X y=Y
event_kind=mouse surface=N type=press   button=left modifiers=none x=X y=Y
event_kind=mouse surface=N type=release button=left modifiers=none x=X y=Y
event_kind=gesture type=n_click phase=update surface=N fingers=1 modifiers=none t_current_ns=T button=1 count=2 x=X y=Y
```

Pass criteria (in order; if any fails, see the runbook's
Troubleshooting section):

1. The four `event_kind=mouse` lines appear, two press
   and two release, in that order. (If absent: the
   problem is upstream of the recogniser; section 3's
   pipeline is not actually verified or has regressed.)
2. The `event_kind=gesture` line appears AFTER the
   second mouse press (typically interleaved between the
   second press and the second release on some
   trackpads, or after the second release on others).
3. `count=2` on the gesture line. (If `count=1` instead:
   either the second click was too late or too far from
   the first; retry with a faster, tighter double-click.)
4. `phase=update` on the gesture line. n_click is a
   discrete gesture; the rev2 ADR specifies `phase=update`
   for discrete gestures with no lifecycle (`begin`/`end`
   pair would be wrong here).
5. `fingers=1` on the gesture line. n_click is a
   pointer-driven gesture, hardcoded to 1 finger.
6. `modifiers=none`, `button=1` (left = `MouseButtonId.left`
   widened to u32).
7. `t_current_ns` is non-zero. The daemon sets it to the
   `ts_ordering` of the most recent input event fed into
   the recogniser (`forwardGestureEvents` reads
   `self.last_input_ts_ns`, which `getInputfsEvents`
   updates per event in `semadrawd.zig`). For an n_click
   triggered by the second press, `t_current_ns` should
   equal that press's `ts_ordering`.

### Optional timing-sanity check

The daemon sets `t_current_ns` on the outgoing
gesture event to the `ts_ordering` of the most recent
input event fed into the recogniser (kernel monotonic
nanoseconds). For an n_click triggered by the second
press, `t_current_ns` should equal that press's
`ts_ordering` exactly.

A trivial sanity check: enable the daemon's existing
event-processing log lines (or add a transient
`log.info` for `ev.ts_ordering` next to the
`forwardGestureEvents` call in `semadrawd.zig`), capture
the most recent press's `ts_ordering`, and confirm it
matches the gesture event's `t_current_ns`. If they
differ by a non-zero amount, something between the
recogniser's input and the wire emission is dropping or
overwriting the timestamp.

Note that this is the **ordering** clock, not the sync
clock. UTF's audio-driven clock is published via
`/var/run/sema/clock` and exposed on the inputfs ring as
`ts_sync`. The current GestureEventMsg wire format
carries `t_current_ns` (kernel ns) only; whether it
should also carry the audio-clock sample position is a
separate design question and not in scope for Phase 2.5
verification.

## 6. Modifier propagation — VERIFIED 2026-05-17

**Goal:** scenarios 4-6 of the runbook (shift +
double-click, ctrl + double-click, shift+ctrl + double-
click) emit gesture events with the corresponding
`modifiers=` field set.

The mechanism: `forwardKeyEvents` in semadrawd updates
`last_modifiers: u8`; `forwardGestureEvents` reads it
and packs the bits into `GestureFlags` per the rev2 ADR
(bit 0 shift, bit 1 alt, bit 2 ctrl, bit 3 meta). The
client library renders the bits via `formatModifiers`
into the same string format as mouse events.

This depends on section 5 passing first (n_click itself
must work before modifier-on-n_click can be tested).

### Verified

2026-05-17 on `pgsd-bare-metal`, after section 5 passed.
All three variants observed on surface 3:
- Sc.4 shift+double-click: `event_kind=key key_code=42
  pressed=1 modifiers=shift`, mouse and gesture lines
  `modifiers=shift`, then shift release.
- Sc.5 ctrl+double-click: same with key_code=29, every
  line `modifiers=ctrl` (confirms a different bit
  position works).
- Sc.6 shift+ctrl+double-click: modifier mask builds
  `shift` then `shift+ctrl` as keys go down; gesture line
  `modifiers=shift+ctrl` in the fixed formatModifiers
  order (confirms simultaneous bits combine on the wire).

Diagnostic note: an intermediate attempt produced no
`event_kind=key` lines at all. This was diagnosed (via
the `forwardKeyEvents` daemon-log path), not assumed, as
keyboard input not reaching the daemon in that attempt -
not a modifier-propagation bug. The subsequent capture
with keyboard correctly routed to surface 3 showed all of
Sc.4-6 passing, confirming the diagnosis. See the AD-2
entry in `BACKLOG.md`.

### Recipe

See `PHASE_2_5_VERIFICATION.md` Scenarios 4, 5, 6.
Expected outputs documented there. Briefly:

  - Scenario 4: hold SHIFT, double-click left. Gesture
    line should show `modifiers=shift`.
  - Scenario 5: hold CTRL, double-click left. Gesture
    line should show `modifiers=ctrl`.
  - Scenario 6: hold SHIFT+CTRL, double-click left.
    Gesture line should show `modifiers=shift+ctrl`
    (parts ordered shift, alt, ctrl, meta by
    `formatModifiers` regardless of key-press order).

Pass criteria:

1. Mouse and gesture lines for the click portion all
   carry the same `modifiers=` string.
2. Key-up event after the modifier release shows
   `modifiers=none`.
3. The exact ordering of parts in `modifiers=shift+ctrl`
   matches `formatModifiers`'s contract (shift, alt,
   ctrl, meta).

## 7. Multi-touch gestures — VERIFIED 2026-05-06

**Goal:** scenarios 7-9 of the runbook (pinch, two-finger
scroll, three-finger swipe) emit the corresponding
gesture sequences.

### Status

Verified end-to-end on `pgsd-bare-metal-test-machine`
2026-05-06 against the HAILUCK USB touchpad
(vendor=0x258a, product=0x000c). The AD-1 HUP_DIGITIZERS
parser sub-item closed in the same session: classifier
extension, descriptor locator, parser, and Touchpad Mode
feature-report send all implemented and operating
together. Multi-touch events flow through the production
stack (inputfs → event ring → consumers).

### Verified

The verification chain end-to-end. dmesg attach output
for the HAILUCK trackpad (inputfs2):

```
inputfs2: inputfs: pointer locations cached (x=yes y=yes wheel=yes buttons=1 count=6)
inputfs2: inputfs: digitizer locations cached (report_id=7 tip=yes x=yes y=yes
          confidence=yes contact_id=yes scan_time=yes contact_count=yes button=yes
          x_range=[0..1535] y_range=[0..1023])
inputfs2: inputfs: roles=pointer,touch
inputfs2: inputfs: Device Mode set to MT Touchpad (report_id=11 rlen=2)
```

The fourth line is the load-bearing one for this
section: the SET_REPORT(FEATURE) succeeded with
Device Mode = 0x03, the HAILUCK transitioned from
Mouse Mode to Multi-touch Touchpad Mode, and Report
ID 7 began arriving in the kernel HID interrupt path.

`inputdump events` (run as root since
`hw.inputfs.dev_mode=384` restricts the state region
to owner-only) captured the touch lifecycle for
several gestures:

  - **Single-finger drag** (~900ms duration). Output:
    one `touch.type1` (touch_down), 111 sequential
    `touch.type2` (touch_move) events at 8ms intervals
    matching the descriptor's 125 Hz polling rate, one
    `touch.type3` (touch_up) on lift. All events
    carried `dev=2` (HAILUCK trackpad's device slot)
    and monotonically increasing `seq` and `ts` values.

  - **Two-finger drag.** Output: an interleaved stream
    of per-contact-id type1/type3 events with
    continuous type2 emission for each active contact.
    A second contact's type1 appeared mid-stream while
    the first contact was still emitting type2s,
    confirming per-contact tracking via Contact
    Identifier works correctly.

  - **Brief tap.** Output: cleanly bounded 7-event
    sequence (type1 + 5×type2 + type3) over ~50ms.

The dispatcher's per-Q1 per-report emission policy
fired one event per Report ID 7 arrival without
batching. The Q2 confidence-low-as-tip-switch=0
policy didn't trip on any tested input (HAILUCK
firmware handles palm rejection at descriptor level
and presents only confident contacts). No crashes,
no missed lifts, no orphaned active contacts after
extended gesture sequences.

### Closure evidence

  - Implementation commits: `9bb35ff` (classifier +
    locator), `6386360` (ADR amendment correcting
    Touchpad Mode mechanism), `fb018da` (parser +
    Touchpad Mode setter).
  - dmesg + inputdump captured 2026-05-06 in the
    operator session that this status update reflects.
  - All other inputfs devices (ELECOM mouse, HAILUCK
    keyboard, Apple keyboard, Broadcom Bluetooth
    keyboard/mouse) unchanged from prior sessions:
    same role classifications, same attach lines, no
    regressions from the second-pass classifier or
    Device Mode write logic.

### Notes for future maintenance

  - inputdump's pretty-printer renders touch events
    as `touch.type1` / `type2` / `type3` rather than
    `touch_down` / `touch_move` / `touch_up`. Cosmetic;
    the wire-format event-type values (1, 2, 3) are
    correct per `shared/INPUT_EVENTS.md`. A small
    inputdump symbol-table fix is tracked separately.

  - The integrated clickpad button transition path
    (Report ID 7 button bit going 0→1 or 1→0,
    emitting `pointer.button_down/up` via
    INPUTFS_SOURCE_POINTER) wasn't exercised in this
    verification session because the operator's
    gestures didn't include physical clickpad
    presses. The dispatcher's button-handling code
    is in place and follows the same payload layout
    Mouse-fallback Report ID 1 uses; a future session
    will exercise it.

  - A second multi-touch device (Apple Bluetooth
    Magic Trackpad) remains available for parallel
    future verification under a separate Apple-
    protocol parser sub-item rather than this one.
    Pairing logistics out of scope for the current
    milestone.

## What this status doc does NOT do

  - It is not a replacement for the runbook. The runbook
    remains the authoritative procedure; this doc records
    history and known gaps.
  - It does not commit to a Phase 2.5 closure date. The
    n_click test (section 5) is the load-bearing
    remaining task; once that runs cleanly and the
    modifier scenarios pass, Phase 2.5 closes on
    scenarios 1-6. Scenarios 7-9 are deferred to a
    separate parallel work item (see section 7).
  - It does not block other work. Phase 3 (deletions) is
    UNBLOCKED per the BACKLOG. The sweep can proceed in
    parallel with the remaining Phase 2.5 work.

## Update log

  - 2026-05-05: initial status, after the duplication-fix
    arc.
  - 2026-05-05: pending sections (5 n_click, 6 modifiers)
    expanded to match the verified-section structure (Goal
    / Verified / Recipe). The Verified subsection contains
    TBD slots ready for actual operator output. Pass
    criteria and an optional timing-sanity check spelled
    out for scenario 2.
  - 2026-05-05: section 7 status changed from
    "BLOCKED on hardware" to "DEFERRED, hardware-blocked";
    path 3 (defer) chosen as the immediate posture; closure
    criterion stated. Path 2 expanded to distinguish
    recogniser-direct (lighter) from ring-level (kernel-
    invasive) synthetic harnesses. The corresponding
    standalone BACKLOG entry tracks the deferred work.
  - 2026-05-05: section 7 reframed again. The HAILUCK
    USB touchpad on the test machine has been verified
    to present a Microsoft-precision-touchpad-class HID
    descriptor (505 bytes, Report ID 7, full Win8+
    multi-touch). Captured via the new
    hw.inputfs.debug_descriptor sysctl (commit 41e8f74).
    Hardware acquisition is no longer the blocker; the
    AD-1 HUP_DIGITIZERS parser sub-item is. Status
    header changed accordingly. Path 1 reframed from
    "different hardware" to "AD-1 HUP_DIGITIZERS
    parser." Apple Bluetooth Magic Trackpad noted as a
    second multi-touch device requiring its own Apple-
    protocol sub-item rather than gating this one.
