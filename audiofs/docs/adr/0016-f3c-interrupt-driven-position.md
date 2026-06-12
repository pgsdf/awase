# 0016 F.3.c: interrupt-driven position tracking

## Status

Accepted, 2026-05-30 (ratified same day as proposed; design
choices reviewed and confirmed by the bench operator before
implementation began). Per ADR 0011, F.3.c is the third F.3
sub-milestone, depending on F.2 (events ring,
bench-verified `[x]` 2026-05-28). The scope statement from
ADR 0011: "Replace LPIB polling with stream interrupt
handler. Position updates flow into the events ring (F.2)
and the clock region (F.4)."

This ADR does not reverse, reopen, or amend ADRs
0006/0007/0008/0010/0011/0012/0013/0014/0015. It scopes
one sub-stage (F.3.c) within the F-stage map.

## Context

F.3.a (ADR 0014) introduced a kthread that wakes every
10 ms (via `pause("audrefill", hz/100)`), reads SDnLPIB,
and refills any BDL fragment the DMA engine has consumed.
F.3.b (ADR 0015) added a user-ring source for the same
kthread, replacing the internal sine source with userland-
written audio data. Both rely on wall-clock-driven polling
at 10 ms granularity.

Polling has two costs that motivate F.3.c:

  - **Position jitter for F.4.** ADR 0003 (clock writer)
    specifies that the kernel writes the audio sample
    position into the shared clock region on each audio
    interrupt that reflects new frames clocked out, giving
    semasound a tight (sample-position, wall-time) pair
    for synchronization. The F.3.a polling kthread cannot
    deliver this: position updates are bounded by the
    10 ms poll interval, so the timestamp lags the
    physical position by up to 10 ms in the worst case.
    F.4 needs sub-millisecond accuracy.

  - **xrun detection latency.** F.3.d (per ADR 0011) wires
    underrun detection to F.2 xrun events. Underruns
    surface in HDA via the FIFOE bit in SDnSTS, set the
    moment the FIFO is empty when the controller wants
    samples. The F.3.a kthread can only notice this on
    its next poll (up to 10 ms late). F.3.d wants the
    interrupt path so events are timestamped accurately.

F.3.c replaces the kthread polling with the real HDA stream
interrupt path: the BDL entries get IOC=1 (Interrupt-On-
Completion), the controller's INTCTL register enables the
stream's interrupt source, and a registered handler runs
on each BDL boundary completion.

## What audiofs needs to add at F.3.c

  - **PCI interrupt allocation** at attach time. Match
    FreeBSD's standard pattern: try MSI (single vector),
    fall back to INTx. Allocate IRQ resource, set up the
    handler, register on the bus.

  - **A filter + ithread handler pair.** The filter runs in
    interrupt context (no sleep), acknowledges the
    interrupt at the hardware level, and schedules the
    ithread. The ithread runs in a kernel thread, can take
    MTX_DEF locks, and does the actual refill work.

  - **A new spin mutex** for the filter handler's register
    accesses. The existing `hw_lock` is MTX_DEF and cannot
    be taken from filter context.

  - **IOC=1 on BDL entries.** Currently `htole32(0)` per
    F.3.a; flip to `htole32(1)` so the controller raises an
    interrupt at each fragment boundary.

  - **INTCTL register management.** Set GIE + CIE + SIE
    bits at `stream_begin`, clear at `stream_end`.

  - **Retire the polling kthread.** `audiofs_refill_worker`
    and its synchronization fields (`output_stream_kproc`,
    `_stop_requested`, `_stopped`) go away. Replace with a
    single `output_stream_active` flag that the ithread
    checks at entry.

What F.3.c does NOT add:

  - **xrun event emission.** F.3.d. The ithread will count
    FIFOE occurrences in a softc counter; F.3.d will
    surface them as F.2 events.

  - **Clock region writes.** F.4. The ithread will compute
    frames_played per interrupt, but the clock region
    shared-memory writes wait for F.4's design.

  - **Format negotiation.** F.3.e.

  - **HDMI bring-up.** F.3.f.

  - **Multi-stream interrupts.** v1 has one output stream
    per controller. The filter handler's INTSTS routing
    code is structured to extend to multiple streams when
    F.3.b's multi-stream story arrives, but does not need
    that work yet.

## Decision

### 1. PCI interrupt allocation: MSI preferred, INTx fallback

In `audiofs_attach`, after BAR mapping and before CORB/RIRB
init, allocate the IRQ:

  - Call `pci_alloc_msi` with count=1. If it returns
    success, the controller will use MSI.
  - If MSI fails (count returns 0 or error), use INTx
    (`bus_alloc_resource_any` with `SYS_RES_IRQ` and
    `RF_SHAREABLE | RF_ACTIVE`).
  - Either way, the resulting IRQ resource is stored in
    `sc->irq_res` with rid in `sc->irq_rid`.
  - Track which path was taken in `sc->msi_count` (1 if
    MSI, 0 if INTx) for the detach release path.

Call `bus_setup_intr` with:

  - `INTR_TYPE_AV` (audio/video, the conventional class for
    audio interrupts).
  - `INTR_MPSAFE`. audiofs takes its own locks; no Giant
    needed.
  - Filter handler: `audiofs_intr_filter`.
  - Ithread handler: `audiofs_intr_thread`.
  - Cookie returned into `sc->irq_cookie` for teardown.

Setup failure at any step is a hard attach error: detach
the controller, free already-allocated resources, return
the error. The F.3.a polling-kthread fallback is NOT
retained; if interrupts cannot be set up, audiofs declines
to manage this controller. (Bench experience will tell us
if this is too strict.)

### 2. Filter handler: minimal, spin-mutex-only

The filter handler runs in interrupt context. It cannot
sleep, cannot take MTX_DEF mutexes, cannot do significant
memory operations. Its sole job is to acknowledge the
interrupt at the hardware level and decide whether to
schedule the ithread.

```
static int
audiofs_intr_filter(void *arg)
{
    /* Take intr_lock (MTX_SPIN). */
    /* Read HDAC_INTSTS. */
    /* If our stream's bit (bit output_stream_idx) is set:
     *   Read SDnSTS for our stream.
     *   OR the bits into sc->output_stream_last_sdsts.
     *   Write the bits back to SDnSTS to clear (RWC).
     *   Drop intr_lock.
     *   Return FILTER_SCHEDULE_THREAD.
     * Else:
     *   Drop intr_lock.
     *   Return FILTER_STRAY.
     */
}
```

Maximum hardware work: 3 register I/Os (INTSTS read, SDnSTS
read, SDnSTS write). No memory operations beyond the softc
field write.

The `output_stream_last_sdsts` field is a uint8_t. The
filter ORs into it (does not overwrite) so that if the
ithread is delayed and a second interrupt fires before the
ithread runs, both events' bits are preserved.

### 3. Ithread handler: refill, frames_played, xrun counting

The ithread handler runs in a kernel thread. It can take
MTX_DEF mutexes. Its job is the actual refill work plus
bookkeeping.

```
static void
audiofs_intr_thread(void *arg)
{
    /* If !output_stream_active (under intr_lock briefly),
     *   return. (Race protection at teardown.)
     *
     * Take hw_lock (MTX_DEF) briefly:
     *   Read SDnLPIB. (current position)
     *
     * Take intr_lock briefly:
     *   sdsts = output_stream_last_sdsts;
     *   output_stream_last_sdsts = 0;
     *
     * Drop locks.
     *
     * Compute frames_played delta from prev_lpib to
     * curr_lpib, accumulate into output_stream_frames_played.
     *
     * If sdsts & BCIS:
     *   Refill output_stream_next_refill_fragment via
     *   audiofs_refill_fragment dispatcher.
     *   Advance cursor mod AUDIOFS_BDL_ENTRIES.
     *
     * If sdsts & FIFOE:
     *   sc->output_stream_underflow_count++.
     *   (F.3.d will surface this.)
     *
     * If sdsts & DESE:
     *   device_printf warning. (Descriptor error is
     *   exceptional; the stream is probably broken.)
     */
}
```

The ithread is owned by FreeBSD's kernel; it runs when the
filter returns `FILTER_SCHEDULE_THREAD` and is invoked by
the kernel's interrupt thread infrastructure. We do not
spawn or stop it ourselves; we only register/unregister it
via `bus_setup_intr` / `bus_teardown_intr`.

### 4. Kthread retirement

The F.3.a polling kthread is fully retired:

  - `audiofs_refill_worker` function deleted.
  - `output_stream_kproc`, `_stop_requested`, `_stopped`
    softc fields deleted.
  - The `msleep(... "audstop" ...)` wait in `stream_end` is
    deleted.
  - `kproc_create` and `kproc_exit` calls deleted.

Replaced with:

  - `output_stream_active` (int, boolean). Set to 1 in
    `stream_begin` AFTER all configuration is complete and
    interrupts are enabled. Set to 0 in `stream_end` BEFORE
    clearing RUN. The ithread checks this flag at entry.
  - The check at ithread entry takes `intr_lock` briefly
    so the set/clear ordering interlocks with the filter
    handler.

`stream_end` simplifies to:

```
audiofs_stream_end:
    Take intr_lock briefly: set output_stream_active = 0.
    Take hw_lock:
        Clear stream's SIE bit in HDAC_INTCTL.
        Clear RUN in SDnCTL.
        Read final SDnLPIB.
    Drop hw_lock.
    Add final delta to frames_played.
    Unbind DAC.
    Emit F.2 stream_end event.
    Return.
```

The "in-flight ithread invocation might run one more time
after we clear SIE" race is handled by the
`output_stream_active` guard at ithread entry. After we set
it to 0 under intr_lock, any new ithread invocation
returns early without touching the now-being-torn-down
state.

### 5. INTCTL register management

`HDAC_INTCTL` bits (per HDA spec section 3.3.14):
  - GIE  (bit 31): Global Interrupt Enable.
  - CIE  (bit 30): Controller Interrupt Enable.
  - SIE  (bits 0-29): one per stream, enabling that
    stream's interrupt source.

In `stream_begin`, after setting RUN:

```
ctl = AUDIOFS_READ_4(sc, HDAC_INTCTL);
ctl |= HDAC_INTCTL_GIE | HDAC_INTCTL_CIE |
       (1U << sc->output_stream_idx);
AUDIOFS_WRITE_4(sc, HDAC_INTCTL, ctl);
```

In `stream_end`, before clearing RUN:

```
ctl = AUDIOFS_READ_4(sc, HDAC_INTCTL);
ctl &= ~(1U << sc->output_stream_idx);
/* Leave GIE and CIE set; other audiofs streams (when
 * we add them) or future use of CIE may need them. */
AUDIOFS_WRITE_4(sc, HDAC_INTCTL, ctl);
```

In `audiofs_detach`, after `stream_end` (which clears SIE
for the one stream we have):

```
ctl = AUDIOFS_READ_4(sc, HDAC_INTCTL);
ctl &= ~(HDAC_INTCTL_GIE | HDAC_INTCTL_CIE);
AUDIOFS_WRITE_4(sc, HDAC_INTCTL, ctl);
```

Then `bus_teardown_intr` (which blocks until any pending
ithread invocation completes), then `bus_release_resource`
on the IRQ, then `pci_release_msi` if MSI was allocated.

### 6. IOC=1 on BDL entries

In `audiofs_configure_output_stream`, change the BDL entry
construction:

```
- bdl[i].ioc = htole32(0);
+ bdl[i].ioc = htole32(1);   /* F.3.c: IOC, raise interrupt
+                              when this entry completes */
```

With 2 BDL entries each covering half the 8 KB buffer at
48k/16/stereo, that is one interrupt every ~21 ms, ~47
interrupts per second. Comfortably within HDA controller
budgets.

### 7. New softc fields and lock ordering

```
struct audiofs_softc {
    /* ... F.3.a/b fields ... */

    /* F.3.c interrupt handling. */
    struct resource *irq_res;       /* IRQ resource */
    int              irq_rid;
    void            *irq_cookie;    /* bus_setup_intr cookie */
    int              msi_count;     /* 1 if MSI, 0 if INTx */
    struct mtx       intr_lock;     /* MTX_SPIN, covers
                                       output_stream_last_sdsts
                                       and output_stream_active
                                       transitions */
    uint8_t          output_stream_last_sdsts;
                                    /* OR-accumulated by
                                       filter, read+cleared
                                       by ithread */
    int              output_stream_active;
                                    /* F.3.c: replaces _running,
                                       _stop_requested,
                                       _stopped trio from F.3.a */

    /* Deletions from F.3.a: */
    /* struct proc *output_stream_kproc;     -- deleted */
    /* int output_stream_stop_requested;     -- deleted */
    /* int output_stream_stopped;            -- deleted */
};
```

Lock ordering (extended from F.3.b):

  - `audiofs_state_sx` (sleepable, outermost) -- F.2
    event publish, softc registry iteration.
  - `output_stream_user_ring_mtx` (MTX_DEF, middle) --
    user ring head/tail/source/cdev_open; msleep address
    for back-pressure.
  - `hw_lock` (MTX_DEF, innermost-1) -- register writes,
    CORB commands, LPIB reads.
  - `intr_lock` (MTX_SPIN, innermost) -- filter handler
    register I/O (INTSTS, SDnSTS), `output_stream_active`
    and `output_stream_last_sdsts` field accesses.

intr_lock is innermost: never held while taking any other
audiofs lock. This is the standard FreeBSD pattern for
filter-context interrupt locks.

### 8. Bench-safety review

Per the discipline lesson from ADR 0014's post-bench
amendment, F.3.c's implementation passes a bench-safety
review BEFORE the first bench load on pgsd-bare-metal:

  - **Default behavior at first kldload after F.3.c lands**:
    no cdev consumer, tunable still 0, so no stream is
    running. No interrupts fire (the IRQ resource is set
    up but no stream-source bits are enabled in INTCTL).
    Speaker silent. Same as F.3.b-amended default.

  - **First audible test**: `sudo sysctl hw.audiofs.test_tone=1`
    enables the internal sine. This now runs through the
    new ithread path. Speaker plays quiet sine at -40 dBFS,
    same as F.3.b. `hw.audiofs.test_tone=0` stops it
    cleanly via the same path. The amplitude and opt-in
    autoplay from ADR 0014's amendment remain unchanged.

  - **Bench-safety risks specific to F.3.c**:
    - An interrupt storm (e.g. SDSTS bit stuck set, can't
      be cleared) would saturate the CPU. Mitigation: the
      filter writes the SDSTS bit back to clear it (RWC);
      if the write does not clear, the next read shows
      the bit still set, but we still ack it and return.
      If the hardware truly will not clear the bit, the
      filter will loop firing every interrupt entry, but
      not within a single filter call. CPU saturation but
      not a hang.
    - A "stuck active" state (interrupts disabled but
      stream still running) would not be hostile from a
      sound perspective: stream would stop the moment the
      BDL underruns (~21 ms) since the kthread is no
      longer there to refill. So the worst case is
      ~21 ms of audio then silence.

  - **Off-switch**: `kldunload` still works as the
    ultimate stop. The detach sequence disables interrupts
    and clears RUN before releasing the IRQ.

  - **Bench iteration**: tests reuse `playtone` and the
    existing `bench-f3b.sh` scripted suite. The bench-f3b
    suite was designed around criteria 1-7 of ADR 0015 and
    happens to also exercise F.3.c's interrupt path
    (since F.3.c is the new mechanism, not a new API).
    Specific F.3.c checks: dmesg shows `intr_setup_msi` or
    `intr_setup_intx` at attach; under streaming load, the
    underflow_count counter is observable (via a new
    sysctl); the kproc named "audiofs_refill" no longer
    appears in `ps -auxw` after stream_begin.

The bench-safety gate for F.3.c: rerun `bench-f3b.sh`
unmodified. If all 14 PASSes from F.3.b still pass under
the new interrupt path, F.3.c's machinery is at least as
correct as F.3.a/b's. Additional manual checks confirm the
interrupt path is actually in use (no kthread present,
dmesg shows interrupt setup, underflow counter exists).

### 9. Diagnostics: new sysctls and events

  - `dev.audiofs.<N>.interrupts_setup`: read-only, reports
    "msi" or "intx" or "none". Lets the operator confirm
    which path was taken at attach.

  - `dev.audiofs.<N>.underflow_count`: read-only, exposes
    the F.3.b underflow counter that previously was
    softc-internal. F.3.d will replace this with F.2
    events; for F.3.c the sysctl is the only way to see it.

  - New event log entries (no new F.2 ring events):
    `intr_setup_msi`, `intr_setup_intx`, `intr_teardown`.
    Visible in `audiofs_log` so the deployment-gate
    discipline can confirm which path each controller
    used.

## What this commits

Closure criteria for F.3.c:

  1. The polling kthread is GONE. `ps -auxw | grep audiofs`
     shows no `audiofs_refill` process while a stream is
     running.

  2. `bench-f3b.sh` still passes all 14 checks unchanged.
     (Source swap, back-pressure, double-open EBUSY, SIGKILL
     cleanup, all the F.3.b closure criteria continue to
     work.)

  3. `dev.audiofs.0.interrupts_setup` reports "msi" or
     "intx" (not "none") on attach for the iMac.

  4. `dev.audiofs.0.underflow_count` exists and reports 0
     after a clean playtone run; rises if playtone is
     deliberately slowed (e.g., wrapped in a slow loop).

  5. The dmesg `intr_setup_msi` or `intr_setup_intx` event
     fires once per controller at attach; `intr_teardown`
     fires once per controller at detach.

  6. No interrupt storm. Under sustained playtone load,
     `vmstat -i` shows audiofs interrupt rate near 47/sec
     per active stream (one per BDL fragment at ~21 ms
     intervals), not thousands.

  7. Clean kldunload after the full test sequence. No
     leaked IRQ, no leaked MSI vectors, no panic on
     teardown.

### What F.3.c implementation lands

  - Modifications to `audiofs/sys/dev/audiofs/audiofs.c`:
    filter and ithread handler functions, attach IRQ
    setup, detach teardown, INTCTL management, BDL IOC=1,
    softc field changes, kthread deletion, new sysctls.

  - Updates to BACKLOG AD-3 status reflecting F.3.c
    landing.

  - No changes to `shared/AUDIO_STATE.md` or
    `shared/AUDIO_EVENTS.md` (schema unchanged).

  - No changes to `shared/src/audio.zig` (no new event
    payloads).

### What F.3.c implementation does NOT do

  - Does not emit F.2 xrun events (F.3.d).
  - Does not write the clock region (F.4).
  - Does not negotiate format (F.3.e).
  - Does not bring up HDMI (F.3.f).
  - Does not change F.1 / F.2 / F.3.b wire formats.
  - Does not change the user-ring or cdev surface.
  - Does not retain the F.3.a kthread as a fallback.

## Why this design

**Why filter + ithread, not filter-only or thread-only.**
Filter-only would require all refill work (memcpy from
user ring, BDL DMA sync, frames_played accumulation,
underflow counting) to run in interrupt context with a
spin lock held. user_ring_mtx is MTX_DEF; converting it
to MTX_SPIN would force `write(2)`'s copyin into a
stack-buffer-then-copy scheme, which is real complexity
for no benefit. Thread-only is not available in FreeBSD's
interrupt API the way filter is; the filter is required
to at least acknowledge the interrupt.

The filter + ithread split is the conventional FreeBSD
pattern for "do the minimum in hardware-context, do the
rest in thread-context." It is exactly what `bus_setup_intr`
is designed for.

**Why MSI preferred, INTx fallback.** MSI gives us our own
interrupt vector with no sharing, so the filter never
returns FILTER_STRAY for someone else's interrupt. INTx
works but requires the filter to read INTSTS even on
spurious entries from sharing. Both work; MSI is just
cleaner. The hdac(4) driver (which we are not modeling on
but does inform our register knowledge) uses the same
fallback order. Note: ADR 0008 names hdac(4) as the
predecessor we are replacing, not a reference architecture;
the MSI-preferred ordering is a property of MSI-vs-INTx
ergonomics, not of hdac(4).

**Why retire the kthread instead of keeping it as a
watchdog.** F.3.c's whole point is "interrupts instead
of polling." Keeping a polling watchdog would mean two
code paths for the same thing forever, with the constant
question of which one is running and whether they agree.
If interrupts are unreliable on real hardware, that is a
real defect to address by hardware-specific quirks at the
filter handler level, not by retaining a fallback that
masks the defect. (The fallback can be re-introduced if
bench experience shows it is needed.)

**Why a separate intr_lock instead of converting hw_lock
to MTX_SPIN.** Converting hw_lock would force every
existing user (CORB commands with DELAY, configure_output_
stream with DMA allocation, stream_end's msleep wait) to
become spin-safe. Some of those would require non-trivial
restructuring; the msleep wait in stream_end is exactly
what F.3.a's first bench session crashed on. A separate
intr_lock with narrow scope (filter handler + active flag
+ last_sdsts field) is the minimum disruption.

**Why IOC=1 on every BDL entry instead of every Nth.** With
only 2 BDL entries, IOC=1 on every-entry gives one
interrupt per ~21 ms. Alternative would be 4+ BDL entries
with IOC on every Nth, reducing interrupt rate at the cost
of larger BDL and longer drain latency. v1 keeps the 2-
entry, every-entry pattern from F.3.a/b for minimal
disruption to the existing buffer model. F.3.c-future
could tune.

**Why output_stream_active flag instead of just using the
filter's SIE-clear as the teardown.** A filter that just
returns FILTER_STRAY when SIE is clear works for one race
but not the other: between the filter scheduling the
ithread and the ithread running, we might have cleared
SIE. If the ithread doesn't check active, it accesses
already-being-torn-down state. The active flag closes that
window cleanly.

## Relationship to ADR 0003 (clock writer)

F.4 will read `output_stream_frames_played` at each
interrupt and write the clock region. F.3.c does NOT do
this writing itself, but it makes the frames_played value
accurate to within one fragment (~21 ms) of physical
position at any moment, instead of within one poll-cycle
(~10 ms) on average and up to ~10 ms worst-case.

The fragment-granularity bound is actually similar to the
poll-cycle worst-case (both are around 10-20 ms). The real
F.4 benefit comes from interrupt timing being **jitter-
free**: the timestamp is taken at hardware completion of a
fragment, which is regular (every 1024 frames = 21.333 ms
exactly at 48 kHz), not at wall-clock-poll boundaries that
drift with scheduler load.

## Relationship to ADR 0011

F.3.c follows F.3.a/b per the dependency map. F.3.d, F.4
both depend on F.3.c landing first:

  - F.3.d uses the FIFOE bit and the underflow_count
    counter that F.3.c introduces.
  - F.4 uses the interrupt-paced frames_played that F.3.c
    introduces.

F.3.e (format negotiation) is parallel to F.3.c. F.3.f
(HDMI) is parallel.

## Relationship to ADR 0014 (F.3.a)

F.3.a's bench-safety amendment (quieter sine, opt-in
autoplay tunable) carries over unchanged. F.3.c's ithread
runs the same refill helpers (`audiofs_refill_sine_fragment`,
`audiofs_refill_user_fragment`, `audiofs_refill_fragment`
dispatcher), so the volume and source-swap behavior are
identical to F.3.b. The only thing that changes is what
drives the refill loop.

## Relationship to ADR 0015 (F.3.b)

F.3.b's cdev surface, user ring, 3-state source machine,
back-pressure model, exclusive-open semantics, and v1
known-behaviors (cold-open sine leak, close-no-drain) all
carry over unchanged. F.3.c is invisible to userland; the
`/dev/audiofs<N>` write path is identical from the userland
perspective.

The 14 PASSes from bench-f3b.sh's verification of F.3.b
should all continue to pass under F.3.c. That is criterion
2 of F.3.c's closure proof.

## Consequences

### What this enables

  - **F.3.d** has the FIFOE bit and the
    `output_stream_underflow_count` softc field; can wire
    F.2 xrun events.
  - **F.4** can read `output_stream_frames_played` on each
    interrupt with sub-millisecond jitter and write the
    clock region.
  - **Diagnostic tooling**: the new
    `dev.audiofs.<N>.interrupts_setup` and
    `underflow_count` sysctls give bench operators a clean
    view of the interrupt setup and the underflow
    accounting.

### What this commits

  - The interrupt path becomes the only path for stream
    progression. No fallback to polling.
  - MSI-preferred / INTx-fallback is the v1 IRQ
    allocation order.
  - intr_lock is MTX_SPIN; everything else stays MTX_DEF.
  - One interrupt per BDL fragment (~47/sec under sustained
    load per active stream).

### What this does not address

  - Multi-stream interrupt routing. v1 has one output
    stream per controller. The filter's INTSTS logic is
    written to scale, but multi-stream is not bench-
    verified at F.3.c.
  - HDMI-specific interrupt handling (F.3.f).
  - Clock-region writes (F.4).
  - xrun event emission (F.3.d).

## What this document is not

  - Not the implementation. The audiofs.c interrupt
    handler, attach IRQ allocation, detach teardown,
    softc field changes, BDL IOC=1, INTCTL management,
    and kthread retirement are separate commits after
    ratification.
  - Not a softening of ADR 0008's anti-snd(4) stance. The
    hdac(4) reference in ADR 0008 names what audiofs is
    replacing; F.3.c uses spec-derived register knowledge
    and hdac_reg.h macros only.
  - Not a softening of ADR 0007. The interrupt path is
    physics-only: report what the hardware tells us
    (BCIS, FIFOE, DESE) into the appropriate state. Policy
    (whether to surface underflows, how often to update
    clocks) belongs to semasound / userland.
  - Not the F.3.d xrun design. F.3.c counts underflows
    internally; F.3.d's ADR will decide how they surface.
  - Not the F.4 clock-writer design. F.3.c maintains
    accurate frames_played; F.4 decides how to publish it.
