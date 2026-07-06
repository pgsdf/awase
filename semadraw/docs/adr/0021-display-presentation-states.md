# ADR 0021: Display-presentation states orthogonal to session lock

## Status

Accepted 2026-07-06 (operator-ratified in session; drafted and revised
same day on operator review). Ratified decisions: the two-axis state
model (Section 3); invariants B1-B5; the dedicated control socket,
Section 8 option (a), as the permanent control-interface architecture;
the Section 9 policy vehicle (a), the SM-2 agent beginning with the T0
stage; and the consequential relocation of ADR 0012's lock verbs to
the control socket (amendment note added to ADR 0012 Section 10). Companion to ADR 0012 (session-lock mode, D-10) and
ADR 0013 (idle publication, D-11); refines sessiond ADR 0009 D3
(two-tier blanking) by making the Tier A compositor blank an
independently requestable state rather than a facet of the T1 lock
engagement.

Revision (operator review, 2026-07-06): blank control moved off the
public client protocol onto a privileged control interface (Section 8),
with a consequential amendment to ADR 0012's opcode placement; the
wake rule restated as a delivery invariant with the mechanism left to
implementation (Section 6); authorization stated in terms of the
ADR 0010 session authority rather than a concrete credential
(Section 5); presentation-root selection added (Section 7). The
two-axis model, the presentation-only invariant, and frame-callback
suspension are affirmed unchanged.

No decisions remain open.

## 1. Context

Sessiond ADR 0009 defines the idle timeline: T1 blank-and-lock, T2
suspend. Its D3 stages blanking in two tiers: Tier A, a compositor-level
blank available now; Tier B, true display power-off, gated on a drawfs
output-power primitive that does not exist. As ratified, the Tier A
blank exists only paired with the lock at T1.

The operator wants a pre-lock blank: the display goes dark after an
idle interval (nominally 15 minutes) and any key or pointer motion
restores it immediately, with no authentication. The ratified corpus
has no such state. Rather than a bespoke blanker that would later be
reworked to accommodate the lock, this ADR gives blanking a permanent
home in the compositor state model such that the lock (ADR 0012)
composes with it unchanged.

A single linear chain (Active -> Blanked -> Locked -> Off) cannot
express the locked-and-blanked case: a session locked at T1 that idles
further should go dark, and a keypress must relight the display onto
the lock prompt without touching the lock. Blank and lock are therefore
modelled as orthogonal axes.

## 2. Normative invariants

  - B1, presentation-only: the display axis affects presentation and
    nothing else. No input-routing decision, focus state, grab state,
    or security-axis state is read from or written by the display axis,
    with the single exception of the wake-event swallow (Section 6).
    A blank is not a lock and must never behave like a weak one
    (sessiond ADR 0010 D4, the no-false-confidence mandate).
  - B2, wake never crosses axes: input restores the display axis to ON
    and can never alter the security axis. Unlock happens only via
    ADR 0012 session_unlock.
  - B3, security axis unweakened: every ADR 0012 invariant (I1-I5)
    holds verbatim in every display-axis state. In particular
    presentation isolation (I1) composes: LOCKED and ON presents only
    the lock surface; LOCKED and BLANKED presents the blank fill.
  - B4, compositor-owned fill: the blanked presentation is a
    compositor-owned solid fill, the same class of object as the
    ADR 0012 Section 7.2 lock fallback fill, and is not a surface and
    not client state.

## 3. State model (flagged for ratification)

Two orthogonal axes replace the linear chain:

  - Security axis (ADR 0012, unchanged): UNLOCKED, LOCKED_ACTIVE,
    LOCKED_NO_OWNER. Transitions only via authorized session_lock /
    session_unlock and owner disconnect; fail-closed.
  - Display axis (this ADR): ON, BLANKED. OFF is reserved for Tier B
    (sessiond ADR 0009 D3) and is not defined further here beyond the
    reservation: OFF will be a deeper display-axis state entered from
    BLANKED, gated on a drawfs output-power primitive (AD-4 or DF-6),
    with the same wake rule.

Composition matrix:

| Security       | Display | Presented                  | Input routing        |
|----------------|---------|----------------------------|----------------------|
| UNLOCKED       | ON      | normal scene               | normal (focus/grab)  |
| UNLOCKED       | BLANKED | blank fill                 | normal, minus wake   |
| LOCKED_ACTIVE  | ON      | lock surface (or 7.2 fill) | lock owner only      |
| LOCKED_ACTIVE  | BLANKED | blank fill                 | lock owner only, minus wake |
| LOCKED_NO_OWNER| ON      | 7.2 fallback fill          | discarded            |
| LOCKED_NO_OWNER| BLANKED | blank fill                 | discarded            |

"Minus wake" means the event that causes BLANKED -> ON is swallowed
(Section 6); subsequent events follow the row's routing rule.

The operator timeline becomes pure policy over these axes: T0 (new,
optional) requests BLANKED; T1 requests session_lock (display axis per
policy, typically already BLANKED or blanked simultaneously); T2
suspends. T0 with no T1 configured is the standalone 15-minute blanker.
This refines sessiond ADR 0009 D3; an amendment note there should
record that Tier A blank is now independently requestable and cite this
ADR.

## 4. Display-axis transitions

| From    | Event                          | To      |
|---------|--------------------------------|---------|
| ON      | valid display_blank            | BLANKED |
| BLANKED | any input event                | ON      |
| BLANKED | valid display_unblank          | ON      |
| BLANKED | valid display_blank            | BLANKED (idempotent, acknowledged) |

Wake (input-driven BLANKED -> ON) is evaluated compositor-locally in
the input path, before routing, and takes effect on the event that
triggers it: no round-trip to any policy agent is involved in waking.
display_unblank exists for policy-driven wake (e.g. an alarm or an
incoming-call surface in some future) and for symmetry; it is not on
the interactive path.

## 5. Authorization

Blank and unblank requests originate from the session authority
defined by sessiond ADR 0010: the principal that authenticates the
session and requests the lock. Rationale: the ratified policy owner is
the SM-2 per-session agent whose privileged actions are routed through
pgsd-sessiond (sessiond ADR 0010 D6), so the requester of blank is the
same principal as the requester of lock, and no new authority class is
introduced. A hostile ordinary client can therefore neither blank the
display (nuisance) nor unblank it (content-hiding bypass when the
operator expects a dark screen).

The concrete credential mechanism (peer uid, capability, socket
ownership, IPC credential) is an implementation matter and is not
specified here; ADR 0012 Section 4 records the current bootstrap
instantiation and its planned evolution, and this ADR inherits
whatever that instantiation is at any given time.

Input-driven wake requires no authorization; it is the point.

## 6. Wake-event semantics

Normative invariant, B5: input responsible for leaving the BLANKED
state is never delivered to clients, in every security state. A
keystroke that wakes must not type into the focused editor, must not
press a button under the pointer, and must not become the first
character of a password in the lock prompt.

The mechanism that satisfies B5 is deliberately not standardized: the
space of waking inputs includes chords, held modifiers, touch
sequences, stylus proximity, and accessibility devices, and freezing
one strategy (e.g. record-the-waking-key, swallow-its-release) into
the ADR would standardize an implementation detail that better
input-state synchronization can later replace. An initial
implementation MAY use waking-event-plus-paired-release swallowing;
whatever the strategy, the bench requirement is stated against the
invariant (no wake-responsible input observed by any client), not
against the strategy.

## 7. Presentation roots and scheduling

The composed output is selected from a small set of presentation
roots by a single selector evaluated from the (security, display)
pair:

  - compose(scene): the normal client scene graph;
  - compose(lock): the lock surface, or the ADR 0012 Section 7.2
    fallback fill;
  - compose(blank): the blank fill (B4).

The Section 3 matrix is exactly this selector's truth table. Blank is
therefore an ordinary presentation mode chosen at the root, not a
special case threaded through the renderer; the lock, when
implemented, is another root under the same selector, and Tier B
display-off becomes a fourth selector outcome (present nothing, power
down) rather than new renderer state.

While BLANKED the compositor presents the blank root and suspends
the frame scheduler: no scene composition, no frame callbacks to
clients whose surfaces are unpresented. Clients keep executing; their
rendering throttles on the absent frame callbacks, which is the
desired behaviour and mirrors the LOCKED treatment of non-lock
surfaces. On wake the scheduler resumes and the first composed frame
reflects whatever the security axis dictates.

Tier A remains a content-hiding and compute-saving measure, not a
power measure (sessiond ADR 0009 D3): the panel and GPU stay on until
Tier B.

## 8. Control interface, not client protocol

Blank control is session policy, not a compositor service offered to
clients, and therefore does not extend the public client protocol.
The compositor exposes a privileged control interface to the session
authority, carrying: blank, unblank, and display-state change
notifications (emitted on every display-axis transition, including
input-driven wake, so the policy agent can restart its idle timeline
without polling races). No display_blank opcode enters the client
protocol; a display-off verb is not defined, Tier B defines it.

Ratified shape (operator, 2026-07-06): a dedicated control socket, a
second unix listener (e.g. /var/run/sema/drawctl), root-owned and
mode-restricted, with its own small message set. The ownership
boundary is physical, filesystem permissions pre-filter before any
credential check, and the client protocol contract stays pure. Cost:
one more listener in the daemon's poll loop (already multi-fd).

Rejected alternative, recorded: a control-plane opcode range
partitioned out of the existing client socket. Cheaper, but the
policy verbs would still live in the client protocol's numeric space
and the boundary would be documentary rather than physical.

Consequential amendment to ADR 0012: session_lock (0x0035) and
session_unlock (0x0036) were assigned in the client protocol
(ADR 0012 Section 10) but are unimplemented, so nothing is lost by
migrating them to the same control interface. The same argument that
excludes blank from the client protocol applies to lock with more
force, since lock is the security-critical verb. With the control
socket ratified, ADR 0012 Section 10 carries an amendment note
relocating its verbs there; 0x0035/0x0036 remain permanently reserved
in the client range rather than being reused, so no stale document or
client can ever collide with a reassigned meaning.

## 9. Policy vehicle and sequencing (flagged for ratification)

The blank timeline is policy and lives with the SM-2 per-session agent
(sessiond ADR 0009 D6, 0010 D6). SM-2 is unimplemented. Two options
for shipping the standalone blanker first:

  - (a) Begin the SM-2 daemon now with only the T0 stage: poll
    idle_query (ADR 0013), signal pgsd-sessiond at T0, which issues blank over the
    control interface (Section 8), do nothing else. The lock and suspend stages land in the same
    agent later. Recommended: the agent skeleton is small, and the
    blanker becomes the first tenant of its permanent home.
  - (b) A compositor-internal timeout as an interim (semadrawd blanks
    itself from its own last_input_ts_ns). Rejected as the primary
    path: it splits timeline policy across two owners, contradicting
    the ratified single-agent posture, and would be removed later.

Implementation order under (a): compositor display axis + wake
semantics (this ADR, semadrawd-side), then the minimal agent stage.
The ADR 0012 lock machinery is not a prerequisite for the blanker and
its implementation can proceed independently afterwards, landing on
the same axis model without rework.

## 10. Bench requirements

On pgsd-bare-metal:

  - a blank request from the session authority over the control
    interface darkens the display; the same request from an ordinary
    client (or over a channel it can reach) is rejected with no state
    change;
  - each input class (keyboard, pointer motion, pointer button, touch)
    wakes the display; no input responsible for the wake is observed
    by any client (B5; verify against a client that logs events),
    regardless of the swallowing strategy in use;
  - events after the wake are delivered normally;
  - while UNLOCKED and BLANKED, client input routing is otherwise
    unchanged (B1): a client-visible event stream across a
    blank/wake cycle differs only by the swallowed wake events;
  - with the lock engaged (once ADR 0012 is implemented): blank over
    the lock, wake relights onto the lock prompt, the wake keystroke
    does not appear in the password field, and unlock still requires
    session_unlock (B2);
  - frame callbacks stop while BLANKED and resume on wake;
  - display-state notifications are observed on the control interface
    for every transition, including input-driven wake.

## 11. Consequences

  - The 15-minute blanker ships without lock machinery and without
    future rework: the lock lands on the same axis model.
  - Blanking acquires a permanent, non-security identity (B1), so it
    can never be mistaken for or drift into a weak lock.
  - The compositor gains one small global state (the display axis) and
    one small input-path check (wake), both cheap on the hot path.
  - Sessiond ADR 0009 D3 needs a one-paragraph amendment note; no
    ratified decision is reversed.

## 12. Risks

  - The wake check sits on the input hot path; it must be a branch on
    a local enum, not a lock acquisition or cross-thread query.
  - B5 is easy to state and subtle to satisfy across chords, held
    modifiers, touch, stylus, and accessibility devices; the mechanism
    is deliberately unstandardized (Section 6) so it can evolve, which
    means the bench invariant test, not the ADR, is the guardrail
    against a regressing strategy. Clients must already tolerate
    modifier state established before they gained focus, which bounds
    the harm of imperfect early strategies.
  - If the policy agent dies, the display stops blanking (fails open,
    to ON). This is correct for a presentation feature and the
    mirror-image of the lock's fail-closed rule; stated here so the
    asymmetry is recorded as intended.
