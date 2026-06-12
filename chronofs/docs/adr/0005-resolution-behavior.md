# chronofs 0005: resolution behavior

## Status

Accepted, 2026-06-10: ratified by the operator as proposed, all seven
decisions, including the Decision 5 extension of ADR 0003's miss taxonomy
with the fourth reason no_sample (the three boundary reasons unchanged). This
ADR authorizes no code, so there is no implementation step. Closure criteria
1 and 2 are discharged; criterion 3 records that the temporal-addressing
design series (0002 through 0005) is now complete, with only the deferred
cross-process cursor-sharing decision and the scheduling of the client-library
implementation remaining before code.

Proposed, 2026-06-10. The fourth ADR of the chronofs multi-series
temporal-addressing series, opened under BACKLOG identifier CHN0002BACKLOG.
It builds on ADR 0002 (ontology), ADR 0003 (index structure), and ADR 0004
(instant representation), all Accepted 2026-06-10, and defines how a cursor
resolves against an index. This ADR authorizes no code.

## Context

ADR 0003 fixed the index structure and named the resampling policies
(hold_last, nearest, linear, none), the result shape (a value with a handle
and a signed staleness, or a pair of bracketing handles with a fraction, or a
miss), and a three-member miss taxonomy (before_start, after_end,
below_horizon), but deferred the actual mapping: given a cursor instant, what
does each policy return. ADR 0004 fixed the cursor as an i64-nanosecond
instant on the bound axis. This ADR closes that gap.

It is the resolution layer, and so the place where the temporal vocabulary
either stays meaningful or decays into a lookup table. Each policy below is
defined as a meaning (what the series asserts is current at the cursor), with
staleness and the miss reason carried honestly so a consumer can always tell
how far the answer is from the cursor and why an answer is absent.

## Decisions

### 1. Common terms

For a cursor instant `t` against an index holding instants in ascending
order, define by bisection (0003): the predecessor, the greatest indexed
instant `<= t`, and the successor, the least indexed instant `>= t`. On an
exact hit the predecessor and successor are the same point.

`staleness_ns` is `t - resolved.instant`, signed: positive when the resolved
sample is in the cursor's past (a hold), negative when it is in the cursor's
future (possible under nearest), zero on an exact hit. The `horizon` is the
windowed-retention eviction low-water mark from 0003; under static retention
it is effectively negative infinity, since nothing is evicted. A consumer
uses `staleness_ns` to decide when an answer is too far from the cursor to
use, so the policies below clamp and report staleness rather than refusing
wherever a meaningful sample exists.

### 2. hold_last

The latest sample at or before the cursor remains current until the next one.
Resolution returns the predecessor as a value with `staleness_ns = t -
predecessor.instant` (always `>= 0`). Past the last sample the predecessor is
the last sample, so hold_last holds it with growing staleness and never
reports after_end; it is the consumer's call, via staleness, when the held
value is too old. With no predecessor (the cursor precedes every retained
sample) it is a miss: below_horizon when `t < horizon`, otherwise
before_start.

### 3. nearest

The closest sample on either side. With both neighbors present, the nearer
wins; on a tie the earlier instant (the predecessor) wins, deterministically.
`staleness_ns` is signed and may be negative when the successor is nearer.
nearest clamps at both ends rather than missing: below the first retained
sample it returns the first (negative staleness), above the last it returns
the last (positive staleness), and the consumer rejects an over-far clamp by
its staleness. The one miss is honesty about eviction: when `t < horizon` the
genuinely nearest sample may have been dropped, so nearest cannot claim the
first retained sample is nearest and returns below_horizon.

### 4. linear

Interpolation between the two bracketing samples. With a predecessor `lo` and
successor `hi` straddling the cursor, resolution returns both handles and a
fraction, `frac = (t - lo.instant) / (hi.instant - lo.instant)` in `[0, 1]`
as an f32; an exact hit returns that sample as a value with zero staleness.
chronofs returns the bracketing handles and the fraction and never blends
field data; the consumer interpolates the two volumes. linear does not
extrapolate: past the last sample it returns after_end, before the first it
returns before_start (or below_horizon when `t < horizon`), because beyond
the data there is no basis to interpolate and fabricating one would be
dishonest.

### 5. none, and a fourth miss reason

none performs no resampling: an exact hit returns that sample as a value with
zero staleness; anything else is a miss. This exposes a gap 0003's taxonomy
does not cover: a cursor strictly between two samples is in range yet has no
exact sample, which is neither before_start, after_end, nor below_horizon.
This ADR therefore extends the miss taxonomy with a fourth reason, no_sample:
the cursor lies within the series span but no sample satisfies the policy. It
is the in-range miss, distinct from the three boundary reasons, which stand
unchanged. Under none, an interior cursor with no exact hit returns
no_sample; the boundary and eviction cases keep their reasons (before_start,
after_end, below_horizon).

### 6. Cross-cutting rules

below_horizon is checked before any clamp or hold: if `t < horizon`, every
policy returns below_horizon rather than reaching for a retained sample,
since the honest answer is that the relevant data was evicted. An empty index
returns before_start for every cursor. chronofs never interpolates or
otherwise computes over field data under any policy; it resolves time and
returns handles, and linear's blend is the consumer's (0002, the opaque
handle).

### 7. Scope fence

This ADR fixes resolution against a single index. It does not decide the
affine map between the data-time axis and the coordination clock (the
planning document's `TimelineMap`), the group resolve over several series for
ensembles (a convenience over single-index resolution), or the deferred
cross-process cursor sharing. Those remain as the planning document records
them.

## Closure criteria

  1. Operator ratifies Decisions 1 through 6 and the fence in Decision 7.
  2. In particular, the fourth miss reason no_sample in Decision 5 is
     ratified, since it extends ADR 0003 Decision 4's taxonomy from three
     reasons to four; the three boundary reasons are unchanged.
  3. With this ADR the temporal-addressing design series (0002 through 0005)
     is complete; only the deferred cross-process cursor-sharing decision and
     the scheduling of the client-library implementation remain before code.

  No code is authorized by this ADR.

## References

  - chronofs ADR 0002 (ontology), ADR 0003 (index structure; the Resample
    policies, the result shape, and the three-member miss taxonomy this ADR
    resolves and extends), ADR 0004 (instant representation), all Accepted
    2026-06-10, under CHN0002BACKLOG.
  - `chronofs/docs/MULTISERIES-TEMPORAL-ADDRESSING.md` (planning): the result
    types, the `TimelineMap`, and the group-resolve convenience.

## Revision history

  - Proposed 2026-06-10.
  - Accepted 2026-06-10: ratified by the operator as proposed, including the
    no_sample taxonomy extension.
