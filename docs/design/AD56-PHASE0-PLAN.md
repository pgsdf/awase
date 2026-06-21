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

## Criterion 1: permanent fallback boot entry, verified on real hardware

Goal: a UEFI boot entry that always boots stock FreeBSD loader.efi, so
any future experiment can be abandoned by selecting it in firmware.

  - From the survey, identify the ESP and the stock loader path
    (typically /EFI/freebsd/loader.efi, with /EFI/BOOT/BOOTX64.EFI as
    the firmware default).
  - Copy the known-good stock loader.efi to a STABLE, never-overwritten
    path on the ESP reserved for the fallback (for example
    /EFI/awase-fallback/loader.efi), so future Awase-loader installs to
    the primary path cannot clobber it.
  - Add a dedicated UEFI boot entry pointing at that fallback path:
        efibootmgr --create --disk <dev> --part <n> \
          --label "FreeBSD stock loader (fallback)" \
          --loader /EFI/awase-fallback/loader.efi
    (confirm efibootmgr create syntax against the bench's version from
    the survey; some FreeBSD efibootmgr builds differ.)
  - VERIFY on real hardware: reboot, select the fallback entry in the
    firmware boot menu, confirm it boots to multi-user. This is the
    criterion; an unverified entry does not count.
  - Record the fallback entry number and the firmware key sequence to
    reach the boot menu in the recovery doc (criterion 4).

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

## Exit

All five criteria met and recorded (boot-chain document, verified
fallback entry, ABI bridge document, tested recovery procedure,
media-free guarantee). Only then does Phase 0.5 (kernel ABI
instrumentation) begin.

## What Phase 0 deliberately does NOT do

No loader code. No menu changes (that is Phase 1, and it waits behind
Phase 0's gates even though it is low risk, because the fallback and
recovery must exist before any boot-path change). No kernel changes
(Phase 0.5 instruments; Phase 0 only reads).

## Sequence

  1. boot-chain-survey.sh  -> boot-chain document (criterion 2)
  2. plan + install + VERIFY fallback entry (criterion 1)
  3. read /usr/src/sys, write ABI bridge document (criterion 3)
  4. document + TEST recovery, prove media-free (criteria 4, 5)
  5. record all five; gate clears; Phase 0.5 may begin
