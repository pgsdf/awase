# Awase boot-path ownership

Status: RATIFIED 2026-06-21 (operator), with the Objective amendment
below: the goal is an Awase-native boot contract, not permanent
reproduction of FreeBSD's boot ABI. Compatibility is the bridge, not the
destination. Phase 0 and Phase 0.5 may begin; Phases 2 and 3 are
scheduled as a program. Each named decision still becomes its own ADR
before its code.

## Purpose

Awase replaces FreeBSD's boot loader and its menu entirely: the boot
experience the firmware hands control to, the framebuffer that
experience runs on, and the loader engine that parses the kernel and
hands it off, all become Awase's. This is the boot-side counterpart to
AD-4's "Awase owns the floor": AD-4 stops drawfs consuming the
loader-provided GOP metadata at the output layer; this program replaces
the loader that provides it.

Operator decision (2026-06-21): the Awase loader is written FRESH, not
forked from FreeBSD's loader.efi, to design the kernel handoff, the
framebuffer ownership, and the boot UI around Awase's model rather than
inherit FreeBSD's structure.

## Objective (ratified amendment, 2026-06-21)

The objective is NOT permanent reproduction of FreeBSD's boot ABI. It is
boot compatibility sufficient to establish an Awase-native boot contract
under the joint control of the Awase loader and the PGSD kernel.

This distinction matters because Awase owns both sides of the boundary.
FreeBSD's loader must reproduce the kernel ABI because the kernel is not
its to change; Awase is under no such obligation past the bridge.
Compatibility is a bootstrap technique, not the destination. The
strategy is the standard one in operating-system development:

  1. Document the current ABI.
  2. Implement compatibility (cross the bridge: boot the existing PGSD
     kernel unchanged).
  3. MEASURE what the kernel actually consumes (Phase 0.5
     instrumentation), not what the loader emits.
  4. Define an Awase-native boot contract: the smallest, clearest
     contract Awase actually requires, owned by both loader and kernel.
  5. Remove the compatibility layers over time, on Awase's schedule.

This preserves the phased risk containment below while pursuing Awase's
architectural goal of reducing inherited complexity rather than
reimplementing it forever. The reverse-engineered ABI is the bridge,
measured down to its load-bearing subset and then replaced, not a
contract reproduced indefinitely.

### Architectural coherence (why fresh, as principle not preference)

AD-4 says Awase owns the floor. A fresh loader extends that principle
backward into the boot path: the display belongs to Awase from power-on
to shutdown, with no ownership transitions that exist solely because of
historical FreeBSD architecture. The coherent ownership story:

  - fresh loader owns the boot UI,
  - Awase owns framebuffer policy,
  - drawfs owns presentation,
  - PGSD owns kernel execution,
  - recovery is an Awase-defined path, not a FreeBSD-defined one.

Fresh-over-fork is therefore a principle that falls out of AD-4 extended
backward, not a preference.

## What is being replaced, in three separable layers

FreeBSD's loader.efi bundles three jobs that this program peels apart
from the outside in, in increasing order of risk:

  1. The menu UI. The beastie/ASCII menu and countdown are Lua scripts
     under /boot/lua (menu.lua, loader.lua). Pure userland script,
     fully reversible, no effect on bootability.
  2. The presentation and framebuffer setup. The loader brings up the
     GOP framebuffer and passes its parameters to the kernel in boot
     metadata; the menu renders on that framebuffer. This is the seam
     AD-4 cares about: the GOP parameters drawfs later consumes
     originate here.
  3. The loader engine and kernel handoff. loader.efi parses the
     kernel and modules, builds the bootinfo / modinfo metadata blob,
     the memory map handoff, and the EFI system-table pointer the
     kernel reads on entry, then transfers control. Replacing this is
     replacing the loader itself.

The ordering is forced by risk, not preference. A wrong menu is
harmless. A wrong kernel handoff is an unbootable bench.

## The fresh-loader decision relocates the risk; the doc must say so

Writing fresh (rather than forking loader.efi) moves the single hardest
and most dangerous piece of the program squarely onto us: the kernel
entry ABI. loader.efi does not merely load a kernel file. It builds a
specific set of structures the PGSD kernel reads on entry:

  - the bootinfo / modinfo metadata blob (kernel path, the module list
    with each module's type, load address, and size, the kernel
    environment, and the GOP framebuffer parameters),
  - the UEFI memory map handoff,
  - the EFI system-table pointer,

laid out exactly where the kernel's early init expects them. This ABI
lives in the FreeBSD/PGSD kernel source, is not published as a stable
contract, and can shift across kernel rebuilds. A wrong field does not
produce a clean error; it produces a kernel that panics in early init
or probes wrong and wedges, on a bench that then will not boot.

A forked loader would have inherited this handoff proven. Fresh means
we reimplement it against an undocumented, version-coupled target. The
program is structured around containing exactly that risk.

Note (per the Objective): reimplementing the ABI is the bridge, not the
destination. Phase 0.5 measures the handoff down to the subset the
kernel actually consumes, and the Awase-native contract (owned by both
loader and kernel, since Awase controls both) replaces the reproduced
ABI over time. The risk described here is the risk of the FIRST bootable
prototype crossing the bridge; it shrinks as the contract becomes
Awase's own and is measured rather than inherited.

## Non-negotiable floor: the stock-loader fallback entry

The analog of AD-4's "a loader knob must always return the machine to
efifb." Before any fresh-loader code runs on a bench, a second UEFI
boot entry that always boots stock FreeBSD loader.efi must exist and be
verified, so every experiment can be abandoned by selecting the
fallback entry in firmware. With a fresh loader this is not convenience
infrastructure; it is the thing standing between an experiment and a
bricked bench. No fresh-loader phase begins until the fallback entry is
proven to boot the bench independently.

## Constraints inherited from AD-11 (console and recovery)

AD-11 places a recovery trigger in the loader: the loader or early rc.d
stage detects Alt held at bootstrap and selects a recovery profile
(minimal services, recovery tools on PATH, defaulting to a root
recovery session rendered through the normal Awase substrate, not a
separate console layer). The Awase loader therefore inherits, as a
first-class responsibility:

  - Alt-held-at-bootstrap detection and the recovery-profile handoff
    signal to rc.d (AD-11 path 2),
  - cooperation with the auto-recovery marker mechanism (AD-11 path 3),

and is bounded by what AD-11 deliberately scopes out:

  - it does NOT take over the kernel's own diagnostic output channel.
    Kernel messages before drawfs.ko loads reach dmesg and any serial
    console; the loader does not displace that. Per AD-4 and AD-11,
    Awase replaces the user-facing console, not the kernel diagnostic
    channel, and does not commit to kernel-side panic rendering.

A fresh loader may bring an Awase framebuffer up earlier in boot, but
it must preserve the kernel diagnostic channel and AD-11's recovery
posture.

## Trust model and secure boot (decide early; it is a term of the contract)

Secure boot is not a feature bolted onto a finished loader. It is a
property of the boot contract itself, so it must be decided before the
Awase-native contract is defined, even though implementation is far
away. Once Awase replaces FreeBSD's loader chain, these become terms of
the contract, not downstream details:

  - Does the Awase loader verify the kernel?
  - Does the kernel verify modules?
  - Is secure boot required, optional, or unsupported?
  - Is recovery allowed when signature verification fails?

The last question is the sharp one, and it is coupled to Phase 0 exit
criterion 5 (return to a known-good state without external media): a
verification model that bricks the bench on a failed signature violates
criterion 5 directly. Secure boot and the recovery guarantee are the
same question viewed from two sides, and that coupling lives in Phase 0,
not Phase 3. Note also that FreeBSD's documented secure-boot path
combines loader and kernel into a single signed object because there is
no cryptographic handshake between boot1.efi, loader.efi, and the kernel
today; a fresh Awase loader is free to define a different handshake, but
must define one deliberately.

Therefore the secure-boot / trust-model ADR is scheduled EARLY: decided
before the Awase-native boot contract is defined (it constrains the
contract's shape), and reconciled with the Phase 0 recovery posture (it
constrains what "recoverable" is allowed to mean). It is decided early
and implemented late.

## Phase plan (observation first, fallback always reachable)

Phase 0: observation, the escape hatch, and recovery. No fresh-loader
code.
  - Document the bench's exact current boot chain: efibootmgr entries,
    ESP contents, whether /boot is Lua or Forth, loader.conf state.
  - Establish and verify the stock-loader fallback UEFI boot entry.
  - Document the PGSD kernel entry ABI from the kernel source as a
    written contract: the modinfo layout, the metadata types, the
    memory-map and system-table handoff, and the GOP-parameter fields
    drawfs depends on. This is the bridge specification (step 1 of the
    Objective), to be measured down to its load-bearing subset in Phase
    0.5, not a contract reproduced indefinitely.
  - Document AND TEST the recovery procedure: how a bench is returned to
    a known-good boot state after a failed experiment, without external
    media.

  Phase 0 EXIT CRITERIA (hard gates; all five required before Phase
  0.5 or any later phase begins):
    1. Permanent fallback boot entry verified on real hardware.
    2. Boot-chain document produced.
    3. Kernel-entry ABI documented from source.
    4. Recovery procedure documented and tested (not just designed).
    5. A bench can always be returned to a known-good state without
       external media.
  Criterion 5 is the one that makes a loader project not scary: every
  experiment has a documented, tested recovery path that needs no USB
  stick and no physical trip to the bench. A fallback that requires
  external media or hands-on access is not a fallback you can lean on
  during rapid iteration.

Phase 0.5: ABI instrumentation. Measure, do not assume. No fresh-loader
code yet; this instruments the EXISTING path.
  - Modify the PGSD kernel to log exactly what boot metadata it
    receives from the loader and which fields early initialization
    actually consumes (parsed-and-used versus present-but-dead).
  - This is the bench-as-authority step for the ABI: the Phase 0
    contract is what the source appears to consume; this produces what
    the kernel actually consumes. Source-reading infers; instrumentation
    measures. The difference is exactly the kind of parsed-but-never-used
    field that a fresh loader would otherwise reproduce for no reason.
  - Expected outcome (to be confirmed, not assumed): the kernel consumes
    a small subset of the metadata loader.efi generates. If so, the
    fresh loader and the eventual Awase-native boot contract are
    substantially simpler than a faithful reproduction would be. The
    measured subset is the input to the Awase-native contract (step 4
    of the Objective).

Phase 1: own the menu (Scope 1), inside stock loader.efi.
  - Replace /boot/lua/menu.lua (or disable beastie and substitute) with
    an Awase boot UI. Pure script, reversible, bench-testable in
    minutes. Builds the Awase boot UI against a known-good handoff.

Phase 2: own the presentation and framebuffer (Scope 2), still inside
stock loader.efi.
  - Own the boot UI's framebuffer setup and presentation while the
    loader engine and kernel handoff stay stock and proven. This is the
    AD-4 seam; the Awase presentation here is the front end to "Awase
    owns the floor." Still no fresh handoff, so a boot failure can only
    be the presentation, not the handoff.

Phase 3: the fresh Awase loader (Scope 3). The dangerous phase, split
so the handoff is proven before anything is built on it.
  - 3a: minimal handoff. A fresh EFI loader the firmware loads directly
    that hands off to the kernel with a MINIMAL metadata blob (kernel
    plus the few mandatory modules) and reaches init on real hardware.
    Boot-to-init is the gate. No UI, no direct-GOP ownership yet.
  - 3b: full module loading and the kernel environment, matching the
    documented ABI from Phase 0.
  - 3c: fold in the Phase 1/2 Awase boot UI (already proven against
    stock loader), now running on the fresh loader.
  - 3d: Awase-native display contract. Replace the compatibility GOP
    handoff with an Awase-native display contract jointly owned by the
    Awase loader and the PGSD kernel. By this phase the loader is
    Awase, so there is no foreign "loader-provided metadata" left to
    replace; what changes is that the compatibility ABI disappears and
    the loader and kernel share a contract Awase defines on both ends.
    This closes AD-4's "owns the floor" at the boot layer; native mode
    setting per AD-4 Phase 2 can then reprogram beyond the firmware
    mode.
  - 3e: AD-11 recovery integration (Alt-held detection, recovery-profile
    signal, auto-recovery marker), preserving the kernel diagnostic
    channel.

Build the UI fresh and the handoff fresh in separate phases, never
simultaneously: if both were new at once, a boot failure could be
either, the ambiguity that must be avoided on an unbootable-bench risk.

## Decisions that each become an ADR

  - the kernel entry ABI bridge (Phase 0 output): the modinfo layout,
    metadata types, memory-map and system-table handoff, GOP fields,
    as the compatibility bridge to cross first, and how it is kept in
    sync across PGSD kernel rebuilds while the bridge stands.
  - the Awase-native boot contract (Phase 0.5 + Phase 3 output): the
    smallest contract the kernel actually consumes (measured, not
    assumed), owned jointly by the Awase loader and the PGSD kernel,
    and the schedule for removing the compatibility layers. This is the
    destination; the ABI bridge above is discarded as this lands.
  - the trust model / secure boot ADR (SCHEDULED EARLY, see the trust
    model section): whether the loader verifies the kernel, the kernel
    verifies modules, secure boot is required/optional/unsupported, and
    whether recovery is allowed on verification failure. These are terms
    of the boot contract, not downstream details, so this ADR is decided
    before the Awase-native contract is defined and reconciled with the
    Phase 0 recovery posture. Decided early, implemented late.
  - recovery and the permanent stock-loader fallback entry: how it is
    provisioned, kept, and guaranteed bootable across updates.
  - the component's build: the loader lives in the pgsd-boot/ top-level
    component (named pgsd-boot, not boot, to avoid colliding with
    FreeBSD's runtime /boot and /usr/src/stand; see pgsd-boot/README.md
    for the naming rationale). How it builds against the SDK toolchain
    and how it is installed to the ESP remain to be decided.
  - the AD-4 boundary (the GOP handoff) and the AD-11 boundary (console
    and recovery posture), restated as this program crosses them.

## Relationship to existing work

  - AD-4 (native output): this program replaces the loader that
    provides the GOP metadata AD-4 wants to stop consuming. Phase 3d
    (direct GOP ownership) is the boot-layer completion of AD-4's
    "Awase owns the floor." The two converge at the GOP handoff.
  - AD-39: already compiled vt(4) and vt_efifb out of the PGSD kernel,
    so there is no FreeBSD console-on-framebuffer driver in the way.
    This program addresses the loader, which sits above the kernel and
    is unaffected by AD-39; AD-39 cleared the kernel-side console, this
    clears the boot-side loader.
  - AD-11 (console and recovery): the Awase loader inherits AD-11's
    Alt-held recovery trigger and auto-recovery marker cooperation, and
    is bounded by AD-11's decision not to own kernel-side panic
    rendering or the kernel diagnostic channel.

## What this program is, in one line

Establish end-to-end Awase ownership of the machine from firmware
handoff to graphical session, while preserving a measured and
recoverable migration path. Not "replace loader.efi"; that is the first
visible step, not the objective.

## What can begin now without scheduling the whole program

Phase 0 (observation, the fallback entry, the kernel-ABI bridge
document, and a tested recovery path), Phase 0.5 (kernel ABI
instrumentation: measure what early init actually consumes), and Phase 1
(own the menu inside stock loader.efi). Phase 1 delivers an Awase boot
screen with zero bootability risk; Phase 0 produces the bridge document
and, via its five exit criteria, the no-external-media recovery
guarantee; Phase 0.5 turns the bridge from an assumption into a measured
fact and likely shrinks the fresh loader's scope. Phases 2 and 3 are
scheduled as a program. None of Phase 0.5 or later begins until the five
Phase 0 exit criteria are met.
