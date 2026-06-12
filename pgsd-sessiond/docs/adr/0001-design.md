# 0001 pgsd-sessiond design

## Status

Proposed (2026-05-10).

## Context

PGSD's vt(4) retirement (BACKLOG AD-11) requires a replacement
login provider. This ADR specifies that replacement: a graphical
login daemon, `pgsd-sessiond`, that authenticates users and
launches their UTF sessions.

The design space was explored in the 2026-05-10 working session,
recorded in `docs/sessions/2026-05-10.md`. The key framing
decisions reached there are inputs to this ADR rather than open
questions:

  - **Option Y was selected** over keeping vt(4) in the login
    path. UTF systems boot directly into a graphical login screen
    drawn via UTF; vt(4) remains compiled into the kernel as a
    recovery fallback (boot to single-user mode), but is not
    part of the normal boot path.
  - **The session-manager is desktop-agnostic.** It is a peer
    track to NDE and LT, not a sub-item of NDE. Session types
    are first-class: any session leader the operator configures
    via `.session` files can be launched, including a fullscreen
    `semadraw-term`, an NDE session, or a custom application.
  - **`pgsd-sessiond` lives in the PGSD distribution layer.** The
    `pgsd-` prefix marks distribution-layer components, distinct
    from UTF userland's `sema-` prefix. The substrate has stable
    contracts that a different distribution could in principle
    adopt.
  - **Age attestation is out of scope** as a compliance feature.
    `pgsd-sessiond` provides a generic per-user attribute
    mechanism that operators may use for age-bracket tracking,
    kiosk modes, parental controls, or jurisdictional compliance
    under their own policy. PGSDF makes no compliance claims.
    The position is documented in `docs/POLICY.md` (separate
    work).

Five sub-decisions were resolved in the same session, recorded
in the session memo's coda. They are inputs here, not open
questions:

  1. User enumeration uses `UID > 1000` and shell in
     `/etc/shells`.
  2. A per-user attribute file ships in v1 of `pgsd-sessiond`.
  3. Login screen v1 has no avatars, includes shutdown buttons,
     and exposes a session picker.
  4. `docs/POLICY.md` will document the age-attestation posture
     in a technical tone with the position implicit.
  5. drawcons (kernel-side panic / recovery text rendering in
     drawfs) gets its own ADR before AD-11 reopens.

This ADR specifies `pgsd-sessiond`'s design under those fixed
constraints. It does not specify drawcons or POLICY.md, both of
which are separate work.

## Decision

`pgsd-sessiond` is a privileged system service that authenticates
users and launches per-user UTF sessions. It runs as a UTF client
of system-wide semadrawd, draws a login screen on a high-z-order
surface, accepts credentials via PAM, and on successful auth
drops privilege to the authenticated user and execs that user's
chosen session leader.

It does not own any UTF substrate device. It does not provide
any service consumed by user applications. It does not encode
NDE-specific or any other desktop-specific behaviour. Its
responsibility is bounded: authenticate, launch, clean up on
session exit, return to the login screen.

The daemon is FreeBSD-native: it uses PAM (`libpam`) for
authentication, FreeBSD's standard user database
(`/etc/master.passwd` via `getpwent(3)` / `getpwnam(3)`), and
FreeBSD's privilege-drop primitives (`setuid(2)`, `setgid(2)`,
`initgroups(3)`). It does not introduce a parallel auth or
account model.

## Authentication backend

`pgsd-sessiond` uses PAM. The PAM stack is configured at
`/etc/pam.d/pgsd-sessiond`, parallel to `/etc/pam.d/login` and
`/etc/pam.d/sshd`.

The default stack uses `pam_unix` against `/etc/master.passwd`,
mirroring `login(1)`'s configuration. This inherits FreeBSD
conventions for free:

  - Password hashing per `/etc/login.conf` (bcrypt by default).
  - Account expiry via `pw_expire` in `master.passwd`.
  - Password aging.
  - login.conf classes for resource limits and environment.
  - Lockout policies if configured at the PAM stack level.

Operators may swap `pam_unix` for `pam_ldap`, `pam_krb5`, or
similar without changes to `pgsd-sessiond` itself. The daemon
treats PAM as the boundary; what's behind PAM is the operator's
choice.

The PAM conversation function is implemented in Zig as a wrapper
around `libpam`. The conversation passes prompts and responses
between the login UI and the PAM stack. Echoed and silent prompts
are distinguished so password fields can be rendered with input
suppression.

`pam_open_session` is called after successful authentication and
before privilege drop. `pam_close_session` is called when the
user's session leader exits. This gives PAM modules the standard
hooks for `utmp`/`wtmp` updates, login logging, resource setup,
and session-bound state.

## User enumeration

`pgsd-sessiond` enumerates eligible users by scanning
`/etc/master.passwd` via `getpwent(3)` and including each entry
that satisfies:

  - `pw_uid > 1000`, and
  - `pw_shell` is present in `/etc/shells` (per
    `getusershell(3)`).

UID 1000 itself is excluded. On a typical FreeBSD install UID
1000 is either unset or held by an administrative account that
should not appear in the everyday-user picker. UIDs 0 through
1000 are reserved for root and system accounts.

The `/etc/shells` filter excludes accounts with `nologin` or
similar non-interactive shells, matching the behaviour of `ftpd`
and other services that consult `getusershell`.

Sort order in the login UI is alphabetical by display name with
a fallback chain:

  1. The user's `display_name` attribute from
     `/etc/utf/users/<username>.conf` (if set).
  2. The first comma-separated field of `pw_gecos` (if non-empty).
  3. The username itself.

This produces "Alice Smith" / "Bob Jones" / `cthacker` ordering
that matches user expectation, regardless of whether GECOS is
populated.

The enumeration is performed at daemon start and on receipt of
`SIGHUP`. It is not file-watched; an operator who adds a user
must signal the daemon, which is consistent with FreeBSD service
conventions.

## Per-user attribute file

For each user that passes enumeration, `pgsd-sessiond` reads
`/etc/utf/users/<username>.conf` (if present). This file holds
PGSD-specific per-user metadata that is not stored in
`master.passwd` and not appropriate to bolt onto the upstream
format.

Absence of the file is not an error; defaults apply.

### Format

Plain text, one field per line, format `key = value`. Comments
introduced with `#` extend to end of line. Whitespace around the
`=` is permitted. Unknown keys are warned-and-skipped, not
errors, so future fields can be added without breaking older
deployments.

Example:

    # /etc/utf/users/csmith.conf
    display_name = Catherine Smith
    default_session = nde
    age_bracket = adult
    capabilities = can-shutdown

### Fields (v1)

  - `display_name` (string, optional). UI override of GECOS for
    user-list display. Defaults to the GECOS-or-username chain
    described under user enumeration.

  - `default_session` (string, optional). Name of the `.session`
    file (without extension) under
    `/usr/local/share/pgsd/sessions/` to launch by default for
    this user. If absent, the daemon falls back to a built-in
    default session whose name is configured at daemon-build
    time (likely `default` or `semadraw-term`).

  - `avatar_path` (string, optional, **reserved**). Path to an
    image file to display next to the user's name. The v1 login
    UI does not render avatars. The field is reserved in v1 so
    the file format is stable; v2 will add rendering.

  - `age_bracket` (enum, optional). One of `under-13`, `13-15`,
    `16-17`, `adult`, `unspecified`. Default `unspecified`.
    **Operator-set**, not user-set. **Not exposed to applications
    via any system API.** Not subject to compliance attestation
    by PGSDF. The field exists so operators who deploy PGSD in
    contexts with age-related policy needs (kiosks, school labs,
    parental-control households, jurisdictional regulations
    they choose to honour) have a building block. PGSD does not
    enforce or query this field; that is operator policy.

  - `capabilities` (list, optional). Comma-separated list of
    capability flag strings recognised by `pgsd-sessiond` and
    its login UI. Initial v1 set:
      - `can-shutdown`: user is offered shutdown / restart /
        suspend buttons in the login UI's logout panel (if such
        panel is added in v2; v1 shutdown buttons are unconditional
        per login screen scope).
      - `can-add-users`: reserved for future user-management UI.
    Capability strings are advisory and additive. Where a
    capability has a corresponding FreeBSD group (e.g. `wheel`,
    `operator`), PAM session hooks may be configured to add the
    user to that group at session open and remove at session
    close; this is operator configuration, not built into the
    daemon.

### Read strategy

Read on each login attempt. Not file-watched. If an operator
edits a user's attribute file while the daemon is running, the
change takes effect at the next login for that user. This is
correct for v1: attribute files are operator-managed and change
on a manual-edit cadence, not a high-frequency cadence.

### Creation

Manual editing in v1. A `pgsd-useradd` or similar wrapper that
provisions both the master.passwd entry and the attribute file
is future work, out of scope for SM-1.

## Login UI

### Scope (v1)

  - Vertical list of enrolled users, sorted by display-name
    chain (above).
  - Tap-a-user expands a password field in an overlay.
  - Session-type dropdown adjacent to the user's name, defaulting
    to the user's `default_session`, permitting an explicit
    override for that login. The override does not persist.
  - Shutdown / restart / suspend buttons in a corner (bottom-right
    by convention).
  - **No avatars.** Defer to v2.
  - **No "Other..." escape hatch.** Only enrolled users appear in
    the picker. Administrative accounts at `UID <= 1000` are not
    accessible from the login screen; admin work happens over
    ssh or via single-user mode boot.

### Visual style

Inherits PGSD's visual identity. The monarch butterfly logo
appears prominently. Typography, colour palette, and spacing
follow whatever design tokens PGSD's design system establishes
(out of scope for this ADR; tracked separately under design
work).

### Implementation surface

The login UI is implemented in Zig using semadraw's existing
client surface APIs. It draws to a fullscreen UTF surface and
processes input events via the standard inputfs / semadraw event
delivery path. It does not introduce new UTF protocol surface.

### Power management

Shutdown invokes `shutdown -p now`. Restart invokes
`shutdown -r now`. Suspend invokes `acpiconf -s 3` (where
supported by the platform). The daemon executes these directly,
not via a privilege-broker, because `pgsd-sessiond` already runs
privileged. Power-management commands are gated only by their
own presence in the login UI; there is no separate authorisation
check beyond "the operator chose to expose the buttons."

## Session lifecycle

### `.session` file format

Session types are enumerated from `/usr/local/share/pgsd/sessions/`.
Each file is named `<id>.session` and follows a FreeDesktop-like
key-value format. The minimal field set for v1:

  - `Name`: human-readable display name shown in the picker.
  - `Exec`: command line to execute as the session leader. Run
    in the user's login shell with their environment.
  - `Comment` (optional): single-line description for tooltips.

Parsing is forgiving (unknown keys ignored), to keep the format
extensible. PGSD ships at least one session file in v1
(probably `default.session` or `semadraw-term.session`); NDE
and others install their own when present.

### Launch sequence

After successful PAM auth and selection of a session type:

  1. `pam_open_session` is called with the authenticated user's
     PAM handle. PAM modules run their session-open hooks
     (utmp/wtmp updates, environment setup, etc.).
  2. The daemon `fork(2)`s. Parent retains the PAM handle for
     later `pam_close_session`; child becomes the session leader's
     ancestor.
  3. Child sets up the session: `setsid(2)` to create a new
     session, drops supplementary groups via `initgroups(3)`,
     drops gid via `setgid(2)`, drops uid via `setuid(2)`. After
     these calls the child runs as the authenticated user with
     no privileged residue.
  4. Child sets `PGSD_SESSION_TYPE`, `XDG_RUNTIME_DIR`-equivalent
     (path TBD; likely `/var/run/pgsd/<uid>/`), and other
     environment variables required by the session leader.
  5. Child execs the session leader per the `.session` file's
     `Exec` line, using the user's login shell as the
     interpreter (so shell-dotfile sourcing happens in the
     standard place).
  6. Parent waits for the child to exit (the session leader's
     exit is the session's end).

### Logout

The session ends when the session leader process exits.
`pgsd-sessiond` observes the exit via the `wait(2)` family,
calls `pam_close_session`, tears down the session-specific PAM
handle, and re-displays the login UI.

Any UTF surfaces owned by the logged-out user are torn down by
semadrawd via its disconnect-cleanup path (the multi-user
refactor in AD-31). `pgsd-sessiond` does not separately cancel
the user's surfaces; that is semadrawd's responsibility.

### Crash recovery

If the session leader segfaults or otherwise exits abnormally,
the daemon treats it as a normal logout: `pam_close_session`,
re-display login UI. No special crash UI in v1; the user simply
sees the login screen again and can log in fresh.

If `pgsd-sessiond` itself crashes, the supervisor (s6 or
equivalent) restarts it. Restart is a fresh start; any in-progress
authentication is lost. This is acceptable in v1 because
authentication is user-driven and fast.

## semadrawd interaction model

`pgsd-sessiond` is a UTF client of semadrawd. It does not have
privileged access to the framebuffer, the input device, or any
UTF substrate. Its surface is drawn the same way any other UTF
client draws.

Three properties distinguish `pgsd-sessiond` from ordinary user
clients:

  - **Connection identity.** The daemon connects to semadrawd
    over the local socket. semadrawd uses `getpeereid(3)` to
    identify the connecting uid. `pgsd-sessiond` runs as
    `_pgsd_sessiond` (a dedicated system uid, not root, not
    `_semadraw`). semadrawd recognises this uid as a system
    service and grants it a privileged surface namespace.
    Specifically: high z-order surfaces that overlay user
    sessions, immune to user-side surface manipulation.
  - **Surface namespace.** `pgsd-sessiond`'s surfaces are not
    visible to or addressable by user clients. semadrawd
    enforces this via the per-uid surface namespacing introduced
    in AD-31.
  - **Input routing.** When `pgsd-sessiond`'s login screen is
    visible (no user session is active), all input events are
    delivered to its surfaces. When a user session is active,
    input goes to that user's surfaces and `pgsd-sessiond`'s
    surfaces are hidden. The transition is effected by
    `pgsd-sessiond` issuing a hide-self request before the
    `fork(2)` and a show-self request after the session leader
    exits.

This protocol surface is small but new. It requires AD-31
(semadrawd multi-user refactor) to be in place before stage 9
of the implementation phasing below; stages 1-8 can be
prototyped against the existing single-user semadrawd.

## Security boundaries

`pgsd-sessiond` runs privileged. The privilege surface is the
minimum necessary:

  - Read `/etc/master.passwd`.
  - Read `/etc/utf/users/<name>.conf` for any user.
  - Open and use `libpam` (which requires privilege for
    `pam_unix`).
  - `setuid(2)` to any uid post-auth.
  - Execute power-management commands (`shutdown`, `acpiconf`).
  - Connect to semadrawd's local socket.

It does not need:

  - Direct access to `/dev/draw`, `/dev/inputfs`, audio devices.
  - Network access.
  - Kernel module loading.
  - Filesystem mount/unmount.

`capsicum(4)` may be used in v2 to constrain the daemon's
privileges further. v1 does not use capsicum because the
privilege surface is already small and the bench infrastructure
for capsicum-aware testing is not yet in place.

The TCP listener on port 7234 in semadrawd (currently
unauthenticated) **must be disabled by default** before
`pgsd-sessiond` enters production. It is an unauthenticated
remote-write surface and represents an attack vector that
`pgsd-sessiond` cannot mitigate from its side. Disabling it
is part of the AD-31 work, not part of this ADR.

The login UI displays user names, which is a minor information
disclosure to anyone with physical access to the machine. This
is the standard tradeoff display managers make (gdm, lightdm,
sddm all enumerate users by default). Operators who object can
replace the user list with a username-and-password text entry
in a future variant; not v1.

## Out of scope

Items listed here are intentionally not part of v1 and have
their own future work:

  - **Fast user switching.** v1 is one logged-in user at a time.
    A second user logs in only after the first logs out. The
    framebuffer, surfaces, and session state belong to one user
    or to `pgsd-sessiond`, never split. SM-2 or later may add
    fast user switching.
  - **Screen lock.** v1 does not lock the screen at idle or on
    user request. SM-2 will add a screen-lock daemon that reuses
    the PAM stack from `pgsd-sessiond`.
  - **Auto-login.** v1 always shows the login screen. Auto-login
    (boot-into-session-as-X-without-prompting, for kiosk and
    single-user developer machines) is future work; the
    attribute file's structure already accommodates it as a
    future field.
  - **Session-type discovery from non-standard paths.** v1 reads
    only `/usr/local/share/pgsd/sessions/`. Per-user session
    types under `~/.local/share/pgsd/sessions/` are not
    supported.
  - **Internationalisation.** v1 strings are English only. i18n
    is future work and benefits from waiting until PGSD's broader
    i18n strategy is decided.
  - **Accessibility.** v1 has basic keyboard navigation but no
    screen-reader integration, no high-contrast mode, no
    Braille-display support. These are real gaps that need to
    be closed; the work is future.
  - **A `pgsd-useradd` wrapper.** Manual editing of
    `/etc/master.passwd` and `/etc/utf/users/` is the v1
    provisioning path. A wrapper that creates both atomically
    is convenience future work.

## Implementation phasing

The work breaks into nine stages. Each stage leaves the daemon
in a working, bench-testable state. Stages 1-8 have no dependency
on AD-31 or AD-10 and may proceed against the bench's current
substrate; only stage 9 (boot integration) requires the multi-user
refactor and the framebuffer-handoff work.

This means the daemon can be substantially built and validated
**before** AD-31 lands. The final promotion to boot-time login
provider is gated, but the daemon's authentication and launch
logic are not.

  - **Stage 1: PAM scaffolding.** Zig wrapper around `libpam`
    that does conversation-style auth against a hardcoded user.
    Bench-testable: run as root, type a password, observe
    auth success/failure. No UTF dependency. No daemon
    structure yet; CLI tool.
  - **Stage 2: User enumeration and attribute file reader.**
    Parse `/etc/master.passwd`, filter by `UID > 1000` and
    `/etc/shells`, read `/etc/utf/users/<name>.conf` for each.
    Bench-testable: `pgsd-sessiond --list-users` prints the
    enumeration with merged attributes.
  - **Stage 3: Session leader exec path.** Given an authenticated
    uid and a session-type name, set up environment, drop
    privilege via `setuid`, exec the session leader. Bench-testable:
    `pgsd-sessiond --launch <user> <session>` after PAM auth.
    Combines stages 1 and 2.
  - **Stage 4: `.session` file enumeration and parsing.** Discover
    `/usr/local/share/pgsd/sessions/*.session`, parse, expose to
    the launcher. Bench-testable: `pgsd-sessiond --list-sessions`
    lists available types.
  - **Stage 5: Login UI minimal version.** Connect to semadrawd
    as a UTF client, draw a static screen with the user list,
    accept keyboard input (no password handling yet). Bench-testable
    inside an existing UTF session: `pgsd-sessiond --ui-only`.
  - **Stage 6: Login UI password entry and auth integration.**
    Wire stages 1, 2, 5 together. Tap user → password field
    appears → PAM auth → exec session leader. Bench-testable as
    a user-invoked tool inside an existing UTF session.
  - **Stage 7: Login UI session picker dropdown.** Add
    session-type override per the v1 visual scope. Composes with
    stages 4 and 6.
  - **Stage 8: Login UI shutdown / restart / suspend buttons.**
    Wire to `shutdown` and `acpiconf`. Composes with stage 6.
  - **Stage 9: Boot integration.** rc.d script, supervision
    setup, hooks for "run at boot before any user is logged in."
    **Depends on AD-31** (semadrawd multi-user refactor) and
    **AD-10** (drawfs takes the framebuffer at boot). Promotes
    `pgsd-sessiond` from user-invoked tool to boot-time login
    provider.

Each stage produces a commit (or small commit series) with bench
verification before the next stage starts. If priorities shift
mid-implementation, partial work is still useful: stages 1-3
alone provide a working "graphical su" tool; stages 1-8 alone
provide a testable login UI inside an existing session.

## Consequences

### What this enables

  - PGSD systems boot into a graphical login screen without
    routing through vt(4)'s `getty`/`login` pair.
  - Multiple users can be enrolled and selected at the login
    screen.
  - Sessions are fully per-user with proper privilege drop;
    no session leaks privileges from the daemon.
  - Operators can deploy PGSD in shared-workstation contexts
    (households, school labs, multi-shift work environments)
    with users who don't share credentials.
  - Operators can deploy PGSD in dedicated single-purpose
    contexts (visualization workstations, kiosks) by configuring
    a custom `.session` file and a single user.
  - Per-user attributes provide a building block for
    operator-driven policy (kiosk modes, parental controls,
    age-bracket-based restrictions) without PGSDF making
    compliance claims.
  - The substrate-vs-distribution split is reified in code:
    `pgsd-sessiond` is distribution-layer, depends on UTF
    substrate via stable contracts, and could be replaced by
    a different distribution's session manager without UTF
    changes.

### What this forecloses

  - Plan-9-style host-owner model (one user owns the console
    from boot, no login prompt). Considered and rejected this
    session; that decision is now reified in code.
  - vt(4) as the normal login path. vt(4) remains compiled in
    for recovery only, not for routine logins.
  - Concurrent multi-user sessions in v1. Must be added later
    or never; the v1 design is one-at-a-time.
  - A pure-userland session manager that doesn't need privileged
    access. `pgsd-sessiond` runs privileged because it does
    `setuid` and PAM auth; this is the standard tradeoff
    display managers make.

### What this requires

The following are dependencies, not consequences:

  - **AD-31** (semadrawd multi-user refactor): system-wide
    semadrawd as `_semadraw`, peer-uid surface namespacing,
    privileged-client recognition, TCP listener disabled.
    Required for stage 9.
  - **AD-10** (drawfs takes the framebuffer at boot): under
    Option Y, drawfs becomes the framebuffer driver before
    vt(4) attaches in the normal boot path. Required for stage 9.
  - **AD-4** (graphics layer replacement): drawfs as a complete
    graphics substrate. AD-10 is downstream of this; AD-4 is
    the broader substrate work that AD-10 sits within.

Stages 1-8 of this ADR can proceed before any of those land.

### Documentation owed

  - `docs/POLICY.md`: technical-tone, position-implicit
    statement of PGSD's age-attestation posture. Separate
    work item.
  - `drawfs/docs/adr/0001-drawcons-design.md` (or similar):
    kernel-side panic / recovery text rendering. Required
    before AD-11 reopens; far-future work.
  - README architecture-split section: makes the
    UTF-substrate-vs-PGSD-distribution layering visible at the
    top level. Separate doc commit.
  - BACKLOG reshape: close NDE-4 with forward pointer here,
    open SM track with SM-1 referencing this ADR, reframe
    AD-10 and AD-11, add AD-31. Separate doc commit.

These are recorded for the next session's planning; they are
not part of SM-1 implementation.
