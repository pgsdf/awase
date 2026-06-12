# semadraw window-manager-client contract (NDE-1 substrate validation)

Purpose. This documents the contract semadraw offers a privileged
window-manager client, and validates it against what NDE-1's Surface
Manager needs (NDE Milestone 1, substrate validation). It is the
semadraw-side companion to NDE's Surface Manager design: the Surface
Manager itself is an NDE component and is specified in the NDE repo
against the windowing-policy contract (NDE DESIGN.md section 3.2);
this document records what semadraw, the substrate, actually provides
that Surface Manager to build on, and where the substrate is short of
what the policy will require.

Scope note. This is a factual account of the semadraw protocol and
daemon as they stand, plus a gap analysis against the windowing-
policy requirement categories the NDE-1 BACKLOG entry names
(toplevel surfaces, popups, stacking, focus transitions, server-side
decorations). It does not restate or invent NDE policy; the binding
policy semantics live in NDE DESIGN.md section 3.2.

## The privileged window-manager client

semadraw recognizes one privileged client by uid, not by a separate
registration. A client connects with the normal hello handshake
(MsgType.hello, 0x0001) like any other; its window-manager authority
comes from its peer uid matching the daemon's configured
SEMADRAW_PRIVILEGED_UID (ADR 0006 section 3, isPrivilegedUid). The
privileged uid bypasses canModifySurface, so it may act on surfaces
it does not own. NOBODY_UID is never privileged. When the tunable is
unset, no client is privileged (the most restrictive default).

Design observation: the window-manager identity is implicit (the one
privileged uid) rather than an explicit "register as window manager"
message. The Surface Manager is therefore the process the operator
runs as the configured privileged uid. This is sufficient for a
single window manager, which is the NDE model.

## What the substrate provides

Stacking and z-order. Fully supported, including the cross-client
case a window manager needs.

  - MsgType.set_z_order (0x0031) sets a surface's stacking order.
  - The client z-order range is Z_ORDER_MIN (-1000000) through
    Z_ORDER_CLIENT_MAX (999999); the cursor is pinned above the whole
    client range at Z_ORDER_CURSOR (1000000).
  - handleSetZOrder sets the caller's own surface; handleRemoteSetZOrder
    lets the privileged client set the z-order of another session's
    surface. Both clamp to the client range; daemon-internal sets
    (for example the cursor) bypass the clamp.

  This covers Surface Manager stacking: the Surface Manager can place
  any client's surface anywhere in the client range, and the cursor
  is structurally always on top.

Geometry and visibility.

  - MsgType.set_position (0x0032) positions a surface.
  - MsgType.set_visible (0x0030) shows or hides a surface.

  Together with z-order, these are enough for the Surface Manager to
  lay out, raise, lower, show, and hide application surfaces.

Server-side decorations. Supported with existing primitives, no new
protocol. The Surface Manager creates its own surfaces (titlebars,
borders), positions them around the application surface with
set_position, and stacks them with set_z_order. Decorations are
NDE-owned surfaces overlaid on application surfaces, exactly as the
NDE-1 entry describes; semadraw needs no decoration-specific message.

Input delivery. Clients receive key_press (0x9001), mouse_event
(0x9002), and gesture_event (0x9030) for their surfaces. The
compositor maintains a focus region (shared/src/input.zig: the
FocusWriter or FocusReader pair at /var/run/sema/input/focus, with
keyboard_focus, a pointer grab field, and per-surface bounds used by
resolvePointer) that inputfs reads to route input. Pointer routing is
position-derived through resolvePointer.
## Gaps against the windowing policy (confirmed by NDE DESIGN.md section 3.2)

NDE DESIGN.md section 3.2 settles the earlier conditionals: it places
windowing policy, including focus transitions and grabs, in NDE, under
"Rendering remains in semadraw. Policy remains in NDE." Section 3.3
puts focus ownership in NDE's input contract, and section 5 requires
layout decisions and UI state transitions to be deterministic and
serializable. Against that, three substrate additions are required.
The first two are small (the focus-region writers already exist; only
a message and handler are missing); the third is real new work.

Gap 1: privileged set-focus message. Focus is NDE policy, so the
Surface Manager must be able to assign keyboard focus. The writer side
is ready: FocusWriter.setKeyboardFocus already writes the focus
region's keyboard_focus. What is missing is a client-to-daemon
set-focus message and the daemon calling setKeyboardFocus on receipt
from the privileged client. Today setKeyboardFocus has no daemon
caller, so keyboard focus is not driven at all. Scope: one message
plus one handler.

Gap 2: privileged grab and release message. Section 3.2 lists grabs;
popups need them (route pointer input to the popup until dismissed).
The writer exists: FocusWriter.setPointerGrab writes the focus
region's pointer grab field (used today only to reset to NO_GRAB).
Missing is a client-to-daemon grab and release message, the daemon
calling setPointerGrab for the privileged client, and inputfs honoring
the grab in routing (it already reads the focus region). Scope: one
message pair plus a handler; the routing substrate is present.

Gap 3: subsurface semantics. Section 3.2 requires subsurfaces, and the
substrate has none: create_surface carries no parent, and there is no
parent-child relationship in the registry. A subsurface must move
atomically with its parent and clip to it; approximating that with
independent surfaces and set_position is racy and would violate
section 5's determinism rule (a frame can catch parent and child
mismatched). So this is genuine compositor work: a parent reference at
create time (or a set-parent message), atomic positioning relative to
the parent, and clip-to-parent in composition. This is the largest of
the three and the one true new mechanism.

Roles and decorations, for completeness:

  - toplevel versus popup roles are NDE policy; NDE tracks them with
    no protocol change. Their compositor-visible consequences are
    grabs (Gap 2) and subsurfaces (Gap 3), not the role labels.
  - server-side decorations by default are already supported via
    existing primitives (NDE overlay surfaces positioned and stacked
    around the application surface); no protocol change.

Determinism (section 5). The three additions must be deterministic and
serializable: focus and grab changes take effect at well-defined
points (not mid-frame), subsurface moves are atomic with the parent,
and the resulting window state (stack, focus, grab, parentage) is
observable so it can be captured for the section 6 diagnostics (window
policy traces, session snapshots).

## Validation summary

  - privileged WM client: provided (by uid; implicit identity).
  - stacking and z-order, including cross-client: provided.
  - position, visibility: provided.
  - server-side decorations: provided via existing surface primitives.
  - input delivery to surfaces, pointer routing: provided.
  - focus transitions (NDE policy): GAP 1, set-focus message and
    handler; focus-region writer already present.
  - grabs for popups (NDE policy): GAP 2, grab and release message and
    handler; pointer-grab writer already present, inputfs reads the
    region.
  - subsurface semantics: GAP 3, parent-child surfaces with atomic
    positioning and clip-to-parent; genuine new compositor work.

## Milestone sequencing (NDE ROADMAP)

NDE's own ROADMAP scopes Milestone 1 (which UTF NDE-1 tracks) as
"basic window policy: focus, raise, close", not the full section 3.2.
That maps to the substrate cleanly: raise is set_z_order (provided),
close is destroy_surface (provided), and focus is Gap 1. So only
Gap 1 (set-focus) blocks NDE-1; Gap 2 (grabs and popups) and Gap 3
(subsurfaces) serve the fuller section 3.2 windowing policy at NDE
Milestone 2 and beyond and can be sequenced after NDE-1. The
Milestone 1 exit criterion "SDCS capture and replay demonstrates
deterministic output" is the section 5 determinism requirement made
concrete for the Surface Manager.

## Next steps

  1. Open the set-focus item (Gap 1) as the NDE-1 substrate blocker:
     a privileged set-focus message and handler (FocusWriter.setKeyboardFocus
     already exists; small). ADR before code. This plus the
     already-provided set_z_order (raise) and destroy_surface (close)
     satisfies Milestone 1's basic window policy.
  2. Open Gap 2 (privileged grab and release message and handler with
     inputfs honoring the grab) and Gap 3 (subsurface semantics:
     parent-child surfaces, atomic positioning, clip-to-parent) as
     later semadraw items for the fuller section 3.2 policy, not
     required for NDE-1. Each is ADR before code; Gap 3 is the
     substantial one and warrants its own ADR.
  3. Write the conformant Surface Manager design in the NDE repo
     (docs/) against section 3.2: role tracking (toplevel, popup,
     subsurface), stacking rules, focus-transition policy, popup grab
     and dismiss behavior, decoration layout. It targets the basic
     focus/raise/close policy first (Milestone 1) and the fuller
     policy as Gaps 2 and 3 land.
  4. NDE-1 implements the Surface Manager as the privileged client:
     hello as the privileged uid, raise via set_z_order, close via
     destroy_surface, focus via the new set-focus message; popups and
     subsurfaces follow at later milestones.
