# ADR 0009: AD-25 input wakeup via a kqueue bridge to the notify cdev

## Status

Accepted 2026-06-07 (operator-ratified in session; this ADR records
the decision and its bench criteria).

This ADR selects the fix for the wakeup half of **AD-25** (cursor
motion smoothness), following the Round U1 findings recorded in
BACKLOG.md and the root-cause analysis of the same evening. It
changes the semadraw daemon only. The inputfs kernel module is
deliberately unchanged; a companion kernel-side cleanup is recorded
as future work.

## Context

Round U1 (2026-06-07, the AD-38 closure capture) measured the main
loop strictly poll-timeout paced under active input: inter-pump
gaps of min 100.9 ms, median 104, max 107.3 over twenty seconds of
steady motion, zero early wakeups, while the inputfs event ring
carried roughly 130 motion events per second. Per-read freshness
was simultaneously confirmed (pos_changed on 90% of motion-phase
reads, real coordinates), so the ADR 0008 data-path fix works and
the remaining bottleneck is the wakeup. The measured user cost:
median 116 px, p90 197, max 621 per cursor update at 3840 wide.

The root cause is in the notify cdev's poll semantics
(inputfs.c, AD-41.3 block). d_poll is edge-only by deliberate
design: always selrecord, return 0, never POLLIN. That design was
itself the fix for an earlier level-trigger bug (no read syscall
means a level can never be consumed; the first event made the fd
permanently readable and consumers spun). But under poll(2) there
is no edge that bypasses d_poll: selwakeup from a publish only
triggers a kernel rescan, the rescan calls d_poll, d_poll returns
0 again by construction, and the kernel resumes sleeping out the
remaining timeout. A poll(2) consumer can never observe a publish
through this cdev. The cdev's kqueue path is correct: the filter
compares the ring's writer_seq against a per-knote snapshot, so
readiness is answered with per-consumer state. The device is in
effect kqueue-only, wearing a poll interface. Side finding, also
from U1: per ADR 0021 Decision 7 the wake fires unconditionally
per publish, so during motion the daemon is woken and lulled back
roughly 130 times per second for zero delivered information.

## Decision

semadrawd bridges the notify cdev into its existing poll loop via
kqueue:

  1. At input initialisation (alongside the existing notify cdev
     open), create a kqueue and register the notify fd with
     EVFILT_READ and EV_CLEAR.
  2. Add the kqueue's own descriptor to the main loop's poll set,
     in place of the notify fd's direct membership. kqueue
     descriptors are pollable; the kqueue fd reports POLLIN when
     a registered knote is active.
  3. On POLLIN against the kqueue fd, drain the kevent (a single
     kevent(2) call with a zero timeout) and run the existing
     input drain path (the event-ring harvest that feeds
     last_motion_x/y and the rest of the pointer pipeline).
     EV_CLEAR re-arms the knote on the kevent read, restoring
     edge semantics without a consumable level in the cdev.
  4. The standing AD-32 rule holds: a polled fd never enters the
     set without a dispatch-path drain handler; the kqueue fd's
     handler is the kevent drain plus the input path.
  5. The 100 ms poll timeout is retained as the idle pace and as
     the fallback if the bridge ever fails; the loop's shape (one
     posix.poll over one fd set) is unchanged.

## Alternatives considered

  - (a) Kernel pending-bit: publish sets an atomic flag; d_poll
    returns POLLIN when set and clears it (poll-consumes-edge).
    Correct and small, and the right eventual contract for the
    cdev, but costs a module rebuild and a bare-metal reload
    cycle under the live input stack. Recorded as the companion
    cleanup, not taken now.
  - (b) Implement d_read (consume-by-read, the eventfd pattern).
    Same reload cost as (a), more code, no advantage over (a) for
    this consumer.
  - (c2) Migrate the whole main loop to kevent. Larger change for
    the same effect; the bridge achieves event-driven input
    inside the existing loop shape. The full migration remains
    aligned with LT-2's recorded direction and can subsume the
    bridge later.
  - Shrinking the poll timeout (Round U3's experiment). A
    mitigation, not a fix: it trades idle CPU for sampling rate
    and still undersamples relative to the event rate. Superseded
    by the root-cause fix; retained as a control if the bridge
    bench surprises.

## Consequences

  - The wasted 130/s wakeup-rescan churn becomes 130/s of useful
    wakes; the pump samples at the event rate during motion and
    at the 100 ms heartbeat when idle.
  - Until the companion kernel cleanup lands, the notify cdev's
    poll interface remains a trap for future consumers. ADR 0021
    and the cdev's in-code comment are owed a "kqueue only"
    sentence in the interim (inputfs-side documentation change,
    tracked under AD-25's entry).
  - The bridge adds one fd and one syscall (the kevent drain) per
    input wake; no allocation, no new threads.

## Bench criteria

The unchanged two-phase capture (scripts/ad38-pump-capture.sh) is
the bench:

  - Idle phase: heartbeat at approximately 10/s, pos_changed
    false throughout, unchanged from the U1 baseline.
  - Motion phase: pump emission rate rises from approximately
    10/s toward the event rate (the existing PASS threshold of
    50/s holds; the Round 2 era reference is approximately
    130/s), and the ps_x step distribution shrinks
    proportionally from the U1 baseline (median 116 px).
  - The AD-43-era census remains the regression guard: idle
    composites must stay at the SM-4 floor; the bridge must not
    reintroduce any spin.
