# 0002: the Awase artifact contract

## Status

Ratified, 2026-07-10 (operator), with one editorial condition applied
in this revision: the enduring architectural contract is stated in
the body, and observations about the current Axiom implementation are
confined to a dated, non-normative appendix that may be updated as
Axiom evolves without reopening this ADR.

The second entry in the project-level series. Per the series rule,
the decisions here bind downstream documents and tooling; subproject
series (the installer and future deployment tooling among them)
consume these decisions and do not originate them. Implementation
concerns deliberately left open (exact inventory schema fields,
repository names, package generation) are settled downstream and do
not reopen this ADR.

## Context

This ADR defines the boundary between building Awase and installing
PGSD, and the published contract that crosses that boundary. Its
established inputs:

- AD-57, which solved the same problem for the kernel (the pinned
  fork as producer, the bench as consumer, FREEBSD-PIN as the
  contract) and explicitly deferred the userland generalization:
  "PGSD as a reproducible artifact... the artifact pipeline builds ON
  this ADR: once the kernel is a well-defined recipe, the artifact
  builder has a defined thing to build." This ADR is that deferred
  successor.

- ADR 0001, which ratified deployment, publication, and durability
  contracts for boot artifacts, including the content, publication,
  and selection authority triad, and graduated finding F8 into the
  read-back verification requirement. The principles stated below
  are the same ones 0001 applied to the boot domain; this ADR
  applies them to the userland artifact domain. The two are
  complementary in scope: 0001 governs boot artifacts on the BAS,
  this ADR governs userland artifact sets; neither reopens the
  other.

- The 2026-07 check-reporting defect series and the recurring
  deploy-gap pattern, detailed under "Why this is project-level, and
  why now".

## The principles

Two architectural principles are stated here not as new inventions but
as observed law: the project has independently derived each of them at
least three times, and this ADR is the point at which they graduate
from local decisions to project rules.

### Publish, Don't Infer

A component that is authoritative for information SHALL publish that
information explicitly. Consumers SHALL rely only on published
contracts and SHALL NOT reconstruct or infer producer intent from
incidental structure.

Existing instances:

1. FREEBSD-PIN (AD-57): the kernel source is published as a pinned
   commit; the bench never infers "whatever is in /usr/src".
2. The Recovery designation (AD-58/AD-59): the recovery authority is
   published by the PGSD lifecycle; the loader consumes the
   designation and never infers it.
3. The artifact inventory (this ADR): what constitutes an installable
   Awase is published by the build; the installer never infers it by
   walking a tree or maintaining a parallel list.

### Authority Owns Truth

Every published contract has exactly one producer, and no consumer
may correct, extend, or reinterpret it. The fork owns the kernel pin;
the lifecycle owns the recovery designation; the Awase build owns the
artifact set. A consumer that believes the contract is wrong reports
the defect to the authority; it does not compensate.

## Decision

Building Awase and installing PGSD SHALL be independent systems that
communicate only through a published artifact contract.

The producer (the Awase build) SHALL compile the substrate and stage
the results as an artifact set: a well-defined output tree plus an
authoritative description of that tree. Its only obligation is to
produce complete, verifiable, reproducible artifact sets.

The consumer (the PGSD installation system) SHALL assemble a runnable
system from published artifact sets: placement, configuration,
users and groups, devfs rules, service enablement, and system
integration. It SHALL install exactly what the contract describes,
verifying before acting, and SHALL treat any divergence between the
contract and the tree, in either direction, as a hard error.

Neither side SHALL depend on the internals of the other.

## Why this is project-level, and why now

Three independent lines of evidence converged:

1. The kernel-in-installer defect class. Embedding the kernel workflow
   inside install.sh (the KERNEL_PLAN machinery) wrapped a script
   designed for phase-by-phase operator inspection in a second layer
   of prompts and banners. Every defect in the 2026-07 check-reporting
   work except one lived in that wrapper, not in either script's real
   work. The wrapper exists because the boundary between building and
   installing was never stated.

2. The deploy-gap pattern, already flagged as systemic: new binaries
   are built but never added to install.sh's hand-maintained BINARIES
   list, because the installer infers what should exist instead of
   consuming a published statement of it. This is a Publish, Don't
   Infer violation with a recurring cost.

3. AD-57 solved exactly this problem for the kernel (see Context)
   and reserved space for the userland generalization. This ADR
   extends the same shape to the entire substrate.

## The contract

The contract is the artifact set. Its authoritative description is
carried in two distinct abstractions that SHALL NOT be conflated:

The MANIFEST answers "what package is this": identity (name, version,
revision), outputs, dependencies, and compatibility requirements
(FreeBSD release and KBI for kernel modules, since drawfs.ko and
friends are version-coupled to the kernel).

The INVENTORY answers "exactly which filesystem objects comprise it":
one record per file with path (relative to the set), type, size,
sha256, and suggested mode. The consumer installs the inventory. A
file listed but missing is a producer failure; a file present but
unlisted is a producer failure or tampering. There is no third state,
and the deploy-gap class is thereby structurally impossible rather
than procedurally discouraged.

Artifact identity SHALL be a content hash over the filesystem tree
and its canonical description (a Merkle identity). Two builds of the
same commit SHALL produce byte-identical artifact sets with the same
identity; the SOURCE_DATE_EPOCH=0 discipline extends to the contract
itself (deterministic field ordering, no wall-clock timestamps in
identity-bearing files, stable archive ordering).

PROVENANCE (how the artifact came to exist: builder, toolchain,
flags, source commit) is descriptive metadata. It SHALL be recorded
and SHALL NOT participate in artifact identity. Provenance describes
how the artifact came to exist; it does not change what the artifact
is.

The contract SHALL carry its own version (a manifest-version and
artifact-format field), and consumers SHALL declare the range they
support, so the contract can evolve without breaking older consumers
and without relying on repository history for compatibility.

## Authority factoring

A producer SHALL publish only facts for which it is authoritative.
Everything else belongs to the consumer.

Producer publishes (intrinsic to the artifact): identity, hashes,
sizes, artifact role (daemon binary, kernel module, default config,
session asset), compatibility requirements, provenance, suggested
default mode.

Consumer decides (policy about the target system): installation
destination (PREFIX and layout), ownership (uid/gid such as
_semadraw, which do not exist at build time), final permissions,
service enablement, and site-specific overrides.

The distinction is between suggested metadata (fine) and required
installation policy (forbidden). A producer that publishes
destinations or ownership has leaked target-system knowledge across
the boundary in exactly the direction this ADR exists to prevent.

## Convergence with Axiom

Axiom (github.com/pgsdf/axiom) is the reference implementation of
this architecture: an immutable ZFS-backed store, declarative
profiles, deterministic resolution, and atomic activation, with the
pipeline Build, Store, Index, Resolve, Realize, Activate. Its
artifact contract (a package as manifest, dependencies, provenance,
and a root/ tree) embodies the authority factoring above: the
manifest publishes intrinsic facts, and destination is supplied at
activation.

This ADR converges on the Axiom artifact contract rather than
inventing a parallel one. Convergence is not passive adoption: the
binding requirements on any implementation of the contract are those
stated in "The contract" and "Authority factoring" above, and where
the current Axiom implementation does not yet meet them, the
requirements flow upstream as Axiom enhancements rather than being
weakened here. The architecture is "publish this contract"; Axiom is
the preferred implementation of it.

Observations about the state of the Axiom implementation as of this
writing, including the specific gaps and the operational
prerequisites for milestone 4, are recorded in the appendix. They are
descriptive, dated, and expected to change; they carry no normative
weight and their resolution does not reopen this ADR.

## What remains outside the contract

The kernel. AD-57's pipeline is untouched: the kernel is defined by
FREEBSD-PIN plus the PGSD config, built and installed by
pgsd-kernel-build.sh in operator-inspected phases, per
KERNEL-RECIPE.md. The kernel is not an artifact-set member; it is the
platform the artifact set is built against, and its compatibility
identity (release, KBI) appears in the manifest as a requirement.

System integration. Axiom places files; it does not integrate a
system. Group creation (_semadraw), devfs rules, rc.conf and
loader.conf, module loading, and service management remain a thin
PGSD integration layer. install.sh does not disappear: it sheds
building (to the producer) and eventually file placement (to the
consumer implementation), and converges toward that layer.

## Migration

Five milestones, each an architectural contract milestone rather than
a tool adoption. The implementation named in milestone 4 appears
exactly once; everything before it establishes the contract, so the
architecture is "publish this contract", not "use this tool".

1. Kernel build separated from installation (AD-57 continuation).
   install.sh SHALL NOT build, offer to build, or install the PGSD
   kernel. The KERNEL_PLAN execution machinery, the dialog and
   confirmation helpers, kernel_build_unattended, and the
   --build-kernel flag are removed. RETAINED: the detection gate.
   pgsd_kernel_satisfied() stays; a non-interactive run on GENERIC
   without a PGSD kernel installed for next boot fails fast (exit 3)
   pointing at KERNEL-RECIPE.md; an interactive run completes and
   prints a prominent GENERIC notice. The gate detects and informs;
   it never executes. Rationale: the success criterion "the system
   can run Awase" (07bcca1) is correct independent of who builds the
   kernel, and strict reversal would reintroduce the
   silent-GENERIC-success defect. Documented order of operations:
   userland deploy precedes kernel install, because the kernel
   script's AD-8 closure verification expects /boot/modules/drawfs.ko.

2. Artifact contract established. The Awase build stages
   Axiom-compatible artifact sets (manifest, dependencies,
   provenance, root/ tree) with complete Lockbox-grade inventory and
   Merkle identity, inside the existing repository. Pure data; zero
   runtime dependency on Axiom; verifiable immediately.

3. The existing installer consumes only the published contract.
   install.sh's deploy phase installs the inventory: every file
   verified against its hash before placement, hard failure on
   divergence in either direction. The BINARIES list and all other
   inferred completeness is deleted. Still no Axiom binary in the
   install path.

4. Consumer implementation replaced by Axiom. Import into the store,
   PGSD expressed as a profile, realize and activate replacing the
   thin consumer. Because milestones 2 and 3 already speak the Axiom
   contract, this is a machinery swap, not a format migration, and it
   is reversible. Precondition: Axiom exercised on the bench, and the
   implementation prerequisites recorded in the appendix resolved. Only at this milestone
   does Axiom become load-bearing for bench recovery, and that is a
   deliberate operational decision taken then, not a side effect of
   this ADR.

5. Repository split reflects the established architecture. The
   producer and consumer repositories separate along the
   already-proven contract. Artifact sets are referenced by identity
   (the FREEBSD-PIN pattern), never committed to git: binary
   artifacts in a forward-only history grow it monotonically and
   forever, and git provides nothing useful for them.

## Rejected alternatives

Strict kernel-blind reversal (milestone 1 without the gate): restores
the pre-07bcca1 defect in which --yes on GENERIC deploys everything
and reports a success the system cannot honor.

Bespoke artifact manifest: designing a new contract when the project
already maintains a reference implementation of the same architecture
would create a format destined for replacement and a second authority
for the same truth.

Binaries committed to the consumer repository: rejected per milestone
5; identity-by-reference preserves auditability without unbounded
history growth.

Machinery-first Axiom adoption (milestone 4 before 2 and 3): couples
the contract, the implementation, and the operational dependency into
one irreversible step, and puts an actively-developed system into the
bench recovery path before the contract it implements has been proven
by existing tooling.

## Deferred decisions

Repository names. Recorded proposal, not ratified here: the producer
keeps the name awase (the substrate, the thing that is built); the
consumer takes the PGSD name (the distribution, the composed system),
which the kernel, sessiond, and loader already carry. Suffixes
implying content (-src) are avoided.

Package generation. The mature endpoint of an inventory-bearing
artifact set is a package; generating pkg(8) packages from the
contract is recorded as a mechanical future option and deliberately
not designed here.

Inventory schema. The exact field set (beyond path, type, size,
sha256, mode) and its canonical serialization are settled at
milestone 2 against Axiom's Lockbox format, not in this ADR.

## Consequences

install.sh shrinks at milestone 1 (roughly 200 lines of kernel
execution machinery removed, some 40 retained as the gate) and
changes contract: --build-kernel is removed; the exit-3 fast-fail
remains with revised messaging. KERNEL-RECIPE.md becomes the sole
documented kernel path and is cross-referenced from README and
INSTALL.md.

The deploy-gap backlog item closes structurally at milestone 3.

The two-machine workflow gains its intended shape: pgsd-dev produces
artifact sets, the bench consumes them, and the bench stops building
userland, which also retires the stale-adapter failure class that
deploy-loader.sh currently patches.

Every future "should the installer also..." question acquires a test:
does it concern how software is built (producer), how a system is
composed (consumer), or does it cross the boundary (then it must ride
the contract or be rejected).

## Decisions

Ratified 2026-07-10 as itemized:

1. The two principles (Publish, Don't Infer; Authority Owns Truth) as
   project architectural law.
2. The producer/consumer separation with the artifact set as sole
   interface.
3. The contract structure: manifest and inventory as distinct
   abstractions; identity as content hash over filesystem plus
   canonical description; provenance descriptive and excluded from
   identity; contract self-versioning.
4. The authority factoring (producer publishes intrinsic facts only;
   consumer owns installation policy).
5. Convergence on the Axiom artifact contract; requirements the
   current implementation does not yet meet flow upstream (see
   appendix), and are requirements of the contract, not conditions
   on this ratification.
6. The five-milestone migration, format before machinery, including
   milestone 1's retained detection gate.
7. The deferrals as listed.

## Implementation status

Maintained as milestones land. Entries are dated facts, not
decisions; the decisions above are not reopened here.

- Milestone 1: landed 2026-07-10 and bench-verified the same day on
  both kernels. GENERIC: exit-3 fail-fast, --skip-kernel
  acknowledgment, interactive completion with notice, and the
  check/uninstall gate bypass. PGSD: the satisfied path, with
  "installation complete" printed for the first time as a true
  statement of the machine's state. Documentation updated
  (INSTALL.md, KERNEL-RECIPE.md).
- Milestones 2 through 5: open. Milestone 2 (Axiom-format artifact
  sets with Lockbox-grade inventory, staged by the Awase build) is
  next.

## Appendix: Axiom implementation observations (2026-07-10)

Non-normative. This appendix records the state of the Axiom
implementation at ratification time, for the benefit of milestone 2
schema work and the milestone 4 operational decision. It may be
amended as Axiom evolves without reopening this ADR.

1. Inventory promotion. Axiom package manifests describe outputs by
   path pattern (for example "bin/"), which requires consumers to
   expand patterns by walking the tree; under this ADR that is
   inference. Axiom's Lockbox subsystem already contains the correct
   abstraction: a per-file inventory (path, mode, sha256, size, type)
   with machine identity as a Merkle root over canonical JSON plus
   filesystem contents. The Awase artifact contract requires
   Lockbox-grade inventory; promoting it from Lockbox into core
   package manifests is the first Awase-driven Axiom enhancement.

2. Identity/provenance separation. Axiom's provenance.yaml requires
   build_time (wall clock) and builder (hostname), so two otherwise
   identical builds produce differing provenance files. Per this ADR,
   identity is the filesystem contents and provenance is descriptive.
   Resolution upstream: exclude provenance from identity, or honor
   SOURCE_DATE_EPOCH; the former matches Lockbox's existing identity
   model.

3. Platform prerequisites for milestone 4. Axiom targets FreeBSD
   14.x and Zig 0.15.x; the bench runs FreeBSD 15.1-RELEASE and Awase
   has completed the Zig 0.16 migration. Axiom needs the equivalent
   migration before becoming operationally load-bearing. Format-first
   ordering (milestones 2 and 3) is what makes this prerequisite
   non-blocking.
