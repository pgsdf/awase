# audiofs: Native Audio Substrate Proposal

Status: Proposed, 2026-04-29

## Summary

UTF will replace its dependence on FreeBSD's OSS sound subsystem
with a native kernel audio substrate, `audiofs`, modelled after
`inputfs` and `drawfs`. Audio becomes a first-class kernel
service: device enumeration, stream lifecycle, sample-position
clock writing, and event publication all happen in the kernel.
The userspace daemon `semasound` replaces `semaaud`, taking over
the durable-policy logic, mixer arithmetic, and runtime UI state
that the existing daemon already implements, but reworked to
talk to `audiofs` instead of `/dev/dsp*`.

This document argues that OSS's shape is increasingly
incompatible with UTF's architectural commitments, describes
the native substrate that replaces it for UTF-aware
applications, and sketches a migration path that keeps UTF
operational throughout. It does not specify ioctl numbers,
struct layouts, the audio-data path, or a schedule. Those
belong in follow-on ADRs.

This proposal is the second named application of the
discipline stated in `docs/UTF_ARCHITECTURAL_DISCIPLINE.md`:
**UTF depends only on code written with UTF's guarantees in
mind**. OSS is an external dependency whose authors were not
thinking about UTF's determinism, clock model, or stability
commitments; it sits on UTF's audio guarantee path; therefore
it is replaced for UTF-aware consumers. The discipline
document provides the broader context for why this work is
being done. inputfs is the precedent that shows the shape of
the replacement: kernel substrate plus reworked userland
daemon, coexisting with the legacy stack rather than removing
it. This proposal describes how the audio version of that
shape works.

## Why OSS is the wrong model for UTF

The rest of UTF is built on a consistent premise: the kernel
owns the authoritative state, userspace daemons publish
derived views, and the substrate is the single arbiter of what
reaches consumers. `drawfs` owns the framebuffer and surface
registry. `inputfs` owns the input event stream. `chronofs`
provides the clock bus. OSS fits none of these patterns. It
is a portable sound API designed in the 1990s for
multi-platform Unix audio, and its assumptions were formed
in an era before sample-position clocks were the substrate of
a temporal fabric and before kernel-side mixing was reconsidered
as a concentration of complexity in the wrong place.

Six concrete mismatches show up in the current code.

**The clock writer is in userland.** UTF's clock model treats
audio as the source of truth (`docs/Thoughts.md`, "Audio as
Source of Truth"). The sample-position counter at
`/var/run/sema/clock` is the temporal substrate every other
daemon reads from. Today, semaaud writes that counter from
userland, deriving it from how many bytes it has written to
`/dev/dsp` and the negotiated sample rate. This is several
indirections removed from the hardware: OSS buffers the
samples, the OSS driver hands them to the codec, the codec
clocks them out at its own pace, and only by inference does
semaaud know "by now, N samples have actually been played."
The actual sample position lives in the kernel: the snd(4)
chain knows it, the codec driver knows it. Reading it from
userland through OSS's `SNDCTL_DSP_GETOPTR` (or equivalent) is
indirect at best and lossy at worst. A kernel substrate that
writes the clock directly closes this gap.

**Format negotiation is hidden inside OSS.** semaaud opens
`/dev/dsp`, calls `SNDCTL_DSP_SETFMT`, `SNDCTL_DSP_CHANNELS`,
`SNDCTL_DSP_SPEED`, and trusts whatever OSS reports back as
the negotiated values. OSS may have applied sample-rate
conversion, bit-depth conversion, or channel up/downmixing
silently; semaaud cannot tell from the outside. UTF's
discipline says the substrate's behaviour should be
specifiable. OSS's negotiation is not specifiable from a UTF
perspective: it is whatever the loaded sound drivers happen
to do.

**Mixing happens in the kernel, but invisibly.** OSS supports
multiple opens of the same device with kernel-side mixing.
This is convenient for legacy applications but it puts
floating-point arithmetic on samples inside a kernel module
whose author was not thinking about UTF's determinism
guarantees. The same eight applications producing audio at the
same sample positions on two different machines may not produce
bit-identical mixed output because the kernel's mixing
algorithm is not specified by UTF and is not under UTF's
control.

**No published stream lifecycle.** When an OSS application
opens, configures, and closes a stream, no event reaches the
substrate. Other UTF consumers cannot observe what's currently
playing, what just stopped, what xruns happened. semaaud
publishes some of this to `/tmp/draw/audio/<target>/` for its
own UI consumers, but those publications are semaaud's
internal state, not a substrate-level fact. A consumer that
wants to react to "this stream just started" has to ask
semaaud, and semaaud has to know to publish the right thing.

**Per-stream state lives nowhere addressable.** inputfs
publishes per-device state (slot index, vendor/product ID,
roles bitmask, current pointer position). Audio has the same
shape (multiple input streams, each with its own sample-rate,
channel-count, current position, mute state), but there is no
substrate-level representation. semaaud holds the data
internally and exposes some via its control socket. A second
UTF-aware daemon that wants to know "what audio streams exist"
cannot ask the substrate; it must know to ask semaaud
specifically.

**OSS is a compatibility surface, not a UTF surface.** The OSS
API is shaped by a quarter-century of cross-platform Unix
audio: ioctls that mean different things on Linux vs FreeBSD
vs Solaris, format flags whose semantics depend on the
implementation, blocking and non-blocking modes that interact
unpredictably with the FreeBSD scheduler. UTF's discipline
calls for substrates whose surface is specifiable and stable.
OSS's surface is neither, by construction; it is a
compatibility layer.

None of these are bugs in OSS. They are consequences of OSS
being designed for a different problem than the one UTF is
solving. inputfs faced an analogous situation with evdev:
evdev is fine for Linux desktop applications; it just isn't
the right shape for UTF's kernel-owned-authoritative-state
model. The same argument applies here.

## What the UTF-native model looks like

audiofs takes the same shape as inputfs, adjusted for the
constraints audio brings.

### Kernel-side device ownership

**Premise reversed by ADR 0006 (2026-05-17).** This section
and the `snd(4)` accepted-risk paragraph that follows it
describe the original design, in which audiofs keeps
`snd(4)` and does not replace it. ADR 0006 superseded that:
UTF replaces `snd(4)` in full, including its hardware-driver
layer. The text below is retained unedited as the record of
the prior premise and the reasoning that led to its
reversal; read "does not replace `snd(4)` itself" and the
conditional-acceptance paragraph as historical, superseded
by ADR 0006. The graphics precedent invoked to motivate the
reversal is examined honestly in ADR 0006: it does not in
fact transfer (drawfs consumes a firmware-provided
framebuffer; audio has no such free lunch), so ADR 0006
records that the decision deliberately exceeds the graphics
precedent rather than following from it.

audiofs attaches to PCM hardware through the existing FreeBSD
`snd(4)` framework, the same way inputfs attaches at the
hidbus layer. It does not replace `snd(4)` itself; it is
another consumer of the same hardware abstraction OSS uses,
sitting alongside OSS rather than under or over it. Hardware
that is enumerated as a sound card by the kernel can be
attached by audiofs the same way inputfs attaches HID
keyboards and pointers.

A device, in audiofs terms, is one PCM endpoint: typically one
output (the speaker line, the headphone jack, a USB headset's
sink) or one input (a microphone, a USB headset's source). A
single sound card with stereo output and a microphone is two
audiofs devices. This matches OSS's mental model and the
underlying hardware reality, but the substrate-level
representation is owned by audiofs.

Keeping `snd(4)` is itself a guarantee-path dependency on
upstream-evolving external code, and this proposal argues OSS
is unacceptable partly on specifiability grounds while resting
the replacement on `snd(4)` internals that are less
contractually stable than OSS's frozen legacy API. That
tension is not hidden: it is analysed, and the posture
(conditional acceptance gated by a per-FreeBSD-version
semantic-drift check in Stage F.7) is decided, in ADR 0003
Decision section 8 per the discipline doc's Operating Rule 1.
The short form: `snd(4)` is accepted as platform transport
for the hardware sample position it uniquely exposes, but its
acceptability is treated as falsifiable per platform version
rather than assumed permanent.

### Shared-memory publication

`/var/run/sema/audio/state` and `/var/run/sema/audio/events`
mirror inputfs's `/var/run/sema/input/` layout. The state
region carries the device inventory, the active stream
inventory, and the current sample position per stream. The
events ring carries stream-lifecycle events (begin, end,
xrun, format change). Both files use the same magic / version
/ valid / pad header pattern as inputfs's regions, so the same
reader machinery in `shared/src/` extends naturally.

The audio data itself is the open question. It does not fit
in the events ring: at 48 kHz stereo s16le, 5.76 GB per hour
is too much for an event-log shape. The choice between a
tmpfs-backed per-stream ring, a kernel-mapped DMA buffer
exposed via mmap, or some third option is the subject of a
dedicated ADR (see "Open architectural questions" below). The
proposal does not pre-empt that decision; it commits only to
the existence of *some* audio data path between audiofs and
its consumers.

### Kernel-side clock writing

Today, `/var/run/sema/clock` is written by semaaud from
userland. With audiofs, the clock writer becomes the kernel
substrate. audiofs knows the actual hardware sample position
through `snd(4)`'s buffer-pointer reporting; reading it once
per audio interrupt and storing it in the clock region closes
the latency gap that userland reading creates.

The wire format of the clock region does not change.
`clock_source` continues to read 1 (audio); the recently-added
observability field already accommodates this scenario. The
shift is in *which process* writes the bytes. Existing
consumers (chronofs, semadraw frame scheduler) see no
change.

This is a meaningful architectural shift: the userland audio
daemon is no longer privileged in the substrate. semaaud today
owns the clock; semasound tomorrow does not. Other UTF
substrates and consumers no longer depend on a userland
process being alive for the clock to advance; they depend on
the kernel module being loaded, which is the same dependency
they already have on inputfs and drawfs.

### Userland responsibilities: semasound

audiofs is the kernel substrate; it is intentionally narrow.
It does not implement durable policy, mixer arithmetic on
sample data, output routing, volume curves, mute logic, or
runtime UI state. Those are userland concerns and they live
in semasound.

semasound inherits semaaud's existing work:

- **Durable policy** (Phase 12): versioned policy grammar,
  policy validation, allow/deny/override/group semantics,
  preemption, fallback routing, the `policy-valid` and
  `policy-errors` filesystem surfaces.
- **Named targets**: the `default` and `alt` topology
  semaaud already implements.
- **Mixer logic**: combining streams from multiple producers
  into a single output buffer that audiofs writes to the
  hardware. This is where the floating-point arithmetic on
  samples lives, in userland, where it is testable,
  inspectable, and replaceable without a kernel module
  rebuild.
- **Control socket and event log**: the JSON event log on
  `/tmp/draw/audio/<target>/stream/events`, the runtime
  state surfaces under `/tmp/draw/audio/<target>/`, the
  control socket for external configuration.

In return, semasound sheds:

- **OSS device handling**: `oss_output.zig`, the
  `SNDCTL_DSP_*` ioctls, the `/dev/dsp{N}` enumeration,
  the format negotiation. audiofs does this.
- **Clock writing**: clock-region init and update.
  audiofs does this.
- **Sample position counting**: deriving samples-played
  from bytes-written. audiofs reports this directly.

The split makes semasound look more like a session-management
daemon (PulseAudio-shaped, in PulseAudio's better moments)
sitting on top of a kernel substrate, rather than a
hardware-driving daemon that also happens to do session
management.

### Sole-writer pattern

Following inputfs's pattern, audiofs has exactly one userland
writer per output device: semasound. Applications that produce
audio talk to semasound, which mixes them and writes the
result to audiofs. They do not write to audiofs directly.

This keeps audiofs simple: it does not need to arbitrate
between multiple kernel-space writers, does not need to mix
streams in-kernel, does not need fairness machinery. It does
what inputfs does for input: presents one authoritative
substrate-level state, written by one privileged process,
readable by any consumer.

The cost is that non-UTF-aware applications cannot speak
audiofs directly. They continue to use OSS, the same way
non-inputfs-aware applications continue to use evdev. A
compatibility shim (an `/dev/dsp`-shaped userland process
that translates OSS calls into audiofs operations) is a
plausible follow-on but is explicitly out of scope for
this proposal.

### Audio-clock timestamps on events

inputfs stamps every published event with the sample position
at emission time. audiofs's events do the same. A
`stream.begin` event carries the sample position at which the
stream started; a `stream.xrun` event carries the sample
position at which the underrun was detected. This is the same
discipline `chronofs` formalised for the rest of the fabric:
all timestamps are in audio samples, not wall-clock seconds.

### Coexistence with OSS

OSS is not removed. The kernel module remains loaded; legacy
applications continue to open `/dev/dsp`. audiofs and OSS
attach to different consumers of the same hardware, the same
way inputfs and evdev both observe the same HID devices. There
is no flag day, no mass cutover, no forced migration of
non-UTF applications.

The trade-off: while both are loaded, both are reading from
the hardware. For input, this works fine because HID reports
are cheap to duplicate. For audio output, this is more
delicate: two writers to the same hardware sink need
arbitration. The audiofs/OSS coexistence story is the subject
of a dedicated ADR (see "Open architectural questions").

## Migration path

Stage F breaks into sub-stages mirroring Stage D's structure.
Each one is independently verifiable; the sequence supports a
working system at every checkpoint.

### Stage F.0: Architectural ADRs

Before any kernel code, the architectural decisions are
captured in ADRs. The data path (tmpfs ring, kernel-mapped
DMA, or a hybrid), the mixer location (semasound is sole
writer, vs in-kernel mixing), the OSS coexistence model, and
the clock-writer transfer are all decided in writing first.
This sub-stage produces no compiled artefact; it produces the
documentation that makes subsequent sub-stages possible.

### Stage F.1: audiofs skeleton

Kernel module attaches to one PCM endpoint (initially USB
audio class only, mirroring inputfs's USB-HID-first start),
publishes `/var/run/sema/audio/state` with the device
inventory, no audio data flow yet. Verifiable: state file
exists with correct magic and version, device count matches
the number of attached USB audio devices, MOD_LOAD and
MOD_UNLOAD are clean.

### Stage F.2: Stream lifecycle events

audiofs's events ring publishes stream begin, stream end,
xrun, and format-change events. No audio data yet, just the
metadata about streams that semasound (or its precursor)
might create. Verifiable: events file exists, semasound
opening and closing test streams generates the expected
events with monotonic sequence numbers.

### Stage F.3: Audio data path

The audio bytes flow per the F.0 ADR's chosen mechanism. This
is the largest single sub-stage and the one with the most
unknowns at the time of this proposal. Verifiable: a
test-tone Zig program written for audiofs can play through the
hardware with the expected sample rate and minimal latency.

### Stage F.4: Clock takeover

audiofs becomes the kernel-side writer of `/var/run/sema/clock`.
semaaud's clock-writer code path is disabled (semaaud still
runs but the relevant code is conditionally compiled out, or
the relevant function returns early). chronofs and semadraw
verify that clock-region semantics are preserved.
Verifiable: `clock_source` reads 1 (audio); `samples_written`
advances monotonically at the negotiated sample rate; the
existing two-thread visibility test in `shared/src/clock.zig`
passes against an audiofs-written clock as well as a
semaaud-written one.

### Stage F.5: semasound

The new userland daemon. Inherits semaaud's durable policy,
mixer logic, named-target topology, event log, and runtime
state surfaces. Removes the OSS code paths. Talks to audiofs
as the sole writer of the audio data path. Verifiable: each
of semaaud's existing functional tests passes against
semasound, with the device-interface portions reworked.

### Stage F.6: semaaud retirement

Analogous to AD-2 (semainput retirement). Once semasound is
verified end-to-end on bare-metal, semaaud's role narrows to
nothing and it is dropped from the active stack. Like AD-2,
this is its own deliberate cutover, not an automatic
consequence of semasound landing.

### Stage F.7: Verification protocol

`audiofs/test/f/f-verify.sh` and
`audiofs/docs/F_VERIFICATION.md`, structurally similar to the
Stage D verification but covering audio-specific concerns:
stream begin and end, sample-rate sanity, xrun detection,
clock takeover correctness, semasound lifecycle.

### Interim status: clock-writer ownership

Through Stages F.0 through F.3, semaaud continues to write
the clock from userland. The clock takeover happens explicitly
in F.4 once audiofs has the audio-data path working.
chronofs sees no change at any point; the clock-region wire
format does not move.

## Open architectural questions

These are the decisions that ADRs in the F.0 sub-stage will
resolve. The proposal commits to the questions, not the
answers.

### Q1: The audio data path

Three plausible shapes for how audio bytes move between
semasound and audiofs (and from audiofs to the hardware):

**A. tmpfs-backed per-stream ring.** semasound writes mixed
audio into a per-output ring file under `/var/run/sema/audio/`
(one file per device or per stream); audiofs reads from the
ring and writes to the hardware. Simplest, matches the
pattern of inputfs's events ring. Cost: one copy through
tmpfs in each direction. At 48 kHz stereo s16le, that is
~192 KB/s per stream, well within tmpfs throughput, but the
copy cost is non-zero.

**B. Kernel-mapped DMA buffer via mmap.** audiofs allocates
a DMA buffer for each output device; semasound mmaps it; the
hardware reads directly from the DMA region without a copy.
Lowest latency, no copy. Cost: introduces kernel-mapped-
userland-buffer machinery that no current UTF substrate uses;
the lifetime and synchronisation of the mapping need careful
specification; cross-architecture portability gets harder.

**C. Hybrid.** A small per-stream ring in tmpfs for control
and metadata; the actual sample frames in a separate kernel-
managed buffer accessed by mmap. The ring carries
"semasound has written N more frames" advance-pointers; the
mmapped buffer holds the frames themselves. Splits the
benefits of A and B at the cost of two synchronisation
mechanisms.

### Q2: Mixer location

inputfs is the sole writer of `/var/run/sema/input/`;
semasound being the sole writer to audiofs is the natural
extension. But: should audiofs allow multiple kernel-space
producers of audio (each application opening audiofs
directly)? The answer affects the audio-data-path ADR. The
inputfs precedent says "one writer, period": applications go
through the userland daemon. The OSS precedent says "many
writers, kernel mixes." UTF's discipline points toward the
former; pragmatism (compatibility with how applications
expect audio to work) might point toward the latter.

### Q3: OSS coexistence

audiofs and OSS both want to talk to the same PCM hardware.
Three plausible postures:

**Exclusive.** audiofs and OSS cannot coexist on the same
device; loading audiofs detaches the device from OSS. Cleanest
semantically, hardest for migration: legacy applications
break the moment audiofs loads.

**Cooperative.** audiofs attaches to specific devices, OSS
keeps the others. Operators choose which devices belong to
which substrate via sysctl or configuration. Allows mixed
deployment but requires per-device attach/detach machinery.

**Layered.** audiofs sits on top of OSS, opening
`/dev/dsp` itself and exposing its own substrate to UTF
consumers. Easiest to implement (audiofs is just a kernel
process that uses OSS the same way semaaud does today) but
gives up the "kernel-side device ownership" property that
motivates the substrate in the first place. Probably wrong
for that reason, but worth having on the list.

### Q4: Format model

How much format negotiation lives in audiofs?

**Native-format-only.** audiofs publishes the hardware's
native sample rate, bit depth, and channel count. semasound
must produce audio in that exact format. All sample-rate
conversion and format conversion happens in semasound.
Cleanest specification of audiofs's behaviour; pushes
complexity to userland where it is testable.

**Negotiated.** audiofs negotiates a format with semasound at
stream-open time and converts on the fly. Easier for
semasound; complicates audiofs's specification.

**Multi-format.** audiofs supports a small fixed set of
formats (e.g. s16le 48 kHz, s32le 48 kHz, f32le 48 kHz, all
stereo) and the hardware-native conversion happens in audiofs.
Compromise; introduces in-kernel conversion which we just
argued against for the mixer case.

### Q5: Latency targets

What is audiofs's latency budget? OSS allows applications to
configure buffer sizes; audiofs needs an analogous mechanism.
The lower bound is set by the F.0 data-path choice; the upper
bound is set by what semasound can usefully do with its
mixing window. For reference, current OSS-based semaaud runs
with a buffer that gives ~20 ms of audio per refill; audiofs
should at minimum match this and ideally improve on it.

### Q6: Serialization format for semasound's userland surfaces

semasound publishes runtime UI state under
`/tmp/draw/audio/<target>/` (current state, active policy,
last event, capabilities, errors). semaaud uses JSON for
these surfaces today; semasound inherits that work. The
question is whether the inheritance is verbatim, or whether
some of these surfaces should switch to a binary format
(FlatBuffers being the leading candidate among binary
options).

The substrate side of audiofs is not in scope for this
question. `/var/run/sema/audio/{state,events}` and any
audio-data-path file follow the same pattern as inputfs's
publication regions: hand-specified byte layouts in
`shared/AUDIO_*.md`, fixed offsets, atomic field updates,
no parser on the read path. FlatBuffers is the wrong shape
for kernel substrate publication regardless of how this
question resolves.

Four ways the userland-surface question could go:

**JSON throughout (status quo).** Inherit semaaud's JSON
verbatim. Lowest effort; aligns with the existing tools
(`inputdump`, `chrono_dump`) that emit JSON for human
inspection via `jq` and similar pipelines. Cost: parsing
overhead grows linearly with consumer poll rate. With no
hot-path consumer driving a requirement today, the cost is
theoretical.

**FlatBuffers throughout.** Switch every userland surface
to FlatBuffers. Wins zero-copy reads; loses
human-inspectability without a decoder; loses
`jq`-pipeline compatibility for diagnostics; introduces a
schema-compilation step in the build. The schema-compilation
step is real cost: every consumer of the surfaces (UI
dashboards, log viewers, CI checks) needs the schema
available at build time, in whatever language they use.

**Split: JSON for diagnostic / log surfaces, binary for
hot-path consumer surfaces.** Treat the JSON-vs-binary
question per surface, not per daemon. `last-event` and
`policy-errors` and capabilities stay JSON because they are
read by humans and tools more often than by hot-path code.
A dedicated "subscribe to current playback state" surface
gets a binary format (FlatBuffers or hand-specified)
because that surface is what a hot-path consumer would
poll.

**Defer until a real consumer drives the requirement.**
Inherit JSON in F.5 (semasound). When a real consumer
emerges that needs zero-copy reads at sustained high
rates, *that consumer's* requirements drive the format
choice for the specific surface it cares about. No
preemptive switch.

Recommended posture, subject to F.0 ADR-level review:
**defer**, on the grounds that picking a binary format
preemptively without a consumer requirement is premature
optimization. The existing JSON surfaces work for the
current consumer set (none of which exist yet for
semasound, and all of which work on tools that prefer
JSON). The criterion that would reopen this question is a
concrete proposed consumer that polls
`/tmp/draw/audio/<target>/` at a sustained rate where JSON
parsing cost matters. Until that consumer exists in design,
JSON is the right answer; this question is tracked here so
the decision is explicit-by-deferral rather than implicit.

## What this document is not

- **A specification.** No ioctl numbers, struct layouts, or
  wire-format details. Those belong in
  `shared/AUDIO_STATE.md`, `shared/AUDIO_EVENTS.md`, and the
  audio-data-path spec (whose name depends on Q1's answer).
- **A schedule.** Stage F follows AD-2 (semainput retirement)
  and AD-9 (HID descriptor and report fuzzing) per the
  BACKLOG priority list. No commitment to start dates or
  duration.
- **An OSS-removal plan.** This proposal commits to
  *replacing OSS for UTF-aware applications*. Whether OSS is
  ever removed from the system is a separate decision that
  depends on the state of the broader FreeBSD ecosystem and
  the maturity of audiofs after several real-world cycles.
- **An audio-stack rebuild beyond UTF's needs.** audiofs
  exists to give UTF a clean audio substrate. It does not
  aim to replace OSS for the wider FreeBSD ecosystem; it
  does not aim to compete with sndio or PipeWire as
  cross-application audio servers. It is UTF's audio
  substrate, no more.

## Related work

- `inputfs/docs/inputfs-proposal.md` is the precedent. The
  arguments and migration shape there transfer directly,
  with the audio-data-path question as the substantial new
  addition.
- `docs/UTF_ARCHITECTURAL_DISCIPLINE.md` provides the broader
  framing.
- `docs/Thoughts.md` "Audio as Source of Truth" establishes
  why audio's clock role makes the substrate question
  structural rather than cosmetic.
- `semaaud/docs/SemaAud-Roadmap.md` and
  `semaaud/docs/SemaAud-Phase12-DurablePolicy-Spec.md`
  document the existing daemon whose responsibilities
  semasound inherits.
- `inputfs/docs/adr/0012-stage-d-scope.md` is the model for
  what the Stage F scope ADR will look like once F.0
  produces it.
- `inputfs/docs/adr/0013-publication-permissions.md`
  establishes the permission model that audiofs will follow
  for `/var/run/sema/audio/`. No new ADR needed there;
  audiofs adopts the same convention.
- `shared/CLOCK.md` describes the clock region whose writer
  audiofs takes over in F.4. The wire format does not
  change; only the writer changes.
