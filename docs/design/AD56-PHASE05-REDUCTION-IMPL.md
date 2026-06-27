# AD-56 Phase 0.5 Delta 3: EFI_FB suppression (reduction)

Implements the REDUCTION stage of Phase 0.5 as the second AD-57
investigational delta. Delta 3 of the three-delta workflow (observe,
understand, modify): this is the modify step, authorized by the ratified
Delta 2 analysis (AD56-PHASE05-INVENTORY-ANALYSIS.md, RATIFIED
2026-06-27) against the EFI_FB target ONLY.

This is the FIRST destructive delta in the boot program: it makes the
kernel stop providing a record it currently provides. It is therefore
default-off, reversible at boot, recovery-gated, and confined to a single
control point.

## Where this code lives

A commit on fork branch awase/ad56-phase05-reduction in
pgsdf/freebsd-src, on top of the Delta 1 observation commit
(4f09e9082493). Per AD-57 it is a fork delta, not an awase change; only
the PGSD-DEBUG config already carries the build flag. This document is the
design record.

## Hypothesis under test

EFI_FB is OPTIONAL: the kernel reaches userspace without it. Delta 2
established EFI_FB is consumed only by drawfs (single inventory request,
caller drawfs MOD_LOAD) and that drawfs returns ENODEV cleanly on absence.
Delta 3 tests this on hardware by suppressing EFI_FB and confirming the
kernel still boots to userspace.

## Mechanism (single control point)

A default-off boot tunable gates EFI_FB resolution at the one chokepoint
already instrumented, preload_search_info. When the tunable is set,
preload_search_info returns NULL for the EFI_FB type only, exactly as if
the record were absent. Every consumer already handles absence (drawfs via
ENODEV); suppression reuses that existing absence path rather than adding
new failure handling.

  tunable: hw.pgsd.ad56.suppress_efi_fb (int, default 0)
  gate:    in preload_search_info, when
           inf == (MODINFO_METADATA | MODINFOMD_EFI_FB)  (0x9005)
           and the tunable is set, return NULL before the walk.

Default 0 means a normal boot is byte-for-byte behaviorally identical: the
gate is inert unless the operator sets the tunable. This satisfies the
control-arm test (boot with tunable off, verify no change) before the
suppression test.

## Early-boot safety (why the tunable read is placed in the EFI_FB branch)

preload_search_info is called both very early (structural reads in locore)
and late (drawfs EFI_FB read at MOD_LOAD). Reading a tunable
(kern_getenv) is only safe once the kernel environment is initialized,
which is NOT guaranteed in the earliest calls. The gate therefore reads
the tunable ONLY inside the EFI_FB type branch, which is reached only when
EFI_FB is requested. The Delta 1 inventory showed EFI_FB requested exactly
once, by a late (MOD_LOAD) caller, so the tunable read never occurs during
the early-unsafe window. This keeps the read safe by construction and
confines the whole mechanism to the EFI_FB branch.

REQUIRES BENCH VERIFICATION: confirm no consumer requests EFI_FB before
the kernel environment is ready. The single late inventory request
supports this, but a configuration that reads EFI_FB earlier would need
the cached-at-SYSINIT variant instead.

## Reversibility and recovery

  - Reversible at boot: unset the tunable (or boot the known-good BE) and
    EFI_FB is provided normally again. No rebuild needed to recover.
  - Default-off: the delta can live in the kernel without changing default
    boot behavior; suppression is opt-in per boot.
  - Single control point: the entire mechanism is one block in
    preload_search_info. Removing it later (whether the reduction is made
    permanent or abandoned) is a one-block revert, not a scattered change.
  - EFI_MAP is never touched (native_parse_memmap panics without it).

## Test procedure (steps 4 and 5)

Control arm first:
  4. Boot with hw.pgsd.ad56.suppress_efi_fb = 0 (default). Verify the
     kernel boots normally and drawfs maps the framebuffer as before
     (dmesg: drawfs EFI framebuffer mapped). Proves the delta is inert by
     default.

Suppression arm:
  5. Boot with hw.pgsd.ad56.suppress_efi_fb = 1 (set in loader.conf or at
     the loader prompt). Verify:
       - the kernel reaches userspace (confirm via SSH/serial, since the
         display may go dark: drawfs owns the framebuffer on this bench and
         will get ENODEV, so the screen may blank; that is EXPECTED
         graceful degradation, not failure);
       - dmesg shows drawfs_efifb: no EFI framebuffer metadata (the ENODEV
         path), confirming suppression took effect;
       - debug.ad56.preload_inventory shows EFI_FB (0x9005) requested with
         found 0 (suppressed) rather than found 1;
       - no panic, no hang.

Success: kernel reaches userspace with the tunable set; drawfs degrades to
no-framebuffer cleanly; recovery (unset tunable or BE) restores EFI_FB.
Failure: panic, hang, or any non-graceful failure. Recovery is the
known-good BE.

CONSOLE NOTE: on this bench drawfs owns the display (kern.vty empty, no
vt_efifb active; drawfs maps the 3840x2160 framebuffer). Suppressing
EFI_FB will likely blank the console. A non-video path to the bench
(SSH/serial) is required to verify userspace was reached. This is expected
degradation, not a crash.

## What this gates

If the kernel reaches userspace with EFI_FB suppressed, the hypothesis
holds and a later phase may consider making the reduction permanent (and
removing the tunable). If it does not, the finding is recorded and EFI_FB
is kept. Either outcome is a clean one-block change at the control point.
This delta does NOT make any reduction permanent; it tests one hypothesis.
