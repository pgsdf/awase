# 0023 audiofs output DMA-boundary artifact: isolation by geometry

## Status

Accepted 2026-06-01; RESOLVED 2026-06-01 by experiment 1. The
boundary hum was caused by per-fragment interrupt servicing on
a slack-free 2-entry ring; deepening the ring removed it. A
depth sweep and an under-load test fixed the permanent depth
at 4 entries. See the Resolution section. Experiments 2 and 3
were not needed: experiment 1 both diagnosed and fixed the
artifact. The F.3 re-verification at non-750 tones (carried
over from ADR 0022) remains to be completed and recorded.

Successor to ADR 0022, which correctly localized a frequency-
selective output artifact but whose stated root cause (LPIB-
derived refill cursor causing stale-fragment replay) was
refuted by its own instrumentation. This ADR takes over the
open investigation with the defect localized to at or below
the DMA hardware programming, and proposes an isolation
experiment over the buffer geometry before any fix.

## Context

The artifact, established under ADR 0022 and not restated in
full here: a hum on output tones whose frequency is not an
integer multiple of the 46.875 Hz fragment rate (440, 660
hum; 468.75, 656.25, 750 are clean), digital, independent of
the userland write chunk size, with zero underruns
(`underflow_count` 0) and zero refill misses
(`refill_miss_count` effectively 0). A capture fork proved the
bytes committed to the DMA buffer are identical to what the
client generated (8192 frames byte-exact for 440). The entire
software path from write(2) through the user ring, the refill
copy, and the fragment boundaries is exonerated by
measurement. What remains is the hardware programming and
below.

The current output geometry (audiofs.c ~4161):

  - `AUDIOFS_BDL_ENTRIES` = 2
  - `AUDIOFS_BUF_BYTES`   = 8192 (fixed)
  - `AUDIOFS_BUF_FRAG_BYTES` = BUF_BYTES / BDL_ENTRIES = 4096
    = 1024 frames
  - IOC = 1 on every BDL entry (ADR 0016 Decision 6), so a
    stream interrupt fires at every fragment boundary: the
    fragment rate is 48000 / 1024 = 46.875 Hz, exactly the hum
    fundamental.

The leading hypothesis is now that the artifact is produced by
the per-fragment interrupt activity itself, not by anything
late or missing. IOC on both entries fires the BCIS ithread at
46.875 Hz; servicing it does synchronous work at the very
boundary the DAC is crossing (an LPIB read under hw_lock, the
refill copy, a DMA sync). On the 2-entry / 8 KB ring there is
no slack between the boundary and the servicing. If that
servicing perturbs the controller read or the codec link at
the boundary, by bus contention, an MMIO read stalling the HDA
link, or FIFO timing, it imprints at exactly the fragment rate
and is inaudible only to fragment-periodic tones. This is a
too-much-work-at-the-boundary hypothesis, not a missed-
deadline one; it is consistent with zero underruns and zero
refill misses, because nothing is late or dropped.

This connects to the question raised at the bench: whether the
absence of hard-realtime support is the cause. The refutation
of the deadline-miss mechanism (zero misses) argues that a
realtime guarantee would not help, because no deadline is
being missed. But the design that exists in the absence of any
separate timing mechanism, IOC every fragment on a minimal
ring, is precisely the suspect. It is a design-shape issue,
not a scheduling-class one.

## Decision

Isolate the cause by geometry before proposing a fix, because
ADR 0022 taught that a code-reading hypothesis here must be
measured, not trusted. The output geometry is already
parameterized off two constants that can be varied
independently, and they yield opposite predictions under the
interrupt-rate hypothesis:

1. Hold fragment size, deepen the ring (lower the interrupt
   rate). Raise `BUF_BYTES` and `BDL_ENTRIES` together so
   `BUF_FRAG_BYTES` stays 4096 (e.g. 8 entries x 4096 = 32 KB).
   The fragment rate stays 46.875 Hz but the interrupt fires
   on a ring with far more slack, and the refill runs many
   fragments behind the DAC. Prediction under the hypothesis:
   if the hum is boundary-servicing perturbation, more slack
   reduces or removes it; if the hum is intrinsic to the
   46.875 Hz boundary regardless of slack, it persists
   unchanged.

2. Hold buffer size, change fragment count (change the
   interrupt rate directly). With `BUF_BYTES` fixed, raise
   `BDL_ENTRIES` so fragments shrink and the interrupt rate
   rises (e.g. 4 entries x 2048 = the same 8 KB at 93.75 Hz).
   Prediction: if interrupt-servicing is the cause, the hum
   pitch tracks the new fragment rate (it should move from
   ~47 Hz toward ~94 Hz); if not, the hum is unchanged.

3. Reduce the interrupt rate without changing the buffer:
   set IOC on only some BDL entries. With more entries but IOC
   on every other one, the DMA still cycles the same buffer
   but the ithread runs at half the boundary rate. This
   separates "interrupt frequency" from "fragment geometry":
   if the hum tracks the IOC rate rather than the fragment
   rate, the interrupt servicing is implicated specifically,
   not the buffer layout.

The three are ordered cheapest-first and any one may settle
it. The decisive signal across all three: does the hum move
with the interrupt rate (implicating servicing) or stay locked
to a boundary regardless of interrupt rate (implicating
something in the DMA/codec datapath at the buffer wrap)?

Run each as an A/B against the known-bad 440 and the known-
good 750, with `refill_miss_count`, `refill_multi_count`, and
`underflow_count` read each time to confirm the change did not
introduce starvation (which would confound the audible
result).

Constraint to respect: the built-in sine-table fill assumes an
8192-byte / 2048-frame buffer to land exactly 750 Hz (audiofs.c
~4195, ~4424). Changing `BUF_BYTES` desynchronizes that table,
so geometry experiments must drive audio through the user-ring
path (playtone to /dev/audiofs0), not the built-in tone, and
the sine-fill constants must be either updated or recognized as
test-only and bypassed. This is a test-harness concern, not a
blocker; the user path is what matters.

## Resolution (2026-06-01)

Experiment 1 settled it. Deepening the ring to 8 entries
(32 KB, fragment size and 46.875 Hz fragment rate unchanged)
removed the hum: 440 and 660 played clean, 750 stayed clean,
and refill_miss/refill_multi/underflow stayed zero (one benign
startup miss). This both confirms the hypothesis and refutes
the alternatives: the cause was per-fragment interrupt
servicing on a slack-free ring, not a missed deadline (zero
misses), not starvation (zero underflow), and not the speaker.
Experiments 2 and 3 were therefore unnecessary as a search;
they remain available only as positive confirmation of the
mechanism if ever wanted.

Mechanism, stated as a measurement rather than a reading: on
the original 2-entry / ~42 ms ring the refill ithread ran at
the fragment boundary the DAC was crossing, with no slack
between them, and that per-boundary work perturbed the
controller read at the fragment rate. Distance fixes it: with
the refill running well behind the DAC, the boundary is
undisturbed.

Depth selection. A sweep found 3 entries (12 KB, ~64 ms)
already clean, both on the idle bench and under a CPU+bus load
test (4 cpu spinners + 4 dd bus-hammerers per the load
harness), counters flat at the one startup miss across six
8-second 440 Hz bursts. 4 entries (16 KB, ~85 ms) was chosen
as the permanent depth: clean with one fragment of slack
margin over the proven minimum, against load conditions the
bench cannot reproduce (other hardware, worse interrupt
latency, contention we did not generate), at a ~21 ms latency
cost over the minimum. The original 2-entry buffer was a
bring-up convenience; the replacement is chosen for robustness
rather than the smallest value that passes.

Fix as landed: geometry expressed fragment-first in audiofs.c
(BUF_FRAG_BYTES primary at 4096, BUF_BYTES = FRAG_BYTES *
BDL_ENTRIES), BDL_ENTRIES = 4. The refill cursor already wraps
modulo BDL_ENTRIES and the built-in sine fill computes its
frame count from BUF_BYTES, so no other code changed. ADR 0016
Decision 6 (IOC on every entry) stands; experiment 3 (reducing
IOC rate) was not needed.

## Rejected alternatives

  - Jump straight to a fix (deepen the ring, or move IOC, or
    switch to DPIB). Rejected: ADR 0022's fix-direction was
    aimed at a refuted cause. Measure which geometry variable
    moves the hum before committing a fix, so the fix targets
    the demonstrated cause.

  - Blame the absence of hard-realtime scheduling and pursue a
    realtime mechanism. Rejected as the primary line: the
    deadline-miss mechanism is refuted by zero misses. If
    experiment 1 shows more slack removes the hum, that is a
    buffer-depth fix, not a scheduling-class one.

  - Treat it as a codec/hardware quirk and document-and-move-
    on. Premature: the geometry experiments are cheap and at
    least one is likely to localize the cause or rule out the
    leading hypothesis decisively. Reserve this option for if
    all three leave the hum unmoved and locked to the buffer
    wrap, which would point genuinely below our programming.

## Consequences

  - One of the three experiments is expected to either
    localize the cause to interrupt servicing (hum moves with
    interrupt rate) or rule that hypothesis out (hum locked to
    a boundary regardless), redirecting toward the DMA/codec
    datapath at the buffer wrap.
  - A geometry change that removes the hum is plausibly also
    the fix (a deeper ring is independently desirable: it
    lowers interrupt load and adds timing margin, and the
    8 KB / 2-entry buffer was an early bring-up artifact). If
    so, this ADR's experiment becomes the basis for a fix ADR.
  - The built-in sine-table 750 Hz assumption must be updated
    or marked test-only as part of any permanent geometry
    change; tracked here so it is not forgotten.
  - ADR 0016 Decision 6 (IOC on every entry) is revisited by
    experiment 3; if IOC-rate reduction helps, that decision
    is amended.
  - F.5.a remains correct and independent (ADR 0021); its
    audible bench closure is gated on this artifact, but its
    mixer correctness is not in question.

## Closure criteria

  1. The hum's dependence on interrupt rate is measured: it
     either tracks interrupt rate across experiments 1-3
     (servicing implicated) or stays locked to the buffer wrap
     regardless (datapath implicated). Either is a definite
     result.
  2. `refill_miss_count`, `refill_multi_count`, and
     `underflow_count` are confirmed zero (no starvation
     introduced) for each geometry tested, so the audible
     result is not confounded.
  3. The cause is stated with the same standard ADR 0022's
     was retracted for lacking: a measurement, not a code-
     reading.
  4. A fix direction follows from the measured cause, to be
     recorded in this ADR or a successor.
  5. Operator confirms the measured result.

## Bench test plan

For each experiment, build with the changed constants, load,
and drive the user path (semasound stopped, playtone direct):

  1. Baseline confirm: `playtone --freq 750` clean,
     `--freq 440` hums (current 2x4096 geometry).
  2. Experiment 1 (8 entries x 4096, 32 KB, ~47 Hz, more
     slack): replay 440 and 750; note whether 440 changes.
  3. Experiment 2 (4 entries x 2048, 8 KB, ~94 Hz): replay
     440; note whether the hum pitch rises toward 94 Hz.
  4. Experiment 3 (more entries, IOC every other): replay
     440; note whether the hum tracks the halved IOC rate.
  5. Each step: read refill_miss_count, refill_multi_count,
     underflow_count; all must stay zero.
  6. Record which variable moved the hum.

## References

  - ADR 0022 (the localization and the refuted cause; the
    refill counters this ADR reuses).
  - ADR 0016 (F.3.c interrupt-driven position; Decision 6,
    IOC on every entry, revisited by experiment 3).
  - ADR 0015 (F.3.b write path) / ADR 0018 (F.4 clock) share
    the LPIB read but are not implicated by the artifact.
  - audiofs.c: geometry constants ~4161, BDL build ~4460,
    CBL/LVI programming ~4489, built-in sine-table 750 Hz
    assumption ~4195/~4424.

## Revision history

  - 2026-06-01: first draft. Takes over from ADR 0022 with the
    defect localized below the software path. Proposes three
    geometry experiments (deepen ring at fixed fragment size;
    shrink fragments at fixed buffer; reduce IOC rate) that
    give opposite predictions under the interrupt-servicing
    hypothesis, to be measured against 440/750 with the refill
    and underflow counters confirming no starvation. Notes the
    built-in sine-table 750 Hz geometry assumption as a test-
    harness constraint.
  - 2026-06-01: RESOLVED by experiment 1. Deepening the ring
    removed the hum (8 entries clean, counters flat),
    confirming the interrupt-servicing-on-slack-free-ring
    cause and refuting the deadline-miss, starvation, and
    speaker alternatives. Depth sweep found 3 entries the
    minimum clean depth (idle and under load); 4 entries
    chosen permanent for a one-fragment slack margin. Fix
    landed as BDL_ENTRIES = 4, fragment-first geometry.
    Experiments 2 and 3 not needed. F.3 re-verification at
    non-750 tones still outstanding.
