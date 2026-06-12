# ADR 0008: AD-25 cursor motion smoothness fix direction

## Status

Accepted 2026-05-12.

This ADR concludes the design phase of **AD-35** (BACKLOG.md). It
selects a direction for resolving the cursor-motion symptom that
opened **AD-25** and that the AD-34 investigation localised to a
specific FreeBSD mmap-visibility problem. The chosen direction
also closes **AD-32** (semadrawd main loop busy-wait) as a side
effect.

## Context

The AD-25 → AD-34 investigation chain established the following
facts, recorded in ADR 0007's two addenda and in
`docs/FREEBSD_ISSUES.md` Issue #1:

  - semadrawd's compositor renders the cursor when `needsComposite`
    returns true. `needsComposite` returns true when the damage
    tracker has damage AND the FrameScheduler's deadline has
    passed. Round 2 of AD-25 confirmed the FrameScheduler is
    willing on 72.9% of calls; damage is the closed gate.
  - Damage is marked when the cursor pump observes a position
    change in inputfs's published state. AD-34 E1 instrumentation
    showed the pump's `pointerSnapshot()` returns the **same**
    `(ps.x, ps.y)` value for the entire lifetime of the daemon
    (39,991 of 39,992 reads identical).
  - The same `_semadraw` user reading the same file via `read(2)`
    sees fresh bytes between calls; only `mmap(MAP_SHARED,
    PROT_READ)` is stuck.
  - Root processes mmap'ing the same file see updates correctly.

A late finding (recorded in this ADR) reframes the problem. When
the design analysis began, the AD-34 hypothesis was that
**tmpfs + mmap + non-root credential** broke uniformly. To verify
this before committing to a direction, `inputdump events --watch`
was run as `_semadraw`:

```
sudo -u _semadraw inputdump events --watch --interval-ms 50
```

It saw **live pointer.motion events flowing at hardware rate**,
hundreds of events per second, absolute x/y coordinates updating
across the framebuffer. This is the same primitive
(`mmap(MAP_SHARED, PROT_READ)` of a tmpfs file written by the
inputfs kthread via `vn_rdwr(IO_SYNC)`) that fails for the state
region. **The event ring works; the state region does not.**

This finding is significant for two reasons:

  - It eliminates one of the three candidate fix directions
    (Direction 3, the cursor-helper daemon) because its
    motivation evaporated. The privilege boundary is not the
    issue; the privilege boundary plus the state-region's
    specific access pattern is.
  - It localises the kernel-side question more precisely. The
    bug is not "non-root mmap of any tmpfs file written by
    `vn_rdwr`"; it is something specific to the **access pattern
    in the state-region write path**. The event-region writes
    differ in two ways that may matter: per-slot offset writes
    rather than whole-buffer writes, and writes that touch
    different pages over time rather than always the same pages.
    These observations are recorded in `docs/FREEBSD_ISSUES.md`
    Issue #1 (updated).

The decision below is informed by this finding.

## Decision

UTF will adopt **Direction 2: switch semadrawd to consume the
inputfs event ring for cursor position, rather than polling the
state region's mmap**. Implementation is tracked as new BACKLOG
entries; see Consequences.

The state region is not abandoned. Other consumers (keyboard
state, focus, smoothing parameters) continue to use it as
appropriate, with awareness that some access patterns hit the
kernel-side staleness bug and others don't. The FreeBSD-side
question (Direction 1) is retained as a sibling track in
**AD-34**, which stays open. If a kernel-side fix lands later,
no UTF code changes; consumers that work today keep working.

### Why Direction 2

The event ring is the right data path for cursor motion in any
architecture, independent of the bug:

  - **Events are pollable.** The ring's underlying notification
    is integrated with `/dev/draw` (per shared/INPUT_EVENTS.md);
    semadrawd's main loop can sleep on poll(2) and wake on
    actual input rather than spinning at 67 kHz. This closes
    AD-32 as a side effect, without requiring a separate fix.
  - **Events carry absolute coordinates plus deltas.** Each
    `pointer.motion` event payload includes x, y, dx, dy. The
    pump can derive cursor position directly from event payloads
    without consulting the state region at all for the position
    update path.
  - **Events deliver at hardware rate.** Bench measurement
    from a `sudo -u _semadraw inputdump events --watch`
    capture during sustained cursor motion: 465 pointer.motion
    events delivered in ~4.25 s, or roughly 110 events/sec,
    with inputfs's kthread bounded at `INPUTFS_SYNC_HZ=1000`.
    This is the same rate as the underlying hardware reports
    and exceeds the 60 Hz frame target by ~80%.
  - **The ring already has a userspace consumer
    (`inputdump events`) and a reader (`shared/src/input.zig`
    `EventRingReader`) that handles seqlock retry, overrun
    detection, and resynchronisation.** semadrawd reuses this
    code, not invents it.
  - **The ring works as `_semadraw`.** The privilege drop in
    semadrawd is preserved; no new daemon, no setuid-helper,
    no privilege machinery.

### Why not Direction 1 (FreeBSD-side fix) as primary

Direction 1 would investigate FreeBSD's tmpfs vm_object code or
modify `inputfs_state_sync_to_file` to invalidate non-root
mmaps explicitly (e.g., by calling `vm_object_page_clean` after
`vn_rdwr`, or by switching the write mechanism). It is not
discarded; it stays on the table as kernel-side cleanup.

It is not the primary fix because:

  - **Depth is unknown.** Reading enough FreeBSD tmpfs code to
    propose a fix with confidence is multi-day work. Submitting
    it upstream and getting it accepted is months. Carrying a
    patch out-of-tree indefinitely is its own cost.
  - **It does not close AD-32.** The busy-wait would persist
    until a separate refactor of the main loop.
  - **Direction 2 fixes the user-visible symptom now.** A
    kernel-side cleanup landing later is a refinement, not a
    blocker.
  - **The bug's narrow characterisation (state region only)
    reduces urgency.** Other consumers can avoid the broken
    path by reading events instead of polling state, which is
    architecturally cleaner anyway.

### Why not Direction 3 (root cursor helper)

Direction 3 was motivated entirely by the assumption that
non-root processes could not see live inputfs publication via
mmap. The `_semadraw inputdump events` test invalidated that
assumption. Without that motivation, Direction 3 trades a clean
data path (Direction 2) for:

  - An additional supervised daemon in the s6 tree.
  - A new IPC mechanism between the helper and semadrawd
    (specification, implementation, error handling).
  - A new data format for the helper-to-compositor cursor plane.
  - All the trade-offs of process boundaries (latency hop, more
    moving parts during bringup, more failure modes).

For zero benefit over Direction 2. Direction 3 is rejected.

### Risks and qualifications

  - **Ring overrun under sustained input.** The ring is 1024
    slots. At 200 events/sec, that's a 5-second buffer. If
    semadrawd is preempted or blocked for longer than that
    interval, events are lost and the consumer must
    resynchronise. `RingDrainResult.overrun` already signals
    this. The current state-region poll is naturally tolerant
    of staleness (it just reads the current value); the
    event-stream consumer is not. semadrawd's input loop must
    handle overrun without losing track of current cursor
    position. Mitigation: on detected overrun, the consumer
    can attempt one `read(2)` of the state region (the
    `_semadraw read(2)` path that AD-34 confirmed works) to
    resynchronise absolute position. The mmap'd view is
    unusable but `read(2)` is not.
  - **Bootstrap.** The pump currently starts with no cached
    position and waits for the first state-region read to seed
    `last_cursor_pos_*`. The event-consumer version starts by
    draining the ring from earliest available seq forward;
    the latest motion event provides the seed position. If the
    ring is empty at startup (no input since inputfs boot),
    the consumer waits for the first event before marking
    damage.
  - **Other consumers retain the broken access pattern.**
    Semadrawd's pump is one consumer of the state region;
    others (focus resolution, device enumeration, smoothing
    parameters) still mmap it. They are not yet known to
    exhibit the staleness because they read less frequently
    or because their data does not change after bringup. The
    risk is that one of them quietly returns stale data and
    we do not notice for a while. Mitigation: documented in
    `docs/FREEBSD_ISSUES.md`; future bringup of any new
    inputfs-state mmap consumer should be bench-verified
    against the same problem.
  - **AD-34 stays open as a kernel-investigation track.** The
    underlying FreeBSD-side bug is not fixed; it is worked
    around. The architectural change is good even without the
    bug, but the bug remains a known issue that may surface
    in other state-region consumers later. Direction 1 work
    can resume at any priority level later without affecting
    Direction 2's implementation.
  - **Existing pump instrumentation.** AD-25 Round 1's
    `pump_diagnostic` event and AD-34 E1's `ps_x, ps_y` fields
    are gated on `UTF_PUMP_INSTRUMENT=1` and live in
    `pumpCursorPosition`. After the refactor, the pump path
    changes shape; instrumentation needs to follow. The
    refactor preserves diagnostic value by emitting an
    analogous `pump_diagnostic` from the event-consumer code
    path, with `ps_x, ps_y` carrying the latest absolute
    coordinates from the event payload. Round 2's
    `composite_gate_diagnostic` continues to fire from
    `needsComposite` unchanged.

## Consequences

### Implementation work (new BACKLOG entries)

The implementation is substantial enough to warrant breakdown
into separate BACKLOG entries. AD-35 D3 produces these in a
follow-up commit; the entries will track:

  - **AD-36 (proposed)**: replace `pumpCursorPosition`'s
    state-region polling with `EventRingReader.drain`-based
    consumption. Includes the bootstrap path (initial drain
    from earliest seq), the overrun-recovery path (fall back
    to `read(2)` of state region for resynchronisation), and
    the integration with the existing damage-marking and
    visibility-detection code.
  - **AD-37 (proposed)**: make the main loop sleep on `/dev/draw`
    plus a timer rather than busy-spinning. Together with
    AD-36 this closes AD-32. The two are tightly coupled
    because the loop's wake source is the ring's notification
    on `/dev/draw`.
  - **AD-38 (proposed)**: refresh the AD-25 / AD-34 / AD-34-E1
    instrumentation to fire from the new code path. Same
    field schemas; new emit sites.

The exact set may shrink once a more careful implementation
sketch is in hand. AD-36 may absorb AD-37 or AD-38 depending
on coupling. The D3 commit settles this.

### Tracks that close as side effects

  - **AD-32**: closes when AD-37 lands.
  - **AD-25**: closes when AD-36 lands and the bench shows
    smooth cursor motion under the new path.

### Tracks that stay open

  - **AD-34**: stays open as a kernel-investigation track. The
    underlying FreeBSD-side mmap-visibility bug is real and
    worth fixing eventually; the workaround chosen here does
    not address it.

### Documentation updates

  - **AD-25 BACKLOG entry**: closes once the new path is on the
    bench. Update the entry to point at AD-36 for the
    implementation.
  - **AD-34 BACKLOG entry**: updates with the new finding (event
    ring works, state region doesn't), narrowing the open
    question to a kernel-side investigation.
  - **AD-35 BACKLOG entry**: closes when this ADR lands (the
    design decision is the deliverable).
  - **`docs/FREEBSD_ISSUES.md` Issue #1**: updated to record the
    event-ring-works finding, narrowing the localised cause
    description.

## Notes on the design process

This ADR's analysis was performed in a single session. The shape
of the analysis changed mid-way: the initial three-direction
comparison was reduced to a two-direction comparison plus an
explicit rejection of Direction 3 when the `_semadraw inputdump
events` probe returned data that invalidated the assumption
underlying Direction 3.

This pattern (a late-arriving observation reshaping the analysis)
mirrors what happened during AD-25 Rounds 1 and 2 and during
AD-34's findings stage. The discovery-driven approach used in
ADR 0007 (Round 1 → Round 2 redirect → AD-34 spinoff) keeps
producing this shape: each step rules out candidate explanations
and the residual question gets narrower until the answer is
visible. The team's response should keep being: pencil in the
analysis, run the cheap probe, accept what the data says,
redirect.

The decision recorded here is the right one given the data we
have. If a later probe further surprises us (e.g., the event ring
exhibits subtle staleness that did not appear in the bench), this
ADR can be amended or superseded. ADRs document decisions in
context, not eternal truths.
