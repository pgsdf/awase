# 0013 F.2: events ring

## Status

Accepted, 2026-05-28. Decision-owner ratification. Per ADR 0011, F.2's closure requires an
events ring at `/var/run/sema/audio/events` publishing the four
event categories (stream begin, stream end, xrun, format
change) with monotonic sequence numbers, readable by a consumer
with the deltas correlatable to the F.1 state region. This ADR
records the design decision for that ring. The byte-level
schema lives in `shared/AUDIO_EVENTS.md` (companion to this
ADR, analogous to how `shared/INPUT_EVENTS.md` relates to
inputfs ADR 0002, and how `shared/AUDIO_STATE.md` relates to
ADR 0012).

ADR-before-code discipline holds: this ADR plus the companion
spec are the specification; the kernel-side publish
implementation plus the Zig reader are separate commits that
follow.

This ADR does not reverse, reopen, or amend ADR 0006, ADR 0007,
ADR 0008, ADR 0010, ADR 0011, or ADR 0012. It specifies one
sub-stage (F.2) under the F-stage map as reconciled by ADR
0011, building on the F.1 state region.

## Context

ADR 0011 reframed F.2's closure criteria:

  1. The events ring exists at `/var/run/sema/audio/events`,
     with schema and concurrency model per ADR 0005's events
     surface and ADR 0007's physics-only constraint.
  2. The four event categories are emitted by audiofs: stream
     begin, stream end, xrun, format change.
  3. A reader (initially a diagnostic tool, later semasound)
     can observe events with monotonic sequence numbers and
     physics-level payloads.

F.1 (ADR 0012, bench-verified on pgsd-bare-metal 2026-05-28)
established the state region: the always-fresh snapshot of
controllers and endpoints. The state region reserved a
`last_event_seq` header field, written to 0, for F.2 to
populate. F.2 adds the ordered delta stream that complements
the snapshot.

UTF has a proven events-ring precedent in
`shared/INPUT_EVENTS.md`: a 64-byte header, 64-byte event
slots, power-of-two slot count, lock-free single-producer /
multi-consumer ring with a seq-published-last writer protocol
and a seq-revalidation reader protocol, plus a pollable
notification fd. The decision recorded here is to mirror that
precedent closely (the decision owner chose maximal consistency
with the established substrate over an audio-bespoke design),
adapting only the event taxonomy to audio.

## What audiofs needs to publish at F.2

By the reframed F.2 closure criteria and ADR 0007's physics-only
constraint, the events ring carries:

  - **Ring identity and bookkeeping.** Magic, version,
    ring_valid, event_size, slot_count, writer_seq,
    earliest_seq. (Standard idiom from INPUT_EVENTS.)
  - **Stream lifecycle events.** stream_begin, stream_end, xrun,
    format_change. These describe what a stream did, as
    physics-level facts.
  - **Endpoint lifecycle events.** endpoint_attach,
    endpoint_detach, inventory_full. These describe inventory
    changes, complementing the state region's snapshot.
  - **Per-event timing.** ts_ordering (monotonic kernel ns) and
    ts_sync (audio sample position). ts_sync is load-bearing for
    audio: it ties an event to a position in the clocked-out
    sample stream.
  - **Endpoint correlation.** endpoint_slot, an index into the
    state region's endpoint inventory, so a reader can join the
    event to the endpoint it concerns.

What audiofs does NOT publish at F.2:

  - **Policy.** No "you should resync now", no "switch default
    sink." ADR 0007 places policy in semasound. An xrun event
    reports where the gap was; semasound decides what to do.
  - **Audio data.** The ring carries metadata about streams, not
    samples.
  - **The user-control surface.** F.3.b decides that; the ring
    is read-only notification.

## Decision

### 1. Path, structure, lifecycle

`/var/run/sema/audio/events`, created mode 0644 root:wheel by
audiofs on module load, in the same directory as the state
file. A 64-byte header plus a power-of-two array of 64-byte
event slots. v1: 256 slots, total 16,448 bytes.

On module unload the file is invalidated (ring_valid set to 0)
and closed, not unlinked, matching the F.1 state file and
inputfs (the established invalidate-and-close substrate
pattern; see F.1-fu1 disposition).

### 2. Schema

Header and event-slot layouts are specified byte-for-byte in
`shared/AUDIO_EVENTS.md`. Magic `0x41554556` ("AUEV"), version
1. Event slot carries seq, ts_ordering, ts_sync, endpoint_slot,
source_role, event_type, flags, and a 32-byte payload.

### 3. Event taxonomy (role plus event_type, mirroring inputfs)

Two-level dispatch on (source_role, event_type), as
INPUT_EVENTS does:

  - **source_role 1 = stream**: event_type 1 stream_begin, 2
    stream_end, 3 xrun, 4 format_change.
  - **source_role 2 = endpoint-lifecycle**: event_type 1
    endpoint_attach, 2 endpoint_detach, 3 inventory_full.

Payload layouts per `shared/AUDIO_EVENTS.md`. The two-level
dispatch is retained even though audio currently has fewer
event families than input, because (a) it keeps the wire format
structurally identical to INPUT_EVENTS so a single mental model
and potentially shared reader scaffolding apply across
substrates, and (b) it leaves room for future audio roles
(capture streams, MIDI, control-surface events) without a
format break.

### 4. xrun carries the physics-level gap position now

The xrun payload reserves `gap_sample_pos` (u64, the
sample-stream position where the gap began) and `gap_frames`
(u32, gap size), correlatable with the event header's ts_sync.
Per ADR 0007, the xrun is reported as a physics fact: audiofs
says where and how big the gap was; semasound decides the
policy response.

This field is specified now, at F.2, even though real xrun
detection is F.3.d (it requires the interrupt-driven position
tracking of F.3.c). Reserving the layout now means F.3.d
populates an existing field rather than changing the wire
format. The decision owner chose this explicitly: the schema
should express the physics-fact framing from the start, so the
events surface is designed around ADR 0007 rather than retrofit
to it.

### 5. ts_sync references the audio sample clock

Each event carries ts_sync, the audio-sample-position clock.
audiofs is the audio clock source (ADR 0003; F.4 makes audiofs
the clock writer). Until F.4, ts_sync is 0 (no clock authority
yet). The field is reserved now so the wire format is stable
across F.2 -> F.4. After F.4, an event's ts_sync ties it to an
exact clocked-out sample position, which is what makes the xrun
gap position meaningful.

### 6. Correlation with the state region

The events publisher writes the state region's last_event_seq
after publishing each event and updating state (step 6 of the
writer protocol in `shared/AUDIO_EVENTS.md`). A reader using
both surfaces knows the state it reads reflects events through
last_event_seq. This closes the loop the F.1 state region left
open (last_event_seq was reserved-and-zero in F.1).

### 7. Pollable notification fd

audiofs exposes a pollable fd supporting kqueue / EVFILT_READ,
mirroring inputfs ADR 0021's `/dev/inputfs_notify`. A read
returns the current writer_seq. This lets semasound wake on
event arrival rather than polling the ring. The device name
(`/dev/audiofs_notify`, by analogy) and the kernel mechanism
(a cdev with d_poll and d_kqfilter, knote list woken from the
publish path) follow the inputfs notify-cdev implementation
that AD-41.3 landed and verified.

### 8. What F.2 actually emits vs. reserves

F.2's implementation emits the **endpoint-lifecycle** events
immediately, because endpoints exist as soon as controllers
attach (F.1 already enumerates them). The **stream** events
(begin/end/xrun/format_change) have their schema fully
specified by F.2 but are not emitted until the data path
creates real streams:

  - stream_begin / stream_end: emitted once F.3.a (continuous
    streaming) creates start/stop-able streams.
  - format_change: emitted once F.3.e (format negotiation)
    can change a running stream's format.
  - xrun: emitted once F.3.d (underrun detection) runs in the
    F.3.c interrupt path.

This is the same pattern F.1 followed (schema complete, some
fields populated only when later sub-stages provide the data).
F.2 closes on the ring existing, the endpoint-lifecycle events
flowing, and the schema for stream events being in place and
reader-parseable.

## Why this design

**Why mirror INPUT_EVENTS rather than design audio-bespoke.**
The decision owner chose maximal consistency. A reader author
(and semasound itself) deals with one ring model across input
and audio: same header shape, same slot mechanics, same writer
and reader protocols, same overrun-resync-from-state pattern.
The cost (a two-level dispatch where audio could use a flat
one) is small and buys structural uniformity plus headroom for
future audio event families.

**Why 256 slots, not inputfs's 1024.** Audio lifecycle events
are far rarer than input events. Endpoint enumeration is a
handful at attach; stream begin/end and format change are
occasional; xruns happen only under load. 256 slots is ample
and keeps the region at 16 KB. The header-driven slot_count
means growing it later is a version bump, not a consumer
rewrite.

**Why reserve xrun gap position and ts_sync now.** Both express
ADR 0007's physics-fact framing and ADR 0003's clock model.
Designing them in from F.2 means the later sub-stages (F.3.d
xrun, F.4 clock) populate existing fields rather than breaking
the wire format. The events surface is thus designed around the
physics/semantics boundary from the start.

**Why invalidate-and-close on unload, not unlink.** Consistency
with the F.1 state file and inputfs (F.1-fu1 disposition). The
file lives in tmpfs-backed /var/run, is overwritten on next
load, and cleared at reboot.

## What this commits

### Closure criteria for F.2

F.2 closes when:

  1. The events ring exists at `/var/run/sema/audio/events`
     with magic 0x41554556 and version 1, 16,448 bytes.
  2. The schema in `shared/AUDIO_EVENTS.md` is implemented in
     the kernel publish path.
  3. On MOD_LOAD with the pgsd-bare-metal attachment,
     endpoint_attach events are published for the enumerated
     endpoints, ring_valid becomes 1, and writer_seq reflects
     the count.
  4. The state region's last_event_seq is updated by the
     events publisher and matches the ring's writer_seq after
     enumeration.
  5. A reader (a diagnostic tool over the Zig EventRingReader,
     or semasound later) can drain the ring, observe the
     endpoint-lifecycle events with monotonic sequence numbers,
     and parse the stream-event schema (even before stream
     events are emitted).
  6. The pollable fd wakes a reader on event publication.

### What F.2 implementation lands

  - `shared/AUDIO_EVENTS.md`: the byte-level schema (this
    commit; the spec).
  - Kernel publish code in `audiofs/sys/dev/audiofs/`: the ring
    region build, the publish path (seq-last writer protocol),
    endpoint-lifecycle event emission wired into the attach /
    detach points alongside the F.1 state republish, the
    last_event_seq update into the state region, the notify
    cdev with d_poll / d_kqfilter. A new `audiofs_events.h`
    for the ring struct layout with _Static_asserts, mirroring
    audiofs_state.h.
  - Zig reader in `shared/src/audio.zig`: EventRingReader
    (and an EventRingWriter sketch for tests), mirroring the
    inputfs ring reader, with unit tests.

The implementation lands as separate commits after this ADR is
ratified. This commit is specification only.

### What F.2 implementation does NOT land

  - Real stream events (begin/end/xrun/format_change emission).
    The schema is specified; emission is F.3.a/d/e.
  - The audio data path. F.3.
  - Clock writing (ts_sync stays 0 until F.4).
  - A user-control surface. F.3.b.

## Relationship to ADR 0007

The events ring is physics-only. Events report hardware facts
(a stream started; an underrun occurred at sample position P of
size N frames). They do not carry policy. semasound consumes
the physics and decides responses. The xrun-as-physics-fact
framing is ADR 0007's xrun stress case made concrete in the
wire format.

## Relationship to ADR 0003

ts_sync references the audio sample clock ADR 0003 specifies.
F.2 reserves the field; F.4 (audiofs becomes clock writer) is
what makes it non-zero. The events ring does not itself write
the clock region; it references the clock's sample position.

## Relationship to ADR 0005

ADR 0005 specifies semasound's userland architecture, including
its events surface. This ADR's ring is designed to be the
surface semasound reads. It does not pre-empt semasound's
internal design; it provides the kernel-published event stream
semasound consumes.

## Relationship to ADR 0008 / ADR 0011 / ADR 0012

ADR 0008 sequenced F.2 as stream lifecycle events. ADR 0011
reframed the closure criteria and set the F.1 -> F.2 dependency.
ADR 0012 (F.1) established the state region and reserved
last_event_seq for F.2. This ADR specifies F.2 per those
criteria, closing the last_event_seq loop and adding the delta
stream that complements F.1's snapshot.

## Relationship to inputfs ADR 0021

The pollable notification fd mirrors inputfs's
`/dev/inputfs_notify` (ADR 0021, implemented and verified in
AD-41.3). audiofs uses the same cdev-with-kqfilter pattern for
its `/dev/audiofs_notify`. This is deliberate reuse of a proven
mechanism, not a parallel invention.

## Consequences

### What this enables

  - **semasound has an event stream to consume.** F.5 semasound
    bring-up can read endpoint lifecycle now and stream events
    as F.3 provides them.
  - **The state/events correlation is complete.** last_event_seq
    ties the snapshot to the delta stream.
  - **F.3.d xrun and F.4 clock populate reserved fields**
    rather than changing the wire format.

### What this commits

  - The events ring is a public surface. Schema changes after
    implementation require a version bump.
  - The event taxonomy (two roles, the listed event_types) is
    the v1 set. New event_types or roles are backwards-
    compatible additions; changing existing ones is a version
    bump.
  - 256 slots, 64-byte events are the v1 sizes; changing them
    is a version bump.

### What this does not address

  - The kernel seqlock/atomic primitives (the implementation
    commit picks them; the spec defines the protocol).
  - Whether the diagnostic reader is in scope for F.2 closure
    (useful, but the closure criteria require the ring plus a
    parseable schema, not necessarily a finished CLI tool).
  - F.3 onward.

## What this document is not

  - Not the implementation. The kernel publish path, the notify
    cdev, and the Zig reader are separate commits.
  - Not a replacement for ADR 0005 (semasound). It specifies the
    surface semasound reads, not semasound.
  - Not the F.1 state region (ADR 0012). It is the complementary
    delta stream; the two surfaces are correlated by
    last_event_seq.
  - Not a softening of ADR 0007. The ring is physics-only by
    design, field by field.
