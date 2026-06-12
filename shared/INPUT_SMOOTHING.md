# Input Smoothing Region

## Purpose

The input smoothing region is a memory-mapped file written
exclusively by the compositor (semadrawd) and read by the
`inputfs` kernel module. It publishes the per-user pointer
smoothing parameters that inputfs applies in its interrupt path,
between the D.3 coordinate transform and D.4 routing. All
consumers of the inputfs event ring see smoothed coordinates;
smoothing is applied at exactly one point and there is no
client-facing opt-out.

This implements the compositor-to-kernel shared-memory surface
specified in
`inputfs/docs/adr/0015-per-user-pointer-smoothing.md`. It is the
second compositor-written, kernel-read region, peer to the focus
region (`shared/INPUT_FOCUS.md`,
`inputfs/docs/adr/0003-focus-publication.md`).

## Smoothing file

**Default path**: `/var/run/sema/input/smoothing`

The file is created (or truncated) by the compositor on startup
via `SmoothingWriter.init()` in `shared/src/input.zig`.

## Region layout

The region consists of a fixed header followed by a fixed-size
parameter block. All multi-byte fields are little-endian.

Total size: **32 bytes** (header 12 + parameter block 20).

### Header (12 bytes, offset 0)

| Offset | Size | Type | Field | Description |
|--------|------|------|-------|-------------|
| 0 | 4 | u32 | `magic` | `0x494E534D` ("INSM" when read as big-endian mnemonic; matches CLOCK.md convention) |
| 4 | 1 | u8 | `version` | Region format version (currently `1`) |
| 5 | 1 | u8 | `algorithm` | `0` = none, `1` = ema, `2` = one_euro |
| 6 | 1 | u8 | `smoothing_valid` | `0` = compositor initialising, `1` = parameters are live |
| 7 | 1 | u8 | `_pad0` | Reserved, zero |
| 8 | 4 | u32 | `seqlock` | Seqlock counter (see Concurrency model) |

### Parameter block (20 bytes, offset 12)

The parameter block is a fixed-size byte region whose
interpretation depends on `algorithm`. Bytes beyond the bytes an
algorithm uses are zero-filled. The fixed size accommodates the
largest v1 algorithm (One-Euro: 12 bytes used) plus 8 bytes
reserved for v2 algorithms.

All algorithm parameters are encoded in **Q16.16 signed
fixed-point** (i32). The integer part is the upper 16 bits and
the fractional part is the lower 16 bits. To convert: a
floating-point value `f` becomes `(i32) round(f * 65536.0)`.

#### `algorithm = 0` (`SMOOTHING_NONE`)

The parameter block is unused. All 20 bytes zero-filled.
Smoothing is identity: `out = in`.

#### `algorithm = 1` (`SMOOTHING_EMA`)

| Offset (rel) | Size | Type | Field | Description |
|--------------|------|------|-------|-------------|
| 0 | 4 | i32 | `alpha` | Q16.16 smoothing factor; valid range `[0x00CC, 0xFF34]` (≈ `[0.005, 0.995]`); default `0x4CCC` (≈ 0.30) |
| 4 | 16 | u8[16] | `_pad` | Reserved, zero |

EMA recurrence per axis:

```
out = (alpha * in + (Q16_ONE - alpha) * prev_out) >> 16
prev_out := out
```

where `Q16_ONE = 0x10000` and the multiplications widen to i64
to avoid intermediate overflow.

#### `algorithm = 2` (`SMOOTHING_ONE_EURO`)

| Offset (rel) | Size | Type | Field | Description |
|--------------|------|------|-------|-------------|
| 0 | 4 | i32 | `min_cutoff` | Q16.16 minimum cutoff frequency in Hz; default `0x10000` (= 1.0) |
| 4 | 4 | i32 | `beta` | Q16.16 speed coefficient; default `0x01CB` (≈ 0.007) |
| 8 | 4 | i32 | `d_cutoff` | Q16.16 derivative cutoff frequency in Hz; default `0x10000` (= 1.0) |
| 12 | 8 | u8[8] | `_pad` | Reserved, zero |

One-Euro is normatively defined by the canonical implementation
in `inputfs_smooth.c`. The algorithm is *inspired by* the
Casiez/Roussel/Vogel One-Euro paper but is specified by UTF in
fixed-point; bit-for-bit equivalence with floating-point One-Euro
implementations is not a goal. UTF One-Euro replays identically
against UTF.

The state machinery (previous smoothed coordinate, previous
derivative, previous tick) is per-axis and lives in the kernel
softc, not in this region.

## Concurrency model

The region uses a seqlock. The compositor is the sole writer;
inputfs is the sole reader.

Reader algorithm (inputfs side):

```zig
fn snapshot(self: SmoothingReader) !Snapshot {
    while (true) {
        const v1 = @atomicLoad(u32, &self.header.seqlock, .seq_cst);
        if (v1 & 1 != 0) continue; // write in progress

        const algorithm = @atomicLoad(u8, &self.header.algorithm, .seq_cst);
        const params = self.readParams();

        const v2 = @atomicLoad(u32, &self.header.seqlock, .seq_cst);
        if (v2 == v1) return .{
            .algorithm = algorithm,
            .params = params,
        };
    }
}
```

- `smoothing_valid` is set once (0 → 1) when the compositor has
  published a coherent first snapshot.
- Smoothing parameter updates are session-activation-rate
  (rare): one update on session login, one on session switch.
  Seqlock retry cost for inputfs is therefore negligible.
- Mid-event-stream parameter changes are atomic: one event uses
  the old algorithm, the next uses the new. There is no
  cross-fade; this matches focus behaviour and avoids
  interpolation machinery in the kernel.

## API

```zig
const input = @import("shared/src/input.zig");

// Writer (compositor only)
var writer = try input.SmoothingWriter.init(input.SMOOTHING_PATH);
defer writer.deinit();

writer.beginUpdate();
writer.setEma(0x4CCC);                       // α ≈ 0.30 in Q16.16
// or:
writer.setOneEuro(0x10000, 0x01CB, 0x10000); // min_cutoff, beta, d_cutoff
// or:
writer.setNone();
writer.endUpdate();

// Reader (inputfs only)
const reader = try input.SmoothingReader.init(input.SMOOTHING_PATH);
defer reader.deinit();

if (!reader.isValid()) {
    // Compositor not ready or region absent: fall back to identity.
    return raw_xy;
}

const snap = try reader.snapshot();
return snap.apply(prev_state, raw_xy);
```

## Lifecycle

- Compositor startup: region created/truncated with
  `smoothing_valid = 0`. Defaults from
  `/etc/inputfs/smoothing.conf` are written and the region is
  marked valid.
- User session activation: compositor reads
  `~/.config/semainput/smoothing.conf` for the activating user
  and republishes the region under seqlock. Parameters take
  effect from the next pointer event.
- Session switch between users: same path; the compositor
  re-reads the new owner's per-user config and republishes.
- Compositor exit or crash: file persists with last consistent
  state. inputfs continues smoothing per the last published
  parameters until the next compositor startup truncates the
  region (and writes `smoothing_valid = 0` momentarily before
  publishing). During the truncation window, inputfs falls
  back to identity per the failure-mode rules below.

## Failure modes

- **Compositor not running** or **region file absent**: inputfs
  falls back to `SMOOTHING_NONE` (identity). Pointer events
  carry transformed but unsmoothed coordinates. This is the
  pre-AD-2b behaviour and is the deliberate fallback for any
  state in which the region cannot be read.
- **`smoothing_valid = 0`**: same as absent. inputfs treats the
  region as not yet authoritative.
- **Unknown version**: inputfs refuses to interpret, logs once,
  falls back to `SMOOTHING_NONE`. Logs do not repeat per event;
  the warning fires when version transitions to an unknown
  value, not on every read.
- **Unknown algorithm**: same as unknown version. inputfs
  recognises algorithms `0`, `1`, `2` in v1; any other value
  causes fallback to identity.
- **Out-of-range parameters** (e.g., EMA `alpha` outside
  `[0x00CC, 0xFF34]`, One-Euro frequencies ≤ 0): inputfs clamps
  to the valid range and continues. The compositor is
  responsible for range-checking before writing; clamping in
  the kernel is defence in depth.
- **mmap failure**: transient; the kthread refresh path
  retries periodically. Until success, fallback to identity.
- **Compositor crash mid-update**: seqlock detects partial
  write; reader retries until next consistent snapshot. During
  the window, the last valid snapshot is used.
- **Reads ignoring seqlock**: undefined. Always use
  `SmoothingReader` helpers.

## Versioning

`version = 1`. Backwards-compatible additions (new reserved
fields within existing parameter blocks, new algorithms in the
range `[3, 255]` with their own parameter layouts within the
existing 20-byte block) do not bump the version. Breaking
changes (parameter-block size change, field repurposing,
representation change away from Q16.16) increment the version.
Readers reject unknown versions per the failure-mode rules.

## Magic value encoding

Following `shared/CLOCK.md`, `shared/INPUT_STATE.md`,
`shared/INPUT_EVENTS.md`, and `shared/INPUT_FOCUS.md`: the magic
u32 is written so its big-endian byte representation spells the
mnemonic ("INSM" → `0x494E534D`). On disk (little-endian) the
bytes are `4D 53 4E 49`. Code compares the loaded u32 directly
against the constant.

## Integration with inputfs and the compositor

The compositor is the only writer. semadrawd's per-user config
loader, session-activation hook, and parameter publication all
flow through `SmoothingWriter`. inputfs reads via
`SmoothingReader` on the same kthread refresh path that serves
the focus region; the snapshot is consulted in the interrupt
path between D.3 transform and D.4 routing.

Smoothing rules (per pointer event):

1. Read transformed coordinate `(tx, ty)` from D.3.
2. Snapshot the smoothing region. If invalid or absent, set
   `(sx, sy) := (tx, ty)`.
3. If valid: apply the algorithm to update per-axis state and
   produce smoothed `(sx, sy)`.
4. Use `(sx, sy)` for the D.4 routing decision and for the
   coordinate fields of the published pointer event.

The previous coordinate transform's output is *not* published
separately. The kernel substrate's output is the smoothed
coordinate by definition. Tools that need to inspect raw
device coordinates use `inputdump` and `smoothing-inspect`,
which read kernel state directly via diagnostic interfaces
rather than the event ring.

## Diagnostic tooling

A CLI `smoothing-inspect` (paralleling `inputdump` and
`chrono_dump`) reads the region and reports:

- Current header (magic, version, algorithm, valid byte,
  seqlock value).
- Current parameters decoded from Q16.16 to floating-point for
  human display.
- Optional live mode: alongside reading the region, attach to
  the event ring and a kernel-side raw-coordinate trace
  (debug-only sysctl, off by default) to display raw vs
  smoothed trajectories. The raw trace is for development and
  is not a production interface.

References:

- `inputfs/docs/adr/0003-focus-publication.md`
- `inputfs/docs/adr/0012-stage-d-scope.md`
- `inputfs/docs/adr/0015-per-user-pointer-smoothing.md`
- `shared/INPUT_FOCUS.md`
- `shared/INPUT_STATE.md`
- `shared/INPUT_EVENTS.md`
