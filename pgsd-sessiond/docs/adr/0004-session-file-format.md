# 0004 `.session` file format and discovery

## Status

Proposed (2026-05-14).

## Context

ADR 0001 introduces `.session` files at
`/usr/local/share/pgsd/sessions/` as the mechanism by which
operators (and packages such as NDE) register session types
that pgsd-sessiond can launch. The format is described as
"FreeDesktop-like" with fields `Name`, `Exec`, and `Comment`.
This ADR specifies the format precisely, settles the questions
that "FreeDesktop-like" leaves open (section headers, locale
variants, `Exec` parsing rules, field codes), and defines the
discovery and selection semantics.

The audience is two-fold:

  - The pgsd-sessiond implementation, which enumerates and
    parses `.session` files and invokes the named session
    leaders.
  - Operators and package maintainers who write `.session`
    files. The two main groups are PGSD itself (shipping
    `default.session`) and third-party session providers like
    NDE.

The constraints inherited from ADR 0001:

  - Files live at `/usr/local/share/pgsd/sessions/`.
  - Each file is `<id>.session`.
  - Format is "FreeDesktop-like key-value."
  - v1 fields: `Name`, `Exec`, `Comment` (optional).
  - Parsing is forgiving; unknown keys ignored.
  - Session leader runs "in the user's login shell with their
    environment."
  - Per-user session files at `~/.local/share/pgsd/sessions/`
    are explicitly out of scope for v1.

## Decision

### File location

```
/usr/local/share/pgsd/sessions/
```

Each session type is a single file named `<id>.session`. The
`<id>` portion is constrained:

  - matches `[a-z][a-z0-9_-]*`
  - length 1 to 64 bytes

The constraint matches the attribute file's `default_session`
validation (ADR 0003). It also ensures `<id>` can appear safely
in URLs, environment variables, and log lines without escaping.

Examples of valid filenames:

  - `default.session`
  - `semadraw-term.session`
  - `nde.session`
  - `kiosk-readonly.session`

Files in the directory that do not match this pattern are
skipped with a warning. Subdirectories are not recursed into;
only files at the top level of `/usr/local/share/pgsd/sessions/`
are considered.

Per ADR 0001, per-user session files at `~/.local/share/pgsd/`
or similar are NOT consulted in v1. The single system directory
is authoritative.

### File grammar

The file format borrows FreeDesktop's section-and-key shape but
uses a PGSD-specific section name. The structure:

```
file        ::= section+
section     ::= header line*
header      ::= '[' section_name ']' ws* EOL
section_name::= [A-Za-z0-9 _-]+
line        ::= blank | comment | assignment
blank       ::= ws* EOL
comment     ::= ws* '#' .* EOL
assignment  ::= key ws* '=' ws* value ws* EOL
key         ::= [A-Z] [A-Za-z0-9]*
value       ::= any UTF-8 character except EOL
ws          ::= ' ' | '\t'
EOL         ::= '\n' | end of file
```

Notes on the grammar:

  - **Section names are case-sensitive.** v1 recognises one
    section: `[PGSD Session]`. Other sections in a file are
    permitted (for forward compat or for shared files that
    other tooling might inspect) but ignored.
  - **Keys are PascalCase ASCII**: first character uppercase,
    subsequent characters letters or digits. Examples: `Name`,
    `Exec`, `Comment`. This matches FreeDesktop convention
    and differs deliberately from the per-user attribute
    file's snake_case (ADR 0003); the two file types have
    different audiences and different historical conventions.
  - **Values are UTF-8** to end of line, no escaping in v1.
    Whitespace at the start of the value and at the end of
    the line is stripped.
  - **`#` starts a comment** only at the start of a line (after
    optional whitespace). A `#` inside a value is part of the
    value. This is different from the per-user attribute file
    (ADR 0003) where `#` always starts a comment; the
    difference is that session-file values are more likely to
    contain `#` legitimately (URLs, fragment identifiers, etc.).
  - **No quoting in v1.** Values that need to embed newlines
    or leading whitespace cannot do so in v1.
  - **No locale variants in v1.** FreeDesktop's `Name[de]`
    syntax for localised strings is not supported. v1 is
    English only per ADR 0001's out-of-scope list. The
    `[a-z][a-z0-9_-]*` regex on keys would reject `Name[de]`
    anyway; this is intentional.

### Section: `[PGSD Session]`

The only section v1 recognises. Files without this section are
treated as invalid and skipped with a warning.

#### `Name` (required)

  - **Type**: string.
  - **Length**: 1 to 256 bytes.
  - **Meaning**: human-readable display name shown in the
    session picker.

Example: `Name=Default UTF Session`

#### `Exec` (required)

  - **Type**: string.
  - **Length**: 1 to 4096 bytes.
  - **Meaning**: the command line to execute as the session
    leader, after privilege drop to the authenticated user.

Per ADR 0001, the command is run "in the user's login shell
with their environment." Concretely, pgsd-sessiond invokes:

```
execvp(shell, [shell, "-c", exec_value])
```

where `shell` is the authenticated user's `pw_shell` (or
`/bin/sh` if `pw_shell` is empty or not in `/etc/shells`).
The `exec_value` is the full string from the `Exec` field,
passed verbatim. Standard shell expansion, redirection,
piping, and exec are all available.

The session-leader process is the shell's child (or, if the
operator uses `exec <command>`, the shell process is replaced
in place). Either way, pgsd-sessiond's `wait(2)` sees the
session end when the top-level process group's last process
exits.

Field codes (FreeDesktop's `%U`, `%f`, `%i`, etc.) are NOT
supported in v1. Sessions are not invoked with documents or
URLs; they are top-level shells, not document handlers.

Example: `Exec=exec semadraw-term --fullscreen --scale 3`

The leading `exec` is operator-recommended (not required) so
the session leader replaces the shell process rather than
becoming its child. Reduces process count and simplifies
signal handling.

#### `Comment` (optional)

  - **Type**: string.
  - **Length**: 0 to 512 bytes.
  - **Meaning**: single-line description shown as a tooltip
    in the picker. May be empty or omitted.

Example: `Comment=Fullscreen text terminal at 3x scale, suitable for HiDPI displays`

### Discovery and selection

#### Discovery

At daemon start, and on receipt of SIGHUP, pgsd-sessiond scans
`/usr/local/share/pgsd/sessions/`:

  1. List entries.
  2. Filter to those matching `[a-z][a-z0-9_-]*\.session$`.
  3. Sort alphabetically by `<id>`.
  4. For each file, attempt to parse. On parse failure, log
     a warning and skip. Files that lack a `[PGSD Session]`
     section, lack `Name`, or lack `Exec` are skipped.
  5. Build an in-memory table of valid sessions keyed by
     `<id>`.

The daemon keeps the parsed table until the next SIGHUP. This
matches the user-enumeration cadence in ADR 0001: operator
edits to the on-disk state take effect on signal, not file
watch.

#### Selection

When a user authenticates, the session to launch is determined
in this order:

  1. The user's per-login override from the login UI's session
    picker, if they made one. Highest priority; never persisted.
  2. The user's `default_session` attribute from
    `/etc/utf/users/<username>.conf` (ADR 0003). The named
    `<id>` is looked up in the in-memory table. If found, that
    session is used. If not found (e.g. typo, package
    uninstalled), the daemon logs a warning and falls through.
  3. The built-in default session. This is a compile-time
    constant in pgsd-sessiond, set at daemon build time. v1
    ships with `DEFAULT_SESSION = "default"`. The matching
    `default.session` file is shipped by PGSD's installer and
    delegates to `semadraw-term` via `Exec`.

If none of the above resolve to a valid session in the
in-memory table, the daemon refuses the login attempt with a
visible error: "No valid session available; contact the
system administrator." This is a misconfiguration, not a
normal user-facing path.

### Process semantics

When a session is launched, after PAM `pam_open_session` and
privilege drop (ADR 0001's Launch sequence steps 1-4):

  1. The working directory is set to the user's `$HOME`. If
    `$HOME` does not exist or is not accessible (a NFS
    failure, say), it falls back to `/tmp` with a warning
    logged.
  2. The environment is the standard set established by ADR
    0001 step 4 (`PGSD_SESSION_TYPE`, the runtime-dir
    equivalent, etc.) plus the standard variables PAM has
    populated via `pam_getenvlist(3)`.
  3. The user's shell is determined from `pw_shell` (or
    `/bin/sh` if `pw_shell` is unset, empty, or not present
    in `/etc/shells`).
  4. The shell is exec'd with `["-c", exec_value]`.

The session ends when the top-level process exits. PAM
`pam_close_session` is called, the UTF surfaces are torn down
by semadrawd (ADR 0001), and the login UI is re-displayed.

If the shell itself fails to exec (the binary doesn't exist,
permission denied, etc.), pgsd-sessiond logs the failure and
returns to the login screen with a brief error message. This
should be extremely rare; `pw_shell` is validated against
`/etc/shells` at user-enumeration time (ADR 0001).

### Bundled `default.session`

PGSD ships a single `default.session` file in v1:

```
# /usr/local/share/pgsd/sessions/default.session
#
# Default PGSD session. Launches semadraw-term at fullscreen
# with HiDPI scaling. Operators may replace this file to change
# the default behaviour for users who have no default_session
# attribute set; or, more cleanly, install an alternative
# .session file and set users' default_session to that.

[PGSD Session]
Name=Default UTF Session
Exec=exec semadraw-term --fullscreen --scale 3
Comment=PGSD's default session: fullscreen terminal at 3x scale
```

The `--scale 3` value matches the bench's iMac 5K display
(3840x2160 EFI framebuffer, where 3x produces readable text).
On a 1024x768 sparrow laptop, this would be wrong; operators
on lower-resolution hardware should install an
override.session or edit the file post-install.

The choice of `--scale 3` in the shipped default is operator
policy and may be revisited. The point of this example is to
show what a working `.session` file looks like, not to commit
to 3x being right for every machine.

### Installation

`/usr/local/share/pgsd/sessions/default.session` is installed
by `install.sh` (specifically, by the pgsd-sessiond install
path, which does not exist yet). The installer:

  - Creates `/usr/local/share/pgsd/sessions/` if absent (mode
    0755, root:wheel).
  - Installs `default.session` (mode 0644, root:wheel).
  - **Does not** clobber `default.session` if it already
    exists. Operator customisations survive reinstall, same
    as ADR 0002's PAM-stack policy.

Third-party packages (NDE, future LT, custom packages) install
their own `.session` files alongside `default.session`. The
naming convention is `<package>.session`: `nde.session`,
`lt.session`, `kiosk-foo.session`. Conflicting filenames
between packages are a packaging error, the same way two
packages installing the same `/usr/local/bin/foo` would
conflict.

## Bench testing

Stage 4 of the pgsd-sessiond implementation can be tested
against this spec as follows:

```
# 1. Install the bundled default.session.
sudo mkdir -p /usr/local/share/pgsd/sessions
sudo tee /usr/local/share/pgsd/sessions/default.session <<EOF
[PGSD Session]
Name=Default UTF Session
Exec=exec semadraw-term --fullscreen --scale 3
EOF

# 2. Verify the daemon enumerates it.
pgsd-sessiond --list-sessions
# expected: includes "default" with name "Default UTF Session"

# 3. Add a second session.
sudo tee /usr/local/share/pgsd/sessions/kiosk.session <<EOF
[PGSD Session]
Name=Kiosk Mode
Exec=exec semadraw-term --fullscreen --scale 2 --no-shell
Comment=Locked-down kiosk display
EOF
pgsd-sessiond --list-sessions
# expected: includes both "default" and "kiosk"

# 4. Verify malformed files are skipped, not fatal.
sudo tee /usr/local/share/pgsd/sessions/broken.session <<EOF
[Wrong Section]
Name=Bad
EOF
sudo tee /usr/local/share/pgsd/sessions/missing-exec.session <<EOF
[PGSD Session]
Name=Missing Exec
EOF
pgsd-sessiond --list-sessions
# expected: still shows "default" and "kiosk"; stderr has two
# warnings (no [PGSD Session] section in broken.session;
# missing Exec in missing-exec.session)

# 5. Verify launch path.
pgsd-sessiond --launch vic default
# expected: PAM auth prompt, then semadraw-term launched as vic

# 6. Verify default fallback.
sudo rm /etc/utf/users/vic.conf  # clear default_session
pgsd-sessiond --launch vic
# expected: uses the built-in default (which is "default" in v1),
# launches semadraw-term

# 7. Verify SIGHUP refresh.
sudo tee /usr/local/share/pgsd/sessions/new-session.session <<EOF
[PGSD Session]
Name=Newly Added
Exec=exec semadraw-term
EOF
# (in another shell)
sudo kill -HUP $(pgrep -f pgsd-sessiond)
pgsd-sessiond --list-sessions
# expected: includes "new-session" without restart
```

## Consequences

### What this enables

  - Operators can register new session types by dropping a
    `.session` file in `/usr/local/share/pgsd/sessions/`,
    no code changes.
  - Per-user default session preferences via ADR 0003's
    `default_session` attribute integrate cleanly: the
    attribute names a `<id>` and the in-memory session table
    resolves it.
  - Per-login override at the login UI is straightforward:
    the session picker presents `name` values from the table,
    selection by `<id>`.
  - Third-party session providers (NDE, LT, custom kiosks)
    can install their session files via standard
    packaging without coordinating with pgsd-sessiond.
  - Forward-compatible parsing: future v2 fields can be added
    without breaking v1.

### What this forecloses

  - **Per-user session files in v1.** No `~/.local/share/pgsd/`
    directory consulted. Adding this would let users define
    their own session types, which is plausible v2 work, but
    in v1 the session-type catalogue is operator-managed.
  - **Localised display names in v1.** FreeDesktop's
    `Name[de]=...` syntax is rejected by the key regex.
    English only.
  - **Field codes in `Exec`.** No `%U`, `%f`, `%i`, etc.
    Sessions are top-level shells, not document handlers.
  - **Sessions that don't go through the user's shell.** v1
    always invokes the shell with `-c`. Sessions that need
    a different launch model (direct exec, su-like, etc.)
    can be approximated with shell `exec` but not bypassed.
  - **Sessions launched without going through PAM
    `pam_open_session`**. The full lifecycle from ADR 0001 is
    mandatory.

### What this requires

  - `/usr/local/share/pgsd/sessions/` directory exists. Created
    by `install.sh` at installation time.
  - At least one valid `.session` file in the directory at
    daemon start (typically the bundled `default.session`).
    Without one, the daemon will refuse all logins with the
    "No valid session available" error.
  - UTF-8-safe string handling in the daemon's parser and
    log paths.
