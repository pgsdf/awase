# UTF Architectural Discipline

Status: Stated, 2026-04-23

This document states the discipline that governs what code UTF depends on
and what code UTF writes. It is the principle behind decisions that were
previously unwritten: why drawfs exists instead of Xlib, why
audiofs and semasound exist instead of PulseAudio over OSS, why
inputfs was built instead of
continuing to use evdev.

The principle is stated once, with its rationale and its accepted
limits. Every subsystem's design document should cite this discipline
and derive specific choices from it rather than re-deriving the
underlying reasoning.

## The principle

> **UTF depends only on code written with UTF's guarantees in mind.
> Everything else is either replaced or explicitly accepted as a named
> platform-transport dependency.**

## Why

UTF's central commitments are **determinism and stability**. A recording
made today should replay identically tomorrow. A session that worked on
Monday should work on Monday-next-year without the user adjusting to
behavioural drift in something underneath them.

These are not soft goals. They shape the entire architecture: the
audio-driven clock, the kernel-authoritative surface registry, the event
schema with sequence numbers, the published state regions. Each of these
was built to hold a specific determinism or stability guarantee.

A single dependency on code that does not share those commitments can
invalidate them all. A library that fixes a "bug" in its next release
changes what UTF does. A kernel module that adds a background thread
changes UTF's timing. A userspace daemon that buffers an event changes
UTF's sequencing. None of these are malicious; they are the normal
lifecycle of code written for other purposes. But they break UTF.

The discipline says: **if we want UTF's guarantees to hold, every layer
that contributes to those guarantees must be written with them in mind.**
External code, written by people with their own goals, constraints, and
future plans, is a risk whenever it sits inside the guarantee path.

## Governance independence: why ownership, not just correctness

The risk above is usually read as a correctness or stability risk:
external code might be buggy, might regress, might change its
semantics. That reading is incomplete and it understates the actual
argument. The deeper reason UTF owns its guarantee path is not that
external code might be wrong. It is that when external code has a gap
UTF needs closed, closing it is not under UTF's control.

A dependency on external code is also a dependency on the governance,
goals, priorities, and release cadence of the people who maintain it.
When UTF needs a feature, a fix, or a behaviour that a third-party
component does not provide, UTF has only three options under a
dependency: persuade the maintainers to add it (subordinating UTF's
timeline and objectives to their decision process and their goals),
carry an out-of-tree patch indefinitely (which is partial ownership
with none of the benefits and all of the maintenance), or do without
the feature (subordinating UTF's objectives to the dependency's
scope). All three put UTF's ability to meet its own objectives in
someone else's hands. Owning the component removes that: a gap
becomes a thing UTF closes, on UTF's schedule, against UTF's
requirements, with no external party's assent required.

This is why the default posture for guarantee-path code is Replace,
not Accept. Accept is correct only where the dependency is genuinely
not something UTF could need to change (the CPU, the kernel
boundary). Where UTF can foresee needing the component to do
something its maintainers may not prioritise, the correctness of the
dependency today is not the deciding factor. The deciding factor is
whether UTF can afford to have its objectives gated by another
project's governance.

### Worked precedent: inputfs and gesture support

This is not a hypothesis. UTF has already encountered exactly this
situation and the ownership posture is what resolved it.

UTF needed gesture recognition (n-click, multi-touch) in the input
path. The external `hms(4)` HID pointing-device driver UTF would
otherwise have depended on did not implement three-finger
swipe-and-select, and did not implement pinch. Users coming from
macOS had requested these features; over `hms(4)`'s lifetime they
were not added, and no action toward adding them was observed. UTF
removed its dependence on `hms(4)` for this path rather than wait
indefinitely on features that showed no sign of arriving. The
relevant fact is not that anyone refused; it is that a capability
UTF required was not going to be provided on any timeline UTF
controlled, and changing that was not within UTF's power.

Because UTF owned the input path through inputfs, this did not block
UTF. The gesture recogniser was written as UTF-owned code
(`semainput/libsemainput/libsemainput.zig`), shaped by UTF's needs
rather than constrained by what an external driver did or did not
implement. It was then verified end to end on real hardware: the
Phase 2.5 bare-metal walkthrough confirmed single / double / triple
click, the n_click count escalation, and shift / ctrl / shift+ctrl
modifier propagation, closing AD-2 (see `BACKLOG.md` AD-2 and
`semadraw/docs/PHASE_2_5_VERIFICATION_STATUS.md`). The capability UTF
needed exists, is owned, and is proven, specifically because UTF was
not waiting on anyone else's governance to deliver it.

This is the empirical grounding for the governance-independence
argument. It is not "ownership might help with hypothetical future
gaps." It is "ownership already overcame exactly this class of
problem once in this project, with a verified result." Future
decisions that invoke governance independence as a rationale
(for example the audio-stack ownership decision in
`audiofs/docs/adr/0006-snd4-replacement.md`) are applying a lesson
UTF has already paid for and proven, not betting on an untested
principle.

## How

Three possible postures toward any external component:

1. **Replace.** Write a UTF-owned equivalent. This is the path for
   everything inside the guarantee path. inputfs replaces evdev.
   drawfs replaces Xlib. audiofs and semasound replace OSS and
   PulseAudio. The replacement is shaped by UTF's needs, not by
   the predecessor's design.

2. **Accept as platform transport.** Some dependencies cannot be
   reasonably replaced (the CPU, the USB controller, the FreeBSD
   kernel itself). These are named explicitly as accepted. They are
   treated as the boundary UTF runs on, not as components UTF's
   guarantees extend through. UTF code does not rely on undocumented
   behaviour of accepted dependencies, and when an accepted
   dependency fails or changes, UTF's response is part of the design
   rather than a surprise.

3. **Remove.** Some external dependencies exist because they were
   convenient at the time UTF started and are not required by UTF's
   goals. When the discipline is applied, these disappear. The code
   that depends on them disappears with them.

Every external component in UTF falls into one of these three.
Nothing is left in the "we'll deal with it later" category without
an explicit note saying so.

## Accepted platform-transport dependencies

This list enumerates what UTF accepts as the platform it runs on. It
is intentionally minimal. Growth requires an ADR-level decision.

**Hardware layer**
- CPU, memory, motherboard
- PCI/USB controllers and their transport-level operation
- Display hardware (through framebuffer paths today; direct GPU
  programming is an open question, see §"In scope for review")
- Audio hardware (through OSS today; also an open question)
- Input hardware (through HID transport today; everything above
  transport is being replaced by inputfs; see
  `docs/UTF_USB_HID_BOUNDARY.md` for the boundary contract)

**FreeBSD kernel**
- Scheduler, memory manager, VM subsystem
- VFS and the filesystems that hold UTF's data
- Signal handling, process model, IPC primitives that UTF uses
  directly (shared memory, sockets, kqueue)
- USB stack above the controller (for HID transport; see
  `docs/UTF_USB_HID_BOUNDARY.md` for the eleven entry points
  inputfs depends on)

**Language and toolchain**
- Zig compiler and its code generation
- Zig standard library, with the caveat that UTF code at determinism
  boundaries verifies stdlib behaviour rather than assuming it; see
  `docs/UTF_ZIG_STDLIB_BOUNDARY.md` for the boundary contract and the
  `posix_safe` helper that mitigates the most concrete risk
  (`unexpectedErrno` panic on errnos outside the stdlib's known set)
- LLVM, the linker, libc (through Zig's use of them)

**Build and runtime machinery**
- `rc.d` scripts and service supervision
- `/var/run`, `/var/log`, `/etc` conventions
- Standard Unix tooling used in build and install scripts

Everything else in UTF is either written by the project or being
actively migrated toward being written by the project.

## In scope for review

These are subsystems or dependencies where the discipline has
implications we have not yet applied. They are listed here so the
discipline is honest about its current state; they are not a
schedule of work. The BACKLOG tracks what is actually scheduled.

**Input.** evdev, bsdinput, libinput: DISCHARGED. inputfs owns
the HID path; AD-2 closed 2026-05-17 and no UTF code path uses
evdev.

**Audio output.** OSS: DISCHARGED. audiofs owns the hardware
directly (class-matched PCI HDA, AD-3 Option A; the snd(4)
framework is removed from the PGSD kernel in full, 2026-05-21),
and semasound is the broker above it (F.5). The OSS-era
semaaud was retired under F.6 (ADR 0029, 2026-06-05). The
direct-hardware-driving path this paragraph used to describe
as future work is the shipped architecture, ADRs 0001-0029.

**Graphics output.** drawfs uses efifb (or DRM/KMS on capable
hardware) for display output. The framebuffer and modesetting
paths are not UTF-written. The replacement path would be direct
GPU programming, which is the largest dependency-replacement
UTF could undertake.

**Userspace classification.** Device classification moved into
the inputfs kernel module with Stage D (2026-04). Gesture
recognition moved into a libsemainput library with AD-2a
Phase 2 (2026-05); semadrawd hosts a single recogniser
instance per ADR 0017-rev2's recogniser-as-service decision.
semainputd was retired by the AD-2a Phase 3 deletion sweep
(2026-05-08).

**File persistence.** UTF runs on whatever filesystem the host
platform provides via VFS. The substrate uses POSIX file I/O,
`mmap` of regular files, and atomic rename within a directory;
nothing filesystem-specific. PGSD the distribution requires ZFS
for its own reasons (boot environments via `bectl(8)`, the Axiom
package manager, and `sysrebase`); UTF inherits ZFS as a runtime
dependency only when delivered as PGSD. See
`docs/UTF_STORAGE_DEPENDENCY.md` for the full layering.

## What the discipline does not mean

The discipline is not a purity test. Some edges of it require pragmatic
acceptance, and pragmatic acceptance is a valid answer.

**It does not mean rewriting everything.** Most of FreeBSD's kernel,
all of Zig's standard library, and the entire USB stack are accepted
as platform transport. The discipline is about the code *inside* the
guarantee path, not every line of code UTF touches.

**It does not mean hostility to external projects.** FreeBSD, Zig,
and the various libraries UTF does not use are fine projects pursuing
their own goals. UTF's discipline is about UTF's guarantees, not
about those projects' quality.

**It does not mean avoiding standards.** UTF uses POSIX socket APIs,
USB HID specifications, OSS audio conventions. Standards are
acceptable, they define stable interfaces. What is not acceptable
is depending on a particular implementation of a standard if that
implementation can change in ways that affect UTF's guarantees.

**It does not mean changes are free.** Each replacement is
substantial work. The discipline says UTF will do that work; it does
not say the work happens all at once. Pragmatic sequencing is part
of the discipline, not a departure from it.

**It does not mean UTF never ships.** At every moment, UTF should be
in a state where testing is possible and the current set of
replacements is working. The discipline governs direction, not
sprints.

## Cross-consumer-consistent input policy

Some input policy must be applied at exactly one point and produce
the same result for every consumer. Pointer smoothing is the
canonical example: per-consumer smoothing in clients would let
different applications disagree about cursor position, and that
disagreement would break surface-under-cursor routing inside the
substrate. The substrate's routing decision and the clients' visual
cursor would target different surfaces.

For policies of this kind, UTF accepts a small impurity in the
substrate/policy boundary. The policy is applied in the substrate
(kernel) using parameters published by userland into a
compositor-to-kernel shared region. The substrate does not choose
the policy; it applies the policy userland chose. ADR 0015
(`inputfs/docs/adr/0015-per-user-pointer-smoothing.md`) is the
worked example.

The alternative is moving the substrate's affected pipeline (in
this case, routing) into userland alongside the policy. That is a
larger architectural move and is preferred where the substrate's
existing pipeline can be relocated without losing other properties
the substrate provides. Where it cannot, the published-parameter
pattern is the chosen shape.

The pattern is bounded. A substrate that grows more such regions
without limit eventually becomes a parameter-application framework
with policy embedded throughout, which is what the discipline
exists to prevent. Each new region is an ADR-level decision. The
running count is two (focus, smoothing); a third should be
weighed against revisiting the relocation alternative.

## Operating rules

These are the rules that follow from the discipline. They apply to
ADRs, code reviews, and the BACKLOG.

1. **New features do not introduce new guarantee-path dependencies
   without an ADR.** If a feature needs capability X, and X would
   require depending on external code Y that is not already accepted
   as platform transport, the ADR for that feature must address
   whether Y is acceptable (with reasoning) or whether a UTF
   replacement for Y is in scope.

2. **Existing guarantee-path dependencies are named, not hidden.**
   Anywhere UTF currently depends on code outside this document's
   accepted list, the code's dependency should be explicit in its
   comments or commit messages. "We use evdev here" is fine as a
   temporary state; silent use of evdev is not.

3. **Replacements preserve guarantees through the transition.** No
   replacement leaves UTF non-functional for an extended period. The
   migration path for each replacement is part of the replacement's
   design, not an afterthought.

4. **Accepted dependencies can be revisited.** The accepted list in
   this document is the current snapshot. A dependency can move from
   "accepted" to "in scope for replacement" when a concrete reason
   appears, a bug that affected UTF's guarantees, a platform change
   that made replacement more tractable, a UTF feature that requires
   guarantees the dependency cannot provide.

5. **Occam's razor applies.** If a UTF component has grown complex
   because it was working around an external dependency, and the
   dependency is replaced, the component simplifies. Don't preserve
   complexity that existed only to compensate for what was wrong.

## Naming

The discipline itself does not have a catchy name in this document,
by intent. It is not a brand to promote. It is a principle the project
operates by, referenced by its commitments: determinism, stability, and
the explicit enumeration of what UTF depends on.

If a short reference is needed in commit messages or BACKLOG entries,
cite this document by path: `docs/UTF_ARCHITECTURAL_DISCIPLINE.md`.

## Related documents

- `README.md`, project overview; mentions determinism and stability
  as central goals.
- `docs/Thoughts.md`, chronofs architecture; the temporal-coherence
  discussion that established the determinism vocabulary.
- `inputfs/docs/inputfs-proposal.md`, first subsystem-level
  application of this discipline as an explicitly named design driver.
- `BACKLOG.md`, where specific replacements and acceptances are
  tracked as work items.
- `semadraw/docs/adr/0001-zig-and-sdcs.md`, the toolchain and
  canonical-representation decision that this discipline assumes.
- `inputfs/docs/adr/0015-per-user-pointer-smoothing.md`, the
  worked example for the cross-consumer-consistent input policy
  pattern named above.
