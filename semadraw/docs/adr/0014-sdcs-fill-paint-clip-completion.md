# ADR 0014: SDCS fill, paint sources, and path clipping completion

## Status

Proposed 2026-06-13. Plans the completion of three in-scope SDCS
capabilities that ADR 0004 lists as belonging to SDCS but that the
v0.1 opcode set does not yet implement. This is a program ADR: it
documents the gaps and stages the work. Each stage lands under its
own implementation ADR (ADR-before-code per stage), with the
software reference renderer and golden tests as the closure gate.
This ADR adds no opcodes and no code; it frames the program and
proposes the staging.

## 1. Context

SDCS is the canonical 2D compositing language of the Awase stack
(ADR 0001). ADR 0004 fixed its scope as 2D compositing intent only
and, under "What stays in SDCS", enumerated capabilities that
belong to SDCS:

  - gradient fills, pattern fills, alpha compositing variants;
  - path operations including Bezier curves, fills with winding
    rules, and stroke styling.

The v0.1 opcode set (`sdcs.zig`) covers transforms, rectangle
clipping, blend modes, antialiasing, stroke styling, stroke
primitives (rect, line, quadratic and cubic Bezier, polyline path),
image blit, and glyph runs. The write API (`encoder.zig`) and the
reference rasterizer (`sdcs_replay.zig`, the golden oracle per ADR
0002) implement all of these with coverage-based antialiasing,
including 4x4 sub-pixel sampling for oriented stroke spans and
analytic coverage for axis-aligned rectangles. They implement no
general fill: the only fill is `FILL_RECT` (axis-aligned),
`encoder.zig` has no `fillPath`, and `simd.zig` provides span fill
and rectangle and convex coverage but no concave or winding-rule
rasterizer. There is no filled path, no winding rule, no gradient or
pattern paint source, and no arbitrary path clip. Paths can be
stroked but not filled. (The compositor's `backend/software.zig` is
a surface-blit stub, not the reference rasterizer.)

These are therefore in-scope-but-unbuilt capabilities, not
exclusions. ADR 0004's hard boundary (no 3D, compute, video, or
shaders; those route to Vulkan and bridge back via a BLIT) is
unchanged and is not reopened here.

## 2. Why now

Two consumers are blocked in practice by the absence of a general
fill:

  - PGSD application surface. Scientific and METOC visualization
    (filled contours, shaded regions, area plots, filled polygons)
    cannot be expressed on a stroke-plus-`FILL_RECT` vocabulary.
    The only workaround today is to precompute a raster and
    `BLIT_IMAGE` it, which forfeits SDCS's transform, clip, and
    determinism guarantees for the filled content.
  - NDE presentation. NDE C3 (presentation resolution,
    `NDE-SEMANTIC-DESIGN.md`) resolves the semantic tree to SDCS.
    Control chrome (filled controls, rounded-rect backgrounds,
    focus fills, non-rectangular masks) requires path fill. The
    resolver cannot produce acceptable chrome until fill exists,
    which makes the fill engine a forward dependency of the M2 and
    M3 semantic milestones.

Gradients, patterns, and arbitrary path clipping are also in scope
and absent, but are lower urgency: a colormap ramp can be blitted,
and rectangle-list clipping covers most current UI.

## 3. The keystone: a deterministic 2D fill engine

The substantive piece is a fill rasterizer, not an opcode. The path
representation already flows for `STROKE_PATH`, so the input side
exists; the fill engine is net-new. Requirements:

  - Winding rule. Support nonzero and even-odd; the default and the
    per-fill selector are decided at the Stage A implementation ADR.
  - Coverage and antialiasing. Edge coverage MUST match the
    existing deterministic 4x4 supersampling model (`SET_ANTIALIAS`)
    so that a filled shape and its stroked outline antialias
    consistently and so that golden images stay stable across
    machines. No floating-point nondeterminism in the coverage path.
  - Reference-defined semantics. The software reference renderer is
    the oracle (ADR 0002). Stage A does not close until golden
    tests cover convex and concave fills, self-intersecting paths
    under both winding rules, and equivalence between a
    full-surface fill and `FILL_RECT`.

## 4. Staging

Each stage is gated, ADR-before-code, and closed against the
reference renderer with golden tests. Stages are ordered by the
dependencies in section 2.

  - Stage A: path fill. Add `FILL_PATH` (a filled path of one or
    more closed contours under a winding rule), reusing the
    `STROKE_PATH` point encoding generalized to multiple contours so
    holes are supported without a later format break. Unblocks METOC
    fills and NDE chrome. Highest priority. Specified in ADR 0015.
  - Stage B: paint sources. Add linear and radial gradient sources
    and pattern (surface) sources. This introduces a paint-source
    state model: today every primitive carries solid RGBA inline,
    and a source model is a design decision (current-source state
    versus per-primitive source) that the Stage B implementation
    ADR settles. Depends on Stage A for filled regions to paint.
  - Stage C: path clipping. Extend clipping from rectangle lists to
    an arbitrary path clip (`SET_CLIP_PATH`) reusing the Stage A
    winding machinery. Lowest urgency.

## 5. Proposed opcode additions (tentative)

Final byte layouts and assignments are fixed at each stage's
implementation ADR, in the manner of ADR 0012 section 10. Tentative
placement within the existing blocks:

  - Draw block (after `STROKE_PATH` 0x0018): `FILL_PATH` at 0x0019.
  - State block (after `SET_ANTIALIAS` 0x0007): paint-source
    opcodes for Stage B (for example `SET_SOURCE_SOLID`,
    `SET_SOURCE_LINEAR_GRADIENT`, `SET_SOURCE_RADIAL_GRADIENT`,
    `SET_SOURCE_PATTERN`) from 0x0008 onward, and `SET_CLIP_PATH`
    for Stage C alongside `SET_CLIP_RECTS`.

The SDCS minor version increments at each stage that adds opcodes;
the magic and chunk framing are unchanged. Unknown-opcode handling
follows the existing validator so that an older backend rejects a
newer stream rather than misrendering it.

## 6. Non-goals

  - No widening of ADR 0004. No 3D, compute, video, or shader
    operations enter SDCS through this program.
  - No change to the glyph-run path. Text coverage already has its
    own path and is not reworked here.
  - No GPU-backend work beyond matching reference behavior within
    the tolerances ADR 0002 already defines.

## 7. Consequences

  - SDCS reaches parity with its own chartered 2D scope, in the
    order its consumers need.
  - The NDE C3 resolver and PGSD visualization gain filled vector
    output with transform, clip, and determinism intact.
  - The reference renderer grows a real fill rasterizer, the
    largest single addition to it since the stroke path.

## 8. Risks

  - Determinism of coverage. A fill rasterizer is where
    floating-point nondeterminism most easily enters. Mitigation:
    integer or fixed-point coverage matched to the 4x4 model, with
    golden tests as the gate; this is a Stage A closure
    requirement, not left to implementation discretion.
  - Paint-source model churn. Introducing sources touches every
    primitive's color handling. Mitigation: Stage B decides the
    model once, in its ADR, before any code; Stage A leaves inline
    RGBA untouched.
  - Scope creep toward effects. Gradients and patterns invite
    requests for blurs, filters, and shader-like effects.
    Mitigation: ADR 0004's boundary holds; effects route to Vulkan
    and bridge via a BLIT.
