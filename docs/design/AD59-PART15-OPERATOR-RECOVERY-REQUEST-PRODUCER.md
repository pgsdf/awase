# AD-59 Part 15: The operator_recovery_request producer

Status: DRAFT CONTRACT.

This document defines the operational contract for the
operator_recovery_request producer: the loader-state that produces the
observation, the values that state may hold, the mapping from that state to
the LOM v1 observation (present, absent, unavailable), and the minimal
loader-menu affordance required to produce the state for hardware
validation. It implements a mechanism already chosen; it does not reopen the
mechanism decision.

## The mechanism is already decided (ADR 0008 / AD-11.1)

AD-11.1 (pgsd-sessiond ADR 0008, "Recovery and console posture," D4)
already chose the loader-stage mechanism. Its D4 decides that in-OS
recovery-request detection lives in early rc.d over inputfs (an Alt poll),
and that the reliable pre-inputfs path is a loader menu entry that sets a
loader environment variable (a menu selection, not modifier detection),
folded into the same recovery-request signal as a cheap complement.

That pre-inputfs path, the loader menu entry setting a kenv variable, is
exactly the loader-stage producer AD-59's discover() consumes. The
inputfs Alt poll is post-inputfs and is not a loader-stage producer; it is
AD-11's own implementation (AD-11.2) and is out of scope here. This
document does not re-decide the mechanism; it defines the operational
contract needed to build and test the loader-stage half.

## Responsibility boundary: AD-59 owns the contract, AD-56 owns the UI

The producer has two parts: the loader-state that carries the signal (a
kenv variable) and the user interface that sets it (a menu affordance).
AD-59 owns the CONTRACT: the observation operator_recovery_request is
produced by a defined loader-state, and discover() reads that state. AD-56
owns the user interface that ultimately produces that state, as part of its
menu ownership (BOOT-PATH-OWNERSHIP, Phase 1 and beyond).

AD-59 supplies a minimal loader-menu affordance here only insofar as it is
the smallest producer needed to exercise the recovery pipeline end to end
on hardware. This is not AD-59 taking ownership of the menu system. It is
the smallest menu extension necessary to produce the observation
discover() consumes, so the pipeline can be validated without simulation
(as Experiment 8b required, because no producer existed).

When AD-56 owns the entire menu, it becomes the component that sets the
same kenv contract. Nothing downstream changes: discover() reads the same
variable, the policy evaluates the same field, the pipeline selects and
transfers unchanged. The contract is stable across the mechanism swap. This
is the same stability the LOM's producer separation was designed for, and
the same portability by which this module migrates from the stock loader to
the Awase loader: only the producer of the state changes, never the
observation or its consumers.

## The loader-state contract

The signal is carried by a single loader environment variable, read at
loader stage via loader.getenv:

  Variable: pgsd_recovery_request

  Permitted values:
    - "1"     The operator has requested recovery for this boot.
    - unset   The operator has not requested recovery (the variable is
              absent from the loader environment).

No other value is defined. The producer that sets the variable (the menu
affordance below, and later AD-56's menu) sets it to exactly "1" or leaves
it unset. A value present but not equal to "1" is treated as not-requested
(see the observation mapping); it is not an error, because discover()
observes rather than validates, but no component is permitted to set a
value other than "1".

The variable is a loader environment variable, not a file: the loader sets
it, and discover() reads it through loader.getenv, so no loader filesystem
access is required (consistent with ADR 0008 D3's note that the loader does
not need to read the recovery marker file).

## The observation mapping

discover() maps the loader-state to the operator_recovery_request field of
the LOM v1 observation object as follows. The three values are the uniform
observation model's values (Part 9, Part 10), used here with these precise
meanings:

  - present     The producer executed and pgsd_recovery_request holds the
                value "1". The observation is "the operator signal is
                present." This is the value Selection Policy v1's R1 tests
                for (Part 12), so a present observation makes the policy
                select the Recovery Role.

  - absent      The producer executed and pgsd_recovery_request is unset
                (or holds any value other than "1"). The observation is
                "the operator signal is not present." Selection Policy v1's
                R1 does not match, and the policy falls through to the
                Operational default.

  - unavailable The producer itself could not make an observation. With the
                producer shipped as part of normal bootstrap, this is
                effectively unreachable in ordinary operation: the read
                either finds the variable ("1" gives present) or does not
                (unset gives absent). unavailable remains in the domain
                because discover() has a uniform observation model and
                other producers may legitimately return unavailable; it is
                not expected from this producer in a normal boot.

Note the semantics shift this introduces, deliberately. Before this
producer, discover() reported operator_recovery_request as unavailable
unconditionally (Part 10 producer table: no producer). After it, the field
reports present or absent on every normal boot, and unavailable becomes the
exceptional value rather than the constant one. This is the field's
producer moving from "none" to "loader environment" in the Part 10 table.
It changes the producer table (implementation progress), not the LOM
vocabulary and not discover()'s interface: the field, its position in the
observation object, and its value domain are unchanged. Consumers that
already handle the three values (decide() via the Part 11 predicate
semantics, which make a present-testing predicate false against absent and
against unavailable alike) require no change.

## The minimal loader-menu affordance (for validation)

To produce the state on hardware, the loader must offer the operator a way
to set pgsd_recovery_request. AD-59 supplies the minimal such affordance,
in the same local.lua space it already occupies (the try_include("local")
pre-menu hook), and no more. Its required behavior:

  - Present a single, clearly labeled option at loader stage by which the
    operator requests recovery for this boot (for example a menu entry or a
    prompted key, whichever the local.lua environment supports cleanly).
  - On selection, set pgsd_recovery_request to "1" via loader.setenv, then
    continue the normal loader flow (the bootstrap pipeline runs afterward
    and observes the variable).
  - On no selection, leave pgsd_recovery_request unset and continue
    normally.

Explicit non-goals of this affordance, which remain AD-56's:

  - It is NOT the loader menu's layout, presentation, or boot UX. It is a
    single option sufficient to set one variable.
  - It does NOT restructure or own the menu. When AD-56 owns the menu, this
    minimal affordance is removed and AD-56's menu sets the same variable.
  - It carries no recovery policy: it sets the signal; decide() interprets
    it. Setting the signal is not deciding that recovery occurs (Part 12
    value-domain note: the signal's presence is an observation, and whether
    presence means recovery is the policy's judgment).

## What this changes in the implementation

  - pgsd_bootstrap.lua: the operator_recovery_request producer changes from
    returning the unavailable sentinel unconditionally to reading
    pgsd_recovery_request via loader.getenv and mapping per the observation
    mapping above (present on "1", absent otherwise). This is a producer
    change isolated to one observation; the observation object's shape,
    version, and every other field are unchanged, and the loader-specific
    read stays in the producer where the module's portability isolates it.

  - The local.lua adapter (or a menu affordance beside it): gains the
    minimal option that sets pgsd_recovery_request on operator request.

  - No change to decide(), the policy, bind(), resolve_destination(),
    transfer(), or run(): the pipeline consumes the same field with the
    same values. The only new behavior is that the field can now report
    present, which the already-validated pipeline handles by selecting the
    Recovery Role.

## Validation intent (not the experiment record)

When implemented, this producer allows the first NON-simulated Recovery
selection on hardware: the operator sets pgsd_recovery_request through the
menu affordance, discover() reports operator_recovery_request as present,
Selection Policy v1 selects the Recovery Role, and the pipeline resolves
and (given a Recovery binding, still simulated until the AD-58 binding
producer exists) transfers. This closes the specific gap Experiment 8b
recorded: 8b simulated operator_recovery_request; this producer makes it
real. The experiment that exercises this is future work and will be
recorded in Part 3 in the established format; this document defines the
contract it validates, before code.

The Recovery binding remains the other missing producer (the AD-58
promotion write path). Until it exists, a bench exercise of this producer
still supplies a temporary binding for the destination, exactly as 8b did;
what becomes real here is the trigger, not the binding. Making the binding
real is separate future work.

Status: DRAFT CONTRACT; defines the operator_recovery_request producer's
loader-state, observation mapping, and minimal validation affordance,
implementing ADR 0008 D4's chosen mechanism. Implementation follows, before
which this contract is ratified.

Bench: none (design contract). The implementation it governs is validated
on bare-metal-test-bench, in the bootstrap-poc instrumentation BE, by
setting the variable through the menu affordance and observing a
non-simulated Recovery selection.
