# BOOT-POOL-INVARIANTS, version 0.1

Status: DRAFT CONTRACT. Not ratified.

Owned jointly by the installer and pgsd-loader; versioned
independently of the ADRs that require it, as its sibling
BOOT-ARTIFACT-STORE is.

Required by pgsd-loader ADR 0002 Decision 2 and unlocked by project
ADR 0001 Decision 4, whose ratification cleared the gate on the
constrained ZFS read capability and on L3b design.

---

## 1. Purpose and scope

### Why this contract exists

Project ADR 0001 Decision 4 (split authority) places the Operating
environment kernel on ZFS, inside its system image unit, and the
Recovery environment kernel in the BAS. The two locations are chosen
against different threat models and neither substitutes for the other:

> *"ZFS authority: the pure architecture and the wrong one alone,
> because Recovery cannot source its kernel from the casualty."*
>
> *"ESP authority: weakened decisively... the Operating environment
> kernel would permanently depend on publication guarantees that must
> be constructed above FAT rather than supplied by the filesystem
> itself."*

The consequence is that an OE boot path requires a capability that can
provide the loader with the OE system image unit selected for transfer,
and that unit resides, by Decision 4, on ZFS. That capability is L3b,
and Decision 4 states the form it is expected to take:
*"The constrained ZFS read capability endorsed and gated by pgsd-loader
ADR 0002 Decision 5 is required."*

The requirement is stated at the boundary, deliberately:

  - something must IDENTIFY the selected unit,
  - the loader must CONSUME that identity and obtain the unit's
    artifacts,
  - the SOURCE of the identity remains open.

An earlier revision of this section said the loader must "resolve" the
unit, which quietly assumed the loader is the resolver. It may not be.
pgsd-loader ADR 0001's L1 already contemplates environment selection
communicated TO the loader through *"a small ESP file or UEFI
variable"*, and AD-59's Discover boundary is explicitly
producer-agnostic (Part 9: the LOM's observations *"carry across a
loader replacement even as the mechanism that reads them changes"*). A
pre-loader selector, a verified identity in NVRAM, or a manifest are all
admissible producers under this contract.

What is NOT open is the consumption: whatever names the unit, the loader
must be able to obtain that unit's kernel and its userland from the same
unit (B2), from a pool satisfying section 5, without executing code from
the pool.

This document is the contract that makes "constrained" mean something.

### What it enables

The whole of the constraint rests on one architectural leverage,
ratified in pgsd-loader ADR 0002 Decision 2:

> *"The loader supports only pools that satisfy installer-defined boot
> pool invariants... PGSD is not a general-purpose distribution booting
> arbitrary pools, and owning the installer is exactly the systems-level
> leverage that reduces the loader's ZFS scope from a partial OpenZFS
> implementation to read-only support for pools PGSD creates."*

Every invariant the installer guarantees is a code path the loader does
not write. That is the trade this document exists to make explicit, and
it is a negotiation, not a specification handed down: the installer
gives up configuration freedom, and the loader gives up implementation
scope. Neither party can set the boundary alone.

### What it does NOT define

Per pgsd-loader ADR 0002 Decision 1, which is binding:

> *"pgsd-loader ADRs decide loader capability only. Deployment
> architecture and operational policy are product decisions... A
> pgsd-loader ADR that embeds a deployment or policy decision is
> reopened on those grounds alone."*

So this document does not decide:

- whether ZFS boot environments are PGSD's upgrade model (ADR 0002
  states this is *"explicitly not ruled"*),
- how boot environments are named, created, promoted, or destroyed,
- what policy selects among them (that is AD-59),
- how the OE is upgraded or rolled back.

It defines only the properties a pool must have for the loader to read
it, and what the loader may do with what it reads.

---

## 2. Invariants

Named so that ADRs, reviews, and code can cite them rather than
paraphrase, as BOOT-ARTIFACT-STORE names I1 through I5.

- **B1, authority split.** The OE kernel resides in its ZFS system image
  unit; the loader, the RE kernel, and ME artifacts reside in the BAS.
  Neither store substitutes for the other. (Project ADR 0001 Decision 4.)

- **B2, OE coherence.** The loader shall never produce an operational
  boot state in which the kernel and the userland originate from
  different system image units. This is the architectural reason L3b
  exists. (Project ADR 0001 Decision 5.1: *"a booted OE runs a kernel and
  a userland from the same unit. A rollback that reverts one without the
  other is a partial rollback and a violation, whatever mechanism
  produced it."*)

- **B3, read-only.** The loader never writes to the pool. Not a
  property, not a timestamp, not an uberblock. A reader that cannot
  write cannot make a damaged pool worse.

- **B4, fail closed.** A pool that does not satisfy this contract is
  refused, and the refusal is reported as a fact. The loader does not
  attempt a partial read and does not guess.

- **B5, no policy.** L3b produces observations, never conclusions. A
  loader that concludes "the pool is bad, therefore boot Recovery" has
  taken Decide's job. (AD-59 Part 6, Part 9.)

---

## 3. Non-goals

Stated explicitly, because this project has repeatedly found layers
doing each other's work, and the cost of discovering it late has been
high.

L3b is NOT:

- **A ZFS implementation.** It is a reader for pools that satisfy this
  contract. A pool that does not satisfy the contract is not supported,
  and the correct response is to say so, not to grow a code path.
- **A filesystem.** It reads what it needs to reach a kernel and its
  metadata. It does not provide open/read/write/stat to anything else,
  and no other component may build on it as though it did.
- **A recovery environment.** Recovery is performed by an operating
  system (AD-59 Part 2, P2). L3b transports; it does not repair.
- **An upgrade or rollback engine.** It observes what exists. It does
  not promote, activate, or destroy.
- **A policy engine.** It produces facts. AD-59's Decide interprets
  them. A loader that decides *"the pool is bad, boot Recovery"* has
  taken Decide's job, and Decide's contract (Part 6, N1) forbids
  reaching around Discover to obtain state.

The last is the one most likely to be violated by accident, because the
loader is *right there* when the fact is discovered and the conclusion
feels obvious.

---

## 4. Authority model

Restated from project ADR 0001 Decision 4, because every other section
depends on it:

| Artifact | Resides in | Rationale |
|---|---|---|
| pgsd-loader | BAS | firmware domain |
| Recovery environment kernel + modules | BAS | pool-independent: recovery cannot source its kernel from the casualty |
| Management environment artifacts | BAS | as defined |
| Manifests | BAS | with the artifacts they cover |
| **Operating environment kernel** | **ZFS, inside its system image unit** | checksummed COW durability; rollback coherence by construction |

**No cross-substitution.** The OE kernel is not a BAS artifact and the
RE kernel is not a pool artifact. Each location was chosen against its
own threat model and neither is a fallback for the other.

### The coherence invariant this protects

Project ADR 0001 Decision 5.1:

> *"A bootable system image unit (in the ZFS sense, a boot environment)
> is the unit of upgrade and rollback coherence for the Operating
> environment: **a booted OE runs a kernel and a userland from the same
> unit.** A rollback that reverts one without the other is a partial
> rollback and a violation, whatever mechanism produced it."*

This is the reason L3b cannot be skipped by staging the OE kernel into
the BAS. A BAS-resident OE kernel is decoupled from the userland it
boots, and any pool rollback then produces a partial rollback by
construction.

---

## 5. Supported pool model

**OPEN.** This section is the negotiation, and it cannot be written by
the loader alone (ADR 0002 Decision 1). It is drafted here as the
question list the installer must answer, with the loader's cost for
each stated so the trade is visible.

The categories are named by ADR 0002: *"vdev topology, compression set,
encryption exclusions, pinned feature flags, and so on."*

### 5.1 Feature flags

The empirical anchor is FreeBSD's own boot-time reader
(`stand/libsa/zfs/zfsimpl.c`), which maintains an explicit allowlist,
`features_for_read[]`, of read-incompatible features it supports, and
whose comment names the leverage that makes a constrained reader
possible at all:

> *"Do not add here features marked as ZFEATURE_FLAG_READONLY_COMPAT,
> they are irrelevant for read-only!"*

A read-only reader may ignore an entire class of features. **PGSD's list
can be shorter than FreeBSD's, because the installer creates the pool.**

  OPEN Q1: which feature flags does the installer enable on a boot
  pool? The answer is the loader's entire feature-compatibility burden.
  A pinned, minimal set is the strongest form of this contract.

### 5.2 vdev topology

  OPEN Q2: single vdev only? Mirrors? Is RAIDZ supported for a boot
  pool? Each topology the installer permits is reconstruction logic the
  loader must implement.

### 5.3 Compression

  OPEN Q3: is compression permitted on the datasets the loader must
  read, and if so, which algorithms? Every algorithm is a decompressor
  in the loader. `off` on the boot path is the cheapest possible
  answer; lz4 alone is the next cheapest.

### 5.4 Encryption

  OPEN Q4: excluded on the boot path, or supported? ADR 0002 names
  *"encryption exclusions"* as an invariant category, which suggests
  exclusion is the expected answer, but it is not ruled. Supporting it
  means key management in the loader, which is a different and much
  larger artifact.

### 5.5 Unsupported configurations

Whatever the answers, the contract must state what the loader does with
a pool that violates them: **it refuses to read it, and says so.** It
does not attempt a partial read, and it does not guess. An unsupported
pool is a fact (section 8), not an error the loader resolves.

---

## 6. Loader read contract

### 6.1 The consumption requirement

**Contract.** Given the identity of a selected OE system image unit, the
loader shall be able to obtain that unit's artifacts required for
transfer, from a pool satisfying section 5, without executing code from
the pool, and without taking the kernel and the userland from different
units (B2).

The requirement is stated on CONSUMPTION, not on resolution. Whatever
names the unit (the pool's own property, a pre-loader selector, an EFI
variable, a manifest) is open under section 7, and this contract binds
only what the loader does once the unit is named.

That is the whole of the requirement. It names an outcome, not a
traversal: freezing the first implementation's block-walk into the
contract would make a later manifest, index, or cache layer a contract
amendment rather than an implementation choice, which is the opposite of
what a contract is for.

The traversal current OpenZFS layouts require is recorded in Appendix A
as an implementation note, where it can be wrong without the contract
being wrong.

### 6.2 Allowed traversal

The loader traverses only what section 5.1 requires. It does not walk
the dataset tree for its own sake, enumerate snapshots, or read
properties it has no use for. This is Discover's N4 (*"no collection
beyond Decide's inputs"*) applied one layer down: extra reading is how
a reader quietly becomes a filesystem.

### 6.3 No mutation

**The loader never writes to the pool.** Not a property, not a
timestamp, not an uberblock, not a scrub. This is absolute and it is
what makes the read capability safe to run on a damaged pool: a reader
that cannot write cannot make things worse.

Boot-completion tracking, generation counters, and any other state the
loader must persist live in NVRAM or the BAS, never in the pool. (The
bootcrumb facility already establishes this pattern from the kernel
side.)

### 6.4 No general filesystem responsibility

Nothing in the loader may depend on L3b as though it were a filesystem
layer. It exposes exactly the operations section 5.1 requires and no
generic read path. If a future stage needs to read something else from
the pool, that is an amendment to this contract, deliberately made.

---

## 7. Boot environment identity

**OPEN, and deliberately not resolved here.**

pgsd-loader ADR 0002 states that whether ZFS boot environments are
PGSD's fundamental upgrade model is *"explicitly not ruled"* and that
the decision *"shapes installer design, recovery semantics, update
tooling, and rollback policy before it ever reaches the loader."*

This document therefore constrains the **properties** any identifier
must have, without selecting the model.

### 7.1 Required properties of a BE identifier

Whatever identifies a boot environment must be:

  - **Loader-observable.** The loader must be able to obtain it from a
    pool that satisfies section 4, without executing code from the pool.
  - **Stable across the boot.** It must name the same thing when
    Discover observes it and when Transfer acts on it.
  - **Sufficient to reach the coherence unit.** It must resolve to the
    system image unit that holds both kernel and userland (Decision
    5.1), not to a kernel alone.
  - **Distinguishable.** Two boot environments must be tellable apart
    by their identifiers.

### 7.2 Candidate models (none selected)

  - A ZFS dataset path (`zroot/ROOT/<name>`). Conventional, and what
    the stock loader uses. Names the coherence unit directly.
  - A ZFS dataset GUID. Stable under rename; opaque to operators.
  - A pool property (`bootfs`) naming the selected unit, with the set
    enumerated from the DSL tree.
  - Something else, if the upgrade model is not BE-based.

### 7.3 What this document requires

  OPEN Q6: the upgrade model decision (a product decision, not a loader
  one) must be made before L3b's identity model is fixed. Until then,
  L3b design proceeds against the *properties* in 6.1, not against a
  concrete identifier.

**Do not write `zroot/ROOT/<name>` into the loader as an assumption.**
It is what the loader hardcodes today (campaign finding F13), and the
hardcoding is precisely the defect: a name compiled into the loader is
a landmine that re-arms on every reinstall, and it went off once
already.

---

## 8. Integrity and trust

### 8.1 What ZFS guarantees, and what it does not

ZFS's checksummed copy-on-write semantics guarantee that a block read
back is the block that was written, or that the read fails. That is a
**corruption** guarantee. It is not an **authorization** guarantee.

It does not answer:

  - Is this the *intended* kernel?
  - Is this the *approved* generation?
  - Is this *authorized* to boot?

Those are different questions, and conflating them is the error this
section exists to prevent. "ZFS checksums it" is not "verified boot."

### 8.2 The asymmetry with the BAS, and whether it is acceptable

The BAS verifies artifacts by manifest hash at use
(BOOT-ARTIFACT-STORE section 13), and its correctness statement is
explicit: *"a selector may designate a slot that verification then
refuses, in which case the set is not reachable."*

The OE path has no equivalent today.

  OPEN Q7: does the OE kernel require verification beyond ZFS's own
  integrity guarantees? Three coherent positions:

  (a) **COW is sufficient.** The pool is the authority (Decision 4),
      its durability semantics are stronger than FAT's, and adding a
      manifest duplicates what ZFS already does. Simplest; asymmetric
      with the BAS.

  (b) **A manifest, as the BAS has.** Symmetric, and answers the
      authorization questions ZFS does not. But where does the manifest
      live? In the pool (and is then only as trustworthy as the pool),
      or in the BAS (and is then coupled to the unit's activation, per
      Decision 5.2's unit-coupled publication property)?

  (c) **Signatures.** Answers authorization properly and introduces key
      management into the loader, which is a substantially larger
      artifact and likely a separate ADR.

This is a real architectural question and it is not the loader's to
answer alone.

---

## 9. Failure semantics

**This section is the integration point with AD-59, and getting it
wrong is how the loader silently becomes a policy engine.**

### 9.1 The principle

> **A loader failure and an architectural recovery decision are not the
> same thing.**

The loader produces **facts**. AD-59's Decide interprets them. A loader
that concludes *"the pool is unreadable, therefore boot Recovery"* has
taken Decide's job, and Part 6 N1 forbids Decide from reaching around
Discover to obtain state, and the symmetric obligation is that the loader
must not reach forward into policy.

### 9.2 The facts L3b produces

Each is an **observation**, in AD-59 Part 9's sense: a statement of what
is, never of what it means.

| Fact | Meaning (stated as observation) |
|---|---|
| `pool_unavailable` | No pool satisfying section 4 was found or opened. |
| `pool_unsupported` | A pool was found and does not satisfy section 4. |
| `selected_be_unavailable` | The identity model resolved to no boot environment. |
| `be_unreadable` | The boot environment was named and could not be read. |
| `kernel_unavailable` | The boot environment was read and contains no loadable kernel. |

  OPEN Q8 (AD-59 dependency). These facts must reach Decide as
  observations. AD-59 Part 10's LOM v1 defines five observations and an
  `unavailable` sentinel for a field with no producer. Part 11's rule E1
  states that a predicate testing an observation for a concrete value
  evaluates to FALSE when the observation is unavailable.

  The problem this raises, stated without proposing its resolution:

      LOM v1's semantics may not distinguish "no observation producer
      exists" from "an observed boot target is unavailable."

  Both would present as the `unavailable` sentinel, and E1 makes any
  predicate over either one false. Under Policy v1 (Part 12), evaluation
  would then fall through to the terminal Operational default in both
  cases, which are not the same case.

  This is a cross-document dependency, not a defect in either document.
  BOOT-POOL-INVARIANTS has found it; it does not resolve it. The
  resolution belongs to AD-59, and the space is open: extend LOM v1,
  define a new LOM version, introduce additional observations, or
  redefine which observations Decide requires. Selecting among those is
  AD-59's decision and this contract does not make it.

### 9.3 What the loader does NOT do

  - It does not select Recovery because the OE failed. That is a policy
    conclusion.
  - It does not retry, fall back, or sequence alternatives (AD-59 Part
    8, N2 and N4).
  - It does not repair the pool.
  - It does not prompt. A console-less kernel cannot ask, and the
    campaign has already paid for that lesson: an invisible mountroot>
    prompt cost seven armed boots.

---

## 10. Evolution and versioning

Versioned independently of the ADRs that require it, as
BOOT-ARTIFACT-STORE is. The pattern is established: *"two storage
substrates the loader reads, two independently evolving specifications
the loader and installer jointly own."*

Changing an invariant is a version bump and a joint act. The installer
cannot loosen a guarantee without the loader growing the code path that
guarantee was buying, and the loader cannot demand a guarantee the
installer cannot make.

  OPEN Q9: the compatibility rule. If a pool declares a
  BOOT-POOL-INVARIANTS version the loader does not know, what happens?
  (Refuse, per section 5.5, seems right, and it is the fail-closed
  posture the rest of this document takes.)

---

## 11. Open questions, classified

Each is tagged with WHO can answer it. The classification is the point:
several of these cannot be answered by this document or by pgsd-loader
at all, and pretending otherwise is how a loader ADR ends up embedding a
product decision (ADR 0002 Decision 1).

| # | Question | Class |
|---|---|---|
| Q1 | Which feature flags does the installer enable on a boot pool? | installer/loader contract |
| Q2 | Which vdev topologies are supported? | installer/loader contract |
| Q3 | Is compression permitted on the boot path, and which algorithms? | installer/loader contract |
| Q4 | Is encryption excluded on the boot path? | installer/loader contract |
| Q5 | Is Appendix A's traversal complete for the resolution requirement? | implementation choice |
| Q6 | What is the upgrade model, and therefore BE identity? | **product decision** |
| Q7 | Does the OE kernel require verification beyond ZFS's integrity? | **product decision** |
| Q8 | Can LOM v1 distinguish "no producer" from "target unavailable"? | **AD-59 dependency** |
| Q9 | What is the version-compatibility rule? | installer/loader contract |

Q1 through Q4 and Q9 are the negotiation this document exists to hold:
every guarantee the installer makes is a code path the loader does not
write, and neither party can set the boundary alone.

Q5 is an implementation choice, constrained by the contract but not
fixed by it.

Q6 and Q7 are product decisions. pgsd-loader cannot make them
(ADR 0002 Decision 1), and ADR 0002 records that the upgrade model is
*"explicitly not ruled."*

Q8 is a cross-document dependency on AD-59. This contract found it and
does not resolve it.

**None of these is a weakness in the draft. Identifying them, and being
clear about who owns each, is the work.** A first version's purpose is
to define the safe envelope in which L3b can be designed, not to settle
every question inside it.

---

## Appendix A: candidate ZFS traversal (implementation note)

Not normative. This records the traversal current OpenZFS layouts
require to satisfy section 6.1's resolution requirement, so that the
contract can name an outcome while the implementation has somewhere to
record the mechanism.

  1. the vdev label and uberblock (find the newest valid uberblock),
  2. the MOS (the meta object set the uberblock names),
  3. the DSL directory tree (to resolve dataset names),
  4. the pool's `bootfs` property, or whatever the BE identity model
     (section 8) determines,
  5. the target dataset's object set,
  6. the file blocks of the kernel and its metadata.

This is the traversal FreeBSD's own boot reader performs
(`stand/libsa/zfs/zfsimpl.c`). It may be wrong for PGSD without the
contract being wrong: if a later design resolves the unit through a
manifest or an index, Appendix A changes and section 6.1 does not.

---

## Appendix B: implementation status (informative)

Not normative. Where the implementation is today, recorded separately
from what must be true so that no future reader mistakes the present
state for the specification.

**The OE currently boots through the L3a (BAS) path.** deploy.sh stages
`/boot/kernel/kernel` into a BAS slot and pgsd-loader boots it from
there. ADR 0004 sanctions this explicitly, as the L3a path being
exercised: *"the pool-independent path that serves the Recovery
environment by design and the bench immediately."* It is not a claim
that the OE kernel is a BAS artifact, and it is not an authority
violation.

It is, however, a standing violation of **B2 (OE coherence)** for as
long as it is the OE's actual boot path: the kernel comes from the BAS
and the userland from ZFS, so a pool rollback reverts one without the
other, which Decision 5.1 names a partial rollback. Closing that is what
L3b is for, and it is the concrete reason B2 is named as an invariant
rather than left implicit in Decision 5.1.

**The loader has no observational capability today.** It reads no EFI
variables, reads no pool, and hardcodes its root
(`vfs.root.mountfrom=zfs:zroot/ROOT/default`). The hardcoding is
campaign finding F13, and it went off once already: the named boot
environment had not existed for three reinstalls, and the kernel dropped
to an invisible mountroot> prompt. That is the practical argument for
section 7.3's prohibition on writing a dataset name into the loader as
an assumption.
