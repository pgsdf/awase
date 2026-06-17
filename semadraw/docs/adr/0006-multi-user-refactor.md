# 0006 semadrawd multi-user refactor

## Status

Proposed (2026-05-10).

**Implementation status** (added 2026-05-11):

  - AD-31.1 (privilege drop): Done. Bench-verified
    2026-05-11. See `docs/sessions/2026-05-11.md`.
    Follow-up commit on the same day relaxed inputfs
    publication file permissions (group `_semadraw`, mode
    0640) via install.sh + loader.conf, because
    semadrawd's `pumpCursorPosition` lazy-opens
    `/var/run/sema/input/state` post-drop and the
    default root:wheel:0600 attributes denied access.
    This uses the operator escape hatch ADR 0013
    contemplated for exactly this case.
  - AD-31.2 (peer-uid identification): Done. Bench-verified
    2026-05-11.
  - AD-31.3 (privileged-client recognition and surface owner
    tagging): Done. Bench-verified 2026-05-11. Landed across
    three commits: part 1 (`69e8f2b`) added the
    `Surface.owner_uid` field and the `isPrivilegedUid`
    helper; part 2 (`9d1e201`) added Daemon-level
    `run_uid` and `privileged_uid` configuration (read from
    `SEMADRAW_RUN_UID` and `SEMADRAW_PRIVILEGED_UID`), the
    `canModifySurface` enforcement helper, and migrated all
    14 `isOwner` call sites; part 3 is the docs/memo close.
    `SurfaceRegistry.isOwner` was removed in part 2 because
    its per-ClientId check is no longer the permission
    concept. The privileged-uid bypass remains dormant in
    production because `SEMADRAW_PRIVILEGED_UID` is unset
    until pgsd-sessiond integrates with AD-31; the bypass
    branch is exercised only by the `isPrivilegedUid` unit
    tests in `privilege.zig`.
  - AD-31.4 (devfs rules and TCP listener tightening): Done.
    Bench-verified 2026-05-11. Landed across three commits:
    part A (`1546ec5`) added the `utf_devices=10` devfs
    ruleset and install.sh's graceful rc.conf handling;
    part B (`b3432b0`) added `peer_uid` to the
    `client_connected` / `client_disconnected` event payloads
    and `owner_uid` to `surface_created` / `surface_destroyed`;
    part C is the docs/memo close. §6 TCP listener
    tightening is in effect through AD-31.3's
    `canModifySurface` logic: TCP clients have
    `peer_uid == NOBODY_UID`, the privileged bypass refuses
    `NOBODY_UID`, and no enumeration message exists, so the
    TCP-cannot-see-other-uids posture holds without
    additional code beyond what AD-31.3 already landed.

AD-31 closes end-to-end with this commit's predecessor
sequence: all four sub-stages done, the substrate's
privilege model live on the bench, and the supporting
operator-facing infrastructure (devfs rule, event
attribution) in place.

## Context

semadrawd today runs as `root` and assumes a single-user world.
Every connecting client is treated identically; surfaces are
identified by a daemon-assigned `ClientId` (u32) but not by the
uid that owns them; the IPC socket and TCP listener accept
unauthenticated connections; the daemon retains `root` for its
entire lifetime. This was acceptable while UTF was a single-user
research substrate. It becomes incorrect once `pgsd-sessiond`
(SM-1, see `pgsd-sessiond/docs/adr/0001-design.md`) starts
authenticating multiple users and serving them through one
shared semadrawd: there is currently no way for the daemon to
tell which user owns which connection, no way to filter event
delivery by uid, and no privilege boundary between semadrawd
and the userspace it talks to.

This ADR specifies the substrate-side changes required for the
"system-wide semadrawd, per-user clients" architecture decided
in the 2026-05-10 working session
(`docs/sessions/2026-05-10.md`). The work is filed as AD-31 in
the BACKLOG under Architectural Discipline because the
capabilities (peer-uid identification, owner-tagged surfaces,
privilege drop) are general-purpose substrate facilities that
any consumer can use, not just SM-1. A different distribution
built on UTF could adopt the same multi-user semadrawd without
taking SM-1's design choices.

The ADR specifies design under fixed inputs from the SM-1
work:

  - **System-wide semadrawd, per-user clients.** One semadrawd
    process serves all logged-in users. There is no
    semadrawd-per-user model.
  - **`pgsd-sessiond` is a privileged client.** When the login
    daemon connects, it gets surfaces at the highest z-order
    range and the right to enumerate other users' surfaces.
    Ordinary user clients see only their own surfaces.
  - **Surfaces are owned by uid, not by login session.** Two
    connections from the same uid share visibility into each
    other's surfaces; connections from different uids do not.
    "Login session" as a concept is owned by `pgsd-sessiond`
    above the substrate, not by semadrawd.
  - **Privilege drop is mandatory, not optional.** The daemon
    starts as `root` only long enough to open device fds, then
    drops to a dedicated system uid before accepting any
    client connection.

The ADR does not specify capsicum sandboxing, authfs (the
network-side auth model for cross-machine UTF), fast user
switching at the substrate level, or per-uid resource
accounting. These have their own future ADRs.

## Decision

### 1. Privilege model

A new system user `_semadraw` (uid in the 100-200 range, by
FreeBSD convention for system accounts) owns the semadrawd
process for its entire steady-state runtime. The user is
created as part of the package install; its shell is
`/usr/sbin/nologin`; its home is `/nonexistent`; it is in a
single primary group `_semadraw` with no supplementary
groups.

semadrawd's main entry point runs the following sequence
before accepting any client connection:

  1. Parse arguments and load configuration.
  2. Open `/dev/draw` read-write. Retain the fd.
  3. Open the inputfs publication regions
     (`/var/run/sema/input/state`,
     `/var/run/sema/input/events`,
     `/var/run/sema/input/focus`,
     `/var/run/sema/input/smoothing`) read-only via
     `mmap(2)` and/or `open(2)` as the existing code does.
     Retain the fds and mappings.
  4. Bind the IPC listening sockets:
     - The Unix socket at the configured path (default
       `/var/run/sema/draw.sock`).
     - The TCP listener, if `--tcp PORT` was passed. See
       §6 for why the default for this changes.
  5. `setgid(<_semadraw gid>)`, `setuid(<_semadraw uid>)`.
     Both must succeed; on failure the daemon exits with a
     diagnostic and does not start.
  6. Verify the privilege drop took. Call `getuid()` and
     `geteuid()`; if either is 0, abort.
  7. Begin the accept loop.

**The retained fds outlive the privilege drop.** The kernel
permits `read(2)`, `write(2)`, `mmap(2)`-derived access, and
ioctl on file descriptors after `setuid(2)`; the access check
is at `open(2)` time. The ordering above (open-while-root,
then drop) is the standard pattern.

**No fd is closed and re-opened post-drop.** Re-opening
`/dev/draw` as `_semadraw` would require devfs rules granting
that uid access (see §3); doing so would also create an
ownership boundary that AD-31 deliberately wants on the
*client* side (clients cannot bypass semadrawd by opening
`/dev/draw` directly), not on the *daemon* side.

**The audio device is not in the retained-fd set.** The
BACKLOG entry's earlier mention of "audio device" was
incorrect: semadrawd does not open audio devices. Audio fds
are owned by semaaud, which is a peer daemon with its own
privilege model (out of scope for AD-31).

### 2. Peer-uid identification

Every accepted connection on the Unix listener has its
peer's uid established by `getpeereid(3)` immediately after
`accept(2)` returns. The `ClientSession` struct
(`semadraw/src/daemon/client_session.zig`) gains two fields:

```zig
pub const ClientSession = struct {
    id: protocol.ClientId,
    peer_uid: posix.uid_t,
    peer_gid: posix.gid_t,
    socket: socket.ClientSocket,
    // ... existing fields ...
};
```

`peer_uid` is set at `init` time and never mutates over the
session's lifetime. All subsequent operations that need to
make a uid-based decision read `session.peer_uid`.

**`getpeereid(3)` failure is a connection-level error.** If
the syscall fails, the daemon closes the socket without
sending a reply. This is the same posture as existing
connection-level errors. There is no fallback "accept
without uid" path; the daemon cannot reason about a
connection whose peer it cannot identify.

**TCP connections have no peer uid.** On the TCP listener,
`getpeereid(3)` is not applicable. TCP connections are
treated as having `peer_uid = NOBODY_UID` (a sentinel,
e.g. 65534 / `nobody`) and `peer_gid = NOBODY_GID`. They are
permitted to perform read-only operations against their own
surfaces (defined as: surfaces created on this same
connection) but cannot enumerate, target, or interact with
surfaces owned by other connections. See §6.

### 3. Privileged-client recognition

A specific uid is recognised as the login daemon and granted
elevated privileges:

  - Allowed to create surfaces in the high-z-order range
    reserved for the login UI (z >= 0x40000000, distinct
    from `Z_ORDER_CURSOR = 1000000`).
  - Allowed to enumerate surfaces owned by any uid.
  - Allowed to send synthesised input events (a future
    capability, not part of v1).

The recognition mechanism is **uid match against a
configured value**, not group membership. The configured uid
is set in semadrawd's invocation environment via the
`SEMADRAW_PRIVILEGED_UID` environment variable, read at
startup and stored in the daemon's runtime config. Default
behaviour when unset: no client is privileged; every client
is treated as ordinary. This makes the privilege grant
explicit at deployment time and reviewable per
configuration.

Why uid rather than group: a group-based check would let any
process running as a member of a privileged group act as the
login daemon. PGSD will run `pgsd-sessiond` as a dedicated
system user (`_pgsd_sessiond`) precisely so that this check
is a uid match, not a group inclusion. The login daemon's
identity is its uid.

Why an environment variable rather than a compile-time
constant: distributions other than PGSD that build on UTF
may use a different daemon name and a different uid. The
runtime configuration keeps semadrawd portable across
distributions.

### 4. Per-surface owner tagging

`Surface` (`semadraw/src/daemon/surface_registry.zig`) gains
one field:

```zig
pub const Surface = struct {
    id: protocol.SurfaceId,
    owner: protocol.ClientId,
    owner_uid: posix.uid_t,
    // ... existing fields ...
};
```

`owner_uid` is set at surface creation time from the
creating client's `peer_uid` and never mutates. When a
client disconnects, surfaces it owns are destroyed (existing
behaviour, see `disconnectClient` in `semadrawd.zig`); when
a uid's last connection drops, that uid no longer owns any
surfaces by definition.

The compositor's surface enumeration
(`SurfaceRegistry.getCompositionOrder`) does **not** filter
by uid. The composition order is global: every surface is
considered for compositing regardless of who owns it. This
is correct because the compositor is the authority on what
appears on the screen; per-uid filtering happens on
*request* paths, not on the render path.

Where uid filtering applies:

  - **Enumerate-surfaces** (a future capability for clients
    that want to know what other surfaces exist): returns
    only surfaces matching `peer_uid`, plus surfaces in the
    "public" z-order range (the cursor surface,
    notifications, etc., uid-tagged as the daemon itself).
    The privileged client (§3) sees all surfaces.
  - **Focus targeting**: keyboard input is routed to the
    focused surface; the focused surface's `owner_uid` must
    match the inputfs-published focus uid (a future
    inputfs-side change, not part of v1 AD-31). Until
    inputfs publishes per-uid focus, focus delivery is
    unchanged from current behaviour and a future ADR will
    address the uid-aware variant.
  - **Surface-modify operations** (`SET_Z_ORDER`,
    `SET_VISIBLE`, `SET_POSITION`, etc.): a client may only
    modify surfaces whose `owner_uid` matches its own
    `peer_uid`. The privileged client may modify any
    surface.

### 5. devfs rules

`/dev/draw` is the only character device in semadrawd's
ownership path. devfs rules under `/etc/devfs.rules` (a
PGSD-shipped file, conditionally loaded by rc.d) restrict
access:

```
[utf_devices=10]
add path 'draw' mode 0660 group _semadraw
```

The mode `0660` (rw-rw----) and group `_semadraw` mean:

  - The `_semadraw` user can open `/dev/draw` for reading
    and writing (this is what semadrawd does at startup as
    root, before the drop; the access works *post*-drop
    because the fd is already open, but the rule documents
    the intended permission).
  - No other user can open `/dev/draw`. **This is the
    point.** Without this rule, any user could open
    `/dev/draw` directly and bypass semadrawd as the
    gatekeeper of the framebuffer. With it, semadrawd is
    the sole userspace process that can drive the
    framebuffer, and clients must go through semadrawd's
    IPC.

The inputfs publication regions
(`/var/run/sema/input/*`) need analogous treatment, but
they are tmpfs files written by the kernel module, not
character devices, and devfs rules do not apply. inputfs
exposes them under `/var/run/sema/input/` with mode 0644
(the default tmpfs permission for kernel-written files).
For AD-31 v1, this is left unchanged: ordinary users can
read input state directly. Restricting that is the
subject of a future inputfs ADR (analogous to ADR 0013
"publication permissions" but stricter), out of scope here.

### 6. TCP listener handling

Today the TCP listener is opt-in (the `--tcp PORT` flag
must be passed; default is no listener). Once AD-31 lands
the default and posture do not change: the listener
remains opt-in, and operators who enable it do so
knowing they are accepting unauthenticated connections.

What changes is **the semantics for TCP-connected
clients**:

  - TCP clients have `peer_uid = NOBODY_UID` (see §2).
  - TCP clients cannot be privileged (§3 requires a uid
    match, and `NOBODY_UID` is not the configured
    privileged uid).
  - TCP clients can create their own surfaces; they can
    modify only those surfaces; they cannot enumerate
    other-uid surfaces.

This is a strict tightening of TCP semantics. Any
existing tooling that relies on a TCP client being able
to inspect a different uid's surfaces will break. There
is no such tooling today; the TCP path is rarely used
and was added for remote-render experiments.

The longer-term answer is **authfs** (a future ADR) which
specifies a network-side authentication model so that TCP
clients can be associated with a real uid via mutual
auth. Until authfs lands, the AD-31 posture is "TCP is
nobody, treat it accordingly."

The TCP listener is not bound until after the privilege
drop. Specifically: the listener is bound during step 4 of
the startup sequence (§1) while still root, but the
*accept* loop runs post-drop. The bind needs to happen
while root because the listener may be on a privileged
port if the operator configured one (uncommon but
possible); accepting on the bound listener is allowed
post-drop because the kernel does not require privilege
on the accept path.

### 7. rc.d integration

The s6 run script
(`/var/service/utf/semadrawd/run` in the PGSD layout) is
unchanged in shape. semadrawd starts as root (s6 starts
all services as root by default) and the privilege drop
happens inside the daemon, not in the supervisor.

Why not have s6 drop privilege via `s6-setuidgid`: the
device-fd-open step (§1, step 2-3) requires root, and
moving that into the daemon means the daemon is the only
process that knows what fds it needs. Having the
supervisor pre-drop privilege would force semadrawd to
either (a) require a fd-passing handshake from a
privileged helper, or (b) require the device files to be
accessible to `_semadraw` directly, which removes the
gatekeeper property in §5. The "daemon drops itself"
posture is the standard Unix daemon pattern and the right
shape here.

The rc.d script needs one substantive change unrelated to
privilege: it must export `SEMADRAW_PRIVILEGED_UID` (§3)
to semadrawd's environment when `pgsd-sessiond` is
deployed. The PGSD package's run-script does this; an
operator running semadrawd by hand, or a non-PGSD
distribution, omits the variable and gets the
no-privileged-client posture.

### 8. Hot reconfig and existing-connection semantics

This ADR specifies steady-state behaviour for new
connections. **Existing connections from before AD-31
landed do not exist as a real case** because AD-31 is a
breaking change to the substrate that requires recompile
and reinstall of semadrawd; there is no graceful upgrade
path that keeps in-flight clients connected across the
upgrade. Operators are expected to bounce semadrawd as
part of the AD-31 install, and clients are expected to
reconnect.

**Within an AD-31-running daemon, there is no hot
reconfig.** The privileged uid (§3) is read once at
startup. Changing it requires a daemon restart. Same for
device fds, devfs rules, and rc.d configuration.

### 9. Logging and event emission

semadrawd emits unified-schema events
(`semadraw/src/daemon/events.zig`) at structured points.
Two events gain `peer_uid` fields:

  - `client_connected` gains `peer_uid` (the uid of the
    connecting client, or the NOBODY sentinel for TCP).
  - `client_disconnected` already takes a `reason`; no
    schema change is required, but the daemon must
    record the uid in its existing client-session-cleanup
    path so that subsequent emit calls can include it.

Surface lifecycle events (`surface_created`,
`surface_destroyed`) gain `owner_uid` fields. This lets
external observers (logs, dashboards, future SM tooling)
attribute substrate activity to users without parsing
ClientId-to-uid mappings out of band.

The unified schema's existing fields (`type`, `subsystem`,
`session`, `seq`, `ts_wall_ns`, `ts_audio_samples`) are
unchanged.

## Consequences

### What this enables

  - **SM-1.9 boot integration becomes possible.**
    `pgsd-sessiond` can recognise its own privileged status,
    create login UI surfaces at the right z-order, and on
    successful auth `setuid` to the authenticated user
    before exec'ing the session leader. Without AD-31's
    peer-uid identification and privileged-client
    recognition, SM-1.9 cannot work.
  - **Multi-user PGSD becomes possible.** Two users logged
    in at the same time (via fast user switching, or two
    SSH-X-style connections in a future authfs world) get
    independent surface namespaces.
  - **Privilege boundary becomes real.** Today a bug in
    semadrawd's IPC handling is a root-level bug. Post-AD-31
    it is a `_semadraw`-level bug, which still has access
    to the framebuffer but does not have arbitrary system
    privilege.

### What this does not address

  - **inputfs-side per-uid filtering.** inputfs currently
    publishes one shared input state for the whole system.
    A future ADR (analogous to inputfs ADR 0013) needs to
    decide whether input state should be per-uid, and if
    so how that interacts with the focus model.
  - **authfs.** TCP clients are second-class citizens
    until authfs lands. This is fine for the current
    research posture but is a real limitation for any
    multi-machine UTF deployment.
  - **Capsicum sandboxing.** semadrawd as `_semadraw` is
    less privileged than as `root`, but it still has the
    framebuffer. A future ADR can specify a capsicum
    capability model that further restricts what the
    daemon can do.
  - **Resource accounting per uid.** Surface counts,
    pixel-budget enforcement, and similar limits are
    per-`ClientSession` today. A future ADR can specify
    per-uid aggregates.

### Implementation stages

The work is structured as four independently-bench-testable
sub-stages, each producing a commit:

  - **AD-31.1: privilege drop.** Add `_semadraw` user
    creation to install.sh. Implement steps 1-7 of §1 in
    semadrawd's main. No client-side semantics change yet.
    Bench-verifiable: daemon starts, drops, logs the
    transition, accepts connections normally.
  - **AD-31.2: peer-uid identification.** Add `peer_uid` /
    `peer_gid` to `ClientSession`, populate via
    `getpeereid(3)` on accept, log at connection time.
    Bench-verifiable: log shows peer_uid for each
    connection; existing functionality unchanged.
  - **AD-31.3: privileged-client recognition and
    surface owner tagging.** Add
    `SEMADRAW_PRIVILEGED_UID` env-var read, add `owner_uid`
    to Surface, populate at surface creation, enforce
    surface-modify checks. Bench-verifiable: ordinary uid
    cannot modify a different uid's surface; privileged
    uid can.
  - **AD-31.4: devfs rules and TCP listener tightening.**
    Land the devfs rule, change TCP semantics per §6, add
    the schema fields per §9. Bench-verifiable: ordinary
    user cannot open `/dev/draw`; TCP client cannot see
    other uids' surfaces.

Each sub-stage is its own commit. AD-31.1-31.3 are
substrate work that does not depend on any other
sub-stage; AD-31.4 depends on 31.1-31.3 because the
devfs rule requires the `_semadraw` user to exist (31.1)
and the TCP semantics depend on per-surface uid tagging
(31.3).

### Estimated cost

Medium-Large per the BACKLOG entry. The privilege drop is
small (~50 lines, well-tested pattern). The peer-uid
identification is small (~30 lines plus tests). The
privileged-client recognition and surface owner tagging
are medium (~200-300 lines across multiple files, plus the
test matrix). The devfs and rc.d work is small (~50 lines).
The bulk of the cost is in the testing matrix: multiple
users connecting concurrently, login-daemon-recognised-
correctly, hostile-client testing, devfs-rule-actually-
restricts-access.

Multiple sessions of work, with each sub-stage
bench-verifiable independently.

### Failure modes worth naming

**Privilege drop fails silently.** If `setuid(2)` returns
success without actually dropping (an impossible case on a
correctly-running kernel, but worth a runtime check),
semadrawd would continue as root with a false sense of
security. Step 6 of §1 (the `getuid()` / `geteuid()`
verification) catches this.

**`getpeereid(3)` returns the daemon's own uid.** On some
Unix variants `getpeereid` on a connection from the same
process returns the process's own uid. semadrawd never
connects to itself in normal operation; if it did, it
would see `peer_uid = _semadraw uid` and would not match
the privileged uid, so the daemon would treat the
connection as ordinary. This is the safe failure mode.

**Privileged uid mistakenly set to 0 or to `_semadraw`.**
If `SEMADRAW_PRIVILEGED_UID=0` is set, semadrawd would
treat root as the privileged client. If the `_semadraw`
uid is set, semadrawd would treat itself as privileged
(with the caveat above). Both are operator
misconfigurations rather than substrate bugs. The daemon
should log the resolved privileged uid at startup so that
this is visible in operational logs.

**TCP listener inadvertently exposed.** If an operator
enables `--tcp PORT` on a network-reachable interface,
the listener accepts connections from anywhere on that
network. AD-31 does not change this; the existing
caveat about TCP being unauthenticated is now stricter
("nobody-uid, severely restricted") but the listener is
still reachable. The right answer is authfs; the
interim answer is "don't enable TCP unless you mean it,
and bind to localhost if you do."

## Related work

  - **SM-1** (`pgsd-sessiond/docs/adr/0001-design.md`):
    the consumer that requires AD-31's privileged-client
    recognition.
  - **inputfs ADR 0013** (publication permissions):
    parallel pattern for restricting access to substrate
    publication regions; relevant to the "inputfs-side
    per-uid filtering" item under "What this does not
    address."
  - **BACKLOG AD-31 entry**: scope summary and stage
    breakdown.
  - **`docs/AWASE_ARCHITECTURAL_DISCIPLINE.md`**: the
    discipline grounding for why this work matters.
    semadrawd's runtime privilege is "external" in the
    sense that running as root means the daemon's bugs
    have system-wide consequences; reducing the privilege
    is part of making semadrawd's behaviour specifiable
    against UTF's commitments.

## What this ADR is not

  - It does not specify protocol message format changes.
    The IPC protocol (`shared/PROTOCOL.md`) is unchanged
    by AD-31; the new fields (`peer_uid`, `owner_uid`)
    are server-side bookkeeping, not on-the-wire fields.
  - It does not specify a uid-to-group mapping for PGSD
    distribution. PGSD's package install creates the
    `_semadraw` and `_pgsd_sessiond` users; the choice of
    specific uid numbers is a packaging concern handled
    in PGSD's install.sh, not specified here.
  - It does not specify migration of existing surface
    data. AD-31 is a clean break; existing semadrawd
    state does not survive a daemon restart (it doesn't
    today either).
  - It does not specify the inputfs-side changes to
    publish per-uid focus. That is a future inputfs ADR.
