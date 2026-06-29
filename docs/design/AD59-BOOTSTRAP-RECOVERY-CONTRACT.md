# AD-59: Bootstrap Recovery Contract

Status: RATIFIED DESIGN CONTRACT (operator, 2026-06-28); drafted
2026-06-28.

This document specifies the GUARANTEES a recovery-capable bootstrap must
satisfy. It is a contract, not a design and not an implementation. It is
centered on reachability, not on features or user interface. No bootstrap
mechanism is proposed here, and no entry trigger (a key, a menu, a prompt)
is chosen; those are downstream of this contract and must be justified by
it. Beginning from the interface would let the first implementation idea
become the requirements, which this contract exists to prevent.

## Purpose

Establish, before any bootstrap is designed, the properties any
recovery-capable bootstrap must satisfy. The properties are about whether
recovery can actually be reached and used when everything else has failed,
not about how a menu looks or what conveniences it offers.

## Motivation

Recovery mechanisms are only useful if they can be reached and exercised
under the conditions that require them. A recovery capability therefore
consists of two distinct properties: a valid recovery TARGET and a
reachable recovery PATH. A valid target with no reachable path is not a
recovery capability; it only appears to be one until the moment recovery
is actually needed.

The contract is centered on the second property, reachability, because it
is the one most easily assumed and least easily guaranteed: it is natural
to confirm that a recovery target exists and boots, and to take that as
evidence that recovery is in place, when the path to the target under
failure conditions has never been established. (The specific incident that
prompted this contract is recorded in commit history, not here, so the
contract remains independent of any one event.)

## Relationship to AD-58 (the complementary half)

AD-58 (Verified System Lifecycle) established that a recovery point must be
verified before it is promoted: it answers the question "does recovery
exist?". This contract establishes the complementary operational
principle: a verified recovery point has no operational value unless it is
reliably reachable. It answers the question "can an administrator actually
use recovery when everything else has failed?".

These are two halves of one recovery story. AD-58 ensures the recovery
point is real; this contract ensures the path to it is real. The
motivating event demonstrated that BOTH are required: AD-58's half worked
(the recovery point was verified and bootable) and recovery still nearly
failed because the path was not reachable.

## Recovery guarantees

### RG-1: Independent known-good path

A known-good boot path shall remain available regardless of the state of
the default boot environment. The default boot environment becoming
unbootable shall not remove or obscure the known-good path.

### RG-2: No dependence on unavailable information

Recovery shall not depend upon information that is unlikely to be
available under failure conditions. This includes loader syntax, dataset
names, device identifiers, special key sequences, and similar operational
knowledge. Information required to recover shall be presented by the
recovery mechanism rather than assumed to be remembered.

### RG-3: Reachable under primary failure

Recovery shall remain possible when the primary boot environment or its
kernel is unbootable. Recovery must work precisely in the condition that
makes it necessary; a path that only works when the system is already
healthy is not a recovery path.

### RG-4: Independently testable

The recovery path shall be independently testable. It shall be possible to
exercise the recovery path on demand, on a healthy system, without first
inducing a real failure.

### RG-5: Validity requires exercise

A recovery procedure is not valid until it has been exercised
successfully. This is the AD-58 verification principle applied to the
recovery path itself: the existence of a recovery mechanism is not
evidence that it works; only a successful exercise of it is. An
unexercised recovery path shall not be relied upon operationally; it may
in fact work, but until exercised it is not treated as dependable.

### RG-6: Graceful degradation of recoverability

Failure of one recovery mechanism shall not eliminate all recovery
mechanisms. Independent recovery paths are preferred over a single
critical path, so that the loss of any one path leaves recovery still
possible by another.

## Scope of the first version (intentionally narrow)

The administrator recovery capability shall, in its first version, answer
exactly one question: "How do I recover from a failed boot?" The initial
capability set is therefore limited to recovery operations:

  - select an alternate boot environment,
  - boot that environment,
  - boot single-user when necessary,
  - list available boot environments,
  - display the current default.

The first version shall NOT include rollback, arbitrary boot-parameter
editing, diagnostics, or general boot management. Those broaden the scope
from a recovery bootstrap into a boot-management console, which is a
different and larger artifact. Recovery is the immediate requirement;
expansion is deferred until the recovery model is proven. Keeping the
boot-path surface small also reduces the ways a boot-path change could
itself render the system unbootable, which would be self-defeating given
the contract's purpose.

The governing principle is RECOVERY PRECEDES ADMINISTRATION. It is the test
for any future proposal: if a proposal improves recovery, it belongs in
the recovery capability; if it improves administration but not recovery,
it waits. This keeps the recovery bootstrap from accreting into a general
boot-management console before recovery itself is proven.

## Out of scope

This contract does not:

  - propose a bootstrap mechanism or architecture,
  - choose an entry trigger (key, menu, prompt, or other),
  - select an implementation substrate (the FreeBSD Lua loader, a custom
    menu, or any other),
  - specify a user interface.

Those belong to later layers (Part 2 bootstrap architecture, Part 3
implementation), each justified by the guarantees above.

## Next layers

Once these guarantees are ratified:

  Part 2 (bootstrap architecture): design a two-mode bootstrap, a normal
    boot path for everyday use and an administrative recovery path entered
    deliberately, justified against the guarantees here. The architectural
    decision is the SEPARATION between normal operation and recovery; the
    entry trigger remains an implementation detail.

  Part 3 (implementation): decide the substrate (FreeBSD Lua loader,
    custom menu, or other) and implement, with the care that boot-path
    changes demand: a known-good boot path preserved throughout, changes
    exercised on a recovery environment first, and incremental steps, so
    that the work to improve recoverability cannot itself destroy it.

## Note on implementation risk (for later layers)

Boot-path changes can render a system unbootable, which is the exact
failure this contract exists to prevent. The contract and the architecture
(Parts 1 and 2) are design work and carry no such risk. The implementation
(Part 3) does, and must be approached so that a known-good boot path is
preserved at every step and any new path is exercised (RG-5) before being
relied upon.
