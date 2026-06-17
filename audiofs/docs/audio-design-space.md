# UTF Audio: Design Space and Discovery

## Status

Discovery document, 2026-05-11.
Not an architectural decision. Not a specification.

## What this document is

A working analysis of the design space for audio in UTF. The
existing `audiofs/docs/audiofs-proposal.md` (Stage F, 2026-04-29)
takes a strong position: kernel-side substrate, modelled after
inputfs, with a userland daemon (`semasound`) that owns mixing
policy. That document was written before the broker-versus-
substrate question had been examined explicitly. The 2026-05-11
working session opened that question by asking what UTF actually
needs from audio, what models exist for solving the problem, and
which fit UTF's discipline cleanly versus by accommodation.

The output of this document is not a decision. The output is a
clearer picture of the question, a survey of how others have
solved analogous problems, and a recommendation for what ADRs
should follow once the framing settles. ADR documents and the
number of ADR documents come from discovery, not from a
pre-allocated slot list.

The voice and shape match `docs/Thoughts.md` (chronofs's
discovery document) more than it matches an ADR. Discovery
documents are exploratory; they are willing to come back and say
the existing proposal got something wrong if that is where the
analysis leads. They do not pretend to be specifications they are
not.

## What UTF actually needs from audio

The starting question, before any reference to OSS, sndio,
audiofs, or anything else, is: what does UTF actually need from
audio?

### From the substrate's perspective

**Hardware sample-position counter as canonical time.** This is
not negotiable. `docs/Thoughts.md` commits chronofs to "audio as
source of truth": the global monotonic clock is driven by the
audio hardware's sample counter. Whatever audio architecture UTF
adopts must let the sample-position counter be read with low
latency and written into the chronofs clock region as the
authoritative time source. A pure-userland broker that hides the
hardware sample position behind its own buffering model is
incompatible with this commitment.

**Specifiable behaviour.** UTF's discipline (in
`docs/AWASE_ARCHITECTURAL_DISCIPLINE.md`) says external code stays
out of the guarantee path. If audio behaviour is determined by
"whatever the loaded audio driver happens to do," UTF's audio
behaviour is not specifiable; it depends on `snd(4)` driver
choices, codec firmware behaviour, and so on. The discipline
constraint is to expose enough hardware-level facts that UTF can
reason about what is happening, even when the underlying drivers
are not under UTF's control.

**Stable contracts.** The boundary between kernel and userland,
or between substrate and broker, must be documented and not
change underneath consumers. `inputfs/docs/inputfs-proposal.md`
established the pattern: hand-specified byte layouts in
`shared/INPUT_*.md`, fixed offsets, atomic field updates, no
parser on the read path. Whatever audio model UTF adopts must
have a contract of similar character at the substrate boundary.

**Lifecycle observability.** Other UTF consumers need to be able
to ask "what audio streams exist, what are their formats, when
did they start, when did they end, has there been an xrun?" The
existing proposal handles this through `/var/run/sema/audio/` in
the inputfs pattern. A broker model handles it differently
(through introspection RPCs against the broker). Either is
acceptable; the requirement is that observability exists.

### From applications' perspective

**Notifications and system sounds.** Terminal bells, error tones,
notification chimes. These are short, infrequent, mixable with
other audio without conflict. They can use a "fire and forget"
shape; they do not need real-time guarantees.

**Application audio playback.** Music players, video conferencing
playback, game audio. These run for extended periods with steady
sample throughput. They tolerate ~20-50 ms of latency comfortably.
They expect to coexist with other audio (the user might want
music low while a notification plays high).

**Voice capture.** Microphone for voice input, video conferencing,
recording. Input rather than output. Single producer (the
hardware) typically, single consumer (the application capturing).
Latency requirements similar to playback.

**Music creation, real-time monitoring.** Live audio processing
where a microphone-input-to-speaker-output round trip must be
under ~10 ms or the player hears their own voice as an echo.
This is the JACK / pro-audio use case. PGSDF's user base is
scientific computing, not music production; this is plausibly
out of scope for the v1 audio substrate.

**METOC visualization sonification.** A research direction in
auditory display of weather data: not a v1 requirement, but worth
keeping in mind as a future possibility. If this becomes real, it
needs precise sample-accurate scheduling (which is the same
requirement as music creation, plus chronofs-tied event delivery).

### From PGSDF's perspective specifically

PGSDF as a distribution serves scientific and METOC work; the
typical workload is visualization and analysis, not music
production. Audio is supporting infrastructure for telecom,
recording, occasional sonification, and desktop sound. The audio
budget (in development-attention terms) is bounded; we should
not spend large effort on professional-music-production-grade
features unless they fall out naturally from a design driven by
the simpler use cases.

### What we do not need

**Network audio transparency.** sndio and Plan 9 both support
audio across network boundaries. PGSDF has no current requirement
for this. The (eventual) authfs work might surface a need for
remote audio in cross-machine session sharing, but that is far
future and should not constrain v1 audio design.

**Per-application advanced effects.** Reverb, EQ, pitch shifting.
PipeWire ships with these; sndio explicitly does not. PGSDF does
not need them.

**Studio-grade synchronization.** Sample-accurate alignment
between audio and external MIDI gear, MIDI Time Code, MMC. JACK
and sndio support this; OSS does not. PGSDF does not need it.

## The chronofs constraint, examined more carefully

The chronofs commitment to audio-as-canonical-clock is the most
load-bearing constraint in this analysis. It deserves a closer
look.

What chronofs actually needs is the hardware's frame counter:
the count of frames the codec has clocked out, monotonically
advancing, queryable with low latency, written into
`/var/run/sema/clock` as `samples_written`. The codec hardware
itself maintains this counter internally; FreeBSD's `snd(4)`
exposes it through buffer-pointer tracking. Reading it requires
either a kernel module that talks directly to `snd(4)`, or a
userland process that knows the OSS query for it.

Three implementation shapes can satisfy this:

  - A kernel module (audiofs or equivalent) reads the counter
    on each audio interrupt and writes the chronofs clock
    region directly. The userland audio process is not in the
    clock-writer path.
  - A userland process queries the counter through OSS
    (`SNDCTL_DSP_GETOPTR`) and writes the chronofs clock
    region from userland. This is the current semaaud
    arrangement.
  - A userland process queries the counter through some
    broker's API (sndio's `sio_onmove` callback, for example)
    and writes the chronofs clock region from userland. This
    is the broker-style equivalent of the current semaaud
    arrangement.

The audiofs proposal argues for option 1 on accuracy grounds:
each layer between the codec and the clock-writer adds latency
and uncertainty. The argument is real but the magnitude is
small: OSS's `SNDCTL_DSP_GETOPTR` is a syscall away from the
hardware counter; the latency is single-digit microseconds. For
chronofs's purposes (frame scheduling at ~16 ms intervals,
frame-position queries to align graphics to audio), microsecond-
level error in the clock writer is invisible.

What does matter is **stability of the path**. If the clock
writer is in userland and the userland process can be killed,
restarted, scheduled out, or change its query rate, the clock
region's update cadence becomes load-dependent. If the clock
writer is in the kernel, the cadence is set by the audio
interrupt rate, which is hardware-determined and stable.

This is a real argument for kernel-side clock writing, but it
does not require the entire audio data path to be in the kernel.
A minimal audiofs that *only* writes the clock from kernel
context, while the audio data path runs through a userland
broker, would satisfy chronofs's requirement. This decouples the
clock-writer question from the data-path question, which the
existing proposal had bundled together under "audiofs replaces
OSS for UTF."

### The "shape" of audio data versus input data

inputfs's pattern works because input events are structurally
small: a cursor move is 16 bytes, a key event is 8 bytes. The
kernel writing them into a tmpfs ring is cheap. Audio is
fundamentally different. At 48 kHz stereo s16le, sustained data
rate is 192 KB/s per stream. Eight concurrent streams is
~1.5 MB/s. A kernel substrate that publishes audio data through
the inputfs-shaped tmpfs ring is doing real work on every
sample.

This is part of why audio architectures historically diverge
from input architectures even when both are "kernel-side
substrates." OSS publishes audio through `/dev/dsp` as a stream
device, not through a state region. ALSA does similarly with
`snd_pcm`. Neither uses inputfs's "publish state, readers poll"
shape; both use stream-write semantics where the kernel pulls
data as the hardware needs it.

The audiofs proposal's Q1 (data path) is wrestling with this
exact question: tmpfs-ring vs DMA-mmap vs hybrid. The honest
answer might be that the inputfs pattern does not transfer
cleanly to audio, and the audiofs substrate's data path has to
look more like OSS's `/dev/dsp` than like inputfs's
`/var/run/sema/input/state`.

This is the place where the audiofs proposal might be reaching
beyond where the inputfs precedent actually carries.

## Survey of the design space

Each model below is described in terms of where it puts the
authoritative state, where it does mixing, how it handles the
clock, and how it relates to UTF's needs.

### OSS (Open Sound System)

The system audiofs is replacing.

**Authoritative state**: the kernel `snd(4)` driver, opaque to
userland.

**Mixing**: kernel-side, optional, invisible. Multiple opens of
`/dev/dsp` get mixed by the kernel; the mixing algorithm is not
specified.

**Clock**: `SNDCTL_DSP_GETOPTR` returns the codec's buffer
position. Userland reads it on demand.

**API shape**: ioctl-based, blocking-write semantics, mmap
optional.

**Relation to UTF**: as the audiofs proposal documents in
detail, OSS does not fit UTF's discipline. The clock writer is
in userland, format negotiation is hidden, mixing is invisible
in-kernel, no published lifecycle, no addressable per-stream
state. None of this is OSS's fault; OSS was designed for a
different problem.

What OSS gets right that other models lose: simplicity of the
write-to-device data path. There is no broker, no per-stream
metadata, no negotiation surface beyond format. Write samples
to `/dev/dsp`; they come out the speaker. The shape is direct,
even if the semantics underneath are underspecified.

### ALSA (Advanced Linux Sound Architecture)

Linux's audio subsystem since the 2.4 era.

**Authoritative state**: kernel ALSA driver (`snd_pcm` core plus
hardware drivers), exposed through `/dev/snd/*` device files.

**Mixing**: split. Kernel-side `dmix` plugin can mix multiple
opens; userspace `pulseaudio` or `pipewire` typically replaces
this.

**Clock**: kernel-side, exposed through `snd_pcm_status` ioctls.
Reasonably accurate.

**API shape**: large. The `libasound` (alsa-lib) library is the
de facto interface; the raw kernel ioctl surface is not used
directly except by the library. The library is itself complex,
implementing a plugin system that lets configuration files
redirect application audio to different sinks (kernel mixer,
PulseAudio, PipeWire, file).

**Relation to UTF**: ALSA's complexity is what UTF's discipline
specifically argues against. The "behaviour is whatever
`alsa-lib` plus the user's `~/.asoundrc` plus the system
configuration does" is the antithesis of specifiable substrate.
ALSA is also Linux-only, which is a non-starter for FreeBSD-
based UTF.

What ALSA gets right: the `snd_pcm` kernel core is a careful
piece of design with a stable interface to drivers. Hardware
manufacturers know how to write ALSA drivers because the
contract is clear at that layer. The mess is in `alsa-lib` and
above, not in the kernel.

### PulseAudio

A userland broker that runs on top of ALSA (or OSS, on FreeBSD).

**Authoritative state**: PulseAudio daemon's internal model.
Applications talk to PulseAudio via a socket protocol; PulseAudio
talks to the kernel via ALSA.

**Mixing**: in the daemon, in userland.

**Clock**: PulseAudio derives its clock from the underlying
ALSA/OSS layer; applications that want hardware-accurate timing
have to work hard to get it.

**API shape**: large. `libpulse` for the synchronous API,
`libpulse-simple` for trivial cases. Asynchronous API for
real-time applications. Configuration is module-based, with
default modules loaded for routing, volume, equalization, etc.

**Relation to UTF**: PulseAudio is the cautionary tale. It
solved a real problem (per-application volume, easy network
audio, hot-swappable devices) but the implementation grew to
contain the world. Latency is not a strength; configuration
debugging is hard; the daemon's failure mode is "audio
disappears." UTF's discipline argues for *less* of this, not
more.

What PulseAudio gets right: per-application volume control as a
substrate-level concept, network audio that mostly works, and a
unified namespace where applications talk to one thing rather
than negotiating between OSS and ALSA and JACK.

### PipeWire

Modern Linux replacement for both PulseAudio and JACK.

**Authoritative state**: PipeWire daemon's graph of nodes and
links. Audio is one type of stream among others (video,
arbitrary data).

**Mixing**: graph-based. Each node can be a producer, consumer,
or processor; the daemon routes streams along the graph.

**Clock**: graph-driven. Nodes negotiate sample rates and
quantum sizes through the graph.

**API shape**: largest yet. Native PipeWire API, plus
ALSA-compatible plugin, plus PulseAudio-compatible plugin, plus
JACK-compatible plugin. Effectively replaces three audio systems
by emulating their interfaces.

**Relation to UTF**: PipeWire's compatibility-by-emulation
strategy is exactly what UTF rejects on discipline grounds. The
emulation layers are correct only to the extent that the
emulator's behaviour matches the original; that match is approximate
across the long tail of edge cases. UTF would not want to depend
on PipeWire as its audio substrate, and PipeWire's design does
not transfer to a UTF-shaped substrate.

What PipeWire gets right: a unified treatment of audio and video
as graph-based streams. The graph model is genuinely novel and
solves real routing problems that PulseAudio could not. UTF's
chronofs/semadraw/audiofs separation could in principle be
expressed as a graph if the project ever wanted to go that
direction; this is worth holding in mind even if v1 does not.

### JACK (Audio Connection Kit)

Pro-audio focused, low-latency, sample-accurate.

**Authoritative state**: JACK daemon (`jackd`), which owns the
audio device exclusively while running.

**Mixing**: applications produce samples that JACK routes.
Mixing happens by virtue of the routing graph rather than as an
explicit step.

**Clock**: JACK's transport model is sample-accurate; clients
schedule events to specific sample positions. Strong guarantees
because the use case demands them.

**API shape**: small and stable. `libjack` is the entire
contract; clients implement a callback that receives input
samples and produces output samples on each cycle. The callback
must complete within the quantum (typically 64-1024 samples).

**Relation to UTF**: JACK's use case (live music production)
overlaps minimally with PGSDF's. The strict callback discipline
is genuinely hard to program against and serves real-time-audio
needs that PGSDF does not have. JACK is also not present on
FreeBSD as a default service; using it would mean shipping it.

What JACK gets right: sample-accurate scheduling as a substrate
property. The transport model is what serious audio work
requires. The callback contract is small and well-defined.

### sndio

OpenBSD's audio system, ported to FreeBSD/Linux/NetBSD.

**Authoritative state**: kernel `audio(4)` driver for hardware
access; userland `sndiod` for shared access. The sndio library
can talk to either, transparent to applications.

**Mixing**: in `sndiod`, when the daemon is running. Direct
hardware access bypasses the daemon and is exclusive (one
client at a time).

**Clock**: `sio_onmove(3)` callback delivers a frame-position
update from the daemon to clients. Sample-accurate within the
daemon's processing window.

**API shape**: small and clean. Roughly: `sio_open` returns a
handle, `sio_setpar`/`sio_getpar` negotiate format, `sio_start`
begins playback, `sio_write` submits samples, `sio_onmove`
provides frame-position updates. About 20 functions total in
the core library.

**Relation to UTF**: this is the interesting one.

sndio is the first audio system in this survey that combines
small API surface with explicit hardware-or-broker
transparency at the application level. An sndio application
does not know whether it is talking to `sndiod` or to the
kernel directly; the choice is made by configuration. This is
structurally similar to UTF's substrate model in that the
*contract* is what matters; the *implementation* (who is on the
other side of the contract) is replaceable.

But sndio's broker model is fundamentally userland: when
`sndiod` is running, it does mixing, sample-rate conversion,
and routing in userspace. The kernel side is just the raw
device. This is the opposite of the audiofs proposal's
"kernel substrate is authoritative" framing.

For UTF specifically: sndio's API surface is small enough to
emulate, and its shape (negotiated parameters, opaque handles,
explicit timing callback) is closer to UTF's discipline than
ALSA or PulseAudio. But adopting sndio's broker model would
require treating the userland process as the authoritative
state holder for audio, which conflicts with UTF's "kernel
substrate is authoritative" pattern from inputfs and drawfs.

What sndio gets right: the API surface (small, stable, well-
documented), the privilege-separated design, the
hardware-or-broker transparency at the application level, the
deliberate omission of network audio and effects to keep the
core simple.

What sndio gets wrong from UTF's perspective: the mixing-in-
userland model means there is no kernel-side authoritative
record of "what audio is being produced." A kernel substrate
that wants to publish per-stream metadata to other UTF
consumers cannot, because the streams exist only inside
`sndiod`'s userland process.

### Plan 9 audio

The reference for "minimal substrate."

**Authoritative state**: kernel `/dev/audio` device file. One
writer at a time.

**Mixing**: not provided. Multiple producers conflict at
`/dev/audio`. If you need mixing, write a userland process that
combines streams and writes to `/dev/audio` as the single
writer.

**Clock**: not exposed as a separate concept. The codec's
sample-position is the codec's; reading it is `audio(3)` device-
specific.

**API shape**: `open()`, `read()`, `write()`, `ioctl()` against
`/dev/audio` and `/dev/audioctl`. About as minimal as it gets.

**Relation to UTF**: Plan 9 is the architectural purist's
position. The kernel publishes the device; userland does
everything else. If you need mixing, that is a userland concern.
If you need per-stream metadata, your userland mixer publishes
it. The kernel does not pretend to know about streams.

This is closest to inputfs's spirit, but it has a real cost:
**no kernel-side per-stream observability**. UTF's discipline
calls for substrate-level addressability of per-stream state;
Plan 9 punts that to userland by design. If UTF wants the
inputfs pattern (publish state, multiple readers can observe)
applied to audio streams, the Plan 9 model alone does not
provide it.

What Plan 9 gets right: ruthless simplicity. The substrate is
the device; everything else is policy. No mixing in the kernel,
no metadata in the kernel, no broker. Userland builds whatever
it needs on top.

### The audiofs proposal

For completeness, included here as one model among others
rather than as the assumed answer.

**Authoritative state**: kernel `audiofs` module, publishing
state to `/var/run/sema/audio/state` (device inventory, stream
inventory, per-stream sample positions) and events to
`/var/run/sema/audio/events` (begin/end/xrun/format-change).

**Mixing**: in `semasound` (userland). audiofs is sole writer to
hardware; semasound is sole writer to audiofs's data path
(however that is implemented). Multiple-producer mixing happens
in semasound.

**Clock**: kernel-side. audiofs reads codec position on audio
interrupt and writes chronofs clock region directly.

**API shape**: not yet specified. The proposal explicitly
defers Q1 (data path) to a future ADR.

**Relation to UTF**: this is what the existing proposal commits
to. It is the inputfs pattern extended to audio. The strengths
and weaknesses are predictable from the inputfs precedent: clean
substrate boundary, kernel-side authoritative state, kernel-side
clock writing, but with the data-path question (Q1) being the
place where the inputfs pattern strains under audio's
fundamentally different shape.

## The discipline question, examined

UTF's architectural discipline argues that "substrate is
authoritative state in the kernel; userland publishes derived
views." inputfs and drawfs both fit this. The question for audio
is whether the discipline argument applies straightforwardly,
or whether audio is structurally different.

### Where the discipline argument is strong

**The clock.** Audio-as-canonical-clock is a chronofs commitment.
Whatever audio architecture UTF adopts, the kernel-side reading
of the hardware sample-position counter and writing it to the
chronofs clock region is the right shape. This is a small piece
of code, pure-function in style, with no policy decisions.

**Hardware enumeration.** Which audio devices exist on the
system, what their capabilities are, when they are
plugged/unplugged. inputfs publishes analogous information for
HID devices. The same shape works for audio.

**Per-stream observability.** "What audio streams currently
exist, what are their formats, when did they start, has there
been an xrun." This is observable substrate-level state, not
policy. The discipline argument applies.

### Where the discipline argument is weak

**Mixing.** Combining multiple producers' samples into a single
output stream is not pure-function; it is policy. Whose audio is
loud, whose is quiet, what happens when the sum overflows, what
ducking rules apply when a notification fires while music plays.
These are user-facing decisions that change with operator
preference, deployment context, and sometimes even time of day.
Putting them in the kernel makes the kernel a place where
policy is encoded, which is the opposite of what UTF's
discipline argues for.

OSS does kernel-side mixing and the audiofs proposal explicitly
rejects this for the same reason. But the proposal then assigns
mixing to `semasound` (userland) without examining whether
semasound's mixing is itself a single-writer to audiofs (current
proposal) or a broker that other applications connect to (sndio
shape). Both are userland; both are off the kernel; the
discipline argument does not distinguish them.

**Sample-rate conversion and format conversion.** Like mixing,
these are policy: which conversion algorithm, what quality vs
latency tradeoff, what happens when the conversion cannot be
done sample-accurate. Userland by discipline.

**Per-application policy.** Per-app volume, per-app device
routing, per-app sample-rate preference. Definitely userland.
The current `semaaud` already implements this; `semasound`
inherits it.

### What the analysis converges to

The discipline argument tells us *some* things about audio go in
the kernel (clock, enumeration, per-stream observability) and
*some* things go in userland (mixing, conversion, per-app policy).
This is a partition, not a single answer.

The actual architectural choice is *how the userland side is
structured*: as a single mixer-daemon writing to a kernel
substrate (the audiofs proposal's `semasound`), or as a broker
that applications connect to (sndio's `sndiod`). Both are
userland. Both keep policy out of the kernel. The difference is
in **whether the kernel substrate sees individual streams or a
mixed output**.

If the kernel substrate sees individual streams (sndio-shaped),
audiofs publishes per-stream metadata directly: each application
that opens audio is a stream the kernel knows about. Mixing
happens between the kernel and the hardware, in `audiofsd` (or
whatever the userland mixer becomes). Per-stream observability
is structural.

If the kernel substrate sees a mixed output (the existing
proposal), audiofs publishes only what `semasound` chooses to
publish about its internal stream graph. Per-stream
observability is conventional, dependent on `semasound` cooperating
with the substrate's metadata model.

This is the fork point. Both are coherent designs. The choice
shapes Q1 (data path), Q2 (mixer location), and the structure of
the userland audio component.

## What the existing proposal might want to revisit

### The mixer question (Q2) is the structural fork

The proposal frames Q2 as "should audiofs allow multiple
kernel-space producers" and treats the inputfs-precedent
("one writer, period") as the leading answer. But this is
exactly the question of "does the kernel substrate see
individual streams or a mixed output."

If audiofs is single-writer (semasound the only writer),
applications cannot open audiofs directly; they go through
semasound's IPC. semasound is a broker.

If audiofs is multi-writer (each application opens audiofs
directly, kernel sees individual streams), applications have a
direct relationship with the kernel substrate. The mixer (still
in userland) reads audiofs's per-stream output and writes the
mixed result back.

The proposal says "UTF's discipline points toward the former"
but does not engage with the broker shape that the latter
opens. A sndio-style design where audiofs publishes per-stream
metadata while a userland broker handles mixing is exactly the
multi-writer-with-userland-broker model. It is closer to what
the kernel-substrate-pattern actually argues for: more
observable structural state in the kernel, less encoded policy.

### The data path question (Q1) might split

The proposal's Q1 enumerates three options for how audio bytes
move between semasound and audiofs: tmpfs ring, kernel-mapped
DMA, or hybrid. All three assume **semasound is the sole
producer**, writing already-mixed audio to audiofs.

If Q2 resolves toward multi-writer, Q1's answer space changes:
the data path from each application to audiofs needs to
support multiple concurrent writers, and the data path from
audiofs to the hardware is downstream of an in-kernel routing
step that the proposal does not currently consider.

This does not invalidate the existing Q1 enumeration; it
suggests that the Q1 ADR cannot be written without first
resolving Q2.

### The "audiofs replaces OSS" framing might be too strong

The proposal title and summary commit to audiofs as a wholesale
replacement for OSS. But on examination, what UTF actually needs
from audio is partitioned: kernel-side clock and per-stream
observability (which OSS does poorly), userland mixing and
policy (which OSS also does, but poorly).

A more honest framing might be: UTF replaces *the kernel-side
parts* of OSS with audiofs. The userland-side parts (mixing,
routing, per-app volume) get replaced by `semasound` regardless
of whether audiofs exists in its current proposed shape or in a
slimmer "kernel-side observability and clock writing only"
shape.

This is a real choice. The slim audiofs is smaller, easier to
specify, and easier to verify. The proposal-shaped audiofs is
larger, owns the audio data path end-to-end, and matches the
inputfs precedent more closely. Both are coherent.

## What discovery surfaces, in summary

Three converging conclusions that did not exist in the proposal:

**1.** The clock-writer responsibility is the load-bearing
kernel-side requirement. Everything else about audio could in
principle live in userland. The decision about how much *more*
than the clock writer to put in the kernel is open.

**2.** The mixer location (Q2) is the structural fork that
shapes everything else, including the data path (Q1) and the
format model (Q4). It is not just one of six independent
questions.

**3.** The sndio reference is more relevant than the proposal
acknowledged. sndio's shape (minimal kernel side, small-API
userland broker, transparent hardware-or-broker access at the
client) is a real candidate model that the proposal dismissed
("does not aim to compete with sndio"). On examination, sndio's
broker model and UTF's substrate model can coexist: UTF's
substrate provides the clock and per-stream observability;
sndio's broker shape (small API, opaque handles, negotiated
parameters) is a good model for the userland audio service.

This does not pre-empt any ADR. It clarifies what the ADRs need
to address.

## Implications for the ADR sequence

The audiofs proposal's ADR plan (`audiofs/docs/adr/0001-stage-f0-plan.md`)
enumerates six ADRs to be written, one per open question.
Discovery suggests the sequence wants modification:

**A. Mixer location (Q2) becomes the lead ADR.** It is the
structural fork; resolving it shapes Q1, Q4, and the userland-
side architecture. Drafting it first forces the question of
"single-writer to substrate vs multi-writer to substrate" to be
answered explicitly.

**B. The clock-writer ADR becomes its own item.** Q1 currently
bundles "data path" with "clock writer," but discovery shows
these are separable. A small dedicated ADR can establish that
the kernel-side clock writer is committed (regardless of how
the rest of audiofs shakes out), which lets chronofs work
proceed without waiting on Q2's resolution.

**C. The userland-side architecture deserves an explicit ADR.**
Currently the proposal assumes `semasound` is shaped as
"semaaud minus OSS plus audiofs." If Q2 resolves toward
multi-writer, semasound's role changes: it becomes a mixer that
reads from audiofs's per-stream regions rather than a sole
writer. This is a structural change in the userland component
that is currently not called out as a separate decision.

**D. Q3 (OSS coexistence) and Q6 (serialization) are unaffected**
by the discovery and can land in their currently-planned
sequence.

**E. Q5 (latency targets) remains downstream of Q1.**

Suggested revised order, replacing the recommendation in
ADR 0001:

  1. **The clock-writer ADR.** Smallest, most independent,
     unblocks chronofs work. (New, was implicit in proposal.)
  2. **Q2 (Mixer location), reframed as the substrate-vs-broker
     question.** The structural fork. Resolves whether the
     kernel sees individual streams or mixed output.
  3. **Q3 (OSS coexistence).** Already accepted as ADR 0002.
  4. **Q6 (serialization).** Recommended posture is defer;
     can land alongside Q3.
  5. **The userland architecture ADR.** Given Q2's answer,
     specifies semasound's shape (sole writer vs broker
     vs mixer-of-streams). (New, was bundled into the
     proposal's "semasound inherits semaaud" framing.)
  6. **Q1 (Data path).** Given Q2 and the userland architecture
     answer, specifies how audio bytes move.
  7. **Q4 (Format model).** Given Q2's answer.
  8. **Q5 (Latency targets).** Given Q1's answer.

Eight ADRs total instead of six. Two new ones (clock writer,
userland architecture) are pulled out of the implicit framing in
the proposal. The remaining six are reordered to match the real
dependency structure.

This is a recommendation, not a decision. The next step would be
to draft the clock-writer ADR (small, mostly mechanical, gets
something landed) and then the Q2-as-substrate-vs-broker ADR
(large, requires real deliberation, is the actual fork).

## What this document is not

  - **A decision.** It does not say which mixer location is
    chosen, which data path is correct, or what the audiofs
    shape becomes. It identifies where the real questions are.
  - **A replacement for the audiofs proposal.** The proposal
    remains the source of truth for what audiofs is and why,
    pending the ADRs that resolve its open questions. This
    document is a discovery layer above the proposal,
    suggesting the question shape has not been fully examined.
  - **A criticism of the existing proposal.** The proposal is
    the right starting document. It identified the right
    questions and committed to the right discipline. What
    discovery suggests is that one of those questions (Q2) is
    structurally more important than the proposal framed it as,
    and that two implicit decisions (clock writer is separable;
    userland architecture is its own decision) want explicit
    treatment.
  - **A schedule.** Stage F follows AD-2 and AD-9 per the
    BACKLOG priority list. No commitment to start dates.

## Related documents

  - `audiofs/docs/audiofs-proposal.md`: the existing proposal.
    Source of truth for what audiofs is committed to; this
    document is discovery above it.
  - `audiofs/docs/adr/0001-stage-f0-plan.md`: the ADR plan.
    Recommends a sequence of six ADRs; this document
    suggests modifying it.
  - `audiofs/docs/adr/0002-oss-coexistence.md`: Q3 resolved.
    Unaffected by this discovery.
  - `docs/Thoughts.md`: chronofs's discovery document. Voice
    and shape model for the present document.
  - `docs/AWASE_ARCHITECTURAL_DISCIPLINE.md`: the discipline
    grounding. The "where the discipline argument is strong /
    weak" section above is a focused application of this
    document to audio.
  - `inputfs/docs/inputfs-proposal.md`: the precedent. The
    discussion of where the inputfs pattern transfers cleanly
    and where it strains is an honest engagement with the
    precedent rather than a wholesale adoption.
