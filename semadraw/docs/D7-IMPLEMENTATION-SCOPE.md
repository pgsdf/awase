# D-7 implementation scope: privileged set-focus message

Grounds ADR 0011 (Accepted 2026-06-08) in the current tree. D-7 is the
single semadraw substrate addition that unblocks NDE-1 Milestone 1 (focus,
raise, close; raise and close already work). This is land-known-code-in-
known-places, not research: the focus-region writer exists and is tested;
what is missing is the protocol message, the daemon handler that calls the
existing writer, the event, and the validity invariant.

## What already exists (verified in tree)

  - FocusWriter (shared/src/input.zig): setKeyboardFocus(session_id),
    setSurfaceMap, the seqlock discipline (beginUpdate/endUpdate/markValid),
    the focus region at /var/run/sema/input/focus. Tested at input.zig
    ~1947-1974. The "focus-region publication prerequisite" the backlog
    flagged is already written at the writer level.
  - The NO_FOCUS sentinel: shared/src/input.zig:967 (pub const
    NO_FOCUS: u32 = 0), already used by the writer. Reference it; do not
    introduce a literal 0 sentinel.
  - The privilege gate: privilege.isPrivilegedUid (semadraw/src/daemon/
    privilege.zig:111), used by the Daemon via isPrivileged
    (semadrawd.zig:465).
  - The pattern to mirror: handleRemoteSetZOrder (semadrawd.zig:1549) does
    exactly the surface-to-session-shaped resolution and gating D-7 needs
    (it validates payload, deserializes, checks canModifySurface, acts).
  - The constants pipeline: shared/protocol_constants.json is the single
    source of truth; shared/tools/gen_constants.py regenerates the
    generated blocks in semadraw/src/ipc/protocol.zig. The 0x0034 slot is
    RESERVED (noted in protocol.zig:67 and protocol_constants.json:240) but
    set_focus is not yet defined.
  - Two dispatch tables: handleRemoteRequest (semadrawd.zig:~1373, TCP/
    remote sessions) and the local-session switch (~1849). Both need a
    set_focus arm. inputfs already reads the focus region to route keyboard
    input, so no inputfs change is needed for the happy path.

AD-54 (protocol_constants reconciliation), the other stated D-7
prerequisite, is CLOSED. Both gates are clear; D-7 is ready.

## Increment 1: protocol constants + wire structs + ser/deser

  - Edit shared/protocol_constants.json (NOT protocol.zig directly): add
    set_focus = 0x0034 to the request range and focus_changed = 0x9003 to
    the events range. Remove the "0x0034 reserved" note since it becomes
    real.
  - Run python3 shared/tools/gen_constants.py to regenerate the generated
    blocks in protocol.zig (and any other generated targets the tool
    emits). Do not hand-edit generated blocks.
  - Add the wire structs in protocol.zig (the hand-written, non-generated
    section, alongside SetZOrderMsg): SetFocusMsg { surface_id: u32 } with
    SIZE and serialize/deserialize, mirroring SetZOrderMsg; and the
    FocusChangedEvent { surface_id: u32 } for the 0x9003 event.
  - Tests: ser/deser round-trip for both, mirroring the existing
    SetZOrderMsg tests.
  - Bench gate: zig build + the protocol unit tests green.

## Increment 2: focus-region ownership and lifecycle (largely pre-existing)

  - The backlog called this a broad prerequisite, but the FocusWriter and
    seqlock are already in shared/src/input.zig. What D-7 needs here is
    confirming semadrawd OWNS a FocusWriter instance (constructs it at
    startup, holds it on the Daemon struct) so the handler can call it.
  - Verify/establish: the Daemon holds a FocusWriter (or constructs one)
    pointed at /var/run/sema/input/focus, per INPUT_FOCUS.md and inputfs
    ADR 0003 naming semadrawd the sole writer. If semadrawd does not yet
    instantiate FocusWriter, that instantiation is this increment's work
    (small: init at daemon startup, deinit at shutdown).
  - Bench gate: semadrawd starts, the focus region is created/owned, no
    behavior change yet (no caller).

## Increment 3: the set_focus handler + privilege gate + resolution

  - Add handleSetFocus and handleRemoteSetFocus (mirror the local/remote
    split that set_z_order and set_cursor already have; see the two
    dispatch tables). Each:
      - validates payload length against SetFocusMsg.SIZE; protocol_error
        if short.
      - deserializes SetFocusMsg.
      - privilege-gates via isPrivileged(peer_uid); on failure send
        error_reply (0x80F0) and return WITHOUT changing focus (D3).
      - surface_id == 0 clears focus: setKeyboardFocus(NO_FOCUS) using the
        existing canonical constant (shared/src/input.zig:967), and reset
        the focused_surface tracking field (increment 4) to NO_FOCUS.
      - else look up the surface, resolve to owning session id (the same
        resolution handleRemoteSetZOrder uses), call
        FocusWriter.setKeyboardFocus(owning_session_id) through the
        seqlock (beginUpdate/.../endUpdate or the writer's internal
        discipline) (D2, D4), and record focused_surface = surface_id so
        the destroy/disconnect paths can enforce the D7 invariant. Unknown
        surface -> error_reply.
  - Wire both handlers into their dispatch tables (the .set_focus arms in
    handleRemoteRequest ~1373 and the local switch ~1849).
  - set_focus is fire-and-forget: no success reply (D6).
  - Bench gate: privileged client sets focus to a surface; inputfs routes
    keyboard input to that client; non-privileged set_focus refused with
    error_reply.

## Increment 4: focus_changed event + D7 validity invariant + bench

**D7 Validity Invariant (normative).** The published keyboard-focus
target MUST either be NO_FOCUS or reference a currently existing session
that owns a live surface. Focus MUST be cleared to NO_FOCUS immediately
when the focused surface is destroyed or when the owning session
disconnects. This holds always, on every path, not only on set_focus, so
any reader (inputfs, NDE components, diagnostics) can trust a published
focus refers to a live surface.

**Daemon must track the focusing surface.** The focus region stores a
SESSION identifier (setKeyboardFocus takes session_id), not a surface id.
Therefore the daemon cannot tell from the focus region alone whether a
destroyed surface was the focused one. The daemon MUST track the surface
most recently selected by set_focus (a focused_surface field on the
Daemon, NO_FOCUS/0 when cleared) so that surface-destroy and disconnect
can detect "this was the focused surface" and enforce the invariant. This
tracking is added in this increment; it is the state the three-path
enforcement reads.

**focus_changed event semantics (normative).**
  - On a focus transition A -> B: the losing client (owner of A) receives
    focus_changed with surface_id = 0; the gaining client (owner of B)
    receives focus_changed with surface_id = B.
  - On a clear (set_focus surface 0, destroy of the focused surface, or
    disconnect of the focused session): the (former) focused client
    receives focus_changed with surface_id = 0. No gaining client.
  - surface_id = 0 in focus_changed therefore uniformly means "you no
    longer hold focus," symmetric with surface 0 meaning "clear" in
    set_focus and with the NO_FOCUS sentinel (shared/src/input.zig:967,
    pub const NO_FOCUS: u32 = 0).

Implementation:
  - Emit focus_changed (0x9003) per the semantics above on every focus
    transition.
  - Enforce the D7 invariant on THREE paths, reading the focused_surface
    state:
      - the set_focus handler (increment 3),
      - the surface-destroy path (handleRemoteDestroySurface and its local
        twin): if the destroyed surface == focused_surface, clear focus to
        NO_FOCUS, reset focused_surface, emit focus_changed(0) to its
        owner,
      - the client-disconnect path: if the disconnecting session owns
        focused_surface, clear focus to NO_FOCUS, reset focused_surface,
        emit focus_changed(0) to that owner.

**Lifecycle ordering (normative, verified against the tree).** Both
disconnect paths (disconnectRemoteClient at semadrawd.zig:1750 and
disconnectClient at :2393) call surfaces.removeClientSurfaces(client_id),
which returns void and drops the surface records. The D7 invariant check
on disconnect MUST run BEFORE removeClientSurfaces, while the surfaces
still exist, so "does this client own focused_surface" can be resolved.
After removeClientSurfaces the surface is gone and the ownership lookup
would fail silently (focused_surface still set, its surface freed),
leaving a published focus that violates the invariant. The resolution
itself is cheap and depends on no torn-down state: it reads the daemon's
own focused_surface field and the surface's owner via the same lookup
canModifySurface uses (surface_registry, owner_uid). The same
before-removal ordering applies to the surface-destroy path: enforce the
invariant before the surface record is removed.
  - Full bench (the ADR 0011 acceptance bench):
      - privileged client focuses each of two surfaces owned by distinct
        clients; inputfs routes keyboard input to the focused client;
      - clearing focus (surface 0) routes to none;
      - non-privileged set_focus refused with error_reply;
      - destroying the focused surface clears focus to NO_FOCUS (D7);
      - disconnecting the focused client clears focus to NO_FOCUS (D7);
      - focus state stable and observable across every transition;
      - focus_changed carries surface_id = 0 to every losing/cleared
        client and the gained surface id to every gaining client.

## Sequencing and risk

Increments are bench-gated in order, as is the project norm. 1 and 2 are
small and carry no behavior change (constants + writer ownership). 3 is the
core (the handler). 4 adds the event and the invariant, and is where the
real correctness surface is (three-path invariant enforcement). The
session-vs-surface granularity is handled by D2's resolution and is
explicitly out-of-scope to go finer (per-surface focus within one client is
a future ADR, per ADR 0011).

## Out of scope (per ADR 0011)

  - per-surface keyboard focus within a single multi-surface client,
  - grabs (D-8) and subsurfaces (D-9),
  - any NDE-specific path: this is a general privileged-client capability
    consumed only through WM_CLIENT_CONTRACT.md; NDE does not touch
    semadraw internals.

## Verification boundary

D-7's behaviors are verified at the level where each can be tested
cleanly, which is a layered strategy rather than a single end-to-end
test:

  - Focus writer/reader contract: unit-tested in shared/src/input.zig
    (keyboard focus round-trip across distinct session ids, NO_FOCUS
    read-back, and successive writes replacing the previous value, each
    under a consistent seqlock snapshot). This is the ABI D-7 exports to
    inputfs, so it is pinned directly.
  - Privilege predicate: already unit-tested in privilege.zig
    (isPrivilegedUid cases). D-7's gate is exactly this predicate.
  - Surface ownership lookup: already unit-tested in surface_registry.zig
    (surface carries owner ClientId). This is the resolution D-7 uses.
  - Handler composition (gate + resolve + write wired together in
    semadrawd) is intentionally NOT unit-tested, because Daemon currently
    couples construction to operating-system resources (it binds a Unix
    socket and mmaps the focus region in init), so it cannot be
    instantiated in a unit test without a refactor. Adding a test-only
    constructor or dependency injection solely for D-7 would expand the
    change from "implement privileged keyboard focus" into "make the
    daemon unit-testable," which is separate engineering work. This is a
    conscious architectural decision, not an oversight.
  - End-to-end routing (inputfs delivers keyboard input to the focused
    client) is the semadrawd-to-inputfs integration contract, not D-7
    daemon logic, and belongs in the planned IPC/integration harness.

Daemon testability and a reusable IPC integration harness are tracked as
separate work so they benefit future window-management features rather
than being justified by D-7 alone.
