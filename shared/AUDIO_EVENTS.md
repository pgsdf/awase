# Audio Events Region

## Purpose

The audio events region is a lock-free ring buffer written
exclusively by the `audiofs` kernel module and read by all
userspace consumers. It publishes the ordered stream of audio
lifecycle events (stream begin/end, xrun, format change) and
endpoint lifecycle events (attach/detach) as physics-level
facts, with monotonic sequence numbers.

This implements the F.2 publication surface specified in
`audiofs/docs/adr/0013-f2-events-ring.md`. It is the ordered
delta stream; the state file (F.1, `shared/AUDIO_STATE.md`) is
the always-fresh snapshot. A late-joining reader reads the
state file for the current picture and follows the events ring
for subsequent changes.

The region is physics-only per ADR 0007: events report what
the hardware did (a stream started, an underrun occurred at a
specific sample position), not what policy should do about it.
Policy responses live in semasound.

This region mirrors `shared/INPUT_EVENTS.md` in structure
(64-byte header, 64-byte slots, power-of-two slot count,
lock-free single-producer/multi-consumer, role plus event_type
dispatch, pollable fd). The taxonomy differs (audio event
families instead of input ones); the mechanics are identical
for maximal consistency across the Awase substrate.

## Events file

**Default path**: `/var/run/sema/audio/events`

Created (or truncated) by `audiofs` on module load, in the same
`/var/run/sema/audio/` directory as the state file. Mode 0644,
owned root:wheel.

## Relation to the state region

The state region (`shared/AUDIO_STATE.md`) carries the current
snapshot: which controllers and endpoints exist, their
capabilities, and per-endpoint runtime state. The events region
carries the ordered deltas: when a stream began, when an xrun
happened, when an endpoint appeared.

The state region's `last_event_seq` header field is written by
the F.2 events publisher: after publishing event N and updating
the state region, audiofs sets `last_event_seq = N`. A reader
using both surfaces can then correlate: the state it reads
corresponds to all events through `last_event_seq`. Until F.2
lands, `last_event_seq` stays 0.

## Region layout

A fixed 64-byte header followed by a power-of-two array of
64-byte event slots. All multi-byte fields are little-endian.

Total size: **16,448 bytes** (header 64 + 256 slots * 64).

### Header (64 bytes, offset 0)

| Offset | Size | Type | Field | Description |
|--------|------|------|-------|-------------|
| 0 | 4 | u32 | `magic` | `0x41554556` ("AUEV" big-endian mnemonic; on disk `56 45 55 41`) |
| 4 | 1 | u8 | `version` | Region format version (currently `1`) |
| 5 | 1 | u8 | `ring_valid` | `0` = initialising, `1` = live |
| 6 | 2 | u16 | `event_size` | Size of each event slot in bytes (64 in v1) |
| 8 | 4 | u32 | `slot_count` | Number of event slots (256 in v1; power of two) |
| 12 | 4 | u32 | `_pad0` | Reserved, zero |
| 16 | 8 | u64 | `writer_seq` | Sequence number of the most recently published event (atomic) |
| 24 | 8 | u64 | `earliest_seq` | Sequence number of the oldest event still in the ring |
| 32 | 32 | u8[32] | `_pad1` | Reserved, zero |

`slot_count` is a power of two. Consumers compute slot index as
`seq & (slot_count - 1)`. Readers respect `event_size` and
`slot_count` from the header rather than hard-coding v1 values.

The v1 slot count is 256 (not inputfs's 1024). Audio lifecycle
events are far less frequent than input events: a handful at
attach, then occasional stream-begin/end and format-change, and
xruns only under load. 256 slots is ample headroom while
keeping the region at 16 KB. A future version can grow it; the
power-of-two-and-header-driven design makes that a version bump,
not a consumer rewrite.

### Event slot (64 bytes each, starts at offset 64)

| Offset (rel) | Size | Type | Field | Description |
|--------------|------|------|-------|-------------|
| 0 | 8 | u64 | `seq` | Sequence number of this event |
| 8 | 8 | u64 | `ts_ordering` | Ordering clock timestamp (monotonic kernel ns) |
| 16 | 8 | u64 | `ts_sync` | Sync clock position (audio samples clocked out), or `0` if unavailable |
| 24 | 2 | u16 | `endpoint_slot` | Index into state region endpoint inventory (`0xFFFF` = not endpoint-specific) |
| 26 | 1 | u8 | `source_role` | Event origin role (`1`=stream, `2`=endpoint-lifecycle) |
| 27 | 1 | u8 | `event_type` | Per-role event variant (see below) |
| 28 | 4 | u32 | `flags` | Bit 0 = synthesised, bit 1 = coalesced; others reserved |
| 32 | 32 | u8[32] | `payload` | Role-specific payload (layout per `event_type`) |

`ts_sync` is the audio-sample-position clock. For audiofs this
is load-bearing: audiofs is itself the audio clock source (per
ADR 0003, F.4 makes audiofs the clock writer), so an event's
`ts_sync` ties the event to an exact position in the clocked-out
sample stream. Until F.4, `ts_sync` is `0` (no clock authority
yet); the field is reserved now so the wire format is stable
across F.2 -> F.4.

`endpoint_slot` identifies which endpoint the event concerns,
as an index into the state region's endpoint inventory. A
reader correlates by reading the same-indexed endpoint slot in
`/var/run/sema/audio/state`. `0xFFFF` marks events not tied to a
specific endpoint.

### Event types and payload layouts

Dispatch on (`source_role`, `event_type`). Payload occupies the
32-byte `payload` field.

#### Stream (source_role = 1)

| event_type | Name | Payload layout (offsets in payload) |
|------------|------|-------------------------------------|
| 1 | `stream_begin` | `stream_id`(u32 0-3), `format`(u16 4-5), `channels`(u8 6), `_pad`(u8 7), `rate_hz`(u32 8-11) |
| 2 | `stream_end` | `stream_id`(u32 0-3), `frames_total`(u64 8-15) |
| 3 | `xrun` | `stream_id`(u32 0-3), `xrun_kind`(u8 4; 0=underrun, 1=overrun), `_pad`(u8[3] 5-7), `gap_sample_pos`(u64 8-15), `gap_frames`(u32 16-19) |
| 4 | `format_change` | `stream_id`(u32 0-3), `old_format`(u16 4-5), `new_format`(u16 6-7), `new_rate_hz`(u32 8-11) |

The `xrun` payload carries the physics-level fact per ADR 0007:
`gap_sample_pos` is the sample-stream position where the
underrun or overrun gap began (correlatable with the event
header's `ts_sync`), and `gap_frames` is the gap size in frames.
This lets semasound decide the policy response (resync, drop,
log) from the physics, without audiofs making that decision.

Note on F.2 scope: F.2 establishes this schema and the ring
mechanics. Real xrun detection is F.3.d (it requires the
interrupt-driven position tracking of F.3.c). Until F.3.d, no
`xrun` events are emitted; the payload layout is reserved now so
F.3.d does not change the wire format. Likewise `stream_begin`,
`stream_end`, and `format_change` are emitted once the data path
(F.3.a onward) creates real streams; F.2 itself emits only the
endpoint-lifecycle events below, which exist as soon as
controllers attach.

`stream_id` matches the HDA stream tag audiofs assigns when it
configures an output stream (the value already logged as
`stream_id` in the commit-6 bring-up). `format` is the HDA
format word (same encoding as the state region's
`current_format`).

#### Endpoint-lifecycle (source_role = 2)

| event_type | Name | Payload layout |
|------------|------|----------------|
| 1 | `endpoint_attach` | `endpoint_id`(u32 0-3), `kind`(u8 4), `direction`(u8 5), `controller_idx`(u8 6) |
| 2 | `endpoint_detach` | `endpoint_id`(u32 0-3) |
| 3 | `inventory_full` | `attempted_kind`(u8 4), `which`(u8 5; 0=controller, 1=endpoint) |

`endpoint_slot` in the event header identifies the affected
endpoint. Lifecycle events describe hardware inventory state,
not stream activity. `endpoint_attach` / `endpoint_detach` are
emitted when the state region's endpoint inventory changes
(controller attach enumerates endpoints; hot-plug add/remove,
when F.3.f brings up HDMI presence detection, will emit these
at runtime). `inventory_full` signals that a controller or
endpoint could not be recorded because the fixed slot array was
exhausted (the state region's 8-controller / 32-endpoint
ceilings).

## Concurrency model

Single producer (audiofs), multiple consumers. Lock-free.

### Writer protocol (order is load-bearing)

1. Compute next slot index: `(writer_seq + 1) & (slot_count - 1)`.
2. Write all event fields except `seq`.
3. Publish: atomic store of `seq` with the new sequence number.
4. Advance `writer_seq` atomically.
5. Update `earliest_seq` if the ring wrapped.
6. Update the state region's `last_event_seq` to the new seq.
7. Wake the pollable fd.

Step 6 ties the events ring to the state region: a reader woken
by the fd sees the new event in the ring, and the state region
reflects events through `last_event_seq`.

### Reader protocol

```zig
fn drain(self: *EventRingReader) !void {
    const writer_seq = @atomicLoad(u64, &self.header.writer_seq, .seq_cst);
    const earliest = @atomicLoad(u64, &self.header.earliest_seq, .seq_cst);

    if (self.last_consumed < earliest - 1) return error.RingOverrun;

    var next = self.last_consumed + 1;
    while (next <= writer_seq) : (next += 1) {
        const slot = &self.slots[next & (self.header.slot_count - 1)];
        const seq1 = @atomicLoad(u64, &slot.seq, .seq_cst);
        if (seq1 != next) continue;
        const event = self.readEventFields(slot);
        const seq2 = @atomicLoad(u64, &slot.seq, .seq_cst);
        if (seq2 != next) continue;
        try self.handleEvent(event);
        self.last_consumed = next;
    }
}
```

Readers that tolerate overrun resynchronise from the state
region on `RingOverrun`: re-read the full endpoint inventory,
set `last_consumed` to the state region's `last_event_seq`, and
resume.

### Pollable fd

audiofs exposes a pollable notification fd supporting
`kqueue`/`EVFILT_READ`, mirroring the inputfs notification
surface (inputfs ADR 0021's `/dev/inputfs_notify`). The exact
device name and the kernel mechanism are specified in ADR 0013.
A read returns the current `writer_seq`. This lets semasound
wake on event arrival rather than polling.

## API

To be added in `shared/src/audio.zig` when the F.2
implementation lands, alongside the existing F.1 StateReader.
Expected shape, mirroring `shared/src/input.zig`:

```zig
const audio = @import("shared/src/audio.zig");

// Writer (audiofs kernel module only; sketch of the
// userspace-side shape).
var writer = try audio.EventRingWriter.init(audio.EVENTS_PATH);
defer writer.deinit();

writer.publish(.{
    .ts_ordering = now_ns,
    .ts_sync = samples_clocked,
    .endpoint_slot = 2,
    .source_role = .stream,
    .event_type = .xrun,
    .payload = .{ .xrun = .{
        .stream_id = 1,
        .xrun_kind = 0,
        .gap_sample_pos = pos,
        .gap_frames = n,
    } },
});

// Reader
const reader = try audio.EventRingReader.init(audio.EVENTS_PATH);
defer reader.deinit();

const fd = try reader.pollableFd();
// register fd with kqueue, then:
try reader.drain(.{ .on_event = onEvent, .on_overrun = onOverrun });
```

## Lifecycle

- Module load: region created/truncated, `ring_valid = 0`,
  `writer_seq = 0`, `earliest_seq = 1`.
- Controllers attach, endpoints enumerate: `endpoint_attach`
  events published; `ring_valid = 1` once enumeration completes.
- Events published: `writer_seq` advances; event written to
  `seq & (slot_count - 1)`.
- Ring wrap: overwrites oldest slot; `earliest_seq` advances.
- Module unload: file persists (matching inputfs and the F.1
  state file: invalidate-and-close, no unlink); next load
  resets. `ring_valid` set to 0 on unload so a reader still
  mmap'd sees the ring as gone.

## Failure modes

- Ring overrun (`last_consumed < earliest - 1`): resynchronise
  from the state region.
- Mid-write slot during read: detected by `seq` mismatch, retry.
- Unknown version: refuse and log.
- mmap failure: transient, retry after reload.
- Unknown `source_role` or `event_type`: skip the event but
  advance `last_consumed` (forward compatibility).
- Reads when `ring_valid == 0`: undefined; readers check the
  flag before interpreting.

## Versioning

`version = 1`. Adding new `event_type` or `source_role` values
is backwards-compatible (readers skip unknown ones). Changing
slot size, slot count, or header layout is breaking and
increments the version. Readers must reject unknown versions.

## Magic value encoding

Following `shared/CLOCK.md`, `shared/INPUT_EVENTS.md`, and
`shared/AUDIO_STATE.md`: the magic u32 is written so its
big-endian byte representation spells the mnemonic ("AUEV" ->
`0x41554556`). On disk (little-endian) the bytes are
`56 45 55 41`. Code compares the loaded u32 directly against
the constant.

## Integration with audiofs

`audiofs` is the only writer. Publication path:

1. Assign the event its sequence number.
2. Publish the event to the ring (seq stored last).
3. Update the state region (inventory or runtime fields).
4. Set the state region `last_event_seq` to this event's seq.
5. Wake the pollable fd.

This ordering guarantees a reader woken by the fd sees both the
new event in the ring and consistent state, with
`last_event_seq` tying them together.

## References

- `audiofs/docs/adr/0013-f2-events-ring.md` (the design ADR)
- `audiofs/docs/adr/0007-physics-semantics-boundary.md` (the
  physics-only constraint; xrun as physics fact)
- `audiofs/docs/adr/0003-clock-writer.md` (the audio sample
  clock that `ts_sync` references; F.4 makes audiofs the writer)
- `audiofs/docs/adr/0011-fstage-reconciliation.md` (F.2's
  reframed closure criteria and the F.1 -> F.2 dependency)
- `shared/AUDIO_STATE.md` (the snapshot surface; `last_event_seq`
  correlation)
- `shared/INPUT_EVENTS.md` (the precedent this mirrors)
- `inputfs/docs/adr/0021-inputfs-notification-surface.md` (the
  pollable-fd pattern)
