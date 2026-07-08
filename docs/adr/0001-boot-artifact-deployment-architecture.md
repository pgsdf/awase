# 0001: boot artifact deployment architecture

## Status

Proposed, 2026-07-08. The first project-level ADR, occupying the
venue established 2026-07-07 for product decisions that
subproject series consume. This document answers the questions
deferred upstream by pgsd-loader ADR 0002 Decision 6, and its
ratification clears or forecloses the gates that decision left
standing.

## Context

This ADR is written after, and because of, evidence that did not
exist when the questions were first posed. Its established
inputs:

- The operator rulings of 2026-07-07: PGSD is ZFS-only; the
  loader supports only installer-defined boot pool invariants
  (pgsd-loader ADR 0002 Decision 2); the ESP is architecturally
  the Boot Artifact Store (BAS), a deliberate system partition
  for immutable boot artifacts with its own subordinate
  specification (ADR 0002 Decision 3).
- The deployment-authority field mapped by ADR 0002 Decision 6:
  ESP authority, ZFS authority, split authority, with evaluation
  criteria and a non-binding advisory ranking.
- The L0 bench campaign (pgsd-loader ADR 0003, closed
  2026-07-08), and above all finding F8: a publication the
  deployment log recorded as complete was held by the disk as
  zero bytes, the FAT having lost directory linkage to
  fully-written data clusters at fast power-off; fsck recovered
  two orphaned cluster chains of exactly the artifact's size.
  The failure was reproduced in effect, understood to the
  cluster, corrected (publish verification by read-back hash),
  and the correction verified by a subsequent successful boot.

F8 graduates from incident to design input. The following
requirements are derived from observed behavior, not precaution,
and bind every decision below:

1. Publication is not complete until the published artifact is
   verified.
2. Filesystem semantics are part of the publication contract,
   not an implementation detail.
3. Deployment tooling must verify what it publishes rather than
   trust write completion alone.
4. Recovery mechanisms are evaluated assuming publication can
   fail in ways that still leave older artifacts usable.

## Decisions

### 1. Deployment authority

Boot artifacts are written only by designated deployment
tooling, acting under operator or upgrade-process authority. No
other component writes them: not the running system in ordinary
operation, not the loader (which reads only), not ad hoc
operator file manipulation outside the tooling. The tooling is
authoritative for the act of deployment; the artifacts' content
authority is the build (the committed sources and the pinned
toolchain that reproduce every artifact byte-identically, per
the L0 criterion 1 result).

Rationale. This generalizes the write-authority invariant
already ratified for the BAS (ADR 0002 Decision 3) to a product
rule for all boot artifacts wherever stored. A single writer is
what makes the publication contract (Decision 2) enforceable and
the provenance record trustworthy: the L0 campaign's deploy log
answered questions operator recall could not precisely because
one tool wrote everything and recorded what it wrote.

### 2. Publication contract

A publication is complete when, and only when, all of the
following hold:

1. The artifact is written by the Decision 1 tooling using
   publish-then-switch semantics: the new content is written
   whole under a non-live name and switched into place, never
   edited in place (the ADR 0002 publication lifecycle,
   product-wide).
2. The published artifact is verified in place: read back and
   content-hashed against the build's canonical hash, after a
   flush of the write path.
3. The publication is recorded: timestamp, artifact identity,
   canonical hash, the hash of what it replaced, and the
   verification outcome, in a machine-kept provenance record.

A publication that fails any element is not a publication;
tooling reports it as a failure and the prior artifact remains
the active one. Success reported by write completion alone is a
contract violation (F8 requirement 3: the L0 deploy log recorded
a publication the disk did not hold, exactly once, and that once
nearly closed a stage on a non-booting primary).

### 3. Durability contract

The guarantee the product requires: at every instant, including
mid-publication and across power loss at any point, the system
can boot some valid artifact set. Older is acceptable; absent is
not.

The guarantee the product deliberately does not require: that
the newest publication survives arbitrary power loss. Newest-
survival is best-effort within the contract; the invariant
protects bootability, not recency.

Filesystem semantics are inside this contract (F8 requirement
2). FAT, which the BAS is constrained to by UEFI, provides no
metadata atomicity: F8 demonstrated data clusters surviving a
power event that their directory linkage did not. The contract
is therefore met by construction above the filesystem, and the
BOOT-ARTIFACT-STORE specification must realize it with, at
minimum: slotted artifacts (a switch to a new slot never
destroys the prior slot's content); verification before any
switch of what the loader will read first; a settle discipline
between publication and any deliberate power event; and firmware
fallback entries that reach an artifact outside the slot being
replaced. ZFS-resident artifacts inherit their durability from
the pool's own semantics, which is part of why they are located
there (Decision 4).

### 4. Boot artifact location: split authority

Evaluated against the ADR 0002 criteria (kernel-update
synchronization; ESP as artifact versus authority; signed-kernel
and secure-boot fit; existing synchronization mechanisms;
boot-environment coherence under rollback; recoverability under
pool damage; auditability), with the campaign's evidence
applied:

- ESP authority: strengthened by the campaign in one respect,
  the publication contract is now proven mechanism rather than
  trusted hook. Weakened decisively in another: F8 demonstrated
  the precise failure class of holding every bootable kernel on
  FAT, and under ESP authority the OE kernel's durability would
  rest permanently on the filesystem least equipped to provide
  it, mitigated only by construction.
- ZFS authority: unchanged from the ADR 0002 assessment, the
  pure architecture and the wrong one alone, because Recovery
  cannot source its kernel from the casualty.
- Split authority: each environment's artifact location matches
  its threat model. Selected.

Decision: split authority. The loader, the Recovery environment
kernel, and any Management environment artifacts reside in the
BAS: pool-independent, protected by the Decision 3 construction,
updated rarely and deliberately. The Operating environment
kernel resides in its system image unit on ZFS (Decision 5),
where checksummed copy-on-write semantics provide the durability
FAT cannot and where rollback coherence is by construction.

Consequences. The constrained ZFS read capability endorsed and
gated by pgsd-loader ADR 0002 Decision 5 is required: upon
ratification of this ADR, that gate clears and L3b design may
begin under BOOT-POOL-INVARIANTS, subdivided and sequenced per
the parent architecture's escalation requirement (L3a first,
which serves the BAS-resident artifacts and Recovery regardless).
The BAS holds a bounded artifact set (loader, RE kernel, ME
artifacts, manifests), so the retained-kernel-set policy from
ADR 0002 Decision 3 applies to a small population, and BAS
capacity ceases to scale with anything.

### 5. Boot environment interaction

Stated as relationship properties, binding on implementations
without naming one:

1. The coherence unit. A bootable system image unit (in the ZFS
   sense, a boot environment) is the unit of upgrade and
   rollback coherence for the Operating environment: a booted OE
   runs a kernel and a userland from the same unit. A rollback
   that reverts one without the other is a partial rollback and
   a violation, whatever mechanism produced it.
2. Unit-coupled publication. Where any artifact outside the unit
   must correspond to the active unit, activation of a unit is
   the event that triggers its publication, under the Decision 2
   contract. Under this ADR's Decision 4 the OE kernel lives
   inside the unit, so in the common case nothing kernel-shaped
   requires activation-coupled publication; the property is
   stated because manifests or future artifacts may.
3. Recovery independence. Recovery environment artifacts are
   independent of every unit and of pool health. No RE artifact
   may reside in, be derived at boot time from, or require the
   readability of, the pool. This is the property that makes RE
   worth having (ADR 0002's assessment of pool damage), restated
   as a product invariant.

### 6. Recovery invariants

Properties that hold even when publication or deployment fails
(F8 requirement 4):

1. Continuous bootability. At every moment, including
   mid-publication, after a failed publication, and after any
   single artifact's loss or corruption, at least one path to a
   functioning system exists. The L0 campaign demonstrated this
   invariant surviving a corrupted primary, a deleted primary, a
   removed boot entry, and an empty published image, planned and
   unplanned.
2. Independence of the recovery path. A recovery path must not
   depend on the artifact being replaced, on the publication
   that failed, or (for RE) on pool health. Firmware-level
   fallback entries pointing outside the artifact set under
   change are the current realization.
3. Verification precedes reliance. A newly published artifact
   does not become the only path to boot before it is verified
   in place, and the prior path is retained until the new
   artifact has demonstrated a successful boot. The campaign's
   F7 is the motivating record: a verified-in-the-log but
   never-booted artifact was one weaker rule away from being
   ratified as working.
4. Exercised, not merely present. Recovery paths are validated
   by routine drills of the L0 campaign's shape, recovery
   demonstrations are part of stage closure criteria, and a
   recovery mechanism that has not been exercised is treated as
   unverified.

## Closure criteria

This is a product architecture ADR; ratification puts it in
force. Downstream consumption that its ratification unlocks or
binds:

1. pgsd-loader ADR 0002 Decision 5's gate clears for L3b design
   (constrained ZFS read), sequenced after L3a per the parent
   escalation rule.
2. BOOT-ARTIFACT-STORE (drafted at L3a) realizes the Decision 3
   construction: slots, verify-before-switch, settle discipline,
   fallback reachability.
3. BOOT-POOL-INVARIANTS is drafted before L3b design, per ADR
   0002.
4. Installer and upgrade tooling requirements derive from
   Decisions 1, 2, and 5; their design documents cite this ADR.
5. The relationship properties of Decision 5 bind any future
   upgrade-tooling ADR without prescribing its mechanism.

## References

- pgsd-loader ADR 0002 (ratified rev 3): the deferred questions,
  the field mapping, the evaluation criteria, the BAS, and the
  gates this document clears.
- pgsd-loader ADR 0003 (closed) and docs/L0-BENCH-CAMPAIGN.md:
  the evidentiary basis, findings F1 through F8.
- pgsd-loader ADR 0001 (ratified rev 2): the parent staging and
  escalation rules the Decision 4 consequences are sequenced
  under.
- Operator statement, 2026-07-08: the four F8-derived
  requirements adopted verbatim in Context.

## Revision history

- Revision 1, 2026-07-08: initial proposal, structured on the
  operator's six decision questions, written against the L0
  campaign's evidence.
