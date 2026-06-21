# AD-57: Source of truth for the PGSD kernel (DRAFT)

Status: DRAFT for ratification. A project-level architectural decision,
not a kernel-subsystem one: it defines how PGSD represents and preserves
its own kernel over time. No tooling is built from this document until
it is ratified.

## Why this is project-level, and why now

PGSD is currently produced by a transformation: install stock FreeBSD
(with sources), then run install.sh to convert the machine into PGSD in
place. The result depends on whatever FreeBSD release and whatever
/usr/src happened to be present when install.sh ran. PGSD is therefore a
procedure, not a defined thing, and "whatever is in /usr/src" is its de
facto kernel source of truth.

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
revision is recorded in the repository. A policy for advancing the pin
(when tracking a new FreeBSD release) is part of this decision; the
mechanism for recording it is not (see Representation).

### 2. Representation

The canonical PGSD kernel is:

    {pinned upstream FreeBSD revision} + {ordered set of project deltas}

The deltas are version-controlled and reviewable. The canonical kernel
is a RECIPE, not a stored tree: the project stores the delta from
upstream, not a mirror of upstream. This preserves the established
"derive, do not fork" discipline (pgsd-kernel/README) and keeps the
repository from becoming a FreeBSD source mirror.

NOTE: the patch-storage MECHANISM is deliberately not decided here. Raw
patch files, a series file, patches generated from a branch, or another
mechanism are implementation details that may evolve. The architectural
decision is the recipe model (pin + ordered deltas); hardcoding a patch
technology would let the ADR rot while the decision remained valid.

### 3. Classification

The deltas are partitioned by intent:

  - DEFINITIONAL patches: part of what PGSD IS (for example the HID class
    driver suppression that pgsd-kernel already defines, and any
    permanent kernel modifications the distribution requires).
  - INVESTIGATIONAL patches: temporary research artifacts, such as the
    AD-56 Phase 0.5 instrumentation. They are reproducible and
    version-controlled like definitional patches, but are understood to
    be transient and removable once their investigation concludes.

The partition matters because it keeps the permanent derivation distinct
from measurement scaffolding. An investigational patch that proves a
record load-bearing informs the Awase-native contract and is then
removed; it was never part of the definition of PGSD.

### 4. Reconstruction

A developer can reconstruct the EXACT kernel used for a given
investigation from repository contents plus the pinned revision: fetch
the pinned upstream source, apply the recorded deltas (definitional, plus
the investigational set for that investigation), build. The investigation
records which delta set it used, so its kernel is reproducible from the
repository alone (given network access to fetch the pinned upstream).

## Migration (install.sh)

install.sh today assumes and uses whatever /usr/src is present. Under
this ADR the build must instead use the PINNED, patched kernel: either
fetch the pinned upstream source itself, or verify the present /usr/src
matches the pin before building, then apply the recorded deltas. This is
real work; AD-56 is its justification, since Phase 0.5 cannot be
reproducible without it. The migration is staged as part of implementing
this ADR; the exact mechanism is implementation, not part of the
decision.

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

## Decisions to ratify

  - the recipe model (pin + ordered, classified deltas; reconstruct on
    build) as the canonical representation of the PGSD kernel.
  - development reproducibility as the primary (and current sole)
    objective; artifact reproducibility explicitly deferred.
  - the policy for advancing the pin (left as a named decision, mechanism
    deferred).
  - that patch-storage mechanics are out of scope for this ADR.
