# Audio hardware-independence constraints (pre-ADR boundary note)

Status: Boundary note, 2026-05-17. This is deliberately
**not an ADR**. It has no ADR number, is not part of the
ADR lineage, and nothing in the ADR sequence should
reference it as a dependency. Its placement outside
`adr/` is intentional and structural, not incidental.

## Why this is a note and not an ADR

A subsystem ADR must not become the vehicle through which
project identity is implicitly ratified. An audio ADR that
recorded the project-identity question (whether PGSD's
scope includes hardware production) - even as an
explicitly provisional or attributed "pending position" -
would still create an edge in the decision-record graph
from a subsystem decision to a meta-architectural one. The
risk is not wording; a clear "pending ratification" label
does not remove it. The risk is structural: it couples
subsystem design to an unratified identity axis, and that
coupling is what must be prevented.

This note therefore records only what is stable
independent of that question, and explicitly fences the
rest out of its scope - not as deferred-within-scope, but
as not addressed here at all.

## Layer 1: stable audio system constraints (recorded)

These hold regardless of how the implementation fork or
the project-identity question resolve. Each is invariant
under "select hardware" and "produce hardware" alike, and
under "PGSD is hardware-producing" and "PGSD is not"
alike. That invariance is the test for belonging in this
layer; anything failing it does not belong here.

1. **No firmware-mediated DSP control in the audio path.**
   The audio signal path must be free of
   firmware-controlled DSP processing, mixing, resampling,
   spatialization, or enhancement. Hardware's role is
   limited to moving raw audio between memory and the
   converters. (This is the ADR 0007 physics/semantics
   boundary holding at the hardware level; it is stated
   here as a constraint, not re-decided.)

2. **OS retains pipeline authority.** The audio hardware
   in use must be selectable or designable such that the
   operating system, not hardware firmware, remains the
   sole authority over the audio pipeline. The constraint
   is on the property (OS retains authority), not on the
   means of achieving it.

3. **Feasibility must not depend on external OS audio
   stack evolution.** Whether UTF's blob-free audio path
   is feasible must not be contingent on FreeBSD (or any
   external party) taking timely action on the
   firmware-blob trend, on `sound(4)`/`uaudio` evolution,
   or on any external roadmap UTF does not control. This
   is the governance-independence principle
   (`docs/AWASE_ARCHITECTURAL_DISCIPLINE.md`) applied to the
   feasibility question; it is referenced, not newly
   decided here.

These three are safe to record because each is true under
every resolution of the questions below.

## Layer 2: implementation mechanism (NOT addressed here)

How Layer 1 is achieved - the choice between a
hardware-selection strategy and a hardware-production
strategy - is **out of scope for this note**. It is not a
decision object yet, and this note neither makes it,
frames it, nor records a position on it. It is named here
only to fence it: a reader must not infer any mechanism
from Layer 1.

## Layer 3: project identity (RESOLVED in the project-scope
charter, referenced here, not decided here)

Whether PGSD's scope definition includes hardware
production is a meta-architectural, project-identity
question. When this note was written it was deliberately
not addressed here. It has since been resolved as its own
deliberate act in `docs/AWASE_PROJECT_SCOPE.md` (PGSD's
scope includes both software and hardware, sequenced into
stages, with the hardware stage trigger-activated by
observed firmware-blob obstruction). This note now
*references* that resolution; it still does not decide,
restate, or re-derive it. The structural rule is intact:
identity was ratified in the project-scope document, not
in this subsystem note. A reader needing the decision goes
to the charter; this note carries a pointer, not a copy,
and therefore still creates no subsystem->identity
ratification coupling.

## What a future reader should take from this

The audio system has firm, stable constraints (Layer 1).
It also has a real implementation fork (Layer 2) and the
project-identity question (Layer 3) is resolved in
`docs/AWASE_PROJECT_SCOPE.md`. Layer 1 is recorded. Layer 2
is deliberately not recorded here and its absence is
intentional: this note exists to
let the stable constraints be written down without
binding them to the unresolved questions. The absence of
ADR 0009 is also deliberate; an ADR at this point would
create the coupling this note exists to prevent.
