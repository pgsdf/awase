# 0005 Userland architecture: semasound

## Status

Accepted, 2026-05-11.

## Context

This ADR specifies the architectural shape of the userland
audio service that the audiofs proposal calls `semasound`.
It is the natural successor to ADR 0004 ("Mixer location"):
once the substrate is settled as single-writer, the userland
broker that does the writing needs its own design.

The discovery document
(`audiofs/docs/audio-design-space.md`) identifies this as an
ADR pulled out of the implicit framing in the audiofs
proposal, where semasound was treated as "semaaud minus OSS
plus audiofs." That framing understated the work involved.
semaaud, as currently implemented, runs a target-based
model where each target accepts one client at a time and
routes between targets via policy-driven preemption.
semasound, as the audiofs proposal commits to, runs a
mixer model where multiple concurrent clients per target
have their streams mixed in userspace. These are
substantially different daemons.

This ADR specifies semasound's architectural shape: what it
inherits from semaaud, what is genuinely new, what its IPC
looks like, and where its boundaries are. It does not
specify the IPC wire format, the mixing algorithm, the
sample-rate conversion strategy, or the specific event
schema. Those belong in follow-on documents under
`semasound/docs/` and in the userland-state region spec
(`shared/AUDIO_*.md`, analogous to `shared/INPUT_*.md`).

## What semaaud does today

The base from which semasound evolves is semaaud as it
exists at the time of this ADR (Phase 12, durable policy
validation):

  - **Two named targets**: `default` and `alt`. Each target
    has its own stream socket
    (`/tmp/semaud-default.sock`,
    `/tmp/semaud-alt.sock`) and its own runtime state.
  - **One client per target.** A second client connecting
    to the same target either preempts the first
    (policy-driven) or is rejected. There is no
    within-target mixing.
  - **Policy engine**: allow/deny/override/group semantics
    over client labels and classes. Determines whether a
    new connection preempts the existing client, falls
    back to the alt target, or is denied entirely.
  - **Filesystem state surfaces** under
    `/tmp/draw/audio/<target>/`: identity, version,
    capabilities, control, runtime state, policy-valid,
    policy-errors, and a JSON event log on
    `stream/events`.
  - **Control socket** at `/tmp/semaud-control.sock`: a
    line-oriented protocol that exposes runtime state
    queries and policy-reload commands.
  - **OSS backend** in `oss_output.zig`: opens
    `/dev/dsp{N}`, configures format via SNDCTL ioctls,
    writes mixed audio to the device.
  - **Clock writer**: writes `/var/run/sema/clock` from the
    stream worker after each `posix.write` to OSS.

## What semasound becomes

semasound inherits semaaud's target model, policy engine,
filesystem state surfaces, and control socket. It sheds the
OSS backend, the clock writer, and the one-client-per-target
constraint. It gains multi-client mixing within a target,
per-stream state tracking, and a more structured IPC.

The result is a daemon that is recognisably semaaud in its
operator-facing surfaces (the same target model, the same
policy engine, the same filesystem state pattern) but
substantially different inside (multi-client connections per
target, sample-domain mixing, per-stream session state).

### What is inherited verbatim

  - **Target model.** semasound has named targets
    (`default`, `alt`, with the option of more if a
    deployment configures them). Each target has its own
    runtime state and is independently configurable. The
    target is the unit of policy: a client requests a
    target by name when connecting, and policy decides
    whether the connection is allowed against that
    target.
  - **Policy engine.** The Phase 12 durable policy grammar
    is preserved verbatim. Allow / deny / override /
    group semantics carry over; policy file paths,
    validation, the policy-valid and policy-errors
    surfaces all behave as in semaaud.
  - **Control socket.** A control socket continues to
    exist (renamed to `/tmp/semasound-control.sock`).
    The line-oriented control protocol carries over for
    runtime queries and policy reload, with extensions
    for per-stream queries (which clients are
    connected to which target, what their formats and
    volumes are, how many xruns each has experienced).
  - **Filesystem state surfaces.** `/tmp/draw/audio/<target>/`
    continues to publish identity, version, capabilities,
    control, runtime state, policy-valid, policy-errors,
    and the stream event log. The shapes of these files
    are unchanged.

### What is shed

  - **OSS backend.** `oss_output.zig` is removed.
    semasound writes to audiofs's audio data path
    instead, via whatever Q1 (data path) resolves to.
    The format negotiation that semaaud performs against
    OSS via SNDCTL ioctls is replaced by negotiation
    against audiofs (Q4's subject).
  - **Clock writer.** semasound does not write
    `/var/run/sema/clock`. ADR 0003 (clock writer)
    settles this: audiofs writes the clock from kernel
    context. semasound's stream worker has no
    `ClockWriter` and makes no clock-region updates.
  - **One-client-per-target constraint.** Multiple
    clients can connect to the same target and have
    their streams mixed. The preemption logic in
    semaaud's policy engine remains for cases where
    policy says a particular class should preempt; the
    *default* behaviour for normal connections changes
    to additive mixing rather than displacement.

### What is genuinely new

  - **Within-target mixing.** semasound mixes multiple
    concurrent client streams within a target before
    writing the mixed result to audiofs. The mixing
    algorithm itself is deferred to a follow-on
    document; this ADR commits to the existence of
    within-target mixing, not to its specific
    implementation.
  - **Per-stream session state.** Each client connection
    becomes a session with its own state: format,
    volume, sample position, last-event log, xrun
    counter. The session is owned by the client
    connection's lifetime; closing the connection
    destroys the session.
  - **Per-stream addressability.** Tools and consumers
    that want to know "which clients are currently
    connected to the default target, what is each one
    doing" query semasound through the control socket
    and receive structured per-stream information. The
    filesystem layout under `/tmp/draw/audio/<target>/`
    grows a `streams/` subdirectory listing active
    sessions.

## Decision

semasound's architecture is specified by the following
five sub-decisions.

### 1. Per-target listening sockets, multi-connection accept

semasound listens on per-target Unix sockets, one socket
per target:

```
/tmp/semasound-default.sock      (default target)
/tmp/semasound-alt.sock          (alt target)
/tmp/semasound-<custom>.sock     (any operator-configured targets)
```

Each socket accepts multiple concurrent connections.
semasound assigns each accepted connection a stream id
(opaque, monotonically increasing within the daemon's
lifetime) and tracks it in its session table.

The naming convention follows semaaud's existing pattern,
with the daemon name updated. Operators can keep using
the same target names; client code that opens
`/tmp/semaud-default.sock` would only need to update the
path to `/tmp/semasound-default.sock`. The semantics of
which target is which are preserved.

This choice is over the alternative of "one rendezvous
socket, per-stream descriptors handed back" (sndio's
shape). The per-target listener is closer to semaaud's
existing pattern, easier to evolve from the existing
code, and easier for operators familiar with semaaud's
state directories. It is also easier to firewall and
audit: a deployment that wants to disable one target
can just remove its listener.

### 2. Per-connection session structure

For each accepted connection, semasound maintains a
session structure:

```
StreamSession {
    id: stream_id,
    target: target_name,
    client_label: string,        (from policy / connection metadata)
    client_class: string,
    format: AudioFormat,         (rate, channels, bit depth)
    volume: f32,                 (0.0 to 1.0, applied during mix)
    samples_consumed: u64,       (per-stream sample position)
    xrun_count: u32,
    state: Active | Paused | Closing,
}
```

Sessions are accessible to the control socket for
queries. Sessions are addressable in the filesystem
under `/tmp/draw/audio/<target>/streams/<stream_id>/`
with files for the current format, volume, sample
position, xrun count, and last event. The filesystem
addressability is read-only; control happens through
the control socket.

Session lifetime tracks the connection: connection
established → session created; connection closed →
session removed; semasound restart → all sessions
destroyed.

### 3. Within-target mixing happens in semasound

Each target has a mix worker. The mix worker reads from
all active sessions of that target, applies per-session
volume, sums into a per-target mix buffer, applies the
target's master volume, and writes the result to
audiofs. The mix arithmetic is sample-domain,
floating-point intermediate, with overflow clamping at
the output stage.

The specific mixing algorithm (sample-rate conversion
for sessions whose format does not match the target's
output format, the floating-point precision used for the
intermediate sum, the clipping vs soft-clipping policy
at the output) is the subject of a follow-on document
under `semasound/docs/`. This ADR commits to the
existence of mix workers and their architectural role,
not to the specific arithmetic.

The mix worker is one userland thread per target. The
data path from sessions to mix worker is a per-session
ring buffer (or equivalent); the data path from mix
worker to audiofs is whatever Q1 resolves to.

### 4. Policy applies at connection time and at preemption events

The Phase 12 durable policy continues to govern
*whether* a connection is accepted to a target, *which*
target a denied-or-deferred connection falls back to,
and *whether* a new connection's class preempts existing
sessions on the target.

This is a partial change from semaaud's behaviour. In
semaaud, a connection preempts the previous one
unconditionally (since there is only one slot). In
semasound, the default behaviour is additive mixing:
new connections do not preempt existing sessions
unless the policy explicitly says they should. Policy
classes that today encode "preemption priority"
(typically: announcements, alarms) continue to preempt;
classes that today preempt by accident (because there
is no other shape available) become additive instead.

Policy authors targeting semaaud should review their
policies for behaviour changes during migration. A
follow-on document captures the migration semantics;
semaaud's existing policy authors are not numerous
(this is PGSDF infrastructure, not user-facing
configuration), so the migration cost is bounded.

### 5. semasound has no kernel-side responsibilities

semasound is purely userland. It does not load kernel
modules, does not write to kernel substrate regions
beyond audiofs's documented data path, does not own
the chronofs clock region, does not enumerate hardware
devices.

Hardware enumeration, format negotiation against
hardware, the chronofs clock, and the substrate-level
event ring are all audiofs's responsibilities.
semasound queries audiofs through audiofs's userland
interfaces (the future `/var/run/sema/audio/state`
read regions, audiofs control socket if it has one,
the audio-data-path entry point) but does not duplicate
any of audiofs's state.

This boundary is the audiofs/semasound contract. It is
the audio counterpart of the inputfs/semadrawd
contract: kernel substrate publishes authoritative state,
userland service consumes and adds policy.

## Consequences

### What this enables

  - **Q1 (data path) becomes specifiable.** With
    semasound as a single mix-worker-per-target writer
    to audiofs, Q1's design space reduces to "how does
    this one writer talk to audiofs efficiently."
  - **Q4 (format model) becomes specifiable.** Format
    negotiation is between the mix worker (one
    canonical format per target's output) and audiofs.
    Per-session format conversion is a semasound
    concern, internal to the mix worker.
  - **Migration from semaaud is bounded.** Operators
    keep their target names, policy files, control
    protocol expectations, and filesystem state
    surfaces. The migration produces visible changes
    only in the multi-client mixing semantics, which
    is documented and policy-controllable.
  - **Per-stream observability becomes available
    through documented surfaces.** Tools that want to
    know what audio is happening on a system can read
    `/tmp/draw/audio/<target>/streams/` or query the
    control socket. This addresses the "ask
    semasound" pattern that ADR 0004 committed to.

### What this commits

  - **semasound's IPC includes per-target listening
    sockets that accept multiple connections.** Client
    libraries link against a thin semasound client
    library (forthcoming) that handles connection
    setup, format negotiation, and the audio-data
    submission protocol against the per-target socket.
  - **Mixing is in semasound, not in audiofs.** This
    is the userland-side commitment of ADR 0004's
    decision. It is restated here for completeness.
  - **The /tmp/draw/audio/<target>/streams/
    directory comes into existence.** This is a new
    filesystem surface that semaaud does not have.
    Tools that depend on the absence of streams/
    under existing targets (none exist today) would
    break.
  - **Policy semantics change at default behaviour.**
    Existing semaaud policies that relied on
    preemption being unconditional need explicit
    preemption directives to keep that behaviour
    under semasound. Migration documentation
    handles this.

### What this does not address

  - **The mix arithmetic.** Floating-point precision,
    clipping policy, sample-rate conversion algorithm,
    inter-sample interpolation. The follow-on
    document under `semasound/docs/` handles these.
  - **The IPC wire format.** The byte-level structure
    of the per-target socket protocol is the subject
    of a follow-on `semasound/docs/IPC.md` (analogous
    to the inputfs publication-region specs). This
    ADR commits to the architectural shape, not the
    bytes.
  - **The client library.** A `libsemasound` (or its
    Zig equivalent) is forthcoming but not specified
    here. Its interface is bounded by what this ADR
    commits to.
  - **Network audio.** The per-target sockets are
    Unix-domain only. TCP listeners (analogous to
    semadraw's TCP listener for cross-machine UTF)
    are deferred to a future authfs-shaped ADR.
  - **The cutover from semaaud.** When semasound is
    ready, the migration from semaaud to semasound is
    its own deliberate operation, structurally
    similar to AD-2 (semainput retirement). Stage F.6
    of the audiofs proposal handles this.

### Risk: feature creep

semasound's design is more elaborate than semaaud's.
Multi-client mixing, per-stream sessions, per-stream
filesystem addressability, mix workers per target. The
risk is that semasound grows into PulseAudio over time:
network audio, per-application effects, per-stream
equalisers, filter graphs, plugin systems.

The mitigation is the same kind of restraint sndio
exercises: explicit deferral of features that PGSDF
does not need. The audio-design-space discovery
document explicitly notes that PGSDF does not need
network audio, per-application effects, or studio-grade
synchronization. semasound inherits that scope
constraint. New features must justify themselves
against PGSDF's actual use cases, not against
"applications expect this from a Linux audio server."

### Risk: per-stream filesystem state under load

`/tmp/draw/audio/<target>/streams/<stream_id>/` is a
new filesystem surface that grows and shrinks with
client connections. Under high churn (an application
that opens and closes audio sessions rapidly), the
filesystem operations become a real cost.

The mitigation is two-part. First, semasound updates
these files lazily: changes batch into periodic writes
rather than per-event filesystem operations. Second,
semasound's `streams/` directory is on tmpfs (the same
filesystem semaaud's existing surfaces use), so the
operations are memory-fast.

If the per-stream filesystem surface becomes a hotspot
in measurement, the mitigation is to drop it and serve
per-stream state only through the control socket. The
filesystem surface is convenience for diagnostics, not
a load-bearing API.

## What this document is not

  - **A specification of semasound's IPC wire format.**
    The byte structure of the per-target socket
    protocol belongs in `semasound/docs/IPC.md`.
  - **A specification of the mixing algorithm.**
    Floating-point precision, sample-rate conversion,
    clipping policy belong in
    `semasound/docs/mixing.md`.
  - **A specification of the client library.**
    `libsemasound` belongs in its own header /
    documentation; this ADR bounds what its interface
    can do but does not enumerate functions.
  - **A migration guide for semaaud users.** When
    semasound is ready, the migration document is part
    of the cutover (Stage F.6 of the audiofs proposal).
  - **A schedule.** Stage F follows AD-2 and AD-9 per
    the BACKLOG priority list. This ADR records
    architectural commitments; it does not commit start
    dates.
