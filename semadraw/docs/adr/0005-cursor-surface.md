# 0005 Cursor surface

# 0005 Cursor surface

Status: **Implemented and verified (2026-05-07).** AD-21 closed
in BACKLOG.md with all 11 sub-items done; bare-metal
verification on pgsd-bare-metal-test-machine passed Phases 0-5
plus Phase 8 (added 2026-05-07 to cover the cursor-during-idle
case sub-item 10 fixed). Implementation lives in
`semadraw/src/daemon/semadrawd.zig` (cursor pump,
visibility/hide-when-outside, surface init), the SET_CURSOR
handler in the IPC dispatch path, and the supporting damage-
model work in `semadraw/src/compositor/compositor.zig`
(region damage in sub-item 9, upper-z propagation in sub-item
10). Verification runbook at `semadraw/docs/AD21_VERIFICATION.md`.

The verification criteria in the Verification section below
were exercised as follows:
  - Criteria 1, 2, 3: passed via runbook Phases 1, 2, 3.
  - Criterion 7 (the AD-1 D.3 edge-clamp follow-up): passed
    via runbook Phase 5.
  - Criteria 4, 5, 6 (test-client SET_CURSOR exercise): not
    exercised on the bench. No test client was built; the
    SET_CURSOR validation logic was covered by code review.
    Tracked as runbook Phase 7 (optional, skipped); not
    gating.

The "reset cursor to default on focus loss" behaviour
referenced in the second sentence of criterion 4 is split
out as **AD-24** (open, Small) and tracked separately. AD-21's
closure does not include it.

Status: Proposed (initial 2026-05-06). Amended 2026-05-06 after
discovering during sub-item 3 design work that the drawfs and
software rendering backends do not currently honour the
`request.offset_x`/`offset_y` field passed by the compositor
(only Vulkan, X11, and vulkan_console backends apply it). New
section 3a captures this prerequisite and the resulting
ordering of sub-items in the AD-21 implementation plan.

Amended again 2026-05-06 in section 5: the proposed SET_CURSOR
opcode `0x0030` collided with the existing `set_visible` request
(established before this ADR was drafted). Reassigned to `0x0033`
inside the surface-state cluster (set_visible/set_z_order/
set_position/set_cursor at 0x0030/0x0031/0x0032/0x0033). The
reply is correspondingly `0x8033`. No semantic change to the
request payload or daemon-side behaviour.

Amended 2026-05-07 with the implementation-and-verification
status block above. The "reset cursor to default on focus
loss" item is tracked as AD-24 in BACKLOG.md.

## Context

UTF currently has no visible cursor sprite anywhere. The kernel
input substrate publishes the pointer position to the inputfs
state region (`pointer_x`, `pointer_y`); the compositor routes
pointer events to the focused surface; clients receive the
events and respond. But no pixel on the screen indicates where
the pointer is. This is invisible to operators trying to verify
input, and unworkable as a basis for any user-facing system.

The lack of a cursor was tolerable through Stage D and into
AD-2a Phase 1 because the verification work was happening at
the level of "events flow correctly" rather than "users can
operate the system." It became a hard blocker on AD-2a Phase 2.5
when the next verification step required pushing the cursor
against screen edges to test the D.3 coordinate-clamp behaviour.
There is no way to drive the cursor against an edge deliberately
when the cursor is invisible.

This ADR defines the cursor architecture as a permanent piece of
UTF rather than an operator utility, so that everything that
gets built on top of it (themed cursors, drag-and-drop visuals,
focus-following cursor changes, hide-on-type) inherits a sound
substrate.

## Decision

**The cursor is a compositor-managed surface.** semadrawd owns a
single cursor surface created at daemon startup, draws a default
arrow sprite into it once, and updates the surface's position
every composition cycle from the inputfs pointer position.
Clients with pointer focus may issue a `SET_CURSOR` request to
replace the sprite for the duration of their focus.

This matches the model used by every serious display server
(Wayland's `wl_pointer.set_cursor`, X11's cursor extension).
The cursor is just another surface in the existing surface
registry; it gets compositor-side z-order, damage tracking,
and per-frame composition for free. No new compositing code
path is introduced; the cursor plugs into the existing one.

The structural pieces:

### 1. Cursor surface ownership

semadrawd creates the cursor surface during its `init()` step,
before the first composite. The owner is a synthetic client ID
reserved for the daemon itself (`CLIENT_ID_DAEMON = 0xFFFFFFFF`,
distinct from the existing `0` "unconnected" value, the local
client range starting at 1, and the remote client range starting
at `0x80000000`). This keeps the surface in the existing surface
registry without special-casing the registry to handle daemon-
owned surfaces.

The surface is `visible: true` by default. It hides
(`visible: false`) when the pointer position is outside the
drawable area `[0, geom_width-1] x [0, geom_height-1]`, which
can only happen when geometry is unknown (no clamp active). Per
ADR 0012, when geometry is known the position is always clamped
inside the area, so the cursor is always visible.

The surface is destroyed during `deinit()` like any other.

### 2. Z-order reservation

A reserved high z-order value `Z_ORDER_CURSOR = 1000000`
(one million) places the cursor surface above all client surfaces.
Client `setZOrder()` requests are clamped to `[Z_ORDER_MIN,
Z_ORDER_CLIENT_MAX = Z_ORDER_CURSOR - 1]` server-side; clients
cannot reach or exceed the cursor's z-band even by accident or
malice.

This uses the existing `z_order: i32` field on `Surface` (in
`surface_registry.zig`). No new flag, no new code path through
the compositor's z-sort. The cursor naturally composites last,
on top of everything.

### 3. Sprite buffer and SDCS encoding

The cursor sprite is held in a normal attached buffer on the
cursor surface, encoded in SDCS. The default sprite is a
24×24 white-and-black arrow built into semadrawd as an embedded
SDCS byte array. The hotspot is at pixel (0, 0) — the top-left,
which is the arrow tip.

A future SET_CURSOR request replaces the buffer. The protocol
field for the hotspot (`hotspot_x`, `hotspot_y` as i32) sits on
the cursor surface struct beside the existing geometry fields,
not in the buffer itself, because the hotspot is per-attachment
metadata that consumers need without parsing SDCS.

Sprite size constraints: the buffer's encoded surface dimensions
must be ≤ 256×256. Larger requests are rejected at SET_CURSOR
time. This limit is generous (a typical cursor is 24×24 to
48×48) and prevents a malicious client from making the cursor
fill the screen.

### 3a. Backend contract: surface position via `request.offset_x/y`

The compositor's existing API surface delivers a surface's
screen position to the rendering backend through the
`request.offset_x` and `request.offset_y` fields of
`backend.RenderRequest`. Backends are expected to apply this
offset when executing the surface's SDCS commands so that a
FILL_RECT(x=10, y=20, ...) inside a surface positioned at
(800, 400) writes pixels at framebuffer coordinates
(810, 420), not (10, 20).

**Discovered prerequisite** (2026-05-06): the drawfs backend
and the software backend currently *ignore* `request.offset_x`
and `request.offset_y`. SDCS commands inside their
`executeSdcs` paths write pixels at the SDCS-supplied
coordinates directly into the full-screen framebuffer with no
offset applied. The Vulkan, X11, and vulkan_console backends
do apply the offset.

This was a latent issue before AD-21 because the existing
client (semadraw-term) occupies the full screen as a single
surface at position (0, 0); the bug had no visible effect.
The cursor surface is the first surface that genuinely needs
to render at a non-origin position while another surface
occupies origin. Without the offset fix, the cursor sprite's
SDCS coordinates would have to bake the screen position into
each FILL_RECT — a per-frame SDCS regeneration scheme that
defeats the purpose of having the position as metadata.

**Resolution**: AD-21 implementation plan adds a new sub-item
**1.5** (drawfs and software backend offset support), inserted
between sub-items 1 (this ADR) and 2 (z-order constants).
Sub-items 2 and 6 can run in any order relative to 1.5 since
they don't depend on rendering. Sub-items 3 (cursor surface
init) and onward depend on 1.5 for visible output.

The fix shape: thread `offset_x`/`offset_y` through
`renderImpl` → `executeSdcs` → `executeChunkCommands` →
each opcode handler (FILL_RECT, STROKE_LINE, etc.); add the
offsets to the x/y arguments at each `fillRect`/`strokeLine`
call site. ~50-100 lines per backend. The fix benefits any
future overlay surface (notification toasts, drag previews,
non-fullscreen windows), not just the cursor.

### 4. Position update path

Each composition cycle, semadrawd:

  1. Reads `pointer_x`, `pointer_y` from the inputfs state region.
  2. Computes the cursor surface's new top-left position as
     `(pointer_x - hotspot_x, pointer_y - hotspot_y)`.
  3. If the new position differs from the current cursor
     surface position, marks damage:
       - On the cursor surface itself, full surface damage
         (`markSurfaceFullDamage(cursor_surface_id)`).
       - On every visible surface with `z_order <
         Z_ORDER_CURSOR` whose bounds intersect either the old
         or new cursor rectangle, partial damage on the
         intersected region (`addSurfaceDamage(other_id, rect)`).
     This propagation lives in semadrawd, not in the damage
     tracker, because it requires walking the surface registry
     in z-order. The damage tracker's existing per-surface API
     is sufficient.
  4. Updates the cursor surface position via the existing
     `setPosition()` API.
  5. Toggles `visible` based on whether the pointer is inside
     the drawable area (only relevant when geometry is unknown).

Damage is propagated *before* the position update so the old
position's underlying surfaces re-render with the cursor gone
from there.

The position pump runs once per composition cycle, regardless
of whether the pointer moved between cycles. If the pointer
didn't move, step 3 finds no difference, no damage is marked,
no rerender happens — the cycle's `composite()` does no work,
which is the existing behaviour.

### 5. SET_CURSOR IPC

A new request type:

```
REQ_SET_CURSOR  = 0x0033   // amended 2026-05-06; see note below
RPL_SET_CURSOR  = 0x8033
```

**Opcode amendment 2026-05-06**: the original ADR proposed
`0x0030 / 0x8030` for SET_CURSOR. Implementation surfaced that
`0x0030` is already in use by the existing `set_visible` request
(see `semadraw/src/ipc/protocol.zig` MsgType enum, predating
this ADR). Moved to `0x0033 / 0x8033` to remain inside the
0x0030 surface-state cluster — `set_visible = 0x0030`,
`set_z_order = 0x0031`, `set_position = 0x0032`,
`set_cursor = 0x0033` is the natural slot. No semantic change.

Payload (REQ):

```
client_id      u32   // requester's client id (validated)
hotspot_x      i32   // hotspot offset in sprite pixels
hotspot_y      i32   // hotspot offset in sprite pixels
sprite_width   u32   // ≤ 256
sprite_height  u32   // ≤ 256
sprite_format  u32   // SDCS = 1; future formats reserved
sprite_length  u32   // bytes of sprite data
sprite_data    bytes // sprite_length bytes
```

Reply (RPL):

```
status         i32   // 0 = success; nonzero = error code
```

Daemon-side handler:

  1. Validates that the requester owns a surface with current
     pointer focus. If not, returns `ENOENT`. (Pointer focus
     is the surface under the cursor at the time of the
     request, per the existing focus model.) Clients without
     pointer focus cannot change the cursor.
  2. Validates `sprite_width` and `sprite_height` ≤ 256.
     Rejects with `EINVAL` otherwise.
  3. Validates `sprite_length` matches the declared format.
     For SDCS, rejects malformed buffers with `EINVAL`.
  4. Allocates a new buffer for the cursor surface, copies
     the sprite into it, attaches it to the cursor surface.
  5. Updates `hotspot_x`, `hotspot_y` on the cursor surface.
  6. Marks full damage on the cursor surface so the new
     sprite gets composited next cycle.
  7. Returns success.

The previous sprite buffer is released. There is no per-client
cursor state on the daemon side beyond "the focused client's
cursor is the current cursor." When focus changes, the daemon
does NOT automatically restore the previous owner's cursor —
the new focused client must SET_CURSOR if it wants something
non-default. If no new focus, the daemon resets the cursor
surface to the default sprite.

Future ergonomic refinement: caching per-client cursor sprites
so focus changes restore the prior owner's cursor without an
IPC round-trip. Out of scope for the first implementation.

### 6. Default sprite

The default cursor is an SDCS encoding of a 24×24 left-pointing
arrow:

  - White interior, black 1px outline.
  - Hotspot at (0, 0) — the arrow tip is the top-left corner.
  - Encoded as a small set of FILL_RECT and STROKE_LINE commands.

Embedded as a `const u8` byte array in semadrawd, generated by a
small build-time helper (`sdcs_make_glyph` already exists in the
tree as a similar utility). The helper output is checked in;
the build step is documentation, not a build dependency.

### 7. Visibility and the no-geometry case

When `inputfs_geom_known == 0` (drawfs absent at module load,
no display geometry available), the inputfs pointer accumulator
runs unclamped. `pointer_x` or `pointer_y` may go negative or
exceed any sensible value. In this case, the cursor surface is
hidden (`visible: false`) whenever either coordinate is outside
the daemon's idea of the framebuffer area, which the daemon
reads from the drawfs `efifb_width`/`efifb_height` it already
queries.

When geometry is known, the inputfs clamp guarantees the pointer
is always inside the area, so visibility is always `true`. This
case is the normal operating mode.

### 8. Hide on text input — out of scope

A common UX feature is to hide the cursor while the user is
typing into a text input, restoring it on next pointer movement.
This requires per-surface metadata ("this surface accepts text
input and prefers cursor hidden during type") and a hook in the
input event path. Both are real but neither is strictly in scope
for the cursor architecture; they are a focus-and-keyboard
concern that integrates with the cursor surface but doesn't
shape its design.

Tracked as a follow-up under AD-21 once the cursor surface
itself is in place.

### 9. Hardware cursor overlay — explicitly out of scope

Modern display hardware can composite a cursor sprite at scanout
time, bypassing the software framebuffer entirely. UTF will not
support hardware cursor overlay in the foreseeable future:

  - PGSD kernel currently has no GPU acceleration; the EFI
    framebuffer is software-only.
  - Hardware cursor formats are vendor-specific (Intel, AMD,
    NVIDIA each differ); supporting one means writing a driver,
    not a feature.
  - Software composite at the EFI framebuffer scale (3840×2160
    at 60 Hz is ~500 MB/s of pixel work) is well within CPU
    budget on the target hardware.

This decision keeps the cursor architecture simple: the cursor
surface is a software surface, composited like any other.

### 10. Ordering with pointer events

Pointer events flow through inputfs → semadrawd → focused
client. The cursor position update happens at composition time,
which is decoupled from event delivery: events go to the client
as they arrive, position updates go to the cursor at the next
frame.

This means there's a small window where the client has received
a `pointer.motion` event for a position the cursor sprite hasn't
yet caught up to. In practice the window is one frame
(16-33 ms at 30-60 Hz composite), invisible to the user. If
this becomes problematic (e.g., for drag-and-drop visual
fidelity), the cursor surface position update can be hoisted
out of the composition loop into an event-driven path, but the
simpler frame-driven model is the first cut.

## Why

A few choices in the above are not the only sensible ones, and
deserve their reasoning:

**Why one cursor surface, not per-client surfaces?** Because the
cursor is a singleton system feature. There is one pointer at a
time; there is one cursor. Clients don't draw their own cursor
because their cursor would only be visible while pointer focus
is on their surface, leaving the system with no cursor outside
focused regions. The daemon owns the cursor for the same reason
the daemon owns surface ordering: it's the only entity with the
necessary global view.

**Why z-order reservation rather than an `is_cursor` flag?**
Because z-order is the existing language of "draw order" in the
compositor. Adding `is_cursor` as a separate flag would mean
two ways to express "always on top," and the compositor's z-sort
would have to handle both. A reserved high z-value is the same
semantic, expressed in the existing API surface, with no new
code.

**Why does the daemon position-pump every frame, not just on
pointer movement?** Because the alternative — wiring the
inputfs event ring directly into a "cursor moved, mark damage,
schedule composite" path — would split the cursor's update
across two flow paths (event-driven for movement, composition-
driven for sprite changes). One path is simpler. The cost is a
no-op cycle when the pointer is stationary, which is what the
existing damage tracker already optimizes for.

**Why must SET_CURSOR require pointer focus?** Because the
focused surface is the one whose semantic meaning the cursor
should reflect (text I-beam over text, resize handle on a
window edge, hand on a clickable element). A non-focused client
changing the cursor is at best ineffective (its cursor would
appear over an unrelated surface) and at worst a UX attack
(impersonating another client's cursor). Tying the right to
SET_CURSOR to focus matches Wayland and X11.

**Why a 256×256 size limit on sprites?** Because there is no
legitimate cursor that large, and the limit is a cheap way to
prevent a malicious or buggy client from filling the screen
with a "cursor." 256 is generous (4× the typical cursor size);
clients that genuinely need larger glyphs should use a regular
surface.

## Out of scope for v1

Captured here so the implementation doesn't grow into them:

  - **Themed cursors.** No theme system, no cursor library,
    no XDG cursor lookup. Default arrow plus per-client SET_CURSOR.
  - **Animated cursors.** No multi-frame sprite, no animation
    timing. A future ADR can add it.
  - **Hide-on-type.** Tracked as a follow-up under AD-21.
  - **Per-client cursor caching across focus changes.** Tracked
    as a follow-up.
  - **Hardware cursor overlay.** Explicitly out of scope, see
    section 9.
  - **Multi-pointer / multi-seat cursors.** UTF assumes one
    pointer; multi-pointer would be its own multi-page ADR.

## Verification

Implementation is complete when:

  1. semadrawd starts and the default arrow appears at the
     pointer position on the EFI framebuffer.
  2. Moving the mouse moves the cursor; cursor lands at
     `(pointer_x - hotspot_x, pointer_y - hotspot_y)` exactly.
  3. Pushing the cursor against each of the four screen edges
     leaves no trail (damage propagation works), and the cursor
     stops at the clamped position (the inputfs D.3 clamp is
     already verified independently).
  4. A simple test client issues SET_CURSOR with a 24×24
     coloured square, focuses its surface, and the cursor
     changes to the square. On focus loss, the default arrow
     returns.
  5. A client without pointer focus that issues SET_CURSOR
     receives `ENOENT` and the cursor doesn't change.
  6. A client that issues SET_CURSOR with an oversized sprite
     (e.g. 1024×1024) receives `EINVAL`.
  7. inputfs+semadrawd together pass the AD-2a Phase 2.5 D.3
     edge-clamp verification (the original ask that surfaced
     this work).
