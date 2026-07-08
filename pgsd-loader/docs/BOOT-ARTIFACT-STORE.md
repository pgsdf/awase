# BOOT-ARTIFACT-STORE, version 0.1

The subordinate specification of the Boot Artifact Store (BAS)
required by pgsd-loader ADR 0002 Decision 3 and bound by project
ADR 0001 Decisions 2, 3, and 4. Owned jointly by pgsd-loader and
the installer; versioned independently of the ADRs that require
it. Drafted with pgsd-loader ADR 0004 (stage L3a); status
follows that ADR's.

## 1. Purpose and correctness statement

The BAS is the deliberate system partition for immutable boot
artifacts: a FAT32 volume (the UEFI ESP) whose publication
semantics are supplied not by the filesystem but by the writer
protocol this specification defines (TxFAT32, section 7). The
single correctness statement everything below serves:

    The selector is the only mutable object whose state
    determines reachability.

Consequences: slot contents may be incomplete; garbage may
exist; interrupted writes are permissible; recovery never
examines partially written slots except to reclaim them.
Correctness rests on choosing between complete states, not on
replaying incomplete ones.

## 2. Volume and sizing

One BAS per bootable disk member. Sizing per ADR 0002 Decision
3: 2 GiB baseline, growable to 4 GiB; the supported size is
validated per platform and recorded as an installer hardware
assumption. FAT32; the volume is otherwise an ordinary ESP and
remains readable by any firmware or FAT implementation.

## 3. Layout

    EFI/BOOT/BOOTX64.EFI          firmware default path (optional,
                                  removable-media convention)
    EFI/freebsd/loader.efi        stock loader, fallback target,
                                  never written by PGSD tooling
    EFI/pgsd/pgsd-loader.efi      the loader (firmware domain
                                  artifact, NVRAM-selected)
    EFI/pgsd/bas/selector         the TxFAT32 selector (section 7)
    EFI/pgsd/bas/slots/<N>/       artifact slots (section 6)
    EFI/pgsd/bas/slots/<N>/manifest
    EFI/pgsd/bas/sounds/          loader-domain audio (future L2)

The EFI/pgsd namespace absorbs the provisional L0 seed (ADR 0003
Decision 2) as promised. Paths use 8.3-safe names below
EFI/pgsd/bas so directory entries stay single-slot.

## 4. Content classes

Per project ADR 0001 Decision 4 (split authority), the BAS holds
the pool-independent artifact set only: the loader itself
(firmware domain), Recovery environment kernel and module sets,
Management environment artifacts as defined, per-slot manifests,
and future loader-domain audio. The Operating environment kernel
resides in its system image unit on ZFS and is out of scope for
this store.

## 5. Curation invariants

Kernels ship without debug symbol files and with an
installer-curated module set (ADR 0002 Decision 3); per-kernel
budget assumes curation. Artifacts are immutable after
publication (the publication lifecycle); updates publish new
slots.

## 6. Slots and retention

Artifacts publish into numbered slots. A slot is complete when
its manifest is present and every artifact it lists verifies by
hash. The retained set is the active slot plus N rollback
targets; the product ADR's population for the BAS is small
(loader-domain artifacts only), so N defaults to 2. Slots not
referenced by the selector and not within the retained set are
garbage, reclaimed per section 9.

## 7. TxFAT32: the selector and commit protocol

A writer protocol over unmodified FAT32. Parameterized: this
section's protocol takes the BAS specifics (selector path, slot
namespace, artifact classes) as parameters and assumes nothing
else about the store, so that extraction to a standalone
specification, if the AD-61 evaluation warrants it, is a
documentation move.

### 7.1 The selector object

A preallocated, fixed-size, contiguous file
(EFI/pgsd/bas/selector) of exactly two 512-byte records,
written at creation and never extended, renamed, or truncated
thereafter. Because commits overwrite one existing data sector
of an unchanged file, a commit touches no directory entry and no
FAT chain: the metadata class F8 demonstrated fragile is never
in the commit path.

Record format (little-endian):

    offset  size  field
    0       4     magic "PGBA"
    4       4     format version (1)
    8       8     generation, monotonically increasing
    16      4     active slot number
    20      32    manifest hash of the active slot (SHA-256)
    52      456   reserved, zero
    508     4     CRC32 of bytes 0..507

### 7.2 Read rule

A reader validates both records (magic, version, CRC) and takes
the valid record with the highest generation. One valid record
suffices; zero valid records means an unprovisioned or destroyed
selector, and the reader falls back per the selection-domain
hierarchy (section 10).

### 7.3 Commit rule

The writer overwrites the record with the LOWER generation (or
the invalid one), writing generation max+1. The other record,
the previously committed state, is never touched by the commit
that supersedes it. Alternation is a consequence, not a rule the
writer must remember: always overwrite the loser.

### 7.4 Publication protocol

1. Write the new slot's artifacts under the slot namespace.
2. Write the slot manifest (artifact list with per-artifact
   SHA-256 and sizes).
3. Flush the write path (fsync with device cache flush).
4. Read back and verify every artifact against the manifest and
   the manifest against the build's canonical hashes.
5. Commit: overwrite the losing selector record per 7.3 with the
   new slot and manifest hash.
6. Flush.
7. Report success, recording provenance (project ADR 0001
   Decision 2); only now is the publication complete.
8. Garbage collect (section 9), at leisure.

### 7.5 The ordering contract

Ordering, not journaling: correctness is carried entirely by two
orderings, slot content durable before the selector names it
(steps 3 before 5), and the selector durable before success is
reported (6 before 7). An intent journal is an optional
extension (section 11) that improves diagnosis and audit; it is
not part of the proof.

### 7.6 Invariant: monotonic reachability

Publication may introduce new reachable state; no publication
failure may make previously reachable verified state
unreachable. The protocol guarantees it by construction: the
losing selector record is the only thing overwritten, and it
never names the currently reachable state. This is the property
the L0 fallback design demonstrated repeatedly at the firmware
domain: failures may prevent progress, but they do not remove
the last known-good path.

## 8. Write-path requirements

Only designated deployment tooling writes the BAS (project ADR
0001 Decision 1). Flush semantics must reach the medium: fsync
must be verified on the target OS to issue a device cache flush
for msdosfs, and if it does not, the tooling must flush the
device explicitly. A settle discipline applies between reported
success and any deliberate power event.

## 9. Garbage collection

Any slot directory neither named by a valid selector record nor
within the retained set is an orphan, deletable at any time. GC
runs after successful publication and may run at tooling
startup; it never runs on the active or retained slots and never
blocks a publication's success report.

## 10. Selection domains

    firmware domain: selector is BootOrder and Boot#### entries
        resolves: which EFI application runs (pgsd-loader, or
        the fallback stock loader)
    loader domain: selector is the TxFAT32 selector
        resolves: which slot's verified artifact set is used
    artifact domain: the selected slot
        resolves: nothing further; content is immutable

Each domain resolves exactly one selector and hands execution
downward. The firmware domain's dual entries realize the same
commit pattern (verify before switch, loser retained) on the
NVRAM substrate; the L0 campaign is its evidence. A loader that
finds zero valid TxFAT32 records reports and falls back to
chainloading the firmware domain's fallback path, preserving
monotonic reachability across even a destroyed selector.

## 11. Optional extension: intent journal

An append-only record of publication begin, verify, commit, and
GC events under EFI/pgsd/bas/journal, for volume-resident
diagnosis when the provenance log (which lives on the pool) is
unreachable. Readers must function identically with or without
it; writers may omit it; it is never consulted for recovery.

## 12. Mirror equivalence

Every bootable member carries an equivalent BAS (ADR 0002
Decision 3): equivalent means same selector state, same retained
slots, same artifact hashes. The replication mechanism is the
deployment tooling applying the section 7.4 protocol per member;
a member that fails publication leaves the others unaffected and
the failure reported. Degraded-member boot is a standing bench
criterion.

## 13. Conformance

The installer conforms by provisioning the layout, the
preallocated selector, and the invariants of section 5. The
deployment tooling conforms by the section 7.4 protocol and
section 8 requirements. The loader conforms by the section 7.2
read rule, verification of the selected slot's manifest before
any control transfer, and the section 10 fallback behavior.

## Open questions (resolved by the L3a campaign)

1. msdosfs fsync semantics on the target OS (section 8): verify
   or compensate.
2. Selector sector atomicity on bench storage: single-sector
   overwrite is assumed atomic at the device; the power-loss
   campaign tests the assumption.
3. Whether N=2 retention is right once RE and ME artifact sets
   are real.

## Revision history

- 0.1, 2026-07-08: initial draft with ADR 0004, incorporating
  the AD-61 design and the operator's review: the correctness
  statement, ordering not journaling, monotonic reachability,
  and the selection-domain hierarchy.
