# ADR 0017-rev2: Gesture event wire format and routing

## Status

Proposed. Supersedes ADR 0017.

Drafted during AD-2a Phase 2.4 design pause on 2026-05-04, after a
design pass surfaced four open questions that ADR 0017 had answered
implicitly: who consumes gesture events, where the recogniser lives
architecturally, whether gestures are instants or intervals, and how
gesture timestamps relate to chronofs. ADR 0017 committed to a 40-byte
tagged-union wire format before those questions were settled. Rev2
records the answers and revises the wire format accordingly.

## Relationship to ADR 0017

Rev2 supersedes ADR 0017 in full. ADR 0017 should be marked superseded
with a pointer to this document; its content remains as historical
record of the first design pass.

What changes from ADR 0017:

  - **MsgType value**: `gesture_event` is `0x9030`, not `0x9003`. The
    `0x9003` slot is taken by `EVT_SURFACE_PRESENTED_REGION` in
    `shared/protocol_constants.json`'s drawfs_protocol events block.
    `0x9030` is the first slot collision-free across both
    semadraw_ipc and drawfs_protocol event ranges. The broader
    namespace-drift question is filed as a separate AD-note; rev2
    does not attempt to resolve it.
  - **gesture_type widens** from `u8` (tag in a tagged-union payload)
    to `u32` (flat field). Justification below.
  - **Wire format changes** from 40-byte tagged-union to a 32-byte
    flat header plus a per-gesture-type payload. Total size is
    gesture-type dependent rather than fixed.
  - **Two timestamps** (`t_begin`, `t_current`) replace the absent
    timestamp in the original. Both are chronofs nanosecond
    timestamps. Justification below.
  - **Phase field** added to express interval semantics
    (begin/update/end/cancel). Original treated each gesture as a
    point event.
  - **Recogniser placement** is made explicit: gesture recognition is
    a semadrawd-owned service for now. ADR 0017 implied this through
    its routing rules but did not state it as an architectural
    commitment.

What carries forward unchanged from ADR 0017:

  - Routing by focused surface at emit time.
  - Subscription is always-on with no opt-in for Phase 2.4.
  - One recogniser per Daemon, shared across clients.
  - Recogniser lifecycle tied to `Daemon.initCompositor`/`deinit`.
  - Side-channel feeding via `injected_inputfs_events` buffer in the
    drawfs backend.
  - Gesture event ordering: raw events forward before the gestures
    they trigger within the same drain batch.
  - Phase 2.4.1–2.4.5 implementation step structure.

## Context

The four semantic questions ADR 0017 left implicit are now answered:

**Who consumes gesture events.** semadrawd is the first consumer
(for system gestures: three-finger swipe to switch desktops, pinch
to expose, etc.) and forwards app-level gestures to the focused
surface's owning client. This is the macOS NSGestureRecognizer model
adapted to a Wayland-shaped world: the compositor arbitrates first,
then forwards.

**Where the recogniser lives.** Gesture recognition is a
semadrawd-owned service for now. The recogniser instance lives in
the `Daemon` struct, runs in semadrawd's main loop, and is the
single producer of gesture events for the system. The "for now"
preserves the option of splitting later if compositor-mediated and
app-mediated gestures grow into different concerns; rev2 commits
only to the current iteration.

This commitment closes the service-vs-library question that was
open during ADR 0017. The libsemainput library (per ADR 0016 and
AD-2a Phase 2) is the recogniser's *implementation*, but the
recogniser as a *system component* is a service that semadrawd
owns. Clients consume gesture events; they do not run their own
recognisers.

**Are gestures instants or intervals.** Intervals. A gesture is a
time-extended object with a begin time, ongoing updates, and an end
(or cancellation). The wire format expresses this through a `phase`
field and two timestamps.

**How do gesture timestamps relate to chronofs.** Every gesture
event carries two chronofs nanosecond timestamps: `t_begin` (the
chronofs time of the input event that triggered the gesture's begin
phase) and `t_current` (the chronofs time of the input event that
triggered *this* phase transition). For `phase = begin`, `t_begin
== t_current`. For phase transitions with no triggering input event
(long-press timeout, gesture cancellation by inactivity),
`t_current` is the chronofs time at which the recogniser detected
the transition.

This timestamp anchoring decouples gesture timing from recogniser
latency. A recogniser that takes 5ms to decide a tap has occurred
still emits the tap with the timestamp of the finger-up input
event, not the decision moment. Clients reasoning about
input-to-photon latency, animation synchronization, or replay get
the same timing data they would compute themselves if doing
recognition locally.

## Decision

### Wire format: flat header plus per-type payload

A new MsgType:

```zig
gesture_event = 0x9030,
```

The message is a 32-byte flat header followed by a per-gesture-type
payload. Total wire size is `32 + payload_size(gesture_type)` bytes.

Header layout (32 bytes, little-endian):

```
offset  size  field           type     notes
   0     4    surface_id      u32      target surface (focused at emit time)
   4     4    gesture_type    u32      see GestureType enum below
   8     1    phase           u8       0=begin, 1=update, 2=end, 3=cancel
   9     1    finger_count    u8       1..N; 0 reserved for future use
  10     2    _reserved       [2]u8    must be zero on emit; ignored on decode
  12     4    flags           u32      see GestureFlags below
  16     8    t_begin         u64      chronofs ns; gesture begin time
  24     8    t_current       u64      chronofs ns; phase-transition trigger time
```

Header rationale:

  - `surface_id`, `gesture_type`, `phase` are always required for
    routing and dispatch; they go first.
  - `finger_count` is in the header rather than the payload because
    it is useful for logging and triage without payload parsing,
    and it is uniform across all gesture types.
  - `flags` carries modifier state (ctrl/alt/shift/meta) and any
    future header-level booleans. Layout matches MouseEventMsg's
    modifier convention but widens to u32 for headroom.
  - The two timestamps are u64-aligned at offsets 16 and 24, which
    makes the header naturally 8-byte aligned end-to-end.

```zig
pub const GestureType = enum(u32) {
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
    _,
};

pub const GesturePhase = enum(u8) {
    begin = 0,
    update = 1,
    end = 2,
    cancel = 3,
    _,
};

pub const GestureFlags = packed struct(u32) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    meta: bool = false,
    _: u28 = 0,
};
```

Payload layouts (all little-endian, packed from offset 0 of the
payload region; payload follows the 32-byte header directly):

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
    delta: i32, scale_factor: f32, direction: u8 (0=in, 1=out), pad: [3]u8

three_finger_swipe_begin, three_finger_swipe (20 bytes):
    dx: i32, dy: i32, total_dx: i32, total_dy: i32,
    axis_locked: u8 (0=none, 1=horizontal, 2=vertical),
    confidence: u8, pad: [2]u8

intent_hint (4 bytes):
    gesture: u8 (0=two_finger_scroll, 1=pinch, 2=three_finger_swipe),
    axis: u8 (0=none, 1=horizontal, 2=vertical, 3=in, 4=out),
    confidence: u8, pad: [1]u8
```

Largest payload is `three_finger_swipe` at 20 bytes, giving a max
total wire size of 52 bytes. Smallest is the zero-payload variants
at 32 bytes total (header only). MouseEventMsg is 16 bytes for
comparison; gesture events are 2x–3.25x its size, which is fine
given gesture rates are at most tens per second versus hundreds per
second for raw motion.

### Per-gesture-type payload sizing

Variable-size payloads. The `MsgHeader.length` field already carries
the payload byte count, so the receiver knows how many bytes to
read after the GestureEventMsg header. No payload_length field is
duplicated inside GestureEventMsg.

The alternative (fixed 32-byte payload sized to the largest variant,
with smaller variants padded) was considered and rejected: it
inflates the on-the-wire size of common gestures (a tap becomes 64
bytes instead of 44) for a serialization simplicity that the
existing length-prefixed framing already provides.

### Two-timestamp encoding rule

`t_begin` is the chronofs nanosecond timestamp of the input event
that triggered the gesture's `phase = begin` event. It is constant
across all subsequent events in the gesture (update, end, cancel
all carry the same `t_begin` as the begin event did).

`t_current` is the chronofs nanosecond timestamp of the input event
that triggered *this* phase transition. Specifically:

  - For `phase = begin`: `t_current == t_begin` (the begin event's
    triggering input is the same input). This overloading is
    accepted as the cost of the uniform shape; clients that want
    "is this the first event of the gesture" should check `phase`,
    not compare timestamps.
  - For `phase = update`: `t_current` is the timestamp of the most
    recent contributing input event.
  - For `phase = end`: `t_current` is the timestamp of the input
    event that ended the gesture (e.g. the finger-up).
  - For `phase = cancel`: `t_current` is the timestamp of the input
    event that caused the cancellation, if any. For
    inactivity-driven cancellation (no triggering input),
    `t_current` is the chronofs time at which the recogniser
    detected the timeout. The same rule applies to long-press
    timeout firings: if no input triggered the transition,
    `t_current` is the recogniser's detection time.

Rationale for "input event time, not emission time": gesture timing
should reflect physical reality, not recogniser implementation
latency. A 5ms recogniser delay should not appear in client-visible
timestamps. Clients comparing `t_current` to a frame timestamp or
to other input timestamps get directly comparable values.

### Routing: focused surface at emit time

(Unchanged from ADR 0017.)

Gesture events route to the client owning the focused surface at
the moment the gesture event is produced — the same rule
MouseEventMsg follows. If focus changes mid-gesture (e.g. during a
drag sequence), subsequent events go to the new focused surface.
Continuity-of-focus during a gesture is a Phase 4 polish concern,
not Phase 2.4.

When no surface is focused, gesture events are dropped on the
floor without further effort.

System gestures intercepted by semadrawd (three-finger swipe to
switch desktops, four-finger pinch to expose) do not forward to
clients at all; semadrawd handles them and the gesture stops at
the daemon. The mechanism for semadrawd to consume its own
recogniser's output before forwarding is part of Phase 2.4.5
(`forwardGestureEvents` checks for system-gesture types and
short-circuits forwarding for those).

### Subscription: always-on, no opt-in for Phase 2.4

(Unchanged from ADR 0017.)

Clients always receive gesture events; clients that don't care
ignore the message kind. The `intent_hint` high-rate exception
applies as documented in 0017.

### Recogniser cardinality: one per Daemon

(Unchanged from ADR 0017, including the correction of ADR 0016's
"per session" wording.)

### Recogniser lifecycle

(Unchanged from ADR 0017.)

### Recogniser feeding: side-channel of raw inputfs Events

(Unchanged from ADR 0017.)

### Gesture event ordering vs raw events

(Unchanged from ADR 0017.)

### Delivery channel

Push over the existing semadraw client connection. Each gesture
event is a `gesture_event` message sent on the same wire as
`mouse_event` and `key_press`.

The chronofs-ring delivery alternative — gesture events written to
a ring under `/var/run/sema/gesture/` and read by clients that
opt-in — was considered and deferred. It would be a more
"UTF-native" fit (state observable as data, replay for free,
multiple consumers without per-client wire traffic), but it is a
larger architectural change than Phase 2.4 needs and the
service-shaped model with one known consumer set (clients via
existing connections) does not yet require it. If gesture
recognition later splits into multiple producers, or if
introspection and replay become real client requirements, the
chronofs-ring alternative can be added alongside push delivery
without breaking the existing wire format.

## Consequences

### Positive

  - Single MsgType keeps the protocol enum small.
  - Flat header makes routing and dispatch uniform; clients can
    decode and route on `surface_id`/`gesture_type`/`phase` without
    parsing payload.
  - Variable-size payload eliminates wasted bytes on common
    gestures.
  - Two-timestamp interval semantics match the underlying reality
    of gesture lifecycles; clients no longer have to reconstruct
    intervals from instants.
  - Chronofs-anchored timestamps keep gesture timing comparable
    with frame and audio timing across the system.
  - Service-as-recogniser commitment makes the architecture
    explicit; the "for now" leaves room for future evolution
    without locking it in.
  - Side-channel feeding doesn't disturb existing raw event
    routing; Phase 2.4 remains structurally additive.
  - 32-byte header with u64-aligned timestamps means no platform
    has alignment-driven encoding surprises.
  - Future gesture additions add new payload variants without
    perturbing the header.

### Negative

  - Variable-size messages are slightly more complex to parse than
    fixed-size; clients must read the header length before reading
    the payload. The existing `MsgHeader.length` field already
    provides this, so the cost is one extra dispatch step.
  - Tagged decode logic remains: each gesture-type-aware client
    needs a switch on `gesture_type` to interpret the payload.
    This is unchanged from ADR 0017 and is the cost of avoiding 15
    separate MessageKinds.
  - `t_current == t_begin` on `phase = begin` events is a small
    semantic overloading. Documented; clients that want "is this
    the first event" check `phase`.
  - Inactivity-driven phase transitions (long-press fires,
    timeout cancels) carry a `t_current` that is the recogniser's
    detection time rather than a triggering input time. This is
    the only case where `t_current` is not strictly an input
    timestamp; documented.
  - Two iterations over the inputfs event batch in the daemon main
    loop (once for MouseEvent forwarding, once for recogniser
    feeding). Cheap but a measurable duplication; the future
    cleanup that collapses streams eliminates it.
  - Mid-gesture focus changes still cause partial gesture
    delivery to multiple surfaces. Phase 4 gesture-grab semantics
    address this; Phase 2.4 does not.

### Open question (deferred)

  - Should `intent_hint` events be opt-in via HELLO? Default
    answer: no, always-on. Revisit if a client demonstrably
    suffers.
  - Namespace drift between semadraw_ipc and drawfs_protocol event
    ranges. The `0x9030` choice in this ADR avoids the immediate
    collision but does not resolve the underlying drift. A
    separate AD-note should propose either formal namespace
    separation (rename one side's constants to make collisions
    impossible) or unification under a shared registry. Rev2 does
    not block on this resolution.
  - Future split of compositor-mediated gestures from app-mediated
    gestures. The "for now" in the recogniser-as-service
    commitment preserves this option. No specific trigger
    identified.
  - Chronofs-ring delivery as an alternate or supplementary
    transport. Deferred until a real consumer requires
    introspection or replay semantics.

## Implementation steps

(Phase structure unchanged from ADR 0017; sub-step content updated
for the rev2 wire format.)

  - **Phase 2.4.1: Protocol changes.** Add `GESTURE_EVENT = 0x9030`
    to `shared/protocol_constants.json` under
    `drawfs_protocol.message_types.events`. Regenerate
    `semadraw/src/ipc/protocol.zig` MsgType enum. Add
    `GestureType`, `GesturePhase`, `GestureFlags`, and
    `GestureEventMsg` types. Add per-variant payload pack/unpack
    helpers. Add unit tests for header round-trip and for each
    payload variant round-trip. Land alone; semadrawd doesn't
    emit yet.

  - **Phase 2.4.2: Drawfs backend side-channel.** (Unchanged from
    ADR 0017.)

  - **Phase 2.4.3: Recogniser ownership in semadrawd.**
    (Unchanged from ADR 0017.)

  - **Phase 2.4.4: Feed and forward.** (Unchanged from ADR 0017,
    with the addition that translation from `LibsemainputOutput`
    to `GestureEventMsg` populates the new header fields:
    `phase`, `t_begin`, `t_current`, `flags`, `finger_count`. The
    recogniser must expose these on its outputs; if it doesn't
    yet, that's a libsemainput change to be sequenced before
    Phase 2.4.5.)

  - **Phase 2.4.5: forwardGestureEvents.** New daemon function as
    in ADR 0017, with the addition of system-gesture
    short-circuiting: gesture types that semadrawd handles itself
    (three-finger swipe variants, four-finger pinch if added)
    are consumed by semadrawd's compositor logic and not
    forwarded to clients. The list of system gestures is
    configurable; for Phase 2.4 the default is empty (all
    gestures forward to clients) with system-gesture interception
    deferred to a follow-up sprint.

Phase 2.5 verifies end-to-end as in ADR 0017.

## Libsemainput surface impact

The recogniser today (per ADR 0016 Phase 2 extraction) emits
`LibsemainputOutput` values that name the gesture type and carry
gesture-specific data. Rev2 requires the output to additionally
carry:

  - `phase: GesturePhase` (or equivalent — current types may
    encode begin/update/end implicitly via separate gesture types
    like `pinch_begin`/`pinch`/`pinch_end`; reconciliation between
    the implicit-via-type encoding and the explicit-phase
    encoding is a libsemainput question, not an ADR question).
  - `t_begin: u64` and `t_current: u64` chronofs nanosecond
    timestamps populated from the triggering `input.Event`s.
  - `flags: u32` modifier state at the triggering input event.
  - `finger_count: u8`.

If the existing libsemainput output struct doesn't carry these,
that's a Phase 2.4.4 prerequisite. The change is additive (new
fields on existing structs) and should not require ADR 0016
revision.

## References

  - ADR 0016 — libsemainput extraction.
  - ADR 0017 — original gesture event wire format and routing
    (superseded by this document).
  - `semadraw/src/ipc/protocol.zig` — wire format for existing
    event messages.
  - `semadraw/src/backend/inputfs_input.zig` — inputfs reader;
    gains the side-channel buffer in Phase 2.4.2.
  - `semadraw/src/daemon/semadrawd.zig` — daemon main loop;
    gains the recogniser and gesture forwarding in Phase 2.4.3-5.
  - `shared/src/input.zig` — inputfs event ring format.
  - `shared/protocol_constants.json` — canonical MsgType
    registry; `GESTURE_EVENT = 0x9030` lands here in Phase 2.4.1.
  - `semainput/libsemainput/libsemainput.zig` — the recogniser
    this ADR connects to clients.
  - `docs/Thoughts.md` — chronofs design, source of nanosecond
    timestamp convention.
  - BACKLOG.md AD-2a — gesture recogniser placement and
    semainputd retirement; rev2 commits to the service-shaped
    answer.

## Addendum 2026-05-04: t_begin removed from wire format

A design pause during AD-2a Phase 2.4.4 layering surfaced that
the two-timestamp wire format (t_begin, t_current) couples the
recogniser to wire-protocol shape in a way that cannot be
sustained as the protocol evolves. This addendum removes
t_begin from GestureEventMsg, reducing the header from 32
bytes to 24 bytes and committing the wire to a single
chronofs nanosecond timestamp per event.

### What changes

GestureEventMsg drops t_begin. The header layout becomes:

```
offset  size  field           type     notes
   0     4    surface_id      u32      target surface (focused at emit time)
   4     4    gesture_type    u32      see GestureType enum
   8     1    phase           u8       0=begin, 1=update, 2=end, 3=cancel
   9     1    finger_count    u8       1..N; 0 reserved for future use
  10     2    _reserved       [2]u8    must be zero on emit; ignored on decode
  12     4    flags           u32      modifier state at the triggering input
  16     8    t_current       u64      chronofs ns; phase-transition trigger
```

GestureEventMsg.SIZE becomes 24 bytes (was 32). Total wire
size including per-gesture-type payload is 24..44 bytes (was
32..52).

The "phase=begin t_begin == t_current" invariant from the
main body is now vacuous and removed: there is no t_begin to
compare. Phase still expresses interval semantics; clients
that want the begin time observe the begin event (where
t_current is the begin time by definition) and remember it
locally.

### Why

The decision turns on what model the wire is implementing.
Two coherent models exist:

  - **Materialised gesture object on the wire.** Each event
    carries enough state to fully reconstruct the gesture
    independently. Late joiners can interpret an in-flight
    gesture from any single event. t_begin makes sense
    here.
  - **Event-stream wire.** The wire is a log of events; each
    event is self-sufficient at the moment it occurs;
    clients that want gesture-as-object accumulate state
    themselves. t_begin is redundant here because the
    begin event already carried that timestamp, and any
    client that cares observed it.

Phase 2.4 is event-stream-shaped. Delivery is push over the
existing semadraw connection; clients connect and from that
moment forward see new events. There is no late-joiner
case where a client receives an in-flight `pinch` (update)
event without having seen the prior `pinch_begin`. So
t_begin's only function is to let clients avoid storing a
single u64 of state per active gesture, which is not a
function the wire format should serve.

The chronofs-ring delivery alternative (deferred per the
main body's open questions) would change this. A client
reading from a ring may join in the middle of a gesture and
need t_begin to interpret it. If chronofs-ring delivery is
adopted, t_begin (or an equivalent gesture-anchor
timestamp) returns. Until then, the wire stays minimal.

### Architectural consequence

The absence of t_begin enforces a useful invariant: the
recogniser does not own wire-protocol shape. With t_begin
present, the recogniser would need to track gesture-begin
timestamps per device_slot to populate it, putting
recogniser-internal state into wire format and creating a
coupling that drifts when the wire format evolves. Without
t_begin, the recogniser produces variant + finger_count
only; the daemon attaches t_current from the input event
that triggered each phase transition, and phase from a
mechanical lookup on the variant. Three-layer split:

  - Input layer (input.Event, LibsemainputInput): owns
    timestamps, modifier state, device_slot.
  - Recogniser layer (LibsemainputOutput): owns gesture
    semantics and finger_count. No timestamps, no flags,
    no lifecycle fields.
  - Daemon layer (forwardGestureEvents): owns wire
    protocol shape — derives phase from variant, attaches
    t_current and modifier flags at emit time.

This split was implicit in rev2's recommendation. Removing
t_begin makes it explicit and removes the cross-layer
coupling t_begin would have required.

### Library and daemon impact (revised from main body)

The "Libsemainput surface impact" section in the main body
called for t_begin, t_current, phase, finger_count, and
flags on every output variant. With this addendum:

  - Output variants gain only `finger_count: u8`,
    populated from the recogniser's `contacts.items.len`
    at gesture-emit time.
  - Input variants are unchanged from their current shape
    (already carry ts_ns, ts_audio_samples, device_slot;
    flags would be a separate future addition not needed
    for Phase 2.4).
  - Daemon attaches t_current from the most recent input
    event timestamp captured during the feed loop, flags
    from the existing last_modifiers tracking, phase from
    a variant-to-phase lookup.

This shrinks the libsemainput change from five new fields
across ~7 structs to one new field across ~7 structs.

### What does NOT change

  - GESTURE_EVENT MsgType remains 0x9030.
  - Routing by focused surface at emit time.
  - Subscription always-on for Phase 2.4.
  - One recogniser per Daemon.
  - Side-channel feeding via injected_inputfs_events.
  - Phase 2.4.1's protocol implementation has already
    landed with the two-timestamp shape; Phase 2.4.4
    will include the protocol.zig edit to remove
    t_begin as part of the implementation sequence
    (see commit ordering in BACKLOG.md AD-2a).

References: discussion in conversation with Vic during
2026-05-04 design pause; contemporaneous notes in
project chat.
