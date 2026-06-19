# 0031 audiofs state/event decoupling and topology split

## Status

Accepted, 2026-06-19: ratified by the operator as proposed,
including the post-review concurrency tightening (causal direction
6.4, coherence invariant 6.5, fence subsumption 6.6, quiesce
failure semantics 3.2, topology representation invariant 3.3, and
inventory linearizability 3.4). Acceptance authorizes the design
only. The implementation and its audit are separately gated: merge
remains blocked until the ten conditions in Section 8 are
discharged, per ADR-before-code discipline.

Proposed, 2026-06-19.

A defect-and-refactor ADR, not a milestone ADR. It records a
fault found during display-freeze bench work (the operator's
"squash all bugs" pass), localizes it to the F.1 state-publish
path crossed with the F.3.d xrun path, and specifies a contract
change to how the state region and the events ring relate. It
amends the publication model of ADR 0012 (F.1 state file) and
the event-coupling assumption carried since ADR 0013 (F.2 events
ring). It does not reopen ADR 0007's physics-only constraint,
ADR 0016's interrupt-position work, or ADR 0017's xrun detection
semantics; F.3.d's one-event-per-shortfall behavior is correct
and is retained unchanged.

ADR-before-code discipline holds. This ADR authorizes the design
and defines the merge gates; the implementation lands in separate
commits after operator ratification, in the same shape as prior
audiofs work (kernel change plus bench), with the audit gates in
this document discharged before merge.

This ADR has a hard dependency on a targeted audit (Section 7)
that is declared here but not claimed complete. Acceptance of the
design is contingent on that audit passing the conditions in
Section 8. The preliminary classification in Sections 5 and 7 is
derived from the current source tree and is authoritative for the
known call sites; it does not assert the audit is closed.

The design was tightened after architectural review to close the
concurrency edges where a correct-looking implementation can still
be causally wrong: causal direction of the watermark (6.4), the
state-and-event coherence invariant (6.5), fence subsumption
(6.6), quiesce failure semantics (3.2), the topology
representation invariant (3.3), and inventory linearizability
(3.4). These are specification closures, not new design.

## 1. Problem statement

dmesg on pgsd-bare-metal floods with `audiofs0: path_dead_end`
at the audio fragment rate (about 47 per second), and
`dev.audiofs.0.underflow_count` climbs at the same rate (measured
94 in 2 seconds, total above 350000, i.e. hours of continuous
underrun). The five cycling args (`0xc`, `0xd`, `0xe`, `0xf`,
`0x12`) are pins whose output-path walk dead-ends immediately;
each such walk is benign and expected for an input or digital
pin with no DAC route. The fault is not the dead-end. The fault
is the rate.

The storm is not one bug. It is the emergent product of two
layering violations stacked on a third condition:

  - **Violation 1 (forced recomputation).**
    `audiofs_state_republish()` rebuilds the entire state region,
    including a re-walk of the static codec topology
    (`audiofs_state_fill_output_endpoint` to `audiofs_path_from_pin`),
    every time it runs. Topology (pins, widgets, DAC paths,
    endpoint inventory) is fixed at attach and does not change
    while the controller runs. Republish therefore pays the cost
    of immutable-data reconstruction at the cadence of
    mutable-data change.

  - **Violation 2 (telemetry amplification).**
    `audiofs_events_publish()` calls `audiofs_state_republish()`
    on every event (Step 6, "keep snapshot and delta stream
    correlated"). Most events change no published state. An xrun
    is the clearest case: it is telemetry, not a state
    transition, yet it triggers a full republish.

  - **The condition (a stream running unfed).** An output DMA
    stream is running with no producer feeding it, so it
    underruns once per 1024-frame fragment forever (46.875 Hz).
    Per ADR 0017's amendment, F.3.d correctly emits one xrun
    event per shortfall.

Multiply F.3.d's correct per-shortfall events through Violation 2
and then Violation 1, and a single abandoned stream becomes 47
full topology re-walks per second. The `path_dead_end` flood is
that re-walk made visible.

Fixing the two violations makes the storm impossible by
construction, independent of why a stream is running or how often
it underruns. That is the scope of this ADR. The unfed-stream
condition is the subject of a separate ADR (forward pointer in
Section 9); it is the trigger, not the amplifier, and removing it
without fixing the amplifier would leave the system fragile to
any future high-frequency event source.

## 2. Design goal: failure legibility

This ADR has a goal beyond load reduction, and it is stated
explicitly because it justifies sequencing this work ahead of the
display-freeze investigation rather than after it.

The audio storm masks unrelated faults by saturating the kernel
log. The display freeze under investigation (scanout wedged, VT
switch dead, survives a semadrawd restart) has never been
observed on a clean dmesg, because `path_dead_end` buries whatever
the drawfs, vt, or efifb path would report at the instant the
scanout wedges. Removing the storm is therefore not only a
performance fix; it is a deliberate reduction of diagnostic
interference from an unrelated subsystem. We are trading
throughput-masking for failure legibility. After this ADR lands,
the display fault becomes observable for the first time.

This goal is normative: the design is required to leave the
kernel log quiet at idle, so that any message appearing during a
display freeze is attributable to the display path.

## 3. Decision A: split static topology from dynamic state

The state region is split, at the level of how it is maintained
(not its on-wire layout, which is unchanged), into:

  - **Static topology**, derived from the codec walk at attach:
    the controller inventory, the endpoint inventory, and within
    each endpoint slot the fields `endpoint_id`, `controller_idx`,
    `codec_addr`, `kind`, `direction`, `pin_nid`, `converter_nid`,
    `electrically_ready`, `rate_mask`, `bit_depth_mask`,
    `channel_mask`, and `name`, plus the header inventory fields
    `controller_count`, `endpoint_count`, and `inventory_seq`.
    Built once by `state_rebuild_topology()`.

  - **Dynamic state**, the closed enumerated set in Section 5,
    maintained by `state_update_dynamic()`, which walks nothing.

`state_rebuild_topology()` runs only on a genuine topology
mutation: attach, detach, and (when it lands) jack hotplug or
codec reset. It does not run on the event path. `audiofs_attach`
and `audiofs_state_unregister` are topology mutations and keep
their full build. `audiofs_events_publish` Step 6 does not call
either rebuild (see Decision B).

### 3.1 Topology-mutation lifecycle rule (quiesce, rebuild, resume)

Topology mutation correlates with exactly the failure modes that
matter: device reset, codec glitch, hotplug. "Topology is static"
is only safe if the behavior in the teardown and re-init window
is defined, because a cache that is stale relative to live DMA
state is unobservable until it bites.

Three models were considered:

  - **Race-and-version.** Allow the topology cache and DMA state
    to diverge transiently, reconciled by a version counter.
    Rejected. It buys concurrency this driver does not need and
    admits precisely the transient cache-to-DMA mismatch we are
    trying to make impossible to observe.

  - **Race, unversioned.** Rejected outright; this is the current
    implicit behavior's failure mode generalized.

  - **Quiesce, rebuild, resume.** On a topology change, quiesce
    any affected stream, rebuild the topology cache, then resume.
    **Chosen.** Topology only changes at reset or hotplug, which
    already implies stream disruption, so quiescing matches
    physical reality and keeps the cache and DMA state provably
    consistent: there is no window in which a running stream is
    described by a stale topology cache.

This is a first-class decision because it determines whether
transient topology-to-DMA mismatch can ever be observed. Under
the chosen rule it cannot.

### 3.2 Quiesce failure semantics (fail-closed)

Quiesce, rebuild, resume specifies the success path. The window
that touches hardware truth, rather than software structure, is
quiesce failure: a stream that will not confirm DMA stop. This is
defined, not left to the success path.

  - **Fail-closed, abort the transition.** If quiesce of an
    affected stream does not confirm DMA stop within a bounded
    synchronous wait, the topology rebuild does not proceed. No
    partial rebuild is permitted: the cache is never left
    half-rebuilt.

  - **Synchronous stop, bounded, no retry.** Stop confirmation is
    synchronous (clear the run bit, read back the status), not
    eventually consistent, because the whole point of quiesce is
    that no window exists in which live DMA is described by a
    half-rebuilt cache. The wait is bounded. Retries are
    prohibited: a retry loop on stop failure is how a new storm
    would be built.

  - **On failure, withdraw (do not flag).** The endpoint whose
    topology cannot be safely re-described is withdrawn from the
    published inventory per the representation invariant in 3.3,
    entering internal pending-removal state until a clean quiesce
    and rebuild succeeds, at which point it reappears. There is no
    degraded flag and no partial visibility.

The bounded stop-confirmation wait is an implementation-measured
hardware property, not an ADR constant. It varies by controller
revision and may differ under faulted DMA, so encoding a fixed
number would silently become fiction the moment either changes.
The ADR therefore treats the bound as a verification requirement
(the implementation MUST establish and document the controller's
synchronous stop-confirmation mechanism and its bound, and MUST
fail closed when it is not met), not as a parameter. Keeping it a
correctness boundary rather than a tunable prevents tuning culture
from creeping into what is a correctness boundary.

### 3.3 Topology representation invariant (normative)

This is a representation invariant of the topology graph, not a
device policy. The distinction is load-bearing: a policy invites a
later "small exception" the way fences get re-added, whereas a
violation of an invariant is a defect by definition.

> AudioFS represents only confirmed topology states. An endpoint
> is present in the published inventory if and only if its
> topology is currently confirmed correct. Uncertain,
> unconfirmed, or unquiesced topology is not represented as a
> valid endpoint; it is absent. There is no third externally
> observable state: an endpoint is confirmed-and-present or
> absent, never present-but-untrustworthy.

This deliberately removes the "structurally visible but
semantically untrustworthy" class everywhere, including the one
point that touches hardware. A degraded-but-present endpoint would
be exactly that third class, resolvable by no seq ordering, and is
prohibited. The model has no valid place for a "just add another
status flag" change, by construction.

  - **Internal pending state is permitted, externally invisible.**
    audiofs needs somewhere to hold a stream mid-withdrawal; an
    internal `pending_removal` (or equivalent softc state) MAY
    exist as a private reconciliation buffer but MUST NOT be
    visible in the published region. A reader observes an endpoint
    only as confirmed-present or absent, never the pending
    intermediate.

  - **Withdrawal and reappearance cross the reader boundary
    atomically.** Removing an endpoint (shift the slot out,
    decrement `endpoint_count`, bump `inventory_seq`) and adding
    it back on clean rebuild are seqlock-bracketed publishes; the
    internal pending state is reconciled behind that boundary.

  - **Consumer consequence is honest.** semasound observes the
    endpoint disappear and will treat it as hot-unplug-like. That
    interpretation is correct: an endpoint audiofs cannot safely
    describe is functionally unavailable, and "gone" is the
    truthful signal. The downstream-churn cost is the right risk
    to carry; the alternative is downstream acting on a false
    structural signal, which is the failure mode this ADR exists
    to eliminate. Withdrawal points MUST be logged (this folds
    into the failure-legibility goal, Section 2).

### 3.4 Inventory linearizability (normative)

The representation invariant requires more than per-slot atomicity
under the seqlock. Seqlock bracketing guarantees a single reader
never observes a torn slot; it does not by itself forbid two
concurrent readers from disagreeing about whether an endpoint
exists, nor does it forbid a later weakening into "eventually
consistent inventory updates." Both are closed here:

> Inventory transitions are linearizable with respect to
> `inventory_seq`. There is one total order of endpoint
> membership changes; every reader observes a prefix of that
> order. No reader observes intermediate membership, and no two
> concurrent readers observe a split-brain view of endpoint
> existence.

This ties the topology representation invariant (3.3) to the
ordering model: inventory membership is not merely atomic, it is
linearizable, and "eventually consistent inventory" is a
prohibited weakening.

## 4. Decision B: decouple event publication from state rebuild

Publishing an event updates the region's `last_event_seq` and
does nothing else to the state region by default. The events ring
is the sole delta channel. The state snapshot is refreshed only
by events that genuinely change published state.

  - **Telemetry events** (xrun is the canonical case) append to
    the events ring, advance the ring's `writer_seq`, and update
    the state region's `last_event_seq`. They do not call
    `state_rebuild_topology()` or `state_update_dynamic()` for
    content, because they change no dynamic field.

  - **State-transition events** (`stream_begin`, `stream_end`,
    format change) call `state_update_dynamic()` to refresh the
    closed dynamic field set, then advance `last_event_seq`. The
    format-change ioctl path, which currently calls a full
    republish, is reclassified to `state_update_dynamic()`.

  - **Inventory-change events** (controller or endpoint add and
    remove) call `state_rebuild_topology()` under the lifecycle
    rule in 3.1.

This is a semantic contract change, not an optimization, and is
recorded as such in Section 6.

## 5. Closed dynamic-state field set (normative)

`state_update_dynamic()` is permitted to write exactly the
following fields, and no others. This set is part of the
committed contract. A future field is in the static set unless
this list is amended to include it by a successor ADR.

  - Header, offset 16, `last_event_seq` (u64). Advanced on every
    event (see Section 6 for its precise semantics).
  - Endpoint slot, relative offset 13, `runtime_active` (u8). Set
    when a stream binds and runs on the endpoint, cleared on
    stop.
  - Endpoint slot, relative offset 14, `current_format` (u16).
    The HDA format word while `runtime_active` is 1; zero
    otherwise.

The `seqlock` (header offset 8) is not a dynamic content field;
it is the intra-region consistency primitive and is written as a
bracket around every update batch, static or dynamic, per
Section 6.2. `state_valid` (offset 5) is set once at init and is
not on the per-event path.

## 6. Ordering contract (critical)

This section replaces an implicit, traversal-derived
synchronization behavior with two explicit, scoped primitives. It
is the part of the ADR most likely to prevent future regressions,
and it is normative.

### 6.1 The two ordering primitives, scoped and non-substitutable

  - **`seqlock` (header offset 8): intra-region read
    consistency.** The sole writer increments `seqlock` to odd
    before, and to even after, every batch update to the region
    (whether a full topology rebuild or a dynamic update).
    Readers retry while `seqlock` is odd or changes across a
    read. This primitive is retained unchanged. Removing republish
    does not remove the seqlock; the seqlock is the only thing
    that makes a multi-field region read consistent.

  - **`last_event_seq` (header offset 16, SeqCst): the sole
    cross-domain ordering primitive for state-snapshot to
    event-stream correlation.** It records the sequence number of
    the last events-ring event reflected by this snapshot. Its
    store is SeqCst and is the designated happens-before edge
    between the events ring and the state snapshot.

The two are scoped and non-substitutable: the seqlock orders
reads within the region, `last_event_seq` orders the snapshot
against the ring. Neither may be repurposed for the other's job.

### 6.2 Positive exclusivity invariant

State the replacement as a positive invariant, not as the
negative "republish is not a synchronization primitive," so that
no future change can reintroduce a fence under a different name
and call it harmless:

> `last_event_seq` (SeqCst) is the sole cross-domain ordering
> primitive for audiofs state-and-event correlation. No other
> mechanism (lock acquisition order, traversal completion,
> allocation, or the side effects of a region rebuild) may be
> relied upon to provide ordering or visibility between the state
> region and the events ring. Any such reliance is a defect.

### 6.3 The accidental equality this change breaks (normative warning)

Because republish currently runs on every event, the state
region's `last_event_seq` and the events ring's own `writer_seq`
advance together and are presently always equal. That equality is
accidental, a side effect of rebuild-on-every-event, and Decision
B breaks it deliberately:

  - After B, `last_event_seq` advances at state-transition density
    plus telemetry acknowledgement (it still moves on every event,
    to mark "snapshot is current as of event N"), but the snapshot
    content changes only at state-transition density.
  - The ring's `writer_seq` advances at full event density and is
    the true monotonic event count.

A reader that needs the count of events, or event-density as a
proxy for time progression, must read the events ring's
`writer_seq`, never the state region's `last_event_seq`, and must
never assume the two are equal. This is the single highest-risk
item in the reader audit (Section 7.2).

Decision on `last_event_seq` advance policy: it advances to the
latest ring `writer_seq` on every event publish (telemetry
included), so a reader can always learn "this snapshot reflects
all state transitions through event N, and N is current." The
divergence in 6.3 is between snapshot content cadence and
`writer_seq`, not between `last_event_seq` and `writer_seq`; the
two seq values remain close, but a reader must still not treat
`last_event_seq` as a content-change signal. Content-change
detection uses `inventory_seq` (topology) and the seqlock-consistent
read of the dynamic fields, not `last_event_seq`.

### 6.4 Causal direction of `last_event_seq` (normative)

A SeqCst store can be correct in atomicity and wrong in causal
direction. The direction is pinned here so that a correct-looking
implementation cannot publish the watermark ahead of the state it
describes.

`last_event_seq` represents **state-visibility time, not event
issuance time.** It is a state-visibility watermark: the assertion
"this snapshot reflects events through N." It is published last,
never ahead of the state it describes.

  - For a state-transition event, the dynamic-field writes
    (Section 5) happen-before the `last_event_seq = N` store. That
    store is the release edge.
  - A reader loads `last_event_seq` with acquire and then reads
    the dynamic fields; it is thereby guaranteed to observe state
    at or after N.
  - Issuance-time semantics are prohibited: if `last_event_seq`
    advanced to N before the state mutation that event N
    represents were visible, a reader could observe
    `last_event_seq = N` with state at N-1. That is the A/V-sync
    inversion this ADR is built to prevent.

Telemetry events may advance the watermark because advancing it
asserts "no state change through N," which is a true statement
about visibility. The watermark thus never lies in either
direction: it never claims a state transition not yet visible, and
it never withholds acknowledgement of an event that changed
nothing.

### 6.5 State and event coherence invariant (normative)

Direction (6.4) fixes what the watermark means; this fixes what a
reader is permitted to observe across the region and the ring. The
allowed skew is one-directional.

> A reader MAY observe the events ring ahead of the snapshot (the
> ring holds event N while the snapshot is still at
> `last_event_seq = N-1`): the snapshot is merely catching up, and
> the ring is the authority for deltas. A reader MUST NEVER
> observe the snapshot ahead of the ring (`last_event_seq = N`
> while event N is not yet visible in the ring): that would let a
> reader act on a state transition whose delta record does not yet
> exist. Equivalently: `last_event_seq` never exceeds the ring's
> `writer_seq` in any single reader's timeline, and the snapshot
> content is always consistent with some prefix of the ring up to
> `last_event_seq`. The snapshot may lag the ring; it may never
> lead it.

This is enforced by ordering the ring enqueue before the
`last_event_seq` publish. It is the matching-snapshot definition,
and it is the A/V-sync hinge: the same care applied to never
letting presentation lead its source.

### 6.6 Fence subsumption (normative)

The prior cross-domain visibility guarantee came incidentally from
the republish path's lock acquire and release bracketing the
region write. This change removes that lock. The guarantee is now
carried, in full, by two mechanisms and no others:

  - the release-store / acquire-load pair on `last_event_seq`
    (6.4), for cross-domain visibility between region and ring;
  - the seqlock (6.1), for intra-region read consistency.

These two together subsume every visibility property the old
republish lock provided incidentally. This subsumption is stated
explicitly so that no one later adds "a small acquire lock for
safety": any further acquire lock introduced for cross-domain
ordering is redundant, and is itself the defect the positive
invariant in 6.2 prohibits.

## 7. Audit obligation (declared, not claimed complete)

This ADR declares the audit below as required work and defines in
Section 8 what would invalidate the design. The classification
here is preliminary, derived from the current tree, and complete
for the known call sites; it does not assert closure.

### 7.1 Known republish callers (current tree)

  - `audiofs_state_register` (attach path). Legitimate full
    build. Becomes `state_rebuild_topology()`. Retained.
  - `audiofs_state_unregister` (detach path). Inventory mutation.
    Becomes `state_rebuild_topology()` under the 3.1 lifecycle
    rule. Retained.
  - `audiofs_events_publish` Step 6 (every event). The amplifier.
    Removed from the content path per Decision B; replaced by a
    `last_event_seq` advance plus, for state-transition events,
    `state_update_dynamic()`.
  - Format-change ioctl handler. State transition
    (`current_format`). Reclassified from full republish to
    `state_update_dynamic()`.

An obligation of the implementation is to confirm, by grep over
the merged tree, that these are the complete set of republish
callers and that none remain on the per-event content path.

### 7.2 Known state-region readers and the dependency to disprove

The state region is read by userspace consumers (principally
semasound; also any diagnostic tooling). The compositor reads the
clock region, not the state region, and is not a reader here. For
each reader, the audit must disprove reliance on any of:

  - `last_event_seq == writer_seq` (the accidental equality, 6.3).
    Highest risk.
  - republish frequency, or snapshot refresh rate, as a proxy for
    time progression or event density.
  - any ordering or visibility between region and ring not carried
    by the SeqCst `last_event_seq` store (6.2), for example an
    assumption that "after the region changes, ring event N is
    visible" derived from the old rebuild's traversal or lock
    acquisition.

If a reader relies on any of these, the defect is fixed in the
reader (it should use the ring's `writer_seq` for counts and the
SeqCst `last_event_seq` for correlation), not by retaining
rebuild-as-fence.

## 8. Merge gates (blocker conditions)

The design is accepted in principle on ratification, but merge of
the implementation is blocked unless all of the following hold:

  1. Republish-caller audit closed: the four callers in 7.1 are
     the complete set in the merged tree, and none remains on the
     per-event content path.
  2. Reader audit closed: every state-region reader is confirmed
     free of the dependencies in 7.2, or each such reader is fixed
     in the same change set.
  3. Idle quiet: at idle with no stream, the kernel log emits no
     `path_dead_end` and no per-fragment audiofs event traffic
     (the failure-legibility goal, Section 2).
  4. Topology consistency: under the 3.1 quiesce-rebuild-resume
     rule, no code path can observe a running stream described by
     a stale topology cache.
  5. Ordering: the only cross-domain ordering primitive in the
     merged audiofs is the SeqCst `last_event_seq` store; the
     seqlock remains the only intra-region consistency primitive;
     no third mechanism is relied upon.
  6. Causal direction: `last_event_seq` is published last, with
     dynamic-field writes release-ordered before its store and
     reader acquire-load before field reads (6.4); no code path
     advances the watermark ahead of the state it describes.
  7. Coherence: no reader can observe the snapshot ahead of the
     ring; the ring enqueue is ordered before the `last_event_seq`
     publish (6.5).
  8. Representation: no externally observable endpoint state exists
     other than confirmed-present or absent; internal
     pending-removal state is never visible in the published region
     (3.3); on quiesce failure the endpoint is withdrawn, not
     flagged (3.2).
  9. Linearizability: inventory membership transitions are
     linearizable with respect to `inventory_seq`; no intermediate
     or split-brain membership is observable (3.4).
 10. Quiesce: stop confirmation is synchronous and bounded with no
     retry, and the controller's stop-confirmation mechanism and
     bound are documented (3.2). Failure fails closed.

A violation of any of 1 through 10 blocks merge.

## 9. Forward pointers

  - **Stream-lifecycle hardening (successor ADR, instrument-only
    first).** The unfed-stream condition (Section 1) is the
    storm's trigger. Its fix is gated on a measurement (what holds
    `/dev/audiofs0` open while it starves) and is sequenced as:
    (a) instrumentation only, counters plus a log line for
    "underrun with no write-owner," no enforcement; (b) measure on
    the bench whether the abandoned-with-no-owner condition holds;
    (c) only then decide whether enforcement belongs in the kernel
    (gated on explicit no-writer-ownership, never on underrun
    count alone, to avoid evicting a slow-but-live producer under
    scheduler jitter) or in semasound's supervision. This ADR does
    not author that policy.

  - **Display-freeze investigation (unblocked by this ADR).** With
    the log quiet (gate 8.3), reproduce the freeze on a clean
    buffer and read the drawfs, vt, and efifb path at the instant
    the scanout wedges. The standing candidate is the
    framebuffer-ownership gap in drawfs ADR 0001 (AD-10, two
    drivers mapping one EFI framebuffer with no protocol), but its
    documented symptom is corruption, not a hard freeze with dead
    VT switching, so it is a suspect to confirm against evidence,
    not a design to commit to now.

## 10. Consequences

  - The storm cannot exist after A and B: a pathological event
    rate produces cheap ring appends and `last_event_seq` stores,
    not topology walks. The system becomes robust to event
    frequency by construction.
  - The kernel log is quiet at idle, making unrelated faults
    legible.
  - A semantic contract changes: the state snapshot is sampled at
    state-transition density with the events ring as the sole
    delta channel, and `last_event_seq` is no longer a content
    change signal. Readers are audited against this per Section 7.
  - Two explicit ordering primitives replace an implicit
    traversal-derived one, closing the path by which a future
    "small harmless fence" could reintroduce the coupling.
  - The system model is compressed from three externally
    observable topology states (valid, degraded, absent) to two
    (valid, absent). This is the deeper reason the design is robust
    under load: the interpretive layer that was previously doing
    accidental synchronization work (degraded-but-present devices,
    republish-as-fence, rebuild-as-signal) is removed, not merely
    made faster. What remains is not a performance fix but a
    semantic compression of the system model, and there is no valid
    place left in it for a third state or a soft-coupling flag.
