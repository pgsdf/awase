# AD-59 Part 8: Transfer Contract

Status: DRAFT CONTRACT.

This document defines the contract for the Transfer responsibility (Part 4).
It is written before any code and is the acceptance criteria for the first
implementation of transfer().

Transfer executes without reasoning. It takes the boot environment Bind
resolved and transfers control to it, once. It is the simplest of the four
responsibilities: it makes no decisions, evaluates no policy, and performs
no resolution. Its single transformation is boot environment in, control
transferred.

The contract follows the pattern of the other responsibility contracts:
positive obligations, negative obligations, acceptance criteria.

## Purpose of Transfer (recap from Part 4)

Transfer invokes the loader primitive demonstrated in Part 3 Experiment 4,
once. No retries, no loops, no fallback logic, no recursive decision making.
It transfers control a single time and continues normal loader execution.
Part 3 Experiment 4 established the exact primitive: the public loader
sequence that redirects the boot environment (the sequence bootenvSet
performs), which was demonstrated to redirect the boot when invoked from the
loader hook.

## Question 1: what information may Transfer use?

  P1: Use the boot environment from Bind, and nothing else. Transfer takes
      exactly one boot environment (Bind's output) and acts on it.

  N1: Consult nothing about how the boot environment was chosen or resolved.
      Transfer does not see the role, the binding, Decide's reasoning, or
      Discover's observations. It receives a boot environment and transfers
      to it; everything upstream is opaque.

## Question 2: what may Transfer do?

  P2: Transfer control to the boot environment, once. Transfer invokes the
      loader primitive (the Part 3 Experiment 4 sequence) to select the boot
      environment Bind produced, and then continues normal loader execution
      so the selected environment boots.

  N2: Never retry. Transfer performs its action a single time. It does not
      retry on failure, loop, or attempt alternatives. This mirrors Part 4:
      Transfer is the single-shot action, and retrying or sequencing
      alternatives is explicitly not part of any responsibility.

  N3: Never decide or resolve. Transfer does not choose a boot environment,
      reconsider the one it was given, or resolve a role. Those are Decide's
      and Bind's responsibilities, complete before Transfer runs. Transfer
      acts on a given result; it produces none of its own.

  N4: Never fall back. If the transfer cannot be performed, Transfer does not
      substitute a different environment or invent a recovery path. It
      surfaces the condition. Fallback and recovery sequencing are not
      Transfer's role and are not part of the bootstrap (Part 4: the
      bootstrap is not a retry framework or recovery engine).

## Question 3: what must Transfer remain ignorant of?

  N5: Policy and reasoning. Transfer does not know why this boot environment
      was selected, what role it implements, or what state produced the
      decision. It knows a boot environment and the primitive that transfers
      to it.

  N6: The binding. Transfer does not read or know the role-to-implementation
      binding. It receives an already-resolved boot environment; resolution
      was Bind's job.

Transfer's ignorance keeps it a pure action: it neither reasons about the
environment nor resolves it, only transfers to it. Because the primitive it
invokes is loader-specific, Transfer is the one responsibility whose
IMPLEMENTATION is expected to differ most between the current loader and the
future Awase loader; but its CONTRACT (one boot environment in, control
transferred once, no retries, no fallback, no reasoning) is loader-invariant
and migrates unchanged. Only the primitive it calls is replaced.

## Acceptance criteria for transfer()

An implementation of transfer() is accepted if and only if:

  - it takes exactly one boot environment (Bind's output) and consults
    nothing about how it was chosen or resolved (P1, N1);
  - it transfers control to that boot environment once (P2), and continues
    normal loader execution so the environment boots;
  - it never retries (N2), never decides or resolves (N3), and never falls
    back to a different environment or a recovery path (N4);
  - it remains ignorant of policy, reasoning, and the binding (N5, N6);
  - it surfaces a failure to transfer rather than substituting or retrying
    (N4);
  - it uses the Part 3 Experiment 4 primitive sequence as the transfer
    mechanism on the current loader, and is structured so that only that
    primitive changes when the mechanism is later the Awase loader (a narrow
    interface isolating the loader-specific call).

## Note: the four contracts are complete

With Transfer's contract, the four responsibility contracts are drafted:
Discover (Part 5), Decide (Part 6), Bind (Part 7), Transfer (Part 8). Each
defines positive obligations, negative obligations, and acceptance criteria,
and each closes with the transformation it performs and its ignorance of the
rest of the pipeline:

  - Discover observes without interpreting.
  - Decide interprets without executing.
  - Bind resolves without deciding.
  - Transfer executes without reasoning.

One design step remains before implementation: enumerating the shared input
set concretely, that is, the specific loader-stage observations that Discover
returns and Decide consumes (the same set, named once). With that
enumeration, all four implementations follow from their contracts:
discover() returns the set, decide() consumes it to produce a role, bind()
resolves the role to a boot environment, and transfer() transfers to it,
each verified against its own contract and written to migrate into the
future Awase loader.

Status: DRAFT CONTRACT; acceptance criteria for the first transfer(). The
four responsibility contracts are complete.

Bench: none (design contract).
