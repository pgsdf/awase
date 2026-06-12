# 0014 F.3.a: continuous streaming

## Status

Accepted, 2026-05-29. Decision-owner ratification. Per ADR 0011, F.3.a is the first F.3
sub-milestone: "Buffer refill loop; indefinite running;
stream lifecycle cleanly tied to explicit start/stop control.
No user-API yet." This ADR records the design decision for
that work. The byte-level event payloads it emits already
exist in `shared/AUDIO_EVENTS.md` (`stream_begin`,
`stream_end`); F.3.a is what populates them.

ADR-before-code discipline holds: this ADR plus the
implementation commits that follow are separate. ADR
ratification precedes any audiofs.c changes for F.3.a.

This ADR does not reverse, reopen, or amend ADRs
0006/0007/0008/0010/0011/0012/0013. It scopes one sub-stage
of AD-3 (F.3.a) within the F-stage map as reconciled by ADR
0011, building on F.1 (state region) and F.2 (events ring).

## Context

ADR 0011 reframed F.3.a's closure criteria:

  1. The stream descriptor configured at attach (the
     commit-6 work) is driven by a buffer refill loop that
     keeps the stream running indefinitely.
  2. Stream lifecycle is tied to explicit start/stop control
     entry points (in-kernel callable; the user-facing API
     is F.3.b).
  3. The F.2 events ring emits `stream_begin` on start and
     `stream_end` on stop, populating the schema reserved by
     ADR 0013.

F.1 (bench-verified [x] 2026-05-28) established the state
region. F.2 (bench-verified [x] 2026-05-28) established the
events ring with reserved stream-event slots that nothing yet
emits. F.3.a is what makes the stream events flow.

The current commit-6 code does a **one-shot** test signal at
attach: configure DMA, fill the stream buffer with one
period of a sine wave, kick RUN, sample LPIB at 10 ms
intervals for ~290 ms, stop. It proved the data path
electrically; it does not stream. F.3.a converts that
one-shot into indefinite streaming with start/stop control.

ADR 0011 sequences the rest of F.3 explicitly: F.3.b owns
user control; F.3.c owns interrupt-driven position tracking;
F.3.d owns xrun detection on the interrupt path; F.3.e owns
format negotiation through the user surface; F.3.f owns
HDMI bring-up. F.3.a deliberately does none of those. Its
job is the refill loop and the lifecycle, nothing more.

## What audiofs needs to add at F.3.a

By the F.3.a closure criteria and the ADR 0007 physics-only
constraint:

  - **A buffer refill mechanism.** Detect which BDL
    fragments the hardware has consumed and refill them
    before the play position reaches them. The refill cadence
    must be safe relative to the hardware's consumption rate.
  - **Start/stop entry points.** In-kernel functions
    `audiofs_stream_begin` and `audiofs_stream_end` that own
    the full lifecycle: DMA setup, initial fill, kthread
    creation, stream RUN; and the inverse on stop, with
    `frames_total` reported.
  - **F.2 event emission.** `stream_begin` at start (payload:
    stream_id, format, channels, rate_hz), `stream_end` at
    stop (payload: stream_id, frames_total). Per the schemas
    reserved in `shared/AUDIO_EVENTS.md`.
  - **Conversion of the attach-time test tone.** The
    one-shot tone is replaced by a `stream_begin` call so
    the attach behavior becomes "speaker plays sine
    continuously until unload" - the F.3.a closure proof.
  - **Removal of the one-shot helpers.** The
    `audiofs_run_output_stream` LPIB-sampling loop and the
    related one-shot infrastructure are superseded; they go.

What F.3.a does NOT add (per ADR 0011's sub-milestone
boundaries):

  - **Interrupts.** F.3.c owns the interrupt-driven position
    path. F.3.a's refill loop polls LPIB from a kthread.
  - **xrun detection.** F.3.d. The kthread refill model is
    designed so refills stay ahead of consumption under
    normal conditions; observed xruns are diagnostic only
    until F.3.d wires them into the events ring.
  - **User-facing API.** F.3.b. F.3.a's start/stop are
    in-kernel callable.
  - **Format negotiation.** F.3.e. F.3.a hardcodes 48 kHz /
    16-bit / stereo, matching what the existing test tone
    binds.
  - **Real audio data source.** F.3.b binds a real source.
    F.3.a's refill produces the sine wave indefinitely; same
    waveform F.1's bench heard, just looped instead of
    one-shot.
  - **Clock writing.** F.4. ts_sync in the stream events
    stays 0 until F.4 lands.

## Decision

### 1. Refill mechanism: per-stream kthread polling LPIB

A `kproc_create`'d per-stream kthread loops:

  1. `pause("audiorefill", N)` for a short interval (10 ms
     in v1; see below for the cadence rationale).
  2. Read SDnLPIB to learn the current play position in the
     stream buffer.
  3. Compute which BDL fragments the hardware has
     transitioned past since the last poll.
  4. For each consumed fragment, refill it with the next sine
     samples and `bus_dmamap_sync` the mapping.
  5. If a stop has been requested, exit the loop and clean
     up; otherwise repeat.

The kthread holds no spin locks across `pause`. It takes
`sc->hw_lock` only for the brief LPIB read and the DMA sync
calls, releasing between iterations. The kthread is the sole
writer to the stream buffer for an active stream; readers (if
any) treat the buffer as opaque.

### 2. Buffer layout

The v1 BDL has **two entries**, the existing layout.
4 KB per fragment, 8 KB total, plays at 48 kHz/16/stereo in
~42 ms total (~21 ms per fragment).

Safety margin against missed polls: the refill model fails
only if the kthread fails to refill a consumed fragment
before the hardware loops back to it. The hardware loops
back when it has played `buf_size - one_fragment` = ~21 ms
of audio after the fragment was consumed. With 10 ms
polling, a single missed `pause()` wakeup still leaves
roughly 10 ms of headroom before replay. That margin is
comfortable for normal scheduling jitter; it is not
generous against system-wide stalls (a sleep longer than
~21 ms produces an audible replay glitch). F.3.c
(interrupts) is where the latency tolerance is broadened.

This is the minimum viable BDL for a refill loop. F.3.c
may grow it (4-8 entries is conventional for interrupt-
driven streaming); F.3.a does not.

The buffer is treated circularly: BDL entry 0 points to bytes
0..4095, entry 1 points to bytes 4096..8191, and the hardware
wraps from entry 1 back to entry 0 automatically per HDA
spec. Fragment-consumed detection compares the previous LPIB
to the current LPIB:

  - If current LPIB < previous LPIB: the buffer wrapped;
    fragments from previous to end and from start to current
    are both consumed.
  - Otherwise: fragments fully covered by [previous, current]
    are consumed.

A fragment is "consumed and refillable" when the current
LPIB has moved past its end. The kthread refills exactly
those fragments and tracks the new "next-position" cursor.

### 3. Start/stop entry points

```c
int audiofs_stream_begin(struct audiofs_softc *sc,
    uint32_t endpoint_id, uint16_t format, uint8_t channels,
    uint32_t rate_hz, uint32_t *out_stream_id);

int audiofs_stream_end(struct audiofs_softc *sc,
    uint32_t stream_id);
```

`audiofs_stream_begin`:

  1. Validates the endpoint exists in the state inventory
     and is an output endpoint with the requested kind.
  2. Allocates the BDL DMA (8 KB) and stream-buffer DMA
     (8 KB) if not already allocated for this controller.
  3. Fills the buffer with the initial sine periods.
  4. Configures the stream descriptor (SDnCBL, SDnLVI,
     SDnFMT, BDPL/BDPU) per the existing commit-6 path.
  5. Binds the DAC's converter to the stream id via
     SET_CONV_STREAM_CHAN.
  6. Emits the F.2 `stream_begin` event (payload: assigned
     stream_id, format, channels, rate_hz).
  7. Creates the refill kthread.
  8. Sets RUN in SDnCTL.
  9. Returns the assigned stream_id via the out parameter.

`audiofs_stream_end`:

  1. Signals the kthread to exit; waits for it (briefly).
  2. Clears RUN in SDnCTL.
  3. Reads the final LPIB and computes `frames_total` (total
     frames played since `stream_begin`, tracking buffer
     wraps the kthread already counted).
  4. Unbinds the converter (SET_CONV_STREAM_CHAN payload 0).
  5. Emits the F.2 `stream_end` event (payload: stream_id,
     frames_total).
  6. Leaves the BDL/buffer DMA allocations live (next
     `stream_begin` reuses them); they are freed at detach.

Per-stream state lives on the softc (currently sized for one
stream per controller; F.3.c may extend this).

### 4. F.2 event emission

`stream_begin` (source_role=1, event_type=1):

  - `stream_id` (u32): the HDA stream tag bound to the DAC.
  - `format` (u16): the HDA format word (0x0011 in v1).
  - `channels` (u8): 2.
  - `rate_hz` (u32): 48000.

`stream_end` (source_role=1, event_type=2):

  - `stream_id` (u32): the stream tag being ended.
  - `frames_total` (u64): cumulative frame count played since
    begin (LPIB-derived, accounting for wraps).

Both events set `endpoint_slot` to the endpoint the stream
runs on. `ts_ordering` is `nanouptime`; `ts_sync` is 0 (F.4
reserves the right to populate it later without wire-format
change).

### 5. Attach-time test tone becomes the closure proof

The existing attach-time `audiofs_configure_output_stream` +
`audiofs_run_output_stream` call sequence is replaced by a
single `audiofs_stream_begin` call from the same attach
position (after `audiofs_state_register`, in the established
attach flow). The stream runs continuously until module
unload. Module unload calls `audiofs_stream_end` for every
active stream as part of detach.

Operational consequence (deliberate; flagged here, not a
surprise): after `kldload`, the bench iMac speaker plays a
48 kHz / 16-bit sine wave at the established amp gain
(unchanged from commit 6) until `kldunload`. That is the
F.3.a closure demonstration: continuous, indefinite,
lifecycle-controlled. Bench iteration of F.3.a uses
`kldunload` as the off switch.

The data plane and bring-up sequence inside the new entry
point reuse the commit-6 work that bench-verified the
electrical path. F.3.a does not redo that work; it wraps it
in start/stop control and adds the refill.

### 6. Removal of one-shot helpers

`audiofs_run_output_stream`, the `AUDIOFS_LPIB_SAMPLES` /
`AUDIOFS_LPIB_INTERVAL_US` constants, the LPIB-sampling loop,
and the `stream_lpib_sample`/`stream_lpib_advanced` logging
that bench-verified commit 6 are removed. The information
they provided (does LPIB advance, is the stream consuming
samples) is now implicit: the refill kthread polls LPIB
continuously and would log a failure to advance.

Specifically removed:

  - `audiofs_run_output_stream` and its static decl.
  - `AUDIOFS_LPIB_SAMPLES`, `AUDIOFS_LPIB_INTERVAL_US`.
  - The `run_result` capture in `audiofs_walk_topology` and
    the call site that invokes the one-shot run.
  - `stream_lpib_sample`, `stream_lpib_advanced`,
    `stream_run_no_config`, `stream_no_oss`,
    `stream_run_cleared` log events (the lifecycle is now
    covered by F.2 stream events; these in-kernel diagnostic
    events become noise once the kthread owns the loop).

`audiofs_configure_output_stream` survives in modified form
as the per-stream-begin setup helper.

### 7. Refill detection and frame counting

The kthread maintains two cursors on the softc:

  - `next_fill_byte`: the byte offset in the stream buffer
    where the next sine sample will be written. Increments
    modulo `AUDIOFS_BUF_BYTES`.
  - `frames_played_total`: cumulative frame count since
    `stream_begin`. Increments by the per-poll consumed-frame
    count (LPIB delta in bytes / bytes-per-frame).

The per-poll consumed-frame computation:

  - `prev_lpib`: last LPIB sample.
  - `curr_lpib`: current LPIB sample.
  - If `curr_lpib >= prev_lpib`: `delta = curr_lpib - prev_lpib`.
  - Otherwise (wrap): `delta = (AUDIOFS_BUF_BYTES - prev_lpib) + curr_lpib`.
  - `frames_played_total += delta / bytes_per_frame`.

Refill: any complete fragment that the LPIB has passed since
the previous poll is refilled. Detection uses the fragment
boundary cross. With 2 fragments of equal size, a fragment is
crossed when `prev_lpib` and `curr_lpib` lie in different
fragments, accounting for wrap.

### 8. Polling cadence

10 ms in v1. Rationale:

  - One fragment plays in ~21 ms; the whole buffer plays in
    ~42 ms.
  - The replay-glitch boundary is `buf_size - one_fragment`
    = ~21 ms after a fragment is consumed. 10 ms polling
    keeps the worst-case-since-last-poll (a single missed
    wakeup of jitter) at ~20 ms, just inside the boundary.
  - It matches the existing one-shot LPIB sample interval
    (`AUDIOFS_LPIB_INTERVAL_US = 10000`), so the bench
    timing experience is consistent.

The cadence is a `#define`; F.3.c may revisit it (or replace
the polling entirely with interrupts). 10 ms is not a wire
format and is not a closure-criterion number.

### 9. Stop-request semantics

The kthread polls a `stream_stop_requested` flag on each
iteration. `audiofs_stream_end` sets the flag and waits on a
completion variable the kthread signals on exit. The wait is
bounded (typical: one poll interval, ~10 ms); if the kthread
fails to acknowledge within a generous timeout (200 ms in
v1), `audiofs_stream_end` proceeds with cleanup anyway and
logs the abandonment. This avoids unload-deadlock if the
kthread is wedged.

### 10. What this commits

Closure criteria for F.3.a:

  1. `audiofs_stream_begin` / `audiofs_stream_end` exist and
     are in-kernel callable with the documented signatures.
  2. On `kldload` against the bench iMac, the attach path
     calls `audiofs_stream_begin` and the speaker plays a
     continuous sine wave (audible). The stream runs
     indefinitely; LPIB readings (visible via the kthread's
     bookkeeping if a diagnostic sysctl exposes it, or via
     dmesg if logged occasionally) advance monotonically
     through wraps.
  3. The F.2 events ring shows a `stream_begin` event at
     attach (writer_seq advances; the new event's
     `source_role` is 1, `event_type` is 1, payload decodes
     to stream_id, format, channels, rate_hz).
  4. On `kldunload`, the attach-time stream is ended:
     RUN is cleared, the kthread exits, a `stream_end` event
     is emitted with `frames_total` matching the
     elapsed-time expectation (within a few-ms tolerance).
  5. The state region's `last_event_seq` matches the events
     ring's `writer_seq` throughout (continuing F.1+F.2's
     correlation invariant).
  6. No deadlock, no lock-order panic, no leaked kthread,
     no `M_AUDIOFS` allocation leak on a load/unload cycle.

What F.3.a implementation lands:

  - Modifications to `audiofs/sys/dev/audiofs/audiofs.c`:
    new entry points, kthread, refill logic, attach-path
    rewrite, removal of one-shot helpers.
  - A small `audiofs_stream.h` private header (in
    `audiofs/sys/dev/audiofs/`) for the public-to-the-module
    signatures of stream_begin/end, if separation of
    concerns calls for it; or inline in audiofs.c if the
    surface is small enough. Decided at implementation
    time.
  - Updates to BACKLOG AD-3 status and the F.3 sub-milestone
    tracking.
  - No changes to `shared/AUDIO_STATE.md` or
    `shared/AUDIO_EVENTS.md` (the schema is unchanged; F.3.a
    populates reserved payloads).
  - No changes to `shared/src/audio.zig` strictly required:
    its existing `EventRingReader` already decodes any
    event, and the `Event.xrun` / `Event.endpointAttach`
    helper decoders cover the events F.2 emits. A new
    `Event.streamBegin` / `Event.streamEnd` helper pair is
    a natural addition and will land in the same commit
    range; not blocking.

What F.3.a implementation does NOT do:

  - Does not add interrupts (F.3.c).
  - Does not add a user API (F.3.b).
  - Does not implement xrun detection (F.3.d).
  - Does not negotiate format (F.3.e).
  - Does not bring up HDMI (F.3.f).
  - Does not write the clock region (F.4).
  - Does not change F.1 or F.2 wire formats.

## Why this design

**Why kthread + LPIB polling, not interrupts.** ADR 0011
explicitly places interrupt-driven position tracking in
F.3.c. Pulling interrupts into F.3.a would absorb F.3.c's
scope and conflate two changes: "make streaming continuous"
and "switch from polling to interrupts." Keeping them
separate means F.3.a's bench result speaks to one decision
(does the refill loop work) and F.3.c's later bench result
speaks to another (does the interrupt replacement work).
The 10 ms LPIB polling cadence is well within the safety
margin of the 42 ms buffer; performance is not the F.3.a
question.

**Why the sine wave, not silence.** Silence proves the
mechanism but not the audible continuity. The sine wave is
hearable proof: if the refill stalls or the kthread dies,
the bench operator hears it. The closure criterion is
inseparable from the audible payoff. F.3.b will replace the
source when a real data plane exists.

**Why convert the attach test tone instead of adding a new
path.** Two parallel stream-start paths (legacy one-shot,
new continuous) would be a forking maintenance liability and
would let the new path go stale. One path, exercised every
load, keeps the code honest. The trade is that the iMac
sings until unload; that is documented and is the closure
proof, not a side effect.

**Why remove the one-shot helpers entirely.** Per the
build-and-replace framing from ADR 0010: when an idea has
been proven and superseded, it goes. The commit-6 LPIB
sampling sequence proved the electrical path; F.3.a's
kthread polls LPIB continuously, so the diagnostic value is
preserved (and improved: it runs for the lifetime of the
stream, not 290 ms). Keeping the one-shot code would be a
parallel maintenance liability for no test value.

**Why two BDL entries, not four or eight.** Two is the
minimum viable for refill (one fragment plays while the
other is refilled). More entries reduce per-fragment refill
latency tolerance but require more code complexity in the
fragment-cross detection. F.3.c (interrupts) is the natural
place to grow the BDL: an IOC-per-entry model benefits from
more entries because each interrupt provides finer-grained
refill timing. F.3.a stays minimal.

**Why frames_total via LPIB delta, not a kthread counter.**
LPIB is the hardware's own position; counting via LPIB makes
the reported frames_total reflect what the hardware actually
clocked out. A kthread-side counter could drift if a refill
was missed (an xrun would be invisible). LPIB-derived
counting is honest about the physics, which is the ADR 0007
posture.

**Why 10 ms polling, not 5 or 20.** 5 ms is wasteful (4
polls per fragment with no benefit). 20 ms leaves only ~1
poll per fragment with no jitter margin. 10 ms matches the
existing commit-6 cadence and gives ~2 polls per fragment.
This is a tuning number, not a wire format; F.3.c can
replace the polling entirely.

## Consequences

### What this enables

  - **F.3.b** has a clean `audiofs_stream_begin`/`_end`
    surface to wrap in a user-facing API.
  - **F.3.c** has a kthread refill model to replace with an
    interrupt-driven model; the interfaces stay the same.
  - **F.3.d** has the existing per-poll consumed-frame
    computation to extend with xrun-gap detection.
  - **F.4** has a running stream against which the clock
    region's sample-position writes are correlated.
  - **semasound (F.5)** will see `stream_begin` and
    `stream_end` events flow on the F.2 ring as soon as it
    starts reading.

### What this commits

  - The `audiofs_stream_begin`/`audiofs_stream_end`
    signatures are stable in F.3.a. F.3.b may add additional
    APIs; it does not change these.
  - The `stream_begin` and `stream_end` event payloads from
    `shared/AUDIO_EVENTS.md` are now actively populated.
    Changing their layout is a wire-format break.
  - One audiofs stream per controller is the v1 assumption;
    multi-stream is not promised by F.3.a.
  - 48 kHz / 16-bit / stereo is the F.3.a stream format.
    F.3.e is what makes it negotiable.

### What this does not address

  - The interrupt path (F.3.c).
  - The user API (F.3.b).
  - xrun reporting (F.3.d).
  - Multi-stream concurrency.
  - HDMI streams (F.3.f).
  - Capture streams (out of F.3 scope; in F-stage map only
    by way of mention in F.3.e's format-query work, not as a
    delivered sub-stage).
  - The amp settings written at attach (unchanged from
    commit 6; F.3.a does not alter them, and they persist
    after unload as a codec-state artifact, unchanged from
    today).

## Relationship to ADR 0007

The events ring populated by F.3.a is still physics-only.
`stream_begin` and `stream_end` report what the hardware is
doing (it started running, it stopped running). The
`frames_total` in `stream_end` is the hardware's own LPIB
count. Policy responses (when to start, when to stop, what
content to play) live in semasound. F.3.a's role is to
expose the start/stop primitives and emit the corresponding
events.

## Relationship to ADR 0011

ADR 0011 sequences F.3.a -> F.3.b, F.3.a -> F.3.c, F.3.c ->
F.3.d, F.3.b -> F.3.e, F.3.f parallel. This ADR scopes
F.3.a within those edges. Each later sub-milestone gets its
own ADR; none of them are pre-empted here.

## Relationship to ADR 0013 and `shared/AUDIO_EVENTS.md`

F.3.a populates `stream_begin` (role=1, type=1) and
`stream_end` (role=1, type=2) per the schema reserved by
ADR 0013. The xrun (type 3) and format_change (type 4)
payloads stay reserved until F.3.d and F.3.e respectively.
ts_sync stays 0 (reserved for F.4). No schema change.

## Relationship to commit 6

The commit-6 series electrically proved the data path on
real hardware. F.3.a preserves the data-plane sequence
(format binding, DAC binding, RUN, sine fill) and wraps it
in lifecycle control plus the refill loop. The one-shot
`audiofs_run_output_stream` and its LPIB-sampling diagnostic
are retired in favor of continuous operation; the
information they provided is now ambient.

## What this document is not

  - Not the implementation. The audiofs.c changes, the
    kthread, the entry points, the attach rewrite, and the
    removals are separate commits.
  - Not a softening of ADR 0007. Sine wave forever is a
    physics surface; the policy of "play this audio when
    audiofs loads" is, regrettably, audiofs's own
    closure-proof artifact until F.3.b binds a real source.
    semasound will subsume this when it lands.
  - Not the F.3.b user API. F.3.a deliberately leaves
    `audiofs_stream_begin`/`_end` as in-kernel symbols only.
  - Not the F.3.c interrupt path. The kthread is
    intentionally a placeholder for F.3.c's interrupt
    handler. The lifecycle surface stays the same; only the
    refill driver changes.

## Amendment 2026-05-29 (post-bench safety)

The first audible F.3.a bench load on pgsd-bare-metal worked
exactly as Decision 5 specified: speaker plays sine wave on
kldload, continues until kldunload. The operational
consequence was also exactly as predicted ("iMac sings until
unload"). What was not predicted was that the prior
amplitude (16384, -6 dBFS) through the CS4206 amp at gain=115
on the iMac internal speaker would be *unbearably loud* at
continuous duration, and that the SSH off switch could
become unreachable during the load.

The operator could not silence the tone through normal
channels and had to physically pull power to stop it. That
is an unacceptable consequence of a development module load.
Decision 5 is amended as follows:

  - The continuous test tone remains the audible closure
    proof, but it is no longer automatic on kldload by
    default.
  - A module-global tunable / sysctl `hw.audiofs.test_tone`
    gates the autoplay. Default 0 (silent on attach). Set
    via `loader.conf` (autoplay at next boot) or runtime
    `sysctl hw.audiofs.test_tone=1` to enable, and back to
    0 to stop the stream cleanly on all controllers without
    needing kldunload.
  - The sine table amplitude is reduced from 16384
    (~-6 dBFS) to 164 (~-40 dBFS), "quiet speech" level.
    Operators who need louder output for diagnostic reasons
    can raise the codec amp gain via the existing path
    (commit 6).

Closure criteria 2 and 4 from the original ADR (speaker
plays after kldload; stops cleanly on kldunload) are now
restated:

  - 2': speaker plays after `sysctl hw.audiofs.test_tone=1`
    (or after kldload with the tunable set in loader.conf)
    at room-comfortable volume.
  - 4': speaker stops cleanly after `sysctl
    hw.audiofs.test_tone=0` OR after kldunload.

The bench audibility test from 2026-05-29 satisfied the
substance of criterion 2 (sound was produced; the codec amp
gate fix worked) even though the volume was hostile; this
amendment is forward-looking, to prevent a repeat of the
pulled-power moment.

This amendment is the result of bench experience overriding
ADR speculation. The discipline holds: the ADR is the
design contract, but reality reserves the right to amend it
when bench evidence shows the original framing was wrong
about real operational impact.
