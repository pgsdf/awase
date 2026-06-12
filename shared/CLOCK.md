# Clock Publication

## Purpose

The clock region is a small memory-mapped file written by the `audiofs`
kernel module (the clock writer since F.4, ADR 0018; semaaud, the original
userland writer, was retired under F.6, ADR 0029) and read by all other
daemons. It exposes the audio hardware clock — a monotonically increasing
count of PCM sample frames clocked out by the codec — as a shared memory
region accessible without any IPC round-trip.

This is the foundation of the chronofs temporal coordination layer. All
timestamped events across the fabric carry `ts_audio_samples`, read from this
region at emission time.

## Clock file

**Default path**: `/var/run/sema/clock`

The file is created by the audiofs kernel module when it loads (the
audiofs rc.d service runs after FILESYSTEMS). The `/var/run/sema/`
directory is created if absent. `ClockWriter` in `shared/src/clock.zig`
is retained as a test fixture only.

## Region layout

Total size: **20 bytes**. All fields are little-endian.

| Offset | Size | Type | Field | Description |
|--------|------|------|-------|-------------|
| 0 | 4 | u32 | `magic` | `0x534D434B` ("SMCK") |
| 4 | 1 | u8 | `version` | Region format version (currently `1`) |
| 5 | 1 | u8 | `clock_valid` | `0` = no stream started, `1` = clock is live |
| 6 | 1 | u8 | `clock_source` | `0` = invalid, `1` = audio, `2` = wall (reserved), `3` = tsc (reserved) |
| 7 | 1 | u8 | `_pad` | Reserved, zero |
| 8 | 4 | u32 | `sample_rate` | PCM sample frames per second |
| 12 | 8 | u64 | `samples_written` | Monotonic sample frame counter (atomic) |

The `u64` at offset 12 is **not** naturally aligned: offset 12 is a 4-byte
boundary, not an 8-byte one. The field is published by a single store and
read by a single load, and that store is single-copy-atomic only by virtue
of the region being mapped at a page-aligned address, which keeps the eight
bytes at offsets 12-19 inside one cache line. On amd64 a store that does not
cross a cache-line boundary is atomic even when unaligned, so the field is
safe on the architecture UTF ships on (pgsd-bare-metal, amd64).

This is an amd64-scoped guarantee, not a portable one. On a non-x86,
non-TSO target (for example aarch64) a 64-bit access to a 4-byte-aligned
address is not guaranteed single-copy-atomic and may fault; that target
would require `samples_written` to be 8-byte aligned (move it to offset 16
with explicit padding), which is a format change and a `version` bump. The
field is left at offset 12 for v1 to preserve compatibility; the constraint
is recorded here so a future port does not rediscover it the hard way.

### clock_source: observability metadata

`clock_source` exists to let readers and diagnostic tools identify which
writer produced the region without guessing. UTF's clock is audio-driven
by construction (see `docs/Thoughts.md` and
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md`); this field does not enable a
runtime fallback to a different clock source. Values 2 (wall) and 3 (tsc)
are reserved for writers that may exist in test scaffolding or
alternative builds; they are not used by the canonical UTF stack.

The field was promoted from a previously-reserved padding byte at offset 6
without bumping `version`. Compatibility holds in both directions:

- Old writers (which wrote 0 at offset 6) appear to readers as
  `clock_source = invalid`. This is accurate semantics for legacy data:
  the old writer did not advertise a source, so the reader should not
  assume one.
- Old readers (which ignored the byte at offset 6) continue to function
  unchanged. They read `clock_valid` and `samples_written` exactly as
  before.

A reader that depends on `clock_source` being meaningful should check
`clock_valid == 1` first; the SeqCst store on `clock_valid` (written
last by `streamBegin`) provides the happens-before edge that guarantees
`clock_source` is also visible.

## Concurrency model

`samples_written` is published by a single little-endian `u64` store and read
with `@atomicLoad(..., .seq_cst)` by all readers. No mutex is required. The
store's single-copy atomicity is the amd64 within-cache-line guarantee
described under "Region layout" above, not natural alignment. Readers use
sequential consistency so that a reader seeing `clock_valid = 1` also sees the
correct `sample_rate` written before it.

`clock_valid` is written once (0 → 1) by the writer's stream-begin path and
never reset for the lifetime of the writer. It is written with a release store
and read with an acquire-or-stronger load, which provides the happens-before
edge on every supported architecture.

**Writer transition (ADR 0018, F.4).** The production writer moves from
`semaaud` (userland, OSS-handoff count) to `audiofs` (kernel, codec
clocked-out count) via a shared kernel mapping of this file. `ClockWriter` in
`shared/src/clock.zig` is retained after that transition as a test and
diagnostic fixture, not the production writer. The wire format and this
document are unchanged by F.4; only the identity of the writer changes.

## API

```zig
const clock = @import("path/to/shared/src/clock.zig");

// --- writer (historical userland form; production writer is audiofs) ---

var writer = try clock.ClockWriter.init(clock.CLOCK_PATH);
defer writer.deinit();

// Called when a PCM stream begins:
writer.streamBegin(48_000);  // sample_rate in Hz

// Called after each successful posix.write() to the OSS device:
writer.update(total_samples_written);  // cumulative count

// --- other daemons (reader) ---

const reader = clock.ClockReader.init(clock.CLOCK_PATH);
defer reader.deinit();

if (reader.isValid()) {
    const samples = reader.read();         // u64 sample frame count
    const rate    = reader.sampleRate();   // u32 Hz
    const ns      = clock.toNanoseconds(samples, rate);
}
```

## Lifecycle

1. `semaaud` starts and calls `ClockWriter.init()`. The file is created with
   `clock_valid = 0` and `samples_written = 0`.
2. `semainput`, `semadraw`, and chronofs start and call `ClockReader.init()`.
   `isValid()` returns false. Events carry `ts_audio_samples: null`.
3. A PCM client connects to semaaud. `ClockWriter.streamBegin(sample_rate)` is
   called. `clock_valid` becomes `1`. `isValid()` returns true on all readers.
4. The stream worker calls `ClockWriter.update(n)` after each write batch.
   Readers see the updated counter with no IPC overhead.
5. The stream ends. `clock_valid` remains `1`. `samples_written` holds the
   final position. New streams resume from that position (monotonic).
6. `semaaud` exits. The file remains on disk (unless `/var/run` is a tmpfs
   that is cleared on reboot). The next `semaaud` start overwrites it with
   `truncate = true`.

## `toNanoseconds`

```zig
pub fn toNanoseconds(samples: u64, sample_rate: u32) u64
```

Converts a sample position to nanoseconds using a u128 intermediate to avoid
overflow. Returns 0 if `sample_rate` is 0.

At 48kHz, 1 second = 48,000 samples. At 96kHz, 1 second = 96,000 samples.

## Integration with semaaud

`semaaud`'s stream worker (A-2) already maintains `Shared.samples_written` as
an `std.atomic.Value(u64)`. The S-4 integration in `main.zig` creates a
`ClockWriter` at startup and passes it to the stream worker, which calls
`writer.update(shared.samples_written.load(.monotonic))` after each write batch.

See `semaaud/BACKLOG.md` item A-3 for the full integration plan.
