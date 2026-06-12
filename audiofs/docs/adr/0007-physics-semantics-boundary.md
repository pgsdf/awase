# 0007 The physics/semantics boundary for audiofs content

## Status

Accepted, 2026-05-17.

Builds on ADR 0006 (replace snd(4) in full). ADR 0006
answered the *ownership* question: UTF owns the audio path
directly rather than delegating to snd(4). This ADR answers
the question ADR 0006 leaves open: given that UTF owns the
path, what kinds of behaviour are permitted to exist inside
audiofs at all. Partially supersedes ADR 0004 (mixer
location): ADR 0004 decided *where* mixing lives; this ADR
decides *why*, and tightens *what else* concentrates in
semasound as a consequence. See "Relationship to prior
ADRs" below.

## Context

The earlier framing of the snd(4) question was "mimic
snd(4)" versus "replace snd(4)," later refined to "shape
versus quality." Both are imprecise. The correct test is
not how much audiofs resembles snd(4), and not a
judgment of degree. It is a determinate question that can
be asked of any individual behaviour:

> Is this behaviour derivable directly from hardware state
> and transport mechanics, or does it represent semantic
> policy and interpretation?

This is materially stronger than the earlier framings
because it is externally checkable per behaviour rather
than a matter of taste. DMA ring advancement is derivable
from the codec's buffer position. Hardware clock extraction
is derivable from the transport position counter. Interrupt
cadence is derivable from the DMA engine. These are
physics-constrained mechanisms; they belong in audiofs.
Resampling, dithering, clipping behaviour, channel
virtualisation, drift smoothing, and latency/quality
tradeoffs are not derivable from any hardware fact. There is
no physically correct resampler, no hardware-derived
interpolation kernel, no hardware answer to a
quality-versus-latency tradeoff. These are semantic
policy; they do not belong in audiofs.

Stated in terms of resemblance: audiofs may resemble snd(4)
freely wherever the resemblance is forced by hardware,
because there is no UTF-specific alternative to the way a
DMA engine and a codec actually work. Resemblance is not
the danger. The danger is inheriting semantic behaviour
designed for a non-UTF world that cannot be externally
specified or reasoned about.

## Decision

**Core rule.** audiofs may contain only behaviour derivable
directly from hardware state and transport mechanics. All
semantic interpretation, adaptation, and policy belong in
semasound or higher userspace layers.

Native-format-only follows as a direct consequence, not as
a separate preference: format conversion is semantic by
definition (no hardware fact determines the correct
resampler or dither), therefore the core rule forbids it in
audiofs. This matters because it prevents later erosion
under convenience arguments. "It would be simpler to just
resample in the kernel" cannot be argued without first
explicitly violating the governing rule of the subsystem.

The rule is only meaningful if it survives the cases where
it is genuinely under stress. The following three
sub-decisions are not implementation detail; they are the
adversarial validation of the rule. Each records an
explicit tiebreak and its accepted cost. An implementation
that satisfies the one-sentence rule while violating these
sub-decisions does not satisfy this ADR.

### Stress case 1: xrun / underrun handling

An underrun is hardware-triggered but policy-determined.
The DMA engine reaching starvation is a physical event; the
choice of what the hardware then emits (silence, stale
samples, repeat-last-buffer, interpolation, pause/resume) is
semantic. The boundary is therefore not self-applying here
and needs an explicit tiebreak.

**Tiebreak.** audiofs performs only the minimal
mechanically-forced behaviour implied by the hardware state
and exposes the xrun as an event. It does not implement
recovery semantics. Whatever the DMA engine naturally emits
when starved is what happens; if the ring is zeroed,
silence results. audiofs reports the condition through its
event ring; semasound owns any recovery policy above it.

**Accepted cost, stated plainly.** Xruns are intentionally
unforgiving under this architecture, because smoothing is
semantic and is deliberately excluded from the kernel
layer. This is a price of the boundary, not a defect to be
fixed later by adding kernel-side smoothing; adding it would
be a violation of the core rule.

### Stress case 2: format selection

"Native-format-only" quietly assumes the hardware has a
single physically privileged native format. Many codecs do
not: some support multiple rates symmetrically, or expose
several equally valid operational modes. If audiofs *chooses*
which hardware-supported format to use, it has crossed into
policy, because selecting among equally valid hardware
states is a semantic decision, not a physical one.

**Tiebreak.** audiofs reports the currently configured
hardware format as a fact; it does not elect it. Selection
among hardware-supported configurations belongs to
semasound. This necessarily introduces a downward control
path from semasound into audiofs for hardware
configuration. There is no coherent way to avoid that while
preserving the rule honestly.

**Fence, stated explicitly so it cannot become precedent.**
Control paths into audiofs are permitted *only* for
selecting among hardware-supported operational states. They
may not carry semantic interpretation or adaptation logic.
Configuring a hardware mode is permitted because it selects
physics. Transforming audio semantics through a control
path is forbidden. The existence of this single fenced
exception is not a precedent for pushing other policy
downward; any future downward path must independently pass
the core rule, and "there is already a control path" is
explicitly not an argument.

### Stress case 3: chronofs clock continuity

This is the case that most strongly validates the rule.
Under ADR 0003 and ADR 0006, audiofs owns clock extraction
directly from the hardware playback counter. If semasound
crashes and audio delivery stops, the question is whether
the clock stops with it.

"Audio stops if semasound dies" is an acceptable
architectural consequence. "The global timing authority
collapses because the userland audio daemon died" is not:
the chronofs clock is consumed by semadrawd's frame
scheduler and inputfs's event timestamps; it is the
system's authoritative timeline, not an audio feature.

**Resolution.** Clock advancement is derivable from
hardware playback progression: if the codec DMA counter
advances, the clock advances. Whether semasound is
currently delivering meaningful samples is irrelevant to
that fact. audiofs therefore continues advancing the
chronofs timeline independently of semasound liveness for
as long as the hardware transport itself remains active.
This is not a special-case carve-out added to make the
consequence palatable; it falls directly out of the core
rule, because clock extraction is physics and sample
delivery is semantics, and the rule already placed them on
opposite sides of the boundary. The system preserves
temporal authority precisely because temporal authority was
grounded in hardware state rather than semantic policy.

This sub-decision is the load-bearing reason the "audio
stops if semasound dies" cost (below) is acceptable. If
clock and sample-delivery were not already separated by the
boundary, accepting that cost would be wrong. The rule did
real architectural work here; it did not merely organise
intuition.

### The clock/mix seam: rate correction, not position correction

ADR 0006 split timing authority (audiofs, kernel) from
mixing (semasound, userland). For "UTF owns the timing
path" to remain true after that split, semasound's
correctness must not depend on the latency or jitter of any
individual clock observation.

**Hard requirement.** semasound maintains a free-running
local playback model derived from its own buffer
accounting. It uses kernel-clock observations only to
estimate and correct *drift rate* over time, not to apply
*position* corrections per observation. A position-
correcting design (read the clock, jump to the reported
sample) remains coupled to kernel/userspace scheduling
jitter even if it samples occasionally: the jitter simply
reappears at the sampling boundary. A rate-correcting
design treats the hardware clock as a long-term authority
on slope, so instantaneous read jitter averages out and
only long-term rate error affects correction. The kernel
clock constrains the mixer's long-term slope; it does not
schedule the mixer.

This is normative, not advisory. An implementation that
samples the clock periodically but applies a positional
correction on each sample technically reads as compliant
with a loose reading of ADR 0006 while violating its
design intent. "Rate correction, not position correction"
is the property that actually closes the seam; the loose
reading merely relocates the old coupling to the sampling
boundary.

## Relationship to prior ADRs

**ADR 0006 (replace snd(4) in full)** established that UTF
owns the audio path. This ADR is the governing rule for
what may exist inside that owned path. ADR 0006 should be
read with a forward pointer to this ADR: "replace snd(4) in
full" does not mean reinventing the audio data-path *shape*
(that shape is physics-forced and audiofs may resemble
snd(4) there freely); it means owning a hardware-shaped
transport while admitting no semantic policy into the
kernel layer.

**ADR 0004 (mixer location), partially superseded.** ADR
0004 decided Option A: semasound is the sole writer and
mixes in userland. That decision stands. What this ADR
supersedes is the *scope* of what concentrates in
semasound. ADR 0004 framed semasound as a mixer with a
"semasound becomes load-bearing" risk. Under the core rule,
semasound is not merely load-bearing: it is the entire
semantic audio system (mixing, resampling, format
negotiation, drift estimation, timing prediction,
compatibility policy). ADR 0004's risk section should be
read as understating this; the accurate statement is the
"accepted costs" section below. ADR 0004's mechanism
(single-writer, userland mix) is unchanged; only its
characterisation of semasound's scope is tightened here.

## Consequences

### Accepted costs, stated bluntly

These are prices of the boundary, recorded plainly in the
manner ADR 0006 recorded the hardware-driver burden, not
softened as possibilities:

- **semasound is the entire semantic audio system.** If
  semasound fails, semantic audio behaviour stops
  completely, because the architecture intentionally
  removes kernel fallback paths. This is the explicit
  price of restricting audiofs to physics-derived
  behaviour. UTF's broader posture already accepts this
  class of concentration: if the system claims ownership
  of guarantees, it accepts ownership of the resulting
  failure domains. Hiding this in the audio stack would be
  inconsistent with the rest of the project.
- **Audio stops if semasound dies; the clock does not.**
  The first is accepted (stress case 1 and the costs
  here). The second is the reason the first is acceptable
  (stress case 3). These are not the same statement and
  must not be conflated.
- **Xruns are intentionally unsmoothed.** Smoothing is
  semantic; it is deliberately absent from the kernel
  layer. This is by design.
- **One fenced downward control path exists.** Format/mode
  selection flows from semasound to audiofs. It is the
  single permitted exception to "audiofs publishes,
  userland reads," fenced to hardware-state selection
  only, and explicitly not a precedent.

### What this does not address

- **The semasound robustness requirements** that follow
  from it being the entire semantic system. Concentrating
  all failure-prone judgment in one userland daemon raises
  its testing, supervision, and restart requirements
  substantially. ADR 0005 (userland architecture) owns
  semasound's shape; that ADR should be revisited against
  this one when AD-3 is scheduled.
- **No kernel safety/fallback path.** This ADR decides
  there is none, and why (a fallback is a semantic escape
  hatch that makes the boundary porous and becomes a
  justification for moving more policy downward over time).
  It does not design a supervision strategy for semasound,
  which is the correct place for robustness to be
  addressed instead.
- **Implementation of the rate-correcting predictor.** The
  requirement is stated; the predictor's design (control
  loop form, drift-estimation window, correction slope
  bounds) belongs in semasound implementation work under
  AD-3.
- **AD-3 scheduling.** Unchanged: AD-3 remains Open and not
  scheduled. This ADR fixes the governing rule so AD-3,
  when scheduled, starts from a decided boundary.

## What this document is not

This is not an implementation plan, a predictor design, a
supervision strategy for semasound, or a schedule. It
records one architectural rule and its adversarial
validation: audiofs may contain only behaviour derivable
from hardware state and transport mechanics; the rule was
stress-tested against xruns, format selection, and clock
continuity; the explicit tiebreaks and accepted costs are
recorded so the difficult seams were confronted rather than
deferred. The rule is reusable beyond audio: "is this
behaviour derivable from hardware state, or is it semantic
policy?" is a test future UTF subsystem decisions can
apply.
