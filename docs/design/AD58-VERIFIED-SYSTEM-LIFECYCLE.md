# AD-58: Verified System Lifecycle

Status: RATIFIED 2026-06-28 (operator); drafted 2026-06-28 (operator and
assistant). A project-level
architectural decision, not a kernel-subsystem one: it defines how Awase
transitions a system between states and what authorizes each transition.
The architectural model is what this ADR fixes; implementation concerns
it deliberately leaves open (the exact awase be command surface, the
metadata file format, the install.sh integration, naming of stable
points) are settled separately and do not reopen this ADR.

## Decision

Awase SHALL model every system-altering operation as a transition through
an explicit state machine, and SHALL NOT promote a system to a trusted
state on the basis of successful execution. Promotion to a trusted state
SHALL require successful verification, which is a distinct act from
successful execution and, in general, cannot be performed by the process
that made the change.

The governing invariant, the Promotion Rule, from which the rest of this
document follows:

  ----------------------------------------------------------------
  PROMOTION RULE

  Awase never promotes a system based on successful execution.
  It promotes a system only after successful verification.
  ----------------------------------------------------------------

The remainder of this document gives the rationale, the
state machine, the FreeBSD Boot Environment implementation, the awase be
command model, the metadata that turns committed states into a release
history, and the consequences.

This ADR fixes the lifecycle model and the promotion invariant. It does
NOT fix implementation details (the exact command surface, metadata
format, install.sh mechanics, naming of stable points, AD-57
interaction); those are settled separately, are summarized in the Scope
boundary at the end, and do not reopen this ADR. Reviewers should evaluate
the architecture here, not the implementation.

## Why this is project-level, and why now

This decision was forced by a concrete failure. During AD-56 Phase 0.5
work, a kernel modification caused the display substrate (drawfs) to hang
at EFI framebuffer initialization. Because drawfs was loaded on every boot
via a shared loader setting, and because no clean, drawfs-free recovery
environment had been prepared and verified in advance, the hang was
inescapable and the bench had to be reinstalled. The broken environment,
which was the only thing that reproduced the failure, was destroyed in the
process, so the root cause could not be examined afterward.

Two distinct mistakes produced that outcome, and both are mistakes of
LIFECYCLE, not of code:

  1. A system was treated as trustworthy because a step completed.
     Repeatedly, "the build completed" and "a clean kernel was produced"
     were read as "the system works". Execution success was substituted
     for verification success. It was not until a clean kernel was
     actually built, installed, booted, and observed that any claim about
     it could be trusted, and several intermediate claims turned out to be
     wrong.

  2. The recovery path was assumed rather than verified. A boot
     environment believed to be safe was relied upon without confirming
     it could boot under the failure condition. It could not, because it
     shared the faulty load setting. A recovery path that has not been
     verified is not a recovery path.

Both mistakes have the same shape: a state was promoted (to "working", to
"safe to rely on") without verification. AD-58 makes that shape
impossible to fall into accidentally by naming the states and the
licenses to move between them.

## The state machine

Every system-altering operation moves a system through these states:

  Recovery -> Installing -> Unverified -> Verified -> Released

  Recovery
    A known-good state captured BEFORE any change, whose only purpose is
    rollback. It is frozen: nothing modifies it after creation. It is the
    escape hatch.

  Installing
    The transient state while changes are applied. No durable trust
    claim exists during this state.

  Unverified
    Changes are applied and the operation has COMPLETED, but the result
    has NOT been verified. This is the default post-install state. It is
    explicitly untrusted. Completion of installation is not success of
    installation.

  Verified
    NOT a persistent state but an instantaneous promotion event: the gate
    between Unverified and Released. A human (or an automated check that
    genuinely exercises the system) boots, exercises, and confirms the
    Unverified state works, and in the same act commits it, at which point
    it is Released. Nothing durable sits in Verified; an environment is
    Unverified until the moment it becomes Released. Verification is a
    separate act from the change that produced the state, and in general
    cannot be performed by the installer, because the installer cannot
    reboot into and exercise its own result. Verified is named explicitly
    because it communicates the intent of the gate, even though it
    persists for no time.

  Released
    A Verified state has been committed as an immutable, named snapshot
    and recorded in the system's release history. It becomes a candidate
    future Recovery point.

The critical boundary is between Unverified and Verified. Crossing it is
the only thing that promotes a system to trust, and crossing it requires
verification, never mere completion.

A Boot Environment is the PERSISTENCE MECHANISM for these states on
FreeBSD. It is not the concept. The same state machine governs other
system-altering operations that do not use Boot Environments at all:
package set changes, configuration migrations, semantic repository schema
changes, system updates, and kernel upgrades. Each moves Recovery ->
Installing -> Unverified -> Verified -> Released, whatever the underlying
snapshot or rollback mechanism. Stating the lifecycle independently of
Boot Environments keeps the architecture portable: another platform with
a different snapshot mechanism implements the same lifecycle unchanged.

## FreeBSD implementation: Boot Environments

On FreeBSD with ZFS, Boot Environments implement the states. The design
relies on /boot and /etc being BE-local, so that a change to the running
BE (for example enabling drawfs in loader.conf) does not alter any other
BE. If any system-altering setting is found NOT to be BE-local, that is a
bug to fix at its source, not a condition to work around in this model.

  Recovery       a frozen BE captured before install (awase-pre-install)
  Unverified     the running BE after install (for example awase-dev)
  Released        an immutable BE created by committing a verified state

Only three states persist as Boot Environments, because Verified is an
instantaneous gate, not a durable state: a BE is Unverified until the act
of verification-and-commit makes it Released. There is never a BE sitting
in a "Verified" state.

The Recovery BE is clean by construction: it is captured before Awase
enables anything, so it inherently carries the original loader.conf,
rc.conf, kernel, and boot configuration. It needs no special drawfs
handling, because it predates drawfs being enabled. This is precisely the
property that was missing in the failure that motivated this ADR.

## The awase be command

BE lifecycle policy lives in ONE place, a repository-local command, not
sprinkled as bectl calls through install.sh. Being repository-local
dissolves the bootstrap problem: the command exists in the checkout
before install.sh runs, so install.sh invokes it by path. Installation
MAY later copy it to /usr/local/bin as a convenience, but that is never
an architectural dependency.

  tools/awase be create --pre-install
      Create the Recovery BE. Recovery is a SINGLETON, not a history: if
      awase-pre-install already exists, this is a no-op that reports the
      existing Recovery BE. Recovery is THE escape hatch, identified by
      name, not by timestamp.

  tools/awase be commit [--name NAME]
      Create an immutable, named snapshot of the CURRENT (Verified) state
      and record its metadata in the release history. The current BE is
      unchanged and remains the working environment, exactly as a git
      commit records a point without altering the working tree. Committing
      is the act that promotes Unverified to Released, and the operator
      runs it only AFTER verifying the system.

  tools/awase be list
      List BEs as a RELEASE HISTORY, including each one's status and
      whether it is verified. The current BE is shown explicitly as NOT
      verified. That single fact, visible at a glance, encodes the
      lifecycle: it is always mechanically clear which states have been
      verified and which have not.

  tools/awase be rollback
      Exactly two operations and nothing more: activate the Recovery BE
      and reboot. It NEVER deletes the broken BE. The broken BE is
      EVIDENCE; evidence is never destroyed automatically. If the bug is
      discovered six months later, the environment that reproduced it
      still exists.

  tools/awase be delete
      Explicit operator action to remove a BE. Deletion is never
      automatic and never a side effect of rollback.

## Committed-state metadata and release history

A committed BE is not merely a snapshot; it is a verified release point.
Each committed BE SHALL carry metadata:

  Name           the BE name, for example awase-0.9.2
  Version        the Awase version, for example 0.9.2
  Kernel         the kernel identity, for example PGSD-DEBUG
  Git            the awase commit the system was built from
  Created        timestamp
  Verified       whether the state was verified before commit
  Verified by     the verification method, for example "Operator" or
                 "CI smoke suite"; valuable provenance once verification
                 is partly automated
  Description     a short human description, for example
                 "first verified PGSD build"

This turns awase be list into an auditable release history with
provenance, for example:

  NAME             STATUS      VERSION    VERIFIED
  awase-pre        Recovery     -          yes
  awase-0.9.0      Stable       0.9.0      yes
  awase-0.9.1      Stable       0.9.1      yes
  awase-dev        Current      HEAD       no

The provenance (which git commit and which kernel produced a verified
state) is exactly what was painful to reconstruct during the failure that
motivated this ADR.

## How install.sh uses the lifecycle

install.sh installs software. It does not declare the installation
successful, because it cannot: it cannot reboot into and exercise its own
result. Its responsibilities are reduced to two lifecycle actions:

  1. Before making any change, create the Recovery BE:
        ./tools/awase be create --pre-install

  2. After completing installation, report that the system is Unverified
     and instruct the operator to verify and then commit:

        Installation completed.

        Current BE:   awase-dev   (UNVERIFIED)
        Recovery BE:  awase-pre-install

        Reboot and verify the installation. Once verified, run:

            awase be commit

The language is deliberate. The installer says COMPLETED, never
SUCCEEDED. Only verification, performed by something that actually
exercises the system, can promote it, and that promotion is the operator
running awase be commit.

## Consequences

  - It is structurally impossible to treat "installation completed" as
    "installation succeeded". The Unverified state is explicit and
    untrusted by default.
  - A clean Recovery point always exists before any change, captured
    before Awase enables anything, so it is a true safe haven by
    construction.
  - Rollback is trivial, fast, and non-destructive. Broken environments
    are retained as evidence for post-mortem.
  - The release history (awase be list) carries provenance: version,
    kernel, and git commit for every verified release point.
  - The lifecycle is portable. Boot Environments are one implementation;
    the same Recovery -> Installing -> Unverified -> Verified -> Released
    state machine governs package sets, configuration migrations, schema
    changes, and updates, on FreeBSD or elsewhere.
  - The governing invariant becomes a general design rule for Awase, not
    merely an installer feature: promotion follows verification, never
    execution.

## Scope boundary

This ADR fixes the lifecycle model and the promotion invariant. It does
NOT fix the implementation details, which are settled separately and do
not reopen this ADR: the precise awase be command-line surface and exit
codes, the metadata storage format and location, the install.sh
integration mechanics, the naming scheme for committed stable points, and
the interaction with the AD-57 kernel source pin. Implementation SHALL be
done deliberately on a stable, verified system, where the first use of
awase be commit fittingly certifies that stable system.

## Addendum: the Recovery authority and its publication contract

Status: ADDENDUM, DRAFT (extends the ratified lifecycle architecture; does
not reopen the lifecycle model or the Promotion Rule).

This addendum is architectural. It defines what must be true about the
Recovery authority and its publication; it does not define how publication
is achieved. It ratifies an interface contract at the same abstraction level
as the rest of this ADR, without committing to any publication mechanism.

Terminology, fixed for this addendum and its consumers: PGSD is the
operating system. This ADR defines the PGSD lifecycle architecture. The
awase be command is the implementation of that lifecycle's Boot Environment
operations. AD-59 defines the bootloader architecture that consumes the
Recovery authority published by the lifecycle.

### Why this addendum exists

The lifecycle above establishes a Recovery state and, on FreeBSD, a Recovery
Boot Environment captured before change. It does not establish how the
identity of the current Recovery target is made known to the bootloader.
AD-59 (the bootloader) must, at loader stage, resolve the Recovery Role to a
concrete destination. That resolution requires an authoritative answer to
"what is the current Recovery target," and nothing in the lifecycle so far
publishes that answer in a form the loader can observe.

The naive path would be for the bootloader to recognize the Recovery target
by a known Boot Environment name (today the canonical Recovery BE is a named
singleton in this ADR's FreeBSD implementation). That path is rejected here,
because it would make a Boot Environment name, an implementation detail of
this lifecycle, into an interface between two architectures. The consumer
would be inferring the authority from the owner's implementation rather than
observing a published authority. This addendum forecloses that by defining
an explicit contract.

### The contract

  Ownership. The PGSD lifecycle (this ADR) SHALL be the sole authority for
  designating the Recovery target. No other component originates the
  designation; components may publish or observe it, but the designation is
  the lifecycle's.

  Publication contract. The Recovery authority SHALL be published through an
  interface that is observable at loader stage. That a loader-observable
  publication exists is the architectural requirement; the bootloader
  depends on its existence, not on its form.

  Consumer contract. AD-59 SHALL consume the published Recovery authority.
  AD-59 SHALL NOT infer the Recovery target from Boot Environment names,
  naming conventions, or any other implementation detail of this lifecycle.
  The published authority is the only interface AD-59 is permitted to
  observe for this purpose.

  Implementation ownership. The mechanism by which the lifecycle publishes
  the Recovery authority (for example a loader variable, a pool or dataset
  property, a metadata record, or another means) is an implementation
  concern owned by this lifecycle. It is not part of this architectural
  contract. The architecture requires that a loader-observable authority
  exist; the implementation is free to satisfy that requirement however the
  lifecycle later chooses, under the same scope boundary that governs this
  ADR's other implementation concerns.

### The resulting layering

  - The lifecycle owns Recovery designation.
  - The lifecycle requires that the designation be published in a
    loader-observable form.
  - AD-59 consumes that published designation.
  - Neither ADR exposes Boot Environment names as an inter-ADR interface.

This preserves the separation the project holds elsewhere: an authority is
published explicitly by its owner and observed by its consumer, rather than
inferred from implementation details. It is the same shape as the operator
recovery-request signal (AD-59 Part 15), where an explicit published signal
is observed rather than an intent inferred; here the published item is the
Recovery target designation rather than the operator's request.

### What this addendum does not do

  - It does not choose or constrain the publication mechanism. That the
    authority is loader-observable is required; which mechanism provides
    that is outside this contract and owned by the lifecycle implementation.
  - It does not define the AD-59 producer that observes the authority. That
    producer is an AD-59 concern, specified separately as a bounded "observe
    the published authority" contract once this authority is ratified,
    parallel to the operator_recovery_request producer.
  - It does not reopen the lifecycle model or the Promotion Rule. It adds an
    interface contract consistent with this ADR's existing scope boundary,
    under which implementation mechanisms are settled separately.

Status: ADDENDUM, DRAFT. Ratifying this fixes the Recovery authority's
ownership and publication contract; the publication mechanism and the AD-59
consuming producer follow separately, each within its owner's scope.
