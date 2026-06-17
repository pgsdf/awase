# N-Click recognizer design

**Document status (2026-05-08):** archived. This was originally
written as a pre-implementation design note for the
`semainputd` daemon's gesture recogniser. The design described
here was implemented and survives, but in `libsemainput`
rather than `semainputd` — see AD-2a Phase 2.3 (recogniser
extraction, 2026-04) and AD-2a Phase 3 step 2 (daemon
retirement, 2026-05-08). References below to "semainputd",
"the daemon", "JSON stream", and "drawfs injection path" are
preserved as historical context. Read them as referring to
the `libsemainput` recogniser running inside semadrawd in
the current tree.

## Original status

Pre-implementation design note. Recorded so that when mouse button
events are wired through the drawfs injection path, double-click (and
N-click in general) is designed in from the start rather than retrofitted.

## Why now

Tonight's work landed key injection through drawfs. Mouse, scroll, and touch
injection are still TODO in the `getMouseEventsImpl` path of the drawfs
backend. As soon as that work begins, the question of how to recognise
multi-click events arises: it is straightforward to layer on top of raw
button events, but the timing threshold and the spatial radius are
system-wide policy decisions that should not vary per application.

The choice of where in the stack to recognise N-click is durable. Once a
contract exists between semainputd and its consumers, changing it later
breaks every application that has settled on either layer.

## Where the recognizer lives

semainputd, in `src/gesture.zig`, alongside the existing touch gesture
recognizer. Three reasons:

The gesture infrastructure already exists. `GestureRecognizer` consumes
`SemanticEvent`s, holds per-device state, and emits higher-level recognised
events. Tap, swipe, and pinch are touch-domain recognisers; N-click is the
mouse-domain equivalent. Mirroring the design keeps the codebase coherent.

The audio sample clock makes timing principled. Conventional double-click
thresholds are expressed in milliseconds (Windows 500 ms, X11 250 ms). Awase
can express the threshold in sample frames against `samples_written`, which
makes the threshold frame-accurate relative to anything else timestamped on
the same clock — useful for music software, accessibility tools, or any
context where click rhythm interacts with audio. This is one of the small
ways Awase's substrate becomes visibly better than what came before.

The unified event log captures both raw and recognised events with seq
numbers, so consumers choose either layer. A terminal might only handle
N-click; a low-level diagnostic tool might want every raw `mouse_button`.
Both remain available, in the same JSON stream, with the same session token.

The two rejected alternatives:

*Recognising in the kernel.* Putting `EVT_DOUBLE_CLICK` next to `EVT_POINTER`
in `drawfs_proto.h` would let clients receive a single high-level event,
but it forces the kernel to know about user-facing semantics it should not
own. The X11 server tried this and the design ages badly: the kernel
threshold cannot be tuned per user without ioctl proliferation, and any
new gesture concept requires a kernel change.

*Recognising in the application.* Emitting only raw events and letting each
application implement its own state machine is correct in principle but
guarantees subtle inconsistency in practice. Different thresholds, different
distance tolerances, different rules for what counts as the same button.
This is the Wayland-purist position and it makes desktops feel inconsistent.

## Event shape

A new variant on `SemanticEvent`:

```zig
mouse_n_click: struct {
    path: []const u8,
    button: []const u8,       // "left", "right", "middle"
    count: u32,               // 2 = double, 3 = triple, etc.
    x: i32,                   // device-accumulated position at the final click
    y: i32,                   // (matches mouse_button x/y; see schema change)
    mods: u8,
},
```

Counted rather than typed. `mouse_double_click` and `mouse_triple_click` as
distinct variants would be more discoverable but does not scale; consumers
that care about a particular N branch on `count`. The recogniser does not
emit `count == 1` — that is a plain `mouse_button` event, already in the
stream.

The recogniser emits `mouse_n_click` *in addition to* the underlying raw
`mouse_button` events. Consumers that care only about raw clicks ignore
the new variant; consumers that care about double-click can ignore the
matched `mouse_button` events. Both layers are always present in the
unified event log.

## Recognition state

Per-device, in `GestureRecognizer`:

```zig
const ClickState = struct {
    button: []const u8,
    surface_id: u32,
    x: i32, y: i32,           // device-accumulated raw units (see schema change)
    ts_audio_samples: u64,
    mods: u8,
    count: u32,
};

last_click_per_device: std.AutoHashMap([]const u8, ClickState),
```

The recogniser reads click position directly from the `mouse_button`
event's `x` and `y` fields (see schema change below). It does not
need to track its own cursor accumulator.

## Recognition rules

On `mouse_button` with `pressed == true`, record the press position
(from the event's `x`, `y`) and the current `samples_written`. Do not
emit a recognised event yet — the press is half of a click.

On `mouse_button` with `pressed == false`, the click is complete. Compare
against the per-device `last_click`:

- If button differs, modifier mask differs, or surface differs: this is a
  fresh sequence; reset `count = 1`, store, do not emit.
- If the time delta from the previous click's `ts_audio_samples` exceeds
  the threshold: fresh sequence; reset.
- If the position has moved more than the radius from the previous click's
  position: fresh sequence; reset.
- Otherwise: increment `count`, update position and timestamp, emit
  `mouse_n_click` with the new count.

The threshold for "click vs drag" is the same as the radius for "same
click as the previous one." If the up event is more than `R` device units
from the down event, the gesture is a drag, not a click, and is *not*
counted as part of any N-click sequence. This bears mentioning explicitly
because without it, a user who drags slightly between presses will see
their intended drag interpreted as a double-click.

## Configuration

Two thresholds, both publishable as filesystem surfaces under
`/var/run/semainput/` (or wherever semainput's config layer lands —
this is currently undefined and worth settling alongside the recogniser):

- `n_click_interval_samples`: default 24000 (= 500 ms at 48 kHz). Maximum
  audio-sample delta between successive clicks for them to be considered
  the same N-click sequence.
- `n_click_radius_px`: default 8. Maximum device-unit distance between
  successive click positions for them to count as the same. Despite the
  `_px` suffix, the unit is device-accumulated raw input (see the
  schema change section for the rationale); for typical mouse hardware
  at typical DPI, 8 device-units approximates 8 pixels of motion.

The defaults are the threshold for both "double-click vs two single
clicks" and "click vs drag" — that is, `n_click_radius_px` doubles as the
drag-detection threshold. Splitting them into separate values is a
plausible refinement but adds a configuration knob without much benefit;
the values are conceptually the same thing ("did the pointer move
meaningfully between events").

These are policy, not per-application. Apps inherit consistent behaviour.
A future per-app override mechanism is conceivable but explicitly out of
scope for the initial implementation.

## Deferred: runtime tunability

The "Configuration" section above describes the intended endpoint —
filesystem surfaces under `/var/run/sema/` (or wherever semainput's
config layer lands) that publish `n_click_interval_samples` and
`n_click_radius_px` for runtime tuning.

That endpoint is not implemented in the initial recogniser. The
thresholds are compile-time constants in `gesture.zig`, matching the
pattern used by every other threshold in semainputd today
(`TapMaxDurationNs`, `DragThreshold`, the various scroll/pinch/swipe
constants). semainputd has no runtime configuration infrastructure; the
daemon is intentionally minimal and stable, doing evdev-to-semantic
translation without config-file or socket overhead beyond what already
exists for the event log.

Adding a config layer for two new thresholds in isolation would create
a piecemeal config story: half the file's behaviour configurable, half
not, with no clear principle for which is which. The cleaner path is to
defer config until a daemon-wide story is settled, then move *all*
thresholds (existing and new) to the same mechanism in one focused
change.

When that work happens, the natural shape is a single config file —
JSON or a simple key=value format — loaded once at startup, with the
existing compile-time constants serving as defaults for any missing
keys. No hot reload required initially; daemon restart on config
change is acceptable for thresholds that change rarely.

Until then: tune by editing the constants in `gesture.zig` and
rebuilding. The recogniser is fully functional with the defaults; the
deferral affects only the ability to tune without recompilation.

## What is not handled

Drag is the natural sibling of click and the same state machine can
handle it: if the up event is outside the radius, emit `mouse_drag_end`
instead of bumping the click count. This design note does not cover
drag in detail, but the recogniser should be designed with the drag
exit path in mind so the eventual addition does not require restructuring.

Modifier-changing-mid-sequence: if the user clicks once with no modifier
and then once with Shift held, this is two separate sequences (count
resets). Documented above as "modifier mask differs."

Cross-device clicks: if the user has two mice and clicks once with each
in the same place, this is two separate sequences (different `path`).
Per-device state means this is automatic.

Cross-surface clicks during a press: if the press lands on surface A and
the release lands on surface B because the user dragged out, the click
is invalid and is not counted. This requires knowing the focused surface
at both press and release time, which the recogniser learns from the
focus-tracking mechanism that does not yet exist (see the related
follow-up about hardcoded `surface_id=1` in the drawfs injector).
Until focus tracking is wired up, the recogniser uses the single
hardcoded surface and the cross-surface case does not arise.

## Schema change: `mouse_button` carries device-accumulated coordinates

`SemanticEvent.mouse_button` is extended with `x, y` fields. The units
are **device-accumulated raw units** (the running sum of `REL_X` /
`REL_Y` deltas seen by the evdev adapter for that device), not
surface-local pixels.

```zig
mouse_button: struct {
    path: []const u8,
    button: []const u8,
    pressed: bool,
    x: i32,           // new — device-accumulated x at event time
    y: i32,           // new — device-accumulated y at event time
},
```

### Why device units, not surface-local pixels

The recogniser needs *some* coordinate space to compare click positions
against the spatial radius. Three were considered:

- **Surface-local pixels.** Cleanest semantically. But surface mapping
  happens in semadrawd's compositor, not in semainputd. Producing
  surface-local coordinates in semainputd would require either
  duplicating cursor placement logic from the compositor, or adding a
  round-trip query, both of which break the layering and add coupling
  semainputd does not currently have.
- **Device-relative deltas only (no schema change).** The recogniser
  could compare each up-event's accumulated motion-since-down against
  the radius. This works for the click-vs-drag check but is awkward for
  the click-position-stability check across multiple events, because
  the recogniser would have to maintain its own per-device cursor.
- **Device-accumulated raw units (chosen).** The evdev adapter already
  observes every `REL_X` / `REL_Y` event; accumulating them into a
  per-context cursor is a small change. The resulting x/y are honest:
  they are not pixels, but for typical mouse hardware at typical DPI
  they approximate pixels closely enough that an 8-unit radius reads
  as roughly 8 pixels of motion. Downstream consumers that need true
  surface-local coordinates (semadrawd's compositor, when pointer
  injection is wired) translate device-units to surface-local-pixels
  themselves, which is the same coordinate transform they would do
  anyway for cursor placement.

The chosen approach keeps the recogniser in semainputd, preserves the
audio-clock proximity that motivated locating it there, avoids waiting
on the compositor's surface-mapping infrastructure, and leaves the door
open for semadrawd to do its own surface-local tracking without
conflict.

### Adapter responsibility

The evdev adapter (and any future adapter) maintains a per-context
cursor accumulator, advanced on every `REL_X` / `REL_Y` event. The
adapter stamps the current accumulator value into every
`mouse_button` event it emits. The accumulator is reset only when the
adapter itself is reinitialised (e.g. device hot-unplug then replug).
There is no "warp the cursor to origin" mechanism because device-units
have no canonical origin: they are a relative sum.

### Backward compatibility

Backward compatibility with external consumers of the JSON event log
is not preserved. This is acceptable at Awase's current maturity — the
event schema is not yet under a stability contract, the unified
envelope was itself a recent change, and there are no known external
consumers beyond Awase's own daemons. If a stability contract is later
adopted, this extension should be visible in any schema diff at that
point.

## Implementation scope

Roughly 80-120 lines in `gesture.zig` for the recogniser, plus ~30 in
`output.zig` for the `mouse_n_click` JSON serialisation, plus tests.
Plus the `mouse_button` schema change: two `i32` fields added to the
`SemanticEvent` variant, the corresponding JSON serialiser update in
`output.zig`, and the evdev adapter modified to stamp the current
pointer position into every `mouse_button` event it emits.

No changes to drawfs, no changes to the kernel, no changes to semadrawd
or semadraw-term beyond consuming the new event type if they wish to.

The recogniser depends on `samples_written` being readable, which is
the case as of tonight (semaaud now publishes `/var/run/sema/clock`).
It does not depend on mouse injection through the drawfs backend
working; the recogniser can be implemented and tested against
synthetic event streams independently. Wiring it into a live pipeline
requires the mouse-injection path which is currently TODO.

Suggested implementation order:

1. Extend `SemanticEvent.mouse_button` with `x, y`, update
   `output.zig`, modify the evdev adapter to populate them.
2. Add `mouse_n_click` to `SemanticEvent` and `output.zig`.
3. Implement `MouseClickRecognizer` in `gesture.zig` against
   synthetic event streams (unit tests).
4. Wire mouse injection through drawfs (the parallel TODO that
   unblocks the recogniser in production).
5. Add config surfaces for the two thresholds.

## Acknowledgements

Raised by Zeke Redgrave during the same session that landed key
injection (2026-04-22). Recorded here so the design choice is settled
before code is written.
