# PGSD boot

This directory will hold the fresh Awase boot loader: the EFI program
that PGSD's firmware loads to boot the PGSD kernel. It is the boot-side
component of the AD-56 boot-path ownership program, replacing FreeBSD's
loader.efi and its menu entirely.

No loader code lives here yet. The program is in Phase 0 (observation and
recovery posture, complete as revised); loader code begins at Phase 1
(own the menu inside stock loader.efi) and Phase 3 (the fresh loader).
This README and the design documents are the component's current
contents.

## What this component is

A fresh EFI loader, written rather than forked, that:
  - owns the boot UI (replacing FreeBSD's beastie/Lua menu),
  - establishes the GOP framebuffer and the display contract the Awase
    substrate (drawfs) inherits once the kernel is up,
  - parses the PGSD kernel and modules and builds the kernel-entry
    handoff (the preload metadata blob, the EFI memory map, the GOP
    record),
  - carries AD-11's Alt-held recovery trigger,
  - leaves the kernel's own diagnostic channel alone (per AD-11).

The loader boots the PGSD kernel and hands a display contract to Awase.
That dual role is why the directory is named neutrally (see below).

## Naming

The directory is `pgsd-boot`, not `boot`, `awase-boot`, or `ignition`.
The reasons, recorded so the choice is not relitigated:

  - `boot` collides with FreeBSD's runtime `/boot` directory and with
    `/usr/src/stand` (the established "boot source"). A source directory
    one character from the live runtime path invites source-vs-runtime
    confusion, and the install path's whole job is copying toward
    `/boot`.
  - `ignition` collides with CoreOS Ignition, a well-known first-boot
    provisioning tool in exactly this domain, and breaks the project's
    descriptive (not evocative) naming convention.
  - `pgsd-boot` is collision-free, matches the `pgsd-` distribution
    component family (the natural sibling of `pgsd-kernel`: the two
    halves of how PGSD starts), and is descriptive. It commits to the
    PGSD/distribution framing, which is accurate: the loader's core job
    is the PGSD kernel handoff, with Awase display ownership a feature it
    provides, not its identity.

## Design documents

The program and its decisions live in `docs/design/`:
  - `BOOT-PATH-OWNERSHIP.md`: the ratified program (objective, fresh-
    loader decision, phases, trust model, AD-11/AD-4 boundaries).
  - `AD56-PHASE0-PLAN.md`: Phase 0 (observation, recovery posture,
    the boot-chain document, the five exit criteria as revised for
    Apple firmware).
  - `AD56-ABI-BRIDGE.md`: the kernel-entry ABI documented from source
    (the compatibility bridge to cross first).
  - `AD56-PHASE05-INSTRUMENTATION.md`: the observation-and-reduction
    design that measures the load-bearing subset of the bridge.

The boot-chain survey tool is `scripts/boot-chain-survey.sh`.

## Status

Tracked as AD-56 in BACKLOG.md. Phase 0 complete as revised; Phase 0.5
(ABI measurement) designed and awaiting ratification; loader code (Phase
1 onward) not yet begun.
