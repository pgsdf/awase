# ADR 0011: Privileged set-focus message (D-7)

## Status

Accepted 2026-06-08 (operator-ratified in session). This ADR is D-7,
the single semadraw substrate addition that unblocks NDE-1 (NDE
ROADMAP Milestone 1 basic window policy: focus, raise, close). D1
through D6 are ratified, the D5 `focus_changed` event is adopted (the
D5-included variant: `set_focus = 0x0034`, `focus_changed = 0x9003`),
and a focus-validity invariant is added as D7. Implementation follows
under the D-7 backlog item with bench verification.

This ADR defines a general privileged-client capability. It is not an
NDE-specific path. NDE is one privileged client and consumes this only
through the documented WM-client contract
(`semadraw/docs/WM_CLIENT_CONTRACT.md`); it does not touch semadraw
internals, and the NDE and semadraw repositories remain separate
(project decision 2026-06-08).

## Context

NDE DESIGN.md sections 3.2 and 3.3 place focus ownership and focus
transitions in NDE policy, under "Rendering remains in semadraw.
Policy remains in NDE." The substrate is half-ready: the focus region
(`/var/run/sema/input/focus`) exists and `FocusWriter.setKeyboardFocus`
already writes its `keyboard_focus` field, but that writer has no
daemon caller, so keyboard focus is not driven by anything a window
manager can reach. inputfs reads the focus region to route keyboard
input. What is missing is a client-to-daemon message that lets the
privileged client assign keyboard focus, and a handler that performs
the write.

Raise and close, the other two Milestone 1 policies, are already
served: raise is `set_z_order` (0x0031, with `handleRemoteSetZOrder`
for the privileged cross-client case), and close is `destroy_surface`
(0x0011). So set-focus is the only missing piece for Milestone 1.

Granularity. The focus region's `keyboard_focus` field is a session
identifier (the parameter of `FocusWriter.setKeyboardFocus` is
`session_id`), and the wire protocol delivers `key_press` (0x9001) to
a client connection, that is, to a session. Pointer routing is
separate and position-derived through `resolvePointer` over per-surface
bounds. So keyboard focus is naturally session-granular, while the
window manager thinks in surfaces. This ADR bridges the two.

## Decision

### D1: a privileged set-focus message keyed by surface

Add a client-to-daemon message `set_focus` carrying a single target
`surface_id` (u32). A `surface_id` of 0 clears focus (writes
`NO_FOCUS`). The window manager passes a surface id because that is
what it already manages (it sets the same surface's stacking order via
`set_z_order`); it does not need to know session ids, which stay
internal to the daemon.

The message type is `set_focus = 0x0034` (the next value after
`set_cursor = 0x0033`), added through the generated-constants pipeline
(`shared/protocol_constants.json`, regenerated into `protocol.zig`),
not hand-edited.

### D2: the daemon resolves surface to session and writes the region

On receipt the daemon looks up the target surface, finds its owning
session, and calls `FocusWriter.setKeyboardFocus(owning_session_id)`,
exactly the surface-to-session resolution `handleRemoteSetZOrder`
already performs for cross-client z-order. Focus delivery granularity
is therefore the session: keyboard input flows to the owning
connection, and a client with more than one surface routes among its
own surfaces internally. This matches the wire model (events go to a
connection) and is sufficient for Milestone 1, where managed surfaces
belong to distinct application clients.

Out of scope for D-7: kernel-enforced per-surface keyboard focus
within a single multi-surface client. If future NDE work requires
multiple independently focusable surfaces within one client
connection, that is a larger change (a per-surface focus field plus
per-surface keyboard routing) and belongs in a new ADR, not a
complication of D-7.

### D3: privileged-only, via the existing mechanism

`set_focus` is honored only from the configured privileged client
(`isPrivilegedUid` against `SEMADRAW_PRIVILEGED_UID`), the same gate
`handleRemoteSetZOrder` uses. A non-privileged client that sends
`set_focus` receives `error_reply` (0x80F0) and no focus change
occurs. This introduces no NDE-specific path: any process running as
the configured privileged uid has the capability, and NDE is simply
that process.

### D4: deterministic application

The handler applies the focus change at message-processing time in the
main loop and publishes it through the focus region's existing seqlock,
so inputfs observes a consistent value on its next read. Focus is a
discrete region write, not coupled to compositing, so there is no
mid-frame ambiguity. This satisfies NDE DESIGN.md section 5: the focus
transition takes effect at a well-defined point and the resulting
focus state is observable (and so capturable for section 6
diagnostics).

### D5: a focus-changed event to clients

Add a daemon-to-client event `focus_changed` (0x9003, in the events
range) delivered to the client that gains focus and to the one that
loses it, carrying the surface id, so applications can render focused
versus unfocused state. Adopted (the D5-included variant). Without it
clients would discover focus indirectly, which leads to polling or
later protocol additions, and focus is one of the few
window-management events applications routinely need to observe. The
event also enables visual focus indication, pause and resume behavior,
keyboard-shortcut enablement, and future diagnostics and tracing. The
implementation cost is small next to the protocol churn it avoids.

### D6: fire-and-forget request semantics

`set_focus` has no success reply, mirroring `set_z_order`. Success is
observable through the focus region and the D5 `focus_changed` event;
failure returns `error_reply`. This keeps the request path symmetric
with the existing stacking request.

### D7: focus validity invariant

The daemon must never publish a focused session that no longer owns a
live surface. Destruction of the focused surface, or termination of
its owning session, automatically clears keyboard focus to
`NO_FOCUS`. This is a protocol invariant on the focus region, holding
always and not only on the `set_focus` path, so any reader (inputfs,
NDE components, diagnostics) can trust that a published focus refers
to a live surface. It is enforced on three paths: the set-focus
handler, the surface-destroy path, and the client-disconnect path.

## Implementation (under D-7, after ratification)

  - add `set_focus = 0x0034` and `focus_changed = 0x9003` to
    `shared/protocol_constants.json`; regenerate.
  - add `handleSetFocus`: privilege-gate, look up surface, resolve to
    owning session, call `setKeyboardFocus`; `error_reply` on
    non-privileged or unknown surface.
  - emit `focus_changed` to the gaining and losing clients.
  - enforce the D7 invariant: clear focus to `NO_FOCUS` on destroy of
    the focused surface and on disconnect of its owning session, and
    emit `focus_changed` for the resulting loss.
  - bench: the privileged client focuses each of two surfaces owned by
    distinct clients; inputfs routes keyboard input to the focused
    client; clearing focus (surface 0) routes to none; a non-privileged
    `set_focus` is refused with `error_reply`; destroying the focused
    surface and disconnecting the focused client each clear focus to
    `NO_FOCUS` (D7); focus state is stable and observable across every
    transition.

## Consequences

  - NDE-1 is unblocked: with raise (`set_z_order`), close
    (`destroy_surface`), and now focus, the Surface Manager can
    implement Milestone 1 basic window policy entirely through the
    WM-client contract.
  - The capability is general (any privileged client), so it does not
    bind semadraw to NDE and does not blur the repository boundary.
  - Grabs (D-8) and subsurfaces (D-9) remain separate, later additions
    for the fuller section 3.2 policy; this ADR does not address them.

## Risks and mitigations

  - Granularity mismatch (session-level focus versus per-surface
    windows). Mitigated by D2's surface-to-session resolution and the
    explicit out-of-scope note; revisited only if section 3.2 demands
    per-surface keyboard focus.
  - Stale focus when the focused surface or its session goes away.
    Addressed by the D7 focus-validity invariant rather than as a
    mitigation here: the daemon never publishes a focus that does not
    refer to a live surface, enforced on the set-focus, surface-destroy,
    and client-disconnect paths and covered in the D-7 bench.
  - Privilege confusion. The gate is the existing `isPrivilegedUid`;
    no new privilege concept is introduced, and the default (no
    privileged uid configured) leaves `set_focus` inert.
