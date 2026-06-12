# 0004 Mixer location

## Status

Accepted, 2026-05-11.

## Context

This ADR resolves question Q2 from
`audiofs/docs/audiofs-proposal.md`'s "Open architectural
questions" section, in the form reframed by
`audiofs/docs/audio-design-space.md` as the structural fork
between two coherent audiofs architectures.

The proposal frames Q2 as:

> inputfs is the sole writer of `/var/run/sema/input/`;
> semasound being the sole writer to audiofs is the natural
> extension. But: should audiofs allow multiple kernel-space
> producers of audio (each application opening audiofs
> directly)? The answer affects the audio-data-path ADR. The
> inputfs precedent says "one writer, period": applications go
> through the userland daemon. The OSS precedent says "many
> writers, kernel mixes." UTF's discipline points toward the
> former; pragmatism (compatibility with how applications
> expect audio to work) might point toward the latter.

The discovery document of 2026-05-11 reframes this as the
substrate-vs-broker structural fork:

> If audiofs is single-writer (semasound the only writer),
> applications cannot open audiofs directly; they go through
> semasound's IPC. semasound is a broker.
>
> If audiofs is multi-writer (each application opens audiofs
> directly, kernel sees individual streams), applications have a
> direct relationship with the kernel substrate. The mixer
> (still in userland) reads audiofs's per-stream output and
> writes the mixed result back.
>
> A sndio-style design where audiofs publishes per-stream
> metadata while a userland broker handles mixing is exactly the
> multi-writer-with-userland-broker model. It is closer to what
> the kernel-substrate-pattern actually argues for: more
> observable structural state in the kernel, less encoded
> policy.

The discovery document does not pre-empt the decision. It
identifies the two options as architecturally serious and
flags that the fork shapes Q1 (data path), Q4 (format model),
and the userland-side architecture.

The mixing arithmetic itself is not at issue. Both the
proposal and the discovery document agree that mixing is
policy and lives in userland. Kernel-side mixing (the OSS
shape) is not a candidate; ADR 0002 ("OSS coexistence")
already records the discipline argument against keeping OSS
as a fallback. The question Q2 actually asks is **whether
the kernel substrate's view of audio is per-stream or
mixed-output**.

## What the two options look like in practice

### Option A: Single-writer (the proposal's default)

Applications connect to `semasound` (userland) over a Unix
socket. semasound mixes incoming streams in userspace.
semasound is the only process that writes audio data to
audiofs. The audiofs kernel module sees one mixed stream per
output device.

Per-stream observability lives in userland. Consumers that
want to know "what audio streams currently exist" query
semasound. semasound publishes per-stream state to
`/tmp/draw/audio/<target>/` in the existing semaaud pattern,
inherited by semasound.

### Option B: Multi-writer (the discovery alternative)

Applications connect to audiofs directly through per-stream
device nodes (or per-stream regions, depending on Q1's
data-path decision). Each application becomes a stream that
the kernel knows about. audiofs publishes per-stream state
to `/var/run/sema/audio/state` in the inputfs pattern.

A userland mixer process reads from audiofs's per-stream
data path and writes the mixed result back to audiofs through
a separate "device output" data path. Mixing is still
userland; the kernel sees both per-stream input and
mixed-output.

## What favours each

### Favouring Option A

  - **Closer to inputfs precedent in shape.** inputfs has one
    publisher per device (the kernel module attaching to
    hidbus); audio's analogue is one writer per device (the
    userland mixer producing the mixed output). The "one
    writer to the substrate region" pattern transfers
    directly.
  - **Closer to sndio's actual implementation.** sndio's
    kernel side is the raw audio device; `sndiod` (userland)
    has all stream state. Per-stream introspection happens
    against the broker, not the kernel. This is the working
    pattern that real BSD systems run on today.
  - **Smaller kernel surface.** audiofs handles one data
    path (mixed output to hardware). The kernel module's job
    is bounded: receive samples from one writer, deliver to
    the codec, read the position counter for the chronofs
    clock writer (per ADR 0003).
  - **Robust failure mode.** If the userland mixer dies, the
    substrate is empty: no streams exist anywhere. The
    failure is total but clean. There is no in-between state
    where the kernel has streams that no userland process
    is consuming.
  - **No load-bearing consumer of substrate-level per-stream
    state exists today.** The discipline argument for
    substrate-level observability is real in principle but
    has no concrete client. chronofs needs the clock (which
    ADR 0003 provides regardless of Q2's answer); semadraw
    and semainput do not need audio-stream metadata; no
    monitoring or auditing daemon currently consumes
    `/var/run/sema/audio/state`.

### Favouring Option B

  - **Substrate-level per-stream observability is structurally
    better.** A future UTF-aware consumer that wants to know
    what audio streams exist can read the substrate region
    rather than asking the userland broker over IPC.
  - **Less coupling to a specific userland design.** A
    distribution that builds on UTF could provide a
    different mixer (or no mixer at all, for a
    single-stream-only system) without changing what audiofs
    does. The substrate's contract is per-stream regardless
    of who does the mixing.
  - **Survives mixer crash with state preserved.** If the
    userland mixer dies, the per-stream regions in the
    kernel persist. Applications can keep writing samples
    (which go nowhere until the mixer restarts, but the
    stream identity is preserved). This is arguably worse,
    not better, because the dangling-stream state is its
    own failure mode; but it is a different shape of
    failure that some operators might prefer.
  - **The discipline argument as the proposal originally
    framed it.** The proposal's "per-stream state lives
    nowhere addressable" was filed as one of the six concrete
    mismatches with OSS that motivated the audiofs work. If
    this mismatch is real, Option B is the resolution; Option
    A re-creates the mismatch in a different process boundary.

## Decision

**Option A: single-writer.** semasound is the sole writer to
audiofs's audio data path. Applications connect to semasound
via Unix socket; semasound mixes; semasound writes the mixed
output to audiofs. The kernel substrate sees one mixed stream
per output device.

This decision is on architectural-quality grounds, not on
architectural-discipline grounds: the discipline argument for
Option B is real, but the practical consequences of Option A
match the project's needs better. The decision is summarised
by four observations.

**One.** The chronofs clock writer (ADR 0003) operates
identically under both options: the kernel reads the codec's
position counter on audio interrupt regardless of how
upstream data flows. The "kernel-side authoritative state"
property that motivated the proposal's discipline argument is
satisfied for the *clock* by ADR 0003, independent of Q2.

**Two.** No load-bearing consumer of substrate-level
per-stream state exists in the project today. The
"per-stream state lives nowhere addressable" complaint in
the proposal is correct as stated, but its consequences are
hypothetical: no existing UTF daemon or tool consumes
substrate-level per-stream audio state. Option B pays a real
kernel-complexity cost to provide a feature with no current
consumer.

**Three.** Option A's failure mode is cleaner. If semasound
dies, audio stops: substrate is empty, applications get
ECONNRESET on their IPC sockets, the situation is
unambiguous. Option B's mixer-dies-but-streams-persist state
is its own failure shape, which an operator must reason about
separately.

**Four.** Option A matches sndio's working implementation.
sndio is the closest reference architecture to UTF's audio
needs (small API, privilege-separated, explicit timing model,
deliberate omission of features UTF doesn't need); its
single-writer-to-kernel shape has been validated in real BSD
deployments for over a decade. Option B's
multi-writer-with-mixer-feedback structure has no real-world
reference implementation in this shape.

### What this decision means concretely

  - **audiofs's audio data path is single-writer.** Whatever
    Q1 (data path) resolves to (tmpfs ring, kernel-mapped
    DMA, hybrid), the path between userland and the codec
    has one userland writer per output device. Q1's design
    space is bounded accordingly.

  - **semasound is a broker.** Applications open Unix
    sockets to semasound, not device nodes in audiofs.
    semasound's IPC protocol (separate from audiofs's
    substrate contract) handles per-application volume,
    routing, format negotiation, and mixing. The userland-
    architecture ADR (the next ADR in the sequence, per the
    discovery document) specifies semasound's shape.

  - **Per-stream observability lives in userland.** semasound
    publishes per-stream state to `/tmp/draw/audio/<target>/`,
    inheriting the existing semaaud pattern. Consumers that
    want stream metadata query semasound, not the substrate.
    audiofs publishes only what the substrate-level view
    actually contains: device inventory, current
    mixed-stream state per device, and the chronofs clock.

  - **`/var/run/sema/audio/state` and
    `/var/run/sema/audio/events` are scoped accordingly.**
    These regions carry device-level information (which
    devices exist, which is the active output, what its
    sample rate is, has there been an xrun) rather than
    per-stream information. The wire format ADR (a future
    `shared/AUDIO_STATE.md` analogous to inputfs's
    `shared/INPUT_*.md`) specifies the contents at this
    granularity.

### What would change this decision

This ADR can be revisited if a concrete UTF consumer emerges
that needs substrate-level per-stream state. Examples that
would qualify:

  - A monitoring daemon that audits per-stream sample-rate
    consistency across the system without trusting
    semasound's reporting.
  - A security tool that needs to verify which uid is
    producing audio without going through a userland
    mediator.
  - A multi-machine UTF deployment (post-authfs) where
    per-stream state needs to be observable across the
    network through the substrate layer rather than through
    a per-machine semasound's IPC.

If such a consumer enters the design with concrete
requirements, the Q2 question can be reopened with the same
candidates. Option B remains a coherent design; this ADR
records that Option A is the right answer for the project's
state today, not that Option B was wrong on the merits.

## Consequences

### What this enables

  - **Q1 (data path) becomes tractable.** With single-writer
    settled, Q1's enumeration (tmpfs ring vs kernel-mapped
    DMA vs hybrid) operates within a known structural
    shape. The Q1 ADR can land without re-litigating Q2.
  - **Q4 (format model) becomes tractable.** With semasound
    as the sole writer, format negotiation happens between
    semasound and audiofs at one boundary, not at multiple
    application-to-substrate boundaries.
  - **The userland-architecture ADR has a clear scope.**
    semasound is a broker that mixes. The next ADR
    specifies its IPC protocol, its per-stream state
    model, its volume / routing / format-negotiation
    interfaces, and how applications discover and connect
    to it. These are all userland-side decisions.
  - **AD-3's BACKLOG entry's framing remains correct.**
    "audiofs replaces OSS for UTF-aware applications" is
    the right characterisation: audiofs is the kernel-side
    substrate; semasound is the userland-side audio
    service; together they replace what OSS did, in the
    shape UTF's discipline calls for.

### What this commits

  - **Applications targeting UTF audio talk to semasound,
    not audiofs.** UTF-aware applications that want to play
    or record audio link against a semasound client library
    and connect to semasound's Unix socket. They do not
    open device nodes in audiofs.
  - **OSS compatibility for legacy applications goes
    through OSS, not through audiofs.** Per ADR 0002, the
    end-state has audiofs owning the device exclusively
    and OSS unloaded. Legacy applications that expect
    `/dev/dsp` either run on a separate OSS-loaded host or
    migrate to use semasound's client library. audiofs is
    not an OSS emulator.
  - **No substrate-level per-stream metadata.** Tools that
    want per-stream visibility (which application is
    producing audio, what is its current sample rate, has
    it underrun) query semasound's IPC or read its
    published state under `/tmp/draw/audio/<target>/`.

### What this does not address

  - **Q1 (data path).** Single-writer constrains the
    answer space but does not pick within it.
  - **Q4 (format model).** Single-writer simplifies the
    format-negotiation boundary but does not specify what
    semasound and audiofs negotiate.
  - **Q5 (latency targets).** Downstream of Q1.
  - **The userland-architecture ADR.** semasound's specific
    IPC shape, per-stream state model, and client-library
    interface are not specified here. They belong in the
    next ADR in the sequence.
  - **Network audio.** semasound, like sndio, can in
    principle accept TCP connections; that is a future
    consideration tied to authfs, not part of Q2.

### Risk: semasound becomes load-bearing

**Scope tightened by ADR 0007 (2026-05-17).** This section
characterises semasound as a mixer that is load-bearing.
ADR 0007 (physics/semantics boundary), following from ADR
0006, established that semasound is not merely load-bearing
but is the *entire semantic audio system*: mixing,
resampling, format negotiation, drift estimation, timing
prediction, and compatibility policy all concentrate there,
with no kernel fallback by design. Read the analysis below
as understating the concentration; the accurate statement
is in ADR 0007's "accepted costs" section. ADR 0004's
mechanism (single-writer, userland mix) is unchanged; only
this risk section's characterisation of semasound's scope
is superseded.

The decision concentrates audio responsibilities in a single
userland daemon. If semasound has bugs, audio fails. If
semasound is killed, audio stops. If semasound's IPC protocol
changes incompatibly, every UTF audio application needs to
update.

This is the same shape of risk the project accepts for
inputfs's userland clients (semadrawd, semainput) and for
chronofs's userland reader (every other daemon). The mitigation
is the same: keep the userland service simple, well-tested, and
well-specified; keep its IPC protocol stable; treat it as
infrastructure rather than as a feature surface.

The semasound design ADR (next in the sequence) carries
responsibility for making this concrete: a small IPC, a
stable client library, deliberate restraint on feature
addition.

## What this document is not

  - **A specification of semasound's IPC protocol.** The
    decision says "applications connect to semasound";
    *how* they connect, what messages they exchange, what
    state they observe, is the next ADR's job.
  - **A claim that Option B is wrong.** Option B remains a
    coherent design. The decision records a project-state
    judgement, not a discipline judgement.
  - **An obligation to track sndio's API.** The decision
    cites sndio as a reference for the shape of single-
    writer-broker design that has been validated in real
    BSD systems. semasound is not required to match
    sndio's API. The semasound design ADR makes its own
    interface choices.
  - **A constraint on AD-3's broader scope.** AD-3
    ("replace OSS dependency") remains the BACKLOG entry
    that tracks the audiofs work; this ADR resolves one
    architectural sub-question within AD-3's scope.
