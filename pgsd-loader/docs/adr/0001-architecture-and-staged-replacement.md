# 0001: pgsd-loader architecture and staged replacement

## Status

Proposed, 2026-07-07. Parent architecture ADR for the pgsd-loader
subproject. Stage ADRs (Decision 3) are drafted and ratified
beneath it individually; this document does not close until stage
L5 closes or it is explicitly superseded.

## Context

PGSD currently boots through FreeBSD's stock loader.efi with lua
shims in pgsd-boot/. Three pressures motivate replacing it with a
loader the project owns:

First, the environment decision point. The AD-59 three-environment
model (OE/RE/ME) resolves which environment a boot enters at or
before the loader menu. Producer #1 (operator recovery request)
already lives at the loader boundary because kenv is loader-set,
and producer #2's establishment event needs a home at the earliest
component with enough context to make the decision. Today that
component is stock loader.efi driven by lua shims: the policy the
project cares most about is implemented in a layer it does not
control, in a language and config surface it inherited rather than
chose. Owning the loader keeps environment selection explicit and
keeps the policy outside the kernel.

Second, capability. Per-environment audio cues (deferred from
audiofs ADR 0032 Decision 5) are only implementable where the
environment decision is made, and a Recovery entry may never bring
up the s6 tree, so the rc.d mechanism cannot serve RE. Loader
audio requires a loader the project can extend.

Third, operational fragility. The stale-adapter boot loss that
deploy-loader.sh papers over is a symptom of deploying artifacts
into a boot path the project does not own end to end. A loader
that is a project artifact makes the deployment and recovery model
a designed thing rather than an accumulation of fixes.

The goal is a from-scratch Zig EFI application (the x86_64-uefi
target is first-class in the pinned toolchain; std.os.uefi covers
boot services). From-scratch means loader.conf and lua semantics
are a choice, not an inheritance. But loader.efi reproduces
contracts accumulated over many years, kernel handoff above all,
and a single-step replacement would gamble the machine's
bootability on getting all of them right at once. The replacement
must therefore be slow: staged, with each stage independently
verified on the bench and each stage leaving a trivial path back
to a known-good boot. The precedent is the project's own practice:
the R1-R4 rename plan, the AD-59 producer sequencing, and the
shared ADR 0004 migration all advanced through stages that were
individually ratifiable and individually reversible.

## Decisions

### 1. Subproject: pgsd-loader, owning its own ADR series

pgsd-loader/ is a subproject with its own docs/adr, following the
per-subproject ADR convention. It is the designated successor to
pgsd-boot/: the lua shims are absorbed or retired stage by stage,
and pgsd-boot closes when its last shim does. deploy-loader.sh
migrates into this subproject's scope, since deployment and
recovery of boot artifacts is loader territory.

### 2. Mechanism of coexistence: chainloading

UEFI's LoadImage/StartImage makes chainloading the seam. From L0
onward, pgsd-loader is the default boot entry and chainloads stock
loader.efi for every responsibility it has not yet absorbed. Each
stage moves one responsibility from the chainloaded side to the
owned side. The stock loader is retired only at L5, after the
owned loader has carried every responsibility through enough cold
boots that the bench record is boring.

Rationale. Chainloading gives incremental replacement for nearly
free and makes every intermediate state a working boot. The
alternative seams (patching stock loader, forking it) are rejected
below.

### 3. Milestones L0 through L5, as contracts rather than tasks

Each milestone is an architectural contract: a single
responsibility absorbed, an objective success criterion, a trivial
rollback. Each gets its own ADR before its code, ratified
independently. The definitions here bind scope; the stage ADRs
bind design.

- L0, presence and chainload. A Zig EFI application that prints a
  banner and chainloads loader.efi unchanged. What it proves is
  not loader function but the deployment and recovery model: the
  vendored-toolchain build path for the uefi target, the ESP
  deployment step, and the fallback entry discipline (Decision 4).
  Closure: boot through the shim is indistinguishable from boot
  without it; removing the shim's boot entry recovers via the
  fallback entry.

- L1, environment selection. The shim owns the OE/RE/ME decision
  per the AD-59 establishment-event design and communicates the
  choice to the still-stock loader through a small ESP file or
  UEFI variable, which a minimal lua shim turns into kenv. The
  policy the project cares most about moves into owned code first,
  while kernel handoff stays on proven code. AD-59 producer #2
  architecture should assume L1 exists so the authority contract
  is designed once, at its final home.

- L2, loader audio. A boot-services HDA path: controller via
  EFI_PCI_IO_PROTOCOL, immediate commands or minimal CORB/RIRB,
  the CS4206 initialization the bench work already established,
  one output stream, clean teardown before handoff. Environment
  cues (ADR 0032 Decision 5 deferral) land here, assets embedded
  from gen-boot-tone output at build time. L2 depends only on boot
  services and PCI access, blocks nothing downstream, and remains
  optional on hardware where it proves difficult. Its ADR must
  also rule on the interaction with the ADR 0032 substrate probe:
  a loader that warms the codec changes the cold-boot initial
  conditions the D0/GPIO bench baselines assumed, so those
  baselines are re-established with loader audio on and off.

- L3, kernel handoff. The cliff: kernel and module loading, the
  MODINFO metadata chain and kenv the FreeBSD kernel expects,
  memory map handoff through ExitBootServices, entry trampoline.
  L3 is subdivided by its own ADRs and is where design effort
  concentrates before code; the kernel-source decision (Decision
  5) gates it. One dependency is recorded now so no stage strands
  it: drawfs is preloaded via loader.conf today, so L3 either
  preloads it or an ADR moves drawfs to early rc before L3 lands.

- L4, cutover. pgsd-loader boots the kernel directly by default;
  stock loader.efi is demoted to the fallback entry.

- L5, retirement. Stock loader.efi and the remaining lua shims
  are removed after a bench-ratified soak. Closes this ADR.

### 4. The fallback invariant

Every stage preserves a known-good boot entry pointing directly at
stock loader.efi, untouched, until L5 removes it deliberately. No
stage modifies stock loader.efi. Deployment tooling maintains the
fallback entry as part of every deploy, and a stage's closure
criteria always include demonstrating recovery through it. This is
the invariant that makes every later experiment safe; it is not
tunable per stage.

Rationale. The stale-adapter lesson: boot-path deployment failures
are discovered at the worst possible time. The invariant converts
"the machine no longer boots" from a possible experiment outcome
into a bounded inconvenience.

### 5. Kernel-source architecture is a gated, deferred decision

Where L3 reads the kernel from is a long-term architecture choice,
not an implementation shortcut, and is deferred to a dedicated
evaluation ADR that must be ratified before L3 design begins. That
ADR evaluates at minimum:

1. Kernel on the ESP (UEFI-native FAT reads; no filesystem driver
   in the loader; deterministic reads; simplest implementation).
2. Kernel on UFS/ZFS (loader filesystem support; the root
   filesystem remains the single authority).
3. The criteria that pick the long-term architecture, including:
   how kernel updates stay synchronized between ESP and root
   filesystem; whether the ESP is a deployment artifact or an
   authoritative source; how signed kernels and a future
   secure-boot posture fit; and whether install.sh already has a
   reliable synchronization mechanism to build on.

The outcome of that ADR determines whether L3 is one stage or
several.

### 6. Bench as sole authority, per stage

Stage ADRs carry the closure criteria; cold-boot counts and
recovery demonstrations are bench-verified on bare metal before a
stage is marked closed. No stage closes on emulation results
alone, though emulation (qemu with OVMF) is encouraged for
iteration speed.

## Alternatives rejected

- Fork FreeBSD's loader. Inherits the C codebase, the lua config
  surface, and the accumulated contracts wholesale; the project
  would own the maintenance without owning the design, and the
  explicit goal of choosing rather than inheriting the config
  surface is lost.
- Big-bang replacement. No intermediate working states, no
  fallback, unbounded risk concentrated at a single cutover; the
  opposite of every discipline this project runs on.
- Remain on loader.efi indefinitely. Leaves the environment
  decision point in lua shims the project does not want to grow,
  makes RE audio cues unimplementable, and leaves the deploy
  fragility class open.
- Patch or wrap stock loader.efi in place. Violates the fallback
  invariant by construction: the known-good path must remain
  untouched.

## Closure criteria

This is an architecture ADR; it closes at L5. Interim health is
measured by its stages: each of L0 through L5 ratified, benched,
and closed under its own ADR, in order, with the fallback
invariant demonstrated at every stage. Any stage finding that
invalidates a decision here reopens this document for revision
rather than being absorbed silently.

## References

- AD-59 bootstrap pipeline: producer #1 (kenv operator recovery
  request, hardware-validated through Experiment 9), producer #2
  (Recovery binding, under design), the OE/RE/ME model, and
  AD59-PART3-BOOTSTRAP-EXPERIMENTS.md.
- audiofs ADR 0032: boot initialization chime; Decision 5 defers
  per-environment cues to the loader layer; the substrate probe
  it defines is unchanged by this ADR.
- pgsd-boot/: the lua shims and deploy-loader.sh this subproject
  absorbs and retires.
- RENAME-PLAN.md (R1-R4) and shared ADR 0004: the staged,
  reversible migration precedents this strategy mirrors.

## Revision history

- Revision 1, 2026-07-07: initial proposal. Milestone structure
  and the reversed drafting order (parent architecture before L0)
  per operator direction; kernel-source evaluation criteria
  per operator input.
