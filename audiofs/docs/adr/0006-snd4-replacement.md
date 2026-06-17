# 0006 Replace snd(4) in full: a UTF-owned audio hardware substrate

## Status

Accepted, 2026-05-17.

Supersedes the posture taken in ADR 0003 Decision section 8
("snd(4) as an evolving guarantee-path dependency"), which
accepted snd(4) as platform transport under a per-version
verification gate. This ADR does not invalidate ADR 0003's
clock-writer mechanism; it changes what sits underneath it.
See "Relationship to ADR 0003" below.

Followed by ADR 0007 (physics/semantics boundary), which
governs what may exist inside the path this ADR decides UTF
owns. "Replace snd(4) in full" does not mean reinventing the
audio data-path shape (that shape is physics-forced; audiofs
may resemble snd(4) there freely); ADR 0007 makes that
explicit and is the governing rule for audiofs content.

## Context

ADR 0003 section 8 analysed snd(4) as an evolving
guarantee-path dependency and chose conditional acceptance:
audiofs would read the codec position through snd(4)'s
internal accessors and gate each FreeBSD version on a
semantic-drift check (Stage F.7). The audiofs proposal's
"Kernel-side device ownership" section stated the matching
premise in plain words: audiofs "does not replace `snd(4)`
itself; it is another consumer of the same hardware
abstraction OSS uses."

This ADR reverses that premise. The decision is to write a
UTF-owned audio hardware substrate that replaces snd(4) in
full, including the hardware-driver layer (HDA controller
programming, codec widget handling, DMA ring management, USB
audio class endpoint handling), not only snd(4)'s pcm-core
abstraction.

### The graphics precedent, examined honestly

The argument that motivated reopening this was: "what we do
for graphics is no different." On inspection of
`drawfs/sys/dev/drawfs/drawfs_efifb.c` and
`drawfs/docs/adr/0001-framebuffer-ownership-at-boot.md`, the
graphics precedent is **not** equivalent, and this ADR
records that plainly rather than citing a precedent that
does not hold:

  - drawfs does not own a GPU. It consumes the linear
    framebuffer that UEFI firmware mode-sets and hands the
    kernel via `MODINFOMD_EFI_FB`. It writes pixels into a
    region the firmware already configured. It performs no
    modesetting and no register programming (atomic
    modesetting via DRM is an unchecked future roadmap
    item, not done).
  - AD-39 compiling out `vt_efifb` removed a *competing
    software consumer* of that firmware-provided buffer. It
    did not replace a hardware driver, because there was
    never a UTF-owned graphics hardware driver.
  - There is no audio analogue of the EFI framebuffer.
    UEFI does not initialise the HDA codec, allocate a PCM
    ring, and hand the kernel a "write samples here"
    region. Audio hardware is uninitialised until a driver
    programs it.

Therefore an audio "equivalent" of the graphics move is not
"consume a firmware-provided buffer." It is writing the
hardware drivers from scratch. **This decision deliberately
exceeds the graphics precedent rather than following from
it.** If anything the graphics precedent argues the other
way: graphics succeeded by *not* owning hardware. This ADR
does not pretend otherwise. The decision stands on its own
rationale, below, not on the precedent.

### Rationale (as stated by the decision owner)

**Primary rationale: governance independence (added
2026-05-17, supersedes the ordering below).** The
load-bearing reason for full ownership is not that snd(4)
may regress in performance. It is that a dependency on
snd(4) is also a dependency on the governance, goals, and
release cadence of FreeBSD's audio-driver maintainers. When
UTF needs a driver-level capability that is not provided,
its only options under a dependency are to persuade upstream
(subordinating UTF's objectives to others' decision
process), carry an out-of-tree patch indefinitely (partial
ownership, all the maintenance, none of the control), or do
without. All three gate UTF's ability to meet its own
objectives on a decision process UTF does not control.
Ownership removes that gate: a driver-level gap becomes a
thing UTF closes on its own schedule against its own
requirements.

This is not a hypothesis for audio; it is a lesson UTF has
already paid for and verified in the input path. The
`hms(4)` HID pointing-device driver did not implement
three-finger swipe-and-select or pinch; those features were
requested by macOS-origin users and, over `hms(4)`'s
lifetime, were not added and no action toward them was
observed. Because UTF owned the input path through inputfs,
UTF delivered them itself and verified them on real
hardware (AD-2, Phase 2.5). The full precedent and the
governance-independence principle are recorded in
`docs/AWASE_ARCHITECTURAL_DISCIPLINE.md` ("Governance
independence: why ownership, not just correctness"). The
audio decision applies that proven principle, not an
untested one. Note the precedent's careful epistemic form:
the argument does not depend on anyone having refused, only
on the capability not arriving on any timeline UTF
controlled. The same form applies here.

This primary rationale does not depend on the
performance-drift measurement. Even if snd(4)'s
driver-level behaviour were measured and found perfectly
stable today, the governance exposure would be unchanged: a
stable driver with a gap UTF cannot get closed on its own
terms is still the problem. The performance-drift argument
below is therefore secondary and contingent; this one is
neither.

**Secondary rationale (contingent): performance drift.**
The argument originally recorded as the rationale, retained
unedited below, is a narrower and weaker form of the above:
it identifies one specific mechanism (upstream performance
regression the F.7 correctness gate cannot catch) by which
the unowned layer can harm UTF. It remains valid as a
concrete instance, but it is not the load-bearing argument
and, unlike the primary rationale, it is the unmeasured
engineering judgment flagged in "What this does not
address."

Ownership of the guarantee path cannot be partial. The part
not owned can shift underneath UTF, and for audio "shift"
includes performance regression, not only semantic change.
ADR 0003 section 8's F.7 gate catches *correctness* drift in
snd(4)'s reported semantics; it does not catch *performance*
drift. An upstream FreeBSD change that adds latency or
jitter to the codec interrupt path, or changes DMA buffering
behaviour, degrades UTF's audio-driven clock without
violating any correctness check the gate could run. The
pcm-core-only replacement option does not address this,
because the hardware-driver layer it would retain is exactly
where that performance risk lives. The decision owner's
position: there is no way to own the audio stack's
guarantees without owning the layer that touches the
hardware, because that layer's performance characteristics
are part of the guarantee and are not under UTF's control
while snd(4) drivers remain in the path.

This is the architectural-discipline argument
(`docs/AWASE_ARCHITECTURAL_DISCIPLINE.md`) taken to its
conclusion for audio specifically: external code with "its
own goals, constraints, and future plans" in the guarantee
path is a risk, and for the audio clock the risk surface
includes performance, which a verification gate cannot
bound from outside.

## Decision

1. **UTF writes a hardware-level audio substrate.** audiofs
   owns the audio device end to end: controller register
   programming, codec/widget configuration, DMA buffer
   allocation and ring management, interrupt handling, and
   the sample-position counter read directly from hardware
   rather than through snd(4)'s `xxxchannel_getptr()`. The
   clock semantic ADR 0003 makes load-bearing
   (frames-actually-clocked-out) is read from the
   hardware's own position register by UTF code.

2. **snd(4) leaves the guarantee path entirely.** Neither
   the pcm core nor the FreeBSD audio hardware drivers sit
   under audiofs for devices audiofs owns. This is the
   audio analogue of AD-39 removing vt(4)/vt_efifb from the
   PGSD kernel, extended to the hardware-driver layer
   because, unlike graphics, there is no firmware-provided
   buffer that lets UTF stop short of it.

3. **Scope is bounded by hardware UTF actually targets,
   not by generality.** This ADR does not commit UTF to a
   general audio driver supporting every chipset. It
   commits to the specific audio hardware PGSDF's target
   machines use, in the same way inputfs started
   USB-HID-first and audiofs's own Stage F.1 starts USB
   audio class only. Each supported device is a deliberate,
   separately-verified addition, not an open-ended promise.

4. **The OSS-coexistence and clock-writer mechanisms are
   retained in shape, re-based onto UTF-owned hardware
   access.** ADR 0002's per-device assignment model and ADR
   0003's clock-region wire format and lifecycle do not
   change. What changes is that audiofs reads the position
   counter from hardware it programs, not from snd(4). The
   "one writer, period" property and the clock-region
   contract are unaffected.

## Relationship to ADR 0003

ADR 0003's clock-writer *mechanism* (kernel-side writer,
unchanged wire format, monotonicity guard, lifecycle,
independence from Q2/Q3) stands. What this ADR supersedes is
only ADR 0003 section 8's *posture*: "Accept snd(4) as
platform transport with a verification gate" becomes
"Replace snd(4), including its hardware-driver layer." The
section 8 analysis remains valuable as the record of why
conditional acceptance was considered and why it was judged
insufficient (it bounds correctness drift but not
performance drift). ADR 0003 section 8 should be read with a
forward pointer to this ADR; the F.7 semantic-drift gate it
specified is subsumed by UTF owning the hardware read path
outright (there is no external semantic to drift once UTF
reads the position register itself).

## Consequences

### What this commits

- **A from-scratch audio hardware driver effort.** This is
  categorically larger than any other single piece of the
  UTF substrate, graphics included, because graphics never
  wrote a hardware driver and this does. The commitment is
  ongoing: hardware UTF does not control, maintained
  indefinitely, per supported chipset. This consequence is
  stated bluntly because the decision was taken with it in
  view, not in spite of being unstated.
- **The audiofs migration path (Stage F) grows a
  hardware-driver sub-stage.** Stage F.3 (audio data path)
  was already flagged in the proposal as the largest
  sub-stage with the most unknowns; under this ADR it also
  subsumes controller/codec bring-up. F.3 is now the
  dominant risk of the entire effort and should likely be
  decomposed further when AD-3 is scheduled.
- **Verification semantics change.** "Verified" for a
  from-scratch HDA driver is a much stronger and less
  well-trodden claim than "verified that we read snd(4)'s
  counter correctly." Stage F.7's protocol must be rebuilt
  around hardware-level correctness (does the codec
  actually clock out what we think, measured against an
  external reference), not snd(4) semantic conformance.

### What this enables

- **The audio guarantee path becomes fully UTF-owned**, on
  the same footing as inputfs and drawfs's
  software-on-firmware-buffer model, closing the
  performance-drift exposure ADR 0003 section 8 could only
  gate against, not eliminate.
- **AD-3's eventual scope is now explicit** rather than
  resting on an unstated assumption that snd(4) would be
  retained.

### What this does not address

- **Which specific chipsets, and the maintenance model.**
  Bounded-by-target is stated as a principle; the actual
  device list and the long-term maintenance commitment are
  not specified here and are the first thing a future
  scheduling ADR for AD-3 must pin down.
- **Whether the *secondary* rationale's premise holds
  empirically.** The claim that upstream snd(4) performance
  drift is a real and material risk to UTF's clock is
  stated as the decision owner's engineering judgment. It
  is not measured here. A future ADR or the F.7 work may
  quantify it. This caveat applies only to the secondary
  (performance-drift) rationale: as the Rationale section
  states, the primary rationale (governance independence)
  is explicitly not contingent on this measurement, so the
  decision does not rest on the unmeasured claim. Measuring
  the performance-drift premise remains worthwhile to
  characterise the risk being accepted, not to gate the
  decision. The empirical validation of the *primary*
  rationale is specified separately in
  `audiofs/docs/snd4-gap-governance-audit.md` (a
  specification, not yet performed); that audit, not the
  performance measurement, is what tests the
  governance-independence argument, and its decision
  criteria are pre-registered there so a weak result is
  recorded rather than buried.
- **AD-3 scheduling.** AD-3 remains Open and not
  scheduled. This ADR fixes the architectural target so
  that when AD-3 is picked up it starts from a decided
  scope rather than reopening this question.

## What this document is not

This is not an implementation plan, a chipset list, a
schedule, or a measurement of the performance-drift risk
that motivates it. It records one architectural decision:
that UTF's audio substrate replaces snd(4) in full,
including hardware drivers, that this deliberately exceeds
the graphics precedent rather than following from it, and
the stated rationale for accepting that scope. The
implementation shape belongs in the AD-3 scheduling work
and the Stage F sub-stage ADRs.
