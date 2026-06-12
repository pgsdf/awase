# 0016 libsemainput extraction: scope and contracts

## Status

Proposed.

Amended 2026-05-06 during Phase 2.3 implementation: two scope
findings surfaced on close reading of `semainput/src/gesture.zig`
that the original Decision section did not anticipate. Both are
folded into the relevant sections below; the amendments are
inline rather than appended.

Change 1: the output union grows from 10 to 15 variants.
gesture.zig today emits `intent_hint`, `scroll_begin`,
`scroll_end`, `three_finger_swipe_begin`, and
`three_finger_swipe_end` in addition to the 10 originally listed.
These are recogniser-level events (gesture bracketing and early
prediction), not daemon-specific signals; they belong in
`LibsemainputOutput`. See "Output contract" below.

Change 2: `device_aggregate.zig` does NOT move to the library.
The original Decision said it would. On close reading, the
Aggregator is fundamentally evdev-era — it imports
`device_classify.zig` and `device_identity.zig`, and its job is
translating `/dev/input/event*` paths into stable device names
by talking to the classifier. That whole concern is moot in the
inputfs world: events arrive with a `device_slot: u16` from the
inputfs ring; we just key per-device state on the slot directly.
The library has no need for the Aggregator. It stays in
`semainput/src/` alongside the rest of the daemon's evdev
pipeline and is deleted in Phase 3 with semainputd. See
"Dependency surface" below.

## Context

AD-2a Phase 1 (cutover) completed and was verified on bare metal
2026-05-06. semadrawd now reads input directly from the inputfs
event ring at `/var/run/sema/input/events`; semainputd is no
longer in the runtime input path.

Phase 2 of AD-2a is "promote `gesture.zig` (1,044 lines) into a
userland library `libsemainput`, consumed by clients and by
semadrawd." PHASE_1.md and BACKLOG describe this as "mostly
mechanical file moves" — that framing is wrong on inspection.
Reading `semainput/src/gesture.zig` reveals four design questions
that need explicit answers before code:

1. **Library input contract.** What events does the library
   accept? Today `gesture.handleEvent` takes
   `semantic.SemanticEvent` (a tagged union with stringly-typed
   fields like `button: []const u8 = "left"`). That shape is
   evdev-era — convenient for semainputd reading evdev nodes,
   awkward for callers who already have typed events from
   inputfs.

2. **Library output contract.** Today `gesture.zig` emits
   gesture events as JSON-lines to stdout via
   `globals.session_hex` / `globals.nextSeq` /
   `globals.readAudioSamples`. That works for a daemon whose
   sole purpose is producing JSON for downstream readers; it
   does not work for a library whose callers (semadrawd, client
   apps) want structured events to consume directly.

3. **Dependency surface.** `gesture.zig` imports
   `semantic.zig`, `device_aggregate.zig`, and `globals.zig`.
   `semantic.zig` is small (25 lines, the event union);
   `device_aggregate.zig` is medium (297 lines, multi-touch
   contact tracking); `globals.zig` is daemon infrastructure.
   What follows the library, what stays in semainputd until
   Phase 3, and what gets new homes?

4. **Consumption model.** PHASE_1.md says "After Phase 2,
   semadrawd consumes gesture events from libsemainput (which
   itself reads from the inputfs ring and from semadrawd's
   focus state)." That sentence is internally inconsistent: a
   library can't both "read from the inputfs ring" (which would
   put per-client recognisers in competition for events) and
   be "consumed by clients" (which implies clients call into
   it). Resolve which is correct.

## Decision

The library does no IO. It accepts typed events as input and
returns typed events as output. The compositor (semadrawd) is
the sole reader of the inputfs ring; it feeds the recogniser
and routes the recogniser's output to clients.

Concretely:

### Input contract

`libsemainput` accepts a new event type `LibsemainputInput`,
defined in the library and shaped to match the events
inputfs publishes (per `shared/INPUT_EVENTS.md`):

```zig
pub const LibsemainputInput = union(enum) {
    pointer_motion: struct { device_slot: u16, x: i32, y: i32, dx: i32, dy: i32, buttons: u32, ts_ns: u64 },
    pointer_button: struct { device_slot: u16, x: i32, y: i32, button: u32, pressed: bool, ts_ns: u64 },
    pointer_scroll: struct { device_slot: u16, dx: i32, dy: i32, ts_ns: u64 },
    touch_down:     struct { device_slot: u16, contact_id: u32, x: i32, y: i32, ts_ns: u64 },
    touch_move:     struct { device_slot: u16, contact_id: u32, x: i32, y: i32, ts_ns: u64 },
    touch_up:       struct { device_slot: u16, contact_id: u32, ts_ns: u64 },
    // No keyboard events; the recogniser does not consume them today.
};
```

`device_slot` is the inputfs ring's `device_slot` field. The
recogniser keys per-device state on this slot. (gesture.zig
today keys on `device_name: []const u8` derived from the
daemon's Aggregator, which doesn't exist in the library; see
"Dependency surface" below.)

`LibsemainputOutput` does not carry `device_slot` — gesture
events are conceptually per-recogniser, and a recogniser
instance is per-session in semadrawd. If a caller needs to
correlate a gesture back to a specific device, it owns that
mapping outside the library.

The compositor is responsible for translating from inputfs's
wire format (`shared/src/input.zig`'s `Event` struct) into this
type. The translation is straightforward — the library's input
type is the inputfs event with its session_id stripped (the
library doesn't need it) and pointer button state simplified.

### Output contract

`libsemainput` returns a `LibsemainputOutput` value (or null) per
`handleEvent` call, never writes to stdout, never opens files,
never forms JSON. Caller decides what to do with the output:

```zig
pub const LibsemainputOutput = union(enum) {
    n_click:           struct { button: u32, count: u32, x: i32, y: i32 },
    drag_start:        struct { x: i32, y: i32 },
    drag_move:         struct { x: i32, y: i32 },
    drag_end:          struct { x: i32, y: i32 },
    tap:               struct { x: i32, y: i32 },

    // Two-finger scroll: bracketed by begin/end with continuous
    // deltas in between.
    scroll_begin:      struct {},
    two_finger_scroll: struct { dx: i32, dy: i32 },
    scroll_end:        struct {},

    // Pinch: scale_factor is the cumulative scale; delta is the
    // step since last pinch event. Bracketed by begin/end.
    pinch_begin:       struct { scale: f32, scale_factor: f32 },
    pinch:             struct { scale: f32, scale_factor: f32, delta: i32 },
    pinch_end:         struct {},

    // Three-finger swipe: bracketed by begin/end. axis_locked
    // reflects the recogniser's decision.
    three_finger_swipe_begin: struct { dx: i32, dy: i32, axis_locked: AxisLock },
    three_finger_swipe:       struct { dx: i32, dy: i32, axis_locked: AxisLock },
    three_finger_swipe_end:   struct {},

    // Early prediction signal emitted while a gesture is still
    // arbitrating. Carries the recogniser's confidence (0-100) and
    // the axis it is leaning toward. Optional for callers; some
    // may ignore intent hints entirely.
    intent_hint:       struct { gesture: Kind, axis: Axis, confidence: u8 },

    pub const AxisLock = enum { none, horizontal, vertical };
    pub const Axis     = enum { none, horizontal, vertical, in, out };
    pub const Kind     = enum { two_finger_scroll, pinch, three_finger_swipe };
};
```

15 variants total. The `_begin` / `_end` events bracket continuous
gestures so callers can match begin to end without inspecting a
gesture-state machine of their own. `intent_hint` is an early
prediction signal that today only fires for two-finger scroll,
pinch, and three-finger swipe — the gestures with arbitration
windows.

A single input event may produce zero, one, or (rarely) two
output events; signature is `pub fn handleEvent(...) !?LibsemainputOutput`
with the option for callers needing a richer signature later.

For the multi-output case (e.g. drag_end + tap on a fast tap),
the recogniser queues the second event internally and the next
caller invocation produces it. This keeps the API straight
without a list type or callback.

### Dependency surface

One file relocates from `semainput/src/` into the new library
location `semainput/libsemainput/`:

  - `gesture.zig` (1,044 lines) — the recogniser core. Loses
    the daemon-era `emitGestureEvent` JSON-emit method;
    callers now consume returned `LibsemainputOutput` values.
    Per-device state is re-keyed from `device_name: []const u8`
    (which required the Aggregator to derive) to `device_slot:
    u16` (which arrives in every inputfs event). All sites
    that previously called `aggregator.findForPath(e.path)`
    or stored `device_name` on `ContactState` /
    `DeviceGestureState` / `ClickHistory` are rewritten in
    terms of `device_slot`.

`device_aggregate.zig` (297 lines) does NOT move. On close
inspection, the Aggregator imports `device_classify.zig` and
`device_identity.zig` and exists to translate
`/dev/input/event*` paths into stable device names by talking
to the classifier — fundamentally evdev-era plumbing. In the
inputfs world, events arrive with a `device_slot: u16` from
the kernel; we have no need for path-to-name translation.
gesture.zig's recogniser used the Aggregator only for
`findForPath` — to derive a per-device key. Keying directly
on `device_slot` removes the dependency. The Aggregator stays
in `semainput/src/` alongside the rest of the daemon's
evdev-era pipeline (classifier, identity, event_queue, evdev
adapter) and is deleted in Phase 3.

`semantic.zig` (25 lines) does NOT move. It's the daemon's
internal event type and is replaced by `LibsemainputInput`
above. Phase 3 deletes `semantic.zig` along with the rest of
semainputd's internal pipeline.

`globals.zig` (~60 lines) does NOT move. It's daemon
infrastructure (session token, audio clock reader, JSON-line
writer state). The library has no need of it; Phase 3 deletes
it along with semainputd.

### Consumption model

semadrawd is the canonical caller. The flow is:

```
inputfs event ring          (kernel writes events)
    |
    v
semadrawd's inputfs_input.zig drain
    |
    | ring drain produces one or more
    | translated events
    v
semadrawd translates inputfs.Event -> LibsemainputInput
    |
    v
libsemainput.handleEvent(input)  -> ?LibsemainputOutput
    |
    | gesture event (or null)
    v
semadrawd routes to focused client via existing protocol
```

semadrawd holds one `GestureRecognizer` per session (or per
connected client; see "Open question" below). The recogniser's
state is per-instance — multiple clients with multiple
recognisers do NOT compete for inputfs events because semadrawd
is the only ring reader; it feeds each recogniser according to
session/focus routing.

Clients that want gesture recognition for their own purposes
(e.g. a drawing app receiving raw pointer events and detecting
its own pinch) link `libsemainput` and call it the same way
semadrawd does, against pointer events they receive from
semadrawd via the existing client protocol. Their input is
already-routed, already-typed; the library doesn't need to
know whether its caller is the compositor or a client.

This resolves PHASE_1.md's internally-inconsistent description.
The library does not read the inputfs ring. The compositor
reads the ring; the library is a function the compositor (and
clients, optionally) calls per event.

## Consequences

### Positive

  - **Clean API.** `LibsemainputInput` and `LibsemainputOutput`
    are typed unions, no stringly-typed field abuse, no JSON
    formatting in the library, no IO.
  - **No competition for inputfs events.** Compositor remains
    the sole ring reader; per-client recognisers in clients
    consume events that the compositor has already routed to
    them.
  - **Phase 3 deletion footprint shrinks correctly.**
    `semantic.zig`, `globals.zig`, and the entire stdout
    JSON-emit path go away with the daemon. The library
    inherits only what genuinely belongs in user code.

### Negative

  - **Caller-side translation overhead.** semadrawd's
    `inputfs_input.zig` already produces `backend.MouseEvent`
    and `backend.KeyEvent` types for the rest of semadrawd; it
    will additionally need to produce `LibsemainputInput` for
    the recogniser. That's a second derivative of the same
    inputfs event. Two options:

    (a) Recogniser sits before the existing translation, so
        the inputfs.Event flows in once (split into one path
        for the recogniser, another for the existing
        translation to backend.MouseEvent). Cleanest.

    (b) Recogniser sits after, accepting backend.MouseEvent.
        Library type becomes backend-coupled, which is
        backward — the library should not depend on a
        compositor's internal types.

    Recommend (a). The recogniser doesn't depend on the
    compositor's MouseEvent / KeyEvent shapes; it only needs
    the inputfs-shaped data. So `inputfs_input.zig`'s drain
    fans out: one branch translates to the existing backend
    types for the focus/routing/protocol path, the other
    branch translates to LibsemainputInput for the
    recogniser.

  - **Ordering subtlety in semadrawd.** The recogniser produces
    gesture events as a *consequence* of pointer events; both
    need to reach the client in some order. If the client gets
    `pointer_button:press` followed by `n_click:1` for the same
    physical click, that's redundant (and `n_click:1` is
    typically equivalent to `pointer_button:press +
    pointer_button:release`). Decide what the client
    protocol's gesture-event delivery looks like: either route
    only gestures (suppressing the underlying pointer events
    when a gesture fires), or route both and let the client
    pick. PHASE_1.md does not address this; it's a Phase 2
    follow-up after the library lands but before semadrawd
    actually consumes gesture output.

  - **No keyboard gesture support today.** `gesture.zig` only
    handles touch and mouse-button events. Keyboard sequences
    (chorded shortcuts, sticky-keys, key-repeat policy) are
    out of scope for libsemainput today and remain wherever
    they live now (mostly in client code). This isn't a
    regression — semainputd doesn't do keyboard gestures
    either.

### Open question (deferred to Phase 2 implementation)

**One recogniser per session, or per client?** Per session
matches the compositor's session model and avoids gesture
state confusion when a client switches focus. Per client
matches the "library callable from any consumer" model but
duplicates state. Recommend per session as the default;
clients that want their own may instantiate.

This question can be answered when semadrawd's gesture-output
routing is wired in (a Phase 2 sub-step that follows the
library extraction). The library itself is agnostic; it's
just `GestureRecognizer.init(allocator)` per caller.

## Implementation steps

Phase 2 is now a sequence rather than a single commit:

  - **Phase 2.1: ADR (this document).** Land the contracts.
    Implementation work is on hold until the contracts are
    accepted.
  - **Phase 2.2: Create `semainput/libsemainput/`** with
    `LibsemainputInput`, `LibsemainputOutput`, and the
    skeleton `GestureRecognizer.init/deinit/handleEvent`.
    No actual gesture logic yet.
  - **Phase 2.3: Migrate gesture.zig logic.** Move the bodies
    of `handleTouchDown`/Move/Up and `handleMouseButton` from
    the daemon's gesture.zig into the library. Replace
    `emitGestureEvent` JSON-emit with returning
    `LibsemainputOutput` values. Re-key per-device state from
    `device_name: []const u8` (which required the daemon's
    Aggregator to derive) to `device_slot: u16` (which arrives
    in every inputfs event).

    `device_aggregate.zig` does NOT move (per amendment to
    "Dependency surface" above). It is fundamentally evdev-
    era plumbing and gets deleted in Phase 3.

    The daemon's gesture.zig becomes a thin shim that:
    (i) translates `semantic.SemanticEvent` (with paths) into
        `LibsemainputInput` (with device_slots), using the
        daemon's existing Aggregator;
    (ii) calls `libsemainput.GestureRecognizer.handleEvent`;
    (iii) translates returned `LibsemainputOutput` values back
          into JSON-line strings via the existing emit path.

    semainputd's external behaviour (JSON-lines on stdout) is
    preserved exactly; downstream consumers don't notice the
    extraction.

    Stage A of Phase 2.3 (this commit on landing) is the
    scope correction: ADR amendments and skeleton type
    updates. Stage B is the actual migration. Splitting keeps
    the migration commit reviewable and the contract changes
    on record before code lands against them.
  - **Phase 2.4: Wire libsemainput into semadrawd.** Add a
    GestureRecognizer instance to semadrawd; feed it from
    `inputfs_input.zig`'s drain (per (a) above); consume the
    output. Decide gesture-vs-pointer routing for clients
    (per the negative consequence above). This is the
    "actually use the library" step.
  - **Phase 2.5: Bare-metal verification.** Confirm
    semainputd still produces JSON-lines via the shim. Confirm
    semadrawd-driven gesture recognition fires for a simple
    case (single tap → n_click:1 reaching the client). Phase
    2 is done when both are green.

Phase 2.4 is the load-bearing motion (analogous to Phase 1's
data-flow cutover). Phase 2.5 verifies. Phase 3 (deletions)
follows: `semantic.zig`, `globals.zig`, and semainputd itself.

## References

  - `inputfs/docs/STAGE_E/PHASE_1.md` — Phase 1 record;
    incorrect "mostly mechanical file moves" framing of
    Phase 2.
  - `BACKLOG.md` AD-2a entry.
  - `semainput/src/gesture.zig` — the file being extracted.
  - `semainput/src/semantic.zig`,
    `semainput/src/device_aggregate.zig`,
    `semainput/src/globals.zig` — the dependency surface.
  - `shared/INPUT_EVENTS.md` — the inputfs wire format that
    informs `LibsemainputInput`.
  - `inputfs/docs/adr/0015-per-user-pointer-smoothing.md` —
    the previous ADR; closest cousin to this one in the
    AD-1/AD-2 cutover arc.
