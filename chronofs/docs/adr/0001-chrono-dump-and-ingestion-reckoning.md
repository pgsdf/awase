# chronofs 0001: chrono_dump repointing and the ingestion reckoning (CH-1, CH-2)

## Status

Accepted, 2026-06-05: ratified by the operator as proposed, all
four decisions, including Decision 2's severity (stdin modes
removed outright, no --ingest flag retained) and Decision 3's
consequence (historical semaaud/semainput recordings lose their
domains under replay; git archives the parsers). Implementation
landed and was bench-verified the same day (criteria 1 through
5 discharged); criterion 6, the operator mark, is the only
open item.

Proposed, 2026-06-05. The first chronofs ADR; opened from the
AD-3 closure handoffs (root ADR 0029 Decision 6, ADR 0030
Decision 6; chronofs/BACKLOG.md CH-1 and CH-2).

## Context

AUDIT FINDINGS, 2026-06-05 tree:

  - chrono_dump's live and drift modes read STDIN: the tool was
    designed as the consumer of a daemon pipeline
    (`{ semaaud; semainputd; semadrawd; } | chrono_dump`). Run
    bare, it blocks on an empty terminal stdin; this is CH-1's
    observed hang during F.6 closure, on a machine whose clock
    was provably live at 48000.0 Hz.
  - runLive never reads `/var/run/sema/clock`. The clock reader
    (chronofs/src/clock.zig) is consumed by semadraw's frame
    scheduling and is the living, load-bearing piece of chronofs
    userland; chrono_dump's live path does not use it.
  - NO producer of the EVENT_SCHEMA JSON-lines format remains:
    semaaud and semainputd are retired, and no emitter of the
    format exists in shared/ or semadrawd. The ingestion arms
    (ingestSemaaudLine, ingestSemainputLine, ingestSemadrawLine),
    the Subsystem enum, ingestionThread/spawnIngestionThreads,
    and the DriftTracker have an input ecology of exactly zero
    live sources. Their only consumer is chrono_dump itself.
  - `--replay` is file-driven and self-contained: it can analyze
    any RECORDED material in the format, independent of live
    producers.
  - The format's tests pin parsing of recorded material; the
    schema document (shared/EVENT_SCHEMA.md) already carries the
    F.6 retirement note.

## Decisions

### 1. chrono_dump's default mode becomes the clock report (CH-1)

Run bare, chrono_dump reads `/var/run/sema/clock` through the
chronofs clock reader, prints the decoded region (validity,
source, sample rate, samples_written, derived t), takes a second
sample after a short interval to report advance (live / paused /
invalid), and exits. It never blocks. `-f` follows at 1 Hz until
interrupted. This is what operators since F.4 reach for under
this tool's name; the F.6 closure used audiofs's clock_dump to
fill exactly this hole, and the two tools remain complementary
(clock_dump is audiofs's raw-region view; chrono_dump reports
through the same reader library the consumers use).

### 2. The stdin live and drift modes are removed

Their producer set is empty; a mode that can only ever block is
not preserved as an interface. `--replay` is RETAINED unchanged:
recorded EVENT_SCHEMA material stays analyzable at zero
maintenance cost. Drift analysis over replayed files, if ever
wanted, is a small follow-on against the retained machinery, not
a reason to keep a stdin reader with no writers.

### 3. The semaaud and semainput ingestion arms are removed (CH-2)

ingestSemaaudLine, ingestSemainputLine, their tests, and their
Subsystem arms are deleted; git is the archive, per the
forward-only discipline and the semainputd/semaaud precedents.
The Subsystem enum trims to what `--replay` still serves
(semadraw); ingestSemadrawLine and the line-dispatch machinery
are retained solely as replay infrastructure. The deprecation
comments placed by root ADR 0029 are superseded by the removal
itself.

### 4. Scope fences

NOT in scope: any new ingestion of semasound's state surfaces
(a future feature decision requiring a real consumer need, not
this cleanup); any change to the clock reader or its consumers;
any change to semasound or audiofs; EVENT_SCHEMA.md beyond an
emitter-status correction (the document claims semadraw emission
remains current; no emitter was found, and the note is corrected
to recorded-format status).

## Closure criteria

  1. Bare `chrono_dump` on the bench prints the clock report and
     exits against (a) a live stream (advance shown), (b) an idle
     broker (paused shown), (c) the module unloaded (invalid or
     absent shown). No invocation blocks.
  2. `chrono_dump --replay` over a recorded sample still works
     (a fixture file exercised by test or by hand).
  3. `zig build test` passes in chronofs with the removed arms'
     tests gone and the retained machinery's tests green.
  4. Tree gate: no ingestSemaaudLine / ingestSemainputLine
     anywhere outside git history and ADR text; EVENT_SCHEMA.md
     carries the emitter-status correction.
  5. chronofs/BACKLOG.md closes CH-1 and CH-2 against this ADR;
     the root README's chronofs section is checked for accuracy.
  6. Operator marks CH-1 and CH-2 `[x]`.

## References

  - Root ADR 0029 Decision 6: the fence this ADR now opens
    deliberately, as chronofs work.
  - Root ADR 0030 Decision 6: the handoff that created CH-1/CH-2.
  - shared/EVENT_SCHEMA.md: the format's record.
  - audiofs/tools/clock_dump: the raw-region sibling tool.

## Revision history

  - 2026-06-05: proposed, on the audit findings above. Four
    decisions: clock report as the default mode; stdin live and
    drift modes removed with --replay retained; the semaaud and
    semainput ingestion arms removed with replay machinery kept;
    fences against new surface ingestion and clock-reader change.
  - 2026-06-05: ratified by the operator as proposed.
    Implementation landed: chrono_dump rewritten (clock-report
    default reading /var/run/sema/clock through the chronofs
    reader, two-sample advance, -f follow at 1 Hz; --replay
    retained byte-identical in behaviour; live/drift/DriftTracker
    and the timeline printers removed); resolver.zig loses
    ingestSemaaudLine, ingestSemainputLine, their five tests, the
    Subsystem enum, IngestionArgs, ingestionThread,
    spawnIngestionThreads, and the posix_safe import (its only
    user); ingestSemadrawLine, the extractors, and all Resolver
    tests retained. EVENT_SCHEMA.md corrected to recorded-format
    status. Container verification: brace balance both files;
    zig build test and the bench states are the operator's gates.
  - 2026-06-05 (bench evidence): zig build test green (criterion
    3). Criterion 1: bare chrono_dump reported and exited in every
    exercised state, never blocking: live during a tone (advance
    +10240 over 200 ms), live at system idle, and paused after
    kldunload. Criterion 2: --replay resolved a hand fixture
    exactly (visual none before t=48000, surface_id=1 frame=1 at
    and after; audio and input (none) per Decision 3). Criterion
    5: BACKLOG entries closed; the README chronofs section checked
    accurate without edits. Three findings recorded:
    (1) Criterion 1(c) as written predicted "invalid or absent"
    after module unload; the bench shows valid+paused, because the
    tmpfs publication outlives the module and clock_valid is never
    reset. That is the designed semantics (FAILURE_MODES, "Clock
    writer stops"), the prediction was wrong, not the tool; the
    criterion is satisfied in its substance (report, exit, no
    block) and this note corrects its letter.
    (2) "Live while idle" is the lazy rest state: the engine keeps
    clocking between sessions (f5b preamble), so advance > 0 with
    no client is correct behaviour, not an anomaly.
    (3) Advance figures are whole 1024-sample interrupt periods
    (9216 or 10240 over a 200 ms window), so the effective-rate
    figure is period-granular, not a rate error. Cosmetic label
    refinements ("paused" wording, a tilde on effective rate) go
    to the hygiene ledger rather than churning a verified binary.
    Bench incidentals: unprivileged semasound-tone fails
    AccessDenied on the broker socket (expected posture; sudo is
    the path), and the takeover flag is uppercase -T (a lowercase
    -t timeout is an s6-svc subscription error).
