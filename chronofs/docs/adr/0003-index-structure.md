# chronofs 0003: index structure, supersession, retention, and the miss taxonomy

## Status

Accepted, 2026-06-10: ratified by the operator as proposed, all five
decisions, including the Decision 2 amendment adopting the per-index
supersession policy (last_insertion or sequenced). This ADR authorizes no
code, so there is no implementation step. Closure criteria 1 and 2 are
discharged; criterion 3 (ADRs 0004 and 0005 build on this structure) remains
open and is addressed as the series proceeds.

Proposed, 2026-06-10. The second ADR of the chronofs multi-series
temporal-addressing series, opened from ADR 0002 (ordered-instants-only
ontology, Accepted 2026-06-10) under BACKLOG identifier CHN0002BACKLOG. It
derives the index's structure and behavior from 0002's ontology and
introduces no temporal model parallel to it. This ADR authorizes no code.

## Context

ADR 0002 fixed the ontology: chronofs indexes ordered instants on a single
bound axis, with opaque handles it never decodes, relationships expressed as
multiple independent indices, and no representation of the bound axis's
identity inside the index. This ADR settles how such an index behaves:
insertion, what a repeated instant means, retention, and the boundary states
a resolve can report. Each decision is derived from 0002 and cites the
decision it follows from, so the structure is a consequence of the ontology
rather than a parallel design.

The settled questions are deliberately the ones most able to decay into
mechanism if treated as storage choices. The meaning of a repeated instant
and the meaning of an out-of-range cursor are semantic, and are decided as
such here, with the data structure following from the meaning.

## Decisions

### 1. Sorted insertion over a bisecting, non-evicting index

Insertion places a sample at its position in bound-axis order; arrivals need
not be monotonic, and an out-of-order arrival is placed by its instant, not
appended. Lookup bisects. The index does not evict by capacity.

This follows from 0002 Decision 1: ordering on the bound axis is the index's
only structure, so insertion preserves that order and lookup uses it. It is
the deliberate divergence from the telemetry `EventStream` (stream.zig),
whose contract is monotonic append with oldest-eviction on a fixed ring.
That contract is correct for a live forward-only event feed and wrong for a
dataset that is scrubbed in both directions and fed by late and out-of-order
arrivals.

### 2. The instant-to-handle relation is functional; a repeated instant supersedes

At most one handle resolves at any instant. A sample inserted at an instant
already present supersedes the prior one. Genuine coexistence of distinct
samples at one instant is expressed client-side as separate indices or a
finer bound axis, never as multiple handles at one instant within a single
index.

The functional relation is forced by 0002, not chosen for convenience:

  - 0002 Decision 1 gives the index no second ordering axis. Two handles at
    one instant are therefore indistinguishable to the index; ordering or
    choosing between them would require a second axis, which is the parallel
    temporal model 0002 forbids.
  - 0002 Decision 3 already routes genuine coexistence (two sensors at the
    same timestamp, ensemble members) to separate indices or filters, so a
    multimap is not needed to express it.

Which sample wins at a repeated instant is a per-index supersession policy:

  - last_insertion: the most recently inserted handle wins. Simple, and
    correct when inserts arrive in issue order.
  - sequenced: each insert carries a client-supplied monotonic sequence (a
    u64); at a repeated instant a strictly greater sequence supersedes, and
    an equal or lesser sequence is dropped, leaving the incumbent. This makes
    supersession reorder-safe (a stale duplicate arriving after a newer
    correction cannot clobber it) and re-delivery idempotent.

The sequence stays consistent with 0002 because of what it is not. It is not
a second ordering axis: it is never bound by a cursor, never queried, and
never orders the index's instants; it breaks ties only within one instant.
It is not a decode of the handle: the client passes the sequence as a
separate scalar at insert time, and chronofs never reads it out of the opaque
handle, so 0002 Decision 2 holds. It is a write-order tiebreak, the storage
analogue of a last-writer-wins version, not a temporal relationship. chronofs
assigns the sequence no meaning beyond "strictly greater supersedes"; what it
represents (issue time, version, ingest counter) and the guarantee that a
superseding sample carries a greater value are the client's, and chronofs
neither knows nor verifies that meaning.

Consequence: a client that needs reorder-safe correction selects the
sequenced policy and assigns sequences in issue order; a client whose inserts
are already ordered uses last_insertion and supplies no sequence. Either way
the relation stays functional and the index stays free of axis semantics.

### 3. Retention policy per index: static or windowed, on the bound axis

Each index carries one retention policy:

  - static: every inserted sample is kept; nothing is dropped; the full
    history is scrubbable in both directions.
  - windowed: the index keeps a horizon, a span on the bound axis behind the
    most recently indexed instant; samples older than the horizon are
    dropped, and an insertion that falls below the horizon is rejected.

The horizon is measured on the bound axis only, never on a second axis such
as ingest time, which keeps retention consistent with 0002 Decision 1.
Windowed eviction is by horizon, distinct from the `EventStream` ring's
eviction by capacity; backing-store sizing is an implementation detail, not a
retention semantic.

### 4. The miss taxonomy: three distinct meanings

A resolve that yields no value reports one of three reasons, which are
meanings and not interchangeable return codes:

  - before_start: the cursor precedes the earliest indexed instant. Data
    never existed at the low end.
  - after_end: the cursor follows the latest indexed instant. Data does not
    yet exist at the high end.
  - below_horizon: under windowed retention, the cursor precedes the horizon.
    Data existed and was dropped by policy. This reason cannot arise under
    static retention.

before_start and below_horizon are deliberately distinct: one means the data
never arrived, the other that it arrived and aged out, and a consumer that
cannot tell them apart cannot reason correctly about an operational feed.
How each resampling policy maps a cursor at or beyond a boundary either to a
value (for example hold_last holding past after_end with growing staleness)
or to one of these misses is resolution behavior, deferred to ADR 0005.

These three are the boundary reasons. ADR 0005 (resolution behavior) adds a
fourth, in-range reason, `no_sample`, for a cursor that lies within the
series span but has no sample satisfying the policy (the `none` policy's
interior miss); see ADR 0005 Decision 5 for the authoritative four-reason
taxonomy.

### 5. Scope fences

This ADR fixes index structure and the meaning of a repeated instant, a
retention boundary, and an out-of-range cursor. It does not decide:

  - the instant unit, epoch, and range (ADR 0004, representation), which
    0002 Decision 4 already scopes to operational and scientific horizons;
  - the resampling-to-result mapping and neighborhood semantics (ADR 0005,
    resolution);
  - the concrete backing-store container, an implementation choice
    consistent with Decisions 1 and 3.

## Closure criteria

  1. Operator ratifies Decisions 1 through 4 and the fences in Decision 5.
  2. In particular, the supersession model in Decision 2 (functional, with a
     per-index last_insertion or sequenced policy, coexistence via separate
     indices) is ratified or amended, since it is the load-bearing semantic
     choice.
  3. ADRs 0004 and 0005 build on this structure.

  No code is authorized by this ADR.

## References

  - chronofs ADR 0002 (ordered-instants-only ontology, Accepted 2026-06-10),
    BACKLOG identifier CHN0002BACKLOG: the ontology this ADR derives from.
  - `chronofs/docs/MULTISERIES-TEMPORAL-ADDRESSING.md` (planning).
  - `chronofs/src/stream.zig`: the `EventStream` whose monotonic-append and
    capacity-eviction contract this index deliberately diverges from.
  - Operator review feedback and sequencing guidance, 2026-06-10.

## Revision history

  - Proposed 2026-06-10.
  - 2026-06-10: amended Decision 2 to adopt a per-index supersession policy
    (last_insertion or sequenced), making reorder-safe supersession a
    first-class option; the sequence is argued consistent with 0002 as a
    write-order tiebreak, not a second axis and not a handle decode.
  - Accepted 2026-06-10: ratified by the operator as proposed, including the
    Decision 2 amendment.
