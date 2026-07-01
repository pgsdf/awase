# AD-59 Part 5: Discover Contract

Status: DRAFT CONTRACT.

This document defines the contract for the Discover responsibility (Part 4),
the first responsibility to be implemented. It is written before any code,
and it is the acceptance criteria for the first implementation of
discover(): an implementation is correct if and only if it satisfies every
obligation here.

The contract follows the discipline used throughout AD-59: contract before
implementation, observation before interpretation, architecture before
mechanism. Discover is the observation stage; the obligations below keep it
strictly observational.

## Purpose of Discover (recap from Part 4)

Discover gathers the minimal information required for Decide, and nothing
more. It has no independent purpose: it exists only to satisfy Decide, and
the moment every input Decide requires is available, Discover is finished.
Any further observation or state collection is, by definition, outside its
responsibility.

Discover gathers the loader-stage observable state that policy will use to
distinguish the boot cases (for AD-59, which operating environment to
select). It stays neutral about which policy model applies: it does not
gather "recovery requested," it gathers the observable state, whatever that
state is, that policy requires to distinguish the cases. How that state came
into existence is not Discover's concern.

## Positive obligations (what Discover must do)

  P1: Observe. Discover reads the loader-stage observable state that Decide
      requires. Reading only; it collects facts as they are.

  P2: Return. Discover returns those observations to its caller as data. The
      return is a set of observed facts, the raw state Decide will evaluate.

  P3: Completeness against Decide. Discover returns every input Decide
      requires to make its selection. Completeness is defined solely by
      Decide's required inputs: Discover is complete when, and only when,
      all of Decide's inputs are present in what it returns.

  P4: Stop at completeness. Once every input Decide requires is present,
      Discover is finished. It performs no further observation. This is the
      hard stopping point: Discover's scope is exactly Decide's input set,
      no larger.

## Negative obligations (what Discover must not do)

  N1: No interpretation. Discover does not decide what the observations
      mean. It does not conclude "recovery," "the OE is bad," "boot the RE,"
      or any other judgment. It returns observations; interpretation belongs
      to Decide.

  N2: No policy. Discover contains no policy logic. It does not weigh
      inputs, apply rules, prefer one environment, or encode any part of the
      selection decision. It gathers the inputs policy will use; it is not
      policy.

  N3: No side effects. Discover does not modify system, loader, or
      environment state. It does not set variables, write files, change
      selection, or alter anything it observes. Observation is read-only.
      (This is what makes Discover safe to run and safe to run again: it
      changes nothing.)

  N4: No collection beyond Decide's inputs. Discover does not gather state
      that Decide does not require, however easy or tempting. Extra
      collection is the path by which an observer quietly becomes a policy
      engine, and N4 forecloses it. If a piece of state is not one of
      Decide's inputs, Discover does not gather it.

## Return shape (architectural, not mechanical)

Discover returns observed facts: the values of the loader-stage state Decide
requires. The contract does not fix the representation (a record, a set of
fields, whatever the implementation environment makes natural); it fixes
only that the return is OBSERVATIONS, not a decision, and not a role. The
boundary between observation and interpretation is exactly the boundary
between Discover's output and Decide's input.

## Dependency on Decide's inputs (a deliberate open item)

Discover's contract is completely determined by Decide's required inputs
(P3, P4). Those inputs are the subject of Decide's own contract, which is
not yet written. This is intentional and consistent with the architecture:
Part 4 establishes that information is derived from responsibilities, and
Decide's inputs are derived when Decide's contract is defined.

Until Decide's contract exists, Discover's contract is complete in its
SHAPE (observe, return, be complete against Decide, stop, and the four
negative obligations) but not yet in the specific FIELDS it returns, because
those fields are exactly Decide's inputs. The recon established the KIND of
state involved: loader-stage observable state that policy uses to select the
operating environment, obtained by loader-stage means, and explicitly not
the post-kernel recovery machinery of AD-11 (the rc.d boolean, the marker
file, Alt-in-rc.d), which lies after Transfer and outside Discover's scope.

So the implementation of discover() proceeds in two steps, in order:
  1. Define Decide's required inputs (Decide's contract).
  2. Implement discover() to observe and return exactly those inputs,
     satisfying every obligation here.

Writing discover() before step 1 would violate the discipline: Discover
cannot be complete against Decide (P3) until Decide's inputs are defined.

## Acceptance criteria for discover()

An implementation of discover() is accepted if and only if:

  - it observes and returns the loader-stage state that constitutes Decide's
    required inputs (P1, P2, P3);
  - it stops once those inputs are present and gathers nothing further
    (P4, N4);
  - it performs no interpretation and encodes no policy (N1, N2);
  - it has no side effects and is safe to run repeatedly (N3);
  - it is written to be portable into the future Awase loader: expressed in
    terms of the Discover responsibility, using loader-specific idioms only
    where essential, with a narrow interface (per the Part 4 relationship to
    BOOT-PATH-OWNERSHIP).

These criteria are the standard against which the first discover()
implementation is reviewed.
