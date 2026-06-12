# 0006 semadrawd protocol for pgsd-sessiond

## Status

Proposed (2026-05-14).

## Context

ADR 0001 specifies that pgsd-sessiond connects to semadrawd as a
UTF client, but with three distinguishing properties: privileged
connection identity, a separate surface namespace, and input-routing
control via hide-self / show-self requests. ADR 0001's description
is a sketch, not a wire-format specification. This ADR pins down
the protocol.

The substrate side has already moved forward materially.
**AD-31** (semadrawd multi-user refactor, semadraw's own
ADR 0006) landed across four sub-stages between 2026-05-10 and
2026-05-11 and is complete:

  - **AD-31.1**: privilege drop in semadrawd.
  - **AD-31.2**: peer-uid identification via `getpeereid(3)`.
  - **AD-31.3**: privileged-client recognition (configured by
    `SEMADRAW_PRIVILEGED_UID`), surface owner tagging, and the
    `canModifySurface` enforcement helper.
  - **AD-31.4**: devfs rules and TCP listener tightening.

The privileged-uid bypass is dormant in production today because
`SEMADRAW_PRIVILEGED_UID` is unset; the code path is exercised
only by `isPrivilegedUid` unit tests. When pgsd-sessiond ships
and its rc.d sets `SEMADRAW_PRIVILEGED_UID` to the
`_pgsd_sessiond` uid, the bypass activates.

What AD-31 did NOT add, and what this ADR specifies:

  - The pgsd-sessiond-side connection handshake. AD-31 added
    server-side recognition; pgsd-sessiond needs to know what to
    do on its end.
  - The hide-self / show-self requests. These are new
    protocol surface that did not exist before pgsd-sessiond.
  - The z-order discipline that places pgsd-sessiond's surfaces
    above all user clients but below the daemon-owned cursor.
  - The input-routing semantics that gate user-session input
    on whether pgsd-sessiond is showing or hidden.

Stage 5 of the pgsd-sessiond implementation (login UI inside an
existing UTF session) can be prototyped without any of this new
protocol surface, because at stage 5 the daemon runs as the
authenticated user inside an already-active session. Stage 9
(boot integration) requires every piece specified here.

The audience for this ADR is:

  - The pgsd-sessiond implementation, which originates the
    requests.
  - The semadrawd implementation, which receives them and acts.
  - Future contributors who need to understand why
    pgsd-sessiond's surfaces don't behave like other clients'.

## Decision

### Connection identity

pgsd-sessiond connects to semadrawd over the standard local
Unix-domain socket at `/var/run/semadraw.sock` (per
`protocol.zig`'s `DEFAULT_SOCKET_PATH`). It does NOT use the
TCP listener.

At `accept(2)` time, semadrawd already calls `getpeereid(3)`
on the new fd and records the peer's uid in the connection's
`peer_uid` field (AD-31.2). When `SEMADRAW_PRIVILEGED_UID` is
set and matches the connection's `peer_uid`, semadrawd marks
the connection privileged via the existing `isPrivilegedUid`
helper (AD-31.3). pgsd-sessiond runs as `_pgsd_sessiond` (a
dedicated system uid, not root, not `_semadraw`), and the
operator-facing configuration sets:

```
SEMADRAW_PRIVILEGED_UID=<numeric uid of _pgsd_sessiond>
```

in semadrawd's environment, via its rc.d script.

pgsd-sessiond does NOT send a special hello message. The
standard `HelloMsg` (per `protocol.zig`) is used. The privileged
status is determined entirely by `getpeereid` + the configured
uid; no client-side declaration is needed and none is trusted.
This matches the principle that authentication is always
server-side enforced.

### Surface namespace

Per AD-31.3, every surface in semadrawd's registry has an
`owner_uid` field, set at surface creation to the connection's
`peer_uid`. The existing `canModifySurface` helper enforces:

  - Surfaces are modifiable only by their owner uid, OR
  - The connection is privileged (matches
    `SEMADRAW_PRIVILEGED_UID`).

For pgsd-sessiond, both clauses produce the same effect: its
surfaces are owned by `_pgsd_sessiond`, and any operation it
performs is by the owner. The privileged-uid bypass is mostly
relevant for future work where pgsd-sessiond might need to
inspect or modify surfaces owned by other uids (it does not
in v1).

User clients running as the logged-in user CANNOT enumerate,
inspect, or modify pgsd-sessiond's surfaces. AD-31.4 already
ensures there is no enumeration message at all in the
protocol, so this property holds automatically: clients only
know about surfaces they themselves created or were sent
events about, and pgsd-sessiond's surface IDs are never sent
to user clients.

### Z-order discipline

The existing constants in `protocol.zig`:

```zig
pub const Z_ORDER_MIN: i32 = -1_000_000;
pub const Z_ORDER_CLIENT_MAX: i32 = 999_999;
pub const Z_ORDER_CURSOR: i32 = 1_000_000;
```

establish three bands: client surfaces (clamped to
[-1_000_000, 999_999]), the daemon-owned cursor (1_000_000),
and nothing in between. pgsd-sessiond needs to draw above all
user clients but below the cursor.

This ADR introduces a new band:

```zig
pub const Z_ORDER_PRIVILEGED_BASE: i32 = 800_000;
pub const Z_ORDER_PRIVILEGED_MAX: i32 = 999_998;
```

with `Z_ORDER_CLIENT_MAX` reduced to `799_999`. The new layout:

```
-1_000_000 .. 799_999   ordinary client surfaces
  800_000 .. 999_998   privileged-client surfaces (pgsd-sessiond)
  999_999              reserved (unallocated, defensive gap)
1_000_000              cursor (daemon-owned)
```

semadrawd's set_z_order handler clamps non-privileged clients
to `[Z_ORDER_MIN, Z_ORDER_CLIENT_MAX]` (unchanged behaviour).
Privileged clients are clamped to
`[Z_ORDER_PRIVILEGED_BASE, Z_ORDER_PRIVILEGED_MAX]`. Both
clamps reject attempts to reach the cursor's z-order.

The reduction of `Z_ORDER_CLIENT_MAX` from 999_999 to 799_999
is technically a protocol change. The risk is low because
production clients today use values well below 1000 (single
or double digit z-orders are typical); no known client uses
z-orders above 800_000. A defensive compatibility check
during rollout: log a warning when the daemon clamps a
non-privileged client's z-order request that was previously
accepted.

### Hide-self and show-self requests

Two new message types, added to the `MsgType` enum:

```
PGSD_HIDE_SELF
PGSD_SHOW_SELF
```

Both are sent only by privileged clients. Non-privileged
clients sending either request receive an error reply and the
request is dropped without effect. This is enforced server-side
by the same `canModifySurface`-style check applied to the
client's connection, not to a specific surface.

Each message has no payload beyond the standard `MsgHeader`.
The semantics:

#### `PGSD_HIDE_SELF`

  - **Effect**: semadrawd flags all surfaces owned by the
    sending client as not-composited. The compositor's
    `needsComposite` and frame paths skip these surfaces
    until the matching `PGSD_SHOW_SELF` is received.
  - **Input routing**: input events (mouse, keyboard, focus)
    bypass the privileged client's surfaces and route to the
    topmost ordinary client surface that would accept them.
  - **State**: persistent within the connection. If
    pgsd-sessiond crashes (connection closes), the flag is
    cleared along with the surfaces themselves; on reconnect,
    the daemon defaults to show-self (its surfaces are
    composited and receive input).
  - **Reply**: a success acknowledgement message with the
    standard reply header.
  - **Idempotent**: a second `PGSD_HIDE_SELF` while already
    hidden is a no-op success.

#### `PGSD_SHOW_SELF`

  - **Effect**: clears the not-composited flag. Surfaces are
    composited again on the next frame.
  - **Input routing**: events route to pgsd-sessiond's
    surfaces as the highest-z-order recipient (per the
    privileged-client z-order band).
  - **Reply**: success acknowledgement.
  - **Idempotent**: a second `PGSD_SHOW_SELF` while already
    shown is a no-op success.

The two requests are the entire surface API additions for
pgsd-sessiond. No "fade in," no "animate," no "lock screen
overlay" subtypes; those can be added later as needed.

### Launch-sequence integration

The protocol interacts with the ADR 0001 Launch sequence as
follows:

  1. User selects themselves and authenticates at the login UI.
  2. pgsd-sessiond calls `pam_authenticate` + `pam_acct_mgmt`.
  3. **pgsd-sessiond sends `PGSD_HIDE_SELF` to semadrawd**.
     The login UI surfaces stop compositing and stop receiving
     input. The framebuffer continues to show the last frame
     (no flicker; semadrawd does not clear hidden surfaces'
     pixels). User-clicks-go-nowhere is brief because the
     fork-and-exec follows immediately.
  4. pgsd-sessiond calls `pam_open_session`.
  5. pgsd-sessiond `fork(2)`s. Child performs the launch
     sequence's privilege-drop and env-setup steps, then
     execs the session leader.
  6. Parent waits for the child via `wait(2)`.
  7. When the child exits:
     - Parent calls `pam_close_session`.
     - semadrawd has already torn down the user's surfaces
       (it observed the user's client connection closing).
     - **Parent sends `PGSD_SHOW_SELF` to semadrawd**. Login
       UI surfaces resume compositing and receiving input.
     - Parent re-renders the login UI's current state (which
       may have changed if `--list-users` results differ).

`PGSD_HIDE_SELF` is sent BEFORE `pam_open_session` rather
than after, so the user's session doesn't briefly see
pgsd-sessiond's surfaces in the moment between session-open
and shell exec. The cost is that if `pam_open_session` fails
after `PGSD_HIDE_SELF`, the daemon must `PGSD_SHOW_SELF`
again before reporting the error in the login UI. The error
handling is straightforward and `pam_open_session` failures
are rare.

### Failure modes

#### pgsd-sessiond crashes mid-session

The supervisor (s6 or rc.d) restarts pgsd-sessiond. The new
process's connection is fresh; it defaults to show-self. If
the user's session is still alive (their session leader is
still running), the new pgsd-sessiond should NOT show its
login UI: it would overlay the user's session.

Resolution: pgsd-sessiond at startup queries semadrawd for
"is any non-privileged client currently connected with active
surfaces?" If yes, it stays hidden (immediate `PGSD_HIDE_SELF`
after `HelloMsg`); if no, it shows the login UI.

This requires one new server-side query, `PGSD_QUERY_USER_ACTIVE`,
which returns a single bool. Like the hide/show requests, it
is privileged-only. Its addition is part of this ADR's
protocol surface.

#### semadrawd crashes

The supervisor restarts semadrawd. pgsd-sessiond's connection
breaks; pgsd-sessiond is responsible for reconnecting. Once
reconnected, the same startup query as above tells it what to
display. User sessions whose clients lost their connections
are dead and pgsd-sessiond shows the login UI.

#### Network split or partial failure

Not applicable: the connection is a local Unix socket. Either
both processes can talk or one of them is dead.

### Protocol version

The new constants (`Z_ORDER_PRIVILEGED_BASE`, etc.) and the
new messages (`PGSD_HIDE_SELF`, `PGSD_SHOW_SELF`,
`PGSD_QUERY_USER_ACTIVE`) bump `PROTOCOL_VERSION_MINOR`. The
major version stays at 0 until the protocol is broadly
considered stable (a v1.0 commitment is out of scope for this
ADR). Clients built against an earlier minor version still
work because the changes are purely additive.

The narrowing of `Z_ORDER_CLIENT_MAX` from 999_999 to 799_999
is the only non-additive change. It's a behaviour change for
clients that explicitly set z-order above 799_999. Given the
audit suggests no such clients exist, and the daemon logs a
warning rather than silently rejecting, this is acceptable
under a minor-version bump.

## Bench testing

Stage 5 of the pgsd-sessiond implementation runs against this
protocol surface without involving stage 9's full boot
integration:

```
# Pre-requisite: semadrawd configured with SEMADRAW_PRIVILEGED_UID.
sudo sysrc 'semadrawd_env=SEMADRAW_PRIVILEGED_UID=<_pgsd_sessiond uid>'
sudo service semadrawd restart

# Run pgsd-sessiond as _pgsd_sessiond.
sudo -u _pgsd_sessiond pgsd-sessiond --ui-only

# Verify the login UI is visible: it should appear at z-order
# 800_000 or above, overlaying any ordinary user clients (e.g.
# a running semadraw-term).

# Exercise hide-self / show-self.
# (manual via the UI: select a user, log in, observe semadraw-term
# becomes input-active; logout, observe login UI input-active.)
```

Stage 9 bench tests will exercise the failure modes:

```
# 1. Simulate pgsd-sessiond crash after login.
sudo -u vic semadraw-term --fullscreen &
sudo kill -9 $(pgrep -f pgsd-sessiond)
# Supervisor restarts pgsd-sessiond. Verify it does NOT show
# the login UI on top of vic's session.

sudo kill -TERM $(pgrep -f semadraw-term)
# vic's session ends. Verify pgsd-sessiond's login UI appears.

# 2. Simulate semadrawd crash.
sudo kill -9 $(pgrep -x semadrawd)
# Supervisor restarts semadrawd. Verify pgsd-sessiond reconnects
# and shows the login UI (no user clients survive across the
# restart).

# 3. Verify privileged-client check.
# Try sending PGSD_HIDE_SELF from a non-privileged process:
# the daemon must reject.
sudo -u vic pgsd-sessiond-protocol-test --send-hide-self
# expected: error reply, no effect on surfaces
```

## Consequences

### What this enables

  - pgsd-sessiond stages 5-8 can be prototyped against the
    current semadrawd (without the new protocol messages),
    because at those stages it runs inside an existing user
    session.
  - Stage 9 (boot integration) has a well-defined protocol
    surface to implement against, with clear failure-mode
    handling.
  - The privileged-uid mechanism that AD-31 added becomes
    operationally active for the first time. The
    `isPrivilegedUid` code path moves from
    dormant-but-tested to load-bearing in production.
  - Future privileged services (a hypothetical screen-locker,
    a hypothetical notification overlay) can use the same
    z-order band and the same hide-self / show-self mechanism.
    pgsd-sessiond is not the only conceivable privileged
    client; the design accommodates that without requiring
    new mechanism.

### What this forecloses

  - **Privileged clients fighting for input.** Only one
    connection is recognised as `SEMADRAW_PRIVILEGED_UID`
    at a time. If two privileged-uid clients connect, they
    share the band but interleave input routing
    unpredictably. v1 has only pgsd-sessiond; if a second
    privileged service appears, the design will need a
    refinement.
  - **Fade or animation between hide / show.** Effect is
    abrupt. Smooth transitions are a future-rendering
    concern.
  - **Privileged clients drawing under user surfaces.**
    The z-order band is fixed above user clients. A
    privileged service that wants to draw a wallpaper under
    everything would need a different mechanism (probably
    a `Z_ORDER_PRIVILEGED_LOW_BASE` band added below
    `Z_ORDER_MIN`); not in v1.

### What this requires

  - **AD-31 complete**: done as of 2026-05-11.
  - **AD-10 not strictly required for this ADR**: AD-10 (drawfs
    takes the framebuffer at boot) is required for stage 9's
    boot timing, but the protocol surface itself does not
    depend on it.
  - **Three new server-side handlers** in semadrawd: hide-self,
    show-self, query-user-active. These are the substrate
    changes pgsd-sessiond depends on for stage 9; they should
    land in a separate semadraw commit referenced from
    pgsd-sessiond's stage-9 commit.
  - **Updated `protocol.zig` constants**: the new
    `Z_ORDER_PRIVILEGED_*` constants and the narrower
    `Z_ORDER_CLIENT_MAX`. Also part of the substrate-side
    work; rolls in with the new handlers.
