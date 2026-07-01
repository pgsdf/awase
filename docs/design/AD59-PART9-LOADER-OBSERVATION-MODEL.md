# AD-59 Part 9: Loader Observation Model (LOM)

Status: DRAFT MODEL.

This document defines the Loader Observation Model: the complete, finite,
versioned set of loader-stage observations that Discover is permitted to
report and Decide is permitted to consume. It is the stable observation
boundary between the loader-stage facts and the responsibilities that use
them.

The LOM is an ARCHITECTURAL artifact, not a policy artifact. It defines what
the loader can know, not what any particular policy needs. This is the
correction that keeps the layers independent:

    Loader reality -> Loader Observation Model -> Discover -> Decide -> Policy

Discover implements the LOM (it reports the model's observations). Decide
consumes the LOM (it evaluates over the observations it is given). Policy is
a pure function over those observations (it interprets a subset). A given
policy consumes only the subset it requires; richer policies consume more
later WITHOUT changing Discover's interface, because the interface is the
LOM, and the LOM is defined by loader reality, not by policy.

This is the kernel/system-call relationship. The kernel exports a stable set
of system calls; applications choose which to use; applications do not
determine which exist. Likewise Discover exports observations, Decide
consumes them, and policy interprets them, as three independent layers.

## The observation/conclusion rule

Every entry in the LOM is an OBSERVATION, never a CONCLUSION. This is the
observation-before-interpretation discipline made into the model's admission
rule:

  - "This loader-visible flag exists and has value X" is an observation. It
    is admissible.
  - "The OE is unhealthy" is a conclusion. It is NOT admissible; it is a
    policy judgment derived from observations.

Discover reports observations. Decide and policy derive conclusions from
them if appropriate. The moment an entry states what something MEANS rather
than what it IS, it belongs to policy, not the LOM. Every candidate entry
below is stated as a fact the loader can see, and the test for admitting any
future entry is the same: is this what the loader observes, or what someone
concludes from it?

## This document's relationship to the contracts

The LOM is the shared input set that Discover's contract (Part 5) and
Decide's contract (Part 6) both point to. It resolves their shared
dependency: Discover returns the LOM's observations (its P1 to P4), and
Decide consumes exactly those (its P1, N1). It also fixes the meaning of
Discover's N4: N4 prohibits collecting observations OUTSIDE the LOM, not
collecting outside what the current policy inspects. The LOM is the boundary
N4 refers to. A policy ignoring part of the LOM creates no coupling; Discover
gathering something not in the LOM violates N4.

## Candidate observation categories

The following are the CATEGORIES of loader-stage observation the model is
expected to contain. They are stated as observations, and each is subject to
the observation/conclusion rule and to confirmation that it is actually
observable at loader stage on this system (a matter for the LOM's concrete
definition, which may require reconnaissance of what the loader can read
before kernel load).

  - Operator recovery-request state. Whether a loader-stage operator signal
    indicating a recovery request is present (for example a loader-set
    variable or a menu selection, per AD-11 D4's pre-inputfs path). This is
    the observation "the operator signal is present/absent," not the
    conclusion "recovery is requested" (whether that signal means recovery
    is a policy matter).

  - Selected boot environment. The boot environment the loader currently has
    selected (currdev / the active BE), as an observed value.

  - Loader-visible boot metadata. Boot-related metadata the loader can read
    before kernel load (loader-stage variables, configuration values), as
    observed values.

  - Recovery assets present. Whether the assets a recovery environment would
    require are observable as present at loader stage (for example whether a
    recovery boot environment exists to select), as a presence/absence
    observation, not a judgment about whether recovery should occur.

  - Boot generation identifiers. Loader-readable identifiers that distinguish
    boot attempts or generations, as observed values. The observation is the
    identifier's value; concluding "the previous boot did not complete" is a
    policy derivation over such identifiers, not itself an LOM entry.

  - Promotion state markers. Loader-readable markers reflecting promotion
    state (per AD-58, the promotion authority owns the binding and may leave
    loader-readable state), as observed values, not as the conclusion
    "promotion is incomplete."

  - Loader-readable status flags. Other loader-stage flags with defined
    meaning that the loader can read, as observed values.

These are categories, not a finalized field list. The concrete LOM fixes the
exact fields, their representations, and their loader-stage sources, and does
so under the observation/conclusion rule. Fields are added only when they are
genuine loader-stage observations, and the model is versioned so additions
are explicit.

## Versioning and finiteness

The LOM is finite and versioned. It is not open-ended: Discover may report
only what the model defines (Discover N4), and Decide may consume only what
the model defines (Decide N1). Extending the model is a deliberate, explicit
act (a new version), not an implicit consequence of a policy wanting more
data. This is what makes the observation boundary stable: policy evolves
freely above it, while the boundary itself changes only by intentional
versioning.

## What the LOM does not do

  - It does not evaluate policy. It defines observations; it does not weigh,
    rank, or interpret them.
  - It does not select a role or an environment. That is Decide (role) and
    Bind (environment).
  - It does not fix which observations a policy must use. A policy consumes
    the subset it requires; the LOM defines what is available, not what is
    obligatory.
  - It does not reach past the loader stage. AD-11's post-kernel recovery
    machinery (the rc.d boolean, marker file, Alt-in-rc.d) is not in the LOM;
    it lies after Transfer and is outside the loader-stage observation
    boundary.

## Next step

The concrete LOM (exact fields, representations, and loader-stage sources)
is the immediate design artifact, and its definition may require confirming
what the loader can actually observe before kernel load on this system. Once
the concrete LOM exists, discover() is implemented as its reporter and
decide() as its consumer, each against its contract, and each written to
migrate into the future Awase loader (the LOM is loader-stage-defined, so its
observations carry across a loader replacement even as the mechanism that
reads them changes).

Status: DRAFT MODEL; defines the observation boundary. The concrete field
list is the next design artifact, before code.

Bench: none (design model); the concrete LOM may require read-only loader
reconnaissance.
