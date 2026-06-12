# 0008 Stage F scope and sequencing (AD-3 scheduling)

## Status

Accepted, 2026-05-17.

This is the scheduling ADR for AD-3 that ADR 0006 requires
("the first thing a future scheduling ADR for AD-3 must pin
down", ADR 0006 "What this does not address"). It follows
the model of `inputfs/docs/adr/0012-stage-d-scope.md` as the
audiofs proposal anticipates (proposal, "Related work").

It does not reverse, reopen, or amend the architecture
decided in ADRs 0002-0007. It schedules the work that
architecture implies, and it pins the sequencing so the
gap-and-governance audit (`audiofs/docs/snd4-gap-governance-audit.md`)
gates the irreversible scope commitment rather than being
overtaken by it.

Two scope inputs ADR 0006 names as mandatory for this ADR -
the specific chipset list and the long-term maintenance
model - are **not decided here**. They are recorded below as
explicitly owed decisions, not filled with plausible
defaults. An ADR that invented them would be exactly the
fabrication the governance-independence work this month was
careful to avoid. Stage F cannot pass its own gate (below)
until they are supplied.

## Context

F.0 (the architectural ADR set, 0001-0007) is complete. The
audiofs proposal anticipated that completion of F.0 is the
trigger for a scope ADR scheduling the rest of Stage F. That
is this document.

The defining constraint on this schedule, absent from the
Stage D precedent, is the gap-and-governance audit. ADR
0006's primary rationale (governance independence) is
principled and not measurement-contingent, but the audit
spec pre-registers that a weak audit result reopens the
narrower pcm-core-only option for explicit reconsideration.
A schedule that committed to the full per-chipset
driver-writing effort before that audit ran would contradict
a committed document. The schedule must therefore have a
fixed pre-gate part and a contingent post-gate part, and the
gate must be structural, not advisory.

## Decision

### 1. The audit is the gate, and it runs strictly first

The gap-and-governance audit specified in
`audiofs/docs/snd4-gap-governance-audit.md` is performed
before any audiofs implementation code is written, including
the F.1 skeleton. No Stage F code begins until the audit is
complete and its result read against its pre-registered
criteria.

This is deliberately stricter than running the audit in
parallel with the audit-independent F.1-F.2 scaffolding,
which would lose no architectural correctness (F.1-F.2 are
true in both the full and the pcm-core-only worlds). The
stricter ordering is chosen because the audit's designed
purpose is that its outcome may be inconvenient, and any
existing audiofs code becomes a sunk-cost argument in the
room when the result is read. Sequencing the audit strictly
first is the structural enforcement of the discipline the
audit spec states only in prose. The cost (F.1-F.2 are
small and their parallelism is forgone) is accepted as
insurance against the audit becoming theatre.

### 2. The gate's three outcomes bind the schedule

Per the audit spec's pre-registered criteria:

- **Strong support:** the contingent post-gate schedule
  (sections 4-5) proceeds as written.
- **Weak / no support:** Stage F does not proceed to F.3+
  on the current basis. A new ADR must explicitly either
  (a) re-justify full replacement on the principled
  rationale alone, with the weak empirical result recorded
  prominently, or (b) adopt the narrower pcm-core-only
  scope. This ADR does not pre-decide which; it requires
  that the choice be made explicitly and recorded, not
  defaulted into by momentum.
- **Mixed / unknown-dominated:** treated as not-strong for
  gating purposes. The thin evidence base is recorded and
  the section-2 weak-result path applies.

### 3. Mandatory scope inputs, owed before the gate

ADR 0006 requires this ADR to pin the chipset list and the
maintenance model. They are not invented here. They are
recorded as decisions owed by the project, and they are
made preconditions of the gate, not of post-gate work:

- **Owed: target chipset list.** The specific audio
  hardware audiofs will support, bounded by PGSDF's actual
  target machines, not by generality (ADR 0006 Decision 3).
  This must be a real enumeration of real hardware, not a
  representative-sounding list. Until it exists, the audit
  cannot scope "the snd(4) path on UTF's target hardware"
  concretely, so the gate cannot be evaluated.
  *(Discharged for the confirmed target in section 3a,
  2026-05-17. An earlier note here cited `pgsd-dev`; that
  was the wrong machine and is superseded. The confirmed
  target is `pgsd-bare-metal`; its codec enumeration is
  discharged from real dmesg (Cirrus Logic CS4206 analog;
  ATI R6xx HDMI). The scope rule is decided. This
  precondition re-opens, per the scope rule, only for any
  future confirmed-target machine. Read this bullet
  together with 3a.)*
- **Owed: maintenance model.** The long-term commitment
  model for indefinitely maintaining from-scratch
  per-chipset drivers (ADR 0006 "What this commits" states
  the burden bluntly; it does not state who carries it or
  how). A scope decision that omits this is incomplete by
  ADR 0006's own terms.

These two are gating preconditions: the audit's concreteness
bar (audit spec, "What the audit must produce") cannot be
met without the chipset list, and the maintenance model is
part of the governance assessment the audit performs. The
gate is not evaluable until both are supplied. This is
stated as a hard precondition rather than a TODO so that
"the audit came back fine" cannot be asserted over an
unscoped target set.

### 3a. Chipset scope: rule decided, codec enumeration discharged for the confirmed target

**Correction note (2026-05-17).** An earlier revision of
this section recorded controller-level targets from a
machine designated `pgsd-dev` (an ASUS B560 / Comet Lake
box: Intel 0xf0c8 PCH HDA, NVIDIA GP108 HDMI, Logitech
G433 USB audio). That was the wrong machine: it is not the
AD-3 confirmed target. None of that data was ever cited
outside this ADR and it is fully superseded here, not
amended. The correct confirmed target is `pgsd-bare-metal`
(the PGSD bare-metal machine: `FreeBSD 15.0-RELEASE-p8
PGSD`, drawfs/inputfs active, the machine the Phase 2.5
input verification ran on). This correction is itself an
instance of why codec/machine identities are held as
"not recordable until confirmed from the real machine's
own output": the prior Realtek-ALC family guess was
plausible and wrong for the actual target.

**Confirmed target machine.** `pgsd-bare-metal`: an Apple
machine (ACPI `<APPLE Apple00>`, i5-6500 Skylake, Intel
Sunrise Point chipset), running the PGSD kernel. This is
the sole confirmed first target. Support for further
machines is added later, per the decision below, as a
deliberate future act, not enumerated speculatively now.

**Scope rule (decided 2026-05-17, unchanged by the
machine correction).** audiofs targets HDA-class and
USB-audio-class devices, of 2016 or later vintage, on
PGSDF's confirmed target machines. This is the bound ADR
0006 Decision 3 requires ("bounded by target, not
generality"): a class-plus-vintage-plus-confirmed-machine
rule, not an open-ended "all modern audio hardware" set,
not a frozen list fixed years before F.3.

**Controller- and codec-level targets (confirmed from
`pgsd-bare-metal` dmesg, not inferred).** The codec
enumeration owed by the "owed: target chipset list"
precondition is discharged here for the confirmed target,
from the machine's own dmesg:

- Primary analog: Intel Sunrise Point HDA controller
  (`hdac1`) with a **Cirrus Logic CS4206** codec
  (`hdacc1`/`hdaa1`). Three pcm endpoints: internal analog
  speaker (pcm6), analog headphones (pcm7), digital
  (pcm8). This is classic HDA, not a firmware-pipeline
  design.
- HDMI: ATI Oland HDA controller (`hdac0`) with an **ATI
  R6xx** HDA codec (`hdacc0`/`hdaa0`), six HDMI pcm
  endpoints (pcm0-pcm5). This is the discrete-GPU display
  audio block; it is AMD/ATI, not NVIDIA. Any GPU-driver
  dependency framing must be assessed against the ATI/AMD
  display stack, not the NVIDIA framing from the
  wrong-machine revision.
- No USB audio device is present on `pgsd-bare-metal` in
  the confirmed boot. USB-audio-class remains a scope-rule
  device class but is not instantiated on this target.

The codec-enumeration action (`dmesg` on the real target)
is therefore **discharged for `pgsd-bare-metal`**. It
re-opens, per the scope rule, for any future
confirmed-target machine.

**Scope start and extension (decision owner, 2026-05-17).**
Start with `pgsd-bare-metal`; extend support to further
machines as needed going forward. Extension is not a blank
cheque: it is gated by the scope rule, the gate
(section 2), and the open concern recorded next.

**HDMI audio: in scope, consequence recorded plainly.**
HDMI audio (here the ATI R6xx path) is in AD-3 scope at
full guarantee. FreeBSD HDMI/DP audio depends on the GPU
display-driver stack being present and version-matched;
the recurring field failure is "analog works, HDMI
silent" when the display side is not driven. Recorded at
full volume, not hidden behind "drivers TBD", and
deliberately not overstated as an already-merged
AD-3/AD-4 scope:

1. HDMI audio remains in AD-3 scope.
2. Third-party GPU/display dependencies for the HDMI path
   are transitional, not accepted architectural
   exceptions, the same posture ADR 0006 takes toward
   snd(4) before audiofs exists.
3. Full long-term HDMI guarantee may require future
   UTF-owned display/GPU work overlapping AD-4.
4. The extent of that overlap is not yet scoped and is
   deferred. This ADR records the implication; it does
   not declare a merged AD-3/AD-4 scope, because that
   decomposition is not done.

**Ownability regime (technical gate, now informed by a
resolved project scope).** The confirmed target's audio is
classic HDA, the regime in which ADR 0006's write-our-own
ownership strategy is tractable. The industry has shifted
post-HDA audio toward Intel SST/cAVS, SoundWire, and
SOF-style DSP-firmware pipelines, where vendor-controlled
signed firmware and undocumented topology may make
software ownership infeasible. ADR 0006's software-ownership
strategy is established only for the classic-HDA regime;
its applicability to firmware-pipeline hardware remains a
technical gate on the "extend support as needed" clause
above: extension into non-classic-HDA hardware is gated on
resolving it, not permitted by default under ADR 0006's
existing justification. What has changed is that this is
no longer an *open-ended* risk: the project-scope decision
(below) defines what happens when blob obstruction is
actually encountered, so this gate now has a defined
disposition rather than being an unresolved cliff.

**Project-identity question: RESOLVED (in the project-scope
charter, referenced here, not decided here).** Whether PGSD
should include hardware production - and how that relates
to firmware-blob obstruction - was previously recorded
here as a foundational open question deliberately kept out
of the audio record. It has since been resolved as its own
deliberate act in `docs/UTF_PROJECT_SCOPE.md`: PGSD's scope
includes both software and hardware, sequenced into stages;
software audio support for 2016+ chipsets is the primary
near-term goal; hardware production is in-scope but
non-urgent and is trigger-activated if and when audio
firmware blobs become the actual obstacle to supporting
known chipsets; interim commodity dependence is
transitional with that obstruction as the characterized
exit trigger. This ADR *references* that resolution and
does not restate or re-decide it. The structural rule is
preserved: project identity was ratified in the
project-scope document, not in this subsystem ADR; this
note carries a pointer, not a copy. The earlier "extend
support as needed" clause is now read in light of the
charter: extension stays within classic-HDA software
ownership until blob obstruction triggers the charter's
hardware stage, at which point the mechanism is decided
separately per the charter (it is explicitly not decided
by this ADR).

### 4. Pre-gate sub-stages (audit-independent, may proceed)

These are valid regardless of the gate outcome and may be
scheduled without waiting on it. They are documentation and
decision work, not audiofs code:

- **F.scope.a** *(discharged for the confirmed target;
  re-opens per scope rule for future machines)*: the
  scope rule and the confirmed target's controller/codec
  enumeration are decided in section 3a, from real
  `pgsd-bare-metal` dmesg (Cirrus Logic CS4206 analog;
  ATI R6xx HDMI). No longer gating for `pgsd-bare-metal`.
  Re-opens, as the same dmesg-on-the-real-machine action,
  for any future confirmed-target machine added under the
  extend-as-needed decision.
- **F.scope.b** *(owed, gating)*: produce the maintenance
  model (section 3).
- **F.audit** *(gating)*: perform the gap-and-governance
  audit per its spec, against the chipset list from
  F.scope.a, read against the pre-registered criteria.
  Records strong / weak / mixed.

Nothing past this point is scheduled to start until
F.scope.a, F.scope.b, and F.audit are complete and the gate
in section 2 has been evaluated.

### 5. Post-gate sub-stages (contingent on a strong gate or an explicit section-2 re-justification)

Structure inherited from the proposal's Stage F breakdown,
expressed in the Stage D ADR's per-sub-stage form. Each is
landed and verified independently before the next begins, as
in Stage D. None of these is scheduled by this ADR to start;
this ADR fixes their order and their gate, not their dates
(the proposal explicitly excludes start dates and durations
from scope, and that holds here).

- **F.1** *(blocked on gate)*: audiofs kernel skeleton.
  Attaches to one PCM endpoint on a listed chipset,
  publishes `/var/run/sema/audio/state`, no audio data
  flow. Mirrors inputfs's USB-HID-first skeleton.
- **F.2** *(blocked on gate)*: stream lifecycle events ring
  (begin / end / xrun / format-change), per ADR 0007's
  physics-only constraint and its xrun tiebreak.
- **F.3** *(blocked on gate; the irreversible commitment)*:
  the audio data path. This is where per-chipset
  hardware-driver work actually begins and where the scope
  ADR 0006 commits to becomes real. The proposal flags F.3
  as the largest single sub-stage with the most unknowns;
  ADR 0006 flags it as the dominant risk. It should be
  decomposed further in its own sub-stage ADR before it
  starts. Native-format-only per ADR 0007; no semantic
  behaviour in the kernel.
- **F.4** *(blocked on gate)*: clock takeover. audiofs
  becomes the kernel writer of `/var/run/sema/clock`,
  reading the hardware position counter directly per ADR
  0003's mechanism and ADR 0006's hardware-owned read
  path. semaaud's clock-writer path compiled out only after
  audiofs's path is verified. Wire format unchanged
  (`shared/CLOCK.md`).
- **F.5** *(blocked on gate)*: semasound. The userland
  semantic audio system per ADR 0004 (single-writer mix)
  and ADR 0007 (it is the entire semantic layer:
  resampling, format, drift, timing prediction), with the
  rate-correction-not-position-correction constraint from
  ADR 0007 as a hard requirement.
- **F.6** *(blocked on gate)*: semaaud retirement, modelled
  on AD-2 (its own deliberate cutover, not an automatic
  consequence), once F.5 is verified.
- **F.7** *(blocked on gate)*: verification protocol.
  Rebuilt around hardware-level correctness per ADR 0006
  ("verified" for a from-scratch driver is a stronger
  claim than "we read snd(4)'s counter correctly"), not
  snd(4) semantic conformance. ADR 0003 section 8's
  per-version semantic-drift gate is subsumed (ADR 0006
  Relationship to ADR 0003): there is no external semantic
  to drift once UTF owns the hardware read path.

## Consequences

### What this commits

- A decided, gated schedule: F.0 done; chipset list and
  maintenance model owed and gating; audit gating and
  strictly first; F.1-F.7 ordered and contingent. AD-3's
  shape is now fixed; its start is not.
- The irreversibility boundary is named: F.3 is where the
  ADR 0006 commitment becomes real. Everything before F.3
  is either audit-independent decision work or
  reversible-by-not-continuing.

### What this does not address

- **Start dates and durations.** Excluded by the
  proposal's stated scope; excluded here. This ADR fixes
  order and gating only.
- **The chipset list and maintenance model themselves.**
  Owed (section 3), not decided here. This ADR makes them
  gating preconditions; it does not supply them, and
  deliberately does not invent them.
- **F.3's internal decomposition.** Flagged as needing its
  own sub-stage ADR before F.3 starts; not done here.
- **Whether the audit will pass.** Not pre-decided. The
  gate (section 2) binds all three outcomes including the
  one that reopens pcm-core-only.

### What this enables

- AD-3, when picked up, starts from a decided sequence with
  the premise-validation correctly placed first, rather
  than reopening any of it.
- The discipline that the audit's outcome is allowed to be
  inconvenient is now structurally enforced by sequencing,
  not only asserted in the audit spec's prose.

## Notes

AD-3 remains Open. This ADR does not change that and does
not schedule a start. It converts "AD-3 is architecturally
decided but unscheduled and ungated" into "AD-3 is
architecturally decided, sequenced, and gated, with the
gating preconditions explicitly owed." Scheduling a start
date is a separate act that requires F.scope.a, F.scope.b,
and F.audit to exist first.
