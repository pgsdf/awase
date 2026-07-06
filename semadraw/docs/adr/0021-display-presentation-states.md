# ADR 0021: Display-presentation states orthogonal to session lock

## Status

Draft 2026-07-06, pending operator ratification. Companion to ADR 0012
(session-lock mode, D-10) and ADR 0013 (idle publication, D-11); refines
sessiond ADR 0009 D3 (two-tier blanking) by making the Tier A compositor
blank an independently requestable state rather than a facet of the T1
lock engagement. Decisions flagged for ratification: the two-axis state
model (Section 3), blank authorization (Section 5), wake-event
swallowing including key-release pairing (Section 6), and the interim
policy vehicle (Section 9).

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

## 5. Authorization (flagged for ratification)

display_blank and display_unblank are accepted only from lock-authorized
principals per ADR 0012 Section 4 (bootstrap: peer uid 0). Rationale:
the ratified policy owner is the SM-2 per-session agent whose privileged
actions are routed through pgsd-sessiond (sessiond ADR 0010 D6), so the
requester of blank is the same principal as the requester of lock, and
no new authority class is introduced. A hostile ordinary client can
therefore neither blank the display (nuisance) nor unblank it
(content-hiding bypass when the operator expects a dark screen).

Input-driven wake requires no authorization; it is the point.

## 6. Wake-event semantics (flagged for ratification)

The event that wakes the display is consumed by the compositor and not
delivered to any client, in every security state: a keystroke that
wakes must not type into the focused editor, must not press a button
under the pointer, and must not become the first character of a
password in the lock prompt. Delivery resumes with the next event.

Key-release pairing: the wake key's release arrives after the wake and
would be delivered as an orphan key-up. The compositor records the
waking key's identity and swallows its matching release; all other
events after the wake are delivered normally. If the waking event is
pointer motion or a button, only that event is swallowed (a button-down
wake also swallows its paired button-up, by the same rule). This costs
one small piece of state and buys clean client-visible semantics.

## 7. Presentation and scheduling

While BLANKED the compositor presents the blank fill (B4) and suspends
the frame scheduler: no scene composition, no frame callbacks to
clients whose surfaces are unpresented. Clients keep executing; their
rendering throttles on the absent frame callbacks, which is the
desired behaviour and mirrors the LOCKED treatment of non-lock
surfaces. On wake the scheduler resumes and the first composed frame
reflects whatever the security axis dictates.

Tier A remains a content-hiding and compute-saving measure, not a
power measure (sessiond ADR 0009 D3): the panel and GPU stay on until
Tier B.

## 8. Protocol additions

New client messages: display_blank, display_unblank. New events:
display_blanked, display_unblanked (emitted on every display-axis
transition, including input-driven wake, so the policy agent can
restart its idle timeline without polling races). Numeric assignments
via the protocol pipeline (shared/protocol_constants.json), in the
established ranges, after the ADR 0012 and ADR 0013 assignments.
A display_off opcode is not assigned; Tier B assigns it.

## 9. Policy vehicle and sequencing (flagged for ratification)

The blank timeline is policy and lives with the SM-2 per-session agent
(sessiond ADR 0009 D6, 0010 D6). SM-2 is unimplemented. Two options
for shipping the standalone blanker first:

  - (a) Begin the SM-2 daemon now with only the T0 stage: poll
    idle_query (ADR 0013), request display_blank via pgsd-sessiond at
    T0, do nothing else. The lock and suspend stages land in the same
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

  - display_blank from an authorized principal darkens the display; an
    unauthorized client's display_blank and display_unblank are
    rejected with error_reply and no state change;
  - each input class (keyboard, pointer motion, pointer button, touch)
    wakes the display; the waking event and its paired release are not
    delivered to any client (verify against a client that logs events);
  - events after the wake are delivered normally;
  - while UNLOCKED and BLANKED, client input routing is otherwise
    unchanged (B1): a client-visible event stream across a
    blank/wake cycle differs only by the swallowed wake events;
  - with the lock engaged (once ADR 0012 is implemented): blank over
    the lock, wake relights onto the lock prompt, the wake keystroke
    does not appear in the password field, and unlock still requires
    session_unlock (B2);
  - frame callbacks stop while BLANKED and resume on wake;
  - display_blanked / display_unblanked events are observed for every
    transition, including input-driven wake.

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
  - Swallow-with-release-pairing has modal edge cases (e.g. wake by a
    modifier held through the wake; wake by the second key of a chord).
    The rule "swallow the waking event and its own paired release,
    deliver everything else" is simple and predictable; clients must
    already tolerate modifier state established before they gained
    focus, which is the analogous situation.
  - If the policy agent dies, the display stops blanking (fails open,
    to ON). This is correct for a presentation feature and the
    mirror-image of the lock's fail-closed rule; stated here so the
    asymmetry is recorded as intended.
