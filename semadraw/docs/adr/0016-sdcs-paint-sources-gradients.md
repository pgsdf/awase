# ADR 0016: SDCS paint sources, part 1 (linear and radial gradients)

## Status

Accepted 2026-06-13 (operator), with review revisions. Implements the
first part of Stage B (paint sources) from the program ADR 0014. This ADR settles the paint-source
state model that ADR 0014 section 4 deferred to Stage B, and lands
linear and radial gradient sources under it. Pattern (surface) sources
are the second part of Stage B and move to a sibling ADR 0017, because
they carry surface pixel data and a sampling model that roughly doubles
the surface area; the state model fixed here is what that ADR extends.
ADR-before-code: no code lands until this is ratified. The software
reference renderer and golden tests are the closure gate (ADR 0002).

## 1. Context

ADR 0004 lists gradient and pattern fills as in-scope SDCS
capabilities, and ADR 0014 stages them as Stage B. Today every drawing
primitive carries solid RGBA inline in its payload: `FILL_RECT`,
`FILL_PATH` (ADR 0015), and the stroke primitives each end with four
f32 color components, and the reference renderer quantizes that one
color to 8 bits and blends it through `fbBlendPixelAA` with the
primitive's coverage. There is no notion of a paint whose color varies
across the surface.

A gradient is exactly such a paint: the color is a function of position.
The two consumers that drove Stage A need it next. METOC visualization
expresses a colormap as a ramp of color against a scalar field; a
colormap is a linear gradient, and today it can only be precomputed and
blitted, which forfeits the transform and determinism guarantees.
NDE C3 chrome (focus fills, rounded-rect backgrounds with depth) reads
as flat without gradient fills.

## 2. Scope

This ADR adds:

  - A current-source state register on the render context, defaulting
    to a sentinel meaning "use the primitive's inline RGBA". This is
    the paint-source model for all sources, present and future.
  - `SET_SOURCE_NONE` (0x0008): reset the register to the inline
    default.
  - `SET_SOURCE_LINEAR_GRADIENT` (0x0009): a linear gradient source.
  - `SET_SOURCE_RADIAL_GRADIENT` (0x000A): a concentric radial gradient
    source.

The source register applies to fills only in this stage: `FILL_RECT`
and `FILL_PATH`. Strokes, glyph runs, and image blit ignore the
register and keep their existing color and semantics. Extending source
application to strokes is a later, additive step; glyph runs are a
non-goal per ADR 0014.

Opcode 0x000B is reserved for `SET_SOURCE_PATTERN` (ADR 0017). The SDCS
minor version increments from 1 to 2; magic and chunk framing are
unchanged. The validator rejects a newer minor version, so an older
backend refuses a gradient stream rather than misrendering it.

This ADR deliberately does not add `SET_SOURCE_SOLID`, which ADR 0014
section 5 listed tentatively. In this model the inline RGBA already is
the solid source, and `SET_SOURCE_NONE` returns to it, so a separate
solid-source opcode would be a redundant second path to the same
result. Omitting it keeps the opcode set minimal.

## 3. The paint-source state model

The register is one piece of render state, in the family of `SET_BLEND`,
`SET_TRANSFORM_2D`, `SET_ANTIALIAS`, and the clip state. Its value is
one of:

  - `inline` (the default and the `SET_SOURCE_NONE` value): the
    primitive's own inline RGBA is the paint, exactly as today.
  - a linear gradient.
  - a radial gradient.

`RESET` (0x0001) returns the register to `inline` along with the rest of
the state. When the register holds a gradient, a fill ignores its inline
RGBA and takes its per-pixel color from the gradient instead. An emitter
may leave any value in a gradient-painted fill's inline RGBA field; the
reference ignores it. RECOMMENDED, for stream inspection and debugging
rather than as a format requirement: emit the first stop's color there,
so a dump shows a representative color instead of stale or zero bytes.

Normative invariants. The following are rendering requirements, not
explanatory notes.

  - B1-1, compatibility. A stream that issues no source op SHALL render
    byte-identically to the same stream under SDCS v0.1. The register's
    default value is `inline`, so existing streams are unaffected.
  - B1-2, paint affects color only. A paint source SHALL affect only the
    per-pixel color a fill contributes. It SHALL NOT affect coverage,
    antialiasing, blend mode, clipping, or transform. A fill computes
    coverage exactly as it would for a solid primitive, then, at each
    covered pixel, resolves the source color and blends it with that
    coverage.
  - B1-3, gradient and solid equivalence. A gradient whose stops all
    resolve to the same color SHALL render byte-identically to the solid
    fill of that color, antialiased edges included. This is the
    observable corollary of B1-2 and is gated by golden tests
    (section 8).

Alternatives considered and rejected:

  - Per-primitive source (embed the gradient in each fill payload).
    Rejected: it bloats every fill, duplicates a shared gradient across
    fills, and does not generalize to strokes or future sources without
    per-op bloat. A state register matches how SDCS already carries
    blend, transform, clip, and antialias.
  - Set-time transform capture (snapshot the CTM when the source is set,
    Cairo pattern-matrix style) or device-space source geometry.
    Rejected in favor of draw-time user-space mapping (section 4): the
    gradient then transforms with the geometry it paints, which is what
    a resolver setting transform, then source, then drawing expects, and
    it costs one matrix inverse per painted primitive.

## 4. Wire format

All scalars are little-endian f32 (`putF32LE`) or u32 (`putU32LE`).
Commands are padded to 8 bytes by the existing framing; payload fields
are read sequentially and need no internal alignment, as with
`FILL_PATH`.

A gradient stop is 20 bytes: `offset` (f32), then `r`, `g`, `b`, `a`
(4 x f32). Stops are shared by both gradient ops.

`SET_SOURCE_NONE` (0x0008). Payload 0 bytes.

`SET_SOURCE_LINEAR_GRADIENT` (0x0009). Variable payload:

      offset  field
      0       x0            f32   axis start, user space
      4       y0            f32
      8       x1            f32   axis end, user space
      12      y1            f32
      16      extend        u32   0 pad, 1 repeat, 2 reflect
      20      stop_count    u32
      24      stops         stop_count x 20 bytes

  Fixed header 24 bytes, then `stop_count` stops. Total payload is
  24 + stop_count * 20.

`SET_SOURCE_RADIAL_GRADIENT` (0x000A). Variable payload:

      offset  field
      0       cx            f32   center, user space
      4       cy            f32
      8       radius        f32   user space, > 0
      12      extend        u32
      16      stop_count    u32
      20      stops         stop_count x 20 bytes

  Fixed header 20 bytes, then `stop_count` stops. Total payload is
  20 + stop_count * 20.

A future focal-point (two-circle) radial gradient is an additive
extension, not a break: it takes its own opcode (or an extended payload
selected by an explicit flag) and leaves this concentric layout intact.
The concentric layout is therefore forward-compatible with a later focal
variant, and emitters and backends written against it keep working.

Stop and geometry constraints (validation, section 6):

  - `stop_count` in [2, 256].
  - Every f32 finite.
  - Stop offsets in [0, 1] and nondecreasing. Equal adjacent offsets are
    allowed and express a hard color transition.
  - Linear axis nondegenerate: (x1 - x0)^2 + (y1 - y0)^2 > 0.
  - Radial radius finite and > 0.
  - `extend` in {0, 1, 2}.

## 5. Rasterization (reference oracle)

Normative, coordinate space. Gradient geometry SHALL be specified in
user-space coordinates and evaluated through the inverse of the current
transform at draw time. Backends and the reference renderer SHALL NOT
interpret gradient geometry in device space, nor snapshot the transform
at the time the source op is processed.

A gradient source is evaluated once per pixel, at the pixel center in
device space, and the resulting straight RGBA is quantized and blended
with that pixel's coverage. Coverage is computed exactly as for a solid
fill: analytic for `FILL_RECT`, the 16-sample lattice for `FILL_PATH`
(ADR 0015 section 5). The source never participates in coverage.

For a covered pixel whose center in device space is `Pd`:

  1. Map to user space. `Pu = Minv * Pd`, where `Minv` is the inverse of
     the current 2D transform (the CTM active at draw time). The inverse
     is computed once per painted primitive. With the identity transform
     `Pu = Pd`.
  2. Compute the raw parameter `s`.
       - Linear: let `d = (x1 - x0, y1 - y0)`. Then
         `s = dot(Pu - p0, d) / dot(d, d)`.
       - Radial: `s = length(Pu - center) / radius`.
  3. Apply the extend mode to get `t`.
       - pad:     `t = clamp(s, 0, 1)`.
       - repeat:  `t = s - floor(s)`.
       - reflect: `f = s - 2 * floor(s / 2); t = if f <= 1 then f
                  else 2 - f`.

     Under repeat, an `s` at an exact integer maps to `t = 0`: the ramp
     restarts at the start color at each integer boundary.
  4. Resolve color from stops at `t`. If `t` is at or below the first
     stop offset, the color is the first stop. If at or above the last,
     the last. Otherwise find adjacent stops with offsets `o0 <= t <= o1`
     and `o0 < o1`, let `u = (t - o0) / (o1 - o0)`, and interpolate each
     channel linearly: `C = C0 + u * (C1 - C0)`, in straight
     (non-premultiplied) RGBA.

The color `C` is quantized with the existing `clampU8` and blended via
`fbBlendPixelAA` with the pixel coverage, the same call a solid fill
makes. Mapping device to user space and the gradient arithmetic use the
same all-f32, non-fused operations as the existing transform path, so
golden images are stable across machines (section 5 of ADR 0015 governs
determinism; this stage adds no new nondeterminism source beyond the
affine inverse, which is f32-deterministic).

## 6. Validation

Normative, stop order. Gradient stop offsets SHALL lie in the closed
domain [0, 1] and SHALL be monotonic nondecreasing. A backend SHALL
reject a stream that violates this rather than normalizing, clamping, or
reordering stops, because differing stop-normalization behavior is a
classic source of replay incompatibility. The validator enforces it
structurally below, and the reference renderer assumes it.

`SET_SOURCE_NONE`: payload length 0, else `PayloadSize`.

Gradient ops, in the variable-payload group alongside `FILL_PATH`:

  - payload at least the fixed header, then `stop_count` read.
  - `stop_count` in [2, 256], else reject.
  - payload length exactly header + stop_count * 20, else `PayloadSize`.
  - every f32 finite (`isFiniteF32Bits`).
  - offsets in [0, 1] and nondecreasing.
  - `extend` in {0, 1, 2}.
  - linear: axis nondegenerate. radial: radius > 0.

The daemon cost estimator (`sdcs_validator.zig`) treats the source ops
as state changes, the same small fixed cost as the other `SET_*` ops.

## 7. Encoder API

      pub const ExtendMode = enum(u32) { pad = 0, repeat = 1, reflect = 2 };

      pub const GradientStop = struct {
          offset: f32,
          r: f32, g: f32, b: f32, a: f32,
      };

      pub fn setSourceNone(self: *Encoder) !void;

      pub fn setSourceLinearGradient(
          self: *Encoder,
          x0: f32, y0: f32, x1: f32, y1: f32,
          stops: []const GradientStop,
          extend: ExtendMode,
      ) !void;

      pub fn setSourceRadialGradient(
          self: *Encoder,
          cx: f32, cy: f32, radius: f32,
          stops: []const GradientStop,
          extend: ExtendMode,
      ) !void;

The two gradient encoders reject, with `error.InvalidArgument`, a
`stops.len` outside [2, 256], any non-finite input, offsets outside
[0, 1] or out of order, a degenerate linear axis, and a radius not
greater than 0. They mirror `fillPath`: compute payload length, allocate,
write the fixed header then the stop array, and append.

## 8. Golden tests

Closure gate for this stage, in `tests/run.sh` and a `sdcs_make_gradient`
generator following the `sdcs_make_fill` pattern:

  - Linear two-stop gradient fill (`FILL_RECT`) under the identity
    transform, golden hash.
  - Linear multi-stop gradient (three or four stops), golden hash.
  - Linear gradient under a non-uniform scale combined with a rotation
    (`SET_TRANSFORM_2D`), golden hash. Transform handling is where replay
    engines most often diverge, so this is a required case, not optional;
    it is the primary check on the section 5 coordinate-space rule.
  - Radial two-stop gradient fill (`FILL_PATH`), golden hash.
  - Extend modes: a linear gradient whose axis covers part of the
    surface, rendered pad, repeat, and reflect. Golden hashes, and an
    invariant that repeat differs from pad over the region beyond the
    axis.
  - Reset: a gradient fill, then `SET_SOURCE_NONE`, then a solid fill;
    the solid region renders as the inline color.
  - Equivalence, linear (invariant B1-3): a linear gradient with two
    identical stops, filling a shape, renders byte-identical to the solid
    fill of that color (`cmp`).
  - Equivalence, radial (invariant B1-3): a radial gradient whose inner
    and outer stop colors are identical renders byte-identical to the
    solid fill of that color (`cmp`). This exercises the radial sampler
    against the solid path independently of the linear one.
  - Determinism: a gradient scene rendered twice is identical.

## 9. Non-goals

  - No pattern or surface source. That is Stage B2, ADR 0017, reusing
    this register.
  - No focal point or two-circle radial gradient. Radial is concentric
    (center and radius) in this stage; a focal extension is a later
    additive opcode or payload, not a break.
  - No source application to strokes, glyph runs, or blit. Fills only.
  - No color management or gamma handling. Stops interpolate in the
    format's existing straight-RGBA space; ADR 0004's boundary holds and
    color science does not enter SDCS here.
  - No nonlinear stop interpolation. Linear between stops only.

## 10. Consequences

  - SDCS expresses position-varying paint natively. METOC colormaps
    become linear gradients with transform and determinism intact rather
    than precomputed blits, and NDE chrome gains gradient fills.
  - The render context grows a current-source register and the fill
    paths grow a per-pixel color resolution. The coverage and blend
    paths are unchanged, which the equals-solid invariant enforces.
  - The source model is established once. Pattern sources (ADR 0017) and
    any later source add a union arm and a sampler; they do not revisit
    the register, the application points, or the affects-color-only rule.
    Future source ADRs reference invariants B1-2 and B1-3 rather than
    restate them in source-specific language; those properties are
    foundational to the source model, not specific to gradients.

## 11. Risks

  - Determinism of the affine inverse and gradient math. Mitigation: the
    same all-f32, non-fused discipline as the existing transform path,
    goldens as the gate, and the equals-solid invariant as a cross-check.
  - Temptation to couple coverage and color. Mitigation: the
    affects-color-only rule is normative and the equals-solid invariant
    fails if coverage is taken from the source.
  - Stop-table size. Mitigation: the 256-stop cap and the exact
    payload-length check (header + count * 20) bound the allocation.

## Revision history

  - 2026-06-13: drafted (Proposed).
  - 2026-06-13: accepted with operator review revisions. Elevated the
    compatibility, paint-affects-color-only, and gradient/solid
    equivalence rules to normative invariants B1-1, B1-2, B1-3. Added the
    normative coordinate-space statement (user-space geometry, inverse
    CTM at draw time) to section 5 and the normative stop-order rule
    (offsets in [0, 1], monotonic nondecreasing, reject rather than
    normalize) to section 6. Noted concentric-radial forward
    compatibility with a future focal-point variant. Added the required
    golden cases: linear under identity, linear under non-uniform scale
    plus rotation, and radial inner-equals-outer equivalence. Radial
    header left at 20 bytes (no alignment requirement emerged).
  - 2026-06-13: ratified. Folded operator documentation observations:
    recommended (non-normative) first-stop convention for a
    gradient-painted fill's inline RGBA field; clarified that repeat maps
    integer parameters to 0; recorded that future source ADRs reference
    B1-2 and B1-3 rather than restate them. No architectural change.
