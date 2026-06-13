# ADR 0017: SDCS paint sources, part 2 (pattern sources)

## Status

Accepted 2026-06-13 (operator), with review revisions. Implements the
second part of Stage B (paint sources) from the program ADR 0014,
extending the source model that ADR 0016 established. ADR 0016 landed the current-source register and the
gradient sources under it; this ADR adds a pattern (surface) source as a
new arm of that same register, taking the opcode (0x000B) reserved for
it there. It reuses, rather than restates, the source state model and
the normative invariants B1-1 (compatibility) and B1-2 (paint affects
color only); it adds one pattern-specific equivalence invariant. ADR
0016 noted that patterns carry surface pixel data and a sampling model
that roughly doubles the surface area, which is why they are a sibling
ADR. ADR-before-code: no code lands until this is ratified. The software
reference renderer and golden tests are the closure gate (ADR 0002).

## 1. Context

ADR 0004 lists pattern fills alongside gradients as in-scope SDCS
capabilities, and ADR 0014 stages both as Stage B. ADR 0016 added
position-varying paint whose color is a continuous function of position
(gradients). A pattern is the other position-varying paint: the color is
a function of position sampled from a fixed grid of texels, a tile, that
repeats or clamps across the surface.

The driving consumer is NDE C3 chrome. Gradients (ADR 0016) cover focus
fills and depth backgrounds; patterns cover the cases gradients cannot:
a tiled texture behind a panel, a hatch or stipple used as a fill, a
small motif repeated as a background. METOC visualization is served by
gradients (colormaps) and does not need patterns, so this ADR is scoped
by the chrome use case.

SDCS already carries pixel data in one place. `BLIT_IMAGE` (0x0020)
embeds an image inline in its payload as `width * height * 4` bytes of
straight RGBA8, row-major, top-left origin, and composites it once at a
destination. A pattern is the same pixel grid used differently: as a
repeating paint sampled under the fill's coverage rather than blitted
once. This ADR reuses that texel layout exactly, so the format gains no
second image representation.

The distinction from `BLIT_IMAGE` is deliberate and is the scope
boundary for this ADR: blit places an image once at a position; a
pattern tiles an image as the paint of a fill, obeying the
affects-color-only rule and the fill's coverage. A single positioned
image is a blit, not a pattern.

## 2. Scope

This ADR adds:

  - `SET_SOURCE_PATTERN` (0x000B): a pattern (surface) source, a new arm
    of the current-source register from ADR 0016. It carries an inline
    tile, a pattern-to-user affine, per-axis extend modes, and a filter
    selector.

The source register, its default (`inline`), `SET_SOURCE_NONE`, and
`RESET` behavior are unchanged from ADR 0016 section 3. The register now
holds one more value, a pattern, in addition to `inline`, linear, and
radial.

The source register applies to fills only, as in ADR 0016: `FILL_RECT`
and `FILL_PATH`. Strokes, glyph runs, and `BLIT_IMAGE` ignore the
register and keep their existing semantics.

The SDCS minor version increments from 2 to 3; magic, chunk framing, and
all existing opcodes are unchanged. The validator rejects a newer minor
version, so a backend built before this ADR refuses a pattern stream
rather than misrendering it.

Opcode 0x000C is now the next free source opcode; no further source
opcodes are reserved here.

## 3. The source state model (reuse)

This ADR does not introduce a new state model. The current-source
register defined in ADR 0016 section 3 already admits arbitrary source
kinds; a pattern is one more value it can hold:

  - `inline` (default and `SET_SOURCE_NONE` value): the primitive's
    inline RGBA, as today.
  - a linear gradient (ADR 0016).
  - a radial gradient (ADR 0016).
  - a pattern (this ADR).

`RESET` (0x0001) returns the register to `inline`. `SET_SOURCE_NONE`
returns it to `inline`. Setting any source op replaces the register's
value. As with gradients, when the register holds a pattern, a fill
ignores its inline RGBA and takes its per-pixel color from the pattern.
An emitter may leave any value in a pattern-painted fill's inline RGBA;
the reference ignores it.

Inherited normative invariants. These are stated in ADR 0016 and apply
to every source, including patterns, without restatement here:

  - B1-1, compatibility. A stream that issues no source op renders
    byte-identically to SDCS v0.1.
  - B1-2, paint affects color only. A source affects only the per-pixel
    color a fill contributes, never coverage, antialiasing, blend mode,
    clipping, or transform. A fill computes coverage exactly as for a
    solid primitive, then at each covered pixel resolves the source
    color and blends it with that coverage.

New normative invariant for this stage:

  - B2-1, pattern and solid equivalence. A pattern whose every texel is
    the same color C SHALL render byte-identically to the solid fill of
    that color C, antialiased edges included, under any pattern affine
    and any extend mode. This is the pattern analog of B1-3 and the
    observable corollary of B1-2 for patterns: it holds because a
    uniform tile returns C at every sample, so the fill blends C at the
    coverage a solid fill would use. It is gated by golden tests
    (section 8).

Alternatives considered and rejected:

  - An image table or handle: define images once, reference them by id
    from `SET_SOURCE_PATTERN` (and later from `BLIT_IMAGE`), so a tile
    reused across many fills is transmitted once. Rejected for this
    stage in favor of inline tiles, which match how `BLIT_IMAGE` already
    carries pixels and how gradients carry their stops, and keep each
    op self-contained and statelessly validatable. A shared image table
    is a real future optimization for repeated large tiles, but it is a
    cross-cutting addition (it touches blit too) and is out of scope
    here; inlining does not preclude it later.
  - Normalized [0, 1] pattern space (the affine maps the unit square to
    user space, independent of tile resolution). Rejected in favor of
    texel space (section 4): texel space makes nearest sampling a direct
    floor with no extra multiply, matches the pixel-addressed mental
    model of the tile, and an emitter that wants resolution independence
    folds the tile dimensions into the affine in one step (the encoder
    can offer that convenience without changing the wire format).

## 4. Wire format

All scalars are little-endian f32 (`putF32LE`) or u32 (`putU32LE`).
Commands are padded to 8 bytes by the existing framing; payload fields
are read sequentially and need no internal alignment, as with
`FILL_PATH` and the gradient ops. The tile pixel array is not internally
aligned, consistent with `BLIT_IMAGE`.

`SET_SOURCE_PATTERN` (0x000B). Variable payload:

      offset  field
      0       a            f32   pattern-to-user affine (texel space to user)
      4       b            f32
      8       c            f32
      12      d            f32
      16      e            f32
      20      f            f32
      24      extend_x     u32   0 pad, 1 repeat, 2 reflect
      28      extend_y     u32   0 pad, 1 repeat, 2 reflect
      32      filter       u32   0 nearest (only 0 in this stage; reserved)
      36      tile_w       u32   texels, >= 1
      40      tile_h       u32   texels, >= 1
      44      texels       tile_w * tile_h * 4 bytes, RGBA8, row-major,
                                 top-left origin, straight (non-premultiplied)

  Fixed header 44 bytes, then `tile_w * tile_h * 4` pixel bytes. Total
  payload is 44 + tile_w * tile_h * 4.

The affine `(a, b, c, d, e, f)` uses the same convention as
`SET_TRANSFORM_2D`: a pattern-space point `(px, py)` maps to user space
as `x = a*px + c*py + e`, `y = b*px + d*py + f`. Pattern space is texel
coordinates: texel `(i, j)` occupies pattern-space `[i, i+1) x [j, j+1)`,
and texel `(0, 0)` is the top-left texel of the tile.

The texel layout is identical to `BLIT_IMAGE`: row-major, top-left
origin, four straight-RGBA8 bytes per texel, the texel at `(i, j)` at
byte offset `(j * tile_w + i) * 4`.

A future bilinear or mipmapped filter is an additive extension selected
by a nonzero `filter` value; the `filter` field reserves that space now,
so adding a filter is not a break. Per-axis extend leaves room for a
later transparent-outside mode as a new extend value if one is ever
needed; this stage does not define one (see non-goals).

Constraints (validation, section 6):

  - `a, b, c, d, e, f` all finite. Finiteness is checked first, before
    the determinant is evaluated, so a non-finite component is rejected
    without ever entering the determinant arithmetic.
  - the affine nondegenerate (it must be invertible for the
    user-to-pattern mapping). The test is evaluated on the decoded f32
    component values: with finiteness already established, compute
    `det = a*d - c*b` in f32 and reject when `det` compares equal to
    `0.0`. Specifying the test on the serialized f32 values, in f32,
    makes an encoder that validates the same components it will serialize
    and a validator that decodes them reach the same verdict on
    borderline cases.
  - `extend_x`, `extend_y` each in {0, 1, 2}.
  - `filter` == 0.
  - `tile_w`, `tile_h` each in [1, 4096].
  - payload length exactly 44 + tile_w * tile_h * 4, with the product
    computed in a 64-bit integer before comparison (see section 6).

## 5. Rasterization (reference oracle)

Normative, coordinate space. Pattern geometry (the affine) SHALL be
specified in user space and evaluated through the inverse of the current
transform at draw time, exactly as for gradients (ADR 0016 section 5).
Backends and the reference SHALL NOT interpret the pattern affine in
device space, nor snapshot the CTM when the source op is processed.

A pattern source is evaluated once per pixel, at the pixel center in
device space. Coverage is computed exactly as for a solid fill: analytic
for `FILL_RECT`, the 16-sample lattice for `FILL_PATH` (ADR 0015 section
5). The source never participates in coverage.

For a covered pixel whose center in device space is `Pd`:

  1. Map to user space. `Pu = Minv_ctm * Pd`, where `Minv_ctm` is the
     inverse of the CTM active at draw time, computed once per painted
     primitive (the same inverse gradients use). With the identity CTM
     `Pu = Pd`.
  2. Map to pattern (texel) space. `Pp = Minv_pat * Pu`, where
     `Minv_pat` is the inverse of the pattern affine, computed once per
     painted primitive.
  3. Take the integer texel indices `i = floor(Pp.x)`, `j = floor(Pp.y)`.
  4. Apply the per-axis extend to fold each index into range. For axis
     length `N` (`tile_w` for x, `tile_h` for y) and raw index `k`:
       - pad:     `clamp(k, 0, N - 1)`.
       - repeat:  `((k mod N) + N) mod N` (positive modulo).
       - reflect: let `m = ((k mod 2N) + 2N) mod 2N`; result is `m` if
                  `m < N`, else `2N - 1 - m`. Under reflect the edge
                  texel SHALL appear twice at each fold: the boundary
                  texel is duplicated, not skipped. Graphics systems
                  disagree on this and it is visible in the output, so it
                  is fixed here rather than left implementation-defined.
  5. Sample. With folded indices `(i', j')`, the color is the texel at
     byte offset `(j' * tile_w + i') * 4`: four straight-RGBA8 bytes.
  6. Blend. The texel color is blended via `fbBlendPixelAA` with the
     pixel coverage, the same call a solid fill makes. Texels are
     already 8-bit, so there is no quantization step.

Two affine inverses are computed per painted primitive (the CTM inverse
and the pattern inverse). The arithmetic is f32 affine inversion, `floor`
to integers, and integer modulo, all deterministic, so golden images are
stable across machines. This stage adds no nondeterminism source beyond
the pattern affine inverse, which is f32-deterministic like the CTM
inverse.

Normative, nearest sampling. SDCS nearest sampling is floor-based texel
selection (point sampling): the texel index is `floor(Pp)` per axis, as
in step 3, with no interpolation. It is NOT texel-center rounding, which
several graphics APIs call "nearest"; the two differ at texel
boundaries, and SDCS fixes the floor definition so there is no
tie-breaking ambiguity. The `filter` selector names this `nearest` (0)
to leave room for a future interpolating filter, but `filter == 0` always
means exactly the floor-based selection defined here, and a later filter
value does not change that meaning. Because the result is an exact texel
copy, the equals-solid invariant (B2-1) holds byte-for-byte.

Tile residency and resource policy. The decoded tile is part of the
current-source register: a backend SHALL keep it resident while the
register holds the pattern, because a fill samples arbitrary texels and
the tile cannot be stream-decoded. Setting another source,
`SET_SOURCE_NONE`, or `RESET` releases it. A stream may replace the
register with a large tile repeatedly; a backend MAY reject a
structurally valid stream whose tile exceeds its memory budget, but such
a rejection is a resource policy applied per resident source, distinct
from a malformed-stream rejection, and SHOULD be reported as resource
exhaustion rather than a format error. Structural validity (section 6)
bounds a single tile but does not oblige a backend to accept an arbitrary
sequence of large tiles.

## 6. Validation

`SET_SOURCE_PATTERN`, in the variable-payload group alongside
`FILL_PATH` and the gradient ops. The checks are ordered so that later
checks never operate on values an earlier check would reject:

  - payload at least the 44-byte fixed header, then `tile_w`, `tile_h`
    read.
  - `tile_w`, `tile_h` each in [1, 4096], else reject.
  - payload length exactly `44 + tile_w * tile_h * 4`, else
    `PayloadSize`. The product `tile_w * tile_h * 4` is computed in a
    64-bit integer (`u64`/`usize`) before the comparison, so large
    dimensions cannot overflow a 32-bit intermediate. The [1, 4096] bound
    keeps the true value within about 67 MB, but the wide computation is
    required regardless of the bound.
  - `a, b, c, d, e, f` finite (`isFiniteF32Bits`). This precedes the
    determinant, so the determinant is never computed from non-finite
    inputs.
  - affine nondegenerate: with finiteness established, compute
    `det = a*d - c*b` in f32 on the decoded component values and reject
    when `det` compares equal to `0.0`. Defining the test in f32 on the
    serialized values keeps an encoder (validating the components it will
    write) and a validator (decoding them) in agreement on borderline
    cases.
  - `extend_x`, `extend_y` each in {0, 1, 2}.
  - `filter` == 0.

The tile-dimension bounds and the exact-length check together bound a
single allocation: at most 4096 * 4096 * 4 bytes, and never more than the
declared payload. Bounding a sequence of large tiles is a renderer
resource policy, not a validation rule (section 5). The daemon cost
estimator (`sdcs_validator.zig`) treats `SET_SOURCE_PATTERN` as a state
change for the per-command draw cost, the same small fixed cost as the
other `SET_*` ops, consistent with how the gradient ops are estimated
(ADR 0016 section 6). Memory and admission-control accounting, by
contrast, SHALL key off the decoded tile size (`tile_w * tile_h * 4`),
not opcode count: a 2x2 tile and a 4096x4096 tile are one
`SET_SOURCE_PATTERN` each but are operationally very different, and the
resource policy of section 5 is meaningless if it counts ops rather than
bytes.

## 7. Encoder API

      pub const PatternFilter = enum(u32) { nearest = 0 };

      pub fn setSourcePattern(
          self: *Encoder,
          a: f32, b: f32, c: f32, d: f32, e: f32, f: f32,
          extend_x: ExtendMode,
          extend_y: ExtendMode,
          filter: PatternFilter,
          tile_w: u32,
          tile_h: u32,
          texels: []const u8,
      ) !void;

`ExtendMode` is reused from ADR 0016. The encoder rejects, with
`error.InvalidArgument`, a non-finite affine component (checked first), a
degenerate affine (`det = a*d - c*b` computed in f32 on the same
component values it will serialize, rejected when `det == 0.0`), `tile_w`
or `tile_h` outside [1, 4096], a `texels.len` not equal to
`tile_w * tile_h * 4` (the product taken in `usize`), an extend value
outside {0, 1, 2}, and a `filter` other than `nearest`. Validating the
determinant in f32 on the to-be-serialized components is what makes the
encoder agree with a decoding validator on borderline cases. It mirrors
`blitImage` and `fillPath`: compute payload length, allocate, write the
fixed header then `@memcpy` the texel array, and append.

A convenience that places a tile into a user-space rectangle without the
caller computing the affine by hand may be added as a thin wrapper over
`setSourcePattern`; it is not part of the wire format and is left to the
implementation.

## 8. Golden tests

Closure gate for this stage, in `tests/run.sh` and a `sdcs_make_pattern`
generator following the `sdcs_make_gradient` pattern:

  - Pattern fill (`FILL_RECT`) with a small distinct tile (for example a
    2x2 or 4x4 checker), repeat on both axes, identity CTM and identity
    pattern affine, golden hash.
  - Pattern fill (`FILL_PATH`) with the same tile, golden hash.
  - Pattern under a non-uniform scale combined with a rotation
    (`SET_TRANSFORM_2D`), golden hash. As with gradients, transform
    handling is where replay engines diverge, so this is required; it is
    the primary check on the section 5 coordinate-space rule for the CTM
    inverse.
  - Pattern with a non-identity pattern affine (the tile itself rotated
    and scaled, under an identity CTM), golden hash. This exercises the
    pattern inverse independently of the CTM inverse, so a bug in either
    inverse is distinguishable.
  - Extend modes: a tile smaller than the filled region, rendered pad,
    repeat, and reflect. Golden hashes, and an invariant that repeat
    differs from pad over the region beyond the tile.
  - Reset: a pattern fill, then `SET_SOURCE_NONE`, then a solid fill; the
    solid region renders as the inline color (`cmp` against a solid-only
    reference).
  - Equivalence, `FILL_RECT` (invariant B2-1): a uniform-color tile fills
    byte-identically to the solid fill of that color (`cmp`).
  - Equivalence, `FILL_PATH` (invariant B2-1): the same uniform-tile
    equivalence on a path, exercising the pattern sampler against the
    solid path independently of the rect path (`cmp`).
  - Determinism: a pattern scene rendered twice is identical.

## 9. Non-goals

  - No bilinear, trilinear, or mipmapped sampling. Nearest only; the
    `filter` field reserves the space for a later additive filter.
  - No transparent-outside (Cairo `EXTEND_NONE`) mode. A single
    positioned image with transparent surroundings is a `BLIT_IMAGE`,
    which already exists; patterns tile. A transparent-outside extend
    could be added later as a new extend value if a fill-shaped use case
    appears.
  - No image table or handle, no caching of tiles across ops. Each
    `SET_SOURCE_PATTERN` carries its own tile inline, as `BLIT_IMAGE`
    does. A shared image table is a possible future optimization.
  - No source application to strokes, glyph runs, or blit. Fills only,
    as in ADR 0016.
  - No color management or gamma handling. Texels are straight RGBA8 in
    the format's existing color space; ADR 0004's boundary holds.
  - No premultiplied tile data. Texels are straight RGBA, matching
    `BLIT_IMAGE` and the rest of SDCS.

## 10. Consequences

  - SDCS expresses tiled and surface-sampled paint natively. NDE chrome
    gains textured and stippled fills under the same transform,
    coverage, and determinism guarantees as solid and gradient fills.
  - The source register gains a pattern arm and the per-pixel resolver
    gains a texel sampler. The coverage and blend paths are unchanged,
    and the sourced fill functions added for gradients (ADR 0016, the
    sourced `FILL_RECT` and `FILL_PATH` paths) are reused as-is: a
    pattern is a different per-pixel color function under the same fill
    machinery. B2-1 holds for the same structural reason B1-3 does.
  - The format reuses the `BLIT_IMAGE` texel layout, so there is one
    image representation in SDCS, not two. A future image table, if
    added, would unify pattern tiles and blit images behind one handle.
  - Inline tiles make a pattern op as large as its tile. The use case is
    small chrome tiles, and the 4096-per-axis bound plus the exact
    payload-length check bound the cost, but a large tile reused across
    many fills is transmitted once per op; the image-table option exists
    if that becomes a problem.

## 11. Risks

  - Determinism of the two affine inverses and the sampling arithmetic.
    Mitigation: the same all-f32, non-fused discipline as the CTM
    inverse, `floor` and integer modulo for indexing, goldens as the
    gate, and the equals-solid invariant B2-1 as a cross-check.
  - Temptation to couple coverage and color, or to let nearest sampling
    drift toward a half-texel offset that breaks equals-solid.
    Mitigation: B1-2 and B2-1 are normative and gated; a uniform tile
    must reproduce the solid fill exactly, which fails if sampling
    perturbs coverage or color.
  - Extend-fold edge cases at negative indices and at fold boundaries.
    Mitigation: the positive-modulo and reflect formulas in section 5
    are normative and specified for all integer `k`, including negative,
    and are unit-tested directly (not only through goldens).
  - Encoder and validator disagreeing on a borderline determinant or a
    payload length. Mitigation: the nondegeneracy test is defined in f32
    on the serialized component values and the length product is computed
    in a wide integer (section 6), so both sides reach the same verdict
    and neither overflows.
  - Tile allocation size, single and cumulative. Mitigation: the per-axis
    [1, 4096] bound and the exact payload-length check bound a single
    allocation before any tile is read; a stream that repeatedly installs
    large tiles is addressed by the per-resident-source resource policy
    (section 5), which a backend MAY enforce as resource exhaustion
    distinct from a format error.

## Revision history

  - 2026-06-13: drafted (Proposed).
  - 2026-06-13: folded operator review revisions (specification
    tightening, no design change). Defined the affine nondegeneracy test
    in f32 on the serialized component values, rejected on `det == 0.0`,
    with finiteness checked first; required the payload-length product to
    be computed in a 64-bit integer to avoid 32-bit overflow; stated
    normatively that SDCS nearest sampling is floor-based texel selection
    (point sampling), not texel-center rounding, and that `filter == 0`
    keeps that meaning under any future filter; elevated reflect-mode
    edge-texel duplication to a normative requirement; added a tile
    residency and resource-policy paragraph (the tile is resident source
    state, releasable on source change or reset, and a backend MAY reject
    a structurally valid stream for resource exhaustion as a policy
    distinct from a format error). Aligned the encoder API and risks
    sections with these.
  - 2026-06-13: ratified. Operator decisions on the two open questions:
    kept the 4096-per-axis tile cap (conservative, covers the chrome use
    case, raising it later is additive while lowering it would break
    streams), and kept the `setSourcePattern` parameter order as a near
    1:1 mirror of the wire layout, deferring caller ergonomics to the
    section 7 convenience wrapper. Folded the operator note that memory
    and admission-control accounting key off the decoded tile size, not
    opcode count (section 6). No architectural change.
