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

Status key: OPEN (recorded, no ADR), ADR (design in progress or
ratified), CLOSED (implemented and verified).

---

## SA-1: the substrate cannot express resize

Status: OPEN. Recorded 2026-07-12. Disposition: semadraw.

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
