# AD-56 Phase 0: Instrumentation Acceptance Criteria

Status: DRAFT DESIGN CONTRACT.

This document specifies ACCEPTANCE CRITERIA, not an implementation and not
a decision. It is a design contract: the properties every candidate
instrumentation design must satisfy before it can be evaluated. No
instrumentation design is proposed, compared, or selected here. Because no
decision is recorded, this is deliberately not an ADR; framing it as a
decision would let it drift toward a preferred implementation, and the
contract must stay agnostic to whatever passes through it.

## Purpose

Before investigating any previous failure or designing replacement
instrumentation, establish the properties any kernel instrumentation must
satisfy before it can be accepted.

These criteria are intentionally independent of any known failure
mechanism. They define the standard against which future designs are
judged, rather than being derived from a particular incident. This
document is written as though no failure had yet occurred: that is the
test of its generality. A reader who has never heard of any specific
incident should be able to derive and apply these criteria. If a past
incident could be reverse-engineered from this document, the document is
contaminated and has failed its purpose. References to specific
subsystems, compile flags, or symbols are therefore deliberately absent;
they belong to Phase A, whose job is to understand a specific incident.

## How to read the criteria

The criteria intentionally overlap. Several push toward the same
properties from different angles (bounded and separate; non-interference
and how it is proven). The overlap is deliberate: it lets a violation be
caught from more than one direction. A candidate design must satisfy ALL
criteria, not a deduplicated subset. Do not collapse them.

Two clusters are worth naming:

  - Containment cluster (AC-1, AC-3, AC-6, AC-7): instrumentation is
    bounded, local, architecturally separate from what it observes, and
    minimal in surface area.

  - Epistemics-of-non-interference cluster (AC-2, AC-5, AC-8, AC-9): what
    counts as KNOWING that instrumentation does not interfere. This
    cluster exists because non-interference is the property most easily
    asserted and least easily proven, and assertion from inspection is
    exactly the failure mode it guards against.

## Acceptance criteria

### AC-1: Explicit scope

Instrumentation shall have a clearly defined scope. Any effect outside
that scope requires explicit justification as part of the design.
Unintended system-wide effects are unacceptable.

### AC-2: Non-interference

Instrumentation shall not alter the observable behavior of the kernel
except by producing observations. The burden of proof lies with the
instrumentation design; assuming non-interference is insufficient.

### AC-3: Locality

Instrumentation should be implemented as locally as practical. Kernel-wide
compilation changes, global compile-time flags, and broad configuration
changes require explicit architectural justification. Local mechanisms are
preferred over global ones.

### AC-4: Reversibility

Removing instrumentation shall restore the original system behavior.
Instrumentation should not require unrelated code to be added or removed,
and its removal should not change unrelated generated output.

### AC-5: Evidence

Claims regarding instrumentation behavior shall be supported by evidence.
Inspection alone is insufficient to establish that instrumentation is
non-interfering.

### AC-6: Isolation

The mechanism used to observe the system should be architecturally
distinct from the functionality being observed. Observation should
introduce the smallest practical coupling to the observed subsystem.

### AC-7: Minimal surface area

Instrumentation should minimize the number of affected compilation units,
runtime paths, and configuration mechanisms. Reducing surface area reduces
opportunities for unintended interaction.

### AC-8: Falsifiability

The design shall permit experiments capable of disproving claims of
non-interference. If no practical experiment could reveal interference,
the claim of non-interference cannot be considered established.

### AC-9: Independence of validation

The evidence used to demonstrate that instrumentation is non-interfering
should, where practical, be independent of the instrumentation itself.
This is deliberately weaker than requiring independence always, because
perfect independence is not always achievable; but it pushes the design
toward external confirmation rather than self-certification. A mechanism
that establishes confidence should not, where avoidable, be part of the
thing whose correctness it is establishing.

## Out of scope

This document does not:

  - identify any previous perturbation mechanism,
  - propose an instrumentation implementation,
  - compare implementation alternatives,
  - recommend a preferred design.

Those activities belong to later phases.

## Next phases

Once these acceptance criteria are ratified:

  Phase A: investigate the mechanism responsible for a previous
    perturbation. Distinguish verified evidence from hypothesis. The
    smallest change sufficient to reproduce a perturbation is the goal,
    so that the mechanism is isolated rather than assumed.

  Phase B: design replacement instrumentation that satisfies every
    acceptance criterion above. The resulting invariants follow from two
    sources: these acceptance criteria, and the evidence collected in
    Phase A. Validate the design with evidence, not assumption.

Implementation begins only after Phase B.

## Note: a possible unifying principle (not pursued here)

AC-9, and the epistemics cluster generally, echo a discipline emerging
elsewhere in the project: a mechanism used to establish confidence should
not itself become part of the thing whose correctness it establishes.
Stated from two directions, this reads as "promotion requires independent
verification" and "observation requires independent non-interference."
Whether this deserves its own foundational statement is explicitly NOT
pursued here, to preserve the discipline of one active architectural
uncertainty at a time. It is noted only as a thread to revisit after this
AD-56 work is complete, when the concrete instance can inform whether the
general principle merits its own document.
