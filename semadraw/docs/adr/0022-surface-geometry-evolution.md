# ADR 0022: Surface geometry evolution (Substrate Evolution 1)

## Status

Proposed 2026-07-12. Not ratified. Awaiting operator review.

This is the first **Substrate Evolution** ADR. The series records
protocol changes made because a real client demonstrated the substrate
could not express something every interactive client needs. Each entry
traces to a finding in `docs/SUBSTRATE-AUDIT.md`. This one traces to
SA-1.

The series exists because the audit will not stop at resize. Cursor
semantics, clipboard, selection, IME, drag-and-drop, and output
enumeration are all likely to surface the same way. A consistent format
for evolving the substrate makes those decisions reviewable against
each other rather than each being argued from scratch.

## 1. Context

Per SA-1, a semadraw surface cannot change size. `CreateSurfaceMsg`
fixes `logical_width`, `logical_height`, and `scale` at
`create_surface`, and no message in either direction changes them.

The capability exists at three layers and is connected at none:

- `Backend` declares `resize(ctx, width, height)` in its vtable, and
  all three backends implement it. No daemon code calls it.
- `SurfaceRegistry.setLogicalSize` mutates a surface's logical extent
  after creation. Its comment says it exists for the cursor
  sprite-replace path "and any future use case where a surface's
  logical extent changes after creation". Nothing else calls it.
- `semadraw-term` implements `pty.resize(cols, rows)` via `TIOCSWINSZ`.
  Nothing calls it. Its reconnect path recreates the surface at the
  original dimensions, commenting that a mid-session resize "would
  disturb the grid".

The missing layer is the protocol, which is the one layer that cannot
be built without deciding who proposes a size and who disposes of it.

Two properties of semadraw make this materially easier than the same
problem in a pixel-buffer system, and the design must exploit both
rather than importing a foreign solution.

**Content is a command stream, not a sized buffer.** `AttachBufferMsg`
carries `shm_size`, `sdcs_offset`, and `sdcs_length`, and no
dimensions. The client submits SDCS commands; the daemon rasterizes
them against the surface's geometry, which lives in the registry. A
client therefore does not reallocate a buffer to resize. It emits
different commands. There is no "buffer of the wrong size" failure mode
to defend against, because buffers have no size in the geometric sense.

**A monotonic frame counter already exists and is already
client-visible.** `SurfaceRegistry.commit` increments a per-surface
`frame_number` and returns it; `FrameCompleteMsg` carries it to the
client. Geometry changes can be sequenced against this existing
counter. No new synchronization primitive is required.

## 2. The semantic question

The protocol must describe a coherent state transition, not merely
transmit dimensions. The question is not "how does a client change its
size" but:

  What does it mean for a semadraw surface to change size?

The answer this ADR adopts:

  A surface's geometry is a value the compositor owns and the client
  observes. A resize is a compositor decision that becomes effective
  at a named frame boundary. The client's obligation is to emit, for
  every frame, a command stream drawn for the geometry that frame will
  be rasterized against. The compositor's obligation is to tell the
  client the geometry before it must draw for it, and never to
  rasterize a stream against a geometry other than the one the client
  drew it for.

## 3. Normative invariants

**I1. The compositor owns visible geometry.** A client does not
unilaterally set the size at which it is presented. It may *request* a
size; the compositor disposes. This preserves the layering ratified for
focus in ADR 0011: the substrate enforces, policy proposes.

**I2. The client owns content.** The compositor never reinterprets,
scales, or reflows a client's command stream to fit a geometry the
client did not draw for. It has no basis to; SDCS is semantic, not a
bitmap it may resample.

**I3. A frame is self-consistent.** A presented frame must never
correspond to one geometry while being rasterized against another.
This is the determinism requirement (NDE DESIGN.md section 5) made
concrete: a resize must not be observable mid-frame.

**I4. Geometry is versioned, not merely current.** Because I3 must hold
across an asynchronous client, a bare "the size is now X" event is
insufficient: the client's in-flight commit may already have been drawn
for the old size. Every geometry has an identity that a commit can name.

## 4. Model: proposed, configured, acknowledged

Three states per surface, all held in the registry.

- **Current geometry.** The geometry against which committed frames are
  rasterized today. Set at `create_surface`.
- **Configured geometry.** A geometry the compositor has decided on and
  announced, carrying a `config_serial` (u64, per surface, monotonic).
  It is not yet in effect.
- **Acknowledged geometry.** The configured geometry the client has
  confirmed it is now drawing for, by echoing the `config_serial` on
  its next commit.

The transition, in full:

1. Something decides a surface should be a different size. Today that
   is the compositor itself (an output change) or a client request
   (section 6); tomorrow it is a window manager dragging a border.
   Deciding *when* is not this ADR's business (see section 8).
2. The compositor sets the configured geometry, increments
   `config_serial`, and sends `surface_configure` to the client with
   the new width, height, scale, and the serial. Current geometry is
   unchanged: frames still rasterize at the old size.
3. The client redraws for the new geometry. It emits a command stream
   drawn for (width, height, scale), attaches it, and commits, echoing
   `config_serial` in the commit.
4. The compositor, on receiving a commit whose `config_serial` matches
   the configured geometry, atomically makes the configured geometry
   current and rasterizes that stream against it. The frame is
   self-consistent by construction: the stream and the geometry carry
   the same serial.
5. A commit echoing a stale serial is rasterized against the geometry
   that serial names, if it is still available, and otherwise is
   rejected. It is never rasterized against a geometry it was not drawn
   for. (See section 5.)

This satisfies I3 without a new synchronization mechanism: the serial
*is* the transaction identity, and the commit *is* the transaction
boundary. It reuses the existing commit path, which is the design
constraint we set out to respect.

## 5. In-flight commits and stale serials

The race is real: the compositor may configure while the client is
mid-draw. The client's commit then arrives carrying the previous
serial.

**Rule.** A commit carries the serial of the geometry it was drawn for.
The compositor rasterizes it against *that* geometry, not the newest
one. Since the compositor knows it has configured a newer geometry and
has not yet been acknowledged, this frame is understood to be the last
frame at the old size, and the client is expected to acknowledge the
configure on a subsequent commit.

The compositor keeps the previous geometry available until the pending
configure is acknowledged. At most one configure may be outstanding per
surface: if the compositor wishes to configure again before the client
has acknowledged, it supersedes the pending configure (new serial, new
dimensions), and the client's acknowledgment of the superseded serial
is accepted as an acknowledgment of nothing and simply awaits the newer
one. This bounds the state to two geometries per surface and forbids
unbounded queues.

A client that never acknowledges is not a correctness problem: it
continues to be presented at its current geometry, which is
self-consistent, merely stale. It is a policy problem (an unresponsive
application), and policy is NDE's, not the substrate's.

## 6. Client-requested size

A client may want to change size on its own initiative (a terminal
told to be 100x40, a viewer opening an image). Under I1 it may not
simply do so.

`request_size` (client to daemon) asks the compositor for a geometry.
The compositor may configure that geometry, configure a different one,
or ignore the request. If it configures, the client learns through the
ordinary `surface_configure` path in section 4; there is no separate
reply, and therefore no second mechanism to keep coherent. A request is
advisory input to a compositor decision, exactly as it should be under
I1.

At this stage of the substrate, with no window manager, the compositor
will honor a well-formed request from a surface's owner. That is a
*policy* the compositor implements provisionally, and it must be
replaceable without protocol change when NDE arrives to own such
decisions (section 8).

## 7. Protocol additions

Three messages. Numbers follow the existing allocation.

    surface_configure   = 0x9006  // daemon to client
        surface_id: SurfaceId
        logical_width:  f32
        logical_height: f32
        scale:          f32
        config_serial:  u64

    request_size        = 0x0038  // client to daemon (advisory)
        surface_id: SurfaceId
        logical_width:  f32
        logical_height: f32

    (commit extended)   = 0x0021
        surface_id:    SurfaceId
        flags:         u32        // existing, reserved
        config_serial: u64        // NEW: the geometry this stream was drawn for

`CommitMsg` today is `surface_id` plus a reserved `flags: u32` (SIZE 8).
It gains `config_serial: u64`, growing to SIZE 16. The reserved `flags`
word is left alone: a serial is not a flag, and spending the reserved
word on it would be a false economy that leaves no room for the flags
it was reserved for.

Numbers verified free against the current enum: the highest allocated
request is `idle_query = 0x0037` and the highest event is
`session_unlocked = 0x9005`, so `0x0038` and `0x9006` do not collide.

A client that has never received a configure sends the serial it was
given at `create_surface`, which is 0: the creation geometry is serial
0 by definition, so the rule in section 4 is uniform and there is no
special case for the first frame.

This is a wire-format change to an existing message, so it is a
compatibility event (`docs/BACKWARD_COMPATIBILITY.md`). It should ride a
protocol version bump rather than be smuggled in.

## 8. What this ADR does not decide

**When to resize.** The compositor decides *that* geometry changes and
the protocol makes it coherent. *Why* it changes (a dragged border, a
tiling rule, a fullscreen toggle, an output hotplug) is window-manager
policy and belongs to NDE. The provisional honor-the-client policy in
section 6 exists so the substrate is usable before NDE exists, and is
explicitly a placeholder, not a position.

**Roles.** The ratified NDE semantic design (C1) makes surface roles
protocol-visible. Geometry policy will eventually key on role (a panel
does not resize like a toplevel). This ADR does not introduce roles and
does not depend on them; `surface_configure` is role-agnostic and will
remain correct when roles arrive.

**Subsurfaces.** D-9 (parent-child surfaces, atomic positioning,
clip-to-parent) is open. A subsurface's geometry will be constrained by
its parent's; that constraint is D-9's to define. This ADR governs a
surface's own geometry and composes with D-9 rather than pre-empting it.

## 9. Consequences

- Three dormant capabilities become reachable and coherent:
  `Backend.resize`, `SurfaceRegistry.setLogicalSize`, and
  `semadraw-term`'s `pty.resize`. The last is the point: the reference
  client stops being designed around an absence.
- `semadraw-term` can reflow its grid, and its AD-40 reconnect path can
  drop the "no size re-query" workaround and re-query honestly.
- Every future interactive client gets resize for free.
- The compositor gains a two-geometry-per-surface state, bounded by the
  supersede rule in section 5.
- A wire-format change to `commit` requires a protocol version bump.

## 10. Bench requirements

Ratification requires, on `bare-metal-test-bench`:

1. A surface is created, configured to a new geometry, acknowledges,
   and is presented at the new size. `frame_complete` and the rendered
   output agree.
2. A configure issued while the client is mid-draw results in the
   in-flight frame being rasterized at the OLD geometry (its serial),
   and the following frame at the new one. No frame is rasterized
   against a geometry it was not drawn for. This is I3 and it is the
   test that matters.
3. Two configures issued before any acknowledgment: the second
   supersedes the first, the client acknowledges only the second, and
   the surface ends at the second geometry with no intermediate
   presentation at the first.
4. A client that never acknowledges continues to present correctly at
   its current geometry indefinitely.
5. `semadraw-term`, resized, reflows its grid and its child process
   observes the new `TIOCSWINSZ` (that is, `pty.resize` is called and
   the shell sees the new size).
6. A `request_size` from a non-owner is refused.
