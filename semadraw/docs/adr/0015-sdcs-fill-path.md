# ADR 0015: SDCS Stage A, FILL_PATH with winding rules

## Status

Accepted 2026-06-13 (operator), with review revisions incorporated
(see Revision history). Implements Stage A of ADR 0014 (SDCS fill,
paint sources, and path clipping completion): a filled path of one
or more closed contours under a winding rule, the keystone that
unblocks NDE C3 chrome and PGSD filled visualization. Implementation
follows in a separate commit after ratification. The software
reference rasterizer (`sdcs_replay.zig`) and golden tests are the
closure gate (ADR 0002).

## 1. Context

SDCS today can stroke a path but not fill one. The only fill is
`FILL_RECT` (axis-aligned). The point input format already exists:
`STROKE_PATH` carries a flat point list, and `encoder.zig`,
`simd.zig`, and the reference rasterizer `sdcs_replay.zig` already
implement coverage-based antialiasing with a 4x4 sub-pixel sample
lattice for oriented stroke spans. What is missing is a fill
rasterizer: the machinery to take closed contours and fill their
interior under a winding rule, with antialiasing consistent with
the strokes.

This is in scope per ADR 0004 ("path operations including fills with
winding rules") and per ADR 0014 section 4 (Stage A).

## 2. Scope

Stage A fills a path of one or more closed contours under a
selectable winding rule. Each contour is a flat point list of the
same f32 (x, y) form `STROKE_PATH` uses.

Multiple contours are in Stage A deliberately, not deferred. Holes
are not an edge case: rings, cutouts, glyph-like counters, nested
METOC contour bands, and many UI shapes require them. The winding
rule is only fully meaningful across multiple contours; with a
single non-self-intersecting contour, nonzero and even-odd agree.
Shipping a single-contour payload would force Stage B or a later
stage to add a second fill opcode or break the format. A
multi-contour payload is forward compatible (a single contour is
the contour_count == 1 case) and leaves the rasterization algorithm
essentially unchanged: it accumulates edge crossings over more
edges, with identical interior and boundary handling.

Deferred, not in Stage A: curve verbs inside the fill path. Callers
flatten Bezier curves to points before filling, exactly as
`strokePath` already requires for stroked curves.

## 3. Wire format

New opcode in the draw block, immediately after `STROKE_PATH`
(0x0018):

    FILL_PATH = 0x0019   // payload = variable

Payload (little-endian):

    offset            type     field
    0                 f32      r
    4                 f32      g
    8                 f32      b
    12                f32      a
    16                u32      fill_rule      (0 = nonzero, 1 = even-odd)
    20                u32      contour_count  (>= 1)
    24                u32[]    contour_lengths  (contour_count entries,
                                                 each >= 3, points per contour)
    24 + 4*cc         f32[]    points         (sum(contour_lengths) pairs,
                                               x, y per point)

where cc = contour_count. Total payload length MUST equal
`24 + 4*contour_count + 8*sum(contour_lengths)`. All multi-byte
fields are little-endian; field reads are 4-byte wide, so no
interior padding is required, and the command record is padded to
8-byte alignment by the existing `pad8` rule. Colors are f32 RGBA
in 0..1 and coordinates are f32 user-space, transformed, clipped,
and blended on the same terms as `STROKE_PATH` and the other
primitives (`SET_TRANSFORM_2D`, `SET_CLIP_RECTS`, `SET_BLEND`).

Contour closure is explicit and normative. Each contour is
implicitly closed: an edge connecting its final point to its first
point is part of the contour for both winding evaluation and edge
rasterization. A caller MUST NOT repeat the first point as the last
point to close a contour; closure is supplied by the renderer.

The winding rule is carried per fill in the payload rather than as
a `SET_FILL_RULE` state opcode. Rationale: a self-describing fill
preserves capture and replay determinism, avoids hidden renderer
state, simplifies validation, and keeps streams easy to inspect and
diff. The state-op alternative is recorded and rejected for Stage A;
it would return only if a future need for sticky fill state appears.

`fill_rule` values 2 and above are reserved and MUST be rejected.

## 4. Rasterization (reference oracle)

In `sdcs_replay.zig`, `FILL_PATH` decodes the contours and fills
their combined interior under the winding rule:

  - Gather the edge set from all contours, each contour closed per
    section 3 (final point to first point).
  - Compute the union bounding box of all contours, intersected
    with the active clip rectangles.
  - For each scanline row in that box, determine inside spans by
    applying the winding rule across all edge crossings on the row.
    Fully-interior runs are filled with `simd.fillSpan` (the
    existing fast interior path).
  - Boundary pixels are antialiased by sub-sampling (section 5),
    each sub-sample classified inside or outside by the winding rule
    over the full edge set: signed crossing count for nonzero,
    crossing parity for even-odd.

Holes follow from this without special handling: an inner contour
wound opposite the outer contour produces a cutout under nonzero,
and nested non-overlapping contours produce a cutout under even-odd
regardless of winding direction. The algorithm is the single-contour
algorithm with the edge set drawn from every contour.

Reference realization. The committed reference renderer takes the
simplest correct form of the above: it sub-samples every pixel in
the bounding box uniformly with the section 5 lattice rather than
separating an interior `simd.fillSpan` run from boundary sampling. A
fully-interior pixel then has all sixteen samples inside and resolves
to full coverage, so the output is identical to the span-fill form.
This keeps a single code path and removes the interior-to-boundary
seam noted in section 11. The `simd.fillSpan` interior fast path
remains available as a later performance optimization and MUST
preserve these outputs (the golden fixtures gate that).

## 5. Antialiasing and determinism (normative)

These requirements are normative and are a closure gate, not
implementation latitude:

  - Boundary coverage MUST be computed on the same 4x4 sub-pixel
    sample lattice (16 samples per pixel) already used by stroke
    rasterization. An implementation MUST NOT substitute analytic
    coverage, a different sample count, or any "higher quality"
    scheme, because that would diverge from the stroke path and
    from other backends.
  - Coverage MUST be represented as an integer sample count in the
    range [0, 16] and converted to the blend input through the same
    `fbBlendPixelAA` entry point the strokes use. A filled contour
    and a coincident stroked outline therefore antialias
    identically.
  - Winding classification MUST use the same f32 edge inputs as
    stroking, with no separate float accumulation path. Identical
    input produces identical coverage and identical pixels across
    machines, preserving the ADR 0002 determinism property.

## 6. Validation

`FILL_PATH` joins the variable-payload opcode list in the `sdcs.zig`
validator (bounds and 8-byte alignment only, as `STROKE_PATH` does
today). Schema depth follows the existing convention: the encoder
and the rasterizer enforce the invariants (contour_count >= 1, each
contour length >= 3, and payload length exactly
`24 + 4*contour_count + 8*sum(contour_lengths)`); a malformed payload
is a deterministic decode error in the rasterizer, consistent with
how the other variable opcodes are handled. Widening the validator
to deep-validate variable opcodes is a separate concern and is not
introduced here.

## 7. Encoder API

`encoder.zig` gains `fillPath`, taking one or more contours:

    pub fn fillPath(
        self: *Encoder,
        contours: []const []const Point,
        fill_rule: FillRule,    // .nonzero | .even_odd
        r: f32, g: f32, b: f32, a: f32,
    ) !void

A single-contour fill is `&.{points}`. The encoder rejects an empty
contour list, any contour with fewer than 3 points, and a total
point count over the existing 65535 bound, then emits `FILL_PATH`
with the section 3 payload.

## 8. Golden tests

Stage A does not close until golden images cover:

  - a convex polygon fill;
  - a concave polygon fill;
  - a self-intersecting single contour rendered under both nonzero
    and even-odd, asserting the two outputs differ;
  - a two-contour ring (outer and inner square as one `FILL_PATH`),
    asserting the inner region is empty under nonzero with opposite
    inner winding and under even-odd regardless of winding;
  - the equivalence invariant from ADR 0014: a full-surface
    rectangle expressed as a four-point single-contour `FILL_PATH`
    matches `FILL_RECT` over the same region;
  - AA consistency: a filled contour and a coincident thin stroke
    agree on edge coverage;
  - vertex-on-sample: a polygon positioned so that edges and
    vertices pass exactly through 4x4 sub-sample lattice points,
    asserting that adjacent edges meeting at a sample-aligned vertex
    neither double-count nor cancel coverage, and that each
    sub-sample receives one consistent inside or outside
    classification.

A fixture generator in the style of `sdcs_make_aa.zig` produces the
streams; the CI golden gate gives the pass or fail.

## 9. Non-goals

  - Curve verbs inside the fill path; callers flatten to points.
  - Gradient or pattern paint sources (Stage B).
  - Arbitrary path clipping (Stage C).
  - GPU-backend fill; the reference rasterizer defines semantics and
    other backends match within ADR 0002 tolerances.

## 10. Consequences

  - SDCS can fill arbitrary closed shapes including holes, the
    keystone capability for NDE chrome and PGSD visualization.
  - The reference rasterizer gains its first general fill, the
    largest addition since the stroked path, but it reuses the
    existing coverage and blend machinery rather than introducing a
    parallel one.
  - The multi-contour payload and the per-fill winding rule
    establish the format and rasterization pattern that Stage B
    paints and Stage C clips build on, with no anticipated format
    break for holes.

## 11. Risks

  - Vertex and edge inclusion at sample points. Adjacent edges
    meeting at a sub-sample location are the classic double-count or
    cancellation bug. Mitigation: the vertex-on-sample golden test
    targets exactly this, alongside the AA consistency and
    full-surface equivalence tests.
  - Self-intersection and hole correctness. Nonzero versus even-odd
    is easy to get wrong across contours. Mitigation: the
    differing-output self-intersection test and the two-contour ring
    test.
  - Performance on large fills. The scanline path is O(area), which
    is acceptable for the reference renderer, whose job is
    correctness, not speed. Backend acceleration is out of scope.

## Revision history

  - 2026-06-13, in review before ratification: adopted a
    multi-contour payload (contour table plus point array) in place
    of the single-contour draft, so holes are supported in Stage A
    and no Stage B format break is required; made contour closure
    explicit and normative; raised the 4x4 sample lattice and the
    integer [0, 16] coverage representation to normative MUST
    requirements; added the two-contour ring and vertex-on-sample
    golden tests. The per-fill `fill_rule` decision and the rejected
    `SET_FILL_RULE` alternative are unchanged from the draft.
