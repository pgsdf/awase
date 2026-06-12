# 0005 Runtime environment and session-leader environment variables

## Status

Proposed (2026-05-14).

## Context

ADR 0001 says the session leader is exec'd with a populated
environment that includes `PGSD_SESSION_TYPE` and an
`XDG_RUNTIME_DIR`-equivalent at `/var/run/pgsd/<uid>/` ("path
TBD"), plus "other environment variables required by the session
leader." This ADR pins down:

  - The runtime directory's exact path, ownership, mode, and
    lifecycle.
  - The full set of environment variables pgsd-sessiond sets
    on the session leader, with rationale.
  - Which environment variables from the daemon's own context
    must be filtered out (or replaced) before the leader sees them.
  - How this interacts with FreeBSD's `login.conf`-driven env
    setup and PAM's `pam_getenvlist(3)` contributions.

The audience is two-fold:

  - The pgsd-sessiond implementation, particularly the launch
    sequence (ADR 0001 Launch sequence step 4) which sets the
    environment before `exec`.
  - Application authors writing session leaders or programs
    invoked from them, who need to know which env vars are
    contracted and which are incidental.

## Decision

### Runtime directory

```
/var/run/pgsd/<uid>/
```

`<uid>` is the numeric user ID of the authenticated user, in
decimal, with no leading zeros. Example: for vic (uid 1001),
the directory is `/var/run/pgsd/1001/`.

Numeric uid (not username) matches the convention used by
`XDG_RUNTIME_DIR` on Linux systems (`/run/user/<uid>`) and
matches FreeBSD's existing per-uid runtime conventions. It is
also typo-resistant for paths constructed in code.

#### Filesystem placement

`/var/run` is a tmpfs on PGSD systems (established by `install.sh`'s
fstab handling). `/var/run/pgsd/` and all per-uid subdirectories
inherit tmpfs storage: fast writes, no disk persistence, all
state cleared at reboot.

This is the intended behaviour:

  - Sockets and lock files for the current user's session
    shouldn't survive reboot.
  - Stale state from a previous boot is never a debugging
    distraction.
  - Disk writes are not contended for transient per-session
    state.

#### Ownership and mode

  - **Owner**: the authenticated user (numeric uid matching
    the directory name).
  - **Group**: the user's primary gid from `getpwnam(3)`.
  - **Mode**: 0700.

Mode 0700 (rwx by owner only, nothing for group or other) means
the user's sessions can read and write the directory, but no
other user on the system can. This is the standard
runtime-directory permission and matches Linux's `XDG_RUNTIME_DIR`
specification.

`/var/run/pgsd/` itself (the parent) is mode 0755 root:wheel:
world-readable so `getpwuid(getuid())`-style probes work, but
writable only by root.

#### Lifecycle

  - **Created**: by pgsd-sessiond during the launch sequence,
    after `pam_open_session(3)` and before the `fork(2)` that
    drops privilege. The daemon creates the directory as root,
    `chown(2)`s it to the authenticated user, and `chmod(2)`s
    it to 0700. The child inherits these permissions.
  - **Persists**: for the lifetime of the boot, regardless of
    how many times the user logs in or out. Subsequent logins
    by the same user find the directory already present and
    use it as-is.
  - **Cleaned up**: at reboot (tmpfs is wiped). pgsd-sessiond
    does NOT delete the directory at logout. Long-running
    inter-session state (e.g. a user's notes daemon that survives
    a logout-login cycle) can rely on the directory's stable
    location within a boot.
  - **Stale state at re-login**: if a previous session crashed
    and left lockfiles or sockets in the directory, the
    re-login finds them. Cleaning up stale per-application
    state is the application's responsibility, not
    pgsd-sessiond's. (For example: semadrawd's user-side socket
    handler must `unlink(2)` its socket file before `bind(2)`,
    which it already does.)

#### Subdirectory convention

pgsd-sessiond creates only `/var/run/pgsd/<uid>/` itself. It
does not pre-create any subdirectories. Applications that need
namespaced state under the runtime dir create subdirectories on
demand using their own short names:

```
/var/run/pgsd/1001/
    semadraw/      created by user-side semadraw client lib
    notes/         created by a hypothetical notes daemon
    history/       created by semadraw-term for scrollback
```

This is convention, not enforcement. The runtime dir is the
user's; what they put in it is up to them and their
applications.

### Environment variables set on the session leader

When pgsd-sessiond exec's the session leader (per ADR 0001
Launch sequence step 5 and ADR 0004 Process semantics), the
following environment is in effect.

#### PGSD-specific

  - **`PGSD_SESSION_TYPE`**: the `<id>` of the launched
    `.session` file (e.g. `default`, `nde`, `kiosk-readonly`).
    Allows the session leader and its children to know which
    session they're under, useful for per-session config
    branches.

  - **`PGSD_RUNTIME_DIR`**: the absolute path of the per-uid
    runtime directory, `/var/run/pgsd/<uid>/`. This is the
    canonical PGSD-specific name. Applications written for
    PGSD specifically should prefer this over `XDG_RUNTIME_DIR`.

#### XDG-style (set for cross-tool compatibility)

  - **`XDG_RUNTIME_DIR`**: same value as `PGSD_RUNTIME_DIR`.
    Set so that third-party tools that key off XDG conventions
    Just Work without per-tool PGSD support.

  - **`XDG_SESSION_TYPE`**: literal string `pgsd` (not `x11`,
    not `wayland`). Tools that interrogate this to choose
    between rendering paths see PGSD and can fall back to
    framebuffer/console-style behaviour if they don't recognise
    `pgsd`.

#### Standard POSIX / FreeBSD

  - **`HOME`**: the authenticated user's `pw_dir`.
  - **`USER`**: the authenticated user's `pw_name`.
  - **`LOGNAME`**: same value as `USER`. Some tools check
    one, some the other.
  - **`SHELL`**: the authenticated user's `pw_shell`, validated
    against `/etc/shells`. If invalid, `/bin/sh`.
  - **`PATH`**: from `login.conf(5)` via `setclassenvironment(3)`
    (see the login.conf interaction subsection). If no class
    is configured, falls back to a hardcoded
    `/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin`.
  - **`TERM`**: not set by pgsd-sessiond. The session leader
    sets `TERM` for child processes that need it (e.g.
    semadraw-term sets `TERM=semadraw` or similar in its
    PTY child).

#### PAM contributions

After `pam_open_session(3)`, the daemon calls
`pam_getenvlist(3)` to retrieve any environment additions
made by PAM modules during session-open. Common contributors:

  - `pam_krb5.so`: sets `KRB5CCNAME` to the user's credential
    cache.
  - `pam_ssh.so`: sets `SSH_AUTH_SOCK` if it started an agent.
  - `pam_env.so` (if configured): sets arbitrary operator-defined
    variables from `/etc/login.conf` or `/etc/pam_env.conf`.

These are added on top of the PGSD-specific and standard
variables. PAM contributions take precedence if they overlap.

#### `login.conf` interaction

FreeBSD's `login.conf(5)` provides per-class environment
defaults (`setenv` capability) and resource limits.
pgsd-sessiond consults `login.conf` by calling
`setusercontext(3)` with the LOGIN_SETALL mask appropriate for
a graphical-login provider:

```
setusercontext(lc, pwd, pwd->pw_uid,
    LOGIN_SETPATH | LOGIN_SETENV | LOGIN_SETUMASK |
    LOGIN_SETPRIORITY | LOGIN_SETRESOURCES |
    LOGIN_SETGROUP | LOGIN_SETLOGIN);
```

The call sets resource limits (`RLIMIT_*` from the class's
`cputime`, `filesize`, etc. capabilities), the user's umask,
process priority, supplementary groups, and the `LOGIN` utmp
field. It also sets `PATH` (per LOGIN_SETPATH) and other
environment variables defined in the class (per LOGIN_SETENV).

The call must happen AFTER `setuid(2)` for some
limit-setting operations to apply correctly, per the
`setusercontext(3)` man page's documented order.

### Environment variables filtered out

pgsd-sessiond's own environment must NOT propagate to the
session leader. The daemon starts its environment from a clean
slate when constructing the leader's env:

```
1. Start with an empty env list.
2. Add the PGSD-specific variables.
3. Add the XDG-style variables.
4. Add the POSIX/FreeBSD standard variables.
5. setusercontext() applies login.conf variables and PATH.
6. Add PAM contributions from pam_getenvlist().
```

Specifically dropped (because they would leak daemon state):

  - `SUDO_*`: not applicable; pgsd-sessiond is not invoked
    via sudo, but defensive.
  - `LD_*`: dynamic-loader variables that would influence the
    leader's library search order. Stripped to prevent
    privilege-escalation-via-library-search attacks.
  - `IFS`: shell field separator. Stripped to avoid surprising
    word-splitting in the shell `-c` invocation.
  - `BASH_ENV`, `ENV`: shell startup-file overrides. Stripped
    so the user gets their own login shell behaviour, not
    inherited from the daemon.

`pgsd-sessiond` itself runs with a minimal environment (set by
its rc.d or supervision wrapper). The clean-slate construction
is defensive even given that minimal starting point.

### Worked example

For user `vic` (uid 1001, gid 1001, shell `/bin/sh`, home
`/home/vic`), logging in via the `default` session:

```
PGSD_SESSION_TYPE=default
PGSD_RUNTIME_DIR=/var/run/pgsd/1001
XDG_RUNTIME_DIR=/var/run/pgsd/1001
XDG_SESSION_TYPE=pgsd
HOME=/home/vic
USER=vic
LOGNAME=vic
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Plus anything `login.conf` adds for the user's class, plus
anything PAM's open_session populated.

## Bench testing

Stage 3 of the pgsd-sessiond implementation introduces the
privilege-drop and exec path, which is where this environment
contract is enforced. Bench tests:

```
# 1. Verify the runtime directory is created with correct
#    ownership and mode.
pgsd-sessiond --launch vic default
# (the launched session leader can inspect:)
ls -ld /var/run/pgsd/1001
# expected: drwx------ 1 vic vic ... /var/run/pgsd/1001

# 2. Verify the directory persists across logout/login.
exit                         # in the launched session leader
pgsd-sessiond --launch vic default
ls -ld /var/run/pgsd/1001    # same inode, still 0700 vic:vic

# 3. Verify the standard env vars are populated.
pgsd-sessiond --launch vic default
# inside the launched session, run:
env | grep -E '^(PGSD_|XDG_|HOME|USER|LOGNAME|SHELL|PATH)='
# expected: all the variables listed in the worked example

# 4. Verify daemon env doesn't leak.
PGSD_LEAK_TEST=visible LD_PRELOAD=/dev/null pgsd-sessiond --launch vic default
# inside the launched session:
env | grep -E '^(PGSD_LEAK_TEST|LD_PRELOAD)='
# expected: empty (both vars filtered)

# 5. Verify resource limits from login.conf apply.
# Pre-set vic's login class to have a small cputime limit:
sudo cap_mkdb /etc/login.conf
# (with appropriate edits to /etc/login.conf for class 'default')
pgsd-sessiond --launch vic default
# inside the launched session:
ulimit -t
# expected: matches the class's cputime capability

# 6. Verify reboot wipes the runtime dir.
sudo reboot
# after reboot, before any login:
ls /var/run/pgsd/
# expected: empty or directory absent (tmpfs is wiped)
```

## Consequences

### What this enables

  - Session leaders and their children have a stable, fast,
    private per-user scratch directory at a well-known path.
  - Cross-platform tools that key off `XDG_RUNTIME_DIR` work
    without PGSD-specific patches.
  - `login.conf`-based resource limits, environment, and umask
    apply to graphical sessions the same way they apply to
    `login(1)`-driven sessions; operators don't maintain a
    parallel limits policy for PGSD.
  - PAM-contributed env vars (`KRB5CCNAME`, `SSH_AUTH_SOCK`,
    operator-defined ones) propagate to session leaders, so
    Kerberos and ssh-agent integration work out of the box if
    the PAM stack is configured for them.
  - Filtered-out daemon env vars (`LD_*`, `IFS`, etc.) close
    a class of privilege-escalation vectors.

### What this forecloses

  - **Cross-boot persistence in the runtime dir.** Applications
    that need cross-boot state must use `$HOME` (which lives
    on persistent storage).
  - **A separate runtime dir per session-instance.** If a user
    has multiple concurrent sessions, they share the runtime
    dir. (v1 is one-at-a-time per ADR 0001's Out of Scope, so
    this is theoretical until fast user switching arrives.)
  - **Operator-overridable runtime dir location.** v1 hardcodes
    `/var/run/pgsd/<uid>/`. Future versions may make this a
    daemon-build-time constant or a daemon flag; v1 doesn't.

### What this requires

  - `/var/run` is a tmpfs. Already true on PGSD systems
    (`install.sh` ensures this).
  - `/var/run/pgsd/` parent directory exists with mode 0755
    root:wheel. Created by `install.sh` at install time, or
    by pgsd-sessiond at daemon start if absent.
  - `setusercontext(3)` is callable. Standard FreeBSD libc;
    no special dependency.
  - The numeric uid representation in path construction
    avoids any path-traversal class of issues. The path is
    built from `pwd->pw_uid` directly, never from
    user-supplied input.
