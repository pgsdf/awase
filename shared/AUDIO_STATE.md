# Audio State Region

## Purpose

The audio state region is a memory-mapped file written exclusively
by the `audiofs` kernel module and read by all userspace consumers.
It publishes the current materialised state of the audio subsystem
(controller inventory, endpoint inventory, per-endpoint runtime
state, and sequencing metadata) without requiring IPC round-trips.

This implements the F.1 publication surface specified in
`audiofs/docs/adr/0012-f1-state-file.md`. It is the authoritative,
always-fresh snapshot consumers can read efficiently; the events
ring (F.2, to follow) will provide the ordered delta stream.

The region is physics-only per ADR 0007: it publishes what hardware
can do, not what policy says about it. Policy lives in semasound.

## State file

**Default path**: `/var/run/sema/audio/state`

The file is created (or truncated) by `audiofs` on module load via
`StateWriter.init()` in `shared/src/audio.zig` (to be added when
the F.1 implementation lands). The parent directory
`/var/run/sema/audio/` is created if it does not exist. File mode
is 0644, owned by root:wheel.

## Region layout

The region consists of a fixed header followed by two fixed-size
arrays (controller inventory and endpoint inventory). All arrays
use the slot counts in v1 (8 controllers, 32 endpoints). Unused
slots are zero-filled. All multi-byte fields are little-endian.

Total size: **2,624 bytes** (header 64 + controller inventory
8 × 64 = 512 + endpoint inventory 32 × 64 = 2,048).

### Header (64 bytes, offset 0)

| Offset | Size | Type | Field | Description |
|--------|------|------|-------|-------------|
| 0 | 4 | u32 | `magic` | `0x54535541` ("AUST" when read as big-endian mnemonic; on disk as `41 55 53 54`) |
| 4 | 1 | u8 | `version` | Region format version (currently `1`) |
| 5 | 1 | u8 | `state_valid` | `0` = initialising, `1` = live |
| 6 | 1 | u8 | `controller_count` | Number of populated controller slots (0..8) |
| 7 | 1 | u8 | `endpoint_count` | Number of populated endpoint slots (0..32) |
| 8 | 4 | u32 | `seqlock` | Seqlock sequence counter (odd = write in progress) |
| 12 | 4 | u32 | `inventory_seq` | Inventory sequence number, increments on any controller or endpoint add/remove |
| 16 | 8 | u64 | `last_event_seq` | Sequence number of the last F.2 events-ring event reflected here (0 until F.2 lands) |
| 24 | 1 | u8 | `controller_slot_count` | Compile-time slot capacity (8 in v1; for forward-compat detection) |
| 25 | 1 | u8 | `endpoint_slot_count` | Compile-time slot capacity (32 in v1) |
| 26 | 1 | u8 | `controller_slot_size` | Per-slot size in bytes (64 in v1) |
| 27 | 1 | u8 | `endpoint_slot_size` | Per-slot size in bytes (64 in v1) |
| 28 | 36 | u8[36] | `_pad` | Reserved, zero |

The header total is 64 bytes. The slot-capacity / slot-size fields
let a reader at a future bumped version detect whether the slot
counts or per-slot sizes have grown without parsing the version
field's semantic mapping.

### Controller inventory (8 slots × 64 bytes = 512 bytes, offset 64)

Each slot:

| Offset (rel) | Size | Type | Field | Description |
|--------------|------|------|-------|-------------|
| 0 | 4 | u32 | `controller_id` | Stable id within audiofs lifetime (0 = unused slot) |
| 4 | 1 | u8 | `subtype` | `0` = unused, `1` = PCI HDA, `2` = USB audio class (reserved for F.3 future) |
| 5 | 3 | u8[3] | `_pad0` | Reserved, zero |
| 8 | 2 | u16 | `pci_vendor` | PCI vendor id (0 if not PCI) |
| 10 | 2 | u16 | `pci_device` | PCI device id (0 if not PCI) |
| 12 | 2 | u16 | `pci_subvendor` | PCI subsystem vendor id (0 if not PCI or not present) |
| 14 | 2 | u16 | `pci_subdevice` | PCI subsystem device id |
| 16 | 1 | u8 | `num_iss` | Input stream descriptors (HDA only; 0 otherwise) |
| 17 | 1 | u8 | `num_oss` | Output stream descriptors |
| 18 | 1 | u8 | `num_bss` | Bidirectional stream descriptors |
| 19 | 1 | u8 | `support_64bit` | `1` if controller supports 64-bit DMA addresses |
| 20 | 4 | u32 | `_pad1` | Reserved, zero |
| 24 | 40 | u8[40] | `name` | Null-terminated free-form name (e.g. "Intel Sunrise Point HDA"); display only, not load-bearing |

Per-slot size: 64 bytes. Slots with `controller_id == 0` are
unused; readers iterate up to `controller_count` populated
slots (which are contiguous from slot 0).

### Endpoint inventory (32 slots × 64 bytes = 2,048 bytes, offset 576)

An endpoint is the abstraction over a discovered audio path: pin
complex through codec widgets to a DAC (output) or from an ADC to
a pin complex (input). Each endpoint corresponds to a path
audiofs has topology-walked and (for output) electrically prepared
at attach time (pin-controlled, amp-unmuted).

Each slot:

| Offset (rel) | Size | Type | Field | Description |
|--------------|------|------|-------|-------------|
| 0 | 4 | u32 | `endpoint_id` | Stable id within audiofs lifetime (0 = unused slot) |
| 4 | 1 | u8 | `controller_idx` | Index into controller inventory (0..7) |
| 5 | 1 | u8 | `codec_addr` | Codec address on the controller (HDA: 0..15) |
| 6 | 1 | u8 | `kind` | Endpoint-kind enum (see below) |
| 7 | 1 | u8 | `direction` | `0` = unused, `1` = output, `2` = input, `3` = loopback (reserved) |
| 8 | 2 | u16 | `pin_nid` | Pin widget node id (for HDA; 0 if not applicable) |
| 10 | 2 | u16 | `converter_nid` | DAC or ADC node id |
| 12 | 1 | u8 | `electrically_ready` | `1` if pin control + amp unmute completed at attach |
| 13 | 1 | u8 | `runtime_active` | `1` if a stream is currently bound and running on this endpoint |
| 14 | 2 | u16 | `current_format` | HDA format word if `runtime_active` is `1`; else 0 |
| 16 | 4 | u32 | `rate_mask` | Supported sample rates, encoded per HDA 1.0a Table 87 |
| 20 | 4 | u32 | `bit_depth_mask` | Supported bit depths, encoded per HDA 1.0a Table 87 |
| 24 | 1 | u8 | `channel_mask` | Bit i set = (i+1) channels supported; bit 1 = stereo |
| 25 | 7 | u8[7] | `_pad0` | Reserved, zero |
| 32 | 32 | u8[32] | `name` | Null-terminated free-form name (e.g. "Internal Speaker", "HDMI/0"); display only |

Per-slot size: 64 bytes.

#### Endpoint-kind enum

Categorical, physics-derived. Values:

| Value | Meaning |
|-------|---------|
| 0 | Unused (the slot is empty) |
| 1 | Analog speaker (internal speaker pin, OUTPUT_CAP) |
| 2 | Analog headphone (HEADPHONE_CAP pin) |
| 3 | Analog line-out (OUTPUT_CAP, not HP, not speaker per pin config default) |
| 4 | Analog mic (INPUT_CAP, mic-class pin config default) |
| 5 | Analog line-in (INPUT_CAP, line-class) |
| 6 | HDMI playback (digital pin, HDMI per pin config default) |
| 7 | DisplayPort playback (digital pin, DisplayPort per pin config default) |
| 8 | S/PDIF playback (digital pin, SPDIF_Out per pin config default, device kind 0x4) |
| 9..15 | Reserved (future analog variants, loopback, USB audio class) |

Pin classification follows the HDA-spec configuration-default
register per HDA 1.0a section 7.3.3.31. Codec-vendor quirks that
misreport pin config defaults go in the platform-policy table
(per the commit 6g pattern), not in endpoint classification.

#### Rate and bit-depth bitmasks

`rate_mask` and `bit_depth_mask` use the HDA 1.0a Table 87
encoding directly. The bits map to specific rates and bit depths
as defined in the HDA spec; consumers should reference the spec
for the exact mapping rather than re-encoding here. The relevant
HDA spec parameter is `HDA_PARAM_SUPP_PCM_SIZE_RATE` (param
0x0A) at the converter node.

A reader checking "does this endpoint support 48 kHz" sets the
corresponding rate bit and tests against `rate_mask`. The
encoding is shared with the HDA stream-format-cap register so
this is the format used by audiofs internally; no translation
layer is needed in the kernel publish path.

#### USB audio class endpoints

USB audio class endpoints (future, when F.3 brings up USB-audio
support) will use the same slot structure but populate fields
differently: `controller_idx` points at a USB-class controller
slot; `codec_addr`, `pin_nid`, `converter_nid` may be repurposed
to carry USB audio class entity ids. The exact USB-specific
field reuse will be decided in the F.3 USB-audio sub-milestone's
ADR; this v1 spec leaves the door open by not constraining
field semantics to HDA-only.

## Concurrency model

The region uses a seqlock. The sole writer (`audiofs`) increments
`seqlock` before and after every batch update.

Reader algorithm:

```zig
fn snapshot(self: StateReader) !Snapshot {
    while (true) {
        const v1 = @atomicLoad(u32, &self.header.seqlock, .seq_cst);
        if (v1 & 1 != 0) continue; // write in progress
        const data = self.readFields();
        const v2 = @atomicLoad(u32, &self.header.seqlock, .seq_cst);
        if (v2 == v1) return data;
    }
}
```

- `state_valid` is set once (0 → 1) after initial enumeration and
  never reset. Readers should check it before interpreting any
  other field.
- `inventory_seq` increments whenever a controller or endpoint
  slot is added, removed, or has its identifying fields change
  (e.g. controller detach, HDMI endpoint appears or disappears
  on jack-detection).
- `last_event_seq` is updated by the F.2 events publisher (when
  F.2 lands) so a reader using both the state file and events
  ring can correlate them. Until F.2 lands, this field is
  always 0.
- Per-endpoint `runtime_active`, `current_format` are atomically
  updated under the same seqlock; readers see them consistent
  with the rest of the snapshot.

## API

To be added in `shared/src/audio.zig` when the F.1 implementation
lands. The expected shape, mirroring `shared/src/input.zig`:

```zig
const audio = @import("shared/src/audio.zig");

// Writer (audiofs kernel module only; this is a sketch
// of the userspace-side API; the kernel implementation
// uses equivalent primitives in C).
var writer = try audio.StateWriter.init(audio.STATE_PATH);
defer writer.deinit();

writer.beginUpdate();
writer.addController(controller_desc);
writer.addEndpoint(endpoint_desc);
writer.setEndpointRuntime(endpoint_id, .{
    .active = true,
    .format = format_word,
});
writer.bumpInventorySeq();
writer.endUpdate();

// Reader
const reader = try audio.StateReader.init(audio.STATE_PATH);
defer reader.deinit();

if (!reader.isValid()) return error.NotReady;

const snap = try reader.snapshot();
const controllers = snap.controllers();
const endpoints = snap.endpoints();
const ep = snap.findEndpointById(endpoint_id); // null if not present
```

## Lifecycle

- **Module load**: file created or truncated; `state_valid = 0`,
  `controller_count = 0`, `endpoint_count = 0`, all slots zero.
- **Controllers attach**: per-controller, `addController` populates
  the next slot, increments `controller_count`, bumps
  `inventory_seq`.
- **Topology walk completes per controller**: endpoints discovered
  during pin-and-path walk are added via `addEndpoint`,
  incrementing `endpoint_count` and bumping `inventory_seq`.
- **Enumeration completes**: `state_valid = 1`.
- **Stream start on an endpoint**: `setEndpointRuntime` updates
  `runtime_active` and `current_format`.
- **Stream stop**: `setEndpointRuntime` clears `runtime_active`
  and zeroes `current_format`.
- **Hot-plug add (HDMI sink appears, USB audio device connects)**:
  `addEndpoint` for the new endpoint, `inventory_seq` bumps.
- **Hot-plug remove**: endpoint slot zeroed, `endpoint_count`
  adjusted (note: slot indices may shift; consumers using
  `endpoint_id` for tracking are not affected by slot shifts),
  `inventory_seq` bumps.
- **Controller detach**: controller slot zeroed; all endpoints
  belonging to it are also removed; `inventory_seq` bumps.
- **Unload**: file is removed. If removal fails, the writer
  zeroes `state_valid` so any reader still mmap'd sees an
  invalid state.

## Failure modes

- **More than 8 controllers attached**: ninth and beyond ignored
  with kernel log; future version bump can grow the array.
- **More than 32 endpoints discovered**: thirty-third and beyond
  ignored with kernel log.
- **Unknown version on read**: refuse and log; no forward-
  compatibility assumption.
- **mmap failure**: treat as transient; retry after reload.
- **Reads ignoring seqlock**: undefined. Always use helpers.
- **Reads when `state_valid == 0`**: undefined; readers should
  check the flag before interpreting other fields.

## Versioning

`version = 1`. Backwards-compatible changes (new reserved fields
used, slot fields populated where previously zero, new
endpoint-kind enum values in the reserved range 8-15) do not bump
the version. Breaking changes (changing slot counts, changing
slot sizes, repurposing existing field values) increment the
version and require a new document. Readers must reject unknown
versions.

Some fields in the v1 header exist precisely to support forward
compatibility: `controller_slot_count`, `endpoint_slot_count`,
`controller_slot_size`, `endpoint_slot_size`. A reader at a
future version can detect grown slot arrays by reading these
fields and adjusting iteration accordingly, without needing to
parse a version-mapping table.

## Magic value encoding

Following CLOCK.md, INPUT_STATE.md, and `shared/src/clock.zig`:
the magic u32 constant is written so its big-endian byte
representation spells the mnemonic ("AUST" → `0x54535541`). On
disk (little-endian), bytes appear as `41 55 53 54` (`A U S T`).
Code compares the loaded u32 directly against the constant.

## Integration with audiofs

`audiofs` is the only writer. All updates go through the
state-writer code path after the relevant attach / detach /
stream-lifecycle event. All other components are readers only.

The companion ADR is `audiofs/docs/adr/0012-f1-state-file.md`;
that document records the design decision behind this schema.
Implementation details (e.g. which C primitives implement the
seqlock; how the file is mmap-backed) live in the F.1
implementation commit when it lands.

## References

- `audiofs/docs/adr/0012-f1-state-file.md` (the design ADR)
- `audiofs/docs/adr/0007-physics-semantics-boundary.md` (the
  physics-only constraint)
- `audiofs/docs/adr/0011-fstage-reconciliation.md` (F.1's
  reframed closure criteria)
- `shared/CLOCK.md` (the reference pattern for magic-plus-
  version headers)
- `shared/INPUT_STATE.md` (the close-fit precedent for state
  regions with slot arrays)
- HDA 1.0a specification, sections 7.3.3.31 (pin config default
  and pin widget control) and Table 87 (rate / bit-depth
  encoding)
