# AD-58 Recovery authority publication: design exploration

Status: Design exploration (non-ratified). Purpose: derive the semantic
requirements for the Recovery authority publication mechanism. This document
is exploratory and may change. It does not amend AD-58 or establish
architectural commitments beyond those already ratified.

## Position in the sequence

AD-58's first addendum ratified the architectural contract for the Recovery
authority: the PGSD lifecycle owns the Recovery target designation, that
designation SHALL be published through a loader-observable interface, AD-59
consumes it and SHALL NOT infer it from implementation details, and the
publication mechanism is owned by the lifecycle and is not part of the
architectural contract.

That contract fixes ownership, publication, and the no-inference boundary. It
deliberately does not say what the published authority designates in detail,
when it changes, or what guarantees it provides. Until those semantics exist,
there is nothing concrete for an AD-59 producer to observe, and no basis on
which to choose a publication mechanism.

This document derives those semantics. It answers four questions (what is
designated, when it changes, what it guarantees, who owns it) and ends with
the requirements any publication mechanism must satisfy. It deliberately does
not choose or compare mechanisms; that is a later step, made objective by
measuring candidates against the requirements derived here. Terminology
follows the addendum: PGSD is the operating system, AD-58 is the PGSD
lifecycle, awase be is the lifecycle's Boot Environment implementation, and
AD-59 is the bootloader that consumes the published authority.

A discipline this document holds: it stays at the level of meaning, not
representation. Where answering a question seems to require naming a
representation (a variable, a property, a name, an identifier, a format),
that is the signal that the question has crossed into mechanism, and the
document stops at the semantic requirement instead. Representation is the
next decision's concern.

## Question 1: What does the published authority designate?

The published authority designates the Recovery target: the destination the
lifecycle has established as the environment to boot when recovery is
selected.

The designation has these properties, stated as meaning, not representation:

  - Authoritative. It is the definitive answer to "what is the current
    Recovery target." No other source overrides it, and no consumer forms
    its own answer.

  - Owned by the AD-58 lifecycle. Only the lifecycle originates and changes
    the designation (Question 4).

  - Stable enough for the loader to consume. It does not change under the
    loader's feet during the window in which the loader observes it, and it
    changes only on defined lifecycle events (Question 2), not
    incidentally.

  - Loader-observable. It is available for observation at loader stage,
    before the kernel loads. (That it is loader-observable is required; how
    it is made so is mechanism.)

  - Not inferred from implementation details. Per the addendum, AD-59
    observes the published designation; it does not derive the Recovery
    target from Boot Environment names, naming conventions, or other
    implementation details. This constrains how AD-59 comes to know the
    designation (by observation of an explicit publication), not what the
    designation is represented as. If the lifecycle chooses to represent the
    designation in a form that resembles an implementation identifier, that
    is acceptable precisely because the lifecycle published it as the
    authoritative designation, rather than AD-59 inferring it.

  - Resolves to the designated destination. The designation, once observed,
    yields the destination the lifecycle designated as Recovery, without
    further inference by the consumer.

What this question deliberately does not answer: whether the designation is
carried as a Boot Environment identifier, a UUID, a logical handle, a name,
or any other form. Those are questions of representation, belonging to the
publication mechanism design, because they concern how the designation is
carried rather than what it means. The architectural distinction the addendum
drew is preserved here: "boot the environment named X" observed by convention
is inference and is rejected; "boot the target the lifecycle has published as
Recovery, whose current value is X" is observation and is acceptable
regardless of what X looks like.

## Question 2: When does the designation change?

The designation changes only on defined lifecycle events. This section
enumerates the events semantically (what the change means), not as storage
operations (how it is written).

The candidate events, drawn from AD-58's state machine (Recovery ->
Installing -> Unverified -> Verified -> Released) and the awase be operations:

  - Recovery establishment. When the lifecycle establishes a Recovery target
    (in the FreeBSD implementation, when the Recovery Boot Environment is
    captured before change), the designation comes to name that target. This
    is the primary event: before it, there may be no designation; after it,
    the designation identifies the established Recovery target.

  - Recovery re-establishment. AD-58 treats Recovery as a singleton (the
    escape hatch, identified by name not timestamp). If the lifecycle
    re-establishes the Recovery target (a subsequent pre-change capture that
    supersedes the prior one), the designation must come to name the new
    target. Whether re-establishment replaces or is a no-op is an AD-58
    lifecycle question; the requirement here is that the designation always
    names whatever the lifecycle currently holds as Recovery, never a
    superseded one.

  - Promotion (Released). When a Verified state is committed to Released, a
    new candidate future Recovery point exists (AD-58: a Released state
    becomes a candidate future Recovery point). Whether promotion changes
    the current Recovery designation is a genuine open lifecycle question:
    promotion creates a candidate, but the Recovery target in force may
    remain the pre-change capture until the lifecycle deliberately
    re-establishes Recovery. This document does not resolve which; it
    records that the designation changes on promotion only if AD-58's
    lifecycle semantics say the promoted state becomes the Recovery target,
    and otherwise promotion leaves the designation unchanged. The resolution
    is an AD-58 lifecycle decision, not a mechanism decision.

  - Rollback. Rollback activates the Recovery target and reboots (AD-58: it
    never deletes the broken environment). Rollback consumes the
    designation (it boots the designated target); it does not obviously
    change it. The requirement: rollback must be able to rely on the
    designation naming a bootable Recovery target, and rollback does not
    leave the designation naming something that no longer exists.

The semantic requirement across these events: the designation changes only
on lifecycle events that establish or re-establish the Recovery target, and
between such events it is stable. It never changes incidentally, and it never
lags behind the lifecycle's actual Recovery target.

An explicitly open item for AD-58 (not resolved here): the exact set of
events that change the designation, in particular whether promotion to
Released changes it or only creates a candidate. This is a lifecycle
semantics question for AD-58, and it should be settled before or with the
mechanism, because it determines the update semantics the mechanism must
support.

## Question 3: What guarantees must the publication provide?

These are the guarantees the publication must provide to be safe for the
loader to depend on. They are the core of the derived requirements.

  - Durability. The designation persists across reboots and across the loss
    of the running environment. This is the guarantee most directly tied to
    AD-58's founding failure: the Recovery target must remain known even
    when the environment that was running is gone or unbootable. A
    designation that lived only in the running environment would vanish
    exactly when recovery is needed.

  - Loader observability. The designation is observable at loader stage,
    before the kernel loads, because AD-59 must resolve the Recovery Role
    there. A designation observable only after the kernel is up would be
    useless to the bootloader.

  - Update semantics. When the designation changes on a defined lifecycle
    event (Question 2), the change is complete and consistent before it is
    observable: the loader never observes a partially written or transiently
    inconsistent designation. Updates are atomic with respect to
    observation.

  - Behavior when absent. The publication must have a defined meaning for
    "no designation is present" (for example, before any Recovery target has
    been established). AD-59 must be able to observe absence as absence (an
    explicit not-present observation, consistent with the LOM's treatment of
    unavailable and absent), and the lifecycle and bootloader must have
    defined behavior for that case rather than undefined behavior. Absence is
    a legitimate state, not an error to be guessed around.

  - Behavior when stale or inconsistent. The publication must not leave the
    loader observing a designation that names a target that no longer exists
    or was superseded. Either the designation is kept consistent with the
    lifecycle's actual Recovery target (preferred), or staleness is
    detectable by the consumer so it can treat a stale designation as absent
    rather than boot a wrong or missing target. A silently stale designation
    that resolves to a vanished target is the failure mode to preclude.

Notice these guarantees are stated without a mechanism. Durability, loader
observability, atomic update, and defined absent/stale behavior are
properties several mechanisms could provide; the point here is to require
them, so that when mechanisms are compared, each is measured against them.

## Question 4: Who owns the designation?

Ownership is reaffirmed from the addendum, at the semantic level:

  - The AD-58 lifecycle (in implementation, awase be) is the sole originator
    of the designation. It establishes it, changes it on lifecycle events,
    and is the only component that writes it.

  - Every other component, including AD-59, is purely a consumer. AD-59
    observes the published designation and resolves the Recovery Role
    against it. AD-59 never originates, changes, or repairs the designation,
    and never substitutes its own answer when the designation is absent or
    stale (it treats those per the defined absent/stale behavior, Question
    3, rather than inventing a target).

This ownership is what makes the other guarantees meaningful: because a
single owner originates the designation on defined events, durability and
update semantics are the owner's responsibility to provide, and the consumer
can depend on them rather than defending against an unowned, racily written
value.

## Derived requirements for the publication mechanism

This is the deliverable. Any candidate publication mechanism must satisfy all
of the following. This section lists the requirements; it does not evaluate
candidates.

  R1. Authoritative single source. The mechanism carries a designation
      written only by the AD-58 lifecycle, with no other writer.

  R2. Loader-stage observability. The designation is observable at loader
      stage, before the kernel loads.

  R3. Durability across environment loss. The designation persists across
      reboots and across the loss or unbootability of the running
      environment, so the Recovery target remains known when recovery is
      needed.

  R4. Stability between lifecycle events. The designation changes only on the
      defined lifecycle events that establish or re-establish the Recovery
      target, and is otherwise stable; it never changes incidentally and
      never lags the lifecycle's actual Recovery target.

  R5. Atomic update with respect to observation. When the designation
      changes, the loader never observes a partially written or transiently
      inconsistent value; the change is complete and consistent before it is
      observable.

  R6. Defined absence. "No designation present" is a representable, defined
      state that the consumer can observe as absence, with defined lifecycle
      and bootloader behavior for that case.

  R7. No silent staleness. The mechanism either keeps the designation
      consistent with the lifecycle's actual Recovery target, or makes
      staleness detectable by the consumer, so a stale designation is never
      silently resolved to a vanished or superseded target.

  R8. Consumer resolves without inference. Once observed, the designation
      yields the Recovery destination without the consumer inferring it from
      Boot Environment names, naming conventions, or other implementation
      details; the consumer's knowledge comes only from the published
      designation.

## What is next (and what is deliberately not in this document)

Not in this document: any choice or comparison of publication mechanisms
(loader variable, pool or dataset property, metadata record, or other); any
representation of the designation; any AD-59 producer contract or code.

Next, in order:

  1. Resolve the open AD-58 lifecycle question from Question 2 (which events
     change the designation, in particular promotion), since it determines
     the update semantics a mechanism must support.

  2. Compare candidate publication mechanisms against R1 through R8,
     objectively, each measured against these requirements rather than
     preference.

  3. If that comparison yields a stable architectural commitment, ratify the
     chosen mechanism, at which point it may be promoted into AD-58 as a
     further addendum. Until then, AD-58 remains unchanged beyond the first
     addendum.

  4. Specify the AD-59 producer that observes the published designation and
     maps it into the LOM for bind(), as a bounded contract parallel to the
     operator_recovery_request producer (AD-59 Part 15).

Status: Design exploration (non-ratified). It derives the semantic
requirements (R1 through R8) for the Recovery authority publication
mechanism, and defers mechanism choice, representation, and the AD-59
producer to later steps.
