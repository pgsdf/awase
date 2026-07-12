# ADR 0022: Transactional surface state and commit semantics (Substrate Evolution 1)

## Status

**Accepted. Ratified 2026-07-12 (operator).**

Ratified at Revision 2. Revision 1 was the resize-only design
(`config_serial` as a synchronization primitive, plus `request_size`);
it was superseded before ratification after inspecting the commit path.
Revision 2 generalized it to the transaction model and, in review,
dropped `request_size` and deferred `setHotspot`.

Implementation is authorized. It is not yet done: this ADR is a
decision, and the bench requirements in section 10 are the condition
for calling it complete. Requirement 2 (position change during draw)
is the one that proves the model, and it fails on the tree as it stands.

**Provenance.** This ADR began as a resize design, opened from audit
finding SA-1 ("the substrate cannot express resize"). Inspecting the
commit path before proposing a protocol change showed that resize was
the symptom and not the deficiency, and the ADR was generalized. The
history is preserved deliberately: the reasoning trail matters more
than the tidiness of the result, and the lesson (the first substrate
evolution item was a missing abstraction, not a missing feature) is one
future contributors should be able to reconstruct.

This is the first **Substrate Evolution** ADR. The series records
protocol changes made because a real client demonstrated the substrate
could not express something every interactive client needs. Each entry
traces to a finding in `docs/SUBSTRATE-AUDIT.md`; this one traces to
SA-1.

## 1. Context

`semadraw-term` cannot resize. Chasing that produced a sharper
diagnosis than the one it started from.

**Surface state is applied immediately. Command streams are committed
separately. The compositor reads surface state live.**

- `SurfaceRegistry` exposes five setters (`setVisible`, `setZOrder`,
  `setPosition`, `setHotspot`, `setLogicalSize`). Each writes the
  `Surface` struct directly. There is no pending copy: the `Surface`
  has one `logical_width`, one `position_x`, one `z_order`, one
  `visible`.
- `SurfaceRegistry.commit` sets a `pending_commit` boolean and
  increments `frame_number`. It promotes nothing, because there is
  nothing staged to promote. It means "the command stream is ready",
  not "this transaction is now visible".
- The compositor reads `logical_width`, `position_x`, `visible`, and
  `z_order` from the registry at composite time
  (`compositor/compositor.zig`), not from a snapshot taken at commit.

Therefore a presented frame is rasterized against whatever surface
state the registry holds at the instant of compositing, which need not
be the state the client drew for.

**Why this has not hurt yet.** Position, z-order, and visibility do not
influence the content of a command stream. A stream drawn while the
surface was at (0,0) still rasterizes correctly if the surface has
since moved to (100,100); it simply appears elsewhere. The tear is
invisible because the content is position-independent.

**Why resize forces the issue.** Geometry is the first surface state the
content depends on. A stream drawn for an 80x24 terminal grid,
rasterized against a 100x40 surface, is wrong: not merely displaced,
but incorrect. Resize is the first consumer-visible failure mode of the
missing abstraction, which is why the reference client hit it first and
why it must not be fixed in isolation.

**What semadraw already has, which the design must exploit.**

- Content is a command stream, not a sized buffer. `AttachBufferMsg`
  carries `shm_size`, `sdcs_offset`, and `sdcs_length`, and no
  dimensions. Clients do not reallocate buffers to resize; they emit
  different commands. There is no wrong-sized-buffer failure mode, and
  therefore none of the apparatus other protocols need to prevent one.
- SDCS already encourages complete scene descriptions over imperative
  mutation. A transaction model is in the grain of the design, not
  against it.
- `commit` already exists as a per-surface event with a monotonic,
  client-visible `frame_number` (`FrameCompleteMsg`). The transaction
  boundary is already named. It simply does not yet transact anything.

## 2. The semantic question

Not "how does a client change its size", but:

  What is a frame, what state participates in it, and when does that
  state become visible?

The answer this ADR adopts:

  A frame is the pair (surface state snapshot, command stream). It is
  the atomic unit of presentation. Surface state mutations are
  proposals staged against a surface; `commit` promotes the staged
  state and the attached command stream together, as one indivisible
  transaction. The compositor presents only promoted state, and
  rasterizes a command stream only against the state promoted with it.

Resize then falls out of the model rather than being added to it.

## 3. Normative invariants

**I1. The compositor owns visible geometry.** A client does not decide
how much space it occupies. It renders against a geometry the
compositor assigned. This preserves the layering ratified for focus in
ADR 0011: the substrate enforces, policy proposes.

The distinction that keeps I1 intact under a committed-state model:

  The client does not own geometry authority. The client owns
  rendering against an assigned geometry.

The client is never saying "make me 100x40". It is saying "I have
produced a frame for the 100x40 configuration you gave me."

**I2. The client owns content.** The compositor never reinterprets,
rescales, or reflows a command stream to fit a state the client did not
draw for. SDCS is semantic, not a bitmap it may resample.

**I3. A frame is self-consistent.** A presented frame must never
correspond to one surface state while being rasterized against another.
Under this ADR this becomes structural rather than enforced: the state
and the stream are promoted by the same commit and cannot be separated.

**I4. Nothing is visible before it is committed.** A staged mutation has
no effect on presentation. This is what makes multiple mutations in one
frame atomic.

## 4. Model

Each surface holds two copies of its state:

    pending surface state
            |
            |  commit  (atomic promotion, together with the SDCS stream)
            v
    current surface state  +  committed command stream

- `set_visible`, `set_z_order`, `set_position`, and the geometry
  acknowledgment (section 5) write **pending**.
- `set_cursor` (hotspot) is deliberately NOT included. See below.
- `attach_buffer` stages the command stream.
- `commit` atomically promotes pending state to current and binds the
  attached stream to it, incrementing `frame_number`.
- The compositor reads **current** state only, and rasterizes the
  stream committed with it.

**Scope of transactional state.**

    setVisible      transactional   surface presence in composition
                                    must be atomic with its content
    setZOrder       transactional   ordering must correspond to the
                                    committed frame
    setPosition     transactional   prevents the configuration and
                                    content mismatch this ADR exists for
    setLogicalSize  transactional   geometry affects the client's
                                    rendering assumptions
    setHotspot      TBD             cursor semantics may differ from
                                    surface semantics; see below

`setHotspot` is left out on purpose. Cursor state does not
automatically inherit surface transaction semantics: the cursor is
compositor-internal, driven by the SET_CURSOR path (ADR 0005), and no
concrete atomicity requirement has appeared for it. Including it by
symmetry would be exactly the speculative reasoning the audit
discipline forbids (no primitive, and no semantics, without a concrete
client demonstrating the need). If an atomicity requirement for cursor
state appears, it gets its own decision rather than inheriting this
one.

**Cursor surfaces are not included in transactional surface state.**
(Clarification added 2026-07-12 during D-12 implementation, from the
first concrete case that tested this ADR's boundary. This is a scope
clarification, not a redesign.)

Cursor position is compositor-owned input state, not client-rendered
surface configuration. The distinction is semantic, not an exception:

- A normal surface's position and geometry are **client-visible
  configuration**. The client renders content against a
  compositor-assigned configuration, and the frame it produces must be
  paired atomically with that configuration. That pairing is what this
  ADR exists to provide.
- A cursor surface's position is **compositor-controlled pointer
  state**. The daemon moves it in response to input events. There is no
  client frame whose rendering must be atomically paired with the
  cursor's location: the sprite's content does not depend on where the
  pointer is.

Forcing cursor motion through commit would use a transaction mechanism
for a problem it was not designed for. Pointer motion is high-frequency
input state, not frame state; it would create transaction traffic per
motion event, couple cursor latency to the surface commit model, and
imply an atomicity requirement that does not exist. It would also break
the cursor pump's damage ordering, which per ADR 0005 section 4 damages
underlying surfaces for both the old and new rects *before* the cursor
moves, and depends on the move landing immediately.

**Implementation invariant.** A cursor surface may bypass transactional
position and visibility updates because it has no client rendering
contract tied to its position. The daemon's cursor path writes current
state directly; the client-facing setters stage pending state. The two
are separate code paths, not one path with a role test, so the
distinction is visible at the call site rather than hidden behind a
shared API.

This is recorded as the first concrete input defining this ADR's
boundary: "surface" turned out to be too broad a category, and the
transaction model exposed that rather than being defeated by it. Cursor
transaction semantics remain deferred to SA-2 if a future requirement
(drag-and-drop sprite atomicity is the plausible one) needs them.

Consequences that follow immediately:

- Multiple mutations in one frame are atomic. A client may move, raise,
  show, and redraw a surface in a single commit and the compositor will
  never present an intermediate combination.
- The existing invisible tears (position and z-order applied mid-stream)
  are closed as a side effect. This is not scope creep; it is the same
  defect, and fixing it for geometry alone while leaving it for position
  would be the one-off mechanism this ADR exists to avoid.
- `frame_number` becomes meaningful: it identifies a transaction, not
  merely a stream.

## 5. Geometry: configure, render, acknowledge

Geometry is the state I1 constrains, so it enters the transaction model
through a compositor-owned path rather than as a client-set field.

    compositor:  surface_configure(surface, width, height, scale, serial)
    client:      produce commands for that configuration
    client:      commit(config_serial = serial)   [with the stream]
    compositor:  promote, and present the frame under that configuration

`config_serial` (u64, per surface, monotonic) is the identity of a
compositor-provided configuration. Its role under this ADR is precise
and narrow, and differs from the earlier draft of this document:

  The serial is an acknowledgement token for compositor state identity,
  not a synchronization primitive pretending to be a transaction. The
  transaction is provided by section 4; the serial names which
  configuration the client is acknowledging, and provides no atomicity
  by itself.

That distinction is what keeps I1 intact. The transaction is

    configured state + commands

and never

    commands + client-provided geometry

**Geometry fields are deliberately NOT added to commit.** The tempting
design, `commit { width, height, commands }`, would make the client the
source of truth for its own geometry and quietly repeal I1. A client
tells the compositor which configuration it drew for; it does not tell
the compositor what size it is.

**Creation.** The geometry established at `create_surface` is serial 0.
A client that has never been configured commits serial 0, so the rule is
uniform and the first frame is not a special case.

**In-flight configures.** The compositor may configure while the client
is mid-draw. The client's commit then carries the previous serial. That
frame is promoted and presented under the configuration its serial
names, which is the last frame at the old geometry; the client
acknowledges the new configuration on a subsequent commit. The
compositor retains the previous configuration until the pending one is
acknowledged.

**Superseding.** At most one configure may be outstanding per surface.
Configuring again before acknowledgment supersedes the pending
configure (new serial, new dimensions). An acknowledgment of a
superseded serial acknowledges nothing and the compositor continues to
await the current one. This bounds retained state to two configurations
per surface and forbids unbounded queues.

**A client that never acknowledges** continues to be presented at its
current configuration, which is self-consistent and merely stale. That
is an unresponsive application, which is a policy problem, and policy
is NDE's.

## 6. Client-requested size is deliberately NOT introduced

An earlier draft of this ADR added `request_size`, an advisory
client-to-daemon request, with the compositor "provisionally" honoring
a well-formed request from a surface's owner until NDE arrived to own
such decisions.

That is rejected. The ADR's central invariant is that the compositor is
the single authority for surface configuration (I1). Introducing a
client request path *at the same time*, with a provisional
honor-the-client policy behind it, creates a second geometry authority
at precisely the moment the first one is being established. A
placeholder that contradicts the invariant it is placed beside is not a
placeholder; it is the thing the invariant forbids, deferred.

It also violates the discipline this audit adopted: no new protocol
primitive without a concrete client demonstrating the need. No client
demonstrates it. `semadraw-term` does not need to request its own size;
it needs to be *told* a size and render for it, which section 5
provides. The demonstrated need is `surface_configure`, and that is
what this ADR adds.

Until a concrete window-management client requires negotiation, the
compositor remains the sole geometry authority. When one does, the
question is reopened as its own decision, and the likely shape is a
compositor-mediated negotiation primitive rather than a client geometry
setter. That distinction is the whole point and is easier to make from
a clean starting position than from a deployed advisory path.

## 7. Protocol additions

    surface_configure   = 0x9006  // daemon to client
        surface_id:     SurfaceId
        logical_width:  f32
        logical_height: f32
        scale:          f32
        config_serial:  u64

    (commit extended)   = 0x0021
        surface_id:     SurfaceId
        flags:          u32   // existing, reserved
        config_serial:  u64   // NEW: the configuration this frame was drawn for

One event is added and one existing request grows. No new request is
added: see section 6. `0x9006` is verified free (the highest allocated
event is `session_unlocked = 0x9005`), and `0x0038` is left unallocated
rather than spent on a request this ADR declines to introduce.

`CommitMsg` is `surface_id` plus a reserved `flags: u32` (SIZE 8) and
grows to SIZE 16. The reserved `flags` word is left alone: a serial is
not a flag.

The existing state-setting messages (`set_visible`, `set_z_order`,
`set_position`, `set_cursor`) are unchanged on the wire. Their
*semantics* change: they stage rather than apply. This is a behavioral
compatibility event even though the wire format is untouched, and both
it and the `commit` wire change should ride a protocol version bump
(`docs/BACKWARD_COMPATIBILITY.md`).

## 8. What this ADR does not decide

**When to change state.** The model makes state changes coherent. What
should trigger one (a dragged border, a tiling rule, a fullscreen
toggle, an output hotplug) is window-manager policy and belongs to NDE.
Section 6 declines to introduce a client request path at all, so no
provisional policy is smuggled in with the mechanism.

**Roles.** The ratified NDE semantic design (C1) makes surface roles
protocol-visible, and geometry policy will eventually key on role. This
ADR introduces no roles and depends on none; the transaction model is
role-agnostic and remains correct when roles arrive.

**Subsurfaces.** D-9 (parent-child surfaces, atomic positioning,
clip-to-parent) is open. Atomic parent-child positioning is exactly a
transaction over two surfaces, so this ADR is a prerequisite for a
clean D-9 rather than a competitor to it. Whether a subsurface commits
with its parent, or parent and child commits are grouped, is D-9's to
decide on top of this model.

## 9. Consequences

- Three dormant capabilities become reachable and coherent:
  `Backend.resize`, `SurfaceRegistry.setLogicalSize`, and
  `semadraw-term`'s `pty.resize`. The reference client stops being
  designed around an absence.
- The pre-existing invisible tears in position, z-order, and visibility
  are closed.
- Multi-property atomic updates become expressible for the first time.
- `Surface` gains a pending copy of its mutable state; the compositor
  reads current only. This is the main implementation cost.
- `commit` changes on the wire, and the state setters change in
  meaning. A protocol version bump is required.
- D-9 (subsurfaces) gains the transaction substrate it needs.
- Cursor hotspot semantics remain an open question, deliberately not
  answered here.
- No client-side geometry authority is created. The compositor is the
  sole source of surface configuration, which is the position the ADR
  can afford to hold precisely because it adds no request path.

## 10. Bench requirements

Ratification requires, on `bare-metal-test-bench`:

1. **Geometry change during draw.** Client receives configure A, begins
   producing commands, compositor issues configure B, client commits
   frame A, then commits frame B. Frame A must be displayed under
   geometry A and frame B under geometry B. No frame is interpreted
   under the wrong geometry. This is I3 and it is the test that matters.
2. **Position change during draw.** The same pattern with `set_position`
   instead of geometry, proving the general mechanism rather than a
   resize special case: the frame is presented at the position that was
   current when it was committed, not the position at composite time.
3. **Multi-property atomicity.** One commit carrying a position change,
   a visibility change, a z-order change, and a command stream must
   appear atomically. No intermediate combination is ever presented.
4. **Supersede.** Two configures before any acknowledgment: the second
   supersedes the first, the client acknowledges only the second, and
   the surface ends at the second geometry with no intermediate
   presentation at the first.
5. **Non-acknowledgment.** A client that never acknowledges continues to
   present correctly at its current configuration indefinitely.
6. **The reference client.** `semadraw-term`, resized, reflows its grid
   and its child process observes the new `TIOCSWINSZ`: that is,
   `pty.resize` is finally called and the shell sees the new size.
7. **Authority.** The compositor is the only source of geometry. No
   client path exists by which a surface can set its own size; the only
   geometry a client may act on is one it was configured with.
