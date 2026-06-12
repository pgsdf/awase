# 0018 F.4: audiofs clock writer

## Status

Accepted, 2026-06-01. Proposed 2026-05-30; revised
2026-06-01 after design review (see "Revision history");
ratified the same day after bench verification on
pgsd-bare-metal.

Per ADR 0011, F.4 is the fifth audiofs F-stage milestone,
depending on F.3.c (interrupt-driven position tracking,
bench-verified `[x]` 2026-05-31, ADR 0016). F.4's scope
per ADR 0011: "audiofs takes over `/var/run/sema/clock`
writing from semaaud; userland clock writer is retired."

This ADR makes the kernel-side commitments concrete. The
wire format and semantic decisions live in ADR 0003 (Clock
writer, Accepted 2026-05-11); this ADR does not reopen
them. It specifies how audiofs implements what ADR 0003
already decided: the file path, layout, semantics of
`samples_written` as "frames the codec has actually
clocked out," and the update cadence "each audio interrupt
that reflects new frames clocked out."

This ADR does not reverse, reopen, or amend ADRs
0001-0017. It scopes the F.4 sub-stage within the F-stage
map. Implementation follows in a separate commit after
ratification, in the same shape as prior F-stages
(kernel change + bench), with explicit bench-safety review
before the new behavior reaches the iMac (per ADR 0014's
post-bench amendment discipline).

## Context

audiofs has, as of F.3.c, an accurate kernel-side count of
frames the codec has clocked out. The per-interrupt
counter `output_stream_frames_played` in the softc is
advanced inside `audiofs_intr_thread` from each LPIB
snapshot (audiofs.c lines 4557 and, for the final
fragment, 5022). ADR 0003 section 2 defines the published
value `samples_written` as:

> `samples_written` represents the count of frames the
> codec has actually clocked out, as reported by FreeBSD's
> `snd(4)` buffer-pointer mechanism. It is not the count
> of frames the kernel has handed to the codec, and not
> the count of frames userland has written to a device
> file.

The kernel has the per-interrupt frame delta. F.4 is the
work of accumulating it into a monotonic counter and
publishing that counter to `/var/run/sema/clock` on each
update.

The userland writer (semaaud's `ClockWriter` in
`shared/src/clock.zig`) currently writes the file from
userland after each `posix.write(audio_fd, ...)`. The
value it writes is the OSS-handed-off count, not the
codec-clocked-out count. Replacing semaaud's writer with
audiofs's improves both:

  - **Precision.** OSS-handed-off and codec-clocked-out
    differ by the codec FIFO depth (10-50 ms on HDA,
    typically ~21 ms at the bench's fragment rate). audiofs
    reads the FIFO-aware position; semaaud cannot.

  - **Cadence.** The OSS write cadence is bounded by how
    often userland completes a `posix.write` and then
    calls `ClockWriter.update()`. The audio-interrupt
    cadence on the bench is fixed at ~21 ms (the fragment
    rate), driven by hardware; it does not degrade under
    userland scheduling load.

Both are stated as F.4 motivations in ADR 0003. F.4 is the
implementation that delivers them.

## Decision

### 1. File ownership

audiofs claims `/var/run/sema/clock` as a kernel-owned
publication. semaaud's production use of the clock writer
in `shared/src/clock.zig` is removed (the call sites in
`semaaud/src/main.zig` and `semaaud/src/stream_worker.zig`).
The `ClockReader` type stays unchanged because it is
consumed by chronofs, semadraw, and semainput; reader code
is unaffected by the writer change.

The `ClockWriter` struct itself stays in
`shared/src/clock.zig`, re-scoped from "production writer"
to "test and diagnostic fixture." It is still referenced by
test code in three modules and removing the struct would
break those builds (see Decision 5). It is no longer the
production writer; audiofs is.

The wire format does not change. All 20 bytes per
`shared/CLOCK.md`: magic `SMCK`, version 1, clock_valid,
clock_source = 1 (audio), sample_rate, samples_written.

### 2. Write mechanism: shared kernel mapping of the file

audiofs holds a long-lived kernel mapping of the clock
file's backing page across module lifetime, and writes the
region through that mapping. On the global publication
init (the same one-time path that opens the F.1 state and
F.2 events files in `audiofs_state_register`), audiofs:

  1. `vn_open`s `/var/run/sema/clock` with
     `O_CREAT | O_TRUNC`, mirroring
     `audiofs_state_open_file` (mkdir of `/var/run/sema`,
     `VOP_SETATTR` for uid/gid/mode).
  2. Sizes it to one page via `VOP_SETATTR` (va_size).
     The region is 20 bytes; the mapping is page-granular,
     so the file occupies the first 20 bytes of one page.
  3. Obtains the vnode's VM object
     (`vnode_create_vobject`), references it, and maps it
     into kernel virtual address space with `vm_map_find`
     against `kernel_map` (`VM_PROT_READ | VM_PROT_WRITE`).
  4. **Wires the page** with `vm_map_wire`
     (`VM_MAP_WIRE_SYSTEM | VM_MAP_WIRE_NOHOLES`). This is
     not optional. The per-interrupt update stores into
     this mapping from the ithread; an unwired page could
     be reclaimed under memory pressure, and a store to a
     non-resident page would fault and require I/O from
     interrupt-thread context. Wiring guarantees the
     per-interrupt store is a single memory access that
     never faults.

Per-interrupt updates are then direct stores at the mapped
address. No `vn_rdwr` per interrupt: the file pages are
mapped, not copied, so a userland reader that has
`mmap`'d the same file sees each store immediately and
coherently (shared backing pages on tmpfs).

**Why a shared mapping and not `vn_rdwr` like the F.1/F.2
files.** The F.1 state and F.2 events files are published
with `vn_rdwr` (audiofs.c `audiofs_state_write_region`,
`audiofs_events_publish`). That is safe for those regions
because their wire formats carry a seqlock (state header
`seqlock`, written odd-before / even-after) or a per-slot
sequence (events ring), which lets a reader detect and
retry a torn snapshot. The clock wire format has neither.
ADR 0003 specifies a seqlock-free region whose
`samples_written` is published by a single atomic store
that a concurrent reader observes whole. `vn_rdwr` copies
a buffer into the file page through `uiomove` and a
concurrent reader can observe the copy mid-flight; it
cannot satisfy the clock's atomic-store contract. A shared
mapping can: an aligned-within-cache-line store is
single-copy-atomic on the writer side and visible whole on
the reader side (see Decision 3). The mapping is therefore
a consequence of ADR 0003's format, not a free choice.

Concrete shape:

```c
struct audiofs_clock {
    struct vnode  *vp;      /* held across module lifetime */
    vm_object_t    obj;     /* referenced backing object */
    vm_offset_t    kva;     /* kernel mapping of the page  */
    int            mapped;  /* 1 once kva is live + wired  */
};

static void audiofs_clock_open(struct thread *td);   /* open+size+map+wire */
static void audiofs_clock_close(struct thread *td);  /* unwire+unmap+deref+close */
static void audiofs_clock_stream_begin(struct audiofs_softc *sc,
    uint32_t sample_rate);                            /* set rate, valid=1 */
static void audiofs_clock_update(struct audiofs_softc *sc); /* store offset 12 */
```

`audiofs_clock_update` is the hot-path call: it stores
`sc->clock_samples_total` (Decision 4) as a u64 at offset
12 in the mapped page. Called inline from
`audiofs_intr_thread` after the per-interrupt accumulation.

### 3. Atomic ordering and architecture scope

`clock_valid` (u8 at offset 5) is written 0 once at open,
then 1 once at the first `stream_begin`, never reset. It is
written with `atomic_store_rel_8()` (release). Readers load
it seq_cst (acquire-or-stronger) before reading
`sample_rate` and `samples_written`, per `CLOCK.md`'s
concurrency model. The release-store on the writer paired
with the acquire-load on the reader provides the
happens-before edge that guarantees a reader seeing
`clock_valid = 1` also sees the matching `sample_rate` and
an initial `samples_written`. This edge holds on every
FreeBSD-supported architecture.

`samples_written` (u64 at offset 12) is the per-interrupt
hot field. It is **not** naturally aligned: offset 12 is
4-byte aligned, not 8-byte. On amd64 the store is still
single-copy-atomic, because the region is mapped at a
page-aligned address and the eight bytes at offsets 12-19
fall entirely within the first cache line; x86 guarantees
atomicity for an unaligned access that does not cross a
cache-line boundary. This is the only architecture audiofs
ships on today (pgsd-bare-metal, amd64), and the F.4 writer
is scoped to it.

This scope is explicit. On a non-TSO, non-x86 target
(for example aarch64), a 64-bit store to a 4-byte-aligned
address is not guaranteed single-copy-atomic and may fault;
the field would have to be 8-byte aligned first. That is a
wire-format change (move `samples_written` to offset 16 with
explicit padding, version bump) and therefore an amendment
to ADR 0003 and `CLOCK.md`, not something F.4 does. F.4
records the constraint so a future port does not discover
it the hard way. See "Rejected alternatives."

The in-kernel accumulator `clock_samples_total` (Decision
4) is a softc field and therefore naturally 8-byte aligned;
the ithread advances it (single writer) and the publish
path reads it with `atomic_load_64`, which is correct on
all architectures. Only the wire field at offset 12 carries
the amd64 scope.

### 4. Monotonic accumulator (the value published)

The published `samples_written` must be monotonic across
stream stop/start, per `CLOCK.md` ("Monotonic sample frame
counter") and ADR 0003 section 4. The per-interrupt counter
`output_stream_frames_played` is **not** suitable to publish
directly: `audiofs_stream_begin` resets it to 0
(audiofs.c:4771), so publishing it verbatim would saw the
clock back to zero on every new stream.

F.4 adds a separate softc field:

```c
uint64_t clock_samples_total;  /* monotonic; never reset per stream */
```

  - Zeroed once at attach (softc is zero-allocated by
    newbus; not reset in `stream_begin`).
  - Advanced by the same per-interrupt delta as
    `output_stream_frames_played`, at both accumulation
    sites: the ithread (audiofs.c:4557) and the final
    fragment captured in `stream_end` (audiofs.c:5022).
  - Published as `samples_written`.

This makes the published clock monotonic by construction
across any number of stop/start cycles within one module
load. On module unload/reload a fresh softc starts the
accumulator at 0, which matches ADR 0003's fresh-load
lifecycle (attach leaves `samples_written = 0` until the
first stream).

`output_stream_frames_played` keeps its existing
per-stream semantics untouched; F.4 reads its delta but
does not change its reset behavior.

### 5. Userland writer changes

`shared/src/clock.zig`:
  - `ClockWriter` is **kept**, re-scoped via its doc
    comment from "used by semaaud" to "test and diagnostic
    fixture; the production writer is audiofs (ADR 0018)."
  - Its tests are kept.
  - The misleading "naturally aligned / sequentially
    consistent" comment on the offset-12 store is corrected
    to state the real basis (within-cache-line atomicity on
    amd64), matching `CLOCK.md`.
  - `ClockReader`, `toNanoseconds`, and all constants are
    unchanged.

The struct is retained because it is consumed as a test
fixture by code outside semaaud:
  - `chronofs/src/clock.zig` test "Clock wraps ClockReader
    correctly" (constructs a clock file to exercise the
    reader).
  - `semadraw/src/compositor/frame_scheduler.zig` two
    tests ("nextFrameTarget with MockClock via
    shared_clock.ClockWriter" and the writer fixture
    below it).

Removing the struct (as the prior draft of this ADR
proposed) would break `zig build test` in both modules.
The prior draft's claim that semaaud was the only consumer
was incorrect.

`semaaud`:
  - Remove the `ClockWriter.init`/`deinit` call sites and
    the "clock region published" log in `main.zig`.
  - Remove the `clock_writer` field and the
    `stream_begin_published` latch from the `Shared` struct
    in `stream_worker.zig`, the `streamBegin` call, and the
    `writer.update(new_total)` call. The internal
    `samples_written` atomic is kept (it feeds event
    metadata and state snapshots; only the clock-region
    mirror is removed).

semaaud continues to perform its other functions. The clock
writer was one responsibility; removing it does not require
the daemon to be restructured.

### 6. Lifecycle

**At global publication open** (the one-time block in
`audiofs_state_register` that opens the state and events
files):
  - `audiofs_clock_open(td)` runs alongside
    `audiofs_state_open_file` / `audiofs_events_open_file`.
  - Writes the static header into the mapping: magic,
    version, clock_valid=0, clock_source=1, _pad=0,
    sample_rate=0, samples_written=0. Matches ADR 0003
    section 4 (Lifecycle).
  - If `vn_open`, the object lookup, the `vm_map_find`, or
    the `vm_map_wire` fails, audiofs logs a warning and
    proceeds with `mapped = 0`. audiofs still functions for
    playback; only chronofs's audio-derived timestamps
    degrade to their no-clock fallback. F.4 is not
    load-bearing for audio playback.

**At stream_begin** (per F.3.a's `audiofs_stream_begin`):
  - `audiofs_clock_stream_begin(sc, rate)` is called from
    the existing sleepable section that already takes
    `audiofs_state_sx` for the F.2 stream_begin event.
  - Writes `sample_rate` to offset 8 and `clock_source` to
    offset 6, then `atomic_store_rel_8` clock_valid=1 at
    offset 5 (valid written last).
  - Does **not** reset `clock_samples_total`.
  - Idempotent after the first call: a stop-start cycle
    leaves clock_valid at 1 (matching semaaud and ADR 0003
    section 4).

**On audio interrupt** (per F.3.c's `audiofs_intr_thread`):
  - After `output_stream_frames_played` is advanced from
    the LPIB delta, audiofs advances `clock_samples_total`
    by the same delta and calls `audiofs_clock_update(sc)`,
    a single u64 store at offset 12 in the wired mapping.
  - The store happens inline in the ithread. The page is
    wired, so the store cannot fault; it is one
    instruction. No `vn_rdwr`, no taskqueue hop.

**At stream_end** (per F.3.a's `audiofs_stream_end`):
  - The final-fragment delta already captured at
    audiofs.c:5022 advances `clock_samples_total` as well,
    and `audiofs_clock_update(sc)` is called once more so
    the published count reflects the final frame.
  - clock_valid stays at 1; samples_written stays at its
    last value. Next stream_begin continues from there
    (now true, because of Decision 4). Per ADR 0003
    section 4.

**At module detach** (per audiofs's existing
`audiofs_detach` and the global teardown in the
last-controller path):
  - `audiofs_clock_close(td)` runs in the global teardown
    under `audiofs_state_sx`, alongside
    `audiofs_events_close_file` and `audiofs_state_close_file`.
  - A separate unwire call is not required:
    `vm_map_remove` over the mapped range unwires and
    removes it. Then `vm_object_deallocate` drops the
    reference and `vn_close` releases the vnode.
  - The file at `/var/run/sema/clock` remains on disk with
    its last values (clock_valid=1, last samples_written,
    last sample_rate). This is a deliberate divergence from
    the state file, which is rewritten with state_valid=0
    on teardown: ADR 0003 section 4 specifies the clock
    persists valid with its last values, matching semaaud.
    A code comment records the divergence.

### 7. What F.4 does NOT do

  - Does not change the wire format. ADR 0003 commits to
    the 20-byte layout; F.4 implements writes to it.
  - Does not add a seqlock to the clock region (that would
    be a wire-format change; see Rejected alternatives).
  - Does not add new event types or extend the F.2 events
    ring schema.
  - Does not change `output_stream_frames_played`'s
    semantics; F.4 reads its delta and adds a parallel
    monotonic accumulator.
  - Does not block on chronofs's consumption logic.
    chronofs already reads the clock region; the change is
    transparent on the reader side.
  - Does not introduce sysctl-controlled toggles to
    enable/disable the writer. audiofs writes
    unconditionally when loaded and the mapping succeeded.

## Rejected alternatives

**A. `vn_rdwr` publication plus a seqlock (the F.1/F.2
pattern).** Unify the clock with the state and events files:
write the 20-byte buffer with `vn_rdwr` from a sleepable
context (taskqueue_fast, as F.3.d already does for xrun
events), and add a seqlock field to the clock region so the
reader can detect a torn copy. This is the most consistent
mechanism within audiofs and removes the kernel-mapping
complexity and its load/unload hazards entirely. It was
rejected for F.4 because adding a seqlock changes the wire
format: it reopens ADR 0003 and `CLOCK.md` (version bump),
and requires updating every reader (`ClockReader`,
chronofs, semadraw, semainput) and the diagnostic tooling.
That is a larger, separable decision. If a future target
forces a wire-format revision anyway (the aarch64 alignment
case in Decision 3), folding a seqlock in at the same time
and switching to the `vn_rdwr` mechanism is the natural
move, and would let audiofs retire the kernel mapping. F.4
stays inside ADR 0003's current contract.

**B. cdev-backed shared region.** audiofs allocates a
kernel-owned VM object and exposes it via `d_mmap_single`
on a cdev; userland mmaps the cdev. This is the most
idiomatic FreeBSD zero-copy kernel/userland sharing and
avoids mapping a vnode. Rejected because it changes the
publication surface from the file path `/var/run/sema/clock`
to a device node, which ADR 0003 fixed as a file and which
`ClockReader` opens by path. Adopting it reopens ADR 0003
and changes every reader. Out of F.4 scope.

## Consequences

**Positive:**

  - chronofs gets a sample-accurate, monotonic audio clock
    instead of an OSS-write-rate approximation. The
    accuracy improvement is real but modest (~21 ms on this
    bench); the monotonicity fix is a correctness gain.
  - semaaud shrinks. Its remaining responsibilities are
    smaller; F.6's eventual retirement becomes a smaller
    commit.
  - audiofs becomes the sole clock authority; future work
    on clock semantics (multi-stream, format-change
    handling) lives in one place.

**Negative:**

  - audiofs holds a long-lived kernel mapping of a vnode
    page across module lifetime. If the unmap path is buggy
    the vnode or the wired page is leaked. The
    implementation must be tested through repeated
    kldload/kldunload cycles (see bench plan).
  - Mapping and wiring a vnode page into `kernel_map` is a
    less commonly used kernel idiom than `vn_rdwr` or
    userland mmap; the implementation may surface
    kernel-API issues not visible elsewhere in audiofs.
    This is the highest-risk part of F.4 and the bench plan
    targets it specifically.
  - The amd64 atomicity scope (Decision 3) is a latent
    portability constraint, recorded but not removed.

**Reversible:**

  - F.4 is reversible by unloading audiofs. The clock file
    persists with its last values; readers see a static
    clock until audiofs reloads. Reinstating semaaud as
    writer is a separate decision (the production call sites
    removed in Decision 5 would have to be restored).
  - The wire format does not change. Any code that reads
    the clock region works whether audiofs or the
    (re-scoped) test fixture wrote it.

**Independent of:**

  - Q2 (mixer location). F.4 publishes the single active
    output stream's monotonic count. A future multi-output
    design would pick one stream as canonical or aggregate;
    neither is F.4's concern.
  - Q3 (OSS coexistence, ADR 0002). audiofs is the
    canonical writer when loaded; OSS does not publish to
    this region.

## Closure criteria

F.4 closes when:

  1. `audiofs_clock_open` runs at the global publication
     init, creates/truncates `/var/run/sema/clock`, sizes
     it, maps and wires the page, and writes the static
     header (magic, version, clock_valid=0, clock_source=1,
     _pad=0, sample_rate=0, samples_written=0).

  2. `audiofs_clock_stream_begin` writes sample_rate and
     clock_source and `atomic_store_rel_8`s clock_valid=1
     on each stream_begin (idempotent after the first), and
     does not reset `clock_samples_total`.

  3. `clock_samples_total` is advanced by the per-interrupt
     delta at both audiofs.c:4557 and audiofs.c:5022, and
     `audiofs_clock_update` stores it at offset 12 inline
     from the ithread and once at stream_end.

  4. `audiofs_clock_close` unmaps (unwiring via
     `vm_map_remove`), dereferences the object, and closes
     the vnode at module detach; the file persists on disk
     with its last values.

  5. `shared/src/clock.zig`'s `ClockWriter` is retained and
     re-scoped as a test fixture; its tests pass;
     `ClockReader`, `toNanoseconds`, and constants are
     preserved; the offset-12 alignment comment is
     corrected.

  6. semaaud's production clock-writer call sites are
     removed and `zig build test` passes in semaaud,
     chronofs, and semadraw.

  7. The `audiofs/tools/clock_dump/` tool reads and decodes
     `/var/run/sema/clock`. During a single playtone run it
     shows: clock_valid flips 0 to 1 at stream_begin;
     samples_written advances monotonically; the rate
     matches `output_stream_frames_played` within one
     fragment; at end, samples_written equals the stream's
     `frames_total`; sample_rate is 48000 throughout.

  8. **Monotonicity across streams.** Two back-to-back
     playtone runs (stop, then start again) without
     reloading the module show samples_written continuing to
     advance from the first run's final value and never
     regressing at the second stream_begin. This is the test
     that the Decision 4 accumulator is correct; a single
     run cannot exercise it.

  9. **Load/unload integrity.** Five kldload/kldunload
     cycles with a playtone run in between each show no
     panic, no WITNESS complaint, no vnode-leak warning, no
     wired-page accounting warning, and a clean
     `vmstat -m` / `vmstat -z` for audiofs allocations
     before and after.

 10. `dmesg` shows no panics, no WITNESS complaints, no
     traps across the above.

 11. Operator marks F.4 `[x]` on `pgsd-bare-metal`.

## Bench test plan

Before bench, dev-side: rebuild audiofs.ko with the F.4
changes; rebuild semaaud without its clock writer calls;
`zig build test` in semaaud, chronofs, and semadraw passes;
build `audiofs/tools/clock_dump`.

On the bench, in order:

  1. `git pull` to the F.4 commit.
  2. `cd audiofs && sudo ./build.sh all` to rebuild and
     reload the kernel module.
  3. `cd audiofs/tools/clock_dump && make`.
  4. Confirm semaaud is not running:
     `pgrep semaaud && sudo killall semaaud`.
  5. `sudo rm -f /var/run/sema/clock`.
  6. `sudo kldload audiofs`; `ls -la /var/run/sema/clock`
     (expect a page-sized or 20-byte file after attach).
  7. `sudo ./tools/clock_dump/clock_dump`: expect
     clock_valid=0, clock_source=1, sample_rate=0,
     samples_written=0.
  8. `sudo ./tools/playtone/playtone /dev/audiofs0 5`.
  9. During playback, sample the clock several times via
     clock_dump.
 10. After playback, capture final state. Verify
     clock_valid=1, sample_rate=48000, samples_written
     advanced monotonically, final within one fragment
     (~1024 frames) of `frames_total` from the stream_end
     log line.
 11. **Stop-start monotonicity (criterion 8).** Without
     unloading, run a second `playtone ... 5`. Sample
     clock_dump during it. Verify samples_written at the
     second stream's start is at least the first run's final
     value, and advances from there. No regression to ~0.
 12. **Load/unload integrity (criterion 9).** Repeat
     kldload, playtone, clock_dump, kldunload five times.
     After each kldunload, `ls -la /var/run/sema/clock`
     (file persists). Check `vmstat -m | grep audiofs` and
     `dmesg` for leaks/panics/WITNESS.
 13. Final `sudo kldunload audiofs`; verify the file still
     exists with its last values.

## References

  - ADR 0003 (Clock writer, 2026-05-11): the contract F.4
    implements; the seqlock-free atomic-store format that
    forces the shared-mapping mechanism.
  - ADR 0011 (F-stage reconciliation, 2026-05-28): the F.4
    placement in the F-stage map.
  - ADR 0016 (F.3.c, 2026-05-31): the predecessor that
    provides the per-interrupt frame delta.
  - ADR 0017 (F.3.d, 2026-05-30): the taskqueue_fast
    deferral pattern referenced in Rejected alternative A.
  - `shared/CLOCK.md`: the wire format specification
    (alignment note corrected alongside this ADR).
  - `shared/src/clock.zig`: `ClockWriter` re-scoped to a
    test fixture; `ClockReader` and `toNanoseconds`
    preserved.
  - `audiofs/sys/dev/audiofs/audiofs.c`: accumulation sites
    (4557, 5022), the `output_stream_frames_played` reset
    (4771), and the F.1/F.2 publication helpers the clock
    open/close mirror.

## Revision history

  - 2026-05-30: first draft. Proposed publishing
    `output_stream_frames_played` directly via a kernel
    mmap, with no monotonic accumulator, no page wiring,
    and removal of `ClockWriter`.
  - 2026-06-01: revised after design review. Four
    corrections: (1) publish a never-reset
    `clock_samples_total` accumulator, not the per-stream
    counter, so the clock is monotonic across stop/start;
    (2) wire the mapped page so the per-interrupt ithread
    store cannot fault; (3) state the offset-12 store's
    real atomicity basis (within-cache-line on amd64) and
    scope the writer to amd64, recording the non-TSO
    alignment constraint; (4) keep `ClockWriter` as a test
    fixture rather than removing it, since chronofs and
    semadraw tests depend on it. Added the contract-level
    justification for the shared-mapping mechanism and the
    two rejected alternatives (vn_rdwr+seqlock, cdev), and
    extended the closure criteria and bench plan with the
    stop-start monotonicity run and the load/unload
    integrity run.
  - 2026-06-01: ratified, Accepted, after bench
    verification on pgsd-bare-metal. Implementation took
    two build-time fixes (vm/pmap.h include order before
    vm/vm_map.h; curthread for the teardown clock close)
    and one cosmetic tool fix (clock_dump magic byte
    order). Criterion 8 (stop-start monotonicity) proven:
    three back-to-back stream_end totals (233445 + 281573
    + 137189) summed to the exact published reading
    652207, no regression across stops. Criterion 9
    (load/unload integrity) clean: VM object and vnode
    counts flat across 70 kldload/kldunload cycles, dmesg
    free of panics/WITNESS/traps, clock file persists.
    Final samples_written equals the kernel's stream_end
    frames_total exactly (codec clocked-out, below the
    userland handoff by the FIFO/buffer tail, as intended).
