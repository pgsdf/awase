# libsemainput

Userland gesture recognition library, originally extracted from
the `semainputd` daemon per AD-2a Phase 2 and now the only
remaining userland surface under `semainput/` after AD-2a Phase 3
retired the daemon (2026-05-08).

## Status

**Production.** Phase 2 (extraction) and Phase 3 (daemon
retirement) are complete. The recogniser is consumed by
semadrawd via build.zig addImport ("recogniser-as-service" per
the Phase 2.4 decision); the compositor holds one
GestureRecognizer per session and feeds it events from the
inputfs ring.

See `inputfs/docs/adr/0016-libsemainput-extraction.md` for the
design decisions this library implements, and the root
`BACKLOG.md` AD-2a entry for the historical multi-phase plan.

## What this library does

Recognises gestures (n-click, drag, two-finger scroll, pinch,
three-finger swipe, tap) from typed pointer and touch events.
Pure compute: no IO, no allocation outside the supplied
allocator, no global state.

Callers feed `LibsemainputInput` events one at a time; each
call returns at most one `LibsemainputOutput`. semadrawd holds
an instance per session; clients may hold their own if they
want gesture recognition over events they receive from the
compositor.

## What this library does NOT do

- Read the inputfs event ring. semadrawd does that and
  translates events for the recogniser. (See ADR 0016 for why
  this matters.)
- Write JSON, stdout, or any other output channel. Returns
  typed values; caller decides routing and serialisation.
- Recognise keyboard gestures. The recogniser today only acts
  on pointer and touch events.

## Use

```zig
const libsemainput = @import("libsemainput");

var rec = libsemainput.GestureRecognizer.init(allocator);
defer rec.deinit();

while (events.next()) |raw_event| {
    const input = translateToLibsemainputInput(raw_event);
    if (try rec.handleEvent(input)) |gesture| {
        switch (gesture) {
            .n_click => |n| handleNClick(n.button, n.count, n.x, n.y),
            .drag_start => |p| handleDragStart(p.x, p.y),
            .drag_move => |p| handleDragMove(p.x, p.y),
            .drag_end => |p| handleDragEnd(p.x, p.y),
            // ...
        }
    }
}
```

## Tests

`zig build test` from `semainput/` runs the library's unit
tests. Eleven cases today: n-click cadence, drag/tap thresholds,
pinch and three-finger swipe arbitration, FIFO ordering across
multiple queued outputs, type-size budget, and init/deinit
cleanliness.

## History

- **Phase 2.2** (2026-04): library skeleton with public types
  and stub recogniser.
- **Phase 2.3** (2026-04): full recogniser logic migrated from
  the now-deleted `semainput/src/gesture.zig`.
- **Phase 2.4** (2026-04): wired into semadrawd as a per-session
  service ("recogniser-as-service" decision); resolved the
  gesture-vs-pointer routing question deferred from ADR 0016.
- **Phase 2.5** (2026-05-06): bare-metal multi-touch
  verification on Apple Magic Trackpad.
- **Phase 3 step 1** (2026-05-07): event_type constants
  promoted to `shared/src/input.zig`.
- **Phase 3 step 2** (2026-05-08): semainputd binary, the
  `semainput/src/` daemon source tree, the rc.d shim, the s6
  service directory, and the legacy DRAWFSGIOC_INJECT_INPUT
  decode path in semadrawd's drawfs backend all retired.
  libsemainput remains; the daemon does not.
