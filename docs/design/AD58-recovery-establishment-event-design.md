# AD-58 Recovery establishment event: design exploration

Status: Design exploration (non-ratified). Purpose: specify the Recovery
establishment event, the deliberate lifecycle event by which a candidate
becomes the designated Recovery target, against the working publication
mechanism (the ZFS property identified as strongest). This document is
exploratory and may change. It establishes no durable architecture and amends
no ADR.

This document is also a test. The sequencing question of whether the
establishment event depends on the eventual three-environment model
(Operational, Recovery, Maintenance) is settled here not by argument but by
attempt: the contract below is written deliberately WITHOUT naming any
invocation environment. If it can be stated completely without doing so,
independence from the three-environment model is demonstrated, and the
Maintenance thread is a consumer of this contract rather than a prerequisite
for it. If any clause cannot be stated without naming an invocation
environment, that clause has found a genuine architectural dependency, which
the document surfaces rather than works around. The result of the test is
recorded at the end.

Terminology follows the addenda: PGSD is the operating system, AD-58 is the
PGSD lifecycle, awase be is the lifecycle's Boot Environment implementation,
AD-59 is the bootloader.

## What this event is, and what settled it

The promotion-semantics addendum settled that promotion creates eligible
Recovery candidates and does not advance the Recovery designation; any change
of the designation is a distinct deliberate establishment event, which that
addendum deferred. This document specifies that event.

It is specified against the working publication mechanism from the mechanism
comparison: a ZFS property carrying the Recovery designation. That mechanism is
the strongest identified but not ratified; this document is where several of
its deferred, implementation-facing properties (the concrete update operation,
loader read path, and platform behaviors) are confirmed or qualified, which is
why the mechanism comparison ratifies only after this work.

## The separation this contract observes

Following the policy, publication, and consumption separation the architecture
already uses (AD-59 consumes the published designation and is indifferent to
which policy produced it), this contract specifies the publication ACT and its
invariants, not the invocation context. Three concerns are kept distinct:

  - Policy: why and from where establishment is invoked. This is a realization
    of the contract, not part of it.

  - Publication: the deliberate act of writing a new Recovery designation to
    the mechanism, with its invariants. This is the contract.

  - Consumption: AD-59 reads the published designation. Already specified by
    the authority contract; unchanged here.

## The establishment event contract

  E1. Authority. The PGSD lifecycle is the sole authority that establishes the
      Recovery designation. Establishment is an act of the lifecycle; no other
      component originates it.

  E2. Deliberate act only. Establishment occurs only as a deliberate lifecycle
      operation, never as a side effect of another operation, and never
      automatically (consistent with the promotion addendum: promotion creates
      candidates, establishment is separate and deliberate).

  E3. The operation. Establishment publishes a new Recovery designation to the
      publication mechanism, replacing the prior designation. The published
      designation identifies the candidate that is to become the current
      Recovery target.

  E4. Verification precondition (existence, not policy). The lifecycle SHALL
      establish only a candidate that satisfies the lifecycle's verification
      requirements. This clause introduces the EXISTENCE of a precondition; it
      does not define what verification consists of. What satisfies the
      requirement (which tests, performed by what, confirming what properties)
      is a separate verification-policy question, deferred, and deliberately
      not answered here. The contract requires that establishment not publish
      an unverified candidate; it does not specify how verification is
      realized.

  E5. Atomicity with respect to observation. The publication of the new
      designation SHALL be atomic with respect to the consumer's observation:
      the consumer never observes a partially written or transiently
      inconsistent designation. Before establishment completes, the consumer
      observes the prior designation; after it completes, the new one; never an
      intermediate state. (This is R5 of the publication requirements,
      instantiated at the establishment event. Whether the chosen mechanism's
      concrete update operation provides this atomicity is confirmed as an
      implementation matter below.)

  E6. Single writer preserved. Establishment is the only operation that writes
      the Recovery designation, and only the lifecycle performs it (R1 of the
      publication requirements, preserved at the event).

  E7. Post-conditions. After establishment completes: the published
      designation names the newly established Recovery target; the prior
      designation is superseded and no longer observable; and the newly
      established designation names a candidate that satisfied E4. The
      designation then remains stable until the next deliberate establishment
      (R4, stability between events).

## R7's policy layer, completed here

The mechanism comparison evaluated R7 (no silent staleness) only as mechanism
capability and deferred R7's policy layer (how much stale state exists in
practice) to this event, because staleness is a function of how often the
designation is re-established. This contract completes that layer as far as the
event defines it:

  - The designation changes only at a deliberate establishment event (E2), so
    the designation is exactly as fresh as the most recent deliberate
    establishment, no fresher and no staler. There is no automatic drift and no
    silent advance.

  - How OFTEN establishment occurs, and therefore how much distance can
    accumulate between the established Recovery target and the current system,
    is governed by when the lifecycle chooses to establish. That frequency is a
    lifecycle-operational matter (when operators or workflows perform
    establishment), and it is the residual policy question: a Recovery target
    established long ago and not re-established remains the designation until a
    deliberate establishment replaces it. The contract does not mandate a
    re-establishment cadence; it guarantees that whatever the designation
    names, it was deliberately established and verified (E4), so it is never
    silently stale in the sense of having drifted, though it may be DISTANT in
    time if not deliberately refreshed.

  - The staleness the founding failure cares about (a Recovery that cannot
    actually recover) is addressed by E4: a candidate is established only if it
    satisfies the lifecycle's verification requirements, so an established
    Recovery is a verified-recoverable one at the time of establishment.
    Whether verification must be periodically renewed to guard against a
    once-verified Recovery becoming unbootable under later platform change is
    part of the deferred verification policy, noted here as the natural place
    that question is answered.

## Implementation-facing confirmations against the working mechanism

The mechanism comparison flagged that several advantages of the ZFS property
are model properties it did not empirically establish, to be confirmed here.
This document records them as requirements the establishment operation places
on the mechanism, to be verified in implementation; it does not assert
platform behavior it cannot establish:

  - The update operation must provide E5 atomicity: publishing the new
    designation must be atomic with respect to a concurrently reading loader.
    The establishment operation requires this; whether a single ZFS property
    set provides it as-is, or whether the operation must be structured to
    guarantee it, is confirmed in implementation.

  - The loader read path (R2) must allow the consumer to read the designation
    at loader stage. The establishment operation writes what the consumer
    reads; the concrete read path is confirmed in implementation and is the
    same point the mechanism comparison left open.

  - Any platform behavior the designation relies on for durability (that the
    property persists across environment loss and travels with the pool) is
    required by R3 and confirmed in implementation, not assumed here.

These are stated as obligations on the realization, keeping this contract at
the level of what must be true while directing the implementation to confirm
the mechanism actually provides it.

## Result of the independence test

The contract above (E1 through E7), the R7 policy completion, and the
implementation confirmations are stated in full without naming any invocation
environment. No clause required saying that establishment happens in the
Operational Environment, in a Maintenance Environment, or in any other
particular environment:

  - Authority (E1) is the lifecycle, an authority, not a place.
  - The deliberate-act requirement (E2) constrains the nature of the trigger,
    not its location.
  - The operation (E3) is a write to the mechanism, location-independent.
  - The verification precondition (E4), the clause most likely to hide a
    dependency, was stated as the EXISTENCE of a requirement without naming
    where verification occurs; it did not force an environment to be named.
  - Atomicity, single-writer, and post-conditions (E5 through E7) are
    properties of the act and the designation, not of any location.

The invocation context appears nowhere in the contract. It appears only as
this observation: an establishment operation could be invoked as an explicit
lifecycle command, as part of an installer workflow, or from a future
Maintenance Environment, and each would be a realization of this same
contract. These are examples of realizations, removable without weakening the
contract, not part of it.

The test therefore passes: the complete establishment-event contract is
expressible without naming an invocation environment. This demonstrates that
the establishment event is architecturally independent of the three-environment
model. The Maintenance thread, if ratified, is a CONSUMER of this contract (one
context from which establishment may be invoked), not a prerequisite for
defining it. The two threads may proceed independently, meeting only where a
Maintenance Environment, if it exists, invokes this already-complete contract.

## What is next (and what is deliberately not concluded here)

Not concluded here: the verification policy (what satisfies E4); the concrete
ZFS property (pool versus dataset, name, value representation); the
implementation confirmations (atomicity, loader read path, durability
behavior); and ratification of the mechanism or this event.

Next, in order:

  1. The AD-59 producer that observes the published designation and upholds R8,
     specified against the working mechanism, as a bounded contract parallel to
     the operator_recovery_request producer.

  2. Implementation of the publication mechanism and the establishment
     operation, confirming the implementation-facing obligations above.

  3. Ratification: once the mechanism, the establishment event, and the
     producer form a complete, confirmed architectural story, ratify the
     mechanism comparison as the rationale for the selected mechanism and, if
     warranted, promote the settled decisions into AD-58.

  The verification policy (E4's content) and the three-environment model remain
  separate threads. This contract is independent of both: it requires that
  verification exist (E4) and can be consumed by a Maintenance Environment
  (shown above), without depending on either being defined.

Status: Design exploration (non-ratified). It specifies the Recovery
establishment event as a location-independent contract (E1 through E7),
completes R7's policy layer as far as the event defines it, records the
implementation obligations on the working mechanism, and demonstrates by
successful drafting that the establishment event is architecturally
independent of the three-environment model. It defers the verification policy,
the concrete mechanism details, and ratification.
