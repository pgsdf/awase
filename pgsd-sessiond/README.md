# pgsd-sessiond

PGSD's graphical login provider. Authenticates users against the
system password database via PAM, then launches their chosen UTF
session.

## What it is

`pgsd-sessiond` is the replacement for `vt(4)`'s `getty`/`login`
pair on PGSD systems. When a PGSD machine boots, instead of
landing on a text console with a login prompt, it boots into a
graphical login screen drawn by `pgsd-sessiond`. After successful
authentication, the daemon drops privilege to the authenticated
user and execs the session leader specified by that user's
`default_session` attribute (commonly a fullscreen `semadraw-term`
or an NDE session).

The component sits in the PGSD distribution layer (the `pgsd-`
prefix marks distribution-layer components, distinct from UTF
userland's `sema-` prefix). It depends on UTF substrate via
stable contracts but is not part of UTF itself; a different
distribution built on UTF could supply its own session manager
in place of `pgsd-sessiond`.

## What it is NOT

  - A desktop environment. Session leaders (semadraw-term, NDE,
    LT, custom applications) are separate; `pgsd-sessiond` only
    authenticates and launches them.
  - An X11 display manager. PGSD is not X11-based; the login
    screen draws via UTF/semadraw.
  - A DBus session manager. Userspace IPC is not in scope.
  - A user-account management tool. Account creation and
    modification continue to use FreeBSD's `pw(8)`,
    `vipw(8)`, and friends. A future `pgsd-useradd` wrapper
    may automate creating both the master.passwd entry and
    the per-user attribute file in one step, but is not part
    of v1.
  - An age-attestation or compliance system. The attribute file
    includes an `age_bracket` field as a building block for
    operators who deploy in contexts with age-related policy
    needs, but PGSDF makes no compliance claims. The position
    is documented in `docs/POLICY.md` (separate work).

## Current state

`pgsd-sessiond` is **in design**. No code has been written yet.
The design ADR (`docs/adr/0001-design.md`) specifies the
architecture and a nine-stage implementation plan. Subsequent
ADRs in this directory specify the formats and protocols that
the design ADR leaves at the "described but not fully nailed
down" level.

Stage progress:

  - Stage 1: PAM scaffolding CLI tool. **Not started.**
  - Stage 2: User enumeration and attribute file reader. **Not started.**
  - Stage 3: Session leader exec path with privilege drop. **Not started.**
  - Stage 4: `.session` file enumeration and parsing. **Not started.**
  - Stage 5: Login UI minimal version (static screen, no auth). **Not started.**
  - Stage 6: Login UI password entry wired to PAM auth. **Not started.**
  - Stage 7: Login UI session picker dropdown. **Not started.**
  - Stage 8: Login UI shutdown / restart / suspend buttons. **Not started.**
  - Stage 9: Boot integration. **Not started.** Gated on AD-32 and AD-10.

Stages 1-8 do not depend on AD-32 (semadrawd multi-user refactor)
or AD-10 (drawfs takes the framebuffer at boot). They can be built
and validated against the current single-user substrate. Only
stage 9 requires those prerequisites.

## Layout

```
pgsd-sessiond/
  README.md                       this file
  docs/
    adr/
      0001-design.md              the design ADR
      0002-pam-stack.md           /etc/pam.d/pgsd-sessiond content (planned)
      0003-attribute-file.md      /etc/utf/users/*.conf format (planned)
      0004-session-file.md        /usr/local/share/pgsd/sessions/*.session format (planned)
      0005-runtime-environment.md /var/run/pgsd/<uid>/ and env vars (planned)
      0006-semadrawd-protocol.md  hide-self / show-self protocol (planned)
  src/                            Zig source, written stage-by-stage (planned)
  build.zig                       Zig build script (planned)
```

When code work begins, the `src/` and `build.zig` will appear and
this layout section will be updated.

## Dependencies

### Build-time

  - **Zig** 0.15.2 or compatible (matches the rest of UTF).
  - **FreeBSD libpam** (`-lpam`, the OpenPAM implementation that
    ships in FreeBSD base).
  - **FreeBSD libc** for `setuid`, `setgid`, `initgroups`,
    `getpwnam`, `getusershell`, the standard credential and
    user-database primitives.

No external Zig dependencies beyond what UTF substrate already
uses (the `shared/` modules).

### Runtime

  - **A working UTF substrate**: drawfs, inputfs, semadrawd
    running. `pgsd-sessiond` is a UTF client of semadrawd.
    Stages 5-9 won't function without it; stages 1-4 are
    CLI tools and don't require UTF.
  - **A configured PAM stack** at `/etc/pam.d/pgsd-sessiond`.
    Stage 1 of the implementation falls back to `/etc/pam.d/login`
    if the pgsd-sessiond service file isn't installed; later
    stages require it.
  - **At least one `.session` file** at
    `/usr/local/share/pgsd/sessions/`. Stage 4 onward depends on
    finding session types here.

## How to use it

Until code lands, there is nothing to run. Once stage 1 ships,
the bench test will be:

```
pgsd-sessiond --auth-test <username>
```

Stages 2 and 3 add `--list-users` and `--launch <user> <session>`.
Stages 5-8 add `--ui-only` and related UI test modes. Stage 9
adds the daemon mode and rc.d integration. See the design ADR
for the per-stage testable artefacts.

## Background reading

In order of usefulness for someone new to the design:

  - `docs/adr/0001-design.md` (this directory): the design ADR.
    Read first.
  - `../docs/sessions/2026-05-10.md`: the working session memo
    where the design was hammered out. Covers Option Y selection
    (graphical login via PAM), the rejection of Plan 9 host-owner
    model, and the sub-decisions on user enumeration and age
    attestation.
  - `../docs/sessions/2026-05-11.md`: follow-up session covering
    AD-31.1 (semadrawd privilege drop, the closest analogue
    pgsd-sessiond will face).
  - `../BACKLOG.md`: the SM-1 backlog entry for this work,
    plus AD-32 and AD-10 dependency entries.

## Conventions

`pgsd-sessiond` follows the UTF repo conventions:

  - **Zig** for new code.
  - **No em dashes** in prose or documentation.
  - **No emoji** in technical docs.
  - **Documentation at the component level**: design and spec
    docs live in this directory's `docs/adr/`, not in the
    repo-wide `docs/`.

Repository-wide build and test still flow through the top-level
`build.zig`; pgsd-sessiond's `build.zig` is invoked from there
the same way `semaaud`, `semainput`, and the other subprojects
are.
