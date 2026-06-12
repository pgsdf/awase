# chronofs backlog

chronofs is complete (C-1 through C-5; the implementation history
moved to the root `BACKLOG-history.md` at the 2026-05-27 split).
This file tracks chronofs-owned items opened after completion.

### `[x]` CH-1: chrono_dump blocks instead of reporting on the supervised stack  *(CLOSED 2026-06-05 per chronofs ADR 0001 Decisions 1 and 2; bench-verified: reports live/paused and exits in every state, never blocks; zig build test green)*

chrono_dump waits indefinitely where the pre-AD-20 design expected
daemon event ingestion; on the supervised production stack it
hangs even with a live clock and an active stream (observed during
F.6 closure verification, 2026-06-05). The clock itself was fine:
`audiofs/tools/clock_dump` read it at exactly 48000.0 Hz. Fix
shape: a blocked wait becomes an invalid-or-idle report; the tool
should print what the clock region says and exit. Owner: chronofs.

### `[x]` CH-2: ingestion-path reckoning (historical semaaud/semainput line formats)  *(CLOSED 2026-06-05 per chronofs ADR 0001 Decision 3: arms removed, replay machinery retained for semadraw; bench-verified by replay fixture and green tests)*

`ingestSemaaudLine`, the `.semaaud` Subsystem arm, and
`spawnIngestionThreads` are unwired library code pinning a retired
producer's JSON-lines format; semasound's events are key=value
with a `frames` position on a state surface, not a stdout stream
(ADR 0027). ADR 0029 deliberately fenced this: rewiring chronofs
ingestion (or retiring it) is a chronofs feature decision. When
chronofs next takes feature work, decide: adapt ingestion to the
semasound surface model, or retire the ingestion layer and its
dead formats. Until then the deprecation comments stand.

### `[~]` CHN0002BACKLOG: multi-series temporal addressing for contemporary METOC visualization  *(In progress 2026-06-10; design complete, initial implementation landed)*

The chronofs surface that 4D/5D METOC visualization needs: addressing a set
of independently-timestamped data series against one shared temporal cursor,
so spatial rendering (Vulkan, client-side) and the variable axis (client
data model) stay out of the substrate while the time axis is UTF's. Design
is captured in `chronofs/docs/MULTISERIES-TEMPORAL-ADDRESSING.md` (planning)
and proceeds as an ADR series, each derived from the one before:

  - ADR 0002 (ordered-instants-only ontology): chronofs indexes ordered
    instants, not temporal relationships; opaque handles it never decodes;
    relationships as multiple independent indices, not a k-D key; scope is
    operational and scientific horizons, not deep time. Accepted 2026-06-10.
    This entry is the identifier that ADR anchors.
  - ADR 0003 (index structure): sorted, bisecting, non-evicting insertion;
    a functional instant-to-handle relation with a per-index last_insertion
    or sequenced supersession policy; static or windowed retention on the
    bound axis; and the miss taxonomy. Accepted 2026-06-10.
  - ADR 0004 (instant representation): i64 nanoseconds since the Unix epoch,
    signed, a uniform count with no civil-time semantics, range about
    1677-09-21 to 2262-04-11, two's-complement little-endian. Accepted
    2026-06-10.
  - ADR 0005 (resolution behavior): per-policy mapping of a cursor and the
    boundary states to a value or a miss, with signed staleness and a
    fourth in-range miss reason, no_sample. Accepted 2026-06-10.

The design series (0002 through 0005) is complete and normative. The
cross-process cursor-sharing decision stays deferred until a real
cross-process linked-view use case exists (operator decision 2026-06-10).

Implementation followed `chronofs/docs/MULTISERIES-IMPLEMENTATION-PLAN.md`.
The core primitives landed and were verified green with `zig build test`
(pure logic, any Zig 0.15.2 host, no bench hardware), in three stages, all
2026-06-10:

  - Stage 1: `src/instant.zig` (instant representation, ADR 0004) and the
    `src/timeindex.zig` core (insertion, both supersession policies,
    static/windowed retention, bisection; ADRs 0002, 0003).
  - Stage 2: resolution in `src/timeindex.zig` (the four resample policies,
    the four-reason miss taxonomy including no_sample, signed staleness,
    below-horizon precedence; ADR 0005).
  - Stage 3: `src/timeline.zig` (`TimelineMap` and `TimelineView`, the affine
    map from the sample-frame clock to the data-time cursor; ADR 0004).

The initial target is complete. What remains is deferred by choice, not
blocked: the cross-process cursor-sharing decision (until a real
cross-process linked-view use case exists; operator decision 2026-06-10) and
the group-resolve convenience over several series for ensembles (a later
addition over single-index resolution). Owner: chronofs.
