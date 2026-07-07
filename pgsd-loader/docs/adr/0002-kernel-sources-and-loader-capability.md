# 0002: kernel sources, loader capability, and the deferred deployment architecture

## Status

Ratified, 2026-07-07, at revision 3 (operator: the document
establishes the loader's architectural capability boundary
without deciding product deployment policy; defines the Boot
Artifact Store and Boot Pool Invariants as independently
versioned subordinate specifications; limits the loader to
installer-defined storage contracts; defers deployment authority
and operational policy to the appropriate architectural venue;
and is sufficiently abstract to survive changes in
implementation strategy while providing stable guidance for L3a
and any future conditional ZFS work).

The evaluation ADR required by parent ADR 0001 Decision 6 before
L3 design begins. Ratification clears that gate for stage L3a
only (Decision 5); the gate for L3b clears when the upstream
product-architecture decision it depends on is ratified
(Decision 6).

## Context

The operator has ruled that PGSD is a ZFS-only solution: UFS is
out of scope permanently, and the original ESP-versus-UFS/ZFS
framing narrows to ESP-versus-ZFS. That narrowing does not make
the question smaller. A ZFS read path is the heavyweight end of
the original spectrum, and ZFS's boot-environment model raises a
coherence question (a rollback that reverts userland but boots a
different kernel is a partial rollback) that the loader alone
cannot answer.

Evaluation surfaced a structural error to avoid: letting this
loader ADR decide product architecture. "Every kernel lives on
the ESP" is not a loader decision; it is a product-wide
deployment decision. "OE and RE use different kernel sources" is
not a read-path detail; it is the operational model of recovery.
If those live here, every change to the installer or upgrade
model reopens a loader document. This ADR therefore separates
three concerns and decides only the first:

- Loader capability: what kernel sources pgsd-loader can read.
- Deployment architecture: where installers and upgrade tooling
  place kernels, and which copy is authoritative.
- Operational policy: which environment (OE/RE/ME) boots from
  which source, and what each is optimizing for.

One further question is upstream even of deployment
architecture: whether ZFS boot environments are the fundamental
PGSD upgrade model. That decision shapes installer design,
recovery semantics, update tooling, and rollback policy before
it ever reaches the loader. It is explicitly not ruled here.

## Decisions

### 1. Concern separation is binding on this subproject

pgsd-loader ADRs decide loader capability only. Deployment
architecture and operational policy are product decisions,
recorded outside this subproject (Decision 6), which loader
stages consume as ratified inputs. A pgsd-loader ADR that
embeds a deployment or policy decision is reopened on those
grounds alone.

### 2. Architectural principle: installer-defined boot pool invariants

The loader supports only pools that satisfy installer-defined
boot pool invariants. Ratified as an architectural assumption by
the operator: PGSD is not a general-purpose distribution booting
arbitrary pools, and owning the installer is exactly the
systems-level leverage that reduces the loader's ZFS scope from
a partial OpenZFS implementation to read-only support for pools
PGSD creates.

The invariants themselves (vdev topology, compression set,
encryption exclusions, pinned feature flags, and so on) are a
subordinate specification, BOOT-POOL-INVARIANTS, owned jointly
by the installer and pgsd-loader and versioned independently, so
this ADR does not encode a snapshot of today's OpenZFS feature
set. The principle is permanent; the invariant list evolves.

### 3. The ESP is the Boot Artifact Store

Architecturally, the ESP is not "the EFI partition" but the Boot
Artifact Store (BAS): the deliberate system partition where
immutable boot artifacts live. UEFI happens to require FAT; the
role is what is designed. Content classes: pgsd-loader itself,
the fallback loader, per-environment kernels and their module
sets as the deployment architecture dictates, manifests and
signatures, boot audio assets, and diagnostic artifacts as
stages add them.

The BAS is specified by a subordinate versioned specification,
BOOT-ARTIFACT-STORE, the sibling of BOOT-POOL-INVARIANTS: two
storage substrates the loader reads, two independently evolving
specifications the loader and installer jointly own. The spec
carries at minimum:

- Layout and naming of content classes and kernel slots.
- Sizing: 2 GiB baseline, growable to 4 GiB, negligible on
  modern storage against substantial loader simplification. The
  primary justification is platform validation: PGSD validates
  the chosen BAS size on its supported platforms and records it
  as an installer hardware assumption per the Decision 2
  philosophy. The architecture does not depend on assumptions
  about UEFI or FAT32 limits; whatever ceiling future firmware
  exhibits, the installer validates the size the project
  supports. (Informative background only: the UEFI specification
  imposes no practical ESP ceiling, and large-volume defects are
  firmware implementation bugs, which is exactly why validation
  rather than specification is the argument.)
- Curation invariants that make the sizing hold: kernels ship
  without debug symbol files and with an installer-curated
  module set (a stock kernel directory with symbols exceeds the
  per-kernel budget by an order of magnitude).
- A retained-kernel-set policy (active plus N rollback targets,
  generalizing A/B slots) so BAS capacity is bounded regardless
  of how many boot environments accumulate in the pool; the
  product ADR picks N, the spec defines the slot mechanism.
- The write-authority invariant: the BAS is written only by
  designated deployment tooling (installer, activation and
  installworld hooks, the deploy tooling this subproject
  absorbs); the running system otherwise treats it read-only,
  and the loader always reads only.
- The publication lifecycle: boot artifacts are immutable after
  publication; updating a kernel or loader publishes a new
  artifact set rather than modifying artifacts in place. This is
  the invariant that manifests, signatures, rollback,
  reproducibility, and any future measured-boot posture stand
  on, and it matches the publication philosophy the project uses
  elsewhere: state is published whole, never edited in place.
- Mirror equivalence: every bootable member contains an
  equivalent BAS, so the redundancy the pool provides is not
  silently lost at the boot layer. Equivalence is the
  architectural invariant; the replication mechanism that
  maintains it (synchronous writes, activation hooks, installer
  logic) belongs to the subordinate specification. Bench
  criteria include booting from a degraded mirror.

### 4. Loader capability: ESP read is unconditional

pgsd-loader gains the capability to read a kernel and its
modules from the ESP (FAT, via UEFI's native filesystem
protocol). Decided now, unconditionally, because every serious
deployment architecture requires it: it is the pool-independent
path that Recovery needs when the pool is the casualty, it is
the simplest path for bench iteration, and it is the natural
first stage under the parent's escalation ordering. Alongside
the read path, the loader verifies a checksummed kernel manifest
before transferring control, an integrity property the stock
loader never provided and a stepping stone toward the
secure-boot criteria this ADR inherits.

### 5. Loader capability: constrained ZFS read is conditional

A read-only ZFS path, scoped strictly to BOOT-POOL-INVARIANTS
pools, is a capability this ADR endorses but gates: no design or
implementation begins until the upstream product decision
(Decision 6) ratifies a deployment architecture that requires
reading kernels from the pool. If the product ratifies ESP
authority, this capability is never built and no loader document
needs revision.

Consequence for the parent's L3: the stage subdivides as L3a
(ESP kernel path, unblocked by ratification of this ADR) and
L3b (constrained ZFS reader, gated). The subdivision satisfies
the parent's escalation requirement by construction: L3a is the
smaller, pool-independent step and lands first regardless of the
upstream outcome.

### 6. Deployment architecture is deferred upstream, with the field mapped

The deployment-architecture and operational-policy selection is
deferred to a product architecture ADR outside pgsd-loader (the
shared ADR series is the suggested venue; the operator
designates the home). To make that decision well-posed, this ADR
records the field as three authority models on the deployment
axis:

- ESP authority. All bootable kernels live on the ESP;
  synchronization hooks (BE activation, installworld) copy
  kernels to checksummed, slotted ESP locations. Strength:
  auditability. The synchronization mechanism is operational
  complexity, inspectable and benchable, and a failure presents
  as a concrete artifact mismatch; a filesystem implementation
  is permanent algorithmic complexity. Standing question
  recorded for the product ADR: can synchronization itself be
  specified as an architectural invariant (atomic
  write-then-rename, A/B slots, manifest carrying source
  identity and checksums, bench criteria), rather than remain a
  hook that is merely trusted? Weakness: the sync mechanism is
  load-bearing forever, and kernel-BE coherence rests entirely
  on it. The capacity objection is retired by Decision 3: a
  2-4 GiB BAS under the retained-kernel-set policy holds any
  realistic rollback window with room to spare.

- ZFS authority. The loader reads the active boot environment's
  kernel from the pool; coherence is by construction, no sync
  mechanism exists to fail. The pure architecture, and almost
  certainly the wrong first architecture: it front-loads the
  project's largest implementation and maintenance burden before
  owning the loader has paid for itself, and it cannot serve
  Recovery when the pool is damaged, so it is incomplete alone
  under the three-environment model.

- Split authority. Kernel source per environment: RE (and
  plausibly ME) from the ESP, pool-independent; OE from its boot
  environment on ZFS. Not a compromise between the first two but
  a recognition that OE and RE have fundamentally different
  requirements, coherence versus independence, and forcing them
  to share one kernel source is the abstraction leak. Each
  environment optimizes for its own threat model. Cost: both
  read paths exist permanently, and a small ESP sync mechanism
  remains for the RE kernel.

Evaluation criteria the product ADR applies: kernel-update
synchronization between ESP and pool; whether the ESP is a
deployment artifact or an authoritative source; signed-kernel
and future secure-boot fit; existing install.sh synchronization
mechanisms to build on; boot-environment coherence under
rollback; recoverability under pool damage; and auditability of
whatever mechanism carries authority.

Advisory ranking, recorded as guidance and explicitly not
binding on the product ADR: split authority under
BOOT-POOL-INVARIANTS first; ESP authority second, rising to
first if synchronization is ratified as an invariant or if boot
environments are ruled out as the upgrade model (without BEs,
the coherence argument for pool reads mostly evaporates);
the documented stopping point (below) third.

### 7. The documented stopping point

If the conditional capability's cost balloons or the product
decision stalls, pgsd-loader may permanently end at L2, with
stock loader.efi chainloaded for kernel handoff indefinitely.
Recorded deliberately: architecture documents should not pretend
only success options exist. Ending at L2 would deliver
environment selection, loader audio, and the deployment and
recovery discipline while avoiding disproportionate complexity,
and would be a conscious architectural decision, not a failure.
The costs are recorded with it: L5 never closes, the parent ADR
remains permanently open, and the deploy-fragility class
persists at the stock-loader layer.

### 8. Considered and rejected

- Dedicated constrained boot pool (the bpool pattern). Solves
  implementation complexity by creating operational complexity:
  cross-pool BE pairing reintroduces the two-authority problem
  inside ZFS, the partial-rollback hazard in a different coat.
  Rejected; the pool-shape leverage is captured by Decision 2
  on the one pool instead.
- Third-party EFI ZFS filesystem driver. Still a ZFS reader in
  the boot path, but one the project does not own: stale
  feature-flag coverage, GPL lineage against the MIT tree, and
  an inversion of pgsd-loader's purpose. Recorded once so the
  suggestion does not recur annually.
- Two-stage boot (minimal ESP kernel pivots to the real one).
  Attractive under the OE/RE/ME mapping, infeasible without a
  mature kexec equivalent on FreeBSD; a reboot loop or a
  research project. Rejected on feasibility.
- Implicit ESP synchronization via union mounts. Runs at the
  wrong layer (a VFS construct cannot exist at loader time),
  msdosfs cannot function as a union upper layer (no whiteouts,
  no metadata, no atomicity for the most critical file), and
  above all it masks the ESP-pool divergence the deployment
  decision needs kept visible. Explicit, auditable
  synchronization is the mechanism that fits this project's
  transparency posture.

## Closure criteria

1. Ratification of this ADR clears the parent Decision 6 gate
   for L3a; the L3a stage ADR may be drafted.
2. BOOT-ARTIFACT-STORE exists as a versioned specification
   before L3a implementation begins (the L3a stage ADR may
   draft it), and before the installer claims conformance to
   its layout.
3. BOOT-POOL-INVARIANTS exists as a versioned specification
   before any L3b design, and before the installer claims
   conformance.
4. The product architecture ADR (Decision 6) is drafted in its
   designated venue, consuming the field mapping and criteria
   recorded here; its ratification clears the L3b gate or
   invokes Decision 6.
5. The upstream boot-environment ruling is recorded in that
   product ADR, not here; this document requires no revision in
   either outcome.

## References

- pgsd-loader ADR 0001: parent architecture; Decision 6 (the
  gate this ADR satisfies), Decision 3 (L3 subdivision),
  Decisions 4 and 5 (the invariants stage ADRs inherit).
- Operator rulings, 2026-07-07: PGSD is ZFS-only;
  installer-defined boot pool invariants ratified as an
  architectural assumption; the boot-environment question
  deferred upstream as a product decision.
- audiofs ADR 0032: the manifest-verification stepping stone
  toward the secure-boot criteria shares lineage with the
  chime's build-product discipline.

## Revision history

- Revision 1, 2026-07-07: initial proposal. Three-axis structure
  (loader capability, deployment architecture, operational
  policy) per operator review of the option enumeration;
  installer-invariant principle elevated from an option
  constraint to an architectural principle per the same review.
- Revision 2, 2026-07-07: the Boot Artifact Store added as
  Decision 3 per operator input, reframing the ESP as a
  deliberate system partition with a sibling subordinate
  specification (BOOT-ARTIFACT-STORE) covering layout, 2-4 GiB
  sizing validated per platform, symbol and module curation
  invariants, a bounded retained-kernel-set policy, the
  write-authority invariant, and mirror replication. The ESP
  authority capacity objection retired accordingly; later
  decisions renumbered.
- Revision 3, 2026-07-07: operator review refinements. Mirror
  replication restated as an equivalence invariant (every
  bootable member contains an equivalent BAS) with the mechanism
  delegated to the subordinate specification; the publication
  lifecycle added as an invariant (artifacts immutable after
  publication, updates publish new sets); BAS sizing justified
  primarily by platform validation, with UEFI limit observations
  demoted to informative background. Ratified at this revision
  the same day, with one editorial correction folded into the
  ratification record: the Status block's L3a gate reference,
  stale since the revision 2 renumbering, corrected from
  Decision 4 to Decision 5. No decision content changed.
