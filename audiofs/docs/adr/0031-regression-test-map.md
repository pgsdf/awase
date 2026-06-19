# ADR 0031 regression-test map

## Relationship to ADR 0031

A verification companion to ADR 0031, not itself an ADR. It turns
the ten merge gates in ADR 0031 Section 8 into concrete,
mechanizable assertions so that gate closure is a checklist of
observations rather than a reviewer judgement call. Every test
here traces to exactly one gate; the coverage table at the end is
the traceability map.

This document authorizes no code and asserts no result. It
specifies what must be asserted, what must never appear again, and
what would betray a surviving fence or a leaked third state. The
runtime tests are written for the operator to run on
pgsd-bare-metal; this environment cannot run them.

Placement is the operator's call: alongside ADR 0031 in
`audiofs/docs/adr/` as a companion file, or under a `verification/`
path. It is referenced by ADR 0031's merge gates and should land
before or with the implementation, since gate closure depends on
it.

## How to read this map

Each test carries a method tag:

  - **STATIC.** Source audit, grep, or compile-time check. The
    operator can run these in CI without the bench.
  - **BENCH.** Single-stream runtime observation on
    pgsd-bare-metal (log and sysctl).
  - **CONCURRENT.** Multi-thread stress against a reader harness,
    the only way to catch the ordering and linearizability holes.

Each test states what it MUST assert (the positive property), what
it MUST NEVER observe (the regression sentinel), a fence or
third-state detector where applicable, and a failure
interpretation that names which invariant broke. The failure
interpretation matters as much as the assertion: a red test should
point at the specific ADR clause that regressed, not just fail.

## Two standing sentinels (run continuously, not per-gate)

### S1. The storm fingerprint (the canonical regression signature)

The original bug's fingerprint is any topology-walk log emitted at
the audio fragment rate. The single most important standing
assertion is that it never returns.

  - **MUST NEVER observe.** `audiofs0: path_dead_end` (or any
    `path_*` topology-walk log, or any state-region full rebuild)
    appearing at or near 46.875 Hz, i.e. more than a few per
    second, under any condition including a sustained stall.
  - **Detector.** Sample `dmesg` rate of `path_dead_end` over a
    60-second window in every bench scenario below. Nonzero at the
    fragment rate is the original storm, regardless of which gate's
    scenario produced it.
  - **Failure interpretation.** The amplifier (Violation 1 or 2,
    ADR 0031 Section 1) has returned: an event path is calling a
    full rebuild again.

### S2. The hidden-fence detector (deliberate weakening)

A fence that was removed in calls can survive in semantics. The
way to prove it has not: in a throwaway test build, deliberately
break the `last_event_seq` release/acquire ordering (for example,
relax the store to non-atomic or move it before the field writes).
Coherence (G7) and causal direction (G6) MUST then break under the
CONCURRENT harness.

  - **MUST assert.** With watermark ordering deliberately broken,
    the G6 and G7 stress tests FAIL.
  - **Detector / failure interpretation.** If they still PASS with
    the watermark ordering broken, then something else is providing
    cross-domain ordering: a hidden fence survives (a lock, a
    traversal, an allocation barrier). That is a defect under ADR
    0031 6.2 and 6.6, and the surviving mechanism must be found and
    removed, not relied upon.

This is a meta-test: it validates that the watermark is actually
load-bearing rather than incidentally shadowed by a second
mechanism.

## Per-gate test map

### G1. Republish-caller audit closed

  - **Method.** STATIC.
  - **Property (ADR 0031 7.1).** The only callers of
    `audiofs_state_republish` / `state_rebuild_topology` are the
    attach and detach topology paths. No event or content path
    calls a full rebuild.
  - **MUST assert.** Grep of the merged tree shows
    `state_rebuild_topology` callers are exactly
    `audiofs_state_register` (attach) and `audiofs_state_unregister`
    (detach). `audiofs_events_publish` contains no rebuild call.
    The format-change ioctl calls `state_update_dynamic`, not a
    rebuild.
  - **MUST NEVER observe.** A rebuild call reachable from
    `audiofs_events_publish`, the xrun task, or any per-fragment
    interrupt path.
  - **Failure interpretation.** Violation 2 (telemetry
    amplification) is reintroduced.

### G2. Reader audit closed

  - **Method.** STATIC (reader code audit), with CONCURRENT
    cross-check via G6/G7/G9.
  - **Property (ADR 0031 7.2).** No state-region reader relies on
    `last_event_seq == writer_seq`, on snapshot refresh rate as a
    time or event-density proxy, or on rebuild-traversal ordering.
  - **MUST assert.** Each reader (principally semasound, plus any
    diagnostic tool) is documented as: using the ring's
    `writer_seq` for event counts, and `last_event_seq`
    (acquire-loaded) only for snapshot-to-ring correlation. Content
    change is detected via `inventory_seq` and the seqlock-consistent
    dynamic-field read, never via `last_event_seq`.
  - **MUST NEVER observe.** Any reader comparing `last_event_seq`
    to `writer_seq` for equality, or deriving a rate or elapsed
    time from snapshot refresh frequency.
  - **Failure interpretation.** The accidental equality (ADR 0031
    6.3) is load-bearing for a reader; fix the reader, do not
    restore rebuild-as-fence.

### G3. Idle quiet (the keystone, most discriminating)

  - **Method.** BENCH.
  - **Property (ADR 0031 2, gate 3).** At idle, and even under a
    sustained stall, the kernel log is quiet: xrun detection still
    works, but it no longer amplifies to a topology walk.
  - **Setup.** Two sub-cases. (a) True idle, no stream. (b)
    Induced stall: `playtone --stall` (per ADR 0017) so the stream
    runs with the user ring starved.
  - **MUST assert.**
    - Case (a): zero `path_dead_end` over 60 seconds;
      `clock_valid == 0` (no stream); compositor on wall clock.
    - Case (b): `dev.audiofs.0.underflow_count` climbs (xrun
      detection is intact, ADR 0017 behavior preserved) AND
      `path_dead_end` count stays at zero. This is the
      discriminating assertion: it separates "xrun detection works"
      (must remain) from "xrun amplifies to a rebuild" (must be
      gone).
  - **MUST NEVER observe.** `path_dead_end` at the fragment rate in
    either case (S1).
  - **Failure interpretation.** If underflow climbs but
    path_dead_end is also climbing, Decision B did not actually
    decouple the xrun event from the rebuild.

### G4. Topology consistency under mutation

  - **Method.** BENCH (fault-injected topology mutation during a
    live stream).
  - **Property (ADR 0031 3.1, gate 4).** No code path observes a
    running stream described by a stale topology cache; mutation
    follows quiesce, rebuild, resume in that order.
  - **Setup.** With a stream running, trigger a topology rebuild
    (forced codec reset or a hotplug fault-injection knob; see
    harness requirements). 
  - **MUST assert.** The sequence in the log is quiesce
    (stream stop confirmed), then rebuild, then resume, strictly
    ordered. At no observation point does a reader see the stream
    `runtime_active == 1` against a topology slot that is
    mid-rebuild.
  - **MUST NEVER observe.** A reader snapshot in which an endpoint's
    topology fields changed while `runtime_active` remained 1
    across the change (stream live over a topology edit).
  - **Failure interpretation.** The quiesce-rebuild-resume ordering
    (3.1) is violated; the cache can be stale relative to live DMA.

### G5. Sole cross-domain ordering primitive

  - **Method.** STATIC.
  - **Property (ADR 0031 6.1, 6.2, 6.6, gate 5).** The only
    cross-domain ordering primitive is the SeqCst `last_event_seq`
    store; the seqlock is the only intra-region primitive; no third
    mechanism is relied upon.
  - **MUST assert.** No lock (mutex, sx, spin) is acquired across
    both a state-region write and an events-ring write on the
    publish path. The seqlock brackets region writes; the SeqCst
    store crosses to the ring.
  - **MUST NEVER observe.** A newly added "safety" acquire lock
    bracketing region and ring (the fence re-add, ADR 0031 6.6).
  - **Failure interpretation.** A second cross-domain primitive
    exists; by 6.2 it is a defect by definition.

### G6. Causal direction of the watermark

  - **Method.** CONCURRENT.
  - **Property (ADR 0031 6.4, gate 6).** `last_event_seq` is a
    state-visibility watermark, published last; a reader that
    acquire-loads `last_event_seq == N` then reads the dynamic
    fields sees state at or after N, never before.
  - **Setup.** Writer thread drives repeated state transitions
    (stream begin/end, format changes). Reader thread tight-loops:
    acquire-load `last_event_seq`, then seqlock-consistent read of
    the dynamic fields, then record the pair.
  - **MUST assert.** For every recorded pair, when
    `last_event_seq == N` reflects a format-change event N, the
    observed `current_format` is event N's format or a later one,
    never the pre-N format.
  - **MUST NEVER observe.** `last_event_seq == N` with dynamic
    state still at the N-1 value (the A/V-sync inversion).
  - **Failure interpretation.** The watermark is published before
    (or unordered with respect to) the field writes; 6.4 release
    ordering is broken. Also the positive case of the S2
    deliberate-weakening test.

### G7. State and event coherence (snapshot never leads ring)

  - **Method.** CONCURRENT.
  - **Property (ADR 0031 6.5, gate 7).** A reader may see the ring
    ahead of the snapshot, never the snapshot ahead of the ring.
  - **Setup.** Reader thread tight-loops: acquire-load
    `last_event_seq`, then read the ring's `writer_seq`, record the
    pair. Writer drives events at high rate (including a stall to
    flood telemetry).
  - **MUST assert.** In every recorded pair,
    `last_event_seq <= writer_seq`. For any `last_event_seq == N`,
    event N is present and readable in the ring.
  - **MUST NEVER observe.** `last_event_seq > writer_seq`, or
    `last_event_seq == N` with event N not yet in the ring.
  - **Failure interpretation.** The ring enqueue is not ordered
    before the watermark publish; 6.5 is violated and a reader can
    act on a transition whose delta record does not yet exist. Also
    the positive case of the S2 deliberate-weakening test.

### G8. Representation: confirmed-or-absent, no third state

  - **Method.** STATIC (no degraded field) plus BENCH
    (quiesce-failure withdrawal).
  - **Property (ADR 0031 3.2, 3.3, gate 8).** Only
    confirmed-present or absent is externally observable; on
    quiesce failure the endpoint is withdrawn, not flagged;
    internal pending-removal state never appears in the region.
  - **Setup.** STATIC: inspect the published region struct for any
    degraded / non-quiesced / pending field. BENCH: fault-inject a
    stop that will not confirm during a topology mutation.
  - **MUST assert.**
    - STATIC: the published region has no third-state field; the
      only endpoint conditions externally are present (slot
      populated, confirmed) or absent (slot unused).
    - BENCH: on quiesce failure the endpoint disappears
      (`endpoint_count` decremented, `inventory_seq` bumped) and
      does not reappear until a clean rebuild succeeds.
  - **MUST NEVER observe.** Any externally visible endpoint that is
    neither cleanly present nor absent; any `pending_removal` value
    leaking into the published region.
  - **Failure interpretation.** The prohibited third semantic class
    (structurally visible but semantically untrustworthy) has been
    reintroduced; 3.3 is violated.

### G9. Inventory linearizability (no split-brain)

  - **Method.** CONCURRENT (multiple concurrent readers).
  - **Property (ADR 0031 3.4, gate 9).** Inventory transitions are
    linearizable with respect to `inventory_seq`; no intermediate
    or split-brain membership is observable.
  - **Setup.** Writer drives repeated endpoint add/remove (via the
    mutation knob). Two or more reader threads each log
    (`inventory_seq`, membership-set) snapshots, taken seqlock-
    consistent.
  - **MUST assert.** All observations across all readers form a
    single total order keyed by `inventory_seq`: for a given
    `inventory_seq` value, every reader that observes it sees the
    identical membership set. Membership sets advance monotonically
    along `inventory_seq`.
  - **MUST NEVER observe.** Two readers at the same `inventory_seq`
    with different membership sets; a membership set inconsistent
    with the total order (an intermediate view).
  - **Failure interpretation.** Inventory updates are only atomic,
    not linearizable; 3.4 is violated and "eventually consistent
    inventory" has crept in.

### G10. Quiesce: synchronous, bounded, no retry, fail-closed

  - **Method.** STATIC (code shape) plus BENCH (fault-injected stop
    failure).
  - **Property (ADR 0031 3.2, gate 10).** Stop confirmation is
    synchronous and bounded with no retry; the controller's
    stop-confirmation mechanism and bound are documented; failure
    fails closed.
  - **Setup.** STATIC: confirm the stop path clears the run bit and
    reads back status within a bounded wait, with no retry loop and
    the bound documented as a measured controller property (not a
    hardcoded constant presented as portable). BENCH: fault-inject
    a stop that never confirms.
  - **MUST assert.**
    - STATIC: the stop-confirmation mechanism and its measured
      bound are documented; the wait is bounded; there is no retry
      loop.
    - BENCH: on a non-confirming stop, the transition aborts within
      the bound, the endpoint is withdrawn (G8), and no repeated
      stop-attempt traffic appears.
  - **MUST NEVER observe.** A retry loop on stop failure (repeated
    stop-attempt log lines, a new storm signature, S1), or an
    unbounded wait (hang).
  - **Failure interpretation.** Fail-closed with bounded
    synchronous stop (3.2) is violated; a retry loop is itself a
    new storm vector.

## Test-harness and fault-injection requirements

These are testability obligations on the implementation. Without
them the CONCURRENT and fault-injection gates cannot be closed, so
they are part of the change set, not separate work.

  - **Concurrent reader harness.** A userland test that maps the
    state region and the events ring, runs one or more reader
    threads doing seqlock-consistent snapshots, and records
    `(last_event_seq, writer_seq, dynamic fields, inventory_seq,
    membership-set)` tuples for offline checking against G6, G7,
    G9. Must be runnable against a writer driving high-rate
    transitions.
  - **Topology-mutation knob.** A fault-injection path (sysctl or
    debug ioctl) to force a topology rebuild while a stream runs,
    for G4 and G9. Compile-gated to debug builds.
  - **Stop-failure knob.** A fault-injection path to make stream
    stop fail to confirm, for G8 and G10. Compile-gated.
  - **Stall driver.** `playtone --stall` already exists (ADR 0017)
    and serves G3 case (b).
  - **Watermark-weakening build flag.** A throwaway compile flag
    that breaks the `last_event_seq` release/acquire ordering, for
    the S2 hidden-fence detector. Never shipped; exists only to
    prove the watermark is load-bearing.

## Coverage and traceability

| ADR 0031 gate | Property | Tests |
|---|---|---|
| 1 | Republish callers closed | G1, S1 |
| 2 | Reader audit closed | G2, (G6/G7/G9 cross-check) |
| 3 | Idle quiet | G3, S1 |
| 4 | Topology consistency | G4 |
| 5 | Sole cross-domain primitive | G5, S2 |
| 6 | Causal direction | G6, S2 |
| 7 | Coherence | G7, S2 |
| 8 | Confirmed-or-absent representation | G8 |
| 9 | Inventory linearizability | G9 |
| 10 | Quiesce fail-closed | G10, S1 |

Standing sentinels S1 (storm fingerprint) and S2 (hidden fence)
run across all scenarios, not just their nominal gate rows. S1 is
the regression detector for the original bug; S2 is the proof that
the new ordering primitive is the real one and no shadow fence
survives.

## What green means

When G1 through G10 pass with their MUST-assert conditions, none of
their MUST-NEVER sentinels fire across any scenario, S1 stays
silent throughout, and S2 fails as required under deliberate
weakening, the ten merge gates of ADR 0031 are discharged.
Remaining risk at that point is ordinary implementation
correctness within the specified contract, not specification
ambiguity and not a latent return of the storm.
