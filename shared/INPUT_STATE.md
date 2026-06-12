# Input State Region

## Purpose

The input state region is a memory-mapped file written exclusively
by the `inputfs` kernel module and read by all userspace consumers.
It publishes the current materialised state of the input subsystem
(global pointer position, per-device keyboard and touch state,
device inventory including lighting capability descriptors, and
sequencing metadata) without requiring IPC round-trips.

This implements the shared-memory publication surface described in
`inputfs/docs/adr/0002-shared-memory-regions.md`. It is the
authoritative, always-fresh view that consumers can snapshot
efficiently; the event ring provides the ordered delta stream.

## State file

**Default path**: `/var/run/sema/input/state`

The file is created (or truncated) by `inputfs` on module load via
`StateWriter.init()` in `shared/src/input.zig`. The parent directory
`/var/run/sema/input/` is created if it does not exist.

## Region layout

The region consists of a fixed header followed by three fixed-size
arrays. All arrays use `slot_count` slots (32 in v1). Unused slots
are zero-filled. All multi-byte fields are little-endian.

Total size: **11,328 bytes** (header 64 + device inventory 32 × 160
+ keyboard state 32 × 64 + touch state 32 × 128).

### Header (64 bytes, offset 0)

| Offset | Size | Type | Field | Description |
|--------|------|------|-------|-------------|
| 0 | 4 | u32 | `magic` | `0x494E5354` ("INST" when read as big-endian mnemonic; matches CLOCK.md convention) |
| 4 | 1 | u8 | `version` | Region format version (currently `1`) |
| 5 | 1 | u8 | `state_valid` | `0` = initialising, `1` = live |
| 6 | 2 | u16 | `slot_count` | Number of slots in each array (32 in v1) |
| 8 | 4 | u32 | `seqlock` | Seqlock counter (see Concurrency model) |
| 12 | 4 | u32 | `_pad0` | Reserved, zero (alignment) |
| 16 | 8 | u64 | `last_sequence` | Sequence number of the most recent incorporated event |
| 24 | 8 | u64 | `boot_wall_offset_ns` | Wall-clock ns at ordering-clock zero |
| 32 | 4 | i32 | `pointer_x` | Pointer X coordinate; interpretation governed by `transform_active` (see below) |
| 36 | 4 | i32 | `pointer_y` | Pointer Y coordinate; interpretation governed by `transform_active` (see below) |
| 40 | 4 | u32 | `pointer_buttons` | Button bitmask (bit 0 = left, 1 = right, 2 = middle; others reserved) |
| 44 | 2 | u16 | `device_count` | Number of populated device inventory slots |
| 46 | 2 | u16 | `active_touch_count` | Total active touch contacts across all devices |
| 48 | 1 | u8 | `transform_active` | `0` = `pointer_x`/`pointer_y` are accumulated raw device deltas (Stage C); `1` = compositor pixel space (Stage D and later). See below. |
| 49 | 15 | u8[15] | `_pad1` | Reserved, zero |

#### `transform_active` semantics (added Stage D per ADR 0012)

The state region's pointer coordinates have two possible
interpretations during the inputfs migration:

- `transform_active = 0`: Stage C publication. `pointer_x` and
  `pointer_y` are accumulated raw deltas from boot-protocol or
  descriptor-driven mouse motion. They have no relationship to
  any display geometry and should not be interpreted as pixels
  on a screen. This is the value Stage C consumers see; the
  state region remains structurally correct but the coordinates
  are diagnostic rather than positional.

- `transform_active = 1`: Stage D publication. `pointer_x` and
  `pointer_y` are in compositor pixel space, clamped to display
  bounds learned from drawfs at module load. Consumers may
  interpret them directly as screen coordinates and resolve
  surface-under-cursor against the focus region's surface_map.

The byte transitions monotonically from `0` to `1` when Stage D
transform is enabled (typically at module load if `hw.inputfs.enable
= 1` and drawfs geometry is available). It does not transition
back to `0` once set.

Consumers that interpret pointer coordinates as compositor pixels
must check `transform_active == 1` first or risk treating raw
delta accumulation as pixel positions. Consumers that only
display the values diagnostically (e.g. `inputdump state`) need
no behavioural change.

### Device inventory (32 slots × 160 bytes = 5,120 bytes, offset 64)

Each slot:

| Offset (rel) | Size | Type | Field | Description |
|--------------|------|------|-------|-------------|
| 0 | 16 | u8[16] | `device_id` | Unique ID within this inputfs instance (all-zero = unused slot) |
| 16 | 16 | u8[16] | `identity_hash` | Stable logical identity hash (for reconnection matching) |
| 32 | 4 | u32 | `roles` | Role bitmask (bit 0 = pointer, 1 = keyboard, 2 = touch, 3 = pen, 4 = lighting; others reserved) |
| 36 | 2 | u16 | `usb_vendor` | USB vendor ID (0 if not applicable) |
| 38 | 2 | u16 | `usb_product` | USB product ID (0 if not applicable) |
| 40 | 64 | u8[64] | `name` | Null-terminated device name (truncated if necessary) |
| 104 | 56 | u8[56] | `lighting_caps` | Lighting capability descriptor (see below) |

### Lighting capability descriptor (56 bytes, inside device slot)

| Offset (rel) | Size | Type | Field | Description |
|--------------|------|------|-------|-------------|
| 0 | 1 | u8 | `zone_count` | Number of addressable zones (capped at 18 for v1) |
| 1 | 1 | u8 | `flags` | Bit 0 = pattern-capable (per ADR 0005); others reserved |
| 2 | 54 | u8[54] | `zones` | Up to 18 × 3-byte zone descriptors |

Zone descriptor (3 bytes):

- Byte 0: type (`0` = unused, `1` = boolean/LED, `2` = brightness, `3` = RGB)
- Byte 1: sub-zone count (`0` or `1` = single unit; higher = array, e.g. per-key)
- Byte 2: reserved (zero)

### Keyboard state array (32 slots × 64 bytes = 2,048 bytes, offset 5,184)

Indexed by device slot. Non-keyboard devices: slot zero-filled.

| Offset (rel) | Size | Type | Field | Description |
|--------------|------|------|-------|-------------|
| 0 | 4 | u32 | `modifiers` | Bitmask (bit 0 = shift, 1 = alt, 2 = ctrl, 3 = meta; others reserved) |
| 4 | 4 | u32 | `held_count` | Number of held keys (up to 6) |
| 8 | 48 | u8[48] | `held_keys` | 6 × 8-byte records |
| 56 | 8 | u8[8] | `_pad` | Reserved, zero |

Held-key record (8 bytes):

- Bytes 0-3: HID usage code (u32 LE)
- Bytes 4-7: positional code (u32 LE) or `0xFFFFFFFF` if unavailable

v1 limits to 6 keys (USB HID boot protocol). Excess keys on NKRO
devices are dropped from state but fully visible in the event ring.

### Touch state array (32 slots × 128 bytes = 4,096 bytes, offset 7,232)

Indexed by device slot. Non-touch devices: slot zero-filled.

| Offset (rel) | Size | Type | Field | Description |
|--------------|------|------|-------|-------------|
| 0 | 4 | u32 | `contact_count` | Active contacts on this device (up to 10) |
| 4 | 4 | u32 | `_pad` | Reserved, zero |
| 8 | 120 | u8[120] | `contacts` | 10 × 12-byte records |

Contact record (12 bytes):

- Bytes 0-3: contact ID (u32 LE, persistent for gesture lifetime)
- Bytes 4-7: compositor-space X (i32 LE)
- Bytes 8-11: compositor-space Y (i32 LE)

## Concurrency model

The region uses a seqlock. The sole writer increments `seqlock`
before and after every batch update.

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

- `state_valid` is set once (0 → 1) and never reset.
- Pointer position and buttons form an atomic tuple under the seqlock.
- Full inventory snapshots require reading all slots inside one seqlock pair (rarely contended).

## API

```zig
const input = @import("shared/src/input.zig");

// Writer (inputfs only)
var writer = try input.StateWriter.init(input.STATE_PATH);
defer writer.deinit();

writer.beginUpdate();
writer.addDevice(device_desc);
writer.setPointer(.{ .x = x, .y = y, .buttons = btns });
writer.setLastSequence(seq);
writer.endUpdate();

// Reader
const reader = try input.StateReader.init(input.STATE_PATH);
defer reader.deinit();

if (!reader.isValid()) return error.NotReady;

const snap = try reader.snapshot();
const ptr = snap.pointer();
const devs = snap.devices();
const kb = snap.keyboardForDevice(dev_id);   // null if no keyboard role
const touch = snap.touchForDevice(dev_id);
```

## Lifecycle

- Module load: region created or truncated with `state_valid = 0`, all zero.
- Enumeration completes: `state_valid = 1`.
- Device attach: `addDevice` (updates inventory, `device_count`, `lighting_caps`).
- Events: targeted updates (`setPointer`, `setKeyboardState`, `setTouchState`) with `last_sequence`.
- Detach: zero slots, decrement `device_count`.
- Unload: file persists; next load resets it.

## Failure modes

- More than `slot_count` devices: ignored (with log); visible in event ring as "inventory full".
- Unknown version: refuse and log; no forward-compatibility assumption.
- mmap failure: treat as transient; retry after reload.
- Reads ignoring seqlock: undefined. Always use helpers.

## Versioning

`version = 1`. Backwards-compatible changes (new reserved fields,
extended descriptors) do not bump the version. Breaking changes
increment the version and require a new document. Readers must
reject unknown versions.

## Magic value encoding

Following CLOCK.md and `shared/src/clock.zig`: the magic u32
constant is written so its big-endian byte representation spells
the mnemonic ("INST" → `0x494E5354`). On disk (little-endian),
bytes appear as `54 53 4E 49`. Code compares the loaded u32
directly against the constant.

## Integration with inputfs

`inputfs` is the only writer. All updates go through `StateWriter`
after event admission (state = materialised view of the event
stream per foundations §4). All other components are readers only.

References:

- `inputfs/docs/adr/0002-shared-memory-regions.md`
- `inputfs/docs/foundations.md` (§2, §4, §5)
- `inputfs/docs/adr/0005-lighting-command-mechanism.md`
- Upcoming event ring and focus region specs (they reference `device_id` and `last_sequence`)
