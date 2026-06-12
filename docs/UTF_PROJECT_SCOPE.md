# UTF / PGSD project scope

Status: Project-defining document, 2026-05-17. This is a
constitutional statement of what the project is. It is
**not** an ADR and not a subsystem document. Subsystem
ADRs may reference it; it references no subsystem. It is
placed at project-doc level deliberately so that project
identity is ratified here, in its own act, and never as a
side effect of a subsystem decision.

## Why this document exists

Across extended design work the same unresolved question
kept reappearing through unrelated subsystems (audio
codecs, HDMI, GPU output, ISA choice, firmware-blob
hardware): is PGSD a software project that consumes
hardware, or a project whose scope includes producing
hardware. While that question was implicit, every
subsystem replacement appeared existential the moment
commodity-hardware opacity arose, because "must eventually
own hardware" was being conflated with "must decide and
build hardware now." The recurring collapse was the signal
that the project lacked an explicit scope definition, not
that any individual subsystem was intractable.

This document resolves that question directly so it stops
being decided indirectly.

## The decision

PGSD's scope includes both software and hardware. The two
are sequenced into stages, not pursued simultaneously:

1. **Primary, near-term: software audio support for known
   chipsets, 2016 onward.** The immediate goal is
   supporting known audio hardware in software. This is
   where effort goes now.

2. **In-scope, non-urgent: hardware production.** PGSD's
   scope includes producing a hardware solution. It is
   explicitly **not urgent** and is **not** to be started
   preemptively or on a predicted timeline.

3. **The trigger, not a date.** The hardware stage is
   activated if and when audio firmware blobs actually
   become the obstacle to supporting known chipsets. The
   move into the hardware stage is driven by *observed
   obstruction*, not by a runway estimate or a forecast.
   Until that obstruction is observed, the project remains
   in the software stage.

## Operating posture in the interim (transitional, with a
characterized exit)

While in the software stage, the project depends on
commodity hardware and the platform's existing audio
support. This dependence is **transitional, not an accepted
permanent condition**. It is governed, not merely
tolerated:

- The exit condition is explicit and named: firmware-blob
  obstruction of known-chipset support is the trigger that
  moves the project into the hardware stage.
- Absence of progress is not a neutral steady state. If
  the project is depending on commodity/platform audio
  while blob obstruction is in fact occurring and the
  hardware stage has not been entered, that is tracked as
  architectural debt, not invisible equilibrium. The
  governing principle is `docs/UTF_ARCHITECTURAL_DISCIPLINE.md`
  ("Governance independence: why ownership, not just
  correctness") and its `hms(4)` precedent: tolerated
  dependence left unguided is how a transitional state
  silently becomes permanent. The trigger and the debt
  tracking exist specifically to prevent that failure
  mode here.

This is the structure that makes the staged scope
survivable: the commitment to hardware is unconditional,
its activation is explicitly conditional, and the two are
not conflated.

## What this decides, and what it does not

**Decides:**
- The project's scope includes both software and hardware
  (constitutional; no longer an open question).
- Software audio support for 2016+ chipsets is the primary
  near-term goal.
- Hardware production is in-scope, non-urgent, and
  trigger-activated by observed firmware-blob obstruction.
- Interim commodity/platform dependence is transitional
  with a named exit and tracked stagnation.

**Does not decide (deliberately out of scope here):**
- The mechanism of the hardware stage when it activates
  (select-and-drive commodity blob-resistant hardware vs.
  design/produce hardware). That is a later decision, made
  when the stage activates, with its own analysis. This
  document fixes *that the stage exists and what triggers
  it*, not how it is executed.
- Any ISA choice (amd64 / arm64 / riscv). Downstream of
  the mechanism decision above; not decided here.
- Audio subsystem specifics. Those live in the audiofs
  ADRs, which reference this document for the now-resolved
  scope question and must not re-decide it.

## Relationship to the audio record

The audio record (ADR 0008 §3a's open-concern note;
`audiofs/docs/audio-hardware-independence-constraints.md`)
previously recorded the project-identity question as
open and deliberately fenced it out of subsystem
documents. That question is now resolved here. The audio
record is reconciled to reference this document as the
resolved authority rather than carrying the question as
open. The structural rule is preserved: identity is
ratified in this project-level document; the audio record
points at it and does not itself decide it.
