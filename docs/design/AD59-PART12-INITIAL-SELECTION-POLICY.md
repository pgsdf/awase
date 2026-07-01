# AD-59 Part 12: Initial Selection Policy (Selection Policy v1)

Status: DRAFT POLICY.

This document is the initial selection policy: the first policy artifact
that decide() will evaluate, expressed in the Part 11 semantics over LOM v1
(Part 10). It is deliberately a document and not code, because the policy is
the one place in the bootstrap where meaning lives (Part 11, "Where
interpretation now lives"), and meaning is ratified here before machinery
applies it. The evaluator (decide()) is implemented after this policy and
the Part 11 semantics are ratified, per the sequence: policy artifact,
evaluation semantics, evaluator, bench.

## The policy

Selection Policy v1. LOM version: 1. Predicate language: v1 (Part 11).
Roles: the AD-59 Part 2 roles.

  R1: operator_recovery_request == present  -> Recovery Role
  R2: otherwise                             -> Operational Role

That is the entire policy.

## Value domain note: present, not requested

Earlier working discussion phrased R1 as "operator_recovery_request ==
requested." This document deliberately writes "present," and the difference
is the Part 9/Part 10 observation/conclusion rule. Part 10 defines the
observation as "the signal is present/absent/unavailable," explicitly NOT
the conclusion "recovery is requested," which it names a policy judgment.
This policy is exactly where that judgment is made: R1 is the judgment
"when the loader-stage operator signal is present, recovery is requested,"
rendered as a rule. The observation vocabulary stays observational; the
conclusion lives here, in the one artifact entitled to draw it.

## Why this rule is first

AD-59's ratified guarantee set begins from RECOVERY PRECEDES ADMINISTRATION,
and RG-3 requires that a recovery request select the Recovery Role without
attempting the Operational path. A selection policy honors that by
consulting the operator recovery signal before anything else, and Policy v1
consults it and nothing else: the recovery question is asked first because
in v1 it is the only question. The Operational Role is the terminal default,
which matches the architecture's posture that recovery is entered by
explicit selection, not by fallthrough accident.

## Behavior today: a complete policy, honestly evaluated

The operator_recovery_request producer is not built (Part 10 producer
table: the AD-11 D4 loader-stage mechanism is future work), so today the
observation is unavailable on every boot. By Part 11 E1, R1's predicate is
therefore false, evaluation falls through to R2, and the policy selects the
Operational Role on every boot.

This is not a placeholder behavior; it is the policy's defined behavior
over the observations that exist. The policy is complete over LOM v1, and
it honestly reflects that no operator signal can be observed yet, rather
than assuming a producer that does not exist. The Operational default is
not a special case anywhere: not in the policy (it is the terminal rule),
not in the evaluator (E1 makes the sentinel fail the match with no
unavailable handling at all). The sentinel does its job by simply not
matching.

## Behavior when the producer arrives

When the AD-11 D4 loader-stage mechanism is built, it becomes the
operator_recovery_request producer (Part 10), and the field moves from
unavailable to a reported present or absent. From that boot onward, this
policy, unchanged, selects the Recovery Role when the signal is present.

Nothing changes to activate this: not the policy, not the evaluator, not
Discover's interface, not the LOM vocabulary. The producer's arrival is
data arriving, not code changing. That property is the payoff of the whole
layering (versioned vocabulary, explicit unavailability, policy as
artifact, generic evaluator), and it is worth recording as the test the
layering was built to pass.

## What Policy v1 does not consult

Policy v1 does not consult selected_boot_environment,
available_boot_environments, promotion_state, or boot_generation. The
reasons:

  - promotion_state and boot_generation are unavailable today, and unlike
    operator_recovery_request, no ratified rule yet defines what a policy
    should conclude from them. Writing rules over them now would be
    speculation ahead of AD-58's write path and the boot-generation design.

  - selected_boot_environment and available_boot_environments are available,
    but Policy v1 has no decision that needs them. The Part 6 dependency
    note is explicit that Decide consumes what policy requires; a policy
    that reads observations it does not use is the policy-side mirror of
    Discover's N4 violation.

Future policy versions (promotion awareness, boot-generation health
inference, rollback selection) will consult these observations. Each such
consumption is a new policy version, an explicit ratified act, evaluated by
the same decide().

## Well-formedness (Part 11 checklist)

Verified at this ratification, per Part 11 ("Well-formedness is a
ratification obligation"):

  - R1's field, operator_recovery_request, is in the LOM v1 vocabulary (W1).
  - R1's value, present, is a value the field's eventual producer reports
    (Part 10 value domain), and is not the sentinel (W2).
  - The terminal rule R2 is present, so the policy is total and
    deterministic.
  - Both roles are the Part 2 roles; the policy names no boot environment,
    no dataset, and no binding, preserving Decide's N2 and its ignorance of
    N5 through N8.

## Relationship to the contracts

Discover (Part 5) already returns everything this policy reads: Experiment 5
observed discover() reporting operator_recovery_request (unavailable today)
at loader stage. Decide (Part 6) is satisfied structurally: evaluating this
policy consumes only Discover's output and produces exactly one Part 2 role.
Bind (Part 7) then resolves that role to an implementation; this policy does
not know or care how. The pipeline for the first end-to-end decision is
therefore: discover() (implemented, proven), Selection Policy v1 (this
document), decide() (next, against Part 11), Bind and Transfer (their
contracts, in turn).

Status: DRAFT POLICY; Selection Policy v1, the first artifact decide() will
evaluate. Companion to Part 11.

Bench: none (design artifact). First exercised when decide() is implemented
and run at loader stage in the instrumentation BE per the Part 3 method,
where the expected result today is the Operational Role on every boot.
