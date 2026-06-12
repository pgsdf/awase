# chronofs 0002: the index domain is ordered instants, not temporal relationships

## Status

Accepted, 2026-06-10: ratified by the operator as proposed, all five
decisions, with the two pre-ratification tightenings folded in (Decision 1's
bound-axis-identity fence and Decision 3's axis-independence rationale in
place of the handle-size rationale). This ADR authorizes no code, so there
is no implementation step. Closure criterion 1 is discharged. Criterion 3
was discharged 2026-06-10: the operator assigned BACKLOG identifier
CHN0002BACKLOG to anchor this ADR. Criterion 2 (follow-on ADRs carry this
framing forward) remains open and is addressed as the series proceeds (0003
onward).

Proposed, 2026-06-10. The foundational ADR of the chronofs multi-series
temporal-addressing series, opened from the planning document
`chronofs/docs/MULTISERIES-TEMPORAL-ADDRESSING.md` and the operator review of
it. A chronofs BACKLOG identifier (a CH-N entry) is pending operator
assignment. This ADR authorizes no code.

## Context

PGSD targets contemporary METOC visualization across at least four classes:
SAR and operational fusion, ensemble and probabilistic NWP, analysis and
reanalysis diagnostics, and coupled earth-system work. When geometry,
statistics, and data semantics are stripped away, all four reduce to the
same temporal requirement: a set of independently-timestamped series
resolved to one shared cursor. The pressure test is that none of the four
introduced a meteorological concept (forecast member relationships, variable
grouping, grid topology, vertical coordinates, provenance graphs) into
chronofs itself. Their union added only ordered-instant indexing and a few
behaviors over it.

The risk this ADR forecloses is the gradual acquisition of domain semantics
by the substrate. The moment chronofs understands valid time, init time,
acquisition time, and ingest time as distinct named dimensions, it has
become a meteorology substrate rather than a temporal one. The hinge is to
commit to the narrowest workable ontology and let everything else follow
from it.

## Decisions

### 1. chronofs indexes ordered instants, not temporal relationships

The index domain is a totally ordered set of instants on a single bound
axis. chronofs assigns no meaning to which axis is bound. The labels valid,
init, acquisition, ingest, model cycle, experiment phase, and whatever comes
next are client concepts, and every relationship among them (the
init-by-valid matrix, ensemble membership, level, variable grouping,
provenance) is expressed and interpreted entirely in the client. chronofs
knows only that an ordered instant domain is currently bound to an index.
The identity of the bound axis is not represented within the index: storing
an axis label (for instance a valid-time or init-time tag) in index metadata
is out of scope by this decision, since it would let the substrate reacquire
the axis semantics this decision removes.

### 2. Handles are opaque; chronofs never decodes them

A handle is an opaque token the client uses to fetch its data. The contract
commits to opacity, not to a width. A handle may be a 64-bit value now and a
wider fixed token later (naming, for instance, variable, member, level, and
chunk) without changing this ADR. The invariant is that chronofs performs no
decode of a handle and branches on no field within one. Handle width is
therefore not a decision this ADR makes; only opacity is.

### 3. Relationships are multiple independent indices, not one k-D key

A client that sweeps more than one axis (valid at fixed init, then init at
fixed valid) holds one index per bound axis; the pinned axes are client-side
equality filters. chronofs does not hold a multidimensional temporal key and
does not resolve across axes. The cost is additional storage proportional
to the number of indexed handles, per swept axis. That cost is accepted
because preserving axis independence is an architectural goal: each index
carries its own retention, its own insertion stream, and its own scrub
behavior, and no operation inside the substrate is made conditional on axis
selection.

### 4. Scope: operational and scientific horizons, not deep time

chronofs's temporal domain targets operational and scientific time series
spanning historical through forecast horizons: the satellite era,
operational feeds, and reanalysis back into the nineteenth and twentieth
centuries. Deep-time geological and paleoclimate timelines are out of scope.
The concrete instant unit, and therefore the finite representable range, is
a representation decision deferred to a later ADR that cites this scope. Any
resulting ceiling (for example the roughly year-2262 bound of a nanosecond
epoch) is a deliberate consequence of this scope, not an arbitrary
limitation, and the representation ADR states it as such.

### 5. Scope fences

This ADR fixes the ontology only. It does not decide the index structure,
the retention policy, the resampling policies, or the instant unit; each is a
separate ADR that builds on this one.

Two clarifications keep the ontology honest:

  - Retention and resampling are behaviors over the index, not relationships
    within it. Retention compares an instant against a horizon; resampling
    compares an instant against its neighbors. Neither introduces axis or
    domain semantics, so both are consistent with Decision 1 and may live in
    the substrate.
  - "Ordered instants" permits duplicate instants. Whether the
    instant-to-handle relation is functional (a reissued or corrected sample
    at the same instant supersedes the prior one) or a multimap (several
    samples coexist at one instant) is left open here and must be decided by
    the index-structure ADR, since out-of-order insertion makes supersession
    a real case (a late correction for an instant already indexed). This ADR
    only asserts that the ontology does not assume uniqueness.

## Closure criteria

  1. Operator ratifies the ontology in Decisions 1 through 4 and the fences
     in Decision 5.
  2. The planning document and all follow-on ADRs adopt this framing; the
     k-D temporal key is treated as out of scope by construction rather than
     as a live alternative.
  3. A chronofs BACKLOG identifier is assigned for the temporal-addressing
     work and points here.

  No code is authorized by this ADR.

## References

  - `chronofs/docs/MULTISERIES-TEMPORAL-ADDRESSING.md` (planning): the design
    this ADR anchors.
  - `chronofs/src/clock.zig`, `chronofs/src/stream.zig`,
    `chronofs/src/resolver.zig`: the existing single-timeline engine this
    generalizes, in which `EventStream.at` is the zero-order-hold degenerate
    case.
  - chronofs ADR 0001 (chrono_dump and the ingestion reckoning).
  - Operator review feedback, 2026-06-10: the narrow-ontology framing, and
    the retention truth-value, handle-opacity, and explicit-scope points.

## Revision history

  - Proposed 2026-06-10.
  - Accepted 2026-06-10: ratified by the operator as proposed, with the
    Decision 1 and Decision 3 tightenings folded in.
  - 2026-06-10: BACKLOG identifier CHN0002BACKLOG assigned; closure
    criterion 3 discharged.
