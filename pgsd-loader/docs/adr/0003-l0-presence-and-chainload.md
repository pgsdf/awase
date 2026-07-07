# 0003: stage L0, presence and chainload

## Status

Proposed, 2026-07-07. First stage ADR under parent ADR 0001
(ratified rev 2) Decision 3, consuming ADR 0002 (ratified rev 3).
ADR-before-code: no L0 code exists at proposal time.

## Context

L0 is defined by the parent as presence and chainload: a Zig EFI
application that prints a banner and chainloads stock loader.efi
unchanged, proving the deployment and recovery model rather than
any loader function. Its significance has grown since the parent
was ratified: L0 is now the first bench validation of three
ratified architectural contracts at once. It exercises the
fallback invariant (parent Decision 4) with a real fallback entry
on real firmware; it is the first patch reviewed under the
behavioral invariant (parent Decision 5), changing deployment
only; and it is the first writer into Boot Artifact Store
locations (ADR 0002 Decision 3), even though it writes nothing
but pgsd-loader itself. Nothing in L0 depends on unresolved
product policy: the deployment architecture decision deferred
upstream does not touch presence, chainloading, fallback, or
recovery.

L0 validates, in order of what would hurt most to discover late:
the vendored Zig toolchain's x86_64-uefi build path; deployment
into the BAS on real firmware; chainloading through
LoadImage/StartImage; the fallback boot entry; and recovery
through it.

## Decisions

### 1. The artifact

pgsd-loader is a Zig EFI application built by the vendored
pinned toolchain (tools/bootstrap.sh, sdk/zig/current) for
x86_64-uefi, with source under pgsd-loader/src and its own
build.zig, following the per-subproject build convention. L0
behavior in full: print a banner (name, version, build
identity), then chainload the stock FreeBSD loader from the same
device it was itself loaded from, forwarding load options
unchanged. On any chainload failure it prints the failure and
returns to firmware, so the machine falls through the boot order
to the fallback entry rather than hanging. L0 performs no
selection, no configuration reading, and no output beyond the
banner and failure reporting: under the behavioral invariant,
the banner is the one externally visible addition, and it is
part of the responsibility L0 absorbs (presence).

### 2. Provisional BAS locations

L0 installs pgsd-loader.efi into the EFI/pgsd/ namespace on the
ESP. This is a provisional seed of the BAS layout, deliberately
minimal: the full BOOT-ARTIFACT-STORE specification remains
L3a's to draft per ADR 0002's closure criteria, and it absorbs
or relocates this seed when ratified. The stock loader's path
(EFI/freebsd/loader.efi) is read, never written: the fallback
invariant forbids touching it. Recording the namespace now
prevents L0 from inventing ad hoc paths that the spec would
later have to honor by accident.

### 3. Boot entries and the fallback mechanics

Deployment maintains two firmware boot entries: the primary,
pointing at EFI/pgsd/pgsd-loader.efi, and the fallback, pointing
directly at the untouched stock loader.efi. The fallback entry
is created before the primary is ever activated and is verified
present on every deploy; a deploy that cannot verify the
fallback aborts without changing the boot order. This is the
parent's fallback invariant made mechanical, and it is the
lesson of the stale-adapter boot loss converted from a script
fix into process: the escape hatch is confirmed before each
jump, not after.

### 4. Deployment tooling

A deployment script under pgsd-loader/ (the beginning of this
subproject's absorption of deploy-loader.sh per parent Decision
1) performs: build verification, ESP mount, copy into the
Decision 2 location by publication (write new, then switch,
honoring the ADR 0002 publication lifecycle even at this small
scale), boot entry maintenance per Decision 3, and idempotent
re-runs. Where the machine carries more than one ESP (mirror
members), the tooling applies the same deployment to every
member per the ADR 0002 mirror equivalence invariant; the bench
validates on the bench topology and records it.

### 5. What L0 explicitly does not do

No environment selection (L1), no audio (L2), no kernel handling
(L3), no reading of any configuration, no writes anywhere but
the Decision 2 location and the boot entries. The behavioral
invariant review question for every L0 patch is: does this
change anything but deployment and the banner?

## Closure criteria

1. Reproducible build of pgsd-loader.efi via the vendored
   toolchain from a clean tree, on the bench host.
2. Deploy on the bench machine creates both boot entries, with
   the fallback verified before the primary activates.
3. Cold boots through pgsd-loader chainload to a fully booted
   system indistinguishable from a direct loader.efi boot
   (kernel messages, rc sequence, and the ADR 0032 chime all
   unchanged), repeated enough times that the record is boring;
   the count is recorded in the experiments file.
4. Recovery demonstrated three ways: primary entry removed,
   boots via fallback; pgsd-loader.efi corrupted in place, boot
   falls through to fallback; pgsd-loader.efi deleted, boot
   falls through to fallback. Each restored by re-running the
   deploy.
5. Load-option forwarding verified: a boot with options set on
   the primary entry reaches loader.efi with them intact.
6. The deploy is re-run twice consecutively and is a no-op the
   second time (idempotence).

## References

- Parent ADR 0001 (ratified rev 2): Decision 3 L0 definition,
  Decision 4 fallback invariant, Decision 5 behavioral
  invariant.
- ADR 0002 (ratified rev 3): Decision 3 Boot Artifact Store
  (provisional seed here, full spec at L3a), publication
  lifecycle and mirror equivalence invariants consumed by
  Decision 4.
- pgsd-boot/deploy-loader.sh: the tooling this stage begins to
  absorb, and the stale-adapter lesson behind Decision 3.
- tools/bootstrap.sh: the pinned toolchain the build must use.

## Revision history

- Revision 1, 2026-07-07: initial proposal, drafted first per
  operator sequencing (L0, then the product architecture ADR,
  then L3a) as the first bench validation of the ratified
  architecture.
