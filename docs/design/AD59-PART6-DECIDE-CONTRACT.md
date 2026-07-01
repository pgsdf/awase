# AD-59 Part 6: Decide Contract

Status: DRAFT CONTRACT.

This document defines the contract for the Decide responsibility (Part 4).
It is written before any code and is the acceptance criteria for the first
implementation of decide().

Decide is architecturally unique among the four responsibilities. The others
are intentionally mechanical: Discover observes, Bind resolves, Transfer
executes. Only Decide interprets. It is the single point in the pipeline
where meaning enters. Its contract reflects that: the negative obligations,
and in particular what Decide must remain ignorant of, carry as much weight
as the positive ones, because Decide is the one component with the standing
to overreach, and defining its ignorance is what keeps the architecture from
drifting.

The contract follows the pattern established by Discover's: positive
obligations, negative obligations, acceptance criteria. It is organized
around three questions.

## Purpose of Decide (recap from Part 4)

Decide evaluates policy and produces exactly one result: a role. Not a boot
environment, a role. Part 2 separates roles from implementations, and Decide
preserves that separation: its output is a role, and resolving that role to
an implementation is Bind's job, not Decide's.

## Question 1: what information may Decide use?

This defines Decide's input and the boundary with Discover.

  P1: Use only Discover's output. Decide's inputs are exactly the
      observations Discover returns. Decide evaluates policy over those
      observations.

  N1: Consult nothing else. Decide does not read loader state, environment
      variables, files, or any other source directly. If a piece of state
      matters to the decision, it is one of Discover's observations; Decide
      does not reach around Discover to obtain it. This is the enforcing
      other half of Discover's own boundary: Discover returns exactly
      Decide's inputs, and Decide consults exactly what Discover returns.
      Neither reaches past the seam.

## Question 2: what may Decide conclude?

This defines Decide's output.

  P2: Produce exactly one role. Decide evaluates policy over Discover's
      observations and returns a single role (for AD-59, the operating
      environment role: the Operational Role or the Recovery Role, or
      whatever the architectural roles become).

  N2: Never a boot environment. Decide does not name, choose, or return a
      boot environment or dataset. Resolving a role to an implementation is
      Bind's responsibility.

  N3: Never multiple candidates. Decide returns one role, not a ranked list,
      not a set of options, not a primary-and-fallback pair. Producing
      alternatives is a decision deferred, which is not deciding.

  N4: Never a retry or recovery algorithm. Decide is a single evaluation
      producing a single role. It contains no retrying, no looping, no
      fallback sequencing, no recovery procedure. Those are not part of
      selecting a role, and Transfer explicitly performs its action once
      without retries.

## Question 3: what must Decide remain ignorant of?

This is where Decide's contract most protects the architecture. The
strongest separations in this design have come from defining ignorance, not
only responsibility. Decide, as the interpreter, must not know:

  N5: Binding representation. Decide does not know how roles map to
      implementations, where that mapping lives, or in what form. It
      produces a role; how a role becomes an implementation is opaque to it.

  N6: Boot environments. Decide does not know which boot environments exist,
      their names, their datasets, or their contents. It reasons about
      roles, never about the concrete environments that implement them.

  N7: Loader implementation details. Decide does not know how the loader
      works, what primitives exist, or how the current mechanism (local.lua
      today, the Awase loader later) is built. It evaluates policy over
      observations and returns a role, in terms that outlive any particular
      loader.

  N8: Transfer mechanics. Decide does not know how control is transferred,
      what the loader primitive is, or what happens after a role is chosen.
      Its work ends when the role is produced.

Decide's ignorance of N5 through N8 is what lets the binding representation,
the set of boot environments, the loader, and the transfer mechanism all
change without touching Decide. It is also what keeps Decide portable into
the future Awase loader: a Decide that knew loader primitives or dataset
names would have to be rewritten; a Decide that knows only observations in
and a role out migrates unchanged.

## The symmetry across the four responsibilities

Decide's contract completes a symmetry that emerged, rather than being
designed, across the responsibility contracts:

  - Discover observes without interpreting.
  - Decide interprets without executing.
  - Bind resolves without deciding.
  - Transfer executes without reasoning.

Each performs exactly one transformation and remains ignorant of the rest of
the pipeline. That the symmetry emerged from writing the contracts
independently is a sign the decomposition is sound: correct seams produce
contracts that close cleanly with a "without X" clause, and the four such
clauses partition the pipeline exactly once.

## Acceptance criteria for decide()

An implementation of decide() is accepted if and only if:

  - it uses only Discover's output as input and consults no other state
    (P1, N1);
  - it produces exactly one role (P2), never a boot environment (N2), never
    multiple candidates (N3), and never a retry or recovery algorithm (N4);
  - it remains ignorant of binding representation, boot environments, loader
    implementation, and transfer mechanics (N5 through N8);
  - it is written to be portable into the future Awase loader: expressed in
    terms of observations-in and role-out, using loader-specific idioms only
    where essential, with a narrow interface.

## Dependency: the specific inputs and roles

Decide's contract is complete in shape. Two specifics are defined by their
own settled or pending work:

  - Decide's inputs are the observations Discover returns; enumerating them
    is the shared subject of this contract and Discover's, and is the
    information the recon began to characterize (loader-stage observable
    state that policy uses to select the environment, not AD-11's post-kernel
    machinery).

  - Decide's output roles are the AD-59 Part 2 roles (Operational Role and
    Recovery Role today; the architecture is role-invariant and admits
    more). Decide does not define the roles; Part 2 does. Decide selects
    among them.

With Decide's contract defined, Discover's returned fields and Decide's
consumed inputs are the same set, named once, from which both
implementations follow. Implementation order remains: define the shared
input set concretely, then implement discover() to return it and decide() to
consume it, each against its own contract.

Status: DRAFT CONTRACT; acceptance criteria for the first decide().

Bench: none (design contract).
