# AD-59 Validation Review: Part 3 experiments against Part 2 architecture

Status: VALIDATION REVIEW.

This document answers exactly one question: do the completed Part 3
experiments require any architectural changes to the Part 2 bootstrap
architecture?

It does not modify Part 2. Part 2 remains exactly the architectural
proposal it was before experimentation. This review is the bridge between
Part 2 (what was believed before experimentation) and the implementation
design (what will now be built). It records what the experiments
established and what, if anything, that requires of the architecture.

## Scope of what the experiments tested

Experiments 3 and 4 tested a single foundational assumption underlying the
Part 2 architecture:

  Does the loader provide a usable insertion point capable of redirecting
  boot-environment selection?

They did NOT test the architecture's higher-level decisions: roles, policy,
bindings, ownership, or the separation of responsibilities. Those decisions
stand or fall on whether the design remains coherent, which is a design
judgment, not an experimental result.

## What the experiments established

  - Experiment 3: local.lua executes before menu presentation and before
    kernel loading.
  - Experiment 4: the loader honors a boot-environment redirection
    initiated from local.lua, using the loader's own selection primitives.

Stated precisely: the foundational loader assumption underlying Part 2 has
been empirically confirmed. This is a claim about the prerequisite, not
about the architecture as a whole. The insertion point the architecture
assumed exists, and it behaves as the architecture requires.

## Effect on the Part 2 open questions

The evidence adds CONSTRAINTS to some open questions. It does not supply
SOLUTIONS. A constraint narrows the design space; a solution chooses within
it. The experiments narrow; they do not choose.

  Q1: how does the bootstrap read the binding?
    New constraint: the binding must be readable at loader time and
    accessible from local.lua. The evidence does not say how the binding
    should be represented. Recorded as a design constraint, not a partial
    solution.

  Q2: where is the binding stored?
    New constraint: the storage must be readable by the loader before
    kernel load. The evidence does not favor one storage mechanism over
    another. A constraint, not a mechanism.

  Q3: how is recovery requested (the trigger)?
    Observed capability: the loader environment supports interactive input
    (io.getchar) if a design later chooses to use it. This is NOT a
    candidate trigger solution. io.getchar proved useful for
    instrumentation; it has not been shown to be the right recovery
    trigger. A recovery trigger has requirements the experiments did not
    address: timeout semantics, unattended boot, automation, serial
    consoles, remote management, and interaction with autoboot. Whether the
    trigger should be interactive at all remains an open design question.

  Q4: how does AD-58 promotion update the binding?
    No new evidence. The experiments concerned the read/select side (the
    bootstrap), not the write side (promotion). This question is as open as
    it was.

## Conclusion

  - The foundational loader assumption underlying Part 2 has been
    empirically confirmed.
  - No architectural changes are required at this stage.
  - Several open questions have gained additional constraints (Q1, Q2) or a
    recorded observed capability (Q3); one (Q4) is unchanged.
  - Implementation design may proceed.

Part 2 is unchanged by this review. The architecture remains the proposal
it was; the experiments confirmed one of its prerequisites without altering
it.

## Note

No architectural changes were made solely because experimentation
succeeded.

This is recorded deliberately. A common failure is to let a successful
experiment creep into redesign, which blurs whether the architecture was
ever predictive. Here the experiments confirmed an assumption without
altering the architecture, which means the Part 2 design was predictive
rather than retrospective: it correctly anticipated the loader capability
before that capability was tested. The investigation reduced uncertainty
without causing architectural churn, a sign that the design work and the
experimental work were properly separated.
