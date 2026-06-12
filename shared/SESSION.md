# Session Identity

## Purpose

> **Retirement note (F.6, ADR 0029).** semaaud and semainputd are
> retired. semasound's events carry no session token (zero consumers
> existed; the `frames` audio position provides correlation, ADR
> 0027/0029); pgsd-sessiond's session machinery is unrelated.

A session token is a single `u64` value shared by the PGSDF daemons
(historically drawfs, semadraw, semaaud, semainput) during a fabric
lifetime. It allows
events emitted by different daemons to be correlated in the unified event log
and by chronofs.

## Token format

The token is a `u64` rendered as a 16-character lowercase hexadecimal string
with zero-padding:

```
deadbeefcafebabe
```

It is stored as 16 hex characters followed by a newline in a plain text file.

## Token file

**Default path**: `/var/run/sema/session`

The file contains exactly 17 bytes: 16 hex characters and a newline (`\n`).

The `/var/run/sema/` directory is created by the module if absent.

## Startup sequence

Whichever daemon starts first calls `session.readOrCreate(path)`:

1. If the file exists and contains a valid 16-character hex token, that value
   is returned. No write occurs.
2. If the file does not exist, is unreadable, or contains invalid data, a new
   token is generated using `std.crypto.random.int(u64)`, written to the file,
   and returned.

All subsequent daemons call `readOrCreate` and receive the same value.

## Lifetime

The token represents a **fabric session** — one complete run of the PGSDF
stack from first daemon start to last daemon stop.

The token changes only when:

- The token file is deleted (full fabric restart or explicit reset).
- The system reboots (since `/var/run` is typically a `tmpfs` on FreeBSD and
  does not survive reboots).

Individual daemon restarts do not change the token. A daemon that restarts
reads the existing token and continues using it.

## Usage in daemons

Each daemon should call `readOrCreate` once at startup and cache the result:

```zig
const session = @import("path/to/shared/src/session.zig");

// At startup:
const token = try session.readOrCreate(session.DEFAULT_SESSION_PATH);
var token_buf: [16]u8 = undefined;
const token_hex = session.format(token, &token_buf);

// In event emission:
// include token_hex as the "session" field in every JSON-lines event
```

## API

```zig
/// Read an existing token from `path` or generate and write a new one.
pub fn readOrCreate(path: []const u8) !u64

/// Render a token as a 16-character lowercase hex string into `buf`.
/// `buf` must be at least 16 bytes. Returns a slice into `buf`.
pub fn format(token: u64, buf: []u8) []u8

/// Default token file path.
pub const DEFAULT_SESSION_PATH = "/var/run/sema/session";
```

## Race safety

If two daemons call `readOrCreate` simultaneously on a cold start, one will
write the file and the other will read it. Because the token is written
atomically (via `createFileAbsolute` with `truncate = true` followed by a
single `writeAll`), the worst case is that both daemons generate independent
tokens and one overwrites the other. In practice this is not a problem:

- Daemons are started sequentially by a supervisor or shell script in normal
  operation.
- If a race does occur, the daemon that reads the overwritten file on its next
  `readOrCreate` call will use the winning token. Since each daemon caches the
  token at startup, a race only affects the initial value — subsequent reads
  are not made.

For strict serialization, start daemons sequentially or use a supervisor that
waits for the token file to appear before starting the next daemon.
