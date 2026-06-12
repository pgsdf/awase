# 0021 F.5.a: semasound mixer core and audiofs output

## Status

Accepted, 2026-06-01 (ratified same day as proposed; design
choices reviewed and confirmed by the operator before
implementation began). BENCH-VERIFIED and CLOSED 2026-06-02:
all eleven closure criteria passed on pgsd-bare-metal. See the
revision history for the bench record.

First sub-milestone of F.5 (semasound), scoped under ADR
0020. Inherits the six binding constraints listed there
(single-writer broker, all-semantics-in-userland, format
election through the one fenced control path, rate-correction
not position-correction, clock independence, sndio
reference) and does not re-argue them. Depends on F.3.b-e
and F.4, all bench-verified.

## Context

semasound is the userland broker: the sole writer to
`/dev/audiofs0`, with client applications connecting over a
Unix socket and their audio mixed in userland (ADR 0004,
Option A). F.5.a builds the spine of that broker: accept
multiple clients, mix their PCM, and write one mixed stream
to audiofs, with the mixer present from the first
sub-milestone (ADR 0020 operator decision).

The audiofs surface this consumes already exists and is
verified: `/dev/audiofs0` is single-open and accepts a PCM
byte stream whose `write(2)` blocks on a full ring and wakes
as the hardware drains (F.3.b); the stream comes up at the
canonical format 48 kHz / 16-bit / stereo by default
(F.3.b, F.3.e); `/dev/audiofs_notify` is a pollable cdev
that wakes on event publication, backed by the F.2 events
ring (xrun among them, F.3.d); and `/var/run/sema/clock`
carries the hardware-derived clock (F.4).

The pacing model falls out of single-writer plus
blocking-write. Because semasound is the only writer and the
hardware ring drains at the DAC's true consumption rate, a
blocking `write(2)` to audiofs is paced by the hardware
itself: when the ring is full, semasound blocks until the
DAC has consumed a fragment. The hardware ring is therefore
the rate authority, and semasound never samples the clock to
schedule output. This is the rate-correction-not-position-
correction posture ADR 0007 mandates, satisfied structurally
rather than by a correction loop: there is no per-observation
position snap because there is no clock observation in the
output path at all. The F.4 clock is consumed read-only for
cross-subsystem alignment and observability, not for pacing.

## Decision

### 1. Client IPC: Unix stream socket, header then PCM

semasound listens on a Unix `SOCK_STREAM` socket at
`/var/run/sema/audio.sock` (the `sema` namespace, mirroring
how semaaud bound a control socket and how inputfs publishes
under `/var/run/sema/`). On accept, the client sends a fixed
connect header, then streams raw interleaved PCM until it
closes.

```
struct semasound_hello {
    uint32_t magic;       /* 'SMA1' */
    uint16_t version;     /* 1 */
    uint16_t format;      /* canonical: 16-bit LE PCM = 1 */
    uint32_t rate_hz;     /* 48000 in F.5.a */
    uint16_t channels;    /* 2 in F.5.a */
    uint16_t _pad;
};
```

semasound replies with a one-byte status (0 = accepted,
non-zero = rejected with a following text reason, then
close). In F.5.a the header must declare the canonical
format exactly; any other rate/format/channel count is
rejected (resampling and arbitrary-rate clients are F.5.b).
After acceptance the client writes PCM frames (4 bytes each,
16-bit LE stereo); semasound reads them into that client's
input ring. Client disconnect is a socket EOF/close. If
semasound exits, clients see `ECONNRESET` (ADR 0004 failure
mode).

The wire protocol is deliberately minimal and is the
artifact F.5.a establishes for later sub-milestones to
extend (F.5.b adds format fields already present in the
header; F.5.c adds a target field; F.5.d adds policy hints).
Extension is by header version bump, not by reshaping F.5.a's
layout.

### 2. Per-client input rings, mixer-driven output

Each accepted connection gets a reader thread that fills a
per-client input ring (a small multiple of the audiofs
fragment size) from the socket, plus a single mixer/output
thread that is the only writer to audiofs. This mirrors
semaaud's per-connection worker model while separating
socket I/O (which may block on a slow client) from the
timing-critical output path (which must not). Per-client
rings are mutex-protected; the mixer reads under the lock,
copies out, releases.

The single-threaded `poll(2)` loop alternative (sndio's
shape) was considered and is viable; the threaded split is
chosen because the blocking-write output path and the
per-client socket reads have different blocking
characteristics that are simpler to reason about in separate
threads than interleaved in one event loop. This is a
structural choice, not a semantic one, and stays within the
sndio reference's spirit (small, explicit). If it proves
heavier than warranted, a later sub-milestone may collapse
it; F.5.a does not depend on the choice being permanent.

### 3. Mixer: sum, clip, zero-fill

Each output tick the mixer pulls one audiofs-fragment's worth
of frames from every active client ring and sums them
per-sample into a 32-bit accumulator, then clips to the
int16 range and packs the canonical output buffer. A client
with insufficient data this tick contributes silence for the
shortfall (its frames are zero-filled); a slow or stalled
client thus mixes as silence without stalling the mix or the
other clients. Clipping is semantic and is owned here (ADR
0007); the choice in F.5.a is hard clipping (saturate), the
simplest defensible policy, with soft-limiting left to a
later sub-milestone if wanted.

### 4. Output path and pacing

The mixer/output thread opens `/dev/audiofs0` once at
startup (semasound is the sole writer; a second opener would
get `EBUSY`, which is the intended exclusivity). It leaves
the stream at the 48 kHz canonical default (no `SET_FORMAT`
in F.5.a; election is F.5.b). It writes each mixed buffer
with a blocking `write(2)`; the full-ring block is the
pacing mechanism. Local frame accounting (frames written) is
maintained for observability and for later drift measurement,
but is not used to schedule writes.

### 5. xrun handling

A small event consumer polls `/dev/audiofs_notify` and reads
the F.2 events ring. On an xrun event, F.5.a's recovery
policy is minimal and explicit: the gap has already occurred
in hardware (ADR 0007 stress case 1, audiofs does not smooth
it); semasound records the xrun (count and last position) for
observability and continues writing. It does not attempt
retroactive fill or rate change in F.5.a. Richer recovery
(e.g. transient buffer growth) is deferred; the minimal
policy is the honest default under the boundary.

### 6. Clock consumption

semasound maps `/var/run/sema/clock` read-only and may
surface the hardware playback position for observability and
for the cross-subsystem timeline, but F.5.a does not feed it
into the output pacing loop (see Context). This keeps the
clock-independence invariant intact: if semasound stalls or
dies, audiofs keeps advancing the clock from hardware
progression regardless.

### 7. Scope fences (deferred to later sub-milestones)

  - No resampling or format election (F.5.b): canonical
    format only; non-canonical clients rejected.
  - No named targets or routing (F.5.c): all clients mix to
    the single output.
  - No policy, preemption, fallback, or ducking (F.5.d).
  - No durable state publication beyond what a test client
    needs to observe; full per-stream/target publication is
    F.5.e.
  - No s6 supervision or fresh-install enablement (F.5.f):
    F.5.a runs from the shell for bench verification.

## Rejected alternatives

**Single-threaded poll loop for everything.** sndio's shape;
one thread polling all client fds plus audiofs writability.
Viable and arguably more sndio-faithful, but interleaving
the blocking-write output path with per-client socket reads
in one loop complicates the timing path. Chosen against for
F.5.a (see Decision 2); revisitable later.

**Clock-driven pacing.** Sample `/var/run/sema/clock` and
schedule writes to track it. Rejected: it reintroduces the
scheduling-jitter coupling ADR 0007 forbids, and it is
unnecessary because blocking-write backpressure already
paces output to the true hardware rate. The clock is for
alignment, not scheduling.

**Resampling in F.5.a.** Accept arbitrary client rates and
convert. Rejected: deferred to F.5.b by ADR 0020 so the
spine lands without the resampler's complexity; canonical-
only clients are enough to prove the mixer and output path.

**Mix in the kernel.** Out of bounds by ADR 0004/0007;
recorded only to mark it closed.

## Consequences

  - After F.5.a, multiple canonical-format clients play
    simultaneously through one mixed audiofs stream: the
    broker spine is real and load-bearing.
  - Pacing is correct by construction (hardware ring
    backpressure), with no clock loop to tune, honoring ADR
    0007 structurally.
  - F.5.a is the largest single semasound sub-milestone
    because the mixer, the IPC protocol, the output path, and
    xrun consumption land together; this is the accepted cost
    of mixer-in-the-spine (ADR 0020).
  - The IPC header is versioned so F.5.b-d extend it without
    breaking F.5.a clients.
  - Failure mode is the ADR 0004 one: semasound death stops
    audio and resets client sockets; the clock keeps
    advancing in the kernel.

## Closure criteria

F.5.a closes when, on `pgsd-bare-metal` (analog path):

  1. semasound starts, binds `/var/run/sema/audio.sock`,
     opens `/dev/audiofs0`, and idles without writing garbage
     (silence or no-write when no clients).
  2. One canonical-format client streaming a tone plays
     audibly and cleanly through audiofs.
  3. Two clients streaming simultaneously mix audibly (two
     tones heard together), with summed amplitude clipped,
     not wrapped.
  4. A client declaring a non-canonical format is rejected
     with a status byte and reason, semasound and other
     clients unaffected.
  5. A client disconnecting mid-stream is mixed as silence
     thereafter and does not disrupt the remaining clients.
  6. A deliberately stalled client (stops writing) mixes as
     silence without stalling the output or other clients.
  7. An induced xrun (e.g. a client gap large enough to empty
     the audiofs ring) is recorded by semasound and playback
     continues; no crash.
  8. `clock_dump` shows the clock advancing while semasound
     plays; killing semasound stops audio but the clock keeps
     advancing (clock independence).
  9. Killing semasound gives connected clients `ECONNRESET`;
     restarting semasound accepts new clients cleanly.
 10. No leaks or crashes across repeated client connect/
     disconnect and semasound start/stop cycles; clean
     shutdown releases the socket and the audiofs handle.
 11. Operator marks F.5.a `[x]`.

## Bench test plan

Build semasound and a test client (`semasound-tone`, an
analogue of `playtone` that writes the hello header then a
generated tone to the socket instead of opening the device).

  1. Start semasound from the shell; confirm the socket and
     the audiofs open, no audio.
  2. One `semasound-tone` client: hear a clean tone;
     `clock_dump` advancing.
  3. Two clients at different frequencies: hear both mixed;
     confirm no wrap distortion at summed peaks.
  4. A client sending a wrong-rate header: rejected, others
     unaffected.
  5. Disconnect one of two clients mid-play: the other
     continues uninterrupted.
  6. Stall a client (pause writes): output continues as
     silence for it; resume and it rejoins.
  7. Force an xrun; confirm semasound logs it and continues,
     dmesg clean.
  8. Kill semasound mid-play: audio stops, clients get
     `ECONNRESET`, `clock_dump` still advancing; restart and
     reconnect.
  9. Repeated connect/disconnect and start/stop loops; check
     for fd/memory leaks and a clean final shutdown.

## References

  - ADR 0004 (mixer location): single-writer broker, sndio
    reference, the failure-mode argument.
  - ADR 0007 (physics/semantics boundary): clipping/xrun
    recovery as semasound's; rate-correction-not-position;
    clock independence.
  - ADR 0020 (F.5 decomposition): F.5.a's place, the
    binding constraints, the mixer-in-the-spine decision.
  - ADR 0018 (F.4): the clock semasound consumes read-only.
  - ADR 0015 (F.3.b): the `/dev/audiofs0` write path and its
    blocking-ring backpressure (the pacer).
  - ADR 0013/0017 (F.2 / F.3.d): the notify cdev and events
    ring semasound polls for xrun.
  - `semaaud/src/control_server.zig`, `stream_worker.zig`:
    the IPC and per-connection-worker reference (not
    inherited as code).

## Revision history

  - 2026-06-01: first draft. IPC header-then-PCM protocol on
    a `/var/run/sema/audio.sock` stream socket; reader-thread-
    per-client plus a single mixer/output thread; sum-clip-
    zerofill mixer; blocking-write pacing (hardware ring as
    rate authority, no clock scheduling loop); minimal xrun
    recording; canonical-format-only with later sub-milestone
    fences. Scoped under ADR 0020.
  - 2026-06-02: BENCH-VERIFIED, all eleven closure criteria
    passed on pgsd-bare-metal (Intel iMac, FreeBSD amd64,
    CS4206). 1 idle broker silent; 2 single canonical tone
    clean; 3 two-client 440+660 mix clean and audible; 4 a
    non-canonical (44.1k) client rejected with status byte,
    broker survived and continued accepting; 5 one client
    disconnecting mid-stream left the other uninterrupted; 6 a
    SIGSTOPped client mixed as silence while the other
    continued, then rejoined on SIGCONT; 7 an xrun induced by
    stalling the output thread (the only way semasound can
    starve audiofs, since a client stall is hidden by the
    mixer's zero-fill) was observed by the consumer, which
    counted all 62 published events in coalesced batches and
    continued; 8 the clock advanced during playback (+96256/2s
    at 48k), held monotonic when idle, and resumed monotonic
    across a broker restart (ADR 0018 stop-start monotonicity,
    not a free-running wall clock); 9 killing the broker gave
    a connected client ECONNRESET and a clean restart accepted
    new clients; 10 no fd leak across ten connect/disconnect
    cycles (12 -> 12).
    Two cross-cutting notes. The audiofs DMA-boundary fix
    (ADR 0023, BDL depth 4) was a prerequisite for criteria
    2/3: before it the 440/660 mix carried a fragment-rate
    hum; the mixer itself was always correct (proven
    byte-exact during the ADR 0022/0023 investigation). The
    xrun consumer (xrun.zig) had a bug found at the bench: it
    did an invalid read on the read-less notify cdev and only
    scanned the events ring on a caught poll edge, missing the
    edge-triggered burst; fixed to scan on every poll wake
    including timeouts, after which it reconciled exactly with
    the kernel underflow_count. Test affordances retained in
    committed source: semasound-tone --badrate and --gap. The
    output-thread test stall (TEST_STALL_MS) was removed after
    use. Criterion 11 (operator mark) completes closure.
