# chronofs multi-series temporal addressing: implementation plan

Status: SCHEDULED 2026-06-10. The design series (ADRs 0002 through 0005, all
Accepted 2026-06-10, under BACKLOG identifier CHN0002BACKLOG) is complete and
is treated as normative. This plan stages the client-library implementation
of that design. It is a roadmap, not an ADR; it introduces no new design
decisions, and where a question of behavior arises the accepted ADRs govern.

## Scope

In scope, the initial target: the core timeline primitives and their types.

  - the instant type and its representation (ADR 0004);
  - `TimeIndex`: a single ordered-instant index with insertion, supersession,
    retention, and resolution (ADRs 0002, 0003, 0005);
  - `TimelineMap` and `TimelineView`: the affine map from the coordination
    clock to the data-time cursor (ADR 0004 and the planning document).

Out of scope here:

  - cross-process cursor sharing, deferred until a real cross-process
    linked-view use case exists (operator decision 2026-06-10);
  - the group-resolve convenience over several series for ensembles, a later
    addition over single-index resolution, not part of the initial target;
  - any METOC visualization client or proof-of-concept, a separate effort
    that consumes this library.

## Module layout

chronofs/src is flat, one concept per file, each wired as a named module in
`build.zig` with an inline-test target. This plan follows that convention and
adds three files:

  - `chronofs/src/instant.zig`: the `Instant` type (`i64` nanoseconds), the
    epoch and range constants, the in-range check, and two's-complement
    little-endian serialize and deserialize (ADR 0004).
  - `chronofs/src/timeindex.zig`: the `SeriesHandle`, `Resample`, `Retention`,
    `MissReason`, and `Sample` types, and `TimeIndex` itself (ADRs 0002, 0003,
    0005).
  - `chronofs/src/timeline.zig`: `TimelineMap` and `TimelineView` (ADR 0004
    and the planning document), importing `instant` and the existing `clock`.

`build.zig` gains a module and an `addTest` target per new file, each added to
the existing `test` step alongside the clock, stream, and resolver tests.

## Verification

Unlike the kernel and audio work, this library is pure logic: no kernel, no
device, no hardware. `TimelineMap` takes a `Clock`, and the existing
`MockClock` in `clock.zig` drives it in tests. The whole library is therefore
exercised by `zig build test` on any Zig 0.15.2 host and needs no bench
hardware; pgsd-bare-metal is not on the critical path for this work. The
authoring container cannot compile Zig, so the operator runs the test step;
the tests are written to be the verification, not a bench session.

## Stages

Each stage is a buildable, test-green increment, committed on its own.

### Stage 1: instant and index core (ADRs 0004, 0003)

`instant.zig`, and the types and structure of `timeindex.zig`: sorted,
out-of-order-tolerant, non-evicting insertion with bisection; the per-index
supersession policy (last_insertion and sequenced); and retention (static and
windowed, with the horizon and below-horizon insert rejection). No resolution
yet beyond the predecessor and successor primitives that bisection provides.

Tests: ordering (sorted insert keeps ascending order; an out-of-order arrival
lands in position); supersession (last_insertion replaces; sequenced keeps the
strictly-greater sequence, drops equal or lesser, is idempotent on
re-delivery); retention (static keeps all and scrubs both ways; windowed drops
below the horizon and rejects a below-horizon insert); instant serialization
round-trips.

### Stage 2: resolution (ADR 0005)

`TimeIndex.resolve(cursor, policy)` returning a `Sample` for all four
policies, with the four-reason miss taxonomy, signed staleness, the
below-horizon precedence rule, and the empty-index case.

Tests, one group per policy plus the cross-cutting rules:

  - hold_last: returns the predecessor; holds past the last sample with
    growing non-negative staleness (never after_end); the low-end miss is
    before_start, or below_horizon when the cursor precedes the horizon.
  - nearest: returns the closer sample; a tie goes to the earlier instant;
    staleness is signed; clamps at both ends; below_horizon when the cursor
    precedes the horizon.
  - linear: returns the bracketing handles and a fraction in [0, 1]; an exact
    hit returns a value with zero staleness; does not extrapolate, so
    before_start or after_end past the ends; chronofs returns handles only and
    never blends.
  - none: a value only on an exact hit; an interior cursor with no exact
    sample returns no_sample; the boundary cases keep their reasons.
  - cross-cutting: below_horizon is reported before any clamp or hold; an
    empty index returns before_start; the full four-reason taxonomy is
    exercised.

### Stage 3: timeline map and view (ADR 0004, planning document)

`TimelineMap` (origin, play-start, rational rate, paused; `cursor(clock)`
computed through a u128 intermediate for exactness) and `TimelineView` (binds
a `Clock` and a map; `cursorNow()`).

Tests: paused returns the origin; playing advances the cursor by the rational
rate against a MockClock; the map is exact (no drift across a long advance);
two views over the same clock and map yield identical cursors (the no-skew
property); scrub sets the origin.

## ADR traceability

  - ADR 0002 (ontology): one bound axis per index, opaque `SeriesHandle` never
    decoded, no cross-axis logic. Enforced structurally across Stages 1 and 2.
  - ADR 0003 (index structure): Stage 1 (insertion, supersession, retention)
    and the miss taxonomy realized in Stage 2.
  - ADR 0004 (representation): Stage 1 `instant.zig` (unit, epoch, range,
    serialization) and Stage 3 (the data-time cursor the map produces).
  - ADR 0005 (resolution): Stage 2 in full, including the no_sample reason.

## Sequencing and commits

Stages land in order; each is a self-contained commit with green tests. The
operator pushes; commit messages are supplied per stage. This plan introduces
no operator marks; CHN0002BACKLOG tracks the implementation phase.
