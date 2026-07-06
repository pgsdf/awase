# ADR 0012: Compositor-enforced session-lock mode (D-10)

## Status

Accepted 2026-06-09 (operator-ratified in session). This ADR is D-10.
It defines the secure-lock substrate required by SM-2 (pgsd-sessiond
ADR 0010 D3) and SM-3 (ADR 0009). SM-2 mandates a real security
boundary with no best-effort interim lock (ADR 0010 D4), so this
mechanism is a required precondition for system security. The
lock-client authorization model (Section 4, uid 0 as the bootstrap
instantiation of a lock capability) and the deferred opcode assignments
(Section 10) are ratified.

Amended 2026-07-06 by ADR 0021: the session_lock and session_unlock
verbs relocate from the public client protocol to the dedicated
privileged control socket ratified in ADR 0021 Section 8; see the
amendment note in Section 10. No other decision of this ADR changes.

## 1. Context

A secure session lock must enforce the following properties:

  - only the lock surface is ever visible while locked;
  - all input is delivered exclusively to the lock client;
  - no other client (including the window manager) can influence
    presentation or input routing while locked;
  - the system must not unlock due to client crash or disconnect
    (fail-closed behaviour).

Today semadrawd composites surfaces via z-order and routes input via
focus and pointer-grab logic. These mechanisms are not security
boundaries and can be influenced by untrusted or buggy clients,
including the window manager. Lock must therefore be a
compositor-enforced mode that bypasses normal policy evaluation
entirely.

The model is the ext-session-lock-v1 analogue, adapted to semadraw's
compositor and focus region.

## 2. Normative security invariants

These invariants MUST hold in all implementations.

  - I1, presentation isolation: only the lock surface (or the
    compositor fallback fill) is ever presented during a LOCKED state.
  - I2, input isolation: no input event is delivered to any non-lock
    client during a LOCKED state.
  - I3, policy bypass: all z-order, focus, grab, and surface-policy
    mechanisms are ignored for presentation and routing decisions during
    a LOCKED state.
  - I4, fail-closed behaviour: if the lock owner disconnects, the system
    remains locked and does not restore normal session behaviour.
  - I5, no implicit fallback target: there is no default or fallback
    focus target during a LOCKED state.

## 3. Lock state machine

### 3.1 States

The compositor defines the following global states:

  - UNLOCKED.
  - LOCKED_ACTIVE: a lock owner exists and is connected; the lock
    surface is valid.
  - LOCKED_NO_OWNER: the lock owner is gone (disconnected or crashed);
    the system remains locked; only takeover or reboot can recover.

### 3.2 Transitions

| From            | Event                          | To            |
|-----------------|--------------------------------|---------------|
| UNLOCKED        | valid session_lock             | LOCKED_ACTIVE |
| LOCKED_ACTIVE   | owner disconnect               | LOCKED_NO_OWNER |
| LOCKED_NO_OWNER | authorized takeover lock       | LOCKED_ACTIVE |
| LOCKED_ACTIVE   | valid session_unlock (owner)   | UNLOCKED      |
| LOCKED_NO_OWNER | reboot                         | UNLOCKED      |

## 4. Authorization model (D2)

Lock authorization is a capability, not an identity property. The lock
must be enforceable over the window manager, which runs as
SEMADRAW_PRIVILEGED_UID and is not necessarily root; routing lock
authority through the window-manager privilege would let the WM defeat
the lock. Lock authority is therefore distinct from, and above,
SEMADRAW_PRIVILEGED_UID.

Bootstrap instantiation: a lock request is accepted only if the peer uid
is 0, checked against the `peer_uid` semadrawd captures via
`getpeereid(3)` at accept (client_session.zig). This uid check is a
temporary instantiation of a lock-capable principal model. Future
revisions MAY replace it with a dedicated capability or token, and MAY
narrow it to a single configured lock principal if multiple root
principals become a concern. Flagged for ratification.

## 5. Operations

### 5.1 session_lock(surface_id)

Conditions:

  - state == UNLOCKED, or state == LOCKED_NO_OWNER (takeover);
  - caller is lock-authorized (Section 4).

Effects:

  - transition to LOCKED_ACTIVE;
  - record `lock_owner_session` and `lock_surface_id`;
  - emit `session_locked`.

Presentation:

  - the compositor immediately enters LOCKED rendering mode;
  - before the first valid lock-surface frame, the compositor displays
    the solid fill fallback (Section 7.2).

### 5.2 session_unlock

Conditions:

  - state == LOCKED_ACTIVE;
  - caller == `lock_owner_session`.

Effects:

  - transition to UNLOCKED;
  - clear lock state;
  - emit `session_unlocked`.

### 5.3 Unauthorized or invalid requests

A request is rejected with `error_reply`, with no state mutation, if any
of the following holds:

  - the caller is not lock-authorized;
  - a session_lock arrives while state == LOCKED_ACTIVE (an owner already
    holds the lock; this is the duplicate case, distinct from the
    takeover of a LOCKED_NO_OWNER state);
  - a session_unlock does not come from the owner.

## 6. Input routing specification (critical path)

### 6.1 Precedence rule (normative)

Input routing MUST evaluate in the following order:

  - if state is any LOCKED state: route exclusively to the lock owner
    session and ignore all focus and grab state;
  - else: normal focus and grab routing applies.

### 6.2 LOCKED_NO_OWNER behaviour

  - all input events are discarded;
  - no client receives events;
  - no fallback focus target exists (I5).

## 7. Presentation rules

### 7.1 LOCKED rendering mode

While in any LOCKED state:

  - only the lock surface is composited;
  - all other surfaces are excluded from scene-graph output;
  - z-order and visibility state are ignored.

### 7.2 Fallback fill

A compositor-owned solid fill is displayed when:

  - the lock surface has not produced a valid committed frame, or
  - the lock owner is absent (LOCKED_NO_OWNER).

This fill is not a surface and is not part of any client state.

## 8. Interaction with the window manager (D-7 / D-8)

While LOCKED, all `set_z_order`, `set_position`, `set_visible`,
set-focus (D-7), and grab (D-8) requests are accepted at the protocol
level but MUST NOT affect input routing, presentation, or compositor
global state. They MAY be dropped, or stored in per-client state
(implementation choice), but MUST NOT influence LOCKED behaviour.

On unlock, normal policy resumes and previous state MAY be restored.

## 9. Crash safety (D6)

If the lock owner disconnects while LOCKED_ACTIVE:

  - transition to LOCKED_NO_OWNER;
  - the compositor remains locked;
  - input is discarded at the routing stage; no client receives events;
  - the fallback fill is displayed.

This is a fail-closed condition. The system MUST NOT restore the
UNLOCKED state, assign focus to any other client, or implicitly rebind
input. Recovery is only via an authorized takeover lock or a system
reboot. A crash must never unlock; this is the single most important
property of this ADR.

## 10. Protocol additions (D8)

New client messages: `session_lock`, `session_unlock`. New events:
`session_locked`, `session_unlocked`. Focus-region extension: a
`lock_active` flag and a `lock_owner_session` reference, honoured by
inputfs per Section 6.

Numeric assignments are generated via the protocol pipeline
(`shared/protocol_constants.json`, regenerated into `protocol.zig`), in
the established ranges and after the D-7 reservations (`set_focus`,
`focus_changed`).

Amendment (2026-07-06, ADR 0021): blanking is session policy and its
control verbs do not enter the client protocol; the same argument
applies with more force to the lock verbs, which are security-critical
and unimplemented. session_lock and session_unlock therefore relocate
to the dedicated privileged control socket ratified in ADR 0021
Section 8, alongside blank/unblank and display-state notifications.
The client-protocol assignments 0x0035/0x0036 remain permanently
reserved and are never reused; the protocol pipeline entries are
updated when the control socket is implemented, not by this
documentation change. Sections 5, 6, 7, and 9 of this ADR are
unaffected: the operations, invariants, and fail-closed semantics are
carried unchanged onto the new transport.

## 11. Implementation requirements

semadrawd:

  - implement the LOCKED state machine (Section 3);
  - enforce authorization (Section 4);
  - enforce the rendering rules (Section 7);
  - enforce the input precedence rule (Section 6);
  - guarantee fail-closed behaviour (Section 9).

inputfs:

  - MUST apply the lock precedence rule before any focus or grab logic;
  - MUST discard input in LOCKED_NO_OWNER;
  - MUST NOT consult `keyboard_focus` or the pointer grab in any LOCKED
    state.

window manager:

  - MUST treat `session_locked` as a suspension signal;
  - MUST NOT assume control authority during a LOCKED state.

## 12. Bench requirements

System validation (pgsd-bare-metal) MUST confirm:

  - only the lock surface is visible during LOCKED;
  - no input reaches non-lock clients during LOCKED;
  - the window manager cannot influence rendering or input during
    LOCKED;
  - killing the lock owner does not unlock the system;
  - LOCKED_NO_OWNER remains input-dead;
  - a new authorized lock can recover the system (takeover);
  - unlock restores prior behaviour.

## 13. Consequences

  - the SM-2 secure boundary becomes implementable;
  - the compositor gains a true security-critical mode switch;
  - the window manager is fully subordinated during a LOCKED state;
  - the system becomes fail-closed on lock-owner crash.

## 14. Risks

  - root-based authorization is a bootstrap assumption and may be too
    coarse for multi-principal systems (Section 4);
  - the lock path is security-critical; any deviation from the input
    precedence rule (Section 6) is a potential privilege bypass, so it
    is a hard, bench-tested invariant;
  - LOCKED_NO_OWNER is intentionally non-recoverable without an explicit
    takeover or a reboot, which may affect usability but preserves the
    security guarantee.
