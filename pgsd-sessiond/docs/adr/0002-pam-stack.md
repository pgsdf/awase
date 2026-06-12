# 0002 PAM stack for pgsd-sessiond

## Status

Proposed (2026-05-14).

## Context

ADR 0001 specifies that `pgsd-sessiond` uses PAM for authentication
and that the PAM stack is configured at `/etc/pam.d/pgsd-sessiond`.
It does not specify the contents of that file. This ADR does.

The audience for this ADR is two-fold:

  - The pgsd-sessiond implementation, which must know the service
    name to pass to `pam_start(3)` and the assumptions it can make
    about which PAM facilities are available.
  - The operator who installs PGSD and may customise the stack
    for their site (LDAP, Kerberos, two-factor, etc.).

The constraints, inherited from ADR 0001:

  - PAM is the authentication boundary; pgsd-sessiond does not
    speak `getpwnam` directly for password verification.
  - The default stack uses `pam_unix` against `/etc/master.passwd`,
    matching `login(1)`'s convention.
  - Password hashing follows `/etc/login.conf` (bcrypt by default).
  - Account expiry, password aging, and login class resource
    limits are honoured.
  - PAM `open_session` is called after auth, `close_session` after
    the session leader exits.
  - Operators may swap `pam_unix` for `pam_ldap`, `pam_krb5`,
    `pam_oath`, etc., without changes to pgsd-sessiond itself.

## Decision

`/etc/pam.d/pgsd-sessiond` is a thin wrapper that delegates to
the system-wide PAM policy file at `/etc/pam.d/system`, with a
small number of service-specific additions for the parts where
pgsd-sessiond's semantics differ from `login(1)`'s.

The choice to delegate via `include system` rather than enumerate
every module explicitly matches the convention used by FreeBSD's
own `/etc/pam.d/login`, `sshd`, and `xdm` files. It inherits
operator-driven changes to `system` (added Kerberos, added LDAP,
disabled bcrypt rounds adjustment) without requiring a parallel
edit to pgsd-sessiond.

The file content:

```
#
# PAM configuration for the "pgsd-sessiond" service.
#
# pgsd-sessiond is PGSD's graphical login provider. This stack
# authenticates and authorises users at the login screen, then
# opens a session that the daemon hands to the chosen session
# leader.
#
# Most of the work is delegated to /etc/pam.d/system. The
# pgsd-sessiond-specific entries are:
#
#   account: pam_nologin (respects shutdown's nologin file)
#   account: pam_login_access (respects /etc/login.access)
#
# These are added explicitly rather than relying on system because
# they are appropriate for an interactive login session but not
# for every service that includes system (e.g. xdm doesn't use
# them by default on stock FreeBSD; cron explicitly skips them).
#

# auth
auth        include     system

# account
account     required    pam_nologin.so
account     required    pam_login_access.so
account     include     system

# session
session     include     system

# password
password    include     system
```

Each section is discussed below.

## Auth chain

`auth include system` delegates to `/etc/pam.d/system`'s auth
chain. On stock FreeBSD 15, that chain calls `pam_unix.so` with
`no_warn try_first_pass nullok` (and optionally `pam_krb5`,
`pam_ssh`, `pam_opie` if the operator has un-commented them).

pgsd-sessiond adds nothing service-specific here. The
conversation function (provided by the pgsd-sessiond daemon, not
by PAM) is what mediates the password entry through the login UI;
the modules don't know they're talking to a graphical client.

`pam_self.so` (succeed if applicant equals target) is NOT
included. `pam_self` is appropriate for su-like flows where the
applicant authenticates as themselves; pgsd-sessiond's applicant
is the daemon (running as `_pgsd_sessiond`), never the same as
the target user.

`pam_securetty.so` (require login on a "secure" tty per
`/etc/ttys`) is NOT included. The login screen does not run on a
tty in the traditional sense; pgsd-sessiond is a UTF client.
Adding `pam_securetty` would require fabricating a tty name to
satisfy the check, which obscures rather than enforces the
policy. Per ADR 0001, pgsd-sessiond excludes UID ≤ 1000 at the
user-enumeration layer, which is the relevant safety property
that `pam_securetty` would otherwise provide for root.

## Account chain

Two service-specific modules precede `include system`:

  - **`pam_nologin.so`**: refuses non-root logins when
    `/var/run/nologin` exists. `shutdown(8)` creates this file
    five minutes before a scheduled shutdown to prevent new
    logins during the shutdown window. Without `pam_nologin`,
    pgsd-sessiond would let users log in seconds before
    their session is terminated.

  - **`pam_login_access.so`**: enforces `/etc/login.access`,
    the per-user / per-group / per-tty access control file.
    Operators who restrict console logins via login.access
    expect that restriction to apply to graphical logins too.

Both are marked `required` (any failure terminates the chain).
This matches `/etc/pam.d/login`'s configuration.

`include system` then runs the system-wide account chain, which
on stock FreeBSD 15 invokes `pam_unix.so` for the standard
account-expiry and password-aging checks.

## Session chain

`session include system` delegates entirely to the system-wide
session chain. On stock FreeBSD 15 this is `pam_permit.so`
(no-op) plus any operator-added modules (commonly `pam_lastlog`,
`pam_mkhomedir`, `pam_limits` etc.).

pgsd-sessiond calls `pam_open_session(3)` after successful
authentication and before forking the session leader. It calls
`pam_close_session(3)` after the session leader exits. These
hooks give PAM modules the standard points for `utmp`/`wtmp`
updates, login logging, resource setup, and any
session-bound state.

The `utmp`/`wtmp` updates matter for `who(1)` and `last(1)` to
show graphical logins the same way they show text logins. UTF
operators should not need to consult a separate "graphical login
log" for routine session tracking.

## Password chain

`password include system` delegates to the system-wide password
chain. pgsd-sessiond v1 does NOT call `pam_chauthtok(3)`, so this
chain is dormant in practice. The entry is present so the file
has a complete set of chains; if v2 adds a password-change UI
(prompted when PAM returns `PAM_NEW_AUTHTOK_REQD` during auth),
the chain is already wired.

If a user's password is expired and `pam_acct_mgmt(3)` returns
`PAM_NEW_AUTHTOK_REQD`, pgsd-sessiond v1 displays an error
("Password expired; log in via ssh or text console to change
it") and aborts the login. v2 will offer in-line password change.

## Installation

`/etc/pam.d/pgsd-sessiond` is installed by `install.sh`
(specifically by the pgsd-sessiond install path, which does not
exist yet but will be added when pgsd-sessiond code lands).

The installer is **idempotent and non-destructive**:

  - If `/etc/pam.d/pgsd-sessiond` does not exist, install the
    default content (the file shown above).
  - If `/etc/pam.d/pgsd-sessiond` exists, leave it untouched and
    log a note. Operators who have customised the file (added
    Kerberos lines, swapped pam_unix for pam_ldap, etc.) should
    not have their changes silently reverted on every install.

The package install hook may use `mtree(8)`'s standard mechanism
for shipping default configuration: install to `/etc/pam.d/`
with NOSCHG and let `mergemaster(8)` / `etcupdate(8)` mediate
operator customisation, matching FreeBSD's broader convention
for `/etc` files. This is the approach the eventual `pgsd-base`
package will use; the standalone `install.sh` uses a simpler
"create-if-absent" rule.

## Operator customisation

Operators may edit `/etc/pam.d/pgsd-sessiond` directly. The
changes pgsd-sessiond cares about, in decreasing order of likely
operator interest:

  - **Adding a second factor.** Insert `pam_oath.so` (TOTP) or
    `pam_yubico.so` (YubiKey) into the auth chain ahead of
    `include system`, marked `requisite` or `required`. The
    daemon does not need code changes; the conversation
    function will prompt for the second factor's input style.

  - **Replacing `pam_unix` with a directory service.** Swap
    `pam_unix.so` for `pam_ldap.so` in `/etc/pam.d/system`
    (system-wide) or override locally by removing the
    `include system` and listing modules explicitly.

  - **Restricting which users see the login screen.** Adding
    `pam_group.so` or `pam_listfile.so` to the account chain
    can restrict beyond UID > 1000. Note: this only affects
    PAM auth; pgsd-sessiond's user enumeration is independent
    and runs from `/etc/master.passwd` + `/etc/shells`. Users
    can still be visible in the login screen but rejected by
    PAM. ADR 0001 says enumeration is the daemon's filter;
    PAM is the second filter. Customisation should normally
    be done at both layers.

  - **Adding `pam_mkhomedir.so` to the session chain.** Useful
    for sites with networked home directories that don't
    auto-create on first login.

Customisations that pgsd-sessiond does NOT support:

  - **Interactive password change embedded in auth.** Adding
    `pam_chauthtok` to the auth chain is not supported in v1.
    The daemon does not handle `PAM_NEW_AUTHTOK_REQD` as an
    in-band password change.

  - **Hardware tokens that require physical access between
    prompts.** The daemon's conversation function is purely
    text-prompt-and-response; modules that require pressing a
    button between separate PAM calls (e.g. some smart-card
    modules) are not supported in v1.

## Bench testing

Stage 1 of the pgsd-sessiond implementation can be tested
against this stack as follows:

```
# 1. Install the stack.
sudo install -m 0644 /path/to/pgsd-sessiond.pam /etc/pam.d/pgsd-sessiond

# 2. Verify the stack parses (FreeBSD's pamtester(1) from ports
#    is the standard tool; if not installed, the next-best test
#    is running stage-1 pgsd-sessiond itself).
pamtester pgsd-sessiond vic authenticate acct_mgmt

# 3. Confirm operator customisations don't break the stack.
echo 'auth requisite pam_deny.so' > /tmp/pgsd-sessiond.test
sudo cp /tmp/pgsd-sessiond.test /etc/pam.d/pgsd-sessiond
pamtester pgsd-sessiond vic authenticate    # must fail
sudo install -m 0644 /path/to/pgsd-sessiond.pam /etc/pam.d/pgsd-sessiond
pamtester pgsd-sessiond vic authenticate    # must succeed
```

A pgsd-sessiond-side test in stage 1 will exercise the same path
without `pamtester`, by invoking the daemon's CLI auth mode
against a known user.

## Consequences

### What this enables

  - pgsd-sessiond authenticates against the same user database
    as `login(1)` and `sshd(8)` with no behavioural divergence.
  - Operator configuration changes in `/etc/pam.d/system` (the
    most commonly customised PAM file on FreeBSD) propagate
    automatically.
  - Sites that have already invested in Kerberos, LDAP, or two-
    factor PAM stacks pick those up without further work.
  - `last(1)`, `who(1)`, `lastlog` work for graphical logins
    via the session chain's standard hooks.

### What this forecloses

  - A pgsd-sessiond-only authentication path that doesn't use
    `/etc/pam.d/`. Considered briefly during ADR 0001 drafting;
    rejected as a parallel auth model.
  - Embedding PAM module behaviour in the daemon (e.g.
    re-implementing password hashing in Zig). The daemon is a
    PAM client; what's behind PAM is module territory.

### What this requires

  - `/etc/pam.d/system` exists. True on all stock FreeBSD installs.
  - `pam_unix.so`, `pam_nologin.so`, `pam_login_access.so` are
    present at the system library path (`/usr/lib/`). True on
    stock FreeBSD 15.
  - `_pgsd_sessiond` system user exists when the daemon runs.
    Created by stage 9 of the implementation phasing.
