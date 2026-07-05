# AD-58 Recovery authority publication: mechanism comparison

Status: Design exploration (non-ratified). Purpose: evaluate candidate
publication mechanisms against the derived requirements, to identify the
strongest mechanism for publishing the Recovery designation. This document is
exploratory and may change. It establishes no durable architecture and amends
no ADR. It selects no mechanism as ratified; it assesses which is strongest so
that the Recovery establishment event can later be designed against a chosen
mechanism.

## Position in the sequence, and what this note may and may not conclude

The Recovery authority contract (AD-58 first addendum) fixed that the
designation is published loader-observably and consumed without inference. The
publication design note derived the publication requirements R1 through R7 (and
the separate consumer invariant R8). The promotion-semantics addendum settled
that promotion creates candidates and does not advance the designation, so the
event set that changes the designation is reduced to a single deliberate
Recovery establishment event, which remains deferred.

This note evaluates candidate mechanisms against those requirements. Two scope
limits are stated up front, because they determine what the note may honestly
claim:

  - The publication mechanism answers HOW the designation is represented,
    observed, and updated. The Recovery establishment event answers WHEN it is
    allowed to change. This note is about the first. It does not design the
    establishment event.

  - R7 (no silent staleness) has two layers. Mechanism CAPABILITY: can a
    mechanism detect, prevent, or expose stale designations? This is a
    property of the mechanism and is evaluated here. Policy BEHAVIOR: under the
    eventual establishment policy, how much stale state exists in practice?
    This depends on when Recovery is re-established and is NOT evaluated here.

  Consequently this note never claims a mechanism "satisfies R7." It claims at
  most that a mechanism "provides the capabilities required to satisfy R7 once
  the establishment policy is defined." R1 through R6 are evaluated fully; R7
  is evaluated only as intrinsic mechanism capability.

This note is a comparative exploration, not a proof. It does not claim to have
exhausted the space of possible mechanisms, and it selects none as ratified;
it narrows the candidate space and identifies the strongest candidate for the
next step to build on. Several of the advantages it attributes to the leading
candidate are properties the mechanism's model naturally supports rather than
behaviors this note empirically establishes; where that is so, the note says
so, and the concrete read and update semantics are confirmed in the
establishment-event design that follows.

A word on sequencing, since this note assumes the publication mechanism is
chosen before the establishment event is designed. That ordering is
deliberate: choosing the mechanism first lets the establishment event be
designed against concrete update semantics (the actual operation that changes
the chosen representation) rather than against an abstract publication
interface. A policy designed to consume a concrete mechanism is cleaner than
one that must constrain an unspecified mechanism abstractly. The mechanism is
the contract; the establishment event is the policy that consumes it; the
contract is settled first.

Terminology follows the addenda: PGSD is the operating system, AD-58 is the
PGSD lifecycle, awase be is the lifecycle's Boot Environment implementation,
AD-59 is the bootloader.

## What the loader actually observes (grounding for R2 and R3)

The requirements R2 (loader-stage observability) and R3 (durability across
environment loss) are not abstract on this platform; they are grounded in what
the FreeBSD loader can read before kernel load and in what the founding
failure showed must survive.

Loader-stage observation, from the existing AD-59 pipeline: the loader reads
loader environment variables (for example zfs_be_active, and the
pgsd_recovery_request producer added in Part 15), and enumerates Boot
Environments through core.bootenvList(). These are established loader-stage
facts. A mechanism is R2-observable only if the loader can read it by such
means before the kernel loads.

Durability, from AD-58's founding failure: the designation must survive the
case that motivated the lifecycle, in which "the bench had to be reinstalled"
and "the broken environment was destroyed in the process." R3 therefore means
the designation survives destruction or reinstallation of the Operational
Environment and remains readable when only the recovery path is left. A
mechanism stored inside the environment that may be destroyed does not satisfy
R3.

## The candidate mechanisms

Five candidates, spanning where the designation could live:

  - A. Filesystem marker: a file at a known path in a filesystem the loader
    can read.
  - B. GPT partition attribute: an attribute bit or field on a GPT partition
    entry.
  - C. EFI variable: a variable in EFI non-volatile storage.
  - D. ZFS property: a user property on a pool or dataset.
  - E. Boot Environment metadata: a designation recorded in the BE metadata
    the lifecycle already maintains.

Each is evaluated against R1 through R6 fully, and R7 as capability.

## Evaluation against R1 through R6, and R7 as capability

### A. Filesystem marker (file at a known path)

  - R1 (single writer): achievable by convention (only awase be writes it),
    but a plain file has no inherent writer restriction; discipline, not the
    mechanism, enforces it.
  - R2 (loader-observable): depends on WHICH filesystem. A marker in the ESP
    (the EFI System Partition) is loader-readable; a marker inside a specific
    BE's root is readable only if that BE is accessible. If the marker lives
    in the environment that may be lost, R2 and R3 both suffer.
  - R3 (durability across environment loss): weak if the file lives in the OE
    (destroyed on reinstall); acceptable only if placed in a partition that
    survives OE loss (for example the ESP).
  - R4 (stability): the file changes only when written; acceptable.
  - R5 (atomic update): achievable with the write-to-temp-and-rename idiom on
    a journaling or copy-on-write filesystem, though the loader-readable ESP
    (FAT) has weaker atomicity guarantees.
  - R6 (defined absence): natural; absence of the file is a representable,
    detectable state.
  - R7 (capability): a file can carry a version or generation field, so
    staleness detection is possible, but a file does not intrinsically couple
    to the object it designates; a stale file can name a vanished target with
    no inherent coupling to reveal it. Staleness is detectable only if the
    format is designed to carry the information and the consumer checks it.

### B. GPT partition attribute

  - R1 (single writer): the partition table is a single system-level
    structure; writable by anything with disk access, so single-writer is by
    discipline, not mechanism.
  - R2 (loader-observable): GPT is loader-readable in principle, but encoding a
    designation as an attribute bit is expressively narrow (a bit or small
    field), poorly suited to naming one of several possible Recovery targets.
  - R3 (durability): high; the partition table survives OE reinstallation.
  - R4 (stability): acceptable; changes only when written.
  - R5 (atomic update): partition-table writes are not obviously atomic with
    respect to a concurrently reading loader, and a torn partition table is a
    serious hazard well beyond this feature.
  - R6 (defined absence): awkward; "no designation" must be encoded in the
    attribute space, and partition attributes have predefined meanings that
    constrain reuse.
  - R7 (capability): an attribute bit carries no version or identity
    information, so staleness is not intrinsically detectable; the mechanism
    is too narrow to expose divergence.

### C. EFI variable

  - R1 (single writer): EFI variables can be namespaced by GUID, giving a
    reasonable single-owner story, though any privileged component can write
    EFI variables.
  - R2 (loader-observable): EFI variables are readable at loader stage on EFI
    systems; the loader runs in the EFI environment.
  - R3 (durability): high in one sense (survives OE reinstallation, lives in
    firmware NVRAM), but firmware NVRAM is a constrained, wear-sensitive, and
    occasionally unreliable store, and its contents are outside the pool and
    outside the system's own backup and replication.
  - R4 (stability): acceptable; changes only when written.
  - R5 (atomic update): EFI variable writes are single-variable atomic at the
    firmware interface, which is reasonable.
  - R6 (defined absence): natural; a missing variable is detectable absence.
  - R7 (capability): a variable can carry a version field, so staleness
    detection is possible, but like a file it does not intrinsically couple to
    the object it designates; a stale value can name a vanished target unless
    the format and consumer detect it. It also sits entirely outside the ZFS
    world the designation refers to.

### D. ZFS property (user property on pool or dataset)

  - R1 (single writer): a pool or dataset user property is written through zfs,
    which awase be already uses; a single-owner discipline is natural and
    consistent with awase be being the lifecycle's implementation.
  - R2 (loader-observable): the loader already reads ZFS boot configuration and
    enumerates BEs, so ZFS is the store the loader is closest to at loader
    stage. This candidate's R2 standing is therefore conditional: it is
    strongest ASSUMING the selected property is readable by the loader at
    loader stage. Whether a specific user property is readable as-is or
    requires a defined loader-stage read is not established here; it is a
    concrete point the establishment-event design confirms (and may require
    reconnaissance). The claim is that ZFS is plausibly strongest given
    straightforward loader access to the selected property, not that such
    access is already demonstrated.
  - R3 (durability): high and, importantly, IN THE SAME STORE as the objects
    designated. A pool-level property survives OE reinstallation (it is on the
    pool, not in the OE dataset), and it is carried with the pool through the
    system's own ZFS replication and backup.
  - R4 (stability): acceptable; a property changes only when written.
  - R5 (atomic update): the ZFS property model naturally supports atomic
    property updates; the concrete atomicity of the specific update operation
    is confirmed in the establishment-event design.
  - R6 (defined absence): natural; an unset property is a detectable absent
    state.
  - R7 (capability): strongest of the candidates on architectural grounds. A
    ZFS property lives in the same store as the Boot Environments it
    designates, so the designation and the objects are coupled in one store
    rather than split across two. A property can carry a version or generation
    for staleness detection, and the ZFS property model is designed so that
    properties travel with the data under pool operations, which means the
    designation is positioned to travel with the objects it refers to rather
    than diverging from them. (That properties are carried under specific
    operations such as cloning and replication is an implementation behavior
    this note does not establish; it is noted as a model property the
    establishment-event design confirms.) This coupling in one store is what
    makes silent divergence between the designation and the objects least
    likely, and it is precisely the coupling a file, an EFI variable, or a
    partition attribute lacks. This provides the capabilities required to
    satisfy R7 once the establishment policy is defined.

### E. Boot Environment metadata (designation in the BE metadata)

  - R1 (single writer): awase be owns BE metadata, so single-writer is natural.
  - R2 (loader-observable): depends on whether the loader can read that
    metadata at loader stage; BE metadata is often consulted by tooling above
    the loader, and loader-stage readability is not guaranteed. This is the
    main risk for this candidate.
  - R3 (durability): depends on WHERE the metadata lives. If it lives with the
    pool or an always-present dataset, durability is high; if it lives inside
    an individual BE, it shares that BE's fate.
  - R4 (stability): acceptable.
  - R5 (atomic update): depends on the metadata store's semantics.
  - R6 (defined absence): representable if the metadata schema defines it.
  - R7 (capability): if the metadata is structured, it can carry version and
    identity, so staleness detection is possible; whether it couples to the
    designated object depends on where and how the metadata is stored. In the
    case where BE metadata is itself a ZFS property, this candidate converges
    toward candidate D.

## Assessment

Measured against R1 through R6 fully and R7 as capability, the ZFS property
(Candidate D) is the strongest publication mechanism identified in this
exploration:

  - It is durable in the same store as the objects it designates (R3), so it
    survives OE reinstallation and travels with the pool through replication,
    which is the durability the founding failure demands.
  - It naturally fits within the loader's existing ZFS-aware world at loader
    stage (R2), where the loader already reads ZFS boot configuration, subject
    to confirming loader access to the selected property in the
    establishment-event design.
  - It has a natural single-writer story through zfs and awase be (R1),
    single-property atomic update (R5), detectable absence (R6), and stability
    between writes (R4).
  - On R7 as capability, it is strongest because it couples the designation to
    the designated objects in one consistent store, making silent divergence
    least likely; it provides the capabilities required to satisfy R7 once the
    establishment policy is defined.

The alternatives are weaker on specific, architectural grounds, not
convenience: the filesystem marker (A) is durable only if placed outside the
OE and does not couple to the designated object; the GPT attribute (B) is
expressively too narrow and raises partition-table-write hazards; the EFI
variable (C) is loader-observable and durable but sits outside the ZFS store
the designation refers to, in a constrained firmware NVRAM, so it splits the
designation from the objects; BE metadata (E) is natural for ownership but
risks loader-stage unreadability.

There is an architectural insight in Candidate E worth stating beyond a
criticism of it: where BE metadata is strong (durable, coupled to the objects,
single-writer), it is strong precisely by being stored as a ZFS property, and
so it converges toward Candidate D. This is not only a weakness of E; it is an
explanation of why the candidate space collapses. The properties that make a
publication mechanism strong for this purpose, durability in the same store as
the designated objects and coupling that resists silent divergence, are the
properties a ZFS property has intrinsically, so candidates that approach those
properties approach being a ZFS property. The convergence is evidence for the
ZFS property being the natural attractor in this space, not merely the
highest-scored entry in a list.

This assessment does not claim to have exhausted the mechanism space, and it
selects no mechanism as ratified. It concludes that a ZFS property is the
strongest mechanism identified, so that the Recovery establishment event can
be designed against a concrete mechanism rather than an abstract one.

## What is next (and what is deliberately not concluded here)

Not concluded here: ratification of any mechanism; the exact ZFS property
(pool versus dataset, name, value representation of the designation); and the
Recovery establishment event.

Next, in order:

  1. If this assessment is accepted, treat the ZFS property as the working
     mechanism (still non-ratified) so that the establishment event is designed
     against it.

  2. Design the Recovery establishment event: exactly when the designation
     changes, the atomic update operation on the chosen mechanism, and the
     operational (policy) interpretation of R7, completing what this note left
     as a policy question.

  3. Specify the AD-59 producer that observes the published designation and
     upholds R8, against the chosen mechanism.

  4. Ratify the mechanism (and, if warranted, promote it into AD-58 as a
     further addendum) once it and the establishment event together form a
     stable commitment.

Status: Design exploration (non-ratified). It evaluates five candidate
publication mechanisms against R1 through R6 fully and R7 as intrinsic
capability, assesses that a ZFS property is the strongest mechanism identified
(providing the capabilities required to satisfy R7 once the establishment
policy is defined), and selects no mechanism as ratified, leaving the
establishment event and mechanism ratification to later steps.
