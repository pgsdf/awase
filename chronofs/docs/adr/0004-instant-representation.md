# chronofs 0004: instant representation (unit, epoch, range)

## Status

Accepted, 2026-06-10: ratified by the operator as proposed, all six
decisions, with the review clarifications folded in (Decision 3's
linear-axis statement and normative shared-timescale invariant, the Decision
4 heading and implementation-defined out-of-range note, and Decision 5's
two's-complement serialization). This ADR authorizes no code, so there is no
implementation step. Closure criteria 1 and 2 are discharged; criterion 3
(ADR 0005 builds on this representation) remains open and is addressed as the
series proceeds.

Proposed, 2026-06-10. The third ADR of the chronofs multi-series
temporal-addressing series, opened under BACKLOG identifier CHN0002BACKLOG.
It builds on ADR 0002 (ordered-instants-only ontology) and ADR 0003 (index
structure), both Accepted 2026-06-10, and fixes the concrete representation
of the instants those ADRs treat abstractly. This ADR authorizes no code.

## Context

ADR 0002 fixed the ontology (chronofs indexes ordered instants on a bound
axis) and scoped the temporal domain to operational and scientific horizons,
deep time out of scope, while deferring the concrete instant unit to a later
ADR. ADR 0003 fixed the index structure over those instants. This ADR pins
what an instant actually is: its unit, epoch, signedness, representable
range, timescale interpretation, and serialization. It is purely a
representation decision; resolution behavior (how a cursor maps to a value or
a miss) is ADR 0005, and the mapping between this data-time axis and the
coordination clock is the planning document's `TimelineMap`.

A clarification this ADR rests on: the instant axis is not the coordination
clock. The existing `Clock` (clock.zig) reports a `u64` of PCM sample frames,
a monotonic count relative to stream start, anchored to no civil epoch. The
instant axis defined here is absolute data time (a model valid hour, a SAR
acquisition instant). The two are related by an affine map with a rate and an
origin (the planning document), not by identity, and this ADR fixes only the
data-time representation.

## Decisions

### 1. Unit and type: i64 nanoseconds

An instant is a signed 64-bit integer count of nanoseconds. Nanoseconds
match the unit the rest of UTF already uses (the clock's `toNs`, the
idle-timestamp work) and give exact, uniform resolution across the entire
representable range, unlike an `f64` count of seconds, whose 53-bit mantissa
holds nanosecond precision only within about 104 days of its origin and
degrades to coarser than a millisecond over a multi-decade span. Exact
uniform resolution is consistent with chronofs's existing exactness
discipline (the sample-frame clock, the rational playback rate).

### 2. Epoch: the Unix epoch, signed

Instants are counted from the Unix epoch, 1970-01-01T00:00:00Z. The count is
signed so instants before the epoch are representable as negative values:
modern reanalysis reaches back past it (ERA5 to 1940, the 20th Century
Reanalysis to 1836), and 0003's sorted index orders negative and positive
instants identically.

### 3. Timescale: a uniform count, not civil time

chronofs treats the instant as a uniform count of nanoseconds and nothing
more: it orders instants and takes their differences. The nanosecond unit is
purely a linear measurement on the instant axis; chronofs attaches no UTC,
TAI, POSIX, or any other civil-timescale semantics to the count. It does not
interpret the count as a civil time, does not know time zones, calendars, or
leap seconds, and does not convert. A client is responsible for linearizing
its source timestamps into this canonical count consistently, including any
calendar (360-day, noleap) or leap-second treatment. This follows from 0002:
civil and calendar semantics are temporal relationships and domain knowledge,
which live in the client, not the substrate. For METOC the common POSIX
convention (nanoseconds since the Unix epoch, ignoring leap seconds) is the
natural client choice, since data cadences dwarf the sub-second leap-second
discontinuity; chronofs neither requires nor forbids it.

Normatively: all series participating in one resolution must be expressed on
the same linearized timescale. Mixing timescales is a client error; chronofs
cannot detect it, since it sees only counts.

### 4. Range: deliberately bounded

i64 nanoseconds spans about 292 years on either side of the epoch, roughly
1677-09-21 to 2262-04-11. Per 0002's scope this covers every operational,
forecast, satellite-era, and modern-reanalysis need. Deep-time geological and
paleoclimate timelines fall outside it and are out of scope; serving them
would require a coarser unit and is explicitly not a goal. The ceiling is a
deliberate consequence of choosing nanosecond resolution under 0002's scope,
not an arbitrary limit, and is recorded here as such so it is never read as
an oversight. An instant outside the representable range is a client error
arising from out-of-scope data, not a case chronofs accommodates. Whether an
implementation detects and reports such an instant at construction, at
insertion, or by assertion is implementation-defined; this ADR fixes only
that such instants are out of scope.

### 5. Serialization: little-endian i64

When an instant crosses a boundary (a persisted index, a future protocol
message) it serializes as the two's-complement little-endian representation
of a signed 64-bit integer, eight bytes,
matching UTF's existing wire conventions (the protocol constants, the
idle-reply payload). No on-wire surface exists yet; this fixes the convention
for when one does.

### 6. Scope fence

This ADR fixes representation only. It does not decide how a cursor at or
beyond a series boundary maps to a value or a miss (ADR 0005), nor the affine
map between this data-time axis and the coordination clock (the planning
document's `TimelineMap`), nor any client-side calendar conversion.

## Closure criteria

  1. Operator ratifies Decisions 1 through 5 and the fence in Decision 6.
  2. In particular, Decision 3 (a uniform count with no civil-time, calendar,
     or leap-second semantics in the substrate) is ratified or amended, since
     it is the load-bearing interpretation choice and the one most able to
     pull domain knowledge into chronofs if decided otherwise.
  3. ADR 0005 (resolution behavior) builds on this representation.

  No code is authorized by this ADR.

## References

  - chronofs ADR 0002 (ordered-instants-only ontology, Accepted 2026-06-10),
    especially Decision 4 (scope), under CHN0002BACKLOG.
  - chronofs ADR 0003 (index structure, Accepted 2026-06-10).
  - `chronofs/docs/MULTISERIES-TEMPORAL-ADDRESSING.md` (planning): the
    `TimelineMap` that relates this axis to the coordination clock.
  - `chronofs/src/clock.zig`: the coordination clock (u64 sample frames),
    distinct from the i64-nanosecond instant axis defined here.

## Revision history

  - Proposed 2026-06-10.
  - 2026-06-10: clarified Decision 3 (the instant is a purely linear axis
    with no UTC/TAI/POSIX semantics; the shared-timescale invariant stated
    normatively), removed the duplicate rounded range from the Decision 4
    heading, noted out-of-range detection as implementation-defined, and
    specified two's-complement little-endian serialization.
  - Accepted 2026-06-10: ratified by the operator as proposed, including the
    review clarifications.
