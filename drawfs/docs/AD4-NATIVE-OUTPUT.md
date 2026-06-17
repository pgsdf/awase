# AD-4: Native Display Output (planning)

Status: PLANNING. Not scheduled. This is a program-level design
document, not an ADR. It frames the problem, states the ownership
principle and the end-state model, decomposes the work into phases,
and names the concrete decisions that each become their own ADR when
the program is scheduled. Nothing here authorizes code.

## Ownership principle

Awase follows a serious ownership model: it owns its substrate end to
end. It already owns input (inputfs), audio (audiofs, semasound),
timing (chronofs), and composition (drawfs, semadraw). Graphics
output is the last major piece Awase does not own; today it is borrowed
from firmware (efifb) or from Linux (drm-kmod). AD-4 brings graphics
output under the same ownership model.

Because the ownership model is taken seriously, AD-4 takes the
BROAD scope: native programming of the GPU up to and including
memory management, command submission, and the render engine, over
time and per vendor. This is a multi-year, multi-vendor program by
nature, and the ownership model accepts that cost deliberately. The
phasing below sequences the work so that each phase delivers a
working output path on its own; it does not narrow the ambition.

## End-state model: native by default, compatible by tier

The end state is not the removal of efifb and drm-kmod. It is a
tiered output stack with native preferred and the external paths
retained for backwards compatibility and graceful degradation:

  - native (default, preferred): Awase programs the GPU directly. The
    default build and the default runtime neither require nor load
    drm-kmod. This is what "DRM/KMS-less by default" means.
  - drm (compatibility tier): the existing drawfs_drm.c path, kept
    buildable and runtime-selectable for GPUs that have no native
    Awase driver yet. Backwards compatible, not the default.
  - firmware-framebuffer floor (universal): the UEFI GOP linear
    framebuffer, available on any UEFI machine, the always-reachable
    fallback and recovery path. Today this path leans on FreeBSD's
    efifb facility; long term Awase consumes the GOP through its own
    framebuffer and FreeBSD's efifb is itself replaced (see "Long
    term: Awase owns the floor").

Selection stays on `hw.drawfs.backend`, which gains a `native`
value beside swap/drm/efifb. The intended automatic order is native
when a native driver matches the GPU, else drm if available, else
efifb. The operator can always pin a tier.

## The two borrowed dependencies are not the same size

This framing still matters, because it sets the order of attack.

  - efifb is a thin firmware dependency with two layers worth
    separating. The UEFI GOP linear framebuffer is the irreducible
    handoff every OS receives from firmware at boot; Awase cannot avoid
    receiving it, only choose how it consumes it. FreeBSD's wrapper
    for the GOP is vt_efifb (there is no separate efifb driver
    distinct from it), and on a PGSD kernel that wrapper is already
    gone: AD-39 compiled vt(4) and vt_efifb out (superseding AD-10
    and its ADR 0001 loader.conf approach), so drawfs consumes the
    loader-provided GOP framebuffer with no FreeBSD console driver in
    the way. The residual borrowed piece is the loader-provided GOP
    metadata, not a running driver. The floor still costs us mode
    setting, page flip, vblank pacing, resolution control, and a blit
    (copyin) per present instead of a scanout retarget. The floor is
    kept; its consumption moves fully under Awase long term.

  - drm-kmod is a large Linux-code dependency: the DRM subsystem and
    a vendor KMS driver (i915, amdgpu) ported from Linux, the single
    biggest Linux-derived component in the Awase graphics stack.
    Making the default path not need it is the principled core of
    AD-4 and what aligns AD-4 with the project's BSD-native, anti-
    Linux-pattern discipline. It is retained as the compatibility
    tier, not removed.

## First-vendor target (open decision, Phase 0)

The program is single-vendor first, then widened. The first target
is not yet chosen, and the choice is a real trade:

  - The simplest, best-documented display engine on a bench machine
    is the right place to learn to drive real hardware end to end
    with the least vendor archaeology. Intel Gen7 (Bay Trail, the
    1024x768 bench machine) has a comparatively simple, well-
    documented display path (pipe, plane, port, GMBUS for EDID).

  - The iMac (3840x2160, the primary bare-metal target) is the
    machine that matters operationally, but a modern GPU display
    block (AMD DCN or a later Intel generation, to be confirmed)
    plus Apple firmware is materially harder, and that firmware is
    already known to be idiosyncratic (the EFI poweroff behavior
    found while closing the pgsd-sessiond shutdown question).

Phase 0 task 1: determine the exact display hardware on each bench
machine (`pciconf -lv vgapci0` and the EDID), then commit the first
target in an ADR. Likely recommendation: prototype the full native
stack on the simpler Intel display block first, add the iMac's GPU
as the second target, so the operationally-important machine is not
also the teaching machine.

## Phased plan

Each phase is observation-first: read and verify before any write,
per project discipline. The drm and efifb tiers remain the reachable
fallback at every phase; a loader knob must always return the
machine to efifb (see Risks). Phases 1 through 3 stand up a native
display engine; Phases 4 and 5 carry the ownership model into memory
and the engine, the broad scope.

Phase 0: floor, tiers, target.
  - Keep efifb as the permanent floor; keep drm as the compat tier;
    document the GOP framebuffer parameters drawfs consumes today so
    the native path reproduces them.
  - Add the `native` backend value and the native/drm/efifb
    selection order (ADR).
  - Determine display hardware on both bench machines; commit the
    first-vendor target (ADR).

Phase 1: native display engine, read-only then scanout.
  - 1a: a newbus driver claims the target vgapci device and maps its
    BARs. Read-only: enumerate display controllers, read the
    firmware-set mode, read EDID. Verify the read mode against the
    known GOP mode. No register writes.
  - 1b: scanout retarget. Point the primary display plane at a
    Awase-owned scanout buffer (the composited frame), keeping the
    firmware's mode. Replaces the per-present efifb blit with a
    direct scanout address owned by Awase.
  - 1c: page flip and vblank. Double-buffered flips synchronized to
    vblank, one flip per SURFACE_PRESENT, mirroring the drm path's
    MODE_PAGE_FLIP. The tearing and latency win.

Phase 2: native mode setting.
  - Program the CRTC, PLL, and encoder from EDID-derived timings to
    set arbitrary modes, not only the firmware's. Vendor-deep (Intel
    DDI and transcoder, or AMD atombios and DCN). Enables resolution
    control and mode changes.

Phase 3: memory and multiple displays.
  - GPU-visible buffer placement for scanout (GTT/VRAM per the
    vendor), hotplug detection, multiple connectors and CRTCs.

Phase 4: GPU memory management (broad scope).
  - A native memory manager for GPU-visible allocations beyond
    scanout (the BSD-native equivalent of what GEM/TTM provide),
    sufficient to back command buffers and engine resources.

Phase 5: command submission and the render engine (broad scope).
  - Native ring/command submission and the vendor render engine,
    enabling GPU-accelerated composition and blit so composition can
    move off the CPU. This is the deepest, longest phase and the
    full expression of the ownership model. It remains per vendor.

CPU-side composition (the swap backend's model) is the baseline
through Phase 3 and stays valid as a fallback even after Phase 5;
acceleration is an addition, not a precondition for output.

## Long term: Awase owns the floor

The floor tier is kept forever, but the borrowed parts of it are not.
The vt(4) and efifb bootstrap deprecation this depends on is already
substantially done: AD-39 compiled vt(4) and vt_efifb out of the PGSD
kernel (2026-05-13/14), superseding AD-10 and its ADR 0001 loader.conf
mechanism, and there is no separate efifb driver in FreeBSD distinct
from vt_efifb. So on a PGSD kernel there is no FreeBSD console-on-
framebuffer driver between Awase and the GOP today.

What remains borrowed is the loader-provided GOP framebuffer handoff:
drawfs consumes the EFI framebuffer the loader set up and passed in
boot metadata. Long term Awase provides its own framebuffer that obtains
and manages the GOP directly rather than through the loader-provided
metadata, completing the ownership model at the lowest output layer.
The one piece that stays firmware's is the GOP handoff itself; Awase
owning the floor means Awase consumes that handoff through its own
framebuffer, and via native mode setting (Phase 2) can reprogram the
display beyond the firmware's chosen mode.

This also bears on the early-boot window, and must respect AD-11. On a
PGSD kernel, kernel messages before drawfs.ko loads have no on-screen
destination (they reach dmesg and any serial console); per AD-11, Awase
replaces the user-facing console, not the kernel's own diagnostic
channel, and does not commit to kernel-side panic rendering. Awase owning
the floor may bring Awase's framebuffer up earlier in boot, but it does
not displace the kernel's diagnostic output channel or AD-11's recovery
posture.

This is a structural change to the boot path, gated on the deprecation
already largely delivered by AD-39 and coordinated with AD-11's console
and recovery design. It is not part of the first scheduled phases.

## Decisions that become ADRs

  - the tiered output model: `hw.drawfs.backend` gains `native`, and
    the native/drm/efifb selection order and operator pinning are
    fixed. efifb floor and drm compat tier are retained; relationship
    to ADR 0001 (drawfs owns the framebuffer at boot) restated for
    the native path.
  - first-vendor target selection and rationale (Phase 0).
  - native path versus the swap compositor: native is a scanout (and
    later an acceleration) transport; swap is the composition store;
    they compose, they are not exclusive.
  - kernel layout: whether the native driver lives inside drawfs or
    as a separate kmod drawfs talks to. A separate kmod is the likely
    choice so drawfs stays vendor-agnostic and the native driver is
    developed and loaded independently.
  - mode-setting approach for the chosen vendor (Phase 2).
  - GPU memory model (Phase 4) and command-submission model
    (Phase 5), each per vendor.
  - long term: Awase's own framebuffer obtaining the GOP directly (the
    loader-provided GOP metadata being the last borrowed piece; the
    vt(4) and efifb kernel deprecation already delivered by AD-39),
    coordinated with AD-11's console and recovery posture.

## Relationship to existing work

  - DF-6 (drm path) is not wasted. It becomes the compatibility tier
    and the reference the native path is validated against on capable
    hardware (same machine, same frames, drm versus native).
  - efifb (swap backend) is the floor and recovery path.
  - AD-3/F.3.f (HDMI audio) is downstream of display capability and
    is unaffected by AD-4's choice of output path.

## Risks

  - This is a real GPU program, broad by intent. Display-only is
    already vendor-specific and often under-documented (modern AMD
    DCN especially); the engine phases are harder still. drm-kmod
    exists because this is hard. AD-4 accepts the cost for the
    ownership it buys, and bounds risk by phasing: each phase ships a
    working output path, and the external tiers stay available.
  - Black-screen failure is the standing hazard. Every phase keeps a
    loader-settable path back to efifb (and a text console per ADR
    0001's recovery analysis). No native path ships without its
    fallback proven first; the drm and efifb tiers are that fallback.
  - The iMac's firmware is idiosyncratic; choosing it as the first
    teaching target compounds GPU difficulty with firmware
    difficulty. Phase 0 should weigh the simpler Intel target first.
  - Scope is broad by decision, so the discipline is sequencing, not
    exclusion: no engine work (Phases 4 to 5) begins before the
    display engine (Phases 1 to 3) is solid on the first vendor, and
    no second vendor begins before the first is complete enough to
    generalize from.

## Status of this document

Draft for operator review. When ratified, the AD-4 BACKLOG entry
should point here and drop its "No design document exists yet" line.
No phase is scheduled; Phase 0 (determine hardware, add the native
tier, choose the first target) is the only step that can begin
without committing the full program.
