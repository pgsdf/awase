# AD-57: Source of truth for the PGSD kernel

Status: RATIFIED 2026-06-21 (operator); AMENDED 2026-06-26 (Git-backed
representation, see the amendment in section 2). A project-level
architectural decision, not a kernel-subsystem one: it defines how PGSD
represents and preserves its own kernel over time. The architectural
decision is
ratified; implementation concerns it deliberately leaves open (patch
storage, pin-recording mechanism, install.sh migration strategy,
pin-advancement workflow, investigation metadata format) are settled
separately and do not reopen this ADR.

## Decision

PGSD SHALL define its kernel as a pinned FreeBSD source revision plus an
ordered, version-controlled set of project deltas. This recipe
constitutes the canonical source of truth for the PGSD kernel and SHALL
be sufficient to reconstruct any kernel used for development or
investigation. The remainder of this document gives the rationale, the
four constituent decisions, the scope boundary (development
reproducibility now; artifact reproducibility later), and the
consequences.

## Why this is project-level, and why now

PGSD is currently produced by a transformation: install stock FreeBSD
(with sources), then run install.sh to convert the machine into PGSD in
place. The result depends on whatever FreeBSD release and whatever
/usr/src happened to be present when install.sh ran. PGSD is currently
defined by a procedure rather than by a reproducible kernel definition,
and "whatever is in /usr/src" is its de facto kernel source of truth.

AD-56 makes this untenable. Phase 0.5 introduces kernel instrumentation
that MEASURES the boot ABI, and a measurement is only meaningful relative
to a specific kernel. A verdict like "EFI_FB is optional for
boot-to-init" is unreproducible, and so nearly worthless, if six months
later nobody can reconstruct which source, which revision, and which
instrumentation produced it. The whole premise of Phase 0.5 (measure, do
not assume) collapses if the measurement cannot be re-run. So a durable,
canonical definition of the PGSD kernel is a PRECONDITION of AD-56 being
worth doing, independent of any ISO or artifact goal.

This is project-level because the canonical representation of the kernel
affects AD-56 investigations, all future kernel work, install.sh,
developer onboarding, any eventual artifact pipeline, and release
engineering. It is the project's representation of itself, not a
subsystem concern.

## Scope: development reproducibility, not artifact reproducibility

This ADR optimizes for ONE objective: project development
reproducibility. If, six months from now, a developer with the
repository can reconstruct the exact kernel used for a given
investigation, rerun the experiment, and verify the result, this ADR has
succeeded.

Explicitly OUT of scope, deferred to a later ADR (PGSD as a reproducible
artifact): ISO/IMG output, release(7)/poudriere/custom tooling choice,
pinned-versus-tracking artifact policy, artifact publication and
versioning, and external offline (no-network) reproducibility. Designing
around a hypothetical no-network builder now would push toward vendoring
costs that do not solve the immediate problem. The artifact pipeline
builds ON this ADR: once the kernel is a well-defined recipe, the
artifact builder has a defined thing to build.

## The four decisions

### 1. Pinning

PGSD is defined against a SPECIFIC FreeBSD source revision. "Whatever
happens to be in /usr/src" ceases to be authoritative. The pinned
revision is recorded in the repository.

The architectural decision is only that PGSD IS pinned. Policies
governing advancement of that pin (when and how to track a new FreeBSD
release) are deferred and may be specified separately: they are
operational, depend on release cadence and other independently-changing
concerns, and are deliberately NOT ratified here. Binding an advancement
policy into this ADR would force reopening an architectural decision
every time the project's release rhythm changes. Advancing the pin is an
explicit project action (see Consequences); its policy lives outside
AD-57.

### 2. Representation

The canonical PGSD kernel is:

    {pinned upstream FreeBSD revision} + {ordered set of project deltas}

The deltas are version-controlled and reviewable. The canonical kernel
is a RECIPE, not a stored tree: the project stores the delta from
upstream, not a mirror of upstream. This preserves the established
"derive, do not fork" discipline (pgsd-kernel/README) and keeps the
repository from becoming a FreeBSD source mirror.

Ordering is part of the kernel definition, not an incidental property:
patch application is not generally commutative, so applying the same
deltas in a different order may produce a different kernel or fail to
apply. The delta set is therefore an ordered sequence, and the order is
recorded as part of the recipe.

NOTE: the patch-storage MECHANISM is deliberately not decided here. Raw
patch files, a series file, patches generated from a branch, or another
mechanism are implementation details that may evolve. The architectural
decision is the recipe model (pin + ordered deltas); hardcoding a patch
technology would let the ADR rot while the decision remained valid.

AMENDMENT (2026-06-26): Git-backed representation. The recipe mechanism
is now realised against a maintained Git fork of FreeBSD source rather
than an upstream release tarball plus separate patch files. This refines
the implementation of the recipe model above; it does not change the
architectural decision (the canonical kernel is still a recipe, not a
tree embedded in this repository).

  - Base and deltas live in a SEPARATE fork repository
    (https://github.com/pgsdf/freebsd-src), not in the awase repository.
    The awase repository continues to embed no copy of FreeBSD; it
    REFERENCES a pinned commit in the fork. "Derive, do not embed" is
    preserved: the fork is an external dependency the recipe points at,
    the same way any upstream dependency is referenced rather than
    vendored. The earlier "do not become a FreeBSD source mirror"
    principle was about the AWASE repository, and that still holds; the
    fork is a distinct repository.
  - The PIN FILE remains canonical, not the fork branch. Identity is the
    immutable COMMIT id, not a branch name. A branch is only a convenient
    pointer and may be renamed or rebased without invalidating the pin,
    because the pin records the commit. "Whatever is on branch X today"
    is never the definition.
  - Deltas are commits in the fork (a delta branch or linear history on
    top of the pinned upstream base), version-controlled with full
    history in the same tool. The definitional/investigational
    classification (section 3) is unchanged; an investigational delta is
    a fork commit (or branch) understood as transient.
  - Reconstruction is: clone the fork, check out the pinned delta commit,
    build with the PGSD config. The pin records the delta commit and the
    upstream base commit it derives from, so reconstruction does not
    depend on branch state.
  - Provenance and drift: because the base is now a Git checkout, drift
    detection is intrinsic (git status / rev-parse), closing the
    release-tarball gap where local modification of /usr/src could not be
    detected. Verification checks the working tree's HEAD against the
    pinned commit.

This amendment changes the REPRESENTATION mechanism, which is why it is
recorded as an ADR amendment rather than left as an implementation
detail. How the fork is kept current with upstream (merge, rebase,
fast-forward, periodic recreation) is OPERATIONAL practice, not
architectural, and is deliberately not prescribed here; it may evolve
without a further amendment.

### 3. Classification

The deltas are partitioned by intent:

  - DEFINITIONAL patches: part of what PGSD IS (for example the HID class
    driver suppression that pgsd-kernel already defines, and any
    permanent kernel modifications the distribution requires).
  - INVESTIGATIONAL patches: research artifacts, such as the AD-56 Phase
    0.5 instrumentation and reduction experiments. They may INSTRUMENT,
    CONSTRAIN, or temporarily MODIFY kernel behavior for the purpose of
    measurement or experimentation; their defining characteristic is not
    their technical effect but that they are NOT part of the long-term
    definition of PGSD. They are reproducible and version-controlled like
    definitional patches, but are understood to be transient and
    removable once their investigation concludes.

The defining axis is intent, not effect. An investigational patch is not
distinguished by being read-only: AD-56 Phase 0.5's reduction stage
deliberately suppresses or malforms metadata records to find which are
load-bearing, which is a behavioral change, yet it is investigational
because it is measurement scaffolding, never part of what PGSD is.

The partition matters because it keeps the permanent derivation distinct
from measurement scaffolding. An investigational patch that proves a
record load-bearing informs the Awase-native contract and is then
removed; it was never part of the definition of PGSD.

### 4. Reconstruction

A developer can reconstruct the EXACT kernel used for a given
investigation from repository contents plus the pinned revision: fetch
the pinned upstream source, apply the recorded deltas IN THEIR RECORDED
ORDER (definitional, plus the investigational set for that
investigation), build. Ordering is restated here deliberately: the deltas
are an ordered sequence (see Representation), and reconstruction applies
them in that order, not as an unordered collection.

Every investigation SHALL identify the pinned revision and the
investigational delta set used to produce its results, so its kernel is
reproducible from the repository alone (given network access to fetch the
pinned upstream). What constitutes a sufficient identifier (a commit
hash, an ADR reference, a manifest, a tag) is implementation; the
requirement is that the pin and the delta set be recorded, not the form
of the record.

Non-goal: local modifications outside the recorded delta set are NOT part
of the canonical PGSD kernel and do NOT produce reproducible
investigation results. A kernel built with uncommitted local edits, or
from a /usr/src that diverges from the pin, is not a PGSD kernel for the
purpose of this ADR, and any measurement taken against it is not
reproducible. Reproducibility is a property of the recorded recipe, not
of any particular developer's working tree.

## Migration (install.sh)

install.sh today assumes and uses whatever /usr/src is present. Under
this ADR, install.sh SHALL build only from source that is VERIFIABLY
IDENTICAL to the pinned upstream revision: either fetch the pinned
upstream source itself, or verify (not merely assume) that the present
/usr/src matches the pin before building, then apply the recorded
deltas. A tree that merely claims to be the correct revision, without
verification, does not satisfy this requirement. The verification
mechanism is implementation; the requirement that source be provably the
pinned revision is part of the decision. This is real work; AD-56 is its
justification, since Phase 0.5 cannot be reproducible without it.

Under the 2026-06-26 Git-backed amendment, the concrete migration is:
install.sh and the kernel build obtain source by cloning the fork at the
pinned commit, or verify that the present /usr/src is a checkout of the
fork whose HEAD matches the pinned commit, before building. The
verifiably-identical requirement is satisfied by a Git commit check
(rev-parse HEAD against the pin), which also detects local drift. An
explicit override (PGSD_ALLOW_UNPINNED) permits deliberate unpinned
investigation with a prominent non-reproducible warning, so the default
stays strict without blocking intentional exploratory work.

## Relationship to other work

  - AD-56: this ADR is the durable foundation AD-56 Phase 0.5 requires.
    The instrumentation patches are investigational deltas under
    decision 3; their measurements are reproducible under decision 4.
  - pgsd-kernel: the kernel config and definitional patches live with
    the component; this ADR defines how they (plus the pin) constitute
    the canonical kernel. The "derive, do not fork" discipline is
    preserved, not reversed.
  - A later ADR (PGSD as a reproducible artifact): builds on this one;
    the artifact builder consumes the recipe this ADR defines.

## Consequences

  - Kernel investigations become reproducible: a given AD-56 measurement
    can be re-run against the exact kernel that produced it.
  - AD-56 measurements become durable and independently verifiable,
    rather than historical trivia tied to a lost /usr/src.
  - install.sh becomes more complex: it must obtain or verify the pinned
    source and apply the delta set, rather than using whatever is
    present.
  - Developers can no longer rely on arbitrary contents of /usr/src;
    only the recorded recipe defines a PGSD kernel.
  - Advancing the FreeBSD base becomes an explicit project action, not an
    implicit side effect of whatever release happened to be installed.

## Decisions to ratify

  - the recipe model (pin + ordered, classified deltas; reconstruct on
    build) as the canonical representation of the PGSD kernel.
  - development reproducibility as the primary (and current sole)
    objective; artifact reproducibility explicitly deferred.
  - that patch-storage mechanics are out of scope for this ADR.
  - that the pin-advancement policy is operational and explicitly NOT
    ratified here (only that PGSD is pinned).
