# AD-59 Part 2: Bootstrap Architecture

Status: DRAFT DESIGN.

This document designs the bootstrap architecture that satisfies the AD-59
Part 1 recovery guarantees (RG-1 through RG-6). Unlike Part 1, which is a
contract (obligations only), this is a design: it proposes structure. Each
structural choice is justified against the Part 1 guarantees rather than
asserted. The entry trigger and storage mechanisms are deliberately left
to Part 3 (implementation); they do not change the architecture and are
named as open questions at the end.

## The architecture in one sentence

  Roles define obligations, policy binds roles to implementations, the
  bootstrap selects a role, and the selected implementation fulfills that
  role's obligations.

Each clause introduces exactly one actor (roles, policy, bootstrap,
implementation). No actor appears twice, and no actor owns another's
responsibility. The rest of this document expands that sentence.

## The core idea: transport, not recovery

The bootstrap does not recover the system. Its only job is to transport
the administrator into the environment that performs recovery. Once that
environment is running, the bootstrap is finished.

This is the decomposition that makes the design work. Recovery is NOT a
pre-boot activity. Recovery is a normal userspace application running
inside a dedicated environment. The bootstrap performs pre-boot SELECTION,
not pre-boot recovery. Stating it this way prevents feature creep into the
loader, which is a primitive place to implement anything: poor interface,
hard to evolve, hard to test, almost no libraries. Its one virtue is that
it runs before the kernel, so it should do only the one thing that
requires running before the kernel: select which environment to boot.

## Five separations

The architecture is built from five separations. Each names a concern, not
a packaging.

  1. Transport vs. environment. The bootstrap transports; the environment
     recovers. The bootstrap never performs recovery or administration.

  2. Role vs. implementation. The bootstrap selects a ROLE; a boot
     environment IMPLEMENTS a role; policy BINDS the two. The bootstrap
     never reasons about datasets, snapshots, or ZFS.

  3. Identity vs. capability. A role is a contract, not a label. "Recovery
     Environment" does not mean a particular dataset; it means "an
     environment that satisfies the Recovery Role's obligations." This
     separates which implementation is bound (identity) from whether it
     meets the role (capability).

  4. Owner vs. reader. The authority that performs promotion under AD-58
     OWNS the role binding. The bootstrap only READS it. This keeps the
     bootstrap from becoming a policy engine.

  5. Obligation vs. capability. A role defines OBLIGATIONS that must always
     hold; an implementation supplies CAPABILITIES; promotion is the proof
     that the capabilities satisfy the obligations. This is the bilateral
     reading of "roles are contracts," and it is what explains why the
     architecture is stable.

## Roles are bilateral contracts

A role defines obligations. An implementation provides capabilities.
Promotion verifies that the capabilities satisfy the obligations. Binding
assigns a verified implementation to the role.

  Role            defines obligations
       |
  Implementation  provides capabilities
       |
  Promotion       verifies capabilities satisfy obligations
       |
  Binding         assigns implementation to role

Every step has exactly one purpose. This chain is where AD-58 is placed
precisely: AD-58 promotion is the proof that an implementation's
capabilities satisfy a role's obligations. AD-58 was never about dataset
names; it certifies capability against a role. AD-58 and AD-59 are
therefore two sides of one contract, with promotion as the verifier
between them.

### The Recovery Role's obligations

The Recovery Role must always satisfy, regardless of which implementation
is bound to it:

  - boots successfully,
  - is independently verified,
  - is reachable when the Operational Role's implementation is not,
  - contains recovery tooling,
  - provides authenticated administration,
  - never depends on the Operational Environment.

These are obligations of the ROLE, not properties of any dataset. Any boot
environment that wishes to become the Recovery Environment must satisfy
them, and AD-58 promotion is how that satisfaction is proven. This is the
gate: an implementation becomes the RE only by demonstrating it meets the
role's obligations.

## The two roles today (the architecture supports N)

Today there are two roles:

  Operational Environment (OE): the normal system. Discipline: rapid
    iteration, development, new features, experimental kernels. This is
    where experimental work, including risky kernel changes, happens.

  Recovery Environment (RE): the environment that performs recovery.
    Discipline: intentionally conservative. It changes only through
    explicit promotion after independent verification. (This is stated
    directly rather than by analogy to firmware, which would import
    implications, immutable images, vendor update control, hardware
    coupling, that are not part of this architecture. The property that
    matters is simply: changes only through promotion after verification.)

The architecture does not depend on there being exactly two roles. It
supports any number. Installer, Diagnostics, Factory Reset, and Secure
Update could be added as additional roles WITHOUT changing the bootstrap,
because the bootstrap's operation is role-invariant: resolve the requested
role to an implementation and boot it. New architectural concepts extend
the system by adding policy and implementations, not by modifying the
bootstrap. That the loader need not change to add a role is the sign the
abstraction is at the correct level.

## The Recovery Environment is a recovery operating system

The RE should be understood as a recovery operating system, not as "a boot
environment." A boot environment is merely how it is delivered. Users boot
into a Recovery OS; the boot environment is the packaging. This keeps the
focus on what the RE provides rather than how it is stored.

pgsd-sessiond runs inside the RE and provides the authenticated recovery
console: it authenticates the administrator, then presents recovery
operations. Because the RE is a full operating system that has already
booted successfully, pgsd-sessiond and the recovery console run in a
known-good environment, not in the possibly-broken Operational
Environment. This is what reconciles a graphical, authenticated recovery
console with RG-3: the console lives in an environment guaranteed to boot,
reached by selecting the Recovery Role before the Operational Role's
implementation is ever attempted.

## The bootstrap is trivial

Given the separations above, the bootstrap reduces to:

  role = determine_requested_role()
  implementation = lookup(role)
  boot(implementation)

No recovery logic. No administration. No diagnostics. No policy ownership.
No knowledge of datasets or ZFS. Just role resolution and transfer of
control. This is the kind of code that can remain stable for years,
precisely because it has one responsibility and no authority over the
binding it reads.

## The dependency graph is one-way

  AD-58
    |  owns role assignment (promotion binds a verified implementation)
    v
  Role Binding
    |  read-only
    v
  Bootstrap
    |  boots
    v
  Recovery Environment

Every arrow is one-way; there are no cycles. The acyclicity is the same
structure as the one-sentence summary: each actor hands off to the next
and nothing reaches back. AD-58 owns the binding; the bootstrap only reads
it; the bootstrap boots the environment. The bootstrap cannot become a
policy engine because it has no write authority over the binding, and the
binding cannot depend on the bootstrap because the dependency runs the
other way.

## The full layering

  Bootstrap
      | selects a role
      v
  Role  (Operational Role / Recovery Role)   -- defines obligations
      | policy binds role to implementation
      v
  Boot Environment                            -- provides capabilities
      | executes
      v
  System
      OE -> normal system
      RE -> pgsd-sessiond -> recovery console

The bootstrap selects roles; roles are implemented by boot environments;
boot environments execute systems. Changing how a role is implemented does
not move the architecture.

## How the design satisfies the Part 1 guarantees

  RG-1 (independent known-good path): the Recovery Role's implementation is
    bound and verified independently of the Operational Role's. Recovery
    does not depend on the OE's implementation in any way.

  RG-2 (no dependence on unavailable information): the recovery console
    runs in the RE and presents recovery operations (enumerated boot
    environments, the current default) rather than requiring the
    administrator to recall datasets or syntax. Selection happens through
    presented options, not remembered ones.

  RG-3 (reachable under primary failure): the bootstrap selects the
    Recovery Role and boots the RE WITHOUT attempting the Operational
    Role's implementation. The path that recovers never touches the thing
    that may be broken, so it is reachable precisely when the OE is not.

  RG-4 (independently testable): selecting the Recovery Role is a normal
    operation that can be performed on a healthy system at any time. The
    recovery path can be exercised on demand without inducing a failure.

  RG-5 (validity requires exercise): because the RE is a normal bootable
    environment selected by a normal operation, exercising it is
    straightforward, and the RE's conservative discipline (change only
    through promotion after verification) keeps an exercised-and-verified
    state stable.

  RG-6 (graceful degradation): roles and implementations are independent,
    so additional recovery implementations or roles can provide alternate
    paths. The architecture prefers independent paths (distinct
    implementations bound to recovery-capable roles) over a single
    critical path.

## Open questions (Part 3, implementation)

These remain, and none of them change the architectural relationships
above. They are implementation questions for Part 3:

  - WHO owns the role binding, and where is it stored. The owner is the
    AD-58 promotion authority (established above); the storage must be
    readable by the bootstrap at selection time and must survive a broken
    Operational Environment, so it cannot live inside the OE. The exact
    storage location and format are implementation details.
  - How the bootstrap reads the binding at selection time.
  - How the entry trigger requests the Recovery Role (a key, a prompt, a
    menu, or other). This is an implementation detail; the architectural
    decision is only the separation between selecting the Operational Role
    and selecting the Recovery Role.
  - How AD-58 promotion updates the binding.

Because these are downstream of a settled structure and cannot move the
architectural boundaries, the architecture is considered complete for the
purpose of proceeding to design review. Part 3 (implementation) carries the
boot-path risk and must preserve a known-good boot path at every step and
exercise any new path (RG-5) before relying on it.
