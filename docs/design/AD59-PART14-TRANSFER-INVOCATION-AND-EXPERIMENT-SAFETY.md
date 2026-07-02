# AD-59 Part 14: Transfer Invocation (Decision Record)

Status: RATIFIED (operator, 2026-07-02); drafted 2026-07-02.

This is a decision record. It records an architectural decision that affects
Parts 8 and 13: whether Transfer runs on the Operational path. It states the
alternatives considered, their consequences, the rationale, and the decision
reached, so the reasoning is preserved and not merely the outcome. It also
lays out the safety design for the Transfer experiment as a plan. No
transfer() code accompanies this record; the implementation follows from the
decision below.

Transfer is the one responsibility that acts. Discover, Decide, and Bind
observe, interpret, and resolve, and their experiments could pause and print
with no effect on the boot. Transfer invokes the loader redirect primitive
(Part 8 P2, the Part 3 Experiment 4 sequence), which changes where the boot
goes. That difference is why this note exists: the question of when Transfer
runs, and the design of an experiment that cannot strand the bench, are
worth settling on paper before code.

## The decision: does Transfer run on the Operational path?

On the Operational path the destination the driver holds equals
selected_boot_environment: the boot environment the loader has already
selected (Part 13). The question is whether transfer() invokes the redirect
primitive against that already-selected boot environment, or whether the
driver recognizes "destination equals current selection" and continues
normal loader execution without calling transfer() at all.

Both alternatives considered are set out below with their consequences,
followed by the rationale and the decision.

### Option A: Transfer runs only when redirecting

Transfer is the act of CHANGING the boot target. The Operational path does
not change it: the loader already points at the selected boot environment,
and Part 8 P2 already describes Transfer as continuing normal loader
execution. Under Option A, "continue normal loader execution with no
redirect" is the whole of the Operational path, so transfer() is not called.
The driver invokes transfer() only when the destination differs from the
loader's current selection, which today is only the resolution path
(Recovery and future roles requiring resolution).

Consequences:

  - The redirect primitive, including loader.perform("unload"), never runs
    on the Operational path. That path is the common one (every boot with no
    recovery request), so the risky mechanism stays off the common path
    entirely, running only when the boot is genuinely being redirected.

  - The driver gains one comparison: is the destination the already-selected
    boot environment? If yes, continue; if no, transfer(). That comparison
    lives in the driver (composition, Part 13), not in Transfer, so Transfer
    stays ignorant of selection state (Part 8 N1, N5).

  - Transfer's contract is unchanged: when it IS called, it takes one boot
    environment and transfers once. Option A narrows WHEN it is called, not
    what it does. This mirrors how Part 13 made bind() conditional without
    changing Bind's contract.

  - One subtlety to state honestly: under Option A, the Operational path
    never exercises transfer() on the bench, because transfer() is not on
    that path. The Operational path's correctness is "the loader booted the
    selected BE normally," which Experiments 5 through 7 already show. So
    transfer() is exercised only by the redirect path, which needs a
    different-BE target to test (see the experiment design below).

### Option B: Transfer always runs; same-BE redirect is idempotent

Every path ends in transfer(), uniformly. The driver hands Transfer the
destination and Transfer invokes the redirect primitive regardless of
whether the destination equals the current selection. Redirecting to the
already-selected boot environment is treated as a redirect that happens to
land where the loader already pointed.

Consequences:

  - Uniformity: the pipeline is always discover -> decide -> (bind?) ->
    transfer, with transfer() unconditional. There is no driver comparison
    and no conditional call; the shape is regular.

  - The redirect primitive runs on every boot, including the common
    Operational path. That means loader.perform("unload") (when a kernel is
    loaded) executes mid-boot on every Operational boot, redirecting to the
    same boot environment. Whether that is truly harmless is an empirical
    question: re-running setenv and config.reload() against the current
    selection, then unloading and continuing, is expected to reach the same
    boot, but it is more work on the common path than Option A, and it
    exercises the redirect machinery where no redirect is needed.

  - Transfer needs no knowledge it lacks: it still takes one boot
    environment and acts. But the idempotent case (destination equals
    current selection) becomes a real execution path that must be shown
    harmless, rather than one that never runs.

  - This is the "idempotent redirect" case Part 13 noted does not reach
    Transfer's CONTRACT. Option B makes it reach Transfer's EXECUTION: the
    contract is still satisfied, but the same-BE redirect is now a thing
    that runs and must be validated.

### Rationale for the decision

The decision is Option A, and the architectural justification is not that it
avoids calling unload. That is a practical benefit, not the reason. The
reason is that Option A preserves the separation of responsibilities AD-59
has steadily converged toward, and Option B quietly breaks it.

The responsibilities now read cleanly:

  - Bind answers: where should this role execute?
  - Dispatch answers: which implementation satisfies this role?
  - Transfer answers: change execution to another boot environment.
  - The bootstrap driver answers: given the current state, which of those
    responsibilities are actually required?

Under Option A, transfer() retains a single narrow responsibility: perform a
transition. If no transition is required, there is nothing for Transfer to
do. The determination that no transition is necessary belongs to the driver,
because only the driver holds both pieces of information the determination
needs: the currently selected boot environment and the destination Bind and
Dispatch produced. This is the same information-locality argument that placed
the role dispatch in the driver (Part 13): the component that holds both
inputs to a decision is the component that makes it.

Under Option B, Transfer subtly acquires a second responsibility. It is no
longer only "perform a transition"; it must also determine whether the
requested transition is effectively a no-op. That looks small, but it
broadens Transfer from executing transitions to managing transition
semantics, that is, reasoning about whether a transition is real. AD-59 has
consistently narrowed responsibilities rather than expanded them, and Option
B expands one.

There is also a consistency with Part 13 that is more than aesthetic. Part
13 established the principle: resolve only what is not already known. Option
A extends the same principle one stage later: transfer only when a transfer
is actually required. That is the same architectural discipline expressed at
the next layer of the pipeline. Every stage performs exactly the work that
remains to be done, and no more.

The tradeoff the alternatives noted is real: under Option A the Operational
path does not exercise transfer(). This is not a weakness. Transfer exists to
change execution between boot environments, so its acceptance should exercise
an actual transition. Testing Transfer through a path that deliberately
performs no transition tests the absence of its responsibility, not the
responsibility itself. Transfer is properly exercised by a genuine redirect
(the experiment design below), not by the Operational path.

### Decision

The Operational path does not invoke transfer() when the destination boot
environment is identical to the currently selected boot environment. In that
case the bootstrap driver continues normal loader execution directly.
transfer() is reserved exclusively for genuine boot-environment transitions.

The driver's dispatch therefore reads: given the role and the observations,
resolve the destination (carry the selected boot environment forward for the
Operational Role, or bind() for a role requiring resolution); then, if the
destination differs from the currently selected boot environment, call
transfer(); otherwise continue normal loader execution. The comparison lives
in the driver (composition, Part 13), so Transfer stays ignorant of selection
state (Part 8 N1, N5) and its contract is unchanged: one boot environment in,
control transferred once, invoked only when there is a transition to perform.

This keeps the architecture internally consistent, preserves Transfer as a
narrowly focused responsibility, and continues the philosophy that emerged
across Parts 7, 8, and 13: every component performs exactly one
responsibility, and only when that responsibility is genuinely required.

## Experiment safety design (plan, not execution)

Transfer's experiment cannot end in a harmless pause the way Experiments 5
through 7 did, because a live transfer() redirects the boot. This section
designs an experiment that proves transfer() without risking a stranded
bench. It is a plan; no experiment is run as part of this note.

The design is two stages, cheapest and safest first.

### Stage 8a: dry-run (no execution, no boot risk)

transfer() is implemented, and the adapter calls it in a DRY-RUN mode that
prints what it would do (the target boot environment and the primitive
sequence it would invoke) without invoking the primitive. This proves the
Bind/driver -> Transfer hand-off, the narrow interface isolating the
loader-specific call, and Transfer's ignorance (it receives only a boot
environment), with zero boot risk: the boot continues exactly as in
Experiment 7. The dry-run is the observe-and-pause pattern applied to
Transfer, and it is the natural first Transfer experiment.

### Stage 8b: live redirect to a known-good BE, single-boot activation

Only after 8a, transfer() is exercised live, redirecting to a DIFFERENT,
known-good boot environment, exactly as Experiment 4 did, but through the
real pipeline (transfer() invoked with a resolution-path destination rather
than a hand-written sequence in the adapter). The safety net is the same one
Experiment 4 used and proved survivable: the instrumentation lives only in
bootstrap-poc, and bootstrap-poc is activated for a SINGLE boot (bectl
activate -t). If transfer() redirects wrongly, or to a BE that does not
boot, the single-boot activation means the next reboot reverts to the
persistent default with no intervention. The redirect target is a
known-good BE (as in Experiment 4, known-good-generic), so even the intended
redirect lands somewhere that boots.

The two stages together prove Transfer: 8a proves the hand-off and interface
with no risk, 8b proves the actual control transfer with the single-boot
revert as the safety net. Neither is run as part of this record; both follow
the transfer() implementation.

Consequence of the decision for 8b: because the Operational path does not
call transfer() (the decision above), 8b's redirect must be driven by a role
requiring resolution, so that the driver actually invokes transfer(). Today
that means exercising the resolution path with a known-good binding value
(simulating the Recovery binding resolving to a known-good boot environment),
since the Operational path deliberately performs no transition. This is the
correct way to test Transfer: through a genuine transition, which is the
responsibility Transfer exists to perform.

## Summary

Decision (ratified): transfer() runs only for a genuine boot-environment
transition. On the Operational path, where the destination equals the
already-selected boot environment, the driver continues normal loader
execution and does not call transfer(). The no-op determination is the
driver's, because only the driver holds both the current selection and the
resolved destination.

Rationale: this preserves Transfer as a single narrow responsibility
(perform a transition) rather than expanding it to manage transition
semantics, and it extends Part 13's discipline (resolve only what is not
already known) to the next stage (transfer only when a transfer is
required). Every stage performs exactly the work that remains.

Contracts: Part 8 is unchanged (Transfer's transformation is still one boot
environment in, control transferred once); Part 13 is unchanged (the driver
composes and dispatches). This record fixes when the driver invokes
transfer(), which is composition, not a change to any responsibility's
contract.

Experiment: staged as 8a (dry-run, no risk) then 8b (live redirect to a
known-good boot environment under single-boot activation), run after
transfer() is implemented. Under this decision, 8b exercises the resolution
path, since the Operational path performs no transition.

Status: RATIFIED (operator, 2026-07-02); records the Operational-path
Transfer decision (Option A) and plans the experiment. Precedes transfer()
code, which follows from this decision.

Bench: none (design decision record). The Transfer experiment (8a dry-run,
8b live redirect under single-boot activation) is planned here and run after
transfer() is implemented per this decision.
