# AD-56 Phase 0 execution plan

Phase 0 of the boot-path ownership program (docs/design/
BOOT-PATH-OWNERSHIP.md). Observation, the escape hatch, the ABI bridge
document, and a tested recovery path. No fresh-loader code. Zero
bootability risk: every step here either reads, or adds a fallback that
strictly increases recoverability. The five exit criteria are hard
gates; Phase 0.5 and all later phases wait behind all five.

Key fact established 2026-06-21: pgsd-kernel/ holds a kernel CONFIG
(a GENERIC derivative), not a vendored source tree. The boot-metadata
handoff code that defines the ABI bridge lives at /usr/src/sys on the
bench, not in this repo. The ABI bridge document is therefore bench-side
reading work against /usr/src/sys, named precisely below.

## Hardware model note (Apple firmware): recovery layers

The bench is an Apple-firmware Mac. Boot selection is the Option-key
picker, which shows one "EFI Boot" per bootable ESP and ignores UEFI
BootXXXX variables. Recovery therefore stands on two hardware-verified
layers, neither of which is an efibootmgr entry:

  1. The FreeBSD loader's ZFS boot-environment menu (within-disk
     recovery: bad kernel/userland, loader intact). Reachable via the
     single "EFI Boot" -> loader -> BE menu. Verified on the bench.
  2. A separate bootable ESP carrying a known-good stock loader
     (independent recovery: broken loader, the fresh-loader risk). Apple
     firmware would show it as its own "EFI Boot." On this hardware no
     such second ESP exists (one disk, one ESP, nearly full), and one is
     NOT built in Phase 0: see criterion 1, where this fallback is
     specified and DEFERRED to the Phase 3 entry gate, because it
     mitigates a failure domain that does not exist until the fresh
     loader does.

Criterion 5 (media-free) is satisfied for the kernel and userland
failure domains today (the known-good BE needs no media). It is NOT yet
satisfied for the broken-primary-loader domain, which has no mitigation
until Phase 3, nor for disk failure (single disk, requires external
media). This is accurate, not a gap to paper over: those domains are
addressed at the Phase 3 entry gate (loader) and via the second-SSD
feature request (disk).

## Criterion 2 first: boot-chain document (do this before anything else)

Run the read-only survey:

    sudo sh boot-chain-survey.sh

It captures, into /var/tmp/awase-boot-survey/<ts>/: the firmware boot
entries and order (efibootmgr -v), the ESP contents and which loader the
firmware actually runs, the /boot layout (Lua vs Forth menu, loader.conf
state, beastie/delay knobs), and the current kernel handoff (loaded
modules, the GOP framebuffer drawfs consumes, and any ZFS boot
environments). The output is the boot-chain document. Read it before
planning the fallback, because the fallback plan depends on the exact
firmware entry layout and whether the system is ZFS-boot (which gives a
free rollback mechanism).

## Criterion 1: recovery architecture (independent-loader fallback deferred to Phase 3 entry)

HARDWARE FINDINGS (2026-06-21, all verified on the bench, several
correcting earlier assumptions):

  - Apple firmware boot selection is the Option key. It shows one
    "EFI Boot" per bootable ESP and IGNORES UEFI BootXXXX variables and
    BootOrder. The efibootmgr Boot0001 "Awase fallback" entry created
    earlier is therefore inert for firmware-level selection and is
    RETIRED as criterion 1's mechanism (kept in NVRAM only as harmless;
    the FreeBSD loader still honors BootOrder once it has control).
  - The bench has ONE visible disk: ada0 (932G Apple HDD), a single
    AHCI port (ahci0: 1 port). One ESP (efiboot0, 260M), gptboot0, swap,
    ZFS-on-root. ada0 is nearly full: no free space for a second ESP
    without repartitioning.
  - The Boot0080 / BootFFFF NVRAM entries reference a partition GUID
    (12f3...) that does NOT exist on ada0. They are stale and may be
    deleted (efibootmgr -B); they are not a recovery resource. Earlier
    reasoning that "a second ESP exists" was wrong: a second boot ENTRY
    existed, not a second partition.
  - A second SSD is physically present (this iMac chassis) but does NOT
    enumerate (single AHCI port). Deferred to a separate hardware
    feature request; not an available fallback target today.

### Why the independent-loader fallback is deferred, not built now

Phase 0 reduces risk; it must not introduce new risk. Building the
independent-loader fallback today means repartitioning a nearly full
ZFS-root disk to carve a second ESP, the single riskiest operation that
would be in Phase 0, undertaken to mitigate a failure domain that does
not exist yet. The completely-broken-primary-loader domain is introduced
by a FUTURE fresh loader (Phase 3); today the bench boots the stock
FreeBSD loader. Requiring risky disk surgery now to prepare for a loader
not yet written inverts Phase 0's purpose. The document's own philosophy
applies: build the mitigation immediately before the risk appears, not
long before. Deferring is also better-informed: by Phase 3 the second
SSD may enumerate, the storage layout may change, or a separate device
may be dedicated, any of which could make a second ESP on ada0
unnecessary. Specify the requirement now; leave the mechanism open.

### Failure-domain status (current)

  - Bad userland: COVERED by verified ZFS boot environments.
  - Bad kernel: COVERED by verified ZFS boot environments.
  - Bad loader configuration (loader still reaches the BE menu): COVERED
    by the loader BE menu.
  - Completely broken primary loader: NOT yet covered. Introduced by the
    Phase 3 fresh loader; mitigation is the independent-loader fallback,
    deferred to the Phase 3 entry gate below.
  - Disk failure: NOT covered (requires external media). Accepted limit
    on a single-disk bench; a dead disk is a hardware failure, not a
    boot-experiment failure. The deferred second-SSD feature request is
    the future path to closing this media-free.

### Phase 0 requirement (what criterion 1 means for Phase 0 closure)

  - Recovery model documented from hardware observation (above). DONE.
  - ZFS boot-environment recovery verified on the bench (the loader BE
    menu reachable, known-good-pre-ad56 selectable). DONE.
  - Independent-loader recovery mechanism designed and validated as
    FEASIBLE: a known-good stock loader on a second ESP that Apple
    firmware shows as its own "EFI Boot." Feasibility rests on verified
    firmware behavior (a second valid ESP would appear as its own
    "EFI Boot"); implementation deferred. DONE as a design.

Criterion 1 status for Phase 0: recovery architecture verified;
independent-loader fallback specified and deferred to the Phase 3 entry
gate. NOT "an efibootmgr entry verified" (that model is retired).

### Phase 3 entry gate (the deferred work, gating the fresh loader)

Before any fresh Awase loader is installed as the PRIMARY loader, all
three must hold:

  1. A known-good stock loader exists independently of the primary
     loader path (mechanism chosen then: a second ESP on ada0, the
     second SSD if it has been made to enumerate, or a dedicated
     device).
  2. That fallback path is boot-tested from Apple firmware selection
     (it appears as its own "EFI Boot" and boots a working stock
     loader).
  3. Recovery from a DELIBERATELY broken loader has been demonstrated
     end to end (break the primary, recover via the fallback, restore).

This moves the expensive and riskier work to the moment it becomes
necessary, and preserves the original intent: never experiment with a
fresh loader unless a tested escape hatch already exists.

## Criterion 3: kernel-entry ABI documented from source

Read /usr/src/sys on the bench and document the handoff the loader
builds and the kernel consumes. Named targets (FreeBSD amd64 UEFI):

  - sys/sys/linker.h: the MODINFO_* and MODINFOMD_* type tags. This is
    the vocabulary of the metadata blob (module name, type, addr, size,
    and the md sub-records: MODINFOMD_HOWTO, _ENVP, _KERNEND, _SMAP,
    _EFI_MAP, _EFI_FB, etc.). The MODINFOMD_EFI_FB record is the GOP
    framebuffer handoff drawfs ultimately consumes.
  - sys/kern/subr_module.c: preload_search / preload_fetch, how the
    kernel walks the preload metadata the loader passed.
  - sys/amd64/amd64/machdep.c (and sys/x86/...): hammer_time / early
    init, where the kernel reads the metadata, the memory map
    (MODINFOMD_EFI_MAP / SMAP), kernend, the envp, and the boothowto.
  - sys/dev/efi or the efifb consumer: where MODINFOMD_EFI_FB is read
    (historically vt_efifb; on the PGSD kernel that is compiled out per
    AD-39, but the metadata record is still passed and is what drawfs
    needs).
  - the loader side for cross-reference: stand/efi/loader and
    stand/common (bi_load* in sys/boot or stand/), which build the blob
    the kernel reads. Reading both sides names every field.

Output: a written ABI bridge document listing each metadata record the
loader passes, its layout, and (provisionally, from source) whether the
kernel consumes it. This is the BRIDGE spec, not the destination;
Phase 0.5 measures which records are actually load-bearing.

## Criterion 4: recovery procedure documented AND tested

Document, then actually exercise, the path back to a known-good boot
after a failed experiment. The mechanism depends on the survey result:

  - If the bench is ZFS-boot (bectl present): the known-good boot
    environment is the rollback. Document: bectl create a pre-experiment
    BE, and the recovery is selecting the prior BE at the loader, or
    bectl activate + reboot. TEST it: create a BE, activate the prior
    one, reboot, confirm.
  - The firmware fallback entry (criterion 1) is the loader-level
    recovery: TEST that selecting it boots stock, already done under
    criterion 1, recorded here as the procedure.
  - nextboot / bootonce for one-shot recovery without making it
    permanent, if applicable.
  - Document the exact firmware key to reach the boot menu on this
    specific board (from the survey / hardware), because a recovery you
    cannot reach under stress is not a recovery.

## Criterion 5: return to known-good WITHOUT external media

The hard gate that makes the program not scary. Verify that every
recovery path in criterion 4 works with no USB stick and no physical
media swap: firmware boot-menu selection of the fallback entry, and/or
ZFS BE selection at the loader, both reachable from a cold boot of the
bench as it sits. If any recovery path requires external media, it does
not satisfy criterion 5; add a media-free path until one exists.
Rationale: the Yokohama bench iterates remotely; a recovery needing
hands-on media is not leanable-on during rapid iteration.

## Exit: Phase 0 complete as revised

Phase 0's deliverables, all complete:
  - Boot chain documented (criterion 2). COMPLETE.
  - Kernel-entry ABI bridge documented from source (criterion 3).
    COMPLETE; the load-bearing subset is deferred to Phase 0.5 by
    design, not an open Phase 0 item.
  - Recovery model documented from hardware observation (criterion 1).
    COMPLETE.
  - ZFS boot-environment recovery verified (criteria 4, 5 for the
    kernel/userland domains). COMPLETE (switch-tested; the loader BE
    menu reached and known-good-pre-ad56 selectable).
  - Independent-loader fallback architecture defined and sequenced to
    the Phase 3 entry gate (criterion 1). COMPLETE as a specification.

Intentionally NOT in Phase 0 (moved out by the criterion-1 correction,
not left undone):
  - Independent-loader fallback IMPLEMENTATION. It mitigates a failure
    domain that does not exist until the Phase 3 fresh loader, and
    building it now would mean repartitioning a near-full ZFS-root disk
    (the riskiest operation that would be in Phase 0). Deferred to the
    Phase 3 entry gate. Re-listing it as a pending Phase 0 item would
    undo that sequencing decision.

The end-to-end boot into the known-good BE, the prerequisite of Phase
0.5 reduction, is DONE (2026-06-24): the known-good BE was selected at
the loader by hand and booted, then the system restored to default. The
recovery path reduction relies on is proven on hardware. Phase 0.5
observation has no unbootable states and was never gated on this;
reduction's recovery prerequisite is now satisfied.

Phase 0 is complete, including the reboot-dependent proofs (criterion 4
reboot-into-BE done 2026-06-24; criterion 1's independent-loader fallback
remains deferred to the Phase 3 gate by design, not pending). Phase 0.5
may begin: observation needs no unbootable states, and reduction's
recovery prerequisite (the proven BE reboot path) is now satisfied.

## What Phase 0 deliberately does NOT do

No loader code. No menu changes (that is Phase 1, and it waits behind
Phase 0's gates even though it is low risk, because the fallback and
recovery must exist before any boot-path change). No kernel changes
(Phase 0.5 instruments; Phase 0 only reads).

## Sequence

  1. boot-chain-survey.sh  -> boot-chain document (criterion 2)
  2. document recovery architecture from hardware; verify ZFS BE
     recovery; specify the independent-loader fallback and DEFER its
     implementation to the Phase 3 entry gate (criterion 1)
  3. read /usr/src/sys, write ABI bridge document (criterion 3)
  4. document + TEST recovery for kernel/userland; prove media-free for
     those domains; record the loader and disk domains as deferred /
     accepted-limit (criteria 4, 5)
  5. reboot once to prove the BE-into-loader recovery path on hardware;
     record criteria; gate clears; Phase 0.5 may begin
