# AD-59 Part 11: Policy Evaluation Semantics

Status: DRAFT SPEC.

This document defines the semantics by which decide() evaluates a selection
policy over the Loader Observation Model. It is written before any decide()
code, together with Part 12 (the initial selection policy), and the two
documents jointly precede the evaluator: the policy is the rules, this
document is how rules evaluate, and decide() is the machinery that applies
the one to the other.

The document exists because of a separation found while preparing to
implement decide(): decide() should not CONTAIN the selection policy, it
should EVALUATE one. The policy is its own artifact (Part 12); decide() is a
generic evaluator that applies whatever policy it is given. This is the same
coupling-avoidance that shaped the LOM (loader-derived, not policy-derived):
when richer policies arrive (promotion awareness, boot generation, health
inference, rollback), the policy evolves without rewriting decide(). The
evaluation machinery is written once; the rules change above it. It also
makes three layers independently testable: observations (Discover, proven by
Experiment 5), rules (a policy artifact, inspectable as data), and
evaluation (a pure function, exercisable in isolation).

## Terminology: selection policy

The Part 2 spine uses "policy" for the binding: "policy binds roles to
implementations." That policy is Bind's subject (Part 7). What Decide
evaluates is a different artifact: the rules that select a role from the
observations. To keep the two from sharing a word, this document and Part 12
call Decide's artifact the SELECTION POLICY. Where this document says
"policy" unqualified, it means the selection policy. The binding is never
called a policy in the Part 11 and Part 12 documents.

## The shape of a selection policy

A selection policy is an ordered list of rules. Each rule is a predicate
over the LOM paired with a role:

  rule:  predicate -> Role

The final rule of every policy is the terminal rule, whose predicate is
"otherwise" (always true):

  otherwise -> Role

Evaluation is first-match-wins: the evaluator applies each rule's predicate
in order against the observation object and returns the role of the first
rule whose predicate is true. Because the terminal rule always matches, two
properties hold by construction:

  Totality:    every observation object produces a role. There is no input
               on which the policy is silent.

  Determinism: evaluation of a given policy over a given observation object
               always produces the same single role.

These structural properties are what let the evaluator satisfy the Decide
contract's P2 (exactly one role) and N3 (never multiple candidates)
mechanically rather than by care: a well-formed policy cannot produce zero
roles or two.

## The predicate language (v1)

Predicate language v1 contains exactly one predicate form:

  observation_field == concrete_value

with two well-formedness requirements:

  W1: observation_field is a field of the LOM vocabulary at the version the
      policy declares (a policy is pinned to a LOM version, as consumers of
      a versioned data contract must be).

  W2: concrete_value is a value the field's producer can report. It is
      never the unavailable sentinel. A policy that compares a field
      against unavailable is malformed under v1.

The predicate language is versioned exactly as the LOM is: adding a
predicate form (negation, set membership, comparison against unavailable
itself, derived facts such as the Recovery-environment-present derivation
noted in Part 10) is a new version and an explicit act, not an implicit
consequence of a policy wanting more expressiveness. W2 in particular is a
v1 restriction, not a permanent rule: Part 10 establishes that producer
absence is itself observable state, so a future language version could admit
testing for it deliberately. Version 1 excludes it because no v1 rule needs
it and minimality is the discipline.

## Evaluation against unavailable (the load-bearing rule)

Any LOM field's value may be the unavailable sentinel (Part 10). The whole
design rests on one rule for how predicates meet that sentinel:

  E1: a predicate testing an observation for a concrete value evaluates to
      FALSE when the observation is unavailable. Not an error, not unknown,
      not a skipped rule: false.

E1 is what makes declarative defaults work. Consider the initial policy
(Part 12): recovery on operator request, otherwise operational. With E1, an
unavailable operator_recovery_request simply fails the match and evaluation
falls through to the terminal rule; the operational default EMERGES from the
rule order. Without E1 the evaluator would need a special case ("if the
field is unavailable, treat the rule as...") and every such special case is
policy leaking into machinery, which is the coupling this separation exists
to prevent.

E1 is stated representation-independently, and that matters. In the current
mechanism the sentinel is the string "unavailable" and plain equality
satisfies E1 by accident of representation: the sentinel never equals a
well-formed concrete value (W2), so the match fails naturally and the
evaluator contains no unavailable handling at all. That is the desired
implementation, but it is a consequence of E1, not its definition. A future
representation (the Awase loader may represent observations as tagged
values) must preserve E1 explicitly: however unavailability is represented,
a concrete-value predicate over an unavailable observation is false.

## What the evaluator must remain ignorant of

The Decide contract (Part 6) defines Decide's ignorance in N5 through N8.
The evaluator inherits all of it, and the separation adds ignorance of its
own:

  E-N1: Which policy. decide() knows how to evaluate rules; it does not know
        which rules it is evaluating. No rule, field name, value, or role is
        written into the evaluator. A policy change is a change to the
        policy artifact and to nothing else.

  E-N2: What fields mean. The evaluator applies predicates to named fields
        as opaque data. It attaches no meaning to operator_recovery_request
        or any other field; meaning lives in the policy's choice of rules.

  E-N3: Unavailability as a concept. The evaluator contains no test for the
        sentinel and no branch on it. E1 is satisfied by the predicate
        semantics (a concrete-value match fails), not by evaluator logic.
        If an implementation of decide() finds itself inspecting a field
        for unavailability, the separation has been violated.

## Where interpretation now lives

Part 6 observes that Decide is the one responsibility that interprets: the
single point where meaning enters. The policy/evaluator separation sharpens
that observation. Interpretation lives entirely in the selection policy,
which is data; the evaluator is as mechanical as Discover, Bind, and
Transfer. The pipeline's machinery is now mechanical end to end, and the
meaning is confined to one small, inspectable, ratified artifact. The Part 6
warning that Decide "has the standing to overreach" is answered
structurally: the evaluator cannot overreach because it decides nothing, and
the policy cannot overreach because it executes nothing.

## Well-formedness is a ratification obligation, not a runtime check

A selection policy is a ratified artifact of this project, like the
documents that define it. It is not runtime input from an untrusted source.
Well-formedness (W1, W2, terminal rule present, roles drawn from Part 2) is
therefore verified by inspection at ratification, and decide() may assume a
well-formed policy without defending against malformed ones. This is the
project's containment discipline (isolation, not code defensiveness) applied
to policy: the guard is the ratification review, not evaluator checks.

## Acceptance criteria for the evaluation semantics

An implementation of decide() conforms to this specification if and only
if:

  - it evaluates an ordered rule list first-match-wins and returns exactly
    the matched rule's role (totality and determinism as defined above);
  - predicate evaluation satisfies E1: a concrete-value predicate over an
    unavailable observation is false, with no error and no special case;
  - it satisfies E-N1 through E-N3: no rule, field meaning, or
    unavailable-handling is present in the evaluator;
  - it continues to satisfy the whole Decide contract (Part 6): LOM in,
    one role out, ignorant of N5 through N8;
  - it is portable into the future Awase loader: the evaluator is a pure
    function over the observation object and the policy, with no
    loader-specific code (the loader-specific code in the module remains
    confined to Discover's producers).

These criteria, together with Part 12's policy, are the standard against
which the first decide() implementation is reviewed, in the same rhythm
that Experiment 5 applied to discover().

Status: DRAFT SPEC; evaluation semantics for decide(), preceding its
implementation. Companion to Part 12.

Bench: none (design specification). Validation arrives with the decide()
implementation, exercised at loader stage in the instrumentation BE per the
Part 3 method.
