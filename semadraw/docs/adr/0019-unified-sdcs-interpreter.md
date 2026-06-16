# 0019 Unified SDCS interpreter and rasterizer interface

Status: Accepted 2026-06-17 (operator). Accepted as drafted. The one open
question (a declared-unsupported primitive: log-and-continue versus typed error)
is carried to Stage 4, where it first binds, with the Notes recommendation as the
default: equality-required for the software backend, which is the oracle, and
log-and-continue for the partial GPU backends.

## Context

ADR 0002 decided two things: maintain a software reference renderer, and enforce
golden image tests in CI as the semantic oracle, with the stated consequence that
"GPU backends must match reference behavior within defined tolerances." This ADR
records that the second half of 0002 was never built, that the backends have
drifted from the reference as a direct result, and that the SDCS command stream is
now interpreted by six independent implementations with no shared decode, no shared
semantics, and no compile-time tie to the canonical opcode table.

The drift is not hypothetical. It was found while surveying refactor candidates
after the 0.16 migration and is measured below.

### Six interpreters, none sharing a decoder

The live render path is `compositor.composite` -> `backend.render` -> `executeSdcs`.
`executeSdcs` is implemented separately in every backend (software, vulkan,
vulkan_console, x11, drawfs), and `sdcs_replay` is a sixth implementation. Each
one re-derives the SDCS framing by hand (skip the 64 byte header, walk 32 byte
chunk headers, walk 8 byte command records, 8 byte alignment) and dispatches on
the opcode.

None of the six references the canonical `sdcs.Op` constants in `sdcs.zig`. Every
one hardcodes the opcode values as magic numbers (`0x0010` for FILL_RECT, `0x00F0`
for END, and so on). Measured: `sdcs.Op` references in software.zig, vulkan.zig,
x11.zig, drawfs.zig are all zero. The opcode table that `encoder.zig` writes
against has no compile-time relationship to the code that reads it. Adding or
renumbering an opcode in `sdcs.zig` compiles clean while silently doing nothing in
six places.

### Coverage divergence (measured)

The same command stream renders differently per interpreter, because each handles
a different subset and every backend ends its dispatch in `else => {}` ("Ignore
unknown opcodes for now"), so unhandled opcodes are dropped with no error:

    interpreter                      opcodes rendered
    software                         FILL_RECT
    vulkan / vulkan_console / x11    FILL_RECT, DRAW_GLYPH_RUN
    drawfs                           RESET, SET_BLEND, SET_ANTIALIAS,
                                     SET_STROKE_JOIN/CAP, SET_MITER_LIMIT,
                                     FILL_RECT, STROKE_RECT, STROKE_LINE,
                                     DRAW_GLYPH_RUN
    sdcs_replay (the 0002 reference) the full set, ~25 ops, including clip rects
                                     and paths, transforms, gradients, patterns,
                                     fill/stroke paths, quad/cubic beziers

The reference renderer renders a strict superset of every live backend. By the
0002 design it is the semantic oracle, yet no live target reproduces it, so it
cannot validate any live output: it passes content the real compositor drops.

### Live blast radius (measured)

What the live path (client, apps, daemon; tools and tests excluded) actually
emits, by Encoder call site:

    FILL_RECT       16 sites      universal, renders everywhere
    STROKE_LINE     16 sites      only drawfs; dropped on software/vulkan/
                                  vulkan_console/x11
    SET_BLEND        7 sites      only drawfs; alpha/compositing mode ignored
                                  on the other four
    DRAW_GLYPH_RUN   3 sites      absent from software; text invisible there
    SET_ANTIALIAS    1 site       only drawfs; cosmetic elsewhere

The embedded cursor (`cursor_arrow.sdcs`, rendered every frame) is RESET +
SET_BLEND + FILL_RECT x30 + END, so it relies on SET_BLEND that only drawfs
honors.

Consequence today: on the drawfs target every opcode the live path emits is
handled, so production on drawfs is correct for the current command mix. On any
other backend the UI is silently degraded, strokes and (for software) text and
blending simply do not appear. The exotic opcodes from the 0014 to 0018 feature
series (SET_CLIP_RECTS, FILL_PATH, gradients, patterns, transforms) are emitted by
no live code yet, but they exist in the encoder and the reference renderer and in
zero backends (measured: SET_CLIP_RECTS and FILL_PATH have zero dispatch arms in
all four non-drawfs backends and in drawfs). The first client that uses them will
have them silently dropped on every display.

### The oracle is wired to itself

`tests/run.sh` renders the golden corpus by running `sdcs_replay` only, then
hash-compares the resulting PPMs against `tests/golden/*.sha256`. No backend is
ever rendered or compared. The golden tests pin the reference renderer to its own
prior output; they do not, and structurally cannot as wired, catch a backend
diverging from the reference. The 0002 enforcement mechanism does not exist.

### Why this happened

The feature ADRs 0014 (fill paint clip), 0015 (fill path), 0016 (gradients), 0017
(patterns), and 0018 (path clipping) each extended the SDCS format, the encoder,
and the reference renderer. None extended the backends, and nothing failed to
compile or to pass golden when they did not, because the backends decode by magic
number and drop the unknown by default, and the oracle never renders a backend.
Every layer that should have flagged the gap was structurally blind to it.

## Decision

1. One decoder. Add a single SDCS decoder to `sdcs.zig` (or a `sdcs_decode.zig`
   beside it) that walks header, chunks, and command records once, against the
   canonical `sdcs.Op` constants, and yields a typed `Command` tagged union. The
   validator, the dump and replay tools, and every backend consume this decoder.
   Opcode additions become a compile-time concern for every consumer through the
   union's exhaustiveness.

2. One rasterizer interface. The decoder drives a small primitive interface
   (vtable or comptime-dispatched): fillRect, strokeRect, strokeLine, strokePath,
   fillPath, blit, glyphRun, setClip, clearClip, setBlend, setTransform,
   resetTransform, and the antialias/join/cap/miter state setters. A backend
   implements only the primitives for its target. The decode-and-dispatch loop
   exists once, not six times.

3. Reference equals live software by construction. Promote the reference
   renderer's complete software rasterization (the cap/join/AA/path logic now in
   `sdcs_replay.zig`) to the canonical software primitive set, and have both
   `sdcs_replay` and the software backend use it. The reference is then literally
   the software backend driven through the shared interpreter, delivering 0002's
   intent rather than restating it.

4. No silent drops. Replace every `else => {}` with explicit per-backend coverage.
   A backend that cannot render a primitive declares it, and the shared
   interpreter handles a declared-unsupported primitive visibly (log, or a typed
   error per policy) rather than discarding it. Coverage gaps become a fact in the
   code, not a surprise on screen.

5. Wire the missing half of 0002. Extend the golden harness to render the corpus
   through the software backend (now identical to the reference) and assert
   equality, and through the GPU and drawfs backends within the tolerance 0002
   already contemplated. The oracle then checks what 0002 said it would.

## Consequences

1. One opcode table, one framing walk, one set of drawing semantics. Backend
   differences shrink to per-primitive blit and capability.

2. The 0014 to 0018 feature set becomes renderable on the live path. Today it is
   encoder-and-reference only.

3. Backend coverage is visible and intentional. A backend that does not implement
   strokes says so; it does not pretend by dropping them.

4. This is a real refactor across all five backends and the reference tool, with
   ABI-sensitive surfaces (the framing must continue to match the encoder exactly).
   It must be staged so every backend stays green at each step, per the migration
   discipline. It does not supersede 0002, 0004, or the 0014 to 0018 series; it
   delivers 0002's unenforced consequence and makes the 0014 to 0018 features
   reachable.

5. Risk: the staged port can change rendered output on backends that currently
   drop opcodes (a stroke that was invisible becomes visible). That is the bug
   being fixed, but it is a visible behavior change and golden baselines for the
   affected backends must be regenerated deliberately, not silently accepted.

## Staged migration (forward-only, green at each step)

1. Land the shared decoder and the `Command` union with unit tests and the
   existing golden corpus driving it, no backend consumer yet. Parallels the
   compat.posix "land the boundary before any consumer" pattern from shared 0003.

2. Define the rasterizer interface. Port the software backend to {shared decoder +
   reference primitives}. Assert it matches the golden corpus. Reference equals
   live software lands here.

3. Port drawfs to the shared decoder and interface, preserving its current
   primitive set. Its coverage is now declared rather than implicit.

4. Port the vulkan, vulkan_console, and x11 backends. Declare unsupported
   primitives explicitly. Wire each backend into the golden harness within
   tolerance.

5. Delete the per-backend duplicate framing and dispatch. A tree-wide check that
   no `executeSdcs`-style hand-rolled framing or hardcoded opcode magic remains.

## Notes

Per ADR-before-code, no shared interpreter lands before this ADR is ratified.

The decoder is also the natural home for the raw-posix fd I/O helpers currently
copy-pasted across the sdcs tools (the separate consolidation candidate), since
the tools that produce and replay SDCS files are the same ones that would import
the shared decode and io surface.

Open question for ratification: whether a declared-unsupported primitive should
log-and-continue or return a typed error. Log-and-continue preserves today's
"degraded but running" behavior with visibility added; a typed error surfaces the
gap at the call site but changes failure semantics for partial-capability
backends. The blast-radius data suggests log-and-continue for the GPU backends
(which are partial by nature) and equality-required for the software backend
(which is the oracle).
