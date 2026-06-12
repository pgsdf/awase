# 0004 SDCS scope

Status: Accepted

## Context

SDCS is the canonical binary representation of graphics intent
in the UTF stack (per ADR 0001). It encodes 2D compositing
operations: rectangles, lines, curves, glyph runs, transforms,
clips, blends, blits. Backends consume SDCS and produce
pixels; recordings of SDCS replay deterministically.

The pressure to extend SDCS comes from two natural-looking
directions:

1. **3D and shader-style operations.** A consumer wants to
   render a 3D mesh, run a custom fragment shader, or
   composite a video frame with effects. Adding opcodes for
   these (DRAW_MESH, SET_SHADER, BLIT_VIDEO_DECODED) seems
   like a small extension.
2. **Heavy compute operations.** A consumer wants to run a
   tensor operation, an image-processing filter, or a
   numerical kernel. Adding opcodes for these
   (DISPATCH_COMPUTE, RUN_KERNEL) seems like a parallel
   extension.

Both pressures are reasonable in isolation. Both are wrong
for SDCS.

## Decision

**SDCS is for 2D compositing intent only.**

3D rendering, video decode, custom shaders, and heavy compute
do not enter SDCS. Consumers that need those route directly to
Vulkan (or another platform 3D/compute API) when available,
bypassing SDCS entirely. SDCS remains a focused 2D compositing
language.

This is a hard scope boundary, not a "we will add these later"
deferral. The decision is that these will not be added.

## Why

SDCS's value is in being **small enough to specify completely
and replay deterministically**. Every opcode has a documented
byte layout. Every backend produces the same pixels for the
same input. Recording is a flat byte log; replay is a
straightforward decode loop.

Adding 3D, shader, video, or compute operations breaks this in
several ways:

- **Determinism collapses.** GPU pipelines have driver-,
  hardware-, and vendor-specific behaviour even for nominally
  identical operations. A SDCS recording that includes
  DRAW_MESH would replay differently across machines, which
  defeats the purpose of having a stream format.
- **Specification grows without bound.** SDCS today has
  roughly two dozen opcodes. Adding 3D would require
  vertex attribute formats, primitive topology, depth/stencil
  state, MSAA, framebuffer attachments, blit semantics across
  format conversions, and shader stage interfaces. Adding
  compute would require workgroup sizes, memory barriers,
  buffer bindings, and atomic operation semantics. The spec
  becomes Vulkan-shaped.
- **Backend complexity explodes.** Today every SDCS opcode
  has a 2D rasteriser implementation in the reference
  backend. Adding 3D requires a full 3D pipeline; adding
  compute requires a compute pipeline. The reference
  renderer stops being a reference of SDCS and starts being
  a re-implementation of a graphics API.
- **The 2D compositing job stops being done well.** Time
  spent on 3D / video / compute extensions is time not spent
  on the things SDCS exists to do: text rendering, surface
  composition, clipping, transforms, blends.

Vulkan exists. It does 3D, compute, and video. Consumers that
need those should use it directly. semadraw can and should
provide bridges (a surface that a Vulkan client renders into,
a SDCS opcode that BLITs from a Vulkan-rendered texture into
the compositor's surface tree) but the Vulkan side of the
bridge is not SDCS.

## Boundaries this does not cross

What stays in SDCS:

- All current opcodes (rectangles, lines, curves, fills,
  strokes, transforms, clips, blends, glyph runs, blits
  between SDCS-managed surfaces).
- 2D anti-aliasing, sub-pixel positioning, gradient fills,
  pattern fills, alpha compositing variants.
- Path operations (Bezier curves, fills with winding rules,
  stroke styling).
- Future 2D compositing work as it arises.

What does not enter SDCS:

- 3D primitives (DRAW_MESH, vertex buffers, index buffers,
  depth testing).
- Custom shader stages (fragment shaders, compute shaders,
  geometry/tessellation shaders).
- Video decode primitives (DECODE_H264, BLIT_VIDEO_FRAME).
- Heavy compute (DISPATCH_COMPUTE, tensor operations,
  image-processing kernels expressed as compute).
- Driver-level GPU operations (queue submission, sync
  primitives, memory management).

## Consequences

**Positive:**

- SDCS stays specifiable, small, and deterministic.
- Recording and replay remain first-class.
- The reference renderer remains a reference of SDCS, not a
  partial Vulkan re-implementation.
- The boundary is explicit, so future contributors know
  where to push back when extension proposals arrive.

**Negative:**

- Consumers that need 3D, video, or compute must use Vulkan
  (or another platform API) and bridge their output back
  into the surface tree via an existing SDCS BLIT opcode.
  This is more work than a single SDCS extension would be.
  Accepted: the 3D / video / compute work is intrinsically
  large; pretending it fits in SDCS does not make it
  smaller, only harder to specify.
- The ecosystem cannot use SDCS as a universal graphics
  language. SDCS is for 2D compositing; that is its purpose
  and its limit.

**Neutral:**

- No code changes accompany this ADR. SDCS today is already
  2D-only; this ADR documents the existing reality and
  declares that it stays that way.

## Notes

This ADR makes explicit a discipline that was previously
implicit. NON_GOALS.md already mentioned "Defining a 3D
scene graph" and "Becoming a driver framework," which point
in the same direction but do not name SDCS specifically and
do not address compute or video. This ADR fills that gap.

The decision aligns with UTF's broader architectural
discipline (`docs/UTF_ARCHITECTURAL_DISCIPLINE.md`): UTF
depends only on code written with UTF's guarantees in mind.
SDCS is one such guarantee path. Code that needs 3D, video,
or compute does not share UTF's determinism commitments by
construction (driver behaviour, hardware variance), so it
cannot live inside SDCS without breaking those commitments.
