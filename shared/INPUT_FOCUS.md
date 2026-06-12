# Input Focus Region

## Purpose

The input focus region is a memory-mapped file written exclusively
by the compositor (semadrawd) and read by the `inputfs` kernel
module. It publishes the routing decisions inputfs needs to deliver
events to the correct session: keyboard focus, pointer grab, and
the compositor-space surface map for surface-under-cursor lookup.

This implements the compositor-to-kernel shared-memory surface
specified in `inputfs/docs/adr/0003-focus-publication.md` and forms
part of the overall publication model in
`inputfs/docs/adr/0002-shared-memory-regions.md`. Unlike the state
region and event ring (kernel-written), the focus region is
compositor-written and kernel-read.

## Focus file

**Default path**: `/var/run/sema/input/focus`

The file is created (or truncated) by the compositor on startup via
`FocusWriter.init()` in `shared/src/input.zig`.

## Region layout

The region consists of a fixed header followed by a fixed-size
surface map array. All multi-byte fields are little-endian.

Total size: **5,184 bytes** (header 64 + 256 surface entries × 20 bytes).

### Header (64 bytes, offset 0)

| Offset | Size | Type | Field | Description |
|--------|------|------|-------|-------------|
| 0 | 4 | u32 | `magic` | `0x4946434F` ("IFCO" when read as big-endian mnemonic; matches CLOCK.md convention) |
| 4 | 1 | u8 | `version` | Region format version (currently `1`) |
| 5 | 1 | u8 | `focus_valid` | `0` = compositor initialising, `1` = focus is live |
| 6 | 2 | u16 | `surface_slot_count` | Number of surface slots (256 in v1) |
| 8 | 4 | u32 | `seqlock` | Seqlock counter (see Concurrency model) |
| 12 | 4 | u32 | `keyboard_focus` | Session id to receive keyboard events (`0` = `NO_FOCUS`) |
| 16 | 4 | u32 | `pointer_grab` | Session id holding pointer grab (`0` = `NO_GRAB`) |
| 20 | 2 | u16 | `surface_count` | Number of populated entries in the surface map |
| 22 | 2 | u16 | `_pad0` | Reserved, zero |
| 24 | 40 | u8[40] | `_pad1` | Reserved, zero |

### Surface map (256 slots × 20 bytes = 5,120 bytes, offset 64)

Entries are ordered from top (index 0, highest z-order) to bottom
(index `surface_count - 1`, lowest z-order). Entries beyond
`surface_count` are zero-filled.

Each slot:

| Offset (rel) | Size | Type | Field | Description |
|--------------|------|------|-------|-------------|
| 0 | 4 | u32 | `session_id` | Session that owns this surface (`0` = unused slot) |
| 4 | 4 | i32 | `x` | Compositor-space X of top-left corner (pixels) |
| 8 | 4 | i32 | `y` | Compositor-space Y of top-left corner (pixels) |
| 12 | 4 | u32 | `width` | Surface width in pixels |
| 16 | 4 | u32 | `height` | Surface height in pixels |

Rectangles are axis-aligned. Surfaces with irregular shapes use
their bounding rectangle; finer hit-testing inside a surface is the
client's responsibility after routing.

## Surface-under-cursor lookup

`inputfs` resolves the target session for a pointer position
`(px, py)` by scanning from index 0 (top) downward:

```zig
fn surfaceUnderCursor(self: FocusReader, px: i32, py: i32) ?u32 {
    var i: usize = 0;
    while (i < self.header.surface_count) : (i += 1) {
        const s = &self.surface_map[i];
        if (px >= s.x and px < s.x + @as(i32, @intCast(s.width)) and
            py >= s.y and py < s.y + @as(i32, @intCast(s.height)))
        {
            return s.session_id;
        }
    }
    return null;
}
```

The first matching rectangle wins (top-most in z-order). This
lookup occurs inside a seqlock retry loop.

## Concurrency model

The region uses a seqlock. The compositor is the sole writer;
inputfs is the sole reader.

Reader algorithm (inputfs side):

```zig
fn snapshot(self: FocusReader) !Snapshot {
    while (true) {
        const v1 = @atomicLoad(u32, &self.header.seqlock, .seq_cst);
        if (v1 & 1 != 0) continue; // write in progress

        const keyboard_focus = @atomicLoad(u32, &self.header.keyboard_focus, .seq_cst);
        const pointer_grab = @atomicLoad(u32, &self.header.pointer_grab, .seq_cst);
        const surface_count = @atomicLoad(u16, &self.header.surface_count, .seq_cst);
        const surfaces = self.readSurfaces(surface_count);

        const v2 = @atomicLoad(u32, &self.header.seqlock, .seq_cst);
        if (v2 == v1) return .{
            .keyboard_focus = keyboard_focus,
            .pointer_grab = pointer_grab,
            .surfaces = surfaces,
        };
    }
}
```

- `focus_valid` is set once (0 → 1) when the compositor is ready.
- Focus updates are low-frequency, so seqlock retry cost for inputfs is negligible.

## API

```zig
const input = @import("shared/src/input.zig");

// Writer (compositor only)
var writer = try input.FocusWriter.init(input.FOCUS_PATH);
defer writer.deinit();

writer.beginUpdate();
writer.setKeyboardFocus(session_id);
writer.setPointerGrab(0);                    // release grab
writer.setSurfaceMap(ordered_surfaces);      // top-to-bottom z-order
writer.endUpdate();

// Reader (inputfs only)
const reader = try input.FocusReader.init(input.FOCUS_PATH);
defer reader.deinit();

if (!reader.isValid()) {
    // Compositor not ready, do not route
    return;
}

const snap = try reader.snapshot();
const keyboard_target = if (snap.keyboard_focus != 0) snap.keyboard_focus else null;
const pointer_target = snap.resolvePointer(px, py); // respects grab or surface map
```

## Lifecycle

- Compositor startup: region created/truncated with `focus_valid = 0`.
- Compositor ready: `focus_valid = 1`; inputfs begins routing.
- Focus or grab change: `setKeyboardFocus` / `setPointerGrab` bracketed by seqlock.
- Surface changes (attach/move/resize/restack): `setSurfaceMap` with new ordered list.
- Compositor exit or crash: file persists with last consistent state; inputfs continues routing to last known focus until next compositor starts and truncates the region.

## Failure modes

- Compositor not running: `focus_valid = 0` or file absent. inputfs publishes events to the ring but performs no routing.
- More than 256 surfaces: map truncated at 256; lower-z surfaces unreachable for pointer routing. Increasing `surface_slot_count` is a v2 change.
- Unknown version: inputfs refuses to interpret and logs; no routing until compatible version appears.
- mmap failure: transient; retry periodically.
- Compositor crash mid-update: seqlock detects partial write; inputfs retries until next consistent snapshot. During the window, the last valid snapshot is used.
- Reads ignoring seqlock: undefined. Always use `FocusReader` helpers.

## Versioning

`version = 1`. Backwards-compatible additions (new reserved fields)
do not bump the version. Breaking changes (slot count or size
changes, field repurposing) increment the version. Readers reject
unknown versions.

## Magic value encoding

Following `shared/CLOCK.md`, `shared/INPUT_STATE.md`, and
`shared/INPUT_EVENTS.md`: the magic u32 is written so its
big-endian byte representation spells the mnemonic ("IFCO" →
`0x4946434F`). On disk (little-endian) the bytes are `4F 43 46 49`.
Code compares the loaded u32 directly against the constant.

## Integration with inputfs and the compositor

The compositor is the only writer. Surface registry, focus
tracking, and grab logic all flow through `FocusWriter`. inputfs
reads via `FocusReader` on every routing decision.

Routing rules (per snapshot):

- Keyboard events → `keyboard_focus` (if non-zero).
- Pointer events → `pointer_grab` (if non-zero), else
  `surfaceUnderCursor(px, py)`, else no session.

Surface-under-cursor changes between pointer events trigger
synthesised enter/leave events in the event ring (see
`shared/INPUT_EVENTS.md`).

References:

- `inputfs/docs/adr/0002-shared-memory-regions.md`
- `inputfs/docs/adr/0003-focus-publication.md`
- `inputfs/docs/foundations.md` (§1 coordinate space, §4 state consistency)
- `shared/INPUT_STATE.md`
- `shared/INPUT_EVENTS.md` (enter/leave synthesis)
