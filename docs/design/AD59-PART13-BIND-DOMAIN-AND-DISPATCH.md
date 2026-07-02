# AD-59 Part 13: Bind Domain and Role Dispatch

Status: RATIFIED (operator, 2026-07-02); drafted 2026-07-02.

This document refines the Bind contract (Part 7) with one interpretation
settled before bind() is implemented: Bind resolves only those roles whose
implementation is not already known. It records the consequence for the
bootstrap driver (the role is dispatched, and Bind is invoked
conditionally) and for Transfer (Part 8, which receives a concrete
destination from either path). It is written in the rhythm of Parts 11 and
12: the design decision is ratified first, then the code follows from it.

The refinement does not change the Part 7 contract. Bind still takes a role
and produces the boot environment that implements it, resolving without
deciding (P1, P2, N1 through N6 all stand). What this document fixes is the
one deferred specific Part 7 named ("the binding representation"), and it
fixes it by observing that the binding is smaller than first assumed: it
exists only where there is something to bind.

## The realization: a binding exists only where there is something to bind

Part 7's deferred question was the concrete representation of the
role-to-implementation binding. Preparing to answer it surfaced a cleaner
separation, in the same reflex that produced the Policy/evaluator split
(Part 11): before building the binding, check whether a binding is needed
at all for each role.

For the Operational Role, it is not. By the time AD-59 runs, the loader has
already selected a boot environment through normal administration, and
Discover has already observed it as selected_boot_environment (Part 10). If
Decide returns the Operational Role, the destination is already known: it
is the boot environment administration already selected. Treating
"Operational Role -> selected_boot_environment" as a binding would wrap a
fact the pipeline already holds inside a lookup, which is the manufacture of
data that already exists. The project's discipline is to avoid exactly that.

So the Operational Role is not a bindable role. There is nothing to
resolve; its implementation is "continue with what administration already
selected." The binding is for roles whose implementation is NOT determined
by discovered loader state, and the Operational Role's implementation is so
determined before Bind could run.

## Bind's domain

Bind resolves roles requiring resolution: roles whose implementation is not
determined by the loader state Discover already observed. Succinctly, Bind
resolves unresolved roles. The defining property is information flow, not
the role's name: the boundary is whether discovered state already fixes the
implementation, not whether the role is in some sense abstract. The
Operational Role is no less abstract than the Recovery Role; it is simply
already resolved, and that, not abstraction, is what keeps it out of Bind.

  - The Recovery Role is the first such role. Nothing in loader state names
    which boot environment implements recovery; that must be resolved
    against the binding. Recovery is therefore the first bindable role and
    the reason Bind exists.

  - The Operational Role is not a bindable role. Its implementation is the
    already-selected boot environment, known from Discover without
    resolution.

  - Future roles (Maintenance, Installer, Diagnostics, or others, should
    they be introduced) are bindable by the same test: is the role's
    implementation determined by discovered loader state? If not, Bind
    resolves it, and Bind's domain grows by that role with no change to its
    contract. The test is symmetric, which is its strength: a future role
    whose implementation becomes directly discoverable would bypass Bind by
    the same rule, and were the Operational Role ever to cease being
    determined by discovered state, it would become bindable, again without
    changing the architecture. The boundary is derived from information
    flow, so it holds however the roles change. This is the extensibility
    the narrowing buys: Bind is the one place unresolved roles become
    concrete, and it accretes roles without changing shape.

This narrowing strengthens rather than weakens the Part 7 contract. N3
(never invent an implementation; surface a resolution failure) was framed as
an edge case there; here it is Bind's central behavior, because Bind is now
invoked precisely for the roles where the implementation is not otherwise
known and a missing binding is the failure that matters.

## The dispatch: where routing on the role lives

The refinement requires that something route on the role: the Operational
Role continues to the selected boot environment, a role requiring
resolution goes to Bind. That routing is not a fifth responsibility and it
is not a change to any of the four. It is the bootstrap driver, the
top-level composition Part 4 already describes (discover -> decide -> bind
-> transfer). The driver
composes the responsibilities; dispatching on Decide's output is the
composition, not a new actor.

Placing the dispatch precisely:

  - It is not Decide's. Decide's work ends at producing the role (Part 6,
    N-clauses). Routing on the role would be Decide reaching downstream into
    what happens next, which its contract forbids.

  - It is not Bind's. Bind sees only roles handed to it (Part 7, P1). It
    cannot be the thing that decides whether it is invoked; that decision
    precedes it.

  - It is the driver's. The driver holds the role Decide returned and the
    boot environment Discover observed, and it composes the next step: for
    the Operational Role, carry the selected boot environment forward to
    Transfer; for a role requiring resolution, call bind() to resolve the
    destination,
    then carry that to Transfer.

The driver dispatch is small: given the role, either take
selected_boot_environment (already in hand) or call bind(role). Both
branches yield a concrete boot environment, which is what Transfer receives.

## Consequence for the pipeline shape

Part 4 draws the bootstrap as discover -> decide -> bind -> transfer. That
linear drawing is the full set of responsibilities in order, and it stands.
This document refines it with one fact: Bind is CONDITIONAL. The pipeline
executed for a given boot is one of:

  resolved:    discover -> decide -> (carry selected BE) -> transfer
  unresolved:  discover -> decide -> bind                 -> transfer

Bind runs only on the unresolved branch. The next reader should not assume
Bind runs on every boot; on the Operational path it does not, because there
is nothing to resolve. This is recorded so the conditional shape is explicit
rather than inferred.

## Consequence for Transfer (Part 8)

This refinement resolves a question that the "bind everything" alternative
would have forced onto Transfer. Under that alternative, the Operational
Role would have resolved (via a binding) to the already-selected boot
environment, and Transfer would then face "do I redirect to the environment
already selected, and is that redirect a no-op?" That question touched
Transfer's N2 and N4 and risked Transfer knowing something about roles.

Under this refinement the question does not arise at the contract level.
Transfer receives a concrete destination from the driver and transfers to
it, ignorant of which path produced it (Part 8, N5, N6 intact). The
Operational path hands Transfer the selected boot environment; the
unresolved path hands Transfer Bind's resolved boot environment. Transfer
never knows which, and never knows the role. Whether transferring to the
already-selected boot environment requires invoking the redirect primitive
at all, or is a no-op the driver can skip, is an implementation detail of
Transfer and the driver, not a design tension: it does not reach Transfer's
contract, which is simply "one boot environment in, control transferred
once." Part 8 is unchanged; this is a note on why its contract stays clean.

## What this makes implementable

bind() is now smaller than the "bind everything" model would have made it.
There is no Operational binding, no Operational lookup, and no binding table
entry for a role whose destination is already known. bind() exists to
resolve roles requiring resolution, of which Recovery is the first, and its
behavior on a role it cannot resolve is to surface a failure (Part 7, N3),
not to choose.

The binding representation Part 7 deferred is correspondingly smaller: it
must name the implementation of each role requiring resolution, beginning
with the Recovery Role's boot environment. Whether that name has a loader-stage
producer today, or is (like operator_recovery_request in Part 12) a value
that is unavailable until a producer is built, is the next design point for
the Bind implementation, and is settled there against the Part 7 acceptance
criteria. This document fixes the shape (Bind resolves roles requiring
resolution; the driver dispatches; Transfer receives a concrete
destination); the Recovery binding's concrete source is fixed at
implementation.

## Summary

  - A binding exists only where there is something to bind. The Operational
    Role has nothing to bind: its destination is the already-selected boot
    environment Discover observed.
  - Bind resolves roles requiring resolution: roles whose implementation is
    not determined by discovered loader state. Recovery is the first;
    future roles join or leave Bind's domain by the same information-flow
    test.
  - The bootstrap driver dispatches on the role: Operational carries the
    selected boot environment forward; a role requiring resolution is
    resolved by bind(). The dispatch is composition, not a new
    responsibility.
  - Bind is conditional in the pipeline: it runs only on the unresolved
    branch.
  - Transfer receives a concrete destination from either path and stays
    ignorant of roles; the idempotent-redirect question the alternative
    raised does not reach its contract.
  - The Part 7 and Part 8 contracts are unchanged. This document fixes the
    one specific Part 7 deferred, by showing the binding is smaller than
    first assumed.

Status: RATIFIED (operator, 2026-07-02); fixes the Bind domain and the
role dispatch, refining Part 7 and noting Part 8. Precedes the bind()
implementation and the driver dispatch.

Bench: none (design refinement). First exercised when bind() and the driver
dispatch are implemented and run at loader stage per the Part 3 method,
where the Operational path (the only path with a producer today) carries the
selected boot environment forward and the unresolved path awaits the
Recovery binding's producer.
