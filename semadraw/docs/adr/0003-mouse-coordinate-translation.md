# 0003 Mouse coordinate translation

Status: Superseded by `inputfs/docs/inputfs-proposal.md` (2026-04-23)

## Superseded

This ADR proposed a compositor-side coordinate translation in
`semadrawd.forwardMouseEvents` as the fix for wrong mouse coordinates.
That fix was a symptom-level patch: it translated already-broken inputs
rather than producing correct inputs at source.

The `inputfs` proposal replaces the entire evdev-based input path with a
native UTF kernel substrate that normalises pointer coordinates at the
point of HID report parsing, against display geometry the kernel
already knows. Under that architecture, `MouseEventMsg.x`/`y` carry
screen-absolute pixels from the first event, and the shim this ADR
proposed is unnecessary. Clients translate to surface-local using the
surface origin they already know.

The Context section below remains accurate as a description of what is
wrong with the current evdev-driven pipeline. The Decision section is
retained for historical traceability but is no longer the intended
implementation path. No work should be scheduled against this ADR.

## Context

Today's session confirmed the mouse event pipeline works end-to-end:
semainputd injects events, the kernel routes them to the target
session, semadrawd's `drainInjectedEvents` reads the frames,
`stashEvtPointer` parses them, and `forwardMouseEvents` delivers
`MouseEventMsg` to the owning client (semadraw-term). What does not
work is the coordinate space.

semainputd currently injects *device-accumulated* coordinates —
the running sum of evdev REL_X/REL_Y deltas since the device was
opened, with no initial offset. Observed values during testing
included `x=1870 y=-568`. Semadraw-term treats incoming
`MouseEventMsg.x`/`y` as *surface-local pixels* and divides by cell
width/height to compute the cell row and column. Feeding negative
device-accumulated coordinates into that math produces negative
cell indices, which `@max(0, @min(...))` clamps to the edge — every
click registers at row 0, column clamped. Chord menus, drag
selection, and any other coordinate-sensitive gesture therefore
land in the wrong place.

Three places could perform the translation:

1. **semainputd**, before injecting. Requires semainputd to know
   surface geometry, which it does not. semainputd's purpose is
   device classification and semantic event production; it has no
   need for a surface registry and adding one couples it to the
   compositor.
2. **semadrawd**, before forwarding. semadrawd already owns the
   surface registry, knows each surface's position, size, and
   scale, and knows which surface the event is destined for (via
   `getTopVisibleSurface` today, via focus tracking eventually).
   The `forwardMouseEvents` function is the natural place.
3. **The client**, on receipt. Requires every client to reimplement
   device-to-surface translation. Duplicates knowledge the
   compositor already has.

A separate question is whether the injector should pass deltas
(dx, dy) or device-accumulated coords at all. The current design
passes both (`x`, `y` for position + `dx`, `dy` for motion). The
kernel's EVT_POINTER payload carries all four. Clients on
traditional stacks expect either absolute surface-local coords
(X11, Wayland) or relative deltas (terminal mouse reporting
modes). Device-accumulated values are a third convention that no
downstream consumer expects.

## Decision

semadrawd performs the translation in `forwardMouseEvents`.

1. On receipt of a `MouseEvent` from the backend, semadrawd looks
   up the target surface (already done today to find the owner).
2. semadrawd computes surface-local coords as `event.x -
   surface.position_x`, `event.y - surface.position_y`, applying
   scale if the surface is scaled.
3. The resulting `MouseEventMsg.x`/`y` are surface-local pixels
   in the convention every client expects.
4. The `dx`/`dy` motion deltas are passed through unchanged; they
   are already frame-local and surface-independent.

The device-accumulated `x`/`y` values remain available to
semadrawd's own compositor-level logic (focus tracking, window
manager gestures) before translation. Only the outward-facing
`MouseEventMsg` is translated.

## Consequences

1. Clients receive coordinates in the convention they already
   expect. semadraw-term's existing `handleMouseEvent` cell math
   starts producing correct values with no client-side change.
2. Focus tracking (when it lands) reuses the same surface lookup
   semadrawd already does to pick the top visible surface.
   Eventually `forwardMouseEvents` will route to the surface under
   the cursor rather than `getTopVisibleSurface`; translation
   then uses the *found* surface's position, not a hardcoded one.
3. The device-accumulated convention remains internal to semadrawd
   and can evolve (seeding on startup, multi-device fusion)
   without breaking any wire protocol.
4. No change to semainputd. The injector continues to pass raw
   device coords; the kernel continues to route by surface_id.
5. No change to the kernel `INJECT_INPUT` ABI.
6. This ADR does not cover the initial-offset question. The
   evdev accumulator currently treats the first event as
   origin, which is why `y=-568` appears after a minute of
   upward mouse movement from the kernel-module-load moment. A
   follow-up may decide to seed from the display center, or
   snap the accumulator to the focused surface's center on
   focus change. That is a separable concern from translation.

## Notes

Implementation lives in
`semadraw/src/daemon/semadrawd.zig:forwardMouseEvents`. Surface
position is available via `SurfaceRegistry.getSurface(id)`.

Related: ADR pending on focus tracking (not yet written). The
mouse-under-cursor version of `forwardMouseEvents` depends on
focus being real; until then, `getTopVisibleSurface` is the stand-
in.

Verification matches the acceptance criteria on the corresponding
backlog item (NDE-5 in BACKLOG.md): chord menu (hold left, click
middle) appears at the pointer position; drag selection highlights
the correct cell range; no negative cell coordinates arrive at
client handlers.
