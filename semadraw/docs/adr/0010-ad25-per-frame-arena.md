# ADR 0010: AD-25 Round U2 fix, a per-frame arena for the render hot path

## Status

Accepted 2026-06-07 (operator-ratified in session).

This ADR addresses the throughput half of AD-25 (cursor motion
smoothness), the Round U2 finding that followed ADR 0009's wakeup
fix. It changes the semadraw daemon only.

## Context

ADR 0009 fixed the wakeup: the loop now wakes at the event rate
(motion truss, 2026-06-07: main poll woken 521 times, timed out 6,
in 5 s; the kqueue bridge delivers per publish). Round U2 then
asked what paces the loop below the event rate, and the same truss
answered: the loop is work-paced, not wakeup-stalled. Per
composite it performs a 252 KB mmap plus several munmaps (500 mmap,
1477 munmap in 5 s) around a handful of synchronous /dev/draw
write/poll/read round-trips (all replies prompt, zero 5000 ms
hangs) and a blit ioctl.

The mmap/munmap churn is traced to the daemon's allocator:
semadrawd backs all allocation through
GeneralPurposeAllocator(.{}) (semadrawd.zig main). Zig's GPA
returns pages to the OS on free, so the per-frame transient
allocations in the synchronous render path (the makeFrame buffer
per /dev/draw op, and other per-pass scratch) cause the OS to
re-map and unmap pages every frame: roughly 100 mmap and 300
munmap syscalls per second of motion plus the attendant page-table
and TLB cost. This churn is the dominant remaining per-pass cost
now that wakeups and reply latency are accounted for.

Two things are explicitly out of scope here. The motion-dependent
~100 ms stall seen in the ADR 0009 capture (roughly 7/s) did not
reproduce in the U2 truss (6 timeouts in 5 s under steadier
motion); it is a separate, smaller question awaiting a timestamped
capture. And the serial /dev/draw round-trips per frame are a real
second pacer whose batching is deferred to a follow-up ADR, so this
one stays focused on the allocator win.

## Decision

Introduce a per-frame arena for the render hot path:

  1. The main loop owns an arena (std.heap.ArenaAllocator wrapping
     the daemon GPA).
  2. At the top of each loop pass, reset it with
     retain_capacity, which keeps the arena's pages mapped and
     resets the bump pointer; nothing is returned to the OS.
  3. Route the per-frame transient allocations through the arena's
     allocator: the /dev/draw op framing (makeFrame and its
     callers in the drawfs backend) and any per-pass scratch the
     composite path takes. The GPA remains the allocator for
     startup and long-lived state.
  4. After the first few frames the arena's capacity reaches the
     steady-state working set and reset-retain stops triggering
     any growth, so steady-state compositing performs zero
     mmap/munmap.

The plumbing follows the existing allocator-passing seam: the
backend's send path already takes self.allocator; it gains a
per-call frame allocator parameter (the arena), leaving its
long-lived allocations on the GPA.

## Implementation note (2026-06-07): the escape audit refined the fix

The audit the risk section mandated was run before any code and
narrowed the design. Result: the render hot path has exactly ONE
per-frame heap consumer, makeFrame in the drawfs backend's
sendAndRecv (one small framing buffer per /dev/draw op). Events
emit into stack buffers (bufPrint, no heap); the composite body
and the loop body allocate nothing per pass. The measured
mmap/munmap churn was GPA cycling its page-run for that one
size class as the per-op buffers were allocated and freed each
frame. makeFrame's lifetime is strictly frame-local (the buffer
is freed within sendAndRecv; the reply it returns is a slice
into the persistent read_buf, not an allocation), so nothing
escapes.

Given a single frame-local consumer bounded by the same
4096-byte protocol limit as read_buf, a per-backend PERSISTENT
inline frame buffer (frame_buf: [4096]u8, mirroring read_buf)
is simpler and safer than the loop-owned arena this ADR first
proposed: no per-pass reset wiring, no arena lifetime surface,
zero heap in the hot path, same zero-churn result. fillFrame
writes into the caller's buffer and errors rather than overrun.
The loop-arena remains the correct shape should future work
introduce additional per-frame consumers with frame-local
lifetime; until then the persistent buffer is the minimal
change. This note supersedes the arena in the Decision above
for the present implementation.

## Alternatives considered

  - Swap the daemon allocator wholesale (c_allocator, smp_allocator,
    or a non-returning configuration of GPA). Lower-effort but
    blunt: it changes allocation behaviour for all of startup and
    long-lived state, loses GPA's leak and double-free checking in
    ReleaseSafe everywhere, and does not express the per-frame
    lifetime that the arena makes explicit. Rejected.
  - A persistent FixedBufferAllocator slab sized to the worst-case
    frame. Zero churn like the arena, but must be sized for the
    worst case and hard-fails (or must fall back) when a frame
    exceeds it; the arena grows gracefully and falls back to the
    GPA for overflow. Rejected in favour of the arena.
  - Leave GPA and accept the churn. Rejected: it is the measured
    pacer.

## Consequences

  - Steady-state motion drops from roughly 100 mmap and 300 munmap
    per second to approximately zero; the loop rate rises toward
    the event rate until the serial /dev/draw round-trips become
    the next pacer (the deferred batching ADR).
  - Risk: a per-frame allocation whose result must outlive the
    frame would be use-after-reset. Mitigation: the implementation
    audits every consumer of the frame allocator to confirm
    nothing escapes the pass; anything long-lived stays on the
    GPA. This audit is the implementation's first step.
  - GPA's safety checking is retained for all non-hot-path
    allocation.

## Bench criteria

  - A motion truss shows steady-state mmap/munmap near zero (the
    first few frames may still grow the arena).
  - scripts/ad38-pump-capture.sh motion phase: emission and
    pos_changed rates rise from the ADR 0009 baseline (45.7/s loop,
    38/s pos_changed) toward the event rate; the ps_x step
    distribution shrinks further from its 16 px median.
  - The AD-43-era census remains the regression guard: idle
    composites at the SM-4 floor, no spin, no leak (GPA deinit
    clean at shutdown).
