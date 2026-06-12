# 0009 Idle and power management

## Status

Accepted 2026-06-09 (operator-ratified in session). This ADR is SM-3.
It depends on SM-2 (the screen-lock daemon and its idle-detection
plumbing), which is itself open and design-pending, so this ADR defines
the contracts SM-3 needs from SM-2 rather than building on a concrete
mechanism. It fixes the idle and power-management model and its
decisions, including D6 (policy lives in the per-session agent) and D8
(conservative defaults: T1 blank-and-lock at 10 minutes, T2 suspend off
by default), both ratified; the implementable parts wait on SM-2.

## Context

SM-3 covers idle-state tracking and power-management integration:
blanking the display after a configurable idle, suspending the system
on deeper idle, handling resume (which may require re-authentication
per operator policy through SM-2), and the question of an
`XDG_RUNTIME_DIR`-equivalent agent-of-record.

Three pieces of the surrounding system already exist and shape this
design:

  - Suspend is implemented. pgsd-sessiond already offers operator-
    initiated suspend from the login UI via `acpiconf -s 3` through
    `system(3)`, which blocks until the system resumes and then
    returns to the login UI (main.zig). SM-3 reuses this path,
    triggered by idle rather than by a menu choice.
  - The runtime directory is decided. ADR 0005 defines a PGSD-native
    runtime directory at `/var/run/pgsd/<uid>/` on tmpfs, created by
    pgsd-sessiond, and exports both `PGSD_RUNTIME_DIR` and
    `XDG_RUNTIME_DIR` pointing at it. The `XDG_RUNTIME_DIR`-equivalent
    question SM-3 was tagged with is therefore mostly answered already.
  - There is no display power-down primitive. drawfs presents
    framebuffers (page flip, vblank) but exposes no DPMS, backlight,
    or output-power control. True display power-down depends on native
    output control that does not exist yet (AD-4) or the DRM path
    (DF-6, hardware-bench-owed).

SM-3 is desktop-agnostic like the rest of the SM track: it does not
depend on NDE and encodes no NDE-specific behaviour.

## Decision

### D1: a staged idle timeline

SM-3 acts on a configurable idle timeline with two thresholds:

  - T1 (shallow idle): blank the display and engage the lock.
  - T2 (deep idle, T2 > T1): suspend the system.

Both thresholds are operator-configurable. Each is independently
disablable: an operator may blank-and-lock but never auto-suspend, or
disable idle handling entirely. The shipped defaults are conservative
and a deliberately separate decision (D8); the mechanism does not
assume any particular timeout.

### D2: idle detection is SM-2's, consumed through a contract

SM-3 does not detect idle itself and does not read the inputfs
substrate directly. Idle detection belongs to SM-2, which derives it
from input activity (the inputfs event stream carries timestamps).
Because SM-2 is unbuilt, SM-3 defines the contract it needs:

  - SM-2 exposes, per session, a monotonic idle measure: either a
    last-input timestamp against the chronofs monotonic clock or an
    idle-seconds counter SM-3 can read cheaply and often.
  - The measure resets to zero on any input activity SM-2 recognises.
  - SM-3 reads it to drive the T1 and T2 transitions; SM-2 owns how it
    is computed.

This keeps the layering clean: SM-2 owns idle plumbing and the lock,
SM-3 owns the power-action policy on top.

### D3: display blanking is two-tier

There is no display power-down primitive today (see Context), so
blanking is staged:

  - Tier A, available now: a compositor-level blank. At T1 the lock
    surface (SM-2) covers the screen; SM-3 additionally requests a
    blank presentation (a black surface) so no application content is
    visible. This hides content and pairs with the lock but does not
    save power: the GPU and backlight stay on.
  - Tier B, future: true display power-down (DPMS-off or backlight-off
    for real energy saving). This requires a drawfs output-power
    primitive that does not exist; it is contracted against AD-4
    (native output) or DF-6 (DRM), and SM-3 adopts it when available.

Consequently the energy saving at idle comes from suspend (D4), not
from blanking, until Tier B lands. Tier A is a security and
content-hiding measure, not a power measure.

### D4: suspend reuses the existing acpiconf path

At T2, SM-3 triggers the same `acpiconf -s 3` (ACPI S3) path
pgsd-sessiond already uses for operator-initiated suspend. This is the
operator-tested mechanism and the real energy win at deep idle.

Platform caveat: S3 reliability is hardware-dependent and must be
confirmed on the bench for idle-triggered round-trips. This is
distinct from the S5 poweroff-reboots issue diagnosed earlier (the
`hw.efi.poweroff` EFI ResetSystem behaviour), which concerns
`shutdown -p` and does not apply to S3 suspend.

### D5: resume and re-authentication hand off to SM-2

On resume, whether re-authentication is required is operator policy,
owned by SM-2. SM-3's contract:

  - SM-3 ensures the lock is engaged at T1 (and therefore before any
    T2 suspend), so resume lands on an already-locked screen.
  - SM-2 performs the unlock conversation (the same PAM stack SM-1 and
    SM-2 use); SM-3 does not authenticate.
  - If operator policy is no-re-auth, SM-2 dismisses the lock without a
    PAM exchange; SM-3 is unaffected either way.

SM-3 never tears down the session across blank, suspend, or resume; it
only drives power state and defers all credential handling to SM-2.

### D6: the idle/power policy lives in SM-2's per-session daemon

SM-3 is not a new daemon and is not pgsd-sessiond logic. It is the
power-action policy added to SM-2's per-session screen-lock daemon,
which already owns idle detection and the lock surface. Co-locating
the timeline, the blank, and the suspend trigger with idle detection
and the lock keeps one per-session agent responsible for the whole
idle-to-resume arc, avoids a second daemon reading the same idle
signal, and matches the SM-2 design (a small daemon launched per
session by the session leader). pgsd-sessiond stays the login and
session-leader manager; it is not a per-session idle agent.

This is the main structural decision and is flagged for ratification.

Refinement (per ADR 0010, the SM-2 screen-lock design): the per-session
agent owns idle detection and the timeline and issues secret-free
triggers, but the lock surface, the password interaction, and the
privileged power actions are performed by pgsd-sessiond, so no
credential ever lives in the user-level agent. "Owns the lock" here
means owns the policy of when to lock, not the authentication itself.

### D7: XDG_RUNTIME_DIR defers to ADR 0005

The runtime directory and its environment variables are already
decided by ADR 0005 (`/var/run/pgsd/<uid>/`, exported as both
`PGSD_RUNTIME_DIR` and `XDG_RUNTIME_DIR`, created by pgsd-sessiond).
SM-3 adopts that and adds nothing structural:

  - The directory is tmpfs and survives suspend and resume (no
    reboot), so SM-3's power actions do not affect it.
  - pgsd-sessiond remains the agent-of-record for creation at login.
  - The one open refinement, only if PGSD supports concurrent sessions
    for the same uid, is lifecycle across multiple sessions
    (reference-count the directory, remove on last logout). If
    concurrent same-uid sessions are not supported, this is punted.

SM-3 therefore resolves the `XDG_RUNTIME_DIR`-equivalent question by
reference rather than by re-deciding it.

### D8: shipped default timeouts (separate, conservative)

Defaults are deliberately separated from the mechanism. The proposed
conservative starting point, subject to ratification: T1 (blank and
lock) at 10 minutes, T2 (suspend) disabled by default. A laptop or
battery profile may enable T2; a desktop or always-on profile may
leave it off. Defaults are operator-overridable through the SM
configuration surface.

## Dependencies

  - SM-2 must land first: SM-3 has no idle signal and no lock without
    it (D2, D5).
  - Tier B blanking (D3) depends on a drawfs output-power primitive
    (AD-4 or DF-6); Tier A and suspend do not.
  - Suspend (D4) reuses the existing pgsd-sessiond path; no new
    mechanism.

SM-3 is therefore not implementable until SM-2 exists. This ADR
records the model, the SM-2 contract, and the decisions so SM-2 can be
designed with SM-3's needs in view.

## Consequences

  - One per-session agent (SM-2's daemon, extended) owns idle, lock,
    blank, suspend, and resume, with pgsd-sessiond unchanged.
  - Until Tier B lands, idle energy saving is suspend-only; shallow
    idle hides content but does not save power.
  - The `XDG_RUNTIME_DIR` story needs no new work beyond ADR 0005
    except the optional multi-session refcount.

## Risks

  - S3 suspend reliability is platform-dependent; idle-triggered
    suspend must be bench-verified on pgsd-bare-metal, separately from
    the settled S5 poweroff issue.
  - A blank that hides content without powering down (Tier A) may be
    mistaken for an energy measure; the ADR states plainly it is not.
  - SM-3 cannot be validated until SM-2 exists; the contracts in D2 and
    D5 must be honoured when SM-2 is designed, or this ADR is revised.
