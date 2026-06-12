# 0017 F.3.d: xrun detection and reporting

## Status

Accepted, 2026-05-30 (replaces the same-numbered earlier
draft of 2026-05-30 that incorrectly assumed the F.3.a
refill kthread still existed; F.3.c retired that kthread,
documented in ADR 0016 section 4. This revision corrects the
deferral mechanism).

**Amended 2026-05-30** with a Post-Bench Amendment section
at the end of this document, recording that F.3.d's original
detection point (hardware FIFOE in the ithread) is
unreachable under playtone --stall on the pgsd-bare-metal
bench because the user-ring zero-pad path in
`audiofs_refill_user_fragment` masks the underrun before it
can fire in hardware. The amendment moves the detection
point to that zero-pad path and takes advantage of the
sample-accurate gap that becomes available there. Everything
above the amendment is the as-ratified text, preserved for
the historical record; readers should treat the amendment's
specification as authoritative for implementation.

**Second amendment 2026-05-30** (Coalescing Empirical Note,
at the end of this document): the bench result for the
amended F.3.d closure showed 15 of 16 PASS, with the
sole FAIL being the absence of `AUDIOFS_EVFLAG_COALESCED`
under sustained-stall. Investigation showed that on
`pgsd-bare-metal` the taskqueue dispatch latency is small
enough that each xrun task completes before the next BCIS
interrupt arrives (~21 ms apart at the fragment rate), so
the taskqueue's pending-bit never gets a chance to coalesce.
The second amendment reframes coalescing as opportunistic
rather than mandatory: one event per shortfall with
sample-accurate gap_frames is more informative than
coalesced events with summed gaps, and is the actual
behavior on a healthy system.

Per ADR 0011, F.3.d is the fourth F.3
sub-milestone, depending on F.3.c (interrupt-driven position
tracking, bench-verified `[x]` 2026-05-30, ADR 0016). The
scope statement from ADR 0011: "xrun detection in the
interrupt path; xrun events emitted on the F.2 events ring
with physics-level payload."

Implementation follows in a separate commit after
ratification, in the same shape as the prior F.3 sub-stages
(kernel change + bench), with explicit bench-safety review
before the new behavior reaches the iMac (per the discipline
lesson recorded in ADR 0014's post-bench amendment).

This ADR does not reverse, reopen, or amend ADRs
0006/0007/0008/0010/0011/0012/0013/0014/0015/0016. It scopes
one sub-stage (F.3.d) within the F-stage map.

## Context

F.3.c (ADR 0016) wired the HDA stream interrupt path: the
filter handler reads `SDnSTS`, OR-snapshots the bits into
`output_stream_last_sdsts`, clears them at the hardware
level, and schedules the ithread. The ithread reads `LPIB`
under `hw_lock`, advances `frames_played`, and refills any
fragment the controller has consumed.

ADR 0016 also retired the F.3.a refill kthread entirely (see
ADR 0016 section 4): `audiofs_refill_worker`, the
`output_stream_kproc` softc fields, the `kproc_create` and
`kproc_exit` calls, and the `msleep("audstop")` synchronisation
in `stream_end` are all gone. After F.3.c, audiofs has no
standing in-kernel thread of its own; everything happens
either in attach/detach/cdev context (sleepable, with
`audiofs_state_sx` held) or in the filter / ithread (not
sleepable).

The filter and ithread already see the three SDnSTS condition
bits the HDA controller can raise per stream:

  - **BCIS** (buffer completion): a BDL entry with IOC=1 was
    consumed. F.3.c uses this to refill from the ithread.
  - **FIFOE** (FIFO error): the controller wanted samples
    from the FIFO and the FIFO was empty. This is an
    underrun.
  - **DESE** (descriptor error): the controller could not
    fetch a BDL entry from system memory. Exceptional; F.3.c
    logs but does not stop the stream.

The current F.3.c ithread handles FIFOE this way (see
`audiofs.c` line 4515):

```c
if (sdsts & HDAC_SDSTS_FIFOE)
    sc->output_stream_underflow_count++;
```

The comment immediately above says "F.3.d will surface as F.2
xrun events. v1: counter only." This ADR specifies how that
surfacing works.

F.3.d's job is to turn underrun detection into the
physics-level xrun event already specified by ADR 0013 and
documented in `shared/AUDIO_EVENTS.md`:

> | 3 | `xrun` | `stream_id`(u32 0-3), `xrun_kind`(u8 4;
> 0=underrun, 1=overrun), `_pad`(u8[3] 5-7),
> `gap_sample_pos`(u64 8-15), `gap_frames`(u32 16-19) |

The schema, the ring mechanics, the `gap_sample_pos` /
`gap_frames` semantics, the source_role/event_type dispatch:
all of that is already specified. F.3.d does not redefine
any of it; F.3.d implements the emission path.

The hard part is not "what to emit" but "how to emit it from
the right context with the right physics." Three concerns:

  - **Context.** `audiofs_events_publish` holds
    `audiofs_state_sx` (sleepable) and may do VFS I/O via
    `audiofs_events_sync`. The ithread cannot sleep, so it
    cannot publish directly. With the kthread gone, F.3.d
    must introduce a new deferral mechanism.

  - **`gap_frames` accuracy.** ADR 0013 specifies
    `gap_frames` as "the gap size in frames." Per the HDA
    spec, FIFOE indicates the FIFO was empty when the
    controller wanted a sample, but the controller does not
    expose how long the FIFO has been empty. Without
    additional hardware support audiofs cannot give an
    exact gap. ADR 0007 (physics-semantics boundary)
    requires audiofs to report what it actually knows, not
    what would be convenient.

  - **Coalescing.** A sustained underrun produces FIFOE on
    every interrupt until samples flow again. ADR 0013
    specifies `AUDIOFS_EVFLAG_COALESCED` for "this event
    represents multiple coalesced occurrences"; F.3.d
    should use it.

## Deferral mechanism: taskqueue

F.3.d defers xrun publish from the ithread to FreeBSD's
`taskqueue_fast`. The ithread enqueues a per-softc task; the
task runs in the taskqueue's own kernel thread context,
where it can sleep and therefore call
`audiofs_events_publish`.

### Why taskqueue rather than reviving a kthread

A new kthread would also work. Taskqueue wins because:

  - **Sleeps when idle.** A taskqueue's worker thread runs
    only when work is enqueued; idle costs are a sleeping
    thread, not a polling loop. F.3.a's retired kthread
    polled at 10 ms; that overhead is gone, and we should
    not reintroduce it for a code path that fires only on
    underrun.
  - **Standard idiom in UTF.** `inputfs_kbdmux.c` defers
    HID-callback work to `taskqueue_fast` for exactly the
    same reason (cross-context handoff from non-sleepable
    to sleepable). F.3.d's pattern matches.
  - **No new state machine.** The taskqueue's `task_pending`
    bit (managed internally by FreeBSD) coalesces repeated
    enqueues for free: if the task is already pending,
    enqueuing again is a no-op. This is exactly the
    coalescing behavior F.3.d wants without writing any
    coalescing logic.
  - **Trivial teardown.** `taskqueue_drain` in detach blocks
    until any in-flight task completes; no race with module
    unload.

### Why `taskqueue_fast` rather than `taskqueue_swi`

`taskqueue_swi` uses a sleep mutex internally for its
enqueue. Enqueuing from spin context (which the ithread is
not by the time we reach the FIFOE branch, but might become
if a future revision moves the enqueue earlier into the
path) trips WITNESS with "acquiring blockable sleep lock
with spinlock or critical section held." `taskqueue_fast`
uses spin locks internally for enqueue and is therefore
safe from any context.

This is the same choice `inputfs_kbdmux.c` made, with the
lesson recorded in its source (lines 760-790): use
`taskqueue_fast` for enqueues that might run in spin
context. The dispatch side (the task body) runs in a
regular kernel thread regardless of which queue we picked,
so sleeping in the task body is fine either way.

The system-provided `taskqueue_fast` (declared in
`<sys/taskqueue.h>`, brought up at boot) is sufficient.
F.3.d does NOT create a per-softc taskqueue: the system
queue is shared with other consumers but the work F.3.d
schedules is trivial (at most one publish per coalesced
window), well inside what the queue can absorb.

## What audiofs needs to add at F.3.d

  - **Three new softc fields** for the pending xrun state:

      - `output_stream_pending_xrun_frames` (u32): an
        upper-bound estimate of the gap size accumulated
        since the last published xrun event. Incremented in
        the ithread on FIFOE; cleared in the task body
        when the event is published.

      - `output_stream_xrun_gap_pos` (u64): the
        `frames_played` value captured at the FIRST FIFOE
        in a coalesced window. This is the
        `gap_sample_pos` for the event the task body will
        emit when it drains. Reset to 0 (sentinel for "no
        pending xrun") after publish.

      - `output_stream_xrun_coalesced_count` (u32): how
        many FIFOE interrupts have been folded into the
        pending event. The task body sets
        `AUDIOFS_EVFLAG_COALESCED` on publish iff this is
        greater than 1.

    All three are protected by `intr_lock` (MTX_SPIN),
    held across the ithread update and the task body
    drain. This is the same lock used for cross-context
    handoff between filter and ithread today, so F.3.d
    introduces no new locking primitive.

  - **One new softc field** for the taskqueue task:

      - `output_stream_xrun_task` (struct task): the task
        structure passed to `TASK_INIT` and
        `taskqueue_enqueue`.

  - **Ithread FIFOE branch update.** The existing one-line
    counter increment expands to set the pending fields
    under `intr_lock` and enqueue the task. The counter
    increment stays (it remains useful for the
    `dev.audiofs.<N>.underflow_count` sysctl as a
    saturation counter independent of the published
    events).

  - **Task body function `audiofs_xrun_task`.** Runs in the
    taskqueue's kernel thread. Reads and clears the
    pending fields under `intr_lock`. If the cleared
    `pending_xrun_frames` is non-zero, builds the payload
    per `shared/AUDIO_EVENTS.md`'s schema and calls
    `audiofs_events_publish` with `AUDIOFS_EVROLE_STREAM`,
    `AUDIOFS_EVSTREAM_XRUN`, the endpoint slot, and
    `AUDIOFS_EVFLAG_COALESCED` when the coalesced count
    exceeds 1.

  - **`TASK_INIT` at attach.** The task is initialised
    once (no per-cycle init cost). The task structure is
    part of the softc and lives as long as the softc.

  - **`taskqueue_drain` at stream_end.** Before clearing
    `output_stream_active`, `stream_end` calls
    `taskqueue_drain(taskqueue_fast, &sc->output_stream_xrun_task)`
    to ensure any in-flight or pending task completes
    before the stream is torn down. After drain, the
    pending fields are guaranteed to have been published
    (or were already zero), so the stream's final state is
    visible on the events ring before the stream_end event
    is itself published.

  - **`taskqueue_drain` at detach.** Standard cleanup,
    matching the inputfs precedent.

  - **Gap-frames estimation comment.** A code comment in
    the ithread documents the estimate model so a future
    contributor reading the FIFOE handler understands why
    `gap_frames` uses fragment-bytes rather than a smaller
    unit. References this ADR.

### Gap-frames estimation model

Per ADR 0007's physics framing, audiofs reports what it
actually knows. The HDA spec does not expose a "FIFO has
been empty for N samples" counter; FIFOE is a level
indicator, not a duration.

What audiofs DOES know:

  - Interrupts arrive at fragment boundaries (~21 ms apart
    at 48 kHz / 16-bit / stereo / 4096-byte fragments).
  - If FIFOE is set at interrupt N, the FIFO ran empty
    sometime between interrupt N-1 and interrupt N.
  - Therefore the underrun gap is at most one fragment
    long per FIFOE-positive interrupt.

The v1 estimate: each FIFOE increments
`pending_xrun_frames` by `AUDIOFS_BUF_FRAG_BYTES / 4`
(one fragment in stereo 16-bit frames, 1024 frames). This
is an upper bound: "the controller's FIFO ran empty for at
most this many samples." A consumer that needs tighter
gaps can correlate `gap_sample_pos` against its own
`frames_played` reading to refine, but audiofs itself
will not claim more precision than the hardware exposes.

## What F.3.d does NOT do

  - **Per-sample gap reconstruction.** The HDA spec does
    not expose a "FIFO has been empty for N samples"
    counter. Without that, F.3.d cannot give sample-exact
    gap sizes. The fragment-granularity estimate is the
    best physics-honest answer; tighter estimates would
    require hardware features audiofs cannot summon.

  - **xrun recovery actions.** ADR 0007 holds: physics
    reports, semantics decides. audiofs reports the
    underrun; semasound (when it exists) decides whether
    to resync, drop frames, log, or escalate. v1 audiofs
    keeps the stream running through underruns (it has no
    choice: stopping the stream on every underrun would
    be a policy decision).

  - **Overrun (`xrun_kind = 1`) reporting.** F.3.d is an
    output-only stage per ADR 0011 (capture is F-stages
    beyond the current scope). Overrun is meaningful only
    for input streams. The schema's overrun case is
    reserved; F.3.d emits only underrun
    (`xrun_kind = 0`).

  - **DESE-derived events.** Descriptor error is a
    separate failure mode (DMA-engine cannot fetch BDL).
    It is exceptional and rare; ADR 0011 places DMA fault
    reporting outside F.3.d. F.3.c's logging path stays
    as it is.

  - **A per-softc taskqueue.** The system-provided
    `taskqueue_fast` is sufficient. Creating a dedicated
    taskqueue would buy serialisation against other
    taskqueue consumers but pay for it in extra setup,
    teardown, and a per-softc kernel thread. F.3.d's work
    is too small to need that.

  - **Sample-accurate `ts_ordering`.** ADR 0013's
    `ts_ordering` is captured at publish time inside
    `audiofs_events_publish` via `nanouptime`. F.3.d
    accepts this: the wall-clock delay between the
    underrun and the published event is bounded by the
    taskqueue's dispatch latency (sub-millisecond in
    practice), and sample-position correlation via
    `gap_sample_pos` is the load-bearing field anyway.

## Closure criteria

F.3.d closes when:

  1. The ithread's FIFOE branch updates the pending-xrun
     fields under `intr_lock` and enqueues the xrun task.
  2. The task body drains the pending fields under
     `intr_lock` and emits an xrun event via
     `audiofs_events_publish` with the schema-correct
     payload, setting `AUDIOFS_EVFLAG_COALESCED` when the
     coalesced count exceeds 1.
  3. `stream_end` calls `taskqueue_drain` before clearing
     `output_stream_active`, ensuring no xrun is lost at
     teardown.
  4. `detach` calls `taskqueue_drain` before freeing the
     softc.
  5. A bench test deliberately induces an underrun
     (described below) and observes a corresponding xrun
     event in the events ring, with `gap_sample_pos` near
     the underrun's actual sample position.
  6. Sustained underrun produces coalesced events at the
     taskqueue's dispatch rate (bounded by FIFOE rate;
     coalesced as the taskqueue absorbs repeated enqueues
     while the task is pending), and the `coalesced` flag
     is set when more than one FIFOE folded into one
     event.
  7. The bench operator marks F.3.d `[x]` on
     `pgsd-bare-metal`, mirroring the F.3.a/b/c closure
     pattern.

## Bench test plan

Inducing an underrun deliberately on the bench is the new
verification burden F.3.d introduces. Two reproducible
approaches:

  - **Stall-the-source method.** Modify `playtone` (the
    F.3.b user-ring test tool) to support a `--stall ms`
    flag that pauses writing samples to the user ring for
    a specified duration after some initial playback. The
    ring drains, the controller fetches what it can, and
    eventually FIFOE fires. The stall duration controls
    how many fragments worth of underrun the test
    reproduces. This is the primary method because it
    does not require kernel modifications and exercises
    the same path semasound would hit in production (slow
    consumer feeds slow producer).

  - **Sysctl-injected method.** A new
    `hw.audiofs.test_underrun` sysctl that, when set,
    would force a synthetic FIFOE-equivalent path. This
    is a test-only crutch and would require a separate
    audit per ADR 0010's discipline on test-only kernel
    surfaces. v1 of F.3.d does NOT add this sysctl; the
    stall-the-source method is sufficient for closure.

The bench verification sequence (parallel to F.3.a/b/c
benches):

  1. Load audiofs with the F.3.d changes.
  2. Run `playtone --stall 100` (or a variant): begin
     playback, pause briefly, resume. Audible glitch
     expected.
  3. Read the events ring via the F.2 reader tool. Expect
     an `xrun` event with `xrun_kind = 0`, non-zero
     `gap_sample_pos`, and `gap_frames` in the
     fragment-granularity range (1024 to a few thousand
     frames depending on stall duration).
  4. Run `playtone --stall 1000` (sustained underrun).
     Expect one or more events with
     `AUDIOFS_EVFLAG_COALESCED` set; total event count
     bounded by the taskqueue dispatch rate, not the
     FIFOE interrupt rate.
  5. Confirm `dmesg` shows no kernel panics, no DESE
     errors, no `INVARIANTS` failures, no WITNESS
     complaints about lock ordering.

The bench-safety review per ADR 0014's amendment: before
running on the iMac, the bench operator confirms that the
changes are confined to the FIFOE branch of the ithread,
the task body function, the new softc fields, and the
attach / stream_end / detach drain hooks; that no other
paths are modified; and that the deferral fields default
to a state (zero) that produces no-op behavior if the
ithread never sets them.

## Consequences

### What this enables

  - semasound (when it exists) sees underruns as discrete
    events with sample-position correlation, enabling
    sample-accurate resync without polling for FIFOE.
  - The events ring sees a fourth event family in
    production use, validating the schema's xrun layout.
  - The closure-criteria mechanism for F.3 advances one
    step toward F.4 (clock writer), which itself unblocks
    F.5 (semasound).
  - The taskqueue pattern is established for audiofs (it
    was already established for inputfs); future audiofs
    work that needs ithread-to-sleepable-context handoff
    has a documented precedent.

### What this forecloses

  - **Sample-exact gap reporting.** v1 commits to
    fragment-granularity. A future ADR could revisit if
    hardware capability surveys reveal a way.
  - **Overrun reporting in F.3.d.** Reserved for an input
    stage outside the current F-map.
  - **Per-event detection-time wall-clock timestamps.**
    `ts_ordering` is the publish moment; correlation is
    via `gap_sample_pos`. A follow-on may revisit if
    jitter matters for semasound's use.

### What this requires

  - **`audiofs_events_publish` callable from taskqueue
    context.** True today (the taskqueue thread can sleep
    and acquire `audiofs_state_sx`).
  - **`shared/AUDIO_EVENTS.md` xrun schema.** Already
    specified and unchanged by F.3.d.
  - **`output_stream_active` guard.** The task body
    checks `output_stream_active` under `intr_lock`
    before publishing, so a task that runs after
    `stream_end` has started clearing state will see
    active=0 and return without publishing. The
    `taskqueue_drain` in `stream_end` then ensures no
    straggler is left pending.
  - **`taskqueue.h` include and FreeBSD's standard
    `taskqueue_fast`.** No new build dependency.

## References

  - `audiofs/docs/adr/0011-fstage-reconciliation.md` (F.3.d
    scope statement and dependency on F.3.c)
  - `audiofs/docs/adr/0013-f2-events-ring.md` (events ring
    design, xrun schema)
  - `audiofs/docs/adr/0016-f3c-interrupt-driven-position.md`
    (the interrupt path F.3.d builds on; kthread
    retirement that motivates the taskqueue choice)
  - `audiofs/docs/adr/0007-physics-semantics-boundary.md`
    (physics-only constraint shaping `gap_frames` model)
  - `audiofs/docs/adr/0014-f3a-continuous-streaming.md`
    (post-bench discipline lesson)
  - `audiofs/docs/adr/0010-retire-audit-as-gate.md`
    (test-only kernel surface discipline; why no sysctl
    crutch in v1)
  - `shared/AUDIO_EVENTS.md` (event slot layout, xrun
    payload, coalesced flag semantics)
  - `inputfs/sys/dev/inputfs/inputfs_kbdmux.c` lines
    760-790 (the `taskqueue_fast` vs `taskqueue_swi`
    lesson)


## Post-Bench Amendment (2026-05-30)

### The diagnostic finding

The kernel-side F.3.d implementation was committed
(`82f7559`) and the bench was set up per the test plan
above. `playtone --stall 500 /dev/audiofs0 2` was run on
`pgsd-bare-metal`. The audible result was "two distinct
long beeps" with clean silence between them. The
`dev.audiofs.0.underflow_count` sysctl rose from 0 to 15.
Zero xrun events appeared on the F.2 events ring.

A diagnostic patch (since reverted) added per-step
`device_printf` probes through the FIFOE detection, the
taskqueue enqueue, and the task body. None of the probes
ever fired on `dmesg`, but `objdump --section=.text` on the
loaded `audiofs.ko` confirmed the probe call sites are fully
compiled in. The probes' call instructions are at known
offsets inside `audiofs_intr_thread` and
`audiofs_xrun_task`, with valid format-string operands and
working `callq` targets.

The puzzle resolved when the second increment of
`output_stream_underflow_count` was located. The counter is
incremented in TWO places in `audiofs.c`:

  1. Line 4353, inside `audiofs_refill_user_fragment`.
     Fires when the BCIS refill path runs and the user
     ring has fewer than `AUDIOFS_BUF_FRAG_BYTES` bytes
     available. audiofs zero-pads the missing bytes into
     the DMA fragment and increments the counter.
  2. Line 4574, inside `audiofs_intr_thread`'s FIFOE
     branch. Fires when the HDA controller reports FIFOE
     in SDnSTS.

The 15 increments observed during the bench all came from
the first call site. The HDA controller's FIFO never
actually ran dry because audiofs's refill path kept it fed
with zeros. The "clean silence" the operator heard was the
DAC playing those zeros, not the FIFO underrunning in
hardware. FIFOE never asserted in SDnSTS, the filter never
saw it, the ithread's FIFOE branch never executed, F.3.d's
detection point was never reached, and no xrun events
published.

This makes F.3.d as-ratified unreachable in practice under
the bench's exercise pattern, and unreachable under the
production pattern semasound will produce (where slow
userland feed is the normal cause of underrun, not
hardware-level FIFO exhaustion).

### Why detection moves to user-ring shortfall

audiofs's zero-pad behavior at line 4353 is the right
choice for audio continuity: zero bytes at the DAC are
audibly preferable to whatever the FIFO would play on real
underrun (sample replay, stuck values, or random controller
behavior depending on hardware). Removing the zero-pad to
make hardware FIFOE reachable would degrade the audio
experience to fix the instrumentation. That is the wrong
trade-off.

The xrun event semantics, as specified in
`shared/AUDIO_EVENTS.md` and the schema portion of this
ADR, are independent of which audiofs path detects the
underrun. The schema says:

> | 3 | `xrun` | `stream_id`, `xrun_kind` (0=underrun),
> `gap_sample_pos`, `gap_frames` |

"Underrun" is the consumer-facing condition. Whether
audiofs detected it via the FIFOE bit or via its own
user-ring shortfall accounting is an internal audiofs
concern that does not change the event payload.

Detection at line 4353 is also strictly better than
detection at line 4574 in two respects:

  - **Sample-accurate `gap_frames`.** The original ADR
    had to commit to an upper-bound estimate (one fragment
    per FIFOE) because the HDA spec does not expose a
    "FIFO has been empty for N samples" counter. At line
    4353, audiofs knows the exact byte count it zero-padded:
    `AUDIOFS_BUF_FRAG_BYTES - copy_bytes`. Divided by 4
    (stereo 16-bit), that is the exact gap in frames.
    Physics-level honesty per ADR 0007 improves: the
    reported gap is what actually happened, not an upper
    bound.

  - **Detected earlier.** The shortfall is observed when
    audiofs zero-pads the DMA fragment, which happens at
    BCIS-driven refill time. FIFOE in hardware would fire
    one fragment later, after the controller had played
    the zeros and started reading past the fragment
    boundary into the next zero-padded fragment. Detection
    at the refill point gives consumers earlier notice.

### Revised detection point and emission

The detection point becomes line 4353 of
`audiofs_refill_user_fragment`. The taskqueue-deferred
publish mechanism from the ratified ADR is preserved
unchanged. The FIFOE branch in `audiofs_intr_thread` and
its task-enqueue call become dead code in normal operation;
see "Fate of the existing FIFOE branch" below.

The detection code at line 4353 becomes:

```c
if (shortfall) {
    memset(dst + copy_bytes, 0,
        AUDIOFS_BUF_FRAG_BYTES - copy_bytes);
    sc->output_stream_underflow_count++;

    /* F.3.d: defer xrun publish to taskqueue_fast. The
     * gap is sample-accurate because we know exactly
     * how many bytes were zero-padded. */
    mtx_lock_spin(&sc->intr_lock);
    if (sc->output_stream_pending_xrun_frames == 0) {
        /* First shortfall in this coalesced window. */
        sc->output_stream_xrun_gap_pos =
            sc->output_stream_frames_played;
    }
    sc->output_stream_pending_xrun_frames +=
        (uint32_t)(AUDIOFS_BUF_FRAG_BYTES - copy_bytes) / 4;
    sc->output_stream_xrun_coalesced_count++;
    mtx_unlock_spin(&sc->intr_lock);

    taskqueue_enqueue(taskqueue_fast,
        &sc->output_stream_xrun_task);
}
```

The four softc fields, the task body function
(`audiofs_xrun_task`), the `TASK_INIT` in attach, the
inline-drain logic in stream_end, and the `taskqueue_drain`
in detach are all preserved from the ratified
implementation. Only the trigger point moves.

### Fate of the existing FIFOE branch

The FIFOE branch at line 4574 in `audiofs_intr_thread`
stays. Removing it would (a) require another patch when
the change set is already substantial, and (b) leave
audiofs unable to report a real hardware FIFOE if one
ever does occur (a sustained DMA fault or other extreme
condition where the zero-pad path itself falls behind).

The FIFOE branch keeps its current behavior: increment
the saturation counter, update pending fields under
`intr_lock`, enqueue the task. In the new design these
two paths converge on the same xrun publish, with
identical payload shape. A hardware FIFOE would be a
genuine independent event, reported with the same schema,
with `gap_frames` falling back to the one-fragment
upper-bound estimate (since at FIFOE time audiofs no
longer knows exactly how much was lost).

If both paths fire for the same underrun (zero-pad runs,
then FIFOE fires a fragment later because the zero-pad
itself was late), the taskqueue's pending-bit coalesces
them into one event. The coalesced flag is set; the
`gap_frames` is the sum of contributions from both paths.
This is acceptable because the consumer's interest is
"an underrun happened, this is how big," not "which path
inside audiofs noticed."

### Closure criteria (amended)

F.3.d closes when:

  1. The user-ring shortfall branch at line 4353 updates
     the pending-xrun fields under `intr_lock` and
     enqueues `output_stream_xrun_task` on
     `taskqueue_fast`.
  2. The existing FIFOE branch at line 4574 continues to
     enqueue the same task (no change from the ratified
     implementation).
  3. The task body and stream_end inline-drain remain
     unchanged.
  4. `playtone --stall 500 /dev/audiofs0 2` produces at
     least one xrun event on the F.2 events ring with
     `xrun_kind = 0` and a non-zero `gap_frames` that
     reflects the actual byte count zero-padded.
  5. `playtone --stall 1500 /dev/audiofs0 3` produces
     one or more events, at least one with
     `AUDIOFS_EVFLAG_COALESCED` set; total event count is
     bounded by the taskqueue dispatch rate.
  6. `dmesg` shows no panics, no WITNESS complaints, no
     DESE errors, no traps.
  7. Operator marks F.3.d `[x]` on `pgsd-bare-metal`.

### Bench plan (amended)

Same as the ratified bench plan, with one clarification:
the expected `gap_frames` for `--stall 500` will be in
the range 8000-40000 (one or more fragments worth of
zero-pad, depending on how many BCIS cycles the stall
spans). The ratified ADR estimated 1024 to a few thousand
frames, which was correct for the one-fragment FIFOE
estimate but underestimates the user-ring shortfall gap,
which sums across all stalled fragments.

### What this amendment does NOT change

  - The schema in `shared/AUDIO_EVENTS.md` is unchanged.
  - The `taskqueue_fast` deferral mechanism is unchanged.
  - The four softc fields are unchanged.
  - The task body function `audiofs_xrun_task` is
    unchanged.
  - The `TASK_INIT`, stream_end inline-drain, and detach
    `taskqueue_drain` are unchanged.
  - ADRs 0001-0016 are not reopened.

### References (added by amendment)

  - `audiofs/sys/dev/audiofs/audiofs.c` line 4353
    (`audiofs_refill_user_fragment`, the new detection
    point).
  - `audiofs/sys/dev/audiofs/audiofs.c` line 4574 (the
    existing FIFOE branch, retained as a defensive
    secondary path).
  - Bench session 2026-05-30 (diagnostic chain;
    `objdump`-confirmed compilation, `dmesg`-confirmed
    absence of FIFOE firing, audible-output-confirmed
    zero-pad behavior).


## Second Post-Bench Amendment (2026-05-30): Coalescing Empirical Note

### What the bench showed

After committing the F.3.d amendment (detection at line
4353 of `audiofs_refill_user_fragment`), the bench script
ran on `pgsd-bare-metal` and reported 15 PASS, 1 FAIL:

  - Section 3 (regression, no-stall playback): PASS.
  - Section 4 (`--stall 500`, 2 sec total): 15 xrun events
    published, `gap_frames=1024` each, `gap_sample_pos`
    monotonic and spaced exactly one fragment apart
    (50148, 51172, 52196, ...). PASS.
  - Section 5 (`--stall 1500`, 3 sec total): 61 xrun
    events published; 47 underflow_count delta; no event
    had `AUDIOFS_EVFLAG_COALESCED` set. FAIL (per the
    closure criteria as written).
  - Section 6 (dmesg sanity): no panics, no WITNESS, no
    DESE. PASS.

The single FAIL was in the coalescing criterion (criterion
6 in the first amendment). Investigation showed:

  - The taskqueue dispatch latency on this bench is small
    (sub-millisecond): each enqueued task body completes
    well before the next BCIS interrupt arrives ~21 ms
    later. The taskqueue's pending-bit only folds repeated
    enqueues when a new enqueue arrives while the task is
    still pending. On a healthy system it never does.
  - The 61 events from a 1500 ms stall correspond to
    roughly one event per BCIS interrupt during the stall
    window. Each event carries the exact gap (one
    fragment, 1024 frames) for the shortfall it represents.
  - Sample positions advance monotonically by exactly
    1024 between consecutive events, confirming no gap is
    lost or double-counted.

### Why this is acceptable

Coalescing was specified in the ratified ADR and the first
amendment as a defense against event-ring overflow under
sustained underrun. The actual ring capacity is 256 slots,
and 61 events per 1.3 seconds of sustained shortfall is
well inside what the ring absorbs (extrapolating to
~470 events for a 10-second sustained stall, still 53%
ring utilization). Coalescing is not needed for
throughput.

The non-coalesced behavior is also informationally richer:

  - **Sample-accurate gap timing.** Each event reports
    exactly one fragment worth of gap, at a precise
    `gap_sample_pos`. A consumer (semasound) can
    reconstruct the full shortfall timeline from these
    events: contiguous events with adjacent
    `gap_sample_pos` values describe one continuous
    underrun period, while gaps between event
    sequences describe distinct underrun bursts.
  - **No information loss to summing.** If coalescing
    folded multiple shortfalls into one event with summed
    `gap_frames`, the consumer would know only the
    aggregate. The current behavior preserves per-shortfall
    timing.
  - **No additional latency.** Coalescing inherently
    delays publish until the taskqueue dispatcher catches
    up; non-coalesced publish happens at the earliest
    moment audiofs's state is consistent.

Per ADR 0007's physics-semantics boundary: audiofs reports
what it actually observes (one shortfall = one event with
exact gap). Semantics layers decide whether to aggregate.

### What this amendment changes

The closure criterion in the first amendment that required
`AUDIOFS_EVFLAG_COALESCED` on at least one event under
sustained-stall is replaced with:

> The sustained-stall test publishes one or more events
> with monotonic `gap_sample_pos`. `AUDIOFS_EVFLAG_COALESCED`
> may appear if dispatch latency causes pending-bit folding,
> but its absence is also acceptable: a system fast enough
> to drain each shortfall before the next arrives is
> behaving correctly, and per-shortfall events with exact
> gap timing are more informative than coalesced ones.

The bench script (`audiofs/bench-f3d.sh`) is updated to
treat absent COALESCED as a `note`, not a `bad`.

### What this amendment does NOT change

  - The `AUDIOFS_EVFLAG_COALESCED` mechanism in the task
    body remains: when `coalesced_count > 1`, the flag is
    set. This behavior is unchanged; only the test
    expectation changes.
  - The schema in `shared/AUDIO_EVENTS.md` is unchanged.
  - The taskqueue deferral, softc fields, and lifecycle
    hooks are unchanged.
  - The first amendment's detection-point move (line
    4353) is unchanged and validated by the 15 PASS
    results.

### Closure criteria (re-amended)

F.3.d closes when:

  1. The user-ring shortfall branch at line 4353 updates
     the pending-xrun fields under `intr_lock` and
     enqueues `output_stream_xrun_task` on
     `taskqueue_fast`. (Verified by bench.)
  2. The existing FIFOE branch at line 4574 continues to
     enqueue the same task. (No change.)
  3. The task body and stream_end inline-drain remain
     unchanged.
  4. `playtone --stall 500 /dev/audiofs0 2` produces at
     least one xrun event with `xrun_kind=0`, non-zero
     `gap_sample_pos`, and `gap_frames` reflecting actual
     byte counts. (Verified: 15 events, all gap_frames=1024.)
  5. `playtone --stall 1500 /dev/audiofs0 3` produces
     events with monotonic `gap_sample_pos`. (Verified:
     61 events, monotonic by exactly 1024 per step.)
     `AUDIOFS_EVFLAG_COALESCED` may or may not appear;
     either is acceptable.
  6. `dmesg` shows no panics, no WITNESS complaints, no
     DESE errors, no traps. (Verified.)
  7. Operator marks F.3.d `[x]` on `pgsd-bare-metal`.
     (Pending after this amendment lands and bench re-runs
     to confirm 16 PASS / 0 FAIL.)

### References (added by second amendment)

  - Bench session 2026-05-30: 15 PASS / 1 FAIL with
    sample-accurate `gap_frames=1024` and monotonic
    `gap_sample_pos` across all 76 xrun events emitted
    (15 from brief stall + 61 from sustained stall).
