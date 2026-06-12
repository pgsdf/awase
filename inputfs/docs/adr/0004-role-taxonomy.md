# 0004 Semantic role taxonomy

Status: Proposed

## Context

The inputfs charter (`inputfs/docs/adr/0001-module-charter.md`)
commits inputfs to handling every input device class FreeBSD
exposes. The foundations document
(`inputfs/docs/foundations.md`, §2) names the abstraction that
holds across device classes: a device carries stable identity and
exposes one or more **role endpoints**, where each role is a
semantic facet of what the device does. Foundations §2 lists five
working roles: pointer, keyboard, touch, pen, lighting.

This ADR fixes the initial role set, the event variants each role
produces, and the rule for adding roles later. The taxonomy is
referenced by the shared-memory region specs (state region's
device inventory, event ring's event schema) and by the focus
publication interface (which events are routed by
keyboard_focus, which by pointer_grab, which by
surface-under-cursor).

The roles are a closed set for v1. Adding a role requires a
revision of this ADR. Roles exist at the kernel level; they are
not a compositor convention or a client library abstraction.

## Decision

1. The initial role set is five:
   - **pointer**: produces motion, button, and scroll events in
     compositor space.
   - **keyboard**: produces key-down and key-up events carrying
     HID usage code and positional code.
   - **touch**: produces touch-down, touch-move, and touch-up
     events with contact identifiers and compositor-space
     positions.
   - **pen**: produces pen-down, pen-move, and pen-up events
     with compositor-space positions, pressure, and tilt.
   - **lighting**: receives commands to set device-level
     lighting state (LEDs, keyboard backlight, device RGB). The
     only role that is a consumer direction rather than a
     producer direction.

2. A device exposes zero or more roles. A device with zero roles
   is still enumerated in the device inventory (so clients can
   see it attached) but produces no events. A device with
   multiple roles appears in the inventory once with a role
   list.

3. Events carry their originating role explicitly. Consumers
   that care about role-specific event variants can filter on
   the role tag without inspecting device identity. The state
   region's per-role current-state fields (keyboard modifiers,
   pointer position, active touches) are updated by events of
   the corresponding role only.

4. Event routing depends on role:
   - pointer and touch events route through
     pointer_grab-or-surface-under-cursor per ADR 0003.
   - keyboard events route through keyboard_focus per ADR 0003.
   - pen events route through pointer_grab-or-surface-under-
     cursor, matching pointer.
   - lighting commands are delivered to the originating device,
     not routed through focus.

5. A role is added to the taxonomy through a revision of this
   ADR. The revision must specify the role's event variants,
   routing rule, state fields contributed to the state region,
   and any interaction with existing roles (for example, if a
   gesture role is added later, its relationship to pointer and
   touch must be stated).

6. Roles explicitly out of scope for v1:
   - gesture (pinch, rotate, swipe synthesis): a compositor or
     per-client concern per foundations §5 and the charter.
   - gamepad: the hardware class is in scope for inputfs
     (charter Decision item 2 and item 7), but the event
     variants that would be needed (stick position, trigger
     pressure, button array) are deferred to a later revision.
     Gamepad devices are enumerated but produce no events until
     the role lands.
   - vendor-specific controls (rotary encoders on specialty
     keyboards, tablet express keys, non-standard sensors): each
     needs its own role addition, or is expressed through an
     existing role's events, or is deferred.

## Consequences

1. The event schema carries a role tag on every event. The
   state region reserves per-role sections rather than
   per-device sections; a device with three roles contributes
   to three sections.

2. Gamepad hardware attaches and enumerates at Stage B without
   producing events. The device inventory shows the device with
   its roles empty or marked `pending`. Adding gamepad events
   is a separate work item, tracked under AD-1 sub-items in
   `BACKLOG.md`.

3. The role set is small enough that per-role code paths are
   reasonable. inputfs does not attempt a role-generic event
   shape; each role has its own event variant structure, and
   the code paths are parallel rather than generic.

4. Lighting as a consumer direction (compositor or client sends
   commands to devices) is the first inputfs feature that is
   not an event in the ingestion sense. The mechanism for
   lighting commands is deferred to a companion spec; it may
   reuse the event ring in a reverse direction, or use a
   separate ioctl path. This ADR commits only to lighting being
   part of the role taxonomy and to its out-of-event-pipeline
   status.

5. The closed-set rule is load-bearing. It prevents gradual
   taxonomy drift where individual drivers add bespoke roles
   that other consumers have to discover at runtime. Every role
   is documented, versioned, and known ahead of time.

## Notes

Role names are lowercase identifiers without qualification:
`pointer`, `keyboard`, `touch`, `pen`, `lighting`. The companion
spec for the state region fixes the byte encoding; ADR-level
decisions use the names directly.

Role endpoints do not imply physical boundaries. A composite
device (gaming mouse with keyboard payload) has one device
identity and two role endpoints (pointer, keyboard); the two
endpoints update their respective sections of the state region
independently. A laptop with integrated keyboard, touchpad, and
backlight has one device identity (the laptop) if enumerated as
such, or three (if enumerated per interface), and either is
acceptable. Enumeration granularity is a Stage B concern, not
a taxonomy concern.

This is the fourth and final Stage A ADR under AD-1. Stage A
concludes with this ADR and the three companion specs
(state region, event ring, focus region) to be written before
Stage B begins.
