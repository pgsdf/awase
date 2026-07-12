# Substrate audit

Purpose. This is the running record of substrate deficiencies found by
exercising semadraw with a real application. It is the justification
trail for protocol evolution: every Substrate Evolution ADR should be
traceable to an entry here, and every entry should be traceable to
evidence in the tree rather than to a design opinion.

Method. `semadraw-term` is the reference client (BACKLOG current
theme, 2026-07-12). Its purpose is not to be a good terminal; it is to
exercise the substrate hard enough to reveal missing primitives and
awkward APIs. When it needs something, the first question is whether
the substrate should provide it generally.

Disposition heuristic, applied to every finding:

1. Is this terminal-specific? Then it belongs in `semadraw-term`.
2. Would any interactive client need it? Then it probably belongs in
   `semadraw`.
3. Is it desktop policy, shell behavior, or window-management policy?
   Then it is deferred to NDE.

A finding belongs in the substrate when (2) is yes and (3) is no.

The characteristic signature of a substrate deficiency is not a
missing feature in the client. It is a client that has *evolved around*
an absence: dead code, a comment explaining why something is not done,
a workaround that looks like a design choice. Those are the entries
worth recording.

**A second signature, and a stronger one: capabilities that evolved
independently above and below the protocol.** When a layer that can act
unilaterally has built something (the backend can resize; the registry
can resize; the client can resize its pty), and the protocol between
them cannot express it, that is strong evidence the protocol is the
missing abstraction. Layers that can proceed alone do; the layer that
requires a design decision about who proposes and who disposes stalls.
Hunt for this pattern deliberately: it is a much stronger signal than
"an application wants X", because it says the need was felt
independently at more than one layer and the only thing that blocked it
was the absence of an agreement between them.

A corollary discipline, adopted 2026-07-12: **no new semadraw protocol
primitive is introduced without a concrete client that demonstrates the
need.** Not every client request becomes protocol (the heuristic above
sorts those), but every protocol addition must be grounded in
demonstrated usage. This keeps the substrate from accumulating
speculative abstractions while ensuring each addition has a proven
purpose.

Status key: OPEN (recorded, no ADR), ADR (design in progress or
ratified), CLOSED (implemented and verified).

---

## SA-1: surface state mutation has no protocol transaction semantics

Status: ADR. Recorded 2026-07-12, reclassified the same day.
Disposition: semadraw.
Design: ADR 0022 (Transactional surface state and commit semantics,
Substrate Evolution 1), **Accepted, ratified 2026-07-12**.
Implementation authorized and open; SA-1 closes when the ADR 0022
bench requirements pass.

**Reclassification note.** This finding was opened as "the substrate
cannot express resize". Studying the commit path showed that resize is
a symptom, not the deficiency. Surface state mutations
(`set_position`, `set_z_order`, `set_visible`, and the dormant
`setLogicalSize`) are applied to the registry immediately, while the
command stream is committed separately, and the compositor reads
surface state live at composite time. There is no pending/current
split and no snapshot. So a frame is already, today, rasterized against
whatever state the registry happens to hold at composite time, not the
state the client drew for.

Position and z-order tear invisibly: a stream drawn for one position
still renders correctly, merely somewhere else, because the content
does not depend on position. Geometry is the first surface state the
content *does* depend on, so resize is the first case where the
missing abstraction becomes visible. Adding a resize-specific
mechanism would have bolted a transactional guarantee onto one field
and left the model unfixed, which is a mechanism future features would
have to work around.

The terminal found resize. The audit found transactions.

### Protocol evidence

A surface's geometry is fixed for its lifetime. `CreateSurfaceMsg`
(`semadraw/src/ipc/protocol.zig`) carries `logical_width`,
`logical_height`, and `scale`, set once at `create_surface` (0x0010).

There is no message, in either direction, that changes them. The
`MsgType` enum has `set_visible` (0x0030), `set_z_order` (0x0031),
`set_position` (0x0032), `set_cursor` (0x0033), `set_focus` (0x0034),
`session_lock` (0x0035), `session_unlock` (0x0036), and `idle_query`
(0x0037): a surface can be shown, stacked, moved, focused, and locked,
but not resized. A search of the protocol for `resize`, `configure`,
`set_size`, or `size_changed` returns nothing (zero matches). There is
no client-to-daemon request to change size and no daemon-to-client
event announcing one.

The sharper form of this finding: **the capability exists at both ends
and is connected at neither.**

- Below, the rendering backends can resize. `Backend` (
  `semadraw/src/backend/backend.zig`) declares
  `resize: *const fn (ctx, width, height) anyerror!void` in its vtable
  with a `self.vtable.resize(...)` dispatcher, and all three backends
  implement it (`software.zig`, `vulkan.zig`, `vulkan_console.zig`;
  the Vulkan ones log that it is partial or fixed, but the seam is
  there). **No daemon code calls it.** The capability is unreachable.
- Above, the reference client can resize. `semadraw-term`'s
  `pty.zig` implements `resize(cols, rows)` via `TIOCSWINSZ`. **No
  code calls it.** It is dead.
- Between them, where the protocol would carry the geometry change,
  there is nothing.

So the missing piece is precisely and only the protocol. This is not a
feature that nobody has built; it is a feature that has been built at
the layers that can build it unilaterally, and stalled at the layer
that requires a design decision. That is the substrate's job.

Consequence: no semadraw application can change size after creation.
Not on its own initiative, and not at the request of any future window
manager. `set_position` can move a surface; nothing can resize it.

### Client evidence

`semadraw-term` has evolved around the absence, which is the signature
we are looking for.

- `semadraw/src/apps/term/pty.zig` implements `resize(cols, rows)`,
  which sets the pty window size via `TIOCSWINSZ`. It is correct and
  it is dead code: there are no call sites anywhere in the tree. The
  terminal can resize its pty and never does, because nothing can ever
  tell it that its surface changed size.
- `semadraw/src/apps/term/main.zig`, in the AD-40 reconnect path,
  recreates the surface at the original dimensions and says why:
  "surface create at the ORIGINAL dimensions (no size re-query: a
  mid-session resize would disturb the grid)". The client is
  deliberately not re-querying its own size, because the substrate
  offers no coherent way for the size to change underneath it.

This is a client compensating for a substrate limitation, which the
architectural principle adopted 2026-07-12 forbids: "avoid
compensating for substrate limitations in NDE" applies equally to
semadraw-term, and more sharply, because semadraw-term is the
instrument we are using to measure the substrate.

### Disposition

semadraw. Every interactive client needs to change size: a terminal
reflows its grid, an editor rewraps, a viewer rescales. This is not
terminal behavior. It is also not desktop policy: a window manager
would *use* resize (drag a border, tile a window, respond to an output
change), but the primitive must exist before any policy can invoke it.
Deciding *when* to resize is NDE's business; being *able* to is
semadraw's.

### What the design must answer

The interesting part is not the message. It is that semadraw already
has transactional guarantees (`attach_buffer`, `commit`,
`buffer_released`, `frame_complete`, `sync`) and a determinism
requirement (NDE DESIGN.md section 5: no implicit timing dependencies,
rendering replayable from SDCS), and geometry has to evolve without
breaking them. The semantic question comes first:

  What does it mean for a semadraw surface to change size?

The protocol must describe a coherent state transition, not merely
transmit dimensions. Principles to design against:

- The compositor owns the visible geometry. Clients do not
  unilaterally decide how much space they occupy.
- Clients own their content. They decide how to redraw for a given
  geometry.
- A frame is self-consistent. A presented frame must never correspond
  to one size while being interpreted as another.

The resize, the buffer contents, and the presentation must form one
coherent transaction from the user's point of view. That points toward
a negotiated model, but the model should be derived from semadraw's
existing commit semantics rather than borrowed from another system's
protocol.

Next step: study `attach_buffer` and `commit` in detail, then a
Substrate Evolution ADR.

### Classification

    Consumers affected:
        All interactive clients

    Layer:
        Protocol

    Root cause:
        Missing abstraction, not a missing feature: surface state
        mutations are immediate while command streams are committed
        separately, so no frame is a coherent transaction over
        (surface state, commands)

    Affected state:
        geometry, position, z-order, visibility, and any future
        surface state

    Implementation status:
        Backend:  present  (Backend.resize, all three backends)
        Registry: present  (SurfaceRegistry.setLogicalSize)
        Client:   present  (semadraw-term pty.resize)
        Protocol: absent

    Disposition:
        Substrate Evolution ADR 0022 (Accepted 2026-07-12)

    Not in scope of the fix:
        setHotspot (cursor semantics; see SA-2)
        request_size (declined: would create a second geometry
        authority; see ADR 0022 section 6)

### Study of the commit path (2026-07-12)

Reading `attach_buffer` and `commit` before designing changes the
problem substantially, and in semadraw's favor.

**semadraw is a command-stream substrate, not a pixel-buffer one.**
`AttachBufferMsg` carries `surface_id`, `shm_size`, `sdcs_offset`, and
`sdcs_length`. It carries **no width and no height**. The client is not
handing over a sized pixel buffer; it is handing over a range of shared
memory containing an SDCS command stream (`docs/SDCS.md`: STROKE_RECT,
FILL_PATH, SET_BLEND, and so on), which the daemon interprets and
rasterizes. Geometry lives in the *surface*, in the registry, not in
the buffer.

This is why resize here is not the problem it is elsewhere. In a
pixel-buffer system the client must reallocate a buffer whose
dimensions the compositor must agree with, and the whole configure/ack
apparatus of other protocols exists to stop a frame being presented at
the wrong size. In semadraw the client does not reallocate anything on
resize: it emits *different commands* for the new geometry. The
coherence requirement is therefore narrower and cleaner:

  A frame is self-consistent if the command stream committed for that
  frame is rasterized against the same geometry the client emitted it
  for.

**The sequencing primitive already exists.** `SurfaceRegistry.commit`
increments a per-surface `frame_number` and returns it, and
`FrameCompleteMsg` carries `frame_number` back to the client. There is
already a monotonic, client-visible frame counter to which a geometry
change can be bound. Resize does not need a new synchronization
mechanism invented for it; it needs to be expressed in terms of the
one that is already there.

**A third unreachable capability.** `SurfaceRegistry.setLogicalSize`
exists and mutates `logical_width`/`logical_height` after creation. Its
own comment anticipates this work: it says dimensions are "normally set
at createSurface time and not changed", that the API exists for the
cursor sprite-replace path "and any future use case where a surface's
logical extent changes after creation". It is called by nothing today
outside that cursor path.

So the count is three: the backend can resize, the registry can resize,
and the reference client can resize its pty. Each was built by a layer
that could build it alone. The protocol, the one layer that requires a
design decision about who proposes and who disposes, is the only thing
missing, and it is the only thing that can make the other three
coherent.

Design proceeded to ADR 0022, which was generalized from resize to the
transaction model after this study. The resize-only draft is not
retained: its `config_serial` was compensating for missing transactions
rather than identifying a configuration, which is the distinction ADR
0022 section 5 now makes explicit.

---

## SA-2: cursor hotspot semantics under a transaction model

Status: OPEN. Recorded 2026-07-12. Disposition: undecided.

### Classification

    Consumers affected:
        Unknown. No client has demonstrated a need.

    Layer:
        Protocol / compositor boundary

    Root cause:
        Not established. This is an open question, not a diagnosed
        deficiency.

    Disposition:
        Deliberately deferred. Not part of ADR 0022.

### The question

ADR 0022 makes surface state transactional: `setVisible`, `setZOrder`,
`setPosition`, and `setLogicalSize` stage against a pending copy and
are promoted atomically by `commit`. `setHotspot` is the fifth setter
and is deliberately excluded.

Should cursor configuration participate in surface transactions, or is
cursor state compositor-internal enough that immediate updates are
preferable?

Arguments have not been gathered because no requirement has appeared.
What is known: the cursor is driven by the SET_CURSOR path (ADR 0005);
its hotspot is used by the compositor to place the sprite at
(pointer - hotspot); and the hotspot fields live on every `Surface`
rather than only the cursor, with a comment anticipating a future
hotspot-using feature such as drag-and-drop visual offsets.

### Surface-user audit by role (2026-07-12, before D-12 implementation)

Every `Surface` creator was audited to establish which surfaces the
ADR 0022 transaction model applies to. There are exactly two
categories, and the discriminator already exists in the tree.

    Client content surfaces
        Created by handleCreateSurface / handleRemoteCreateSurface
        (semadrawd.zig:1641, 2468) with the client's session id and
        peer_uid. These carry client-rendered content whose frame must
        be paired atomically with its configuration.
        TRANSACTIONAL (ADR 0022).

    The cursor surface
        Created by the daemon (semadrawd.zig:598) with
        owner = CLIENT_ID_DAEMON and owner_uid = the daemon run_uid,
        and tracked as Daemon.cursor_surface_id. Exactly one exists.
        Its position is compositor-owned pointer state, moved by the
        cursor pump on every pointer motion (semadrawd.zig:1016).
        NOT TRANSACTIONAL.

No third category exists today. The lock surface (ADR 0012) is a
client surface adopted into a compositor mode, not a daemon-created
one, so it is a client content surface and is transactional.

Two findings from the audit shaped the implementation:

- The cursor pump uses TWO of the four transactional setters:
  `setVisible` (semadrawd.zig:1008) and `setPosition` (1016), not
  position alone. Any cursor carve-out has to cover both.
- The cursor pump depends on the writes landing immediately. Per ADR
  0005 section 4 it damages underlying surfaces for both the old and
  new displayed rects *before* moving or hiding the cursor. Staging
  those writes would break that ordering, not merely delay the cursor.

The cursor and client paths are already separate call sites; they
merely share a setter. Splitting the setter is therefore a small,
honest change rather than a special case bolted into shared logic.

### Why it is recorded rather than decided

Including `setHotspot` in the transaction set by symmetry would be
speculative: it would extend a mechanism to a case that has not
demonstrated it needs it, which is precisely what the audit discipline
forbids. Cursor state does not automatically inherit surface
transaction semantics.

If a concrete atomicity requirement appears (most plausibly from
drag-and-drop, where a sprite and its hotspot may need to change
together with other surface state), this finding is where it lands, and
it gets its own decision rather than inheriting ADR 0022's.
