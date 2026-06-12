# 0015 F.3.b: user-controlled playback

## Status

Accepted, 2026-05-30 (ratified same day as proposed; design
choices reviewed and confirmed by the bench operator before
implementation began). Per ADR 0011, F.3.b is the second
F.3 sub-milestone, depending on F.3.a (bench-verified `[x]`
2026-05-29). The scope statement from ADR 0011: "ioctl or
/dev node or other application-facing surface (the choice is
F.3.b's own ADR work)."

This ADR records the design decision for that surface.
Implementation follows in a separate commit after
ratification, in the same shape as F.3.a (kernel + Zig +
bench), with the explicit addition this time of a
**bench-safety review step** before any new behavior reaches
the iMac (per the discipline lesson recorded in ADR 0014's
post-bench amendment).

This ADR does not reverse, reopen, or amend ADRs
0006/0007/0008/0010/0011/0012/0013/0014. It scopes one
sub-stage (F.3.b) within the F-stage map.

## Context

ADR 0011 sequenced F.3.b after F.3.a so that user control
has a continuous stream to control. F.3.a (ADR 0014) landed
`audiofs_stream_begin` / `audiofs_stream_end` as in-kernel
callable lifecycle entry points and an internal sine wave
source driving a kthread refill loop. The attach-time
behavior is opt-in via `hw.audiofs.test_tone`.

F.3.b's job is to expose a userland-facing surface that
replaces the internal sine source with **real audio data
from userland**. After F.3.b lands, the audio audiofs plays
is whatever a userland process writes to it.

The userland consumer of audiofs is semasound (per ADR 0005)
and any tooling that bypasses semasound for diagnostic
purposes. Applications do not talk to audiofs directly;
they talk to semasound, which uses audiofs as its kernel
output sink. This layering matters for F.3.b's scoping:
audiofs's surface needs to be *whatever makes semasound's
job simple and robust*, not a general-purpose audio API
optimised for application latency. Latency optimisation is
semasound's job; audiofs's job is to give semasound a
reliable way to push samples to hardware.

ADR 0011 also sequences the rest of F.3 around F.3.b:

  - F.3.c (interrupts) replaces F.3.a's polling kthread
    with the real HDA interrupt path; F.3.b's user-ring
    drain logic must be compatible with that swap.
  - F.3.d (xrun detection) reports underruns through the
    F.2 events ring; F.3.b's user-ring-empty case is the
    underrun source.
  - F.3.e (format negotiation) negotiates format through
    the user surface F.3.b lands; F.3.b must reserve a
    surface where F.3.e can plug in.

## What audiofs needs to add at F.3.b

By the F.3.b scope from ADR 0011 plus the layering
constraint:

  - **A userland-facing device surface** that lets a single
    consumer push samples to a running output stream.
  - **A kernel-side intermediate ring** between the userland
    consumer and the hardware BDL, because the kthread
    cannot safely copy from userland memory in arbitrary
    contexts and the BDL requires DMA-coherent memory.
  - **A source-selection model** so the kthread refill loop
    can draw from either the internal sine (F.3.a's opt-in
    test source) or the user ring (F.3.b's real source),
    with clean transitions between them.
  - **Back-pressure**: when the user ring is full, the
    writer blocks until the kthread drains a fragment.
  - **Underflow handling**: when the user ring is empty
    and the kthread needs to refill the BDL, the kthread
    fills with silence (zero) and accumulates an internal
    underflow count. F.3.d will report these as xrun events;
    F.3.b just makes the count exist.

What F.3.b does NOT add:

  - **Format negotiation.** F.3.e. v1 is hardcoded 48 kHz
    / 16-bit / stereo (matching F.3.a and what commit 6
    bound electrically); other formats are rejected.
  - **Multi-stream / mixing.** Single-consumer per
    controller, exclusive open. Mixing is semasound's job.
  - **Capture.** F.3.b is output-only. `read(2)` returns
    ENXIO.
  - **Interrupts.** F.3.c. The kthread refill loop from
    F.3.a still drives drain; the user-ring drain happens
    in the same iteration as the BDL refill.
  - **xrun event emission.** F.3.d. Underflows accumulate
    a counter but emit no F.2 event yet.

## Decision

### 1. Surface: `/dev/audiofs<N>` cdev with `write(2)`

Each attached audiofs controller exposes a cdev named
`audiofs<N>` (e.g. `/dev/audiofs0` for the iMac internal
HDA controller, `/dev/audiofs1` for the discrete GPU HDMI
controller). The numbering matches the device-instance unit
number that `audiofs_attach` already uses.

The cdev supports:

  - `open(2)`: exclusive open. If already opened, returns
    `EBUSY`. Opens the stream if not already running (via
    `audiofs_stream_begin` with a new source-mode parameter
    set to "user ring"); if the stream is already running
    with the internal-sine source (test tone), swaps the
    source atomically to "user ring".
  - `close(2)`: ends the user-ring source. If the test-tone
    tunable is set at close time, swaps the source back to
    "internal sine"; otherwise calls `audiofs_stream_end`.
  - `write(2)`: copies samples from userland into the
    kernel-side user ring. Blocks when the ring is full
    (unless `O_NONBLOCK`, in which case returns `EAGAIN`).
    The byte count returned is what was successfully
    enqueued; partial writes are permitted but in practice
    the implementation completes the requested length unless
    interrupted.
  - `read(2)`: returns `ENXIO`. F.3.b is output-only.
  - `ioctl(2)`: returns `ENOTTY` in v1. F.3.e will add
    format-query / format-set ioctls.

The cdev does NOT support `mmap(2)` in v1. The mmap-ring
model exists in other systems (ALSA `mmap` mode) to reduce
copy overhead and latency for application-facing audio
APIs. audiofs is semasound's output sink, not an
application API; semasound does its own ring management
and pushes via `write(2)`. The copy cost is real but
trivial relative to semasound's own mixing work, and the
implementation simplicity of `write(2)` outweighs the
optimisation. F.3 future work or a successor sub-stage can
add mmap support if profiling shows it matters.

### 2. The user ring (kernel-side)

A fixed-size 32 KB ring per controller, allocated with the
controller's other DMA structures at stream open and freed
at close. Size rationale: 32 KB at 48 kHz / 16 / stereo is
~170 ms of audio, which is:

  - Big enough that semasound's typical write granularity
    (a few ms to ~20 ms) does not trigger back-pressure
    blocks in steady state.
  - Small enough that a write that fills the ring is
    observable to semasound as a back-pressure signal
    rather than a stall.
  - 4× the BDL buffer (~42 ms), so there is always at
    least 3 fragments of headroom for the kthread to drain
    into even at unfavourable timing.

The ring is a plain byte buffer with head and tail indices
(both `size_t`, advancing forever modulo the ring length
by `&` mask). Single producer (`write(2)`-side) and single
consumer (kthread-refill-side); a single `MTX_DEF` mutex
(`user_ring_mtx`) covers head, tail, and the condition
variable for back-pressure.

The ring is fragmented at write time only by the userland
caller's write boundary; the kthread reads in BDL-fragment-
sized chunks (4 KB), filling the next BDL fragment in one
read. If the ring has less than a full BDL fragment when
the kthread needs to refill, the kthread reads what is
available and zero-fills the remainder of the fragment.

### 3. Source selection model: a 3-state machine

The output stream descriptor exists in one of three states:

  - **Stopped** (no RUN, no kthread).
  - **Running with internal-sine source** (the F.3.a-
    amended test-tone mode; tunable controls it).
  - **Running with user-ring source** (the F.3.b mode;
    cdev open/close controls it).

Transitions (six, all documented):

  - tunable 0->1, cdev closed: stopped -> running-sine.
  - tunable 1->0, cdev closed: running-sine -> stopped.
  - cdev open() while stopped: stopped -> running-user.
  - cdev open() while running-sine: running-sine ->
    running-user (source-swap; stream stays alive).
  - cdev close() while running-user, tunable == 0:
    running-user -> stopped.
  - cdev close() while running-user, tunable != 0:
    running-user -> running-sine.

In all "running" states, the same kthread is alive (one per
stream descriptor); only the source it reads from changes.
This keeps the kthread lifecycle simple: it is started by
the first transition into a running state and stopped only
by a transition out.

The source selector is a single softc field
(`output_stream_source`) holding an enum value
(`AUDIOFS_SRC_SINE`, `AUDIOFS_SRC_USER`). Read by the
kthread on each iteration under `user_ring_mtx` (cheap;
already taken to consult the ring). Written by the
transition paths under `user_ring_mtx`.

### 4. Back-pressure model

When `write(2)` finds the ring full (free space less than
requested), it `msleep`s on `user_ring_mtx` waiting for the
kthread to wake it. The kthread, after draining a fragment
from the ring (which frees `AUDIOFS_BUF_FRAG_BYTES` of
space), calls `wakeup(&sc->user_ring_mtx)` to wake any
blocked writer.

On `O_NONBLOCK`, `write(2)` returns `EAGAIN` without
blocking when the ring would block.

A blocked writer is interruptible. If the process receives a
signal, `msleep` returns `ERESTART` / `EINTR`; `write(2)`
returns whatever bytes were successfully queued so far, or
`EINTR` if zero.

### 5. Underflow model

When the kthread needs to refill a BDL fragment and the
user ring has less than `AUDIOFS_BUF_FRAG_BYTES` of data,
the kthread reads what is available, zero-fills the rest,
and increments `output_stream_underflow_count` (a softc
counter). The counter is read by F.3.d when it wires xrun
events; for F.3.b it is informational only.

The audible result of underflow is a brief silence (the
zero-filled tail of the BDL fragment); the stream does not
stall, the kthread does not exit, and the next refill
catches the user back up if data arrives.

This is the physics-only honest behaviour per ADR 0007:
"the user data ran out" is reported by accumulating the
underflow event; semasound (or F.3.d when it lands) decides
the policy response.

### 6. Exclusive open

Only one process at a time may hold the cdev open. A second
`open()` while the cdev is open returns `EBUSY`. The
"is_open" state is a softc flag (`output_stream_cdev_open`,
boolean) protected by `user_ring_mtx`.

`D_TRACKCLOSE` ensures `close()` fires on file-descriptor
teardown for any reason (normal close, process exit,
SIGKILL); no zombie open state is possible.

### 7. Lock additions and ordering

New per-softc lock: `user_ring_mtx` (MTX_DEF). Protects:
ring head, ring tail, `output_stream_cdev_open`,
`output_stream_source`, the back-pressure condition variable.

Lock ordering (with F.3.a's locks):

  - `audiofs_state_sx` (sleepable) - outermost.
  - `user_ring_mtx` (MTX_DEF) - middle; can sleep via
    msleep on its own address for back-pressure.
  - `hw_lock` (MTX_DEF) - innermost; brief, no sleep.

Code that needs all three (rare; the source-swap path during
cdev open with stream already running) takes them in this
order. The kthread refill loop takes only `user_ring_mtx`
(brief, for the source check + ring drain) and `hw_lock`
(brief, for the LPIB read), in that order, both briefly.

### 8. Format hardcoded; ioctl reserved

`open(2)` does not negotiate format. The stream comes up at
48 kHz / 16-bit / stereo (the F.3.a hardcoded format), and
`write(2)` accepts only that wire format: 4 bytes per
stereo frame, byte order little-endian, samples interleaved
L/R.

If the user writes a partial frame (byte count not a
multiple of 4), the implementation enqueues complete frames
only and reports the byte count enqueued. F.3.e will add
format negotiation when it lands; the wire format for v1
is documented here so F.3.e's negotiation is opt-in rather
than retrofitted.

`ioctl(2)` returns `ENOTTY` in v1; F.3.e adds:
  - `AUDIOFS_IOC_GET_FORMAT`: query current format.
  - `AUDIOFS_IOC_SET_FORMAT`: request a new format
    (subject to DAC support).

ioctl numbers are not allocated yet; F.3.e's ADR will pick
them.

### 9. F.2 event emission

F.3.b adds no new F.2 event types. The existing
`stream_begin` / `stream_end` events that F.3.a populates
continue to fire on the same transitions; the source mode
(sine vs user-ring) is an internal detail that does not
affect the event payload.

A future enhancement could add a `stream_source_change`
event type, but F.3.b does not need it: semasound, the
intended consumer, knows it opened the cdev and therefore
that the source is "user-ring"; it does not need a
notification.

## What this commits

Closure criteria for F.3.b:

  1. `/dev/audiofs<N>` cdev exists for each attached
     audiofs controller. `ls -l /dev/audiofs0` shows
     root:wheel 0666 character device.
  2. A small userland test program can `open` the cdev,
     `write` ~5 seconds of pre-generated sine samples at
     48k/16/stereo, and `close`. The iMac internal speaker
     plays the written sine wave (audibly, at the F.3.a-
     amended quiet amplitude or whatever the test data
     specifies).
  3. The F.2 events ring shows a `stream_begin` event at
     `open()` and a `stream_end` event at `close()`.
     `frames_total` in `stream_end` matches the byte count
     written divided by 4.
  4. With the test tone tunable set to 1 *before* the cdev
     is opened, the source swap works: sine plays
     immediately, then swaps to user data on open without
     a stream restart (single stream_begin in the events
     ring, the one at tunable transition).
  5. `write(2)` blocks when the ring is full, drains, and
     resumes; a slow writer does NOT cause the kthread to
     exit. (Tested by writing in chunks slower than the
     drain rate; underflow_count rises but the stream
     continues.)
  6. Double-open returns EBUSY. SIGKILL on the writer
     process cleans up the cdev state (next open succeeds).
  7. No deadlock, no lock-order panic, no kthread leak, no
     DMA leak on any combination of load / open / write /
     close / unload, including operator interruption with
     SIGKILL mid-write.

### What F.3.b implementation lands

  - Modifications to `audiofs/sys/dev/audiofs/audiofs.c`:
    new cdevsw, open/close/write/read/poll/ioctl handlers,
    user_ring allocation + free, source selector
    field, refill loop updated to choose source.
  - Updates to BACKLOG AD-3 status and the F.3 sub-
    milestone tracking.
  - No changes to `shared/AUDIO_STATE.md` or
    `shared/AUDIO_EVENTS.md` (schema unchanged).
  - No changes strictly required to `shared/src/audio.zig`;
    a small userland test program may be added later but
    is not a closure-criterion artifact.

### What F.3.b implementation does NOT do

  - Does not add interrupts (F.3.c).
  - Does not emit xrun events (F.3.d).
  - Does not negotiate format (F.3.e).
  - Does not bring up HDMI (F.3.f).
  - Does not write the clock region (F.4).
  - Does not change F.1 / F.2 wire formats.
  - Does not add mmap.

## Why this design

**Why `write(2)` cdev, not mmap or ioctl-ring.** semasound,
the intended consumer, will do its own mixing and ring
management in userland; audiofs's surface needs to be
simple, robust, and testable, not low-latency. `write(2)`
is the simplest POSIX shape, exercises easily from a shell
or one-page C program, and matches the data-flow pattern
of "userland pushes samples; kernel hands them to the
DMA engine". mmap optimisation can come later if profiling
demands it; over-engineering it now would cost design
complexity without buying anything semasound actually
needs.

**Why open/close drives the stream lifecycle.** semasound
opens the device once at startup and holds it. Frequent
open/close is not a real use case. Tying the F.3.a
`stream_begin` / `stream_end` calls to `open` / `close`
keeps the model clean: the stream descriptor is configured
only when there is a consumer, hardware is quiet otherwise.
The test-tone tunable continues to drive a sine source
independently when no cdev consumer is present; this lets
bench operators verify electrical health without needing
the cdev.

**Why a kernel intermediate ring, not direct userland-memory
DMA.** Two reasons. First, the BDL requires DMA-coherent
memory the kernel allocated; userland pages cannot be
handed directly to the HDA controller without
sophisticated pinning + IOMMU mapping that audiofs has no
infrastructure for. Second, the kthread (and F.3.c's
future interrupt handler) needs to read from "the source"
in contexts where `copyin` is unsafe or expensive. A
kernel-side ring filled by `write(2)` is the lowest-
complexity decoupling layer.

**Why 32 KB ring, not bigger or smaller.** 32 KB at
48k/16/stereo = ~170 ms. Bigger increases tail-latency for
real-time changes (paused audio takes longer to stop
playing); smaller makes back-pressure visible at typical
semasound write granularities. 32 KB is large relative to
typical write chunks (a few ms) and small relative to
audio latency tolerances (~100 ms is the threshold of
noticeable lag for interactive audio).

**Why exclusive open.** Mixing is semasound's job. Allowing
two concurrent writers would require audiofs to define
mixing semantics (linear sum? saturating sum? per-source
volume?), which is policy and belongs in semasound per
ADR 0007. EBUSY is honest: "only one consumer at a time;
go through semasound if you need mixing."

**Why silence on underflow.** The audible truth. Repeating
the last fragment hides the underflow at the cost of
audible artefacts; stalling RUN risks HDA state-machine
issues. Silence is the cleanest, most diagnosable failure
mode, and F.3.d will surface the underflow count as
xrun events so semasound can respond.

**Why a 3-state source machine rather than separate
stream/source flags.** A small state machine with explicit
documented transitions is easier to verify than two
independent booleans that may go out of sync. Six
transitions, all named.

## Bench-safety review

Per the discipline lesson recorded in ADR 0014's post-bench
amendment, F.3.b's implementation must pass a bench-safety
review *before* the first bench load on pgsd-bare-metal:

  - The cdev is created with mode 0666 (any user can write).
    Is this a hostile surface? **Mitigation**: writing to
    the cdev produces audio at whatever amplitude userland
    sends. Userland can write loud audio. This is no
    different from any other audio API and is the expected
    behaviour. semasound will be the typical consumer and
    will apply its own volume policy.
  - Default behaviour at first kldload after F.3.b lands:
    no cdev consumer, tunable still 0, so stream is
    stopped, no audio. Same as F.3.a-amended default.
    **Safe.**
  - Bench test workflow: write a short (say 1-second) sine
    fragment from a userland test program, hear it, exit.
    No "iMac sings indefinitely" risk because `close()`
    ends the stream cleanly. **Safe.**
  - The 32 KB user ring + 8 KB BDL means up to ~210 ms of
    audio can be queued. If the test program writes a
    huge buffer and exits before close, the queued audio
    plays out (200 ms) then silence. **Safe.** The
    `close()` handler in v1 cleans up the cdev and ends
    the stream immediately rather than draining; queued
    audio is lost on close. That is the kinder behaviour
    for "operator wants to stop now".

The bench-safety gate for F.3.b: a 1-second sine test
program lands together with the kernel implementation, and
the first bench load uses that program (which exits
immediately after writing). The "iMac plays until I say
stop" scenario is foreclosed by program lifetime.

## Relationship to ADR 0007

The cdev surface is still physics-only in spirit: audiofs
plays what userland tells it to play. Policy (volume,
mixing, source-routing, app-priority) lives in semasound,
which is the consumer of this cdev. audiofs makes no
policy decisions about content; it presents the wire.

## Relationship to ADR 0011

F.3.b follows F.3.a per the dependency map. F.3.c, F.3.d,
F.3.e all build on the surface F.3.b lands here:
  - F.3.c swaps the kthread for the interrupt path; the
    drain-source-on-fragment logic stays in the new handler.
  - F.3.d wires the underflow counter to F.2 xrun events.
  - F.3.e adds format ioctls to this cdev.

## Relationship to ADR 0014

F.3.a's `audiofs_stream_begin` and `audiofs_stream_end`
signatures are preserved. F.3.b adds a source-mode
parameter to `stream_begin` (or a separate "source-switch"
helper; implementation detail), but the signature change is
within audiofs and does not affect the F.2 event payloads
or wire formats.

The `hw.audiofs.test_tone` tunable continues to work as
before, with the new transition rules documented in
Decision 3.

## Consequences

### What this enables

  - **semasound (F.5)** has a kernel sink to send mixed
    audio to.
  - **F.3.c** has a real consumer to demonstrate interrupt-
    driven drain against.
  - **F.3.d** has an underflow event source to wire xrun
    events from.
  - **F.3.e** has a user-facing surface to negotiate format
    through.
  - **Diagnostic tooling**: a one-page C program can
    produce arbitrary audio test signals from userland,
    independent of semasound.

### What this commits

  - `/dev/audiofs<N>` is a public surface. Adding fields
    to its behaviour (new ioctls, new poll() behaviour)
    is forward-compatible; removing or changing existing
    behaviour is a break.
  - Single-writer, exclusive-open semantics are the v1
    contract.
  - 48 kHz / 16-bit / stereo is the v1 wire format. F.3.e
    is what makes it negotiable.
  - The 3-state source machine is the v1 lifecycle model.

### What this does not address

  - Capture (input). Out of F.3.b scope.
  - HDMI streams (F.3.f).
  - Concurrent multi-stream playback (semasound's job).
  - Format negotiation (F.3.e).
  - The interrupt path (F.3.c).

## What this document is not

  - Not the implementation. The audiofs.c cdev wiring, the
    user-ring allocator, the back-pressure msleep loop,
    and the source-selector refactor are separate commits.
  - Not a softening of ADR 0007. The cdev is physics-only
    by design; policy goes through semasound.
  - Not the F.3.c interrupt path. The kthread continues
    to drive drain in F.3.b; F.3.c swaps it later.
  - Not a general-purpose application audio API. It is
    semasound's kernel output sink, scoped narrowly to
    what semasound needs.
