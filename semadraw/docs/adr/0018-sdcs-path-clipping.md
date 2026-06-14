# ADR 0018: SDCS path clipping (arbitrary clip path)

## Status

Accepted 2026-06-14 (operator), with review revisions. Implements Stage C
(path clipping) from the program ADR 0014, the last of the three stages
that ADR 0014 opened (Stage A fill in ADR 0015, Stage B paint sources in
ADR 0016 and ADR 0017). It extends clipping from the existing union of
axis-aligned rectangles (`SET_CLIP_RECTS`) to an arbitrary path clip
(`SET_CLIP_PATH`), taking the next free state-block opcode (0x000C)
alongside `SET_CLIP_RECTS` (0x0002) and `CLEAR_CLIP` (0x0003). It reuses,
rather than restates, the Stage A path encoding (the `FILL_PATH` contour
layout from ADR 0015) and the Stage A winding predicate, and it reuses
the existing clip lifecycle (a clip is set, replaced, or cleared, and
tested as a per-sample membership predicate at every draw). It adds one
clip-specific equivalence invariant. ADR-before-code: no code lands until
this is ratified. The software reference renderer and golden tests are
the closure gate (ADR 0002).

## 1. Context

The reference renderer already clips. The clip state today is a union of
axis-aligned rectangles, set by `SET_CLIP_RECTS` and cleared by
`CLEAR_CLIP`, and it is tested as a per-pixel (for antialiased draws,
per-sub-sample) membership predicate inside every draw routine: a sample
that fails the clip is not painted. Rectangle-list clipping covers most
current UI, which is why ADR 0014 ranked path clipping lowest in urgency.

Stage A added `FILL_PATH` (ADR 0015): one or more closed contours under a
winding rule (nonzero or even-odd), rasterized by a point-in-path
predicate that the reference renderer already implements and tests. A
path clip is the same region machinery viewed as a mask rather than as a
fill: the clip admits a sample exactly when that sample lies inside the
clip path under its winding rule. The work of this stage is therefore not
new geometry but the wiring of the existing path predicate into the
existing clip test, plus the wire format and validation to carry the clip
path on the stream.

Two facts about the current renderer shape this design. First,
`FILL_PATH` transforms its points by the current transform at draw time,
so its contours are authored in user space. Second, `SET_CLIP_RECTS`
stores its rectangles in device space and does not apply the current
transform. The path clip follows `FILL_PATH`, not `SET_CLIP_RECTS`, on
the coordinate-space question, for the reason given in section 3.

## 2. Scope

In scope:

  - One new state opcode, `SET_CLIP_PATH` (0x000C): replace the current
    clip with an arbitrary path region, given as one or more closed
    contours under a winding rule, in user space.
  - A second clip kind in the reference renderer (path, beside the
    existing rectangle-list kind), set by `SET_CLIP_PATH`, replaced by
    either clip setter, and cleared by `CLEAR_CLIP`.
  - The normative clip-equals-fill-mask invariant (C-1) that ties the
    path clip to the Stage A fill.
  - Wire format, validation, encoder API, and the golden coverage that
    closes the stage.

Out of scope (section 9 lists the full set): a clip stack or
save-and-restore, intersection of two clip kinds (setting one replaces
the other), any change to `SET_CLIP_RECTS` device-space semantics, soft
or feathered clips, and per-primitive clip.

## 3. The clip state model (reuse)

The clip is current-clip state, exactly as it is today: a draw is tested
against whatever clip is in effect at the time of that draw. This ADR
generalizes the clip from one kind to two:

  - none: every sample passes (the unset and post-`CLEAR_CLIP` state).
  - rectangles: a sample passes when it lies in the union of the clip
    rectangles. Unchanged from `SET_CLIP_RECTS`.
  - path: a sample passes when it lies inside the clip path under its
    winding rule. New, set by `SET_CLIP_PATH`.

Setting either kind replaces the current clip. `SET_CLIP_PATH` after
`SET_CLIP_RECTS` discards the rectangles and installs the path, and the
reverse discards the path. This mirrors the existing replace semantics of
`SET_CLIP_RECTS` (each call replaces the prior rectangle list) and avoids
introducing a clip stack or an intersection of clip kinds, either of
which is a larger design that would belong in its own ADR. `CLEAR_CLIP`
clears whichever kind is active and returns to none.

Coordinate space. The clip path is authored in user space and resolved
to device space by the current transform in effect at the time of
`SET_CLIP_PATH`. The transformed device-space contours become the stored
clip region and remain unchanged until replaced or cleared. This matches
`FILL_PATH`, which transforms its points by the draw-time transform, and
it is what makes the central invariant hold:

  Invariant C-1 (clip equals fill mask). Let D be the device-space
  contour produced by transforming a path P, under winding rule W, by the
  transform active at the time of `SET_CLIP_PATH`. Setting the clip to
  (P, W) and then filling, with color C, a primitive that fully covers D
  paints exactly the pixels that filling D directly with C under W would
  paint, byte for byte.

C-1 is the anchor of the stage. It says a path clip clips to exactly the
region the same contour fills, with the same antialiased edge, so that
"clip to this shape" and "fill this shape" cannot diverge.

The invariant is stated over the device-space contour D, not over the
user-space path P, on purpose. `FILL_PATH` transforms its points by the
transform active at draw time, while `SET_CLIP_PATH` transforms at set
time. The two produce the same device-space contour only when the
transform active at the fill equals the transform active when the clip
was set. C-1 therefore holds when the clip and the equivalent fill are
evaluated under the same transform state; it is not a claim about a fill
performed under a later, different transform. Concretely, the sequence
`SET_TRANSFORM(A); SET_CLIP_PATH(P); SET_TRANSFORM(B); FILL_PATH(P)` does
not satisfy C-1, because the clip is baked under A and the fill is
transformed under B; the device-space contours differ, and that is the
intended behavior (see transform immutability, next paragraph).

Because the clip is baked to device space when it is set, a later
`SET_TRANSFORM_2D` does not move an installed clip. This is the standard
2D model (a clip is established in the current transform space, then
fixed) and it keeps the clip predicate a pure device-space test with no
per-draw inverse.

Known asymmetry. `SET_CLIP_RECTS` remains device-space and
transform-naive; this ADR does not change it and does not retroactively
make rectangle clips transform-aware. Path clips are transform-aware.
Consumers should not assume the two clip kinds share a coordinate-space
model, and an implementation must not silently transform rectangle clips
to match path clips. Harmonizing the two is a possible later ADR and is
out of scope here.

Degenerate and empty clips. A clip path whose region is empty (for
example a zero-area contour, or contours that the winding rule resolves
to no interior) admits no samples, so all subsequent drawing is clipped
away until the clip is replaced or cleared. This is well defined by the
winding predicate with no special-casing, and the validator does not
reject it: an empty region is a valid region.

## 4. Wire format

`SET_CLIP_PATH` (0x000C) reuses the `FILL_PATH` contour layout (ADR 0015)
with the 16-byte RGBA prefix removed, since a clip is a region, not a
paint.

Payload, little-endian throughout:

  - Header, 8 bytes:
      - `fill_rule` (u32): 0 nonzero, 1 even-odd. Same enum as
        `FILL_PATH`.
      - `contour_count` (u32): number of closed contours, 1 to 65535.
  - Contour table: `contour_count` entries, each a u32 point count for
    that contour. Each count is at least 3.
  - Points: for each contour in order, its points as (x: f32, y: f32)
    pairs, user space. The total point count across all contours is at
    most 65535.

Total payload length is `8 + contour_count * 4 + total_points * 8`, which
the validator recomputes and checks exactly. Contours are implicitly
closed (the last point connects to the first), as in `FILL_PATH`; no
explicit closing point is encoded.

The SDCS minor version increments from 3 to 4. The magic, header, and
chunk framing are unchanged. An older backend that does not know opcode
0x000C rejects the stream through the existing unknown-opcode path rather
than misrendering it.

## 5. Rasterization (reference oracle)

Decode. On `SET_CLIP_PATH`, the renderer reads the header and contour
table, then reads each user-space point and transforms it by the current
transform (the same `applyT` that `FILL_PATH` uses) into device space. It
stores the device-space points, the per-contour lengths, and the winding
rule as the active clip, with kind set to path. Any previously installed
clip (rectangles or path) is released first.

Normatively, the renderer stores only the transformed device-space
contour. The original user-space coordinates are not retained, and the
clip is not a live user-space object that re-resolves under a later
transform. The path clip state is:

```text
struct ClipPath {
    FillRule rule;
    []Point  device_points;
    []u32    contour_lengths;
}
```

with no reference to the transform that produced `device_points`. This
keeps the clip a fixed device-space region and forbids an implementation
from accidentally treating it as transform-relative.

Predicate. The per-sample clip test generalizes to a dispatch on the
active clip kind:

  - none: passes.
  - rectangles: the existing point-in-rectangles test (union).
  - path: the existing point-in-path predicate from Stage A, evaluated
    against the stored device-space clip contours and winding rule.

Every draw routine already performs a clip test at each sample it might
paint (at the pixel center for aliased draws, at each of the 16 fixed
sub-sample offsets for antialiased draws). That test routes through the
kind dispatch above. Nothing else in the draw routines changes: the clip
remains a gate on whether a sample contributes, so a path clip yields an
antialiased clip edge of the same quality as the fill, because it is
evaluated at the same sub-samples.

Fast-path interaction. The rectangle clip has a fast path: a rectangle
fill under a rectangle clip is rendered by intersecting the two
axis-aligned rectangles and filling the intersection, with no per-sample
clip test. That fast path is valid only because a rectangle intersected
with a rectangle is a rectangle. It does not apply to a path clip. Under
a path clip, a rectangle fill falls back to the same per-sample coverage
computation used by `emitFilledPath`: for each pixel in the rectangle,
count the sub-samples that lie inside the clip path, and paint at that
coverage.
This fallback is not merely an implementation detail; it is what makes
C-1 exact. The covering rectangle of C-1 contains the clip path P, so
every sub-sample that lies inside P also lies inside the rectangle, and
the per-pixel inside-sample count is identical to the count
`emitFilledPath` computes when filling P directly. Identical counts,
identical color, identical blend yield identical bytes.

## 6. Validation

Validation follows the existing SDCS model, the same one `FILL_PATH`
uses. `validateOpcodePayload` performs only coarse payload-shape
validation: by construction it receives the payload length, not the
payload body, so it cannot inspect `fill_rule`, `contour_count`, contour
lengths, or point totals. Field-level validation of `SET_CLIP_PATH`
occurs in the components that parse the payload body, the encoder before
serialization and the renderer/replay path while decoding. The live
validators treat `SET_CLIP_PATH` as a variable-length opcode for framing
purposes, ensuring its payload stays within the declared chunk, exactly
as they already do for `FILL_PATH`.

Coarse shape, in `validateOpcodePayload`: the payload is at least 36
bytes (the 8-byte header plus the smallest possible body, one contour of
three points: `8 + 1 * 4 + 3 * 8`), and `payload - 8` is a multiple of 4
(the contour table is a multiple of 4 bytes and the point array a
multiple of 8). This mirrors the coarse size-shape case that
`SET_SOURCE_PATTERN` carries; it does not attempt the field-level checks,
which need the body.

Field-level, in the encoder and (in increment 2) the decode path:
`fill_rule` in {0, 1}; `contour_count` in 1..65535; each contour length
at least 3; total points at most 65535; the reconstructed payload length
equal to `8 + contour_count * 4 + total_points * 8` exactly; and point
coordinates finite (the encoder rejects non-finite coordinates before
serialization, as `fillPath` does). The reconstructed-length computation
and the running point total must be performed in a type wide enough to
avoid integer overflow (u64 or usize), not u32, so a malformed stream
cannot wrap a product around a length check. This matches the
overflow-safe accounting ADR 0017 requires for the pattern payload.

## 7. Encoder API

A single new method, mirroring `fillPath` with the color arguments
removed:

```
pub fn setClipPath(
    self: *Encoder,
    contours: []const []const Point,
    fill_rule: FillRule,
) !void
```

It applies the same argument validation `fillPath` applies: at least one
contour, at most 65535; each contour at least 3 points; at most 65535
points in total; all coordinates finite. It serializes the 8-byte header,
the contour table, and the points, then appends the `SET_CLIP_PATH`
command. The existing `setClipRects` and `clearClip` are unchanged.

## 8. Golden tests

Closure gate for the stage, in `tests/run.sh` and a `sdcs_make_clip`
generator following the `sdcs_make_pattern` and `sdcs_make_gradient`
pattern:

  - Basic path clip, golden hash: set a clip to a non-rectangular convex
    contour (for example a hexagon), fill a covering rectangle with a
    solid color, and confirm only the clip region is painted.
  - Path clip with a hole, golden hash: a two-contour clip (outer
    contour and an inner contour) under each winding rule, so the
    nonzero and even-odd interpretations of the hole are both pinned.
  - Path clip under a non-uniform scale combined with a rotation, golden
    hash. As with the gradient and pattern transform goldens, this is the
    primary check on the section 3 coordinate-space rule: the clip is set
    with a non-identity transform, the transform is then reset, and a
    covering rectangle is filled; the clip must remain in the transformed
    device region.
  - Transform immutability (`cmp`): establish a clip under transform A,
    change the transform to B, draw, and confirm the result is
    byte-identical to an equivalent rendering where B is never applied.
    This proves the clip was baked at set time and is unaffected by later
    transform changes, verifying the section 3 semantics directly rather
    than indirectly through C-1.
  - Invariant C-1, covering FILL_RECT (`cmp`): with the identity
    transform in effect (so the device-space contour D equals the
    authored path P), clip to P, fill a full-canvas rectangle with color
    C, and confirm the result is byte-identical to filling P with C
    directly under the same transform. This is the central equivalence
    and pins the rectangle-under-path-clip fill to the same sampler as the
    path fill.
  - Invariant C-1 on a multi-contour P (`cmp`): the same equivalence,
    under the same transform, on a path with a hole, so the clip
    predicate and the fill agree on the winding parity, not just on a
    simple convex region.
  - Clear restores unclipped drawing (`cmp`): clip to P, `CLEAR_CLIP`,
    fill a rectangle, and confirm the result is byte-identical to filling
    that rectangle with no clip ever set.
  - Replace, rectangles then path (`cmp`): set a rectangle clip, then set
    a path clip, then fill; confirm the result is byte-identical to
    setting only the path clip, so the path replaces rather than
    intersects the rectangles.
  - Winding distinction (`cmp` differ, or two hashes): a self-overlapping
    clip contour clips differently under nonzero than under even-odd, so
    the two must not be byte-identical.
  - Determinism: a clip scene rendered twice is identical.

## 9. Non-goals

  - No clip stack and no save-or-restore of clip state. There is one
    current clip; setting replaces it, clearing removes it.
  - No intersection of clip kinds. A path clip does not intersect a prior
    rectangle clip or a prior path clip; it replaces it. Stacked or
    intersected clips are a separate design.
  - No change to `SET_CLIP_RECTS`. Rectangle clips remain device-space
    and transform-naive; this ADR does not harmonize them with the
    transform-aware path clip.
  - No soft, feathered, or alpha-mask clip. The clip is a hard region;
    its antialiased edge comes only from the shared sub-sampling, not
    from a separate softness control.
  - No per-primitive clip argument. The clip is state, applied to every
    draw until replaced or cleared.
  - No widening of ADR 0004. No new geometry primitives enter SDCS here.

## 10. Consequences

  - The clip test becomes a small kind dispatch shared by every draw
    routine. The rectangle fast path is kept for the rectangle kind and
    bypassed for the path kind.
  - A rectangle fill under a path clip costs a per-sample point-in-path
    test per covered pixel, where a rectangle fill under a rectangle clip
    costs a rectangle intersection. This is the price of arbitrary clip
    geometry and is paid only when a path clip is active.
  - C-1 holds by construction once the rectangle-under-path-clip fill
    uses the same sub-samples and the same predicate as the path fill,
    which it must, since the rectangle intersection fast path cannot
    apply. The invariant and its test keep the clip and the fill from
    drifting.
  - With Stage C landed, ADR 0014 (fill, paint sources, and path
    clipping) is closed: SDCS reaches its chartered 2D scope for fills,
    paint sources, and clipping.
  - The device-space rectangle clip and the user-space path clip coexist
    with a documented asymmetry. If a future consumer needs
    transform-aware rectangle clips, that is a later, separate change.

## 11. Risks

  - Cost. A per-sample point-in-path test over a large fill under a
    large, many-edged clip path is slower than a rectangle clip. For the
    reference oracle this is acceptable (correctness over speed, ADR
    0002); a GPU backend can express the clip with a stencil and does not
    inherit the oracle's per-sample loop.
  - C-1 byte-identity depends on the rectangle-under-path-clip fill and
    the path fill using identical sub-sample offsets and the identical
    predicate. The C-1 goldens enforce this and would fail if the two
    ever diverged.
  - A degenerate or self-intersecting clip contour is well defined by the
    winding predicate, but a zero-area or empty-region clip blanks all
    subsequent output. That is correct but can surprise an author; the
    validator does not reject it, because an empty region is valid. The
    golden suite includes a winding-distinction case but not an
    all-clipped case, since its output is trivially blank.

## Revision history

  - 2026-06-14: initial draft (Proposed).
  - 2026-06-14: operator review folded (Proposed). Tightened invariant
    C-1 to the device-space contour D and the same-transform-state
    condition, with the differing-transform sequence called out as
    intended non-equivalence. Stated normatively that the renderer stores
    only the baked device-space contour (with a ClipPath state sketch)
    and not the user-space path. Required overflow-safe (u64 or usize)
    payload-length accumulation in validation. Added a transform
    immutability golden. Added a consumer note that the two clip kinds do
    not share a coordinate-space model. Minor lifecycle wording.
  - 2026-06-14: ratified (Accepted, operator). Second review pass: minor
    editorial polish ("per-sample coverage computation" wording in
    section 5, shortened the transform immutability test description). No
    normative changes.
  - 2026-06-14: section 6 erratum (operator). Rewrote validation to match
    the existing SDCS architecture: `validateOpcodePayload` carries only a
    coarse payload-shape case (the prior text implied field-level checks
    in a size-only function and claimed to mirror a `FILL_PATH` case that
    does not exist). Field-level checks live in the encoder and the decode
    path, and the live validators treat `SET_CLIP_PATH` as variable-length
    for framing, as they already do for `FILL_PATH`. No change to the wire
    format or the normative semantics.
