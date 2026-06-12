# 0003 Per-user attribute file format

## Status

Proposed (2026-05-14).

## Context

ADR 0001 introduces a per-user attribute file at
`/etc/utf/users/<username>.conf` and gives an example, but does
not nail down a parseable grammar. This ADR specifies the format
precisely enough that a parser can be written without ambiguity,
and clarifies the semantics that ADR 0001 leaves at the
"described but not fully nailed down" level.

The audience is the pgsd-sessiond implementation (which reads the
file) and the operator (who edits it).

The constraints inherited from ADR 0001:

  - Plain text, one field per line, format `key = value`.
  - Comments introduced with `#` extend to end of line.
  - Whitespace around the `=` is permitted.
  - Unknown keys are warned-and-skipped, not errors.
  - Absence of the file is not an error; defaults apply.
  - v1 fields: `display_name`, `default_session`, `avatar_path`,
    `age_bracket`, `capabilities`.
  - Read on each login attempt; not file-watched.

This ADR fills in the rest.

## Decision

### Grammar

A per-user attribute file is a sequence of lines, each line one
of:

  - **Blank line**: zero or more whitespace characters, then end
    of line. Ignored.
  - **Comment line**: optional leading whitespace, then `#`, then
    any characters to end of line. Ignored.
  - **Assignment line**: a key, optional whitespace, `=`, optional
    whitespace, then a value, then end of line. The value may
    contain an inline comment (anything from the first `#` to
    end of line is treated as a comment).

Formally, in extended BNF:

```
file        ::= line*
line        ::= blank | comment | assignment | invalid

blank       ::= ws* EOL
comment     ::= ws* '#' .* EOL
assignment  ::= ws* key ws* '=' ws* value ws* (comment)? EOL
invalid     ::= any other line

key         ::= [a-z] [a-z0-9_]*
value       ::= value_char*
value_char  ::= any UTF-8 character except '#' and EOL
ws          ::= ' ' | '\t'
EOL         ::= '\n' | end of file
```

Notes:

  - Keys are case-sensitive ASCII; `display_name` and `Display_Name`
    are different keys. v1 recognises only the lowercase form.
  - Values are UTF-8. The parser must reject invalid UTF-8
    sequences as if the line were invalid (see invalid handling
    below).
  - Whitespace at the start of a key, around the `=`, and at the
    end of a value (before any comment) is permitted and
    stripped. Whitespace inside a value is preserved literally.
  - `#` always starts a comment. v1 has no quoting mechanism;
    operators who need `#` in a value must wait for v2. This is
    a known limitation, accepted because no v1 field is expected
    to contain `#`.

### Field reference

Each field's syntax constraint is layered on top of the generic
value grammar above. A field-specific syntax error (e.g. an
unknown `age_bracket` value) is treated as a warning, not a hard
parse failure: the field reverts to its default and parsing
continues.

#### `display_name` (string, optional)

  - **Syntax**: any non-empty UTF-8 string after grammar
    processing.
  - **Length**: maximum 256 bytes after UTF-8 encoding.
  - **Default**: the fallback chain from ADR 0001 (first
    comma-field of `pw_gecos`, then username).
  - **Empty value** (`display_name =`): treated as if the line
    were absent; default applies.

Example: `display_name = Renée Müller`

#### `default_session` (string, optional)

  - **Syntax**: a `.session` file name without the extension.
    Must match `[a-z][a-z0-9_-]*$`.
  - **Length**: maximum 64 bytes.
  - **Default**: the daemon's built-in default session (commonly
    `default` or `semadraw-term`; finalised at daemon build
    time).
  - **Resolution**: pgsd-sessiond looks for
    `/usr/local/share/pgsd/sessions/<value>.session`. If that
    file does not exist at login time, the daemon falls back to
    the built-in default and logs a warning. The attribute file
    is not re-parsed to "correct" the bad reference; that's the
    operator's responsibility.

Example: `default_session = semadraw-term`

#### `avatar_path` (string, optional, **reserved**)

  - **Syntax**: an absolute filesystem path.
  - **Length**: maximum PATH_MAX (1024 on FreeBSD).
  - **Behaviour in v1**: parsed and stored but not rendered. The
    field is reserved so the format is stable across the v1-to-v2
    transition.

Example: `avatar_path = /usr/local/share/pgsd/avatars/csmith.png`

#### `age_bracket` (enum, optional)

  - **Syntax**: exactly one of: `under-13`, `13-15`, `16-17`,
    `adult`, `unspecified`. Case-sensitive.
  - **Default**: `unspecified`.
  - **Unknown value**: warned-and-skipped; field reverts to
    default.
  - **Reminder from ADR 0001**: operator-set, not user-set; not
    exposed to applications via any system API; PGSDF makes no
    compliance claims.

Example: `age_bracket = adult`

#### `capabilities` (list, optional)

  - **Syntax**: zero or more capability strings separated by
    commas. Each string matches `[a-z][a-z0-9-]*$`. Whitespace
    around commas is permitted and stripped. Empty entries
    (resulting from `,,` or trailing/leading commas) are skipped
    silently.
  - **Length**: maximum 1024 bytes total.
  - **Default**: empty list.
  - **Recognised capabilities in v1**: `can-shutdown`,
    `can-add-users` (reserved for future).
  - **Unknown capability strings**: warned-and-skipped; the
    known capabilities in the same line are still applied.

Example: `capabilities = can-shutdown, can-add-users`

### Duplicate keys

If the same key appears more than once in the file, the **last
occurrence wins** and a warning is logged for each prior
occurrence. Last-wins matches common shell convention and is
predictable. Files that accumulate duplicates over time (because
an operator appended rather than edited) still produce a
deterministic result.

### Invalid lines

A line that is neither blank, comment, nor a valid assignment is
treated as invalid. Invalid lines are:

  - Logged at warning level with the file path and line number.
  - Skipped (parsing continues to the next line).
  - **Not** sufficient to reject the whole file or fail the
    user's login.

This matches ADR 0001's "warned-and-skipped, not errors" stance
and is appropriate for a file format intended to be operator-edited
where minor typos shouldn't lock anyone out.

### Username validation

The lookup path is constructed as:

```
/etc/utf/users/<username>.conf
```

Before opening the file, the daemon validates `<username>`
against the same regex FreeBSD's `pw(8)` uses:

```
[a-z_][a-z0-9_-]*
```

with a length limit of 32 bytes (FreeBSD's `MAXLOGNAME` minus
the trailing null). Names that fail validation are treated as
"no attribute file present" and the daemon logs a warning. This
defends against path-traversal attempts even though usernames
come from `getpwent(3)` (where the kernel-validated source should
already be safe).

### File permissions and ownership

The file is **owned by root, group wheel, mode 0644**. The
permissions are operator-policy:

  - **Read by anyone**: the file contains operator-managed
    metadata, no secrets. Display names and age brackets are
    not confidential. (Operators who disagree may use 0640 with
    the daemon's `_pgsd_sessiond` user in the group; this is
    site policy, not pgsd-sessiond requirement.)
  - **Written only by root**: editing the file is a privileged
    operation, the same as editing `/etc/master.passwd`.

The daemon does not write to the file in v1. The future
`pgsd-useradd` wrapper will write it, with appropriate atomic
rename semantics borrowed from `vipw(8)`.

### Read strategy

Per ADR 0001, the file is read on each login attempt. Concretely:

  - When the daemon needs a user's attributes (during user
    enumeration for the login UI, or during the auth-and-launch
    sequence after a user is selected), it opens
    `/etc/utf/users/<username>.conf`, reads it into memory,
    parses it, applies it, and closes the file.
  - The file is not memory-mapped, not cached across login
    attempts, not file-watched.
  - File-not-found is silently treated as "no attributes set;
    use defaults." This is the common case and should not log.
  - Other I/O errors (permission denied, I/O error from the
    underlying filesystem) are logged at warning level and
    treated as "no attributes set; use defaults."

The read cost is one open / read / close per login. The files
are small (typically under 1 KiB). This is cheap and the
no-cache rule keeps the daemon's behaviour predictable across
operator edits.

### Parser semantics summary

To make implementation unambiguous:

  1. Read the file into memory. Reject if larger than 64 KiB
     (no reasonable use case exceeds this; the limit prevents
     accidental DOS via a runaway file).
  2. Split into lines on `\n`. CRLF line endings are tolerated;
     the trailing `\r` is stripped.
  3. For each line:
     - If empty or whitespace-only, skip.
     - If first non-whitespace character is `#`, skip.
     - Otherwise, attempt to parse as `key = value`. If parsing
       fails, log warning and skip.
     - If key is recognised, apply field-specific syntax. If
       field-specific syntax fails, log warning and skip.
     - If key is not recognised, log warning and skip.
  4. After processing all lines, return the populated attribute
     struct (with defaults filled in for unset fields).

### Example file

```
# /etc/utf/users/csmith.conf
#
# Catherine Smith, primary workstation user.
# Operator: vic, 2026-05-14.

display_name = Catherine Smith
default_session = nde
age_bracket = adult
capabilities = can-shutdown
```

## Bench testing

Stage 2 of the pgsd-sessiond implementation can be tested
against this spec as follows:

```
# 1. Create a valid attribute file.
sudo mkdir -p /etc/utf/users
sudo tee /etc/utf/users/vic.conf <<EOF
display_name = Vic Thacker
default_session = semadraw-term
capabilities = can-shutdown
EOF
sudo chown root:wheel /etc/utf/users/vic.conf
sudo chmod 0644 /etc/utf/users/vic.conf

# 2. Verify the daemon's CLI list reflects it.
pgsd-sessiond --list-users
# expected: includes "vic" with display name "Vic Thacker"

# 3. Introduce errors and verify warn-and-skip behaviour.
sudo tee /etc/utf/users/vic.conf <<EOF
display_name = Vic Thacker
unknown_key = whatever
age_bracket = wizard
malformed line with no equals
EOF
pgsd-sessiond --list-users
# expected: includes "vic" with display name "Vic Thacker",
# age_bracket falls back to unspecified, stderr has three
# warning lines (unknown_key, invalid age_bracket value,
# malformed line at line 3).

# 4. Verify file-not-found is silent.
sudo rm /etc/utf/users/vic.conf
pgsd-sessiond --list-users
# expected: includes "vic" with display name from GECOS or
# username, no warnings.

# 5. Verify path-traversal defence.
sudo tee /etc/utf/users/../passwd.conf <<EOF
display_name = malicious
EOF
# The file exists at /etc/utf/passwd.conf but the daemon's
# lookup for username "passwd" (which doesn't pass enumeration
# anyway) and for "../passwd" (which fails username validation)
# both refuse to open it.
```

## Consequences

### What this enables

  - Operators can supply per-user display names that include
    non-ASCII characters (Latin-1, CJK, Cyrillic, etc.) without
    encoding tricks.
  - Per-user default sessions let operators provision users with
    different "primary apps" (NDE, semadraw-term, custom kiosk
    binaries) without code changes.
  - Capability flags provide the building block for a v2 UI that
    surfaces shutdown / user management based on whether the
    operator granted the corresponding capability.
  - The age_bracket field exists for operators who deploy in
    contexts with age-related policy needs; PGSDF makes no
    compliance claims.
  - Forward-compatible parsing means future v2 fields can be
    added without breaking v1 deployments. A v2 daemon reading
    v1 files works; a v1 daemon reading v2 files works (unknown
    keys warn-and-skip).

### What this forecloses

  - **In-band quoting in v1.** Values containing `#` are not
    supported. v2 may add quoting; v1 callers must avoid `#` in
    values.
  - **Per-user attribute files in non-standard locations.** v1
    reads only `/etc/utf/users/`. Per-user files under
    `~/.config/pgsd/user.conf` are not v1. The reason is that
    attributes are operator-set, not user-set, and a
    user-writable location would invite confusion about who
    controls what.
  - **Binary attribute fields.** Avatars referenced by path,
    not inlined. Inline base64 would bloat the format and
    encourage huge files.

### What this requires

  - `/etc/utf/users/` directory exists. Created by `install.sh`
    (or its successor) at installation time, with mode 0755
    root:wheel.
  - The daemon implements UTF-8 validation for value strings.
    This is standard library territory in modern Zig.
  - The daemon implements a path-traversal-resistant filename
    lookup. This is the username regex check above.
