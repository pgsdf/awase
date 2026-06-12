# 0010 Screen-lock daemon

## Status

Accepted 2026-06-09 (operator-ratified in session). This ADR is SM-2.
It depends on SM-1 (ADR 0001 session model, ADR 0002 PAM stack, ADR
0005 runtime directory) and surfaces substrate requirements that gate
its secure form (see Dependencies). SM-3 (ADR 0009) co-locates its idle
and power policy in this daemon. D2 and D3 (re-authentication entirely
within pgsd-sessiond, no cleartext in user space or transit) and D4
(secure-only, no best-effort interim lock) are ratified under the
mandate to work toward a secure environment.

Revised 2026-06-09: re-authentication is performed entirely by
pgsd-sessiond so that the cleartext password never enters a user-level
process or a socket (D2, D3). This supersedes the initial draft, in
which a user-level lock daemon forwarded the password to pgsd-sessiond
over a socket.

## Context

SM-1 (ADR 0001) explicitly defers screen locking to SM-2: v1 does not
lock the screen at idle or on request. The PAM conversation pgsd-
sessiond uses for login is reusable (ADR 0002). A screen lock has three
needs, and each meets a constraint in the system as it stands:

  - Re-authentication needs privilege. The lock daemon runs per session
    as the user. A non-root process cannot verify the user's password:
    the hash in master.passwd is root-only, so `pam_authenticate`
    against pam_unix cannot run unprivileged.
  - A secure lock needs compositor enforcement. semadraw has no
    session-lock primitive (only a composition mutex). A client that
    merely sets a top z-order and grabs input is not a boundary: a
    buggy or hostile client, or the window manager, could present above
    it or take input. The proposed set-focus (D-7) and grab (D-8) are
    window-manager conveniences, not a security boundary.
  - Idle detection needs a global last-input signal. semadrawd already
    tracks `last_input_ts_ns` internally (semadrawd.zig) but does not
    publish it to clients.

SM-2 is desktop-agnostic, like the whole SM track: it must lock
regardless of NDE, and the lock must override desktop (window-manager)
policy, since a lock is a security boundary and the WM is policy.

## Decision

### D1: a per-session lock daemon that never tears down the session

SM-2 is a small daemon launched per session by the session leader. It
presents a lock surface and dismisses it on successful
re-authentication. It never execs a new session leader and never tears
down the session: the session leader and its children keep running
behind the lock. It locks on explicit request and on idle (D5, with
SM-3's timeline in ADR 0009).

### D2: pgsd-sessiond owns the password interaction; no cleartext leaves the authenticator

The password is never present in a user-level process and is never
sent over a socket. The process that re-authenticates is pgsd-sessiond:
the root parent that authenticated the login, alive for the whole
session (it forked the session leader and waits, ADR 0001), owner of
the PAM conversation (ADR 0002), and crucially a process that sits
outside the trust boundary of the session it locks.

On lock, triggered by a secret-free signal (D6), pgsd-sessiond drives
the whole password interaction itself:

  - It becomes the lock client under the compositor's secure-lock mode
    (D3): it draws the password prompt, reusing its existing login-UI
    rendering, and the compositor routes keyboard input to it.
  - It accumulates the password directly into a locked, non-pageable
    buffer (`mlock`), runs `pam_authenticate` plus the account chain for
    the session's user, and zeroes the buffer (`explicit_bzero`)
    immediately after. The cleartext is never written to disk or logged.
  - On success it requests unlock (D3); on failure it reprompts.

So the cleartext exists only transiently in pgsd-sessiond, the same
root process that already held it at login, and nowhere else. There is
no user-level lock daemon holding the secret and no password-forwarding
socket.

Keystrokes still pass through semadrawd, which routes all input and is
inherently in the input trusted path; this is true of any
compositor-mediated password entry and is not worsened here. semadrawd
forwards individual key events and never reassembles or stores the
password; reassembly happens only in pgsd-sessiond.

This supersedes an earlier forwarding design (a user-level lock daemon
sending the password to pgsd-sessiond over a unix socket). Moving the
collection into pgsd-sessiond removes cleartext from user space and
from transit, and places the authenticator outside the session it
guards rather than inside it. The cost is that pgsd-sessiond gains a
lock interaction (connect to semadrawd on trigger, draw, collect,
verify, unlock) on top of its login UI; it needs no setuid helper and
no second PAM stack.

### D3: a compositor-enforced secure-lock mode with pgsd-sessiond as the lock client (semadraw substrate requirement)

A secure lock must guarantee, while locked: only the lock surface is
presented, all input is routed to it, and no other client (including
the window manager) can present above it or receive input, until the
lock client authenticates and requests unlock. semadraw cannot do this
today.

Decision: define a semadraw session-lock contract as a new substrate
item (the ext-session-lock analogue):

  - An authorized lock client, pgsd-sessiond (D2), requests lock;
    semadrawd enters a locked state.
  - While locked, semadrawd presents only the lock client's surface and
    routes all input, including the keyboard for the password, to it,
    ignoring every other surface's presentation and input, overriding
    window-manager policy.
  - pgsd-sessiond authenticates the input it receives (D2) and requests
    unlock; semadrawd leaves the locked state.
  - Lock authority is distinct from the window-manager privilege
    (SEMADRAW_PRIVILEGED_UID). The lock must be enforceable over the WM,
    so it cannot route through WM privilege. Because the lock client is
    pgsd-sessiond (root, outside the user session), the authorization
    model can be "the session's authenticator may enter lock mode"
    rather than a lock capability handed to a user-level client, which
    is both simpler and safer; the exact model is part of that semadraw
    item's own ADR.

z-order, set-focus (D-7), and grab (D-8) do not substitute for this:
they are defeatable by the parties the lock must defend against.

### D4: v1 scope, secure-only

Two options were weighed:

  - (a) Ship SM-2 only against the secure-lock contract (D3); SM-2 is
    not usable until the semadraw lock mode lands. Clean security,
    later.
  - (b) Ship a v1 best-effort lock now (top z-order plus grab via D-7
    and D-8), documented loudly as NOT a security boundary: it deters
    casual access but not a hostile client, a buggy client, or a
    compromised WM. Harden to the secure mode when D3 lands.

Decision: (a), secure-only (operator-ratified 2026-06-09, under the
mandate to work toward a secure environment). A lock that is not a
boundary invites false confidence, which for a security feature is
worse than no lock. SM-2 ships only against the compositor-enforced
session-lock mode (D3); there is no best-effort interim lock.

### D5: idle detection by publishing semadrawd's existing last_input_ts_ns

semadrawd already maintains `last_input_ts_ns`; it is not published.
Decision: semadrawd publishes it (a small readable value in a stats or
idle region, or via a query); SM-2 reads it and computes idle against
the chronofs monotonic clock.

  - Requirement: `last_input_ts_ns` must reflect all input (keyboard,
    pointer, gesture). It is updated today in the event-forwarding path;
    confirm on the substrate that every input class updates it, and
    extend it if it does not, or idle detection will miss activity and
    lock spuriously.
  - This is the idle-detection plumbing the SM-2 entry and SM-3 (ADR
    0009 D2) refer to. It is a small semadraw addition (expose an
    existing value), separate from the secure-lock mode (D3).

SM-2 owns idle detection and applies its own lock timeout; SM-3's power
timeline, co-located in this daemon (ADR 0009 D6), reads the same idle
measure internally.

### D6: relationship to SM-3, and where policy versus secrets live

SM-3's idle and power timeline (ADR 0009 D6) decides when to act and
carries no credentials. It reads the idle measure (D5); on T1 it
signals pgsd-sessiond to lock, and on T2 it reuses pgsd-sessiond's
`acpiconf -s 3`. pgsd-sessiond owns everything privileged or
secret-bearing: the password interaction (D2), the locked state as the
lock client (D3), and suspend.

This refines ADR 0009 D6. The per-session policy agent still owns the
idle and power timeline, but credential handling and the privileged
actions move to pgsd-sessiond, and the trigger from the agent to
pgsd-sessiond carries no secret (just "lock now" or "suspend now").
Whether that policy agent is a thin per-session daemon or folded into
pgsd-sessiond's own wait loop is a secondary structural choice; either
way no secret ever lives in a user-level process.

## Dependencies (substrate and SM-1 hooks)

  - pgsd-sessiond lock interaction (D2, D3): on a secret-free lock
    trigger, connect to semadrawd, enter the lock mode, draw the
    prompt, collect and verify the password, and unlock. This replaces
    the earlier unlock-socket idea. pgsd-sessiond-side work.
  - semadraw session-lock mode (D3): a new semadraw item; gates the
    secure SM-2. Distinct from D-7 and D-8.
  - semadraw `last_input_ts_ns` publication (D5): a small new semadraw
    item; required for idle detection and for SM-3.

SM-2's secure form is therefore gated on two semadraw additions and the
pgsd-sessiond lock interaction. This ADR records the design and
contracts; the implementable parts wait on them.

## Consequences

  - The cleartext password never enters a user-level process or a
    socket; it lives only transiently in pgsd-sessiond, the root
    authenticator that already held it at login, in `mlock`ed memory
    zeroed after use.
  - The authenticator sits outside the trust boundary of the session it
    locks, rather than inside it as a user-level daemon.
  - No setuid binary and no second PAM stack.
  - One per-session policy agent owns the idle and power timeline;
    pgsd-sessiond owns the privileged and secret-bearing actions.
  - The idle plumbing (D5) is cheap; the secure-lock mode (D3) is the
    substantial substrate dependency.

## Risks

  - The cleartext password lives only in pgsd-sessiond, in `mlock`ed
    memory zeroed (`explicit_bzero`) after use; it never enters a
    user-level process or a socket. Keystrokes still transit semadrawd,
    which is inherent to any compositor-mediated password entry;
    semadrawd routes individual key events and does not reassemble or
    store them.
  - Without D3 any lock is best-effort; shipping (b) risks false
    confidence and must be documented at every appearance of the lock.
  - If `last_input_ts_ns` does not cover all input classes, idle
    detection misses activity and locks spuriously; verify before
    relying on it.
  - Lock authority distinct from WM privilege must be designed so an
    ordinary client cannot spoof a lock; that is the D3 item's
    authorization model.
