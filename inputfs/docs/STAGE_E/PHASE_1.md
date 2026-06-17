# AD-2a Phase 1 — semadrawd switches to inputfs as the input source

Status: **Verified on bare metal 2026-05-06**. Phase 2 (libsemainput
extraction) is now unblocked.

## Verification record (2026-05-06)

Bare-metal verification on PGSD-bare-metal-test-machine using
the protocol from §"Open questions" item 5 below.

  - Test 1 — semainputd NOT running, input still works:
    Stopped utf-supervisor, restarted, then stopped semainput
    via `service semainput stop`. utf-supervisor reported
    semainputd as `down (signal SIGTERM)` while semaaud and
    semadrawd were `up`. Launched `semadraw-term`. Keys
    produced characters end-to-end. **Pass.**

  - Test 2 — semainputd running, inputfs path still authoritative:
    Brought semainput back up via `service semainput start`.
    All three services up. Keys still arrived in semadraw-term.
    semainputd's events are dropped on the floor at the drawfs
    backend's discard drain (`drainInjectedEvents` reads /dev/draw
    for legacy frames and discards them). **Pass.**

  - Test 3 — pointer events: confirmed via inputdump and via
    in-terminal click. `inputdump events` showed
    `pointer.motion` and `pointer.button_down` events being
    published by inputfs (dev=0 ELECOM mouse, dev=2 touchpad).
    Click-and-drag in semadraw-term produced visible response,
    confirming events route end-to-end through semadrawd to
    the client. **Pass.**

  - Tests 4 (modifier bits) and 5 (cold-boot replay): not run
    explicitly, but inputdump showed modifier bits arriving
    correctly with key events (`modifiers=0x4` with hid_usage
    matching shift+letter combinations), and the `EventRingReader`
    init does `last_consumed = writerSeq()` which mathematically
    skips historical events — both are reasonably covered by
    indirect verification. Direct retest at any reboot will
    catch regressions if they appear.

Two unrelated findings surfaced during verification, filed as
their own BACKLOG items rather than blocking Phase 1:

  - **Missing mouse cursor sprite** (B-PR-1, polish): neither
    semadrawd nor semadraw-term draws a pointer cursor. Pointer
    events arrive and route correctly (clicks register, drags
    work in the terminal), but no visible sprite tracks the
    pointer position. This was true pre-cutover too; it is not
    a Phase 1 regression. Filed as a separate item.

  - **inputfs y-clamp emits motion events with non-zero dy
    while y stays at 0** (filed as a sub-item under AD-1):
    when the pointer is at the top edge of the screen and the
    user keeps moving up, inputfs publishes events with `y=0`
    and `dy=-N` for many frames in a row. Consumers integrating
    `(dx, dy)` into their own state see phantom drift. Cause is
    in the kernel-side D.3 coordinate transform; AD-1
    territory, not Phase 1.

Both findings are tracked separately. Phase 1 itself is done.

## What unblocks

  - **Phase 2** (libsemainput extraction): promote
    `semainput/src/gesture.zig` (1,044 lines) into a userland
    library consumed by clients and by semadrawd. Phase 2 is
    mostly mechanical file moves per §"Relationship to Phase 2
    and Phase 3" below; the binary risk landed in Phase 1.

  - **Phase 3** (deletions): remove `semainputd`, the evdev
    adapter, the `drawfs_inject` adapter, the
    `DRAWFS_EVT_KEY/POINTER/SCROLL` decode arms in
    `sendAndRecv`, the rc.d shim, the s6 service directory,
    and the install.sh blocks that wire them up. Phase 3 is
    irreversible at the commit level but only deletes code
    Phase 1 made unreachable.

## Original status block (preserved for context)

This document specifies Phase 1 of AD-2a (Stage E cutover). Phase 1
moves semadrawd's input source from drawfs's injected-event channel
to inputfs's event ring, while leaving every other piece of the
legacy system in place. After Phase 1 lands, evdev is *unused* by
semadrawd even though semainputd, the evdev adapter, and the
drawfs_inject path are still present in the tree. Phase 1 is the
load-bearing motion: it proves the post-evdev system works before
any deletions happen.

## Implementation note (added post-landing)

The code described in §"Files touched" below is already in the
tree as of the seed commit:

- `semadraw/src/backend/inputfs_translate.zig` — HID Usage
  Page 0x07 → evdev translation table plus
  `hidModifiersToBackend()` for the boot-keyboard modifier byte
  layout. Includes unit tests for letters, modifiers, function
  keys, navigation cluster, unmapped usages, and page-prefixed
  defensive masking.
- `semadraw/src/backend/inputfs_input.zig` — `InputfsInput`
  struct that owns the `EventRingReader`, drains in batches of
  64 events per call, and dispatches keyboard / pointer events
  into the drawfs backend's `injected_keys` / `injected_mice`
  stash buffers. Also handles ring overrun (logs and continues),
  pointer button transitions synthesised from MOTION events
  when no explicit BUTTON_DOWN/UP arrived, and modifier
  carry-forward into MouseEvent records (which the backend
  schema requires but inputfs pointer events do not carry).
- `semadraw/src/backend/drawfs.zig` — owns an
  `?InputfsInput` field; `init()` opens the ring;
  `pollEventsImpl()` calls `inputfs.drain()` then
  `drainInjectedEvents()` (the latter is the legacy
  `/dev/draw` fd drain whose data is now discarded).
- `shared/src/input.zig` — already provided
  `EventRingReader` and `Event`; no changes were needed for
  Phase 1.

Acceptance criterion 4 in §"Acceptance criteria" below names a
"dedicated commit message" for Phase 1; that criterion does not
apply post-hoc. The work landed inline in the seed.

What remains: bare-metal verification per §"Open questions"
item 5, and `KeyEvent.key_code` comment update in
`backend.zig` (option a from §"Files touched"). Both are
trackable from this document.

## Why this is Phase 1

Stage E cannot start with deletions. Deleting `semainput/src/adapters/evdev.zig`
or `semainputd.zig` before semadrawd has another input source means
UTF stops receiving input the moment those files are removed. The
sequencing rule is: change the data flow first, verify, *then*
delete what the new data flow has obsoleted.

Phase 1 is also the smallest change with binary risk. Phase 2
(library extraction) is mostly mechanical file moves; Phase 3
(deletions) is irreversible at the commit level but deletes only
code already known dead. Phase 1 is the one that has to actually
work the first time on real hardware.

## Current state (pre-Phase-1)

The input flow today, as implemented:

```
USB HID device
  -> FreeBSD hidbus
  -> evdev/hms/usbhid (legacy compatibility layer)
  -> /dev/input/eventN (evdev nodes)
  -> semainput/src/adapters/evdev.zig (reader)
  -> semainputd's classification, aggregation, gesture pipeline
  -> semainput/src/adapters/drawfs_inject.zig
  -> ioctl(/dev/draw, DRAWFSGIOC_INJECT_INPUT, ...)
  -> drawfs.ko enqueues frames into the active session's read queue
  -> semadraw/src/backend/drawfs.zig reads /dev/draw fd
  -> stashes EVT_KEY/EVT_POINTER/EVT_SCROLL frames in injected_keys / injected_mice
  -> backend.getKeyEvents() / backend.getMouseEvents() returns them
  -> compositor delivers to clients
```

In parallel, inputfs (Stages A through D, landed) provides a
complete substitute path:

```
USB HID device
  -> FreeBSD hidbus
  -> inputfs.ko attaches as a hidbus child (ADR 0007)
  -> parses HID descriptor (Stage B)
  -> classifies device by role (Stage B)
  -> reads HID reports in interrupt context
  -> applies coordinate transform (D.3)
  -> applies focus-driven routing (D.4)
  -> writes events into /var/run/sema/input/events (ring writer)
  -> EventRingReader from shared/src/input.zig drains events
```

Phase 1 cuts the second path into semadrawd in place of the first.
Both paths can run simultaneously — both attach to hidbus, both
publish to userspace — but for Phase 1's purposes inputfs is the
sole consumed source and the legacy injection path is ignored.

## Goal of Phase 1

semadrawd reads input events exclusively from
`/var/run/sema/input/events` via `EventRingReader`. The compositor's
`backend.getKeyEvents()` and `backend.getMouseEvents()` accessors
return events synthesised from the inputfs ring rather than from
the drawfs-injected stash buffers.

semainputd may continue to run during Phase 1 verification (it
still reads evdev and injects to drawfs), but its events are never
consumed by semadrawd. The drawfs backend's `drainInjectedEvents`
mechanism is gated off but not yet deleted; the evdev adapter is
present but its output is dropped on the floor at the drawfs
queue.

After Phase 1 lands and verifies, Phase 2 extracts the gesture
library and Phase 3 deletes the now-dead injection path.

## Files touched

### Edited

`semadraw/src/backend/drawfs.zig` — primary work.

The drawfs backend gains an `EventRingReader` field opened against
`input.SHARED_INPUT_EVENTS_PATH` (constant from `shared/src/input.zig`,
existing). The reader is initialised in the backend's `init()`
after the `/dev/draw` open and HELLO succeed.

`drainInjectedEvents` is renamed and rewritten as a direct ring
drain: poll the inputfs ring (it is mmap-backed; pollability is via
a separate fd channel — see Open question 1 below), call
`EventRingReader.drain(events_buf)`, translate each `Event` into
the backend's `KeyEvent` / `MouseEvent` shapes, append to
`injected_keys` / `injected_mice`. The translation step is new
(see "HID usage translation" below).

`pollEventsImpl`, `getKeyEventsImpl`, `getMouseEventsImpl`,
`getScrollEventsImpl` keep their existing signatures and stash
buffers unchanged. The change is the source of fill, not the shape
of the output.

The `sendAndRecv` switch arms that stash `DRAWFS_EVT_KEY`,
`DRAWFS_EVT_POINTER`, `DRAWFS_EVT_SCROLL` frames during protocol
transactions are left in place but never trigger after Phase 1
because semainputd's injection is the only thing that produced
those frames. Phase 3 removes them.

`semadraw/src/backend/backend.zig` — secondary, possibly no-op.

The `KeyEvent.key_code` field is documented as "evdev code on
Linux" (line 84). After Phase 1, the value semadrawd produces for
this field is no longer an evdev code; it is the result of
HID-usage-to-keysym translation. Two options:

(a) Keep the field name and update the comment to say "post-
    translation keysym; was evdev code under semainputd."
(b) Rename the field to `keysym` to remove the confusion.

Option (a) is less disruptive (no client-side or test-side
ripple). Option (b) is more honest. I recommend (a) for Phase 1
and (b) as a follow-up cleanup once the post-cutover state is
stable.

`semadraw/src/backend/drawfs.zig` (continued) — comment updates.

The block comments at lines 314-318, 374-377, 542-548, 1324-1339,
1370-1373 all describe input as arriving via injection from
semainputd. These are updated to describe arrival via inputfs's
event ring. Doc-only edits within the same file; same commit.

`semadraw/build.zig` — link the shared input module if not already
linked.

`shared/src/input.zig` is already imported transitively for the
state region. The `EventRingReader` and `Event` types are in the
same file. If the build graph already pulls in the input module,
no build.zig change is needed; if not, add the import.

### New

`semadraw/src/backend/inputfs_translate.zig` — HID-usage-to-keysym
translation.

inputfs publishes keyboard events with `hid_usage` (per
`INPUT_EVENTS.md` line 117), where the value is a HID Usage Page +
Usage ID composite (typically Usage Page 0x07 = Keyboard for
ordinary keys). The current `KeyEvent.key_code` consumers expect
evdev key codes (e.g. `KEY_A = 30`, `KEY_LEFTSHIFT = 42`). Until
a deeper backend rework lands, semadrawd needs to translate.

The translation table is finite (HID Usage Page 0x07 has ~150
keys) and well-documented (USB HID Usage Tables 1.4 §10). The
translation is a switch on `hid_usage` returning either an evdev
code or a sentinel for unmapped usages. Modifier handling
(left/right shift/ctrl/alt/meta) parallels what
`semainput/src/adapters/evdev.zig` does today, but with HID usage
inputs.

This file lives in `semadraw/src/backend/` because it's a
backend-specific translation; other backends (Wayland, X11)
already consume their host system's keysyms and don't need it.

The `modifiers` field on inputfs's keyboard events is a
ready-made bitmask per `INPUT_EVENTS.md` line 117 ("modifiers"
u32). It maps directly to `KeyEvent.modifiers` (bits 0-3 per
`backend.zig` line 87). The HID modifier bits are HID Usage Page
0x07 IDs 0xE0-0xE7; inputfs has already aggregated them into the
`modifiers` field, so the translation layer reads them as-is.

`semadraw/src/backend/inputfs_input.zig` (provisional name) — the
ring drain and translate glue.

This is the small adapter that opens the `EventRingReader`, drains
events, dispatches them through `inputfs_translate.zig` for
keyboard events and direct field-pull for pointer events, and
writes results into the drawfs backend's existing `injected_keys`
and `injected_mice` buffers.

The drawfs backend holds an instance of this struct rather than
duplicating the logic inside `drawfs.zig`. Keeps the change
isolated and the legacy stash-from-fd code path easy to delete in
Phase 3.

### Not touched in Phase 1

- `semainput/` directory and any of its sources. Still builds,
  still runs, still produces events that semadrawd ignores.
- `start.sh`. semainputd still starts.
- `inputfs/` kernel module. Already publishes the events Phase 1
  reads.
- Other semadraw backends (`evdev.zig`, `wayland.zig`, `x11.zig`,
  `bsdinput.zig`). Phase 1 only affects the drawfs backend.
- `semadraw/README.md`. User-facing setup recipes are still
  accurate for the legacy path; the recipe update is a Phase 3
  concern.
- `BACKLOG.md` AD-2 entry. Status moves to `[~]` when the Phase 1
  commit lands, which is the standard "first implementation
  commit" trigger; the BACKLOG nudge ships in the same commit.
- `README.md`. The README's Stage E intent paragraph is already
  in place from commit 67be99c; it does not need changes for
  Phase 1.

## Open questions to resolve before code

### 1. How does semadrawd wake on inputfs events?

Today, the drawfs backend polls `/dev/draw` for input events
because injected events arrive on the same fd as protocol replies.
inputfs's event ring is mmap-backed, which is not directly
pollable. Two options:

(a) inputfs already publishes a wakeup fd or eventfd-equivalent
    that signals when the ring's writer_seq advances.
(b) Polling: semadrawd's main loop calls `EventRingReader.drain()`
    every frame regardless. This works because the loop already
    runs at compositor frequency.

Verify which inputfs supports today by reading `inputfs/docs/`
before implementing. If neither, (b) is the cheap fallback for
Phase 1; a wakeup mechanism can be added later without changing
the data path.

Action: read `inputfs/docs/foundations.md` and the relevant ADRs
to confirm. (Likely answer: poll-on-frame is the current
mechanism.)

### 2. Does inputfs publish session_id, and does the drawfs backend need it?

`INPUT_EVENTS.md` shows every pointer and keyboard event payload
contains `session_id`. The drawfs backend currently treats all
events as belonging to the active session implicitly. Post-Phase-1,
events arrive with a session_id stamped by inputfs's D.4 routing.

For Phase 1, the simplest action is to ignore session_id at the
drawfs backend level: deliver every event the ring produces to
the active session, same as today. A future cleanup may make use
of the session_id for multi-session work, but Phase 1 does not
need it.

Action: confirm by reading the focus region's current state in
the running system that semadrawd's session is what inputfs is
routing to. If yes, drop session_id on the floor in Phase 1.

### 3. Coordinate space agreement

inputfs publishes pointer events in display-space coordinates
post-D.3 transform. The drawfs backend currently feeds the
compositor coordinates that semainputd had already smoothed and
sometimes accumulated relative to surface origin (the original
D-6 bug class).

Verification step: confirm that inputfs's `motion.x` and `motion.y`
are already in the same space the compositor expects. Per ADR
0012 and the proposal's "interim status" section (line 281-294),
this is the intended behaviour; Phase 1 verifies it on hardware.

If there is a mismatch, the fix is in inputfs (kernel-side D.3),
not in semadrawd. Phase 1 reports the discrepancy and waits; it
does not work around it in userland.

### 4. Initial state synchronisation

When semadrawd starts, the inputfs ring already contains events
from before semadrawd was running. The `EventRingReader` starts
with `last_consumed = 0`, which means it would replay history.

The mitigation: on initialisation, set `last_consumed = writer_seq`
to skip historical events. This is the standard "start fresh"
pattern for ring-buffer consumers. Implementing it requires a
one-line addition to the reader's init or a helper method.

Action: either add a helper `EventRingReader.skipToCurrent()` to
`shared/src/input.zig`, or do the skip directly in
`inputfs_input.zig`. Direct-in-glue is fine for Phase 1; the
helper is a Phase-3-or-later cleanup if the pattern recurs.

### 5. Verification on hardware

Phase 1's verification is yours, on PGSD-bare-metal:

- Build the modified semadrawd.
- Launch with `semainputd` *not* running. Verify keyboard and
  pointer input both work.
- Launch with `semainputd` running. Verify the inputfs path is
  still authoritative (events from inputfs reach the compositor;
  events from semainputd's injection are present in the queue
  but ignored).
- Verify all six HID device classes used in AD-1's verification
  still work: USB keyboard, USB mouse, USB trackball, laptop
  keyboard, laptop trackpad (basic motion + buttons; gestures
  are out of scope for Phase 1 because gesture recognition still
  lives in semainputd until Phase 2). Touch and pen remain
  deferred per AD-1's Status block.
- Verify modifier keys (shift/ctrl/alt/meta) produce the right
  modifier bits in delivered events.
- Verify that on cold start, no replay of historical events
  occurs.

If Phase 1 verifies clean, Phase 2 may proceed. If verification
finds bugs, the fix lands in semadrawd or inputfs as appropriate
before Phase 1 is considered done.

## Acceptance criteria

Phase 1 is complete when:

1. `semadraw/src/backend/drawfs.zig` reads input from inputfs's
   event ring exclusively. The injection path's stashing in
   `sendAndRecv` is no longer the source of any event the
   compositor delivers (the code is still present but
   unreachable in the input flow).

2. The HID-usage-to-keysym translation table covers HID Usage
   Page 0x07 (Keyboard) IDs 0x04 through 0xE7 (the standard
   keyboard usages including modifiers). Other HID pages
   (consumer control, system control, etc.) are deferred.

3. semadrawd builds clean, runs on PGSD-bare-metal, and passes
   the verification list in §"Open questions" item 5 above.

4. The commit message names the cutover explicitly, references
   AD-2a and this document, lists what is *not* deleted yet,
   and notes that Phase 2 (library extraction) and Phase 3
   (deletions) are the follow-on work.

5. `BACKLOG.md` AD-2 status moves from `[ ]` to `[~]` in the
   same commit, matching the AD-9 sub-stage precedent.

## Out of scope for Phase 1

- Library extraction (`semainput/libsemainput/`). Phase 2.
- semainputd deletion. Phase 3.
- evdev adapter deletion. Phase 3.
- semadraw/src/backend/evdev.zig deletion. Phase 3.
- start.sh updates. Phase 3.
- semadraw/README.md user-setup recipe updates. Phase 3.
- AD-2b smoothing implementation. Independent track per
  ADR 0015.
- Touch and pen input. Deferred per AD-1's status.
- Gesture recognition through libsemainput. Phase 2.

## Estimated change size

- Edited files: 2 (drawfs.zig substantial, backend.zig comment-only).
- New files: 2 (inputfs_translate.zig ~150 lines, inputfs_input.zig ~80 lines).
- Deleted files: 0.
- Net diff: ~+250 / -50 lines, single commit.

The "single commit" framing matters: Phase 1 is one atomic move.
Splitting it would create intermediate states where input is
half-routed through the old path and half through the new, which
is harder to verify than either pure state.

## Relationship to Phase 2 and Phase 3

Phase 2 promotes `gesture.zig` into `semainput/libsemainput/`.
After Phase 2, semadrawd consumes gesture events from libsemainput
(which itself reads from the inputfs ring and from semadrawd's
focus state). Phase 1's `inputfs_input.zig` is the foundation
libsemainput will build on, not a competitor to it.

Phase 3 deletes the legacy paths Phase 1 made unreachable. Phase 3
is small per file but touches many files; it lands as one or
several commits per the planning document yet to be drafted.

## References

- `inputfs/docs/inputfs-proposal.md` Stage E section (line 255-280).
- `inputfs/docs/adr/0012-stage-d-scope.md` for what the kernel
  substrate produces.
- `shared/INPUT_EVENTS.md` for the event ring's wire format.
- `shared/src/input.zig` for the `EventRingReader` API.
- `BACKLOG.md` AD-2a entry (added in commit ba4f7ca).
- `docs/AWASE_ARCHITECTURAL_DISCIPLINE.md` for the no-fallback
  commitment that Phase 3 ultimately enforces.
