# ADR 0017: Gesture event wire format and routing

## Status

Superseded by ADR 0017-rev2 on 2026-05-04, which corrects the
recogniser-placement question (the original draft was
ambiguous on whether the recogniser is a service inside
semadrawd or a per-client library) and locks in the
single-timestamp wire format. See
`0017-rev2-gesture-event-wire-format-and-routing.md` for the
realized design and the 2026-05-04 addendum that records the
t_begin removal.

This document is preserved as the original draft. New work
should reference rev2.

Drafted during AD-2a Phase 2.4 design pass on 2026-05-03.

## Context

ADR 0016 specified the libsemainput library's input/output
contract but deferred the question of how gesture events get
from semadrawd to clients. Phase 2.4 makes semadrawd consume
libsemainput; the moment it does, the recogniser produces 15
distinct gesture types that need to reach clients. We have to
decide:

  1. What does a gesture event look like on the wire between
     semadrawd and a client?
  2. Which client gets which gesture event?
  3. How does a client opt in or out of gesture events?
  4. How are recogniser-state lifecycles tied to anything in
     semadrawd's existing state?

semadrawd today routes raw input events to the client owning
the focused surface via `protocol.MouseEventMsg` (16 bytes,
fixed-size). Keys go via `protocol.KeyEventMsg`. Adding 15
new MessageKinds for gestures would bloat the protocol enum
and force a corresponding switch arm in every client. A
single tagged-union message keeps the protocol small.

## Decision

### Wire format: one message kind, tagged-union payload

A new MsgType:

```zig
gesture_event = 0x9003,
```

A new fixed-size 40-byte message:

```zig
pub const GestureEventMsg = extern struct {
    surface_id: SurfaceId,        // 4 bytes; target surface (focused at emit time)
    gesture_type: GestureType,    // 1 byte; tag
    _pad: [3]u8 = [_]u8{0} ** 3,  // 3 bytes; alignment
    payload: [32]u8,              // 32 bytes; variant-specific, little-endian

    pub const SIZE: usize = 40;
    pub const GestureType = enum(u8) {
        n_click = 1,
        drag_start = 2,
        drag_move = 3,
        drag_end = 4,
        tap = 5,
        scroll_begin = 6,
        two_finger_scroll = 7,
        scroll_end = 8,
        pinch_begin = 9,
        pinch = 10,
        pinch_end = 11,
        three_finger_swipe_begin = 12,
        three_finger_swipe = 13,
        three_finger_swipe_end = 14,
        intent_hint = 15,
    };
};
```

Payload layouts (all little-endian, packed from offset 0):

```
n_click (16 bytes):
    button: u32, count: u32, x: i32, y: i32

drag_start, drag_move, drag_end, tap (12 bytes):
    contact_id: u32, x: i32, y: i32

scroll_begin, scroll_end, pinch_end, three_finger_swipe_end (0 bytes)

two_finger_scroll (8 bytes):
    dx: i32, dy: i32

pinch_begin (8 bytes):
    delta: i32, scale_factor: f32

pinch (12 bytes):
    delta: i32, scale_factor: f32, direction: u8 (0 = in, 1 = out), pad: [3]u8

three_finger_swipe_begin, three_finger_swipe (20 bytes):
    dx: i32, dy: i32, total_dx: i32, total_dy: i32,
    axis_locked: u8 (0 = none, 1 = horizontal, 2 = vertical),
    confidence: u8, pad: [2]u8

intent_hint (4 bytes):
    gesture: u8 (0 = two_finger_scroll, 1 = pinch, 2 = three_finger_swipe),
    axis: u8 (0 = none, 1 = horizontal, 2 = vertical, 3 = in, 4 = out),
    confidence: u8, pad: [1]u8
```

Largest payload is three_finger_swipe at 20 bytes. n_click at
16 bytes. 32-byte payload field gives headroom for future
gestures or field additions without a wire-format break.

The 40-byte total is 2.5x the size of MouseEventMsg, but
gestures are produced at much lower rates than raw motion
events (gestures: at most a handful per second; raw motion:
hundreds per second during a sweep). Bandwidth is a non-
issue.

### Routing: focused surface at emit time

Gesture events route to the client owning the focused surface
at the moment the gesture event is produced — the same rule
MouseEventMsg already follows. If focus changes mid-gesture
(e.g. during a drag sequence), subsequent events go to the
new focused surface. Continuity-of-focus during a gesture is
a Phase 4 polish concern, not Phase 2.4.

When no surface is focused, gesture events are dropped on the
floor without further effort. Same as MouseEventMsg today.

### Subscription: always-on, no opt-in for Phase 2.4

Clients always receive gesture events; clients that don't
care for them ignore the message kind. No HELLO opt-in flag,
no per-client filter.

Justification: gesture events are low-rate (tens per second
peak during active multi-touch); the cost of receiving and
discarding is negligible. Adding an opt-in mechanism is
premature complexity until a real client demonstrates a
latency or bandwidth concern.

The one exception worth noting now: `intent_hint` is
moderately high-rate (it fires every touch frame during
arbitration windows, so up to ~60 Hz per active touch).
Today's clients won't use these. The decision to send them
anyway is deliberate: it keeps the protocol small (no
filtering surface) and lets future clients (e.g. apps doing
predictive UI) consume them without protocol changes. If a
real cost surfaces, an opt-in flag is added in a backwards-
compatible way (default-on; clients flag default-off in
HELLO).

### Recogniser cardinality: one per Daemon

ADR 0016 said "one recogniser per session" but used "session"
in libsemainput's vocabulary, which conflicts with semadrawd
using "session" to mean "client connection". The right
cardinality is **one GestureRecognizer per Daemon instance**,
shared across all clients.

Justification: the recogniser's internal state is keyed on
input device_slot (per ADR 0016 Stage A). It's a function of
the physical input devices, not of clients. Two clients
seeing the same physical touch sequence (because focus passed
to the second mid-gesture) should produce one consistent
gesture stream, not two divergent recogniser states. One
recogniser per daemon achieves that.

### Recogniser lifecycle

Created during `Daemon.initCompositor` (alongside the
existing compositor init). Destroyed during `Daemon.deinit`.
Held as `Daemon.gesture_recognizer:
libsemainput.GestureRecognizer` (a value, not a pointer; the
library type is stack-shaped with allocator-borrowed lists).

### Recogniser feeding: side-channel of raw inputfs Events

The recogniser needs `device_slot: u16`, which is on the
inputfs `input.Event` but not on backend `MouseEvent` (which
gets translated and loses the slot). To feed the recogniser
without disrupting the existing MouseEvent/KeyEvent
plumbing, the drawfs backend gains a third buffer:

```zig
injected_inputfs_events: [DRAIN_BATCH]input.Event,
injected_inputfs_events_len: usize,
```

`InputfsInput.drain` appends to this buffer alongside
producing MouseEvent/KeyEvent. The drawfs backend exposes a
new vtable method `getInputfsEvents() []const input.Event`
analogous to `getMouseEvents`. The daemon iterates this
buffer in its main loop, translates each event to
`LibsemainputInput`, calls `gesture_recognizer.handleEvent`,
drains `nextOutput()` into `forwardGestureEvents`.

This is **side-channel additive**, not a replacement for the
existing typed event flow. Raw MouseEvent forwarding is
unchanged — the focused surface receives clicks and motion
exactly as today. The gesture stream is layered on top. The
duplication (each pointer event traverses the daemon main
loop twice, once as MouseEvent and once as input.Event) is
cheap; the main loop is not pointer-event-bound.

A future cleanup could collapse the two streams (have the
daemon receive only raw inputfs events and translate to
MouseEvent at the daemon edge instead of inside the
backend). That refactor is out of scope for Phase 2.4.

### Gesture event ordering vs raw events

For a given input sequence, raw events forward to the client
*before* any gesture they trigger. In wire-message order:

  1. `mouse_event` (pointer button down)
  2. `mouse_event` (pointer button up)
  3. `gesture_event` (n_click, count=2)  ← only on the
     second click within the n-click window

The daemon main loop processes inputfs events in the order
they were drained. For each event it (a) forwards the raw
MouseEvent if the dispatch produces one, (b) feeds the
recogniser, (c) drains and forwards any gesture outputs
produced. Since the recogniser only emits at the
end-of-action (e.g. n_click on button-up, drag_start once
the threshold is crossed), the raw event for the same
physical action lands first.

Clients should not rely on a strict ordering invariant
between raw and gesture streams beyond "gestures arrive
after the raw events that caused them in the same drain
batch." Cross-batch ordering depends on the daemon's main
loop iteration timing.

## Consequences

### Positive

  - Single MsgType keeps the protocol enum small (no 15-arm
    explosion).
  - Fixed-size 40-byte message is simple to (de)serialise;
    matches the convention of MouseEventMsg.
  - Side-channel feeding doesn't disturb existing raw event
    routing; Phase 2.4 is structurally additive.
  - One recogniser per daemon avoids cross-client divergence
    and keeps state cardinality matching the physical input
    cardinality.
  - 32-byte payload field has comfortable headroom for
    future gesture additions or field extensions without a
    wire-format break.

### Negative

  - Tagged-union payload requires per-gesture decode logic
    in every client that wants gesture support. That's the
    cost of avoiding 15 separate MessageKinds; the
    alternative (15 fixed structs) bloats the protocol. The
    decode logic is straightforward (switch on
    gesture_type, read payload bytes per layout).
  - intent_hint events are moderately high-rate. Sending
    them unconditionally to all clients is wasted work for
    clients that ignore them. Acceptable for Phase 2.4;
    revisit if a client demonstrably suffers.
  - Two iterations over the inputfs event batch in the
    daemon main loop (once for MouseEvent forwarding,
    once for recogniser feeding). Cheap but a measurable
    duplication; the future cleanup that collapses streams
    eliminates it.
  - Gesture events route by focused surface at emit time.
    Mid-gesture focus changes cause partial gesture
    delivery (e.g. drag_start to surface A, drag_move and
    drag_end to surface B). Surface A may be confused.
    Phase 4 can introduce gesture-grab semantics
    (whichever surface gets the begin event keeps the
    sequence) but Phase 2.4 doesn't need that complexity.

### Open question (deferred)

Should `intent_hint` events be opt-in via HELLO? Default
answer in this ADR: no, always-on. Revisit if a client
demonstrably suffers. The opt-in mechanism would be a small
addition to HELLO (one bit in a flags byte) and is
compatible with the always-on default.

## Implementation steps

  - **Phase 2.4.1: Protocol changes.** Add `gesture_event`
    to `MsgType`. Add `GestureEventMsg` struct with
    serialise/deserialise. Add a unit test for round-trip
    of each gesture variant. Land alone; clients still see
    no traffic on the new MsgType because semadrawd
    doesn't emit yet.

  - **Phase 2.4.2: Drawfs backend side-channel.** Add the
    `injected_inputfs_events` buffer to drawfs.zig. Modify
    `InputfsInput.drain` to append every drained
    `input.Event` to the buffer **before** calling
    `dispatch`. Placing the append in `drain` (not in
    `dispatch`) ensures touch and pen events reach the
    side-channel even though the existing typed-event
    `dispatch` path drops them via the `else => return`
    arm. Without that placement, touchscreen gestures
    (pinch, two-finger scroll, three-finger swipe) would
    never reach the recogniser. Add the
    `getInputfsEventsImpl` vtable function exposing a
    slice of raw events. The buffer drains every poll
    cycle, same as the typed buffers. semadrawd doesn't
    consume yet; the buffer fills and drains harmlessly.

  - **Phase 2.4.3: Recogniser ownership in semadrawd.**
    Add `gesture_recognizer:
    libsemainput.GestureRecognizer` to the `Daemon`
    struct. Init in `initCompositor`. Deinit in
    `deinit`. semadrawd build.zig adds
    `addImport("libsemainput", libsemainput_mod)` to its
    exe.

  - **Phase 2.4.4: Feed and forward.** In the main loop,
    after `getMouseEvents`/`getKeyEvents`, call
    `comp.getInputfsEvents()`, translate each event to
    `LibsemainputInput`, feed `gesture_recognizer.handleEvent`,
    then drain `gesture_recognizer.nextOutput` and call
    `forwardGestureEvents` (analogous to
    `forwardMouseEvents`). Translation logic mirrors the
    daemon shim's `translateSemanticToLib` but takes
    `input.Event` directly (no SemanticEvent
    intermediate); the device_slot is on the input.Event,
    no Aggregator lookup needed.

  - **Phase 2.4.5: forwardGestureEvents.** New daemon
    function: looks up focused surface (same as
    forwardMouseEvents), builds a `GestureEventMsg` per
    `LibsemainputOutput`, sends to the surface owner.
    Includes the per-variant payload pack logic.

Phase 2.5 verifies end-to-end: do a click, see a
mouse_event arrive at the client; do a double-click, see a
mouse_event then a gesture_event with n_click count=2.

## References

  - ADR 0016 — libsemainput extraction.
  - `semadraw/src/ipc/protocol.zig` — wire format for
    existing event messages (MouseEventMsg, KeyEventMsg).
  - `semadraw/src/backend/inputfs_input.zig` — current
    inputfs reader; gains the side-channel buffer in
    Phase 2.4.2.
  - `semadraw/src/daemon/semadrawd.zig` — daemon main
    loop; gains the recogniser and gesture forwarding
    in Phase 2.4.3-5.
  - `shared/src/input.zig` — inputfs event ring format;
    `input.Event` carries device_slot which the
    recogniser needs.
  - `semainput/libsemainput/libsemainput.zig` — the
    recogniser this ADR connects to clients.
