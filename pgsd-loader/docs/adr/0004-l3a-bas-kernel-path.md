# 0004: stage L3a, the Boot Artifact Store kernel path

## Status

Ratified, 2026-07-08, at revision 2, as an architectural draft
(operator: the revisions strengthen structure rather than adding
mechanism; the protocol, platform, and mechanism layers isolate
the correctness argument; the documents have reached the point
where further improvement comes from implementation and bench
evidence rather than architectural editing). BOOT-ARTIFACT-STORE
is ratified with it at version 0.3, which names the protocol
invariants I1 through I5 per the operator's suggestion at
ratification. L3a.1, the kernel handoff study, begins.

Previously: Proposed, 2026-07-08. Stage ADR under parent ADR 0001 Decision 3
(the L3 subdivision defined by ADR 0002 Decision 5), unlocked by
the ratification of project ADR 0001, which cleared this stage's
gate and decided split authority. ADR-before-code: no L3a code
exists at proposal time. BOOT-ARTIFACT-STORE version 0.1 is
drafted with this ADR, satisfying ADR 0002 closure criterion 2
ahead of implementation.

## Context

L3a gives pgsd-loader the ability to load and start a FreeBSD
kernel from the Boot Artifact Store: the pool-independent path
that serves the Recovery environment by design (project ADR 0001
Decisions 4 and 5.3) and the bench immediately. It is the first
half of the parent's "cliff," deliberately the smaller half: FAT
reads via firmware protocols, artifacts verified by manifest,
and the kernel handoff contract, with no filesystem
implementation of any kind.

The stage carries two bodies of prior decision into
implementation. First, the publication architecture: project ADR
0001's contracts and the TxFAT32 protocol (BOOT-ARTIFACT-STORE
section 7, from AD-61) are what this stage's campaign exercises
under power loss. Second, the handoff contract: stock loader.efi
reproduces years of accumulated expectations about what a
FreeBSD kernel receives; the parent demands design effort before
code here, and this ADR structures that as an explicit
source-anchored study phase rather than pretending the contract
is already understood.

The behavioral invariant governs throughout: until L4 cutover,
the default boot path remains chainload to the stock loader,
byte-for-byte the L0 behavior. L3a adds a capability that is
exercised only when explicitly selected.

## Decisions

### 1. Scope, in four sub-stages

- L3a.1, contract study. Source-anchored reading of the stock
  loader's kernel handoff (ELF load, boot metadata, environment,
  memory map delivery, control transfer), producing a written
  contract document (KERNEL-HANDOFF.md) that the implementation
  is reviewed against. No loader code. The discipline lesson
  from the audiofs work applies: source-anchoring prevents
  architectural blind spots, and the contract is the deliverable.
- L3a.2, kernel load and start. The loader reads the selected
  slot's kernel, verifies it against the slot manifest, builds
  the contract's metadata, and transfers control. Closure is a
  curated kernel booting to multi-user on the bench.
- L3a.3, module preload. The slot's curated module set,
  including drawfs, is loaded and presented per the contract,
  discharging the dependency the parent recorded so no stage
  would strand it.
- L3a.4, minimal environment. The smallest kernel environment
  set the booted system requires, defined by what L3a.2 and
  L3a.3 bench runs show missing, not by loader.conf parity,
  which remains explicitly out of scope.

### 2. Activation is selector-gated; the default path is untouched

The BAS-kernel path runs only when explicitly selected: a
dedicated firmware test entry during the campaign, and
thereafter the TxFAT32 selector arms it for the environments
that use it. The default entry continues to chainload stock
loader.efi unchanged until L4. Under the behavioral invariant,
every L3a patch answers: does this change anything on the
default path? The answer must be no.

### 3. Verification precedes control transfer

The loader verifies the selected slot's manifest and the
kernel's (and each module's) hash against it before building any
handoff state, and refuses the slot on any mismatch, falling
back per BOOT-ARTIFACT-STORE section 10. This is project ADR
0001 Decision 6.3 in loader form, and the loader-domain
instantiation of the integrity property the L0 deploy
verification provides at publication time: verified at publish,
verified again at use.

### 4. BOOT-ARTIFACT-STORE 0.1 is this stage's specification

Drafted with this ADR; the installer provisions it, the
deployment tooling implements the section 7.4 protocol, and this
stage's loader implements the read side. The AD-61 disposition
executes here: TxFAT32 is specified as the parameterized section
7, and the extraction question is answered by this stage's
campaign, not before.

### 5. The publication campaign is a closure criterion, not an afterthought

The stage closes on two campaigns, run in the L0 ledger
methodology (a campaign document, findings with dispositions,
operator-ratified stopping rules):

Publication campaign, expressed as hypotheses the evidence
confirms or refutes:

- H1: the ordering contract guarantees monotonic reachability
  under power interruption at every protocol phase boundary
  (during slot write, after slot durability before commit,
  mid-selector-write, after commit before report).
- H2: recovery is deterministic at every interruption point,
  the selector resolving to exactly one complete verified state
  with GC reclaiming the debris.
- H3: the platform assumptions hold on bench hardware
  (BOOT-ARTIFACT-STORE section 14, A1 and A2).
- H4: TxFAT32 merits standalone extraction only if the campaign
  record supports it; the AD-61 disposition is written from the
  evidence, in either direction.

Boot campaign: the selected slot's kernel and modules boot to
multi-user on the bench with drawfs preloaded and the ADR 0032
chime audible; the default chainload path demonstrated unchanged
throughout; fallback demonstrated from a refused slot and from a
destroyed selector.

### 6. Non-goals

Stated explicitly so scope cannot drift into them:

- L3a does not replace the stock loader; the default boot path
  chainloads it, unchanged, until L4 rules otherwise.
- L3a implements no filesystem. ZFS reading is L3b, separately
  gated; FAT is read through firmware protocols only.
- L3a does not reproduce loader.conf or lua semantics; L3a.4 is
  defined by what the bench shows missing, and configuration
  parity is a non-goal by ratified parent decision.
- L3a does not optimize performance. The campaigns test
  correctness properties; speed is measured only to detect
  regressions, never pursued.

## Closure criteria

1. KERNEL-HANDOFF.md exists and the implementation is reviewed
   against it (L3a.1).
2. BOOT-ARTIFACT-STORE 0.1 provisioned by the installer;
   deployment tooling implements the publication protocol;
   provenance recorded per project ADR 0001 Decision 2.
3. Publication campaign complete under an operator-ratified
   stopping rule, including the induced power-interruption
   matrix, with the spec's open questions 1 and 2 answered and
   recorded.
4. Boot campaign complete: multi-user from a BAS slot with
   modules and chime; default path unchanged; fallback from
   refused slot and destroyed selector demonstrated.
5. The AD-61 extraction question receives an evidence-based
   disposition from the campaign record.
6. Findings disposed per the ledger methodology.

## References

- Project ADR 0001 (ratified rev 2): the contracts this stage
  implements and the gate its ratification cleared.
- pgsd-loader ADR 0002 (ratified rev 3): the L3 subdivision, the
  BAS, and closure criterion 2 discharged by this ADR's spec
  draft.
- pgsd-loader ADR 0003 (closed) and the L0 campaign ledger: the
  methodology template and the firmware-domain selector
  evidence.
- BACKLOG AD-61: the TxFAT32 design this ADR's spec section 7
  realizes and this stage's campaign evaluates.
- BOOT-ARTIFACT-STORE.md 0.1: drafted with this ADR.

## Revision history

- Revision 1, 2026-07-08: initial proposal, drafted on the
  operator's L3a target list following project ADR 0001's
  ratification.
- Revision 2, 2026-07-08: operator review applied. The
  publication campaign restated as hypotheses H1 through H4,
  including the evidence-in-either-direction framing of the
  AD-61 extraction disposition; non-goals stated as Decision 6.
  Companion changes in BOOT-ARTIFACT-STORE 0.2 (layering,
  definitions, assumptions).
- 2026-07-08: ratified at revision 2 with the specification at
  0.3.
