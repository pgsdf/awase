# 0003 Compositor focus publication interface

Status: Proposed

## Context

The inputfs charter
(`inputfs/docs/adr/0001-module-charter.md`) places focus-routed
event delivery inside inputfs's scope. ADR 0002 names the
shared-memory regions inputfs publishes to userspace and the one
region (`transform`) that the compositor publishes for inputfs to
read. Foundations §1 states that pointer coordinates are in
compositor post-transform space; foundations §7 states that
compositor-level grabs are implemented via inputfs's routing
rather than via exclusive device locks.

This ADR decides the interface by which the compositor publishes
focus state to inputfs. The focus state answers three routing
questions inputfs must resolve for every event:

1. Which session receives keyboard events?
2. Which session receives pointer events under normal routing
   (surface-under-cursor)?
3. Which session receives pointer events when a grab is active
   (compositor-directed override)?

The inputfs proposal sketched the model (keyboard follows focus,
pointer follows cursor, grabs override) but left the interface
unspecified. This ADR specifies the interface; byte-level layout
of the focus region is deferred to a companion spec alongside the
other per-region specs tracked under AD-1.

## Decision

1. Focus state is published by the compositor in a fourth
   shared-memory region: `/var/run/sema/input/focus`. This is a
   peer of the state/events/transform regions already named in
   ADR 0002. The compositor is the sole writer; inputfs is the
   sole reader.

2. The focus region publishes three fields that together answer
   the routing questions:
   - `keyboard_focus`: the session id that should receive
     keyboard events. A sentinel value (e.g., `NO_FOCUS = 0`)
     indicates no keyboard focus; in that state, inputfs
     publishes keyboard events to the ring but does not route
     them to any session.
   - `pointer_grab`: the session id that should receive pointer
     events regardless of cursor position. A sentinel value
     (`NO_GRAB = 0`) indicates no active grab; pointer routing
     falls through to the surface-under-cursor rule.
   - `surface_map`: a compact encoding of which session owns
     each surface region in compositor space. inputfs uses this
     with the current pointer position to determine
     surface-under-cursor routing when no grab is active.

3. The compositor updates the focus region using seqlock
   versioning (the same pattern as the state region). Focus
   changes are atomic; inputfs never routes events according to
   half-updated focus state.

4. Routing resolution at event-ingestion time:
   - For keyboard events: deliver to `keyboard_focus` if set.
     Otherwise deliver to no session (event is still published
     in the ring for observers).
   - For pointer events: if `pointer_grab` is set, deliver to
     that session. Otherwise, look up the current pointer
     position in `surface_map` and deliver to the session that
     owns the containing surface. If no surface contains the
     pointer, deliver to no session.

5. Pointer enter and leave events are synthesised by inputfs when
   the surface-under-cursor changes between ingested pointer
   events, using successive reads of `surface_map`. The
   compositor is not responsible for generating enter/leave; it
   is responsible for publishing accurate surface geometry.

6. The Zig library at `shared/src/input.zig` (named in ADR 0002)
   exposes `FocusWriter` and `FocusReader` types, paralleling
   the other Writer/Reader pairs. The compositor uses
   `FocusWriter`; inputfs uses `FocusReader`.

## Consequences

1. The compositor owns all focus policy. Which surface gets
   keyboard focus on window creation, whether focus follows
   pointer or requires click, how grabs are initiated and
   released: all are compositor concerns. inputfs implements
   the routing mechanism the compositor directs but does not
   make focus decisions.

2. The surface_map encoding is the subtle part of this
   interface. It must represent the current compositor-space
   surface layout compactly enough for inputfs to update it per
   surface change without contention, and efficiently enough for
   inputfs to look up pointer positions in the event hot path.
   The companion spec for the focus region addresses this
   explicitly.

3. Per-surface pointer behaviour (buttons reported, scroll
   semantics, hit-test exclusions) is not represented in the
   focus region. Those are client concerns, resolved by the
   client after it receives a pointer event for its surface.

4. Synthesised enter/leave events consume sequence numbers from
   the same counter as ingested events, preserving total
   ordering. The sequence-number invariant from foundations §3
   extends to synthesised events.

5. The focus interface makes the compositor a mandatory
   consumer: inputfs cannot route any event without it. If the
   compositor is not running, inputfs publishes events to the
   ring but routes nothing. This matches the behaviour of the
   transform region (ADR 0002 consequence 4) and is consistent
   with UTF's compositor-as-arbiter model.

## Notes

Byte-level layout of the focus region, including sentinel
values, surface map encoding, version and migration rules,
lives in the companion spec to be written as
`shared/INPUT_FOCUS.md` or equivalent. Tracked under AD-1
alongside the other per-region specs.

This interface is a one-way channel: the compositor publishes,
inputfs reads. There is no path for inputfs to request a focus
change. If a feature emerges that would require inputfs-initiated
focus changes (e.g., "tap to focus" at the hardware level), that
feature is added through a separate mechanism; this region stays
compositor-writes-only.

Surface-under-cursor routing assumes surfaces do not overlap in a
way that leaves the pointer's containing surface ambiguous. The
compositor's composition order already resolves z-order for
rendering; the same resolution applies for routing. When multiple
surfaces contain the pointer position, inputfs routes to the
top-most one per composition order.

Third of four Stage A ADRs under AD-1. The fourth (semantic role
taxonomy) remains.
