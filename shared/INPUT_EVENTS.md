# Input Event Ring

## Purpose

The input event ring is a memory-mapped file written exclusively
by the `inputfs` kernel module and read by userspace consumers
that need the ordered event stream. It publishes a bounded
history of recent input events in strict sequence-number order
without requiring IPC round-trips.

This is the event-stream surface of the inputfs publication model
described in `inputfs/docs/adr/0002-shared-memory-regions.md`.
The companion state region holds the materialised view; the event
ring holds the delta stream the state is materialised from.

## Events file

**Default path**: `/var/run/sema/input/events`

The file is created (or truncated) by `inputfs` on module load
via `EventRingWriter.init()` in `shared/src/input.zig`.

## Relation to the unified event log

The input event ring is distinct from the JSON-lines event log
defined in `shared/EVENT_SCHEMA.md`. The ring is a binary,
high-frequency, shared-memory publication. High-frequency events
(pointer motion, keystrokes, touch updates) appear only in the
ring; they do not flood the JSON log.

`inputfs` emits JSON-lines events to stdout only for low-frequency
lifecycle events (`module_load`, `device_attach`, `device_detach`)
and aggregate cases (`inventory_full`).

## Region layout

The region consists of a fixed header followed by a circular
buffer of fixed-size event slots. All multi-byte fields are
little-endian.

Total size: **65,600 bytes** (header 64 + 1024 slots × 64 bytes).

### Header (64 bytes, offset 0)

| Offset | Size | Type | Field | Description |
|--------|------|------|-------|-------------|
| 0 | 4 | u32 | `magic` | `0x494E5645` ("INVE" when read as big-endian mnemonic; matches CLOCK.md convention) |
| 4 | 1 | u8 | `version` | Region format version (currently `1`) |
| 5 | 1 | u8 | `ring_valid` | `0` = initialising, `1` = live |
| 6 | 2 | u16 | `event_size` | Size of each event slot in bytes (64 in v1) |
| 8 | 4 | u32 | `slot_count` | Number of event slots (1024 in v1; power of two) |
| 12 | 4 | u32 | `_pad0` | Reserved, zero |
| 16 | 8 | u64 | `writer_seq` | Sequence number of the most recently published event (atomic) |
| 24 | 8 | u64 | `earliest_seq` | Sequence number of the oldest event still in the ring |
| 32 | 32 | u8[32] | `_pad1` | Reserved, zero |

`slot_count` is a power of two. Consumers compute slot index as
`seq & (slot_count - 1)`. Readers respect `event_size` and
`slot_count` rather than hard-coding v1 values.

### Event slot (64 bytes each, starts at offset 64)

| Offset (rel) | Size | Type | Field | Description |
|--------------|------|------|-------|-------------|
| 0 | 8 | u64 | `seq` | Sequence number of this event |
| 8 | 8 | u64 | `ts_ordering` | Ordering clock timestamp (monotonic kernel ns) |
| 16 | 8 | u64 | `ts_sync` | Sync clock position (audio samples), or `0` if unavailable |
| 24 | 2 | u16 | `device_slot` | Index into state region device inventory (`0xFFFF` = synthetic) |
| 26 | 1 | u8 | `source_role` | Event origin role (`1`=pointer, `2`=keyboard, `3`=touch, `4`=pen, `5`=lighting, `6`=device-lifecycle) |
| 27 | 1 | u8 | `event_type` | Per-role event variant (see below) |
| 28 | 4 | u32 | `flags` | Bit 0 = synthesised, bit 1 = coalesced; others reserved |
| 32 | 32 | u8[32] | `payload` | Role-specific payload (layout per `event_type`) |

`source_role` identifies the origin of the event. This is
distinct from the `roles` bitmask in the state region's device
inventory: a device *has* roles (what it can produce); an event
*comes from* a source_role (what produced it).

### Event types and payload layouts

Dispatch on (`source_role`, `event_type`). Payload occupies the
32-byte `payload` field.

Stage D adds a `session_id` (u32) field to each per-event-type
payload. It identifies the destination session for routed events
(or `0` if no session was matched and the event is unrouted).
Per ADR 0012, the session_id is placed in the per-type payload
rather than the unified header so the wire format does not break
Stage C consumers; the payload offsets shown below assume Stage D.

For events emitted before the routing path is active (Stage C
emission, or Stage D with `hw.inputfs.enable = 0`), the
`session_id` field is set to `0`. Consumers must check
`session_id != 0` before treating it as authoritative; a zero
value means "no session yet matched" rather than "session 0."

#### Pointer (source_role = 1)

| event_type | Name | Payload layout (offsets in payload) |
|------------|------|-------------------------------------|
| 1 | `motion` | `x`(i32 0-3), `y`(i32 4-7), `dx`(i32 8-11), `dy`(i32 12-15), `buttons`(u32 16-19), `session_id`(u32 20-23) |
| 2 | `button_down` | `x`(i32 0-3), `y`(i32 4-7), `button`(u32 8-11), `buttons`(u32 12-15), `session_id`(u32 16-19) |
| 3 | `button_up` | `x`(i32 0-3), `y`(i32 4-7), `button`(u32 8-11), `buttons`(u32 12-15), `session_id`(u32 16-19) |
| 4 | `scroll` | `x`(i32 0-3), `y`(i32 4-7), `scroll_dx`(i32 8-11), `scroll_dy`(i32 12-15), `delta_unit`(u32 16-19; 0=lines, 1=pixels), `session_id`(u32 20-23) |
| 5 | `enter` | `x`(i32 0-3), `y`(i32 4-7), `surface_id`(u32 8-11), `session_id`(u32 12-15) |
| 6 | `leave` | `x`(i32 0-3), `y`(i32 4-7), `surface_id`(u32 8-11), `session_id`(u32 12-15) |

`enter` and `leave` are synthesised by inputfs (ADR 0003) with
`flags` bit 0 set. They are emitted only when transform and
routing are both active (Stage D); Stage C does not synthesise
them.

#### Keyboard (source_role = 2)

| event_type | Name | Payload layout |
|------------|------|----------------|
| 1 | `key_down` | `hid_usage`(u32 0-3), `positional`(u32 4-7, or `0xFFFFFFFF`), `modifiers`(u32 8-11), `session_id`(u32 12-15) |
| 2 | `key_up` | same as `key_down` |

No auto-repeat events generated by inputfs. Modifier state is
carried in every keyboard event's `modifiers` field; there are
no separate modifier-transition event types. Pure modifier-only
presses are emitted as ordinary `key_down` / `key_up` events
whose `hid_usage` identifies the modifier key.

#### Touch (source_role = 3)

| event_type | Name | Payload layout |
|------------|------|----------------|
| 1 | `touch_down` | `contact_id`(u32 0-3), `x`(i32 4-7), `y`(i32 8-11), `pressure`(u32 12-15; 0-1023), `session_id`(u32 16-19) |
| 2 | `touch_move` | same as `touch_down` |
| 3 | `touch_up` | `contact_id`(u32 0-3), `x`(i32 4-7), `y`(i32 8-11), `session_id`(u32 12-15) |

Touch events are not emitted in Stage D; descriptor-driven
touch parsing is deferred to a post-Stage-D AD-1 sub-item per
ADR 0012.

#### Pen (source_role = 4)

| event_type | Name | Payload layout |
|------------|------|----------------|
| 1 | `pen_down` | `x`(i32 0-3), `y`(i32 4-7), `pressure`(u32 8-11), `tilt_x`(i16 12-13), `tilt_y`(i16 14-15), `barrel_buttons`(u32 16-19), `session_id`(u32 20-23) |
| 2 | `pen_move` | same as `pen_down` |
| 3 | `pen_up` | `x`(i32 0-3), `y`(i32 4-7), `barrel_buttons`(u32 8-11), `session_id`(u32 12-15) |

Pen events are not emitted in Stage D; same deferral as touch.

#### Lighting (source_role = 5)

No outbound events in v1 (commands are inbound via ioctl per
ADR 0005). Future revisions may add status notifications.

#### Device-lifecycle (source_role = 6)

| event_type | Name | Payload layout |
|------------|------|----------------|
| 1 | `device_attach` | `roles`(u32 0-3) |
| 2 | `device_detach` | zero |
| 3 | `inventory_full` | `attempted_roles`(u32 0-3) |

`device_slot` in the event header identifies the affected device.
Lifecycle events do not carry `session_id`: they are not routed
to any session because they describe device state, not user
input. Consumers interested in lifecycle events read all of
them regardless of session.

## Concurrency model

Single producer (inputfs), multiple consumers. Lock-free.

### Writer protocol (order is load-bearing)

1. Compute next slot index: `(writer_seq + 1) & (slot_count - 1)`.
2. Write all event fields except `seq`.
3. Publish: atomic store of `seq` with the new sequence number.
4. Advance `writer_seq` atomically.
5. Update `earliest_seq` if the ring wrapped.
6. Wake pollable fd.

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

Readers that tolerate overrun resynchronise from the state region
on `RingOverrun`.

### Pollable fd

The `/dev/inputfs` fd (ADR 0001) supports `kqueue`/`EVFILT_READ`.
A `read()` returns the current `writer_seq`.

## API

```zig
const input = @import("shared/src/input.zig");

// Writer (inputfs only)
var writer = try input.EventRingWriter.init(input.EVENTS_PATH);
defer writer.deinit();

writer.publish(.{
    .ts_ordering = now_ns,
    .device_slot = 3,
    .source_role = .pointer,
    .event_type = .motion,
    .payload = .{ .motion = .{ .x = 1024, .y = 512, .dx = 1, .dy = 0 } },
});

// Reader
const reader = try input.EventRingReader.init(input.EVENTS_PATH);
defer reader.deinit();

const fd = try reader.pollableFd();
// register with kqueue, then:
try reader.drain(.{ .on_event = onEvent, .on_overrun = onOverrun });
```

## Lifecycle

- Module load: region created/truncated, `ring_valid = 0`, `writer_seq = 0`, `earliest_seq = 1`.
- Enumeration completes: `ring_valid = 1`.
- Events published: `writer_seq` advances; written to `seq & (slot_count - 1)`.
- Ring wrap: overwrites oldest slot; `earliest_seq` advances.
- Module unload: file persists; next load resets.

## Failure modes

- Ring overrun: `last_consumed < earliest - 1` → resynchronise from state region.
- Mid-write slot during read: detected by `seq` mismatch → retry.
- Unknown version: refuse and log.
- mmap failure: transient; retry after reload.
- Unknown `source_role` or `event_type`: skip the event (but advance `last_consumed`).

## Versioning

`version = 1`. Adding new `event_type` values or `source_role`
values is backwards-compatible. Changing slot size, slot count,
or header layout is breaking. Readers encountering an unknown
`source_role` or `event_type` must skip the event gracefully.

## Magic value encoding

Following `shared/CLOCK.md` and `shared/INPUT_STATE.md`: the
magic u32 is written so its big-endian byte representation
spells the mnemonic ("INVE" → `0x494E5645`). On disk
(little-endian) the bytes are `45 56 4E 49`. Code compares the
loaded u32 directly against the constant.

## Integration with inputfs

`inputfs` is the only writer. Ingestion path:

1. Admit event and assign sequence number.
2. Publish event to ring.
3. Update state region.
4. Wake pollable fd.

This ordering guarantees that a reader woken by the fd sees
both the new event in the ring and consistent state.

References:

- `inputfs/docs/adr/0002-shared-memory-regions.md`
- `inputfs/docs/foundations.md` (§3 event ordering, §4 state consistency, §5 keyboard semantics)
- `inputfs/docs/adr/0003-focus-publication.md` (enter/leave synthesis)
- `inputfs/docs/adr/0004-role-taxonomy.md`
- `shared/INPUT_STATE.md`
- `shared/EVENT_SCHEMA.md` (JSON log, distinct from this ring)
