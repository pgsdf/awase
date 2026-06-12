# 0007 AD-25 cursor motion smoothness discovery plan

## Status

Proposed 2026-05-12. Round 1 findings recorded as an addendum
on 2026-05-12; see the final section of this document. Round 2
is redirected from "render-phase breakdown" to "composite-gate
instrumentation" based on Round 1 findings. Round 2 findings
recorded as a second addendum on 2026-05-12; see the final
section. Round 2 ruled out the FrameScheduler as the gate and
surfaced a new question (mmap visibility from the cursor pump),
which is opened as a separate track under AD-34.

This is a **discovery-plan ADR**, not a fix-ADR. It commits to a
measurement strategy and success criteria for the next round of
investigation into AD-25 (cursor motion smoothness). It does not
commit to a specific implementation. Subsequent ADRs (0008, 0009,
...) will resolve specific decisions once data is in hand.

The shape follows audiofs ADR 0001 (Stage F.0 plan): structure
the unknowns before structuring a fix.

## Context

### Lineage

AD-25 surfaced during AD-21 sub-item 9 bare-metal verification on
2026-05-07. With the cursor region-damage fix in place, the
cursor follows the pointer correctly but motion is described as
"not smooth." AD-21 closed without addressing smoothness; AD-25
was opened as a separate track.

The original AD-25 entry hypothesised two causes:

  - Full-repaint fallback firing during cursor motion.
  - Per-pixel loops in `clearRegionImpl` being slow on EFI
    framebuffers.

Both hypotheses are tactical: optimise the existing path.
Estimate was Small-Medium.

### Instrumentation patch and bench data

Instrumentation landed 2026-05-10. The patch adds an
`ad25_diagnostic` unified-schema event emitted from
`semadraw/src/compositor/compositor.zig` per composite cycle,
gated on `UTF_COMPOSITOR_INSTRUMENT=1` in semadrawd's
environment. The event reports `clear_calls`, `clear_px`,
`clear_ns`, `full_entry`, `full_clearpath`, `surfaces_rendered`,
and `render_ns` per frame. Zero runtime cost when the env var is
unset (one `getenv` per cycle).

Bench data collected on `pgsd-bare-metal-test-machine` during
steady cursor motion. Findings:

  - `full_entry` and `full_clearpath` are false on every
    sampled frame. The compositor is not promoting to full
    repaint. **Original hypothesis (a) ruled out.**
  - `clearRegion` cost is small. The 2-call frames spend
    ~35,500 ns total for 1152 pixels (~30 ns/px). The 6-call
    frames spend ~120,000 ns for 3456 pixels (same per-pixel
    cost; the variation is in call count, not per-call cost).
    **Original hypothesis (b) ruled out as a smoothness
    cause.** A per-pixel optimisation is real future work
    but would not move the needle on perceived smoothness.
  - `render_ns` is the dominant per-frame cost. The render
    loop spends ~7,800,000 ns (~7.8 ms) per composite cycle
    rendering a single surface (a fullscreen
    `semadraw-term`). That is ~70x the `clearRegion` work.
  - Inter-frame gap is ~115 ms (~8.7 Hz). Consecutive
    `ad25_diagnostic` events' `ts_wall_ns` deltas land at
    ~114-115 million ns. At 8.7 Hz the cursor visibly steps
    rather than glides.

The original Small-Medium estimate was revised upward to
Medium-Large in BACKLOG 2026-05-10.

### Code inspection finding (added by this ADR)

Reading the daemon main loop in
`semadraw/src/daemon/semadrawd.zig` reveals an architectural
detail the instrumentation alone did not surface:

```
const n = posix.poll(poll_slice, 100) catch |err| {
    log.err("poll error: {}", .{err});
    continue;
};
```

The main loop's `poll(2)` timeout is **100 ms**. The loop runs
`pumpCursorPosition`, then `pumpCursorFocus`, then
`needsComposite` / `composite` per iteration. The loop wakes on:

  - Activity on any client socket (Unix or TCP).
  - Activity on the backend's pollable fd (drawfs `/dev/draw`,
    via `Compositor.getPollFd()`).
  - The 100 ms timeout expiring.

The cursor position is read via `pumpCursorPosition`, which
opens `/var/run/sema/input/state` via mmap (the inputfs
`StateReader`). **mmap state has no pollable fd**: there is no
kernel-side notification when the cursor moves. The daemon
must re-read the snapshot each loop iteration. On the idle
no-input path, the loop wakes only when the 100 ms timeout
expires.

The observed 115 ms cursor-motion cadence is consistent with:

  - 100 ms poll timeout, plus
  - ~15 ms execution overhead per iteration (the 7.8 ms
    composite work plus pump/scheduler/event handling).

The `FrameScheduler` is configured for **60 Hz** (16.7 ms
intervals) in `compositor.zig`. When `shouldComposite` is
asked, it correctly reports "yes, composite" but the daemon
asks only ~10 times per second on the cursor-only path. The
scheduler's discipline is irrelevant when the outer loop's
poll timeout is the rate floor.

This finding shifts the framing of open question 2 in the
BACKLOG entry. The scheduler is not holding off composite;
the daemon is not asking the scheduler often enough.

### Three unknowns remain

After the bench round and the code inspection above, three
measurements are still needed before any fix is designed:

  - **U1: Cursor pump cadence in isolation.** What rate does
    `pumpCursorPosition` actually fire at? The poll-timeout
    finding suggests ~10 Hz on the idle path, ~higher when
    other events wake the loop. Direct measurement would
    confirm. Crucial: does pump fire faster than composite
    (suggesting the bottleneck is downstream of pump), or do
    they fire at the same rate (suggesting both are paced by
    the same outer-loop floor)?
  - **U2: Render-phase breakdown.** Where in the 7.8 ms render
    do the ms go? Candidate phases (in
    `semadraw/src/compositor/`):
    - Surface-walk and damage intersection
    - SDCS interpretation per surface
    - Backend `render`/blit to framebuffer
    - Cursor sprite composite

    A per-phase timing inside the backend's render path would
    tell us whether the work is in the term's contribution
    (likely a full surface re-render per damage), in the
    compositor's surface walk, or in the backend blit itself.
  - **U3: Pump-to-composite latency under wake-on-event.**
    If we reduce or eliminate the 100 ms poll timeout, what
    does cadence look like? This is partly a "what happens if
    we change the variable" question, answerable with a
    controlled experiment (toggle the timeout via env var,
    measure cadence delta).

U1 partially has an answer from `clear_calls` cycling between
2, 4, and 6 (the BACKLOG entry notes this suggests pump faster
than composite), but a direct measurement is cleaner than
inference.

## Decision

This ADR commits to a **three-round discovery cycle** with
explicit instrumentation, bench-collection, and analysis
criteria for each round. The order resolves dependencies: U3
should not be tackled before U1 (without knowing pump cadence
we can't interpret a poll-timeout change), and U2 is
independent of both (the render-cost question stands regardless
of cadence).

The cycle proceeds:

### Round 1: pump cadence (resolves U1)

Add a `pump_diagnostic` unified-schema event emitted from
`pumpCursorPosition` per invocation, env-gated on
`UTF_PUMP_INSTRUMENT=1`. Fields:

  - `ts_wall_ns` (free from the unified schema header)
  - `pos_changed: bool` (the change-detection result)
  - `vis_changed: bool`
  - `state_valid: bool` (whether `pointerSnapshot()` returned
    non-null)

Each pump invocation emits one event regardless of whether the
position changed. Cost: one `getenv` per pump on the disabled
path, one event emission per pump on the enabled path. The
event volume is bounded by the poll-timeout floor (~10/sec on
idle, higher under input) so log impact is acceptable.

**Bench protocol**: enable `UTF_PUMP_INSTRUMENT=1`, start
semadraw-term --fullscreen, move the cursor continuously for
~10 seconds, exit, grep `pump_diagnostic` events.

**Success criteria**:

  - Pump cadence measured as the median delta between
    consecutive `ts_wall_ns` values.
  - Pump cadence compared against composite cadence (median
    delta between `ad25_diagnostic` events from the same run).
  - Ratio determined: pump rate ÷ composite rate.

**Decision criteria**:

  - If pump rate ≈ composite rate (both ~9 Hz), both are
    paced by the same outer-loop floor. Round 3 is high-value.
  - If pump rate > composite rate (e.g. pump 30+ Hz,
    composite 9 Hz), composite is the bottleneck. Round 2 is
    high-value, Round 3 less so.
  - If pump rate < expected (somehow pump itself is slow,
    e.g. 1 Hz), the diagnosis is misframed and we need to
    look at `StateReader`'s read path.

Estimated work: Small. Instrumentation only, mirrors the
existing `ad25_diagnostic` pattern.

### Round 2: render-phase breakdown (resolves U2)

Extend the compositor's render-time instrumentation to break
the existing `render_ns` total into phases. Candidate
sub-timings (to be refined when the code is read in detail):

  - `surface_walk_ns`: time spent in the composition-order
    walk and per-surface damage intersection.
  - `sdcs_interpret_ns`: total time across surfaces in SDCS
    command interpretation.
  - `backend_blit_ns`: time in the backend's writeRegion /
    framebuffer path.
  - `cursor_composite_ns`: time spent compositing the cursor
    sprite specifically (separating cursor work from
    application-surface work).

Sub-timings sum to approximately the existing `render_ns` (a
small accounted-elsewhere remainder is acceptable). Each phase
is gated on `UTF_RENDER_PHASE_INSTRUMENT=1` and emitted as
additional fields on the existing `ad25_diagnostic` event.

**Bench protocol**: same as round 1, with both env vars
enabled.

**Success criteria**:

  - The 7.8 ms total broken down into the four phases (or
    refined phase set after code inspection).
  - The phase carrying the largest share identified.

**Decision criteria**:

  - If `backend_blit_ns` dominates: the problem is in the
    backend's blit path. A future ADR addresses backend
    write efficiency.
  - If `sdcs_interpret_ns` dominates and the dominant
    contributor is the fullscreen `semadraw-term` surface:
    the problem is that the term re-renders its full surface
    on every cursor motion (because cursor damage propagates
    to the term as a damage event, and the term has no
    per-region damage path). A future ADR addresses term-side
    per-region damage.
  - If `surface_walk_ns` dominates: the compositor's walk
    itself is the bottleneck. Less likely given there is
    typically one application surface plus cursor.

Estimated work: Small-Medium. New instrumentation in the
compositor render path; some code-reading to identify clean
phase boundaries.

### Round 3: wake-on-event experiment (resolves U3)

Add an `UTF_POLL_TIMEOUT_MS` environment variable that, when
set, overrides the hardcoded `100` in `posix.poll`. Read once
at daemon startup; falls back to `100` if unset or invalid.

**Bench protocol**: three runs, each ~10 seconds of steady
cursor motion under semadraw-term --fullscreen:

  - Baseline: `UTF_POLL_TIMEOUT_MS=100` (current behaviour).
  - Tighter: `UTF_POLL_TIMEOUT_MS=16` (matching the
    scheduler's 60 Hz interval).
  - Tightest: `UTF_POLL_TIMEOUT_MS=5`.

Each run: grep `ad25_diagnostic` events, compute cadence
median and CPU usage (`top` or `ps` snapshot during the run).

**Success criteria**:

  - Cadence numbers for each timeout setting.
  - CPU-time-while-idle measurement for each setting (how
    much CPU the daemon burns when no cursor motion is
    happening, with the tighter timeout).

**Decision criteria**:

  - If 16 ms timeout produces ~60 Hz cadence and idle CPU is
    acceptable: the fix is to tighten the timeout (with an
    appropriate value committed to). A future ADR settles
    the exact value and any deadline-driven sleep refinement.
  - If 16 ms produces 60 Hz cadence but idle CPU is
    unacceptable: the fix is event-driven, not timeout-driven.
    Options: inputfs publishes a pointer-changed eventfd; or
    `FrameScheduler.waitForDeadline()` is hooked into the
    main loop's timeout calculation. A future ADR chooses.
  - If tightening produces sub-60-Hz cadence anyway: round 2
    findings dominate, the timeout is not the floor, and
    composite cost is the bottleneck. The round-3 experiment
    is informative but the fix lives in round 2's findings.

Estimated work: Small. Env-var read + bench runs + analysis.

### What this ADR commits to

The three rounds above, in order. Each round produces a
bench-data artefact (event log excerpts in the session memo or
a dedicated `docs/perf/` document) and a decision call
recorded in BACKLOG.

If a round's decision criteria do not cleanly select one
direction (e.g. round 1 shows pump rate slightly higher than
composite but not dramatically), the next round still proceeds
on its own merits; the decision is escalated to a follow-up
ADR. No round is gated on a clean-cut answer from the prior
round.

The eventual fix ADR(s), of which there may be one, may be
several depending on findings, will be numbered 0008 onward and
will reference this ADR for the data they rest on.

## Consequences

### What this enables

  - Bounded discovery: three concrete rounds, each Small or
    Small-Medium, totalling perhaps one to two days of work
    across several sessions.
  - Honest scoping: subsequent fix ADRs rest on data, not
    hypothesis.
  - Reuse: each instrumentation patch is env-gated and stays
    in the tree (mirroring the existing
    `UTF_COMPOSITOR_INSTRUMENT` pattern). Future regressions
    in cursor motion or render performance can use the same
    diagnostic hooks without re-instrumenting.

### What this does not address

  - The fix itself. By design.
  - Cursor motion smoothness on alternative backends (X11,
    Wayland, headless). The bench platform is drawfs on
    bare-metal FreeBSD. Other backends may have different
    cadence characteristics (X11 has its own cursor sprite
    path) and are out of scope for this discovery cycle.
  - The broader question of compositor cadence and
    event-driven scheduling for non-cursor periodic work
    (clipboard polling, focus pump, future SM tooling
    integration). The 100 ms poll-timeout finding has
    broader implications worth a separate track. AD-25 is
    narrowly scoped to cursor motion smoothness.
  - Audio-clock-driven scheduling. The `ChronofsClockSource`
    in `frame_scheduler.zig` is mentioned in code comments
    as a future replacement for the wall clock; AD-25
    discovery uses the wall clock as-deployed.

### Estimated cost

  - Round 1 (pump cadence): Small. 1-2 hours of
    instrumentation + bench cycle + analysis.
  - Round 2 (render-phase breakdown): Small-Medium. 2-4
    hours, mostly because clean phase boundaries in the
    backend's render path may require some code reading.
  - Round 3 (poll-timeout experiment): Small. 1 hour for
    the env-var addition + bench runs.

Total discovery cost: 4-7 hours of focused work, plausibly
spread across two or three sessions to allow for bench
turnaround and reflection between rounds.

Subsequent fix ADRs are out of scope of this estimate.

### Failure modes worth naming

  - **Premature commitment.** A round's data may suggest a
    fix direction so strongly that there is pressure to skip
    the remaining rounds. Resist: U1, U2, U3 are independent
    questions; skipping U2 because U1 looks decisive risks
    landing a fix for cadence that leaves a 7.8 ms render
    cost unresolved.
  - **Instrumentation cost.** Each round adds a small env-var
    branch. Three branches is not a lot, but `getenv` calls
    on hot paths warrant care. The existing
    `UTF_COMPOSITOR_INSTRUMENT` pattern caches the lookup
    inside a `blk:` block; the new instrumentation follows
    the same pattern.
  - **Bench-machine specificity.** All three rounds run on
    `pgsd-bare-metal-test-machine` (drawfs, EFI fb,
    3840×2160). Findings may not transfer to other UTF
    deployments. A future ADR (out of scope here) would
    consider whether cursor smoothness needs platform-
    specific tuning.
  - **The "what about feature X" trap.** While reading
    render-path code in round 2, scope drift toward
    rendering-engine improvements is tempting. AD-25 is
    about smoothness, not throughput. Findings that suggest
    rendering improvements should be recorded in BACKLOG as
    separate entries, not folded into AD-25 fix work.

## Related work

  - **AD-21** (mouse cursor sprite rendering, closed
    2026-05-07): introduced the region-damage path that
    surfaces this issue. AD-25 inherits AD-21's pump and
    damage model.
  - **AD-24** (cursor reset on focus loss, closed 2026-05-10):
    the most recent cursor-track work. Same general code
    path; no smoothness implications.
  - **AD-26** (semadraw-term fullscreen, closed 2026-05-10):
    the test vehicle for AD-25's bench cycle. The fullscreen
    surface is what makes the render cost visible.
  - **audiofs ADR 0001** (Stage F.0 plan, accepted 2026-05-11):
    structural precedent for plan-style ADRs that enumerate
    open questions and commit to resolution order rather than
    to a specific decision.
  - **ADR 0005** (cursor surface design): the design that
    AD-21 implemented and that AD-25 builds on. No changes
    expected as a result of this discovery cycle.
  - The existing `UTF_COMPOSITOR_INSTRUMENT` instrumentation
    in `semadraw/src/compositor/compositor.zig` and
    `semadraw/src/daemon/events.zig` (`emitAd25Diagnostic`):
    the pattern this ADR's new instrumentation follows.

## What this ADR is not

  - **Not a fix.** No code in the compositor, daemon, term,
    or backend changes structure as a result of this ADR.
    Three small env-var-gated instrumentation patches land
    over the discovery cycle; that is all.
  - **Not a commitment to specific implementation directions.**
    The decision criteria above identify *which class* of
    fix each round's data points to, not which fix.
  - **Not scope for broader cadence work.** The 100 ms
    poll-timeout finding has implications beyond cursor
    motion (clipboard, focus, any future periodic work). The
    discovery cycle treats this as relevant context but does
    not propose a system-wide cadence revision. If a future
    track surfaces cadence as a cross-cutting concern, it
    gets its own ADR.
  - **Not term-side work.** If round 2 implicates term-side
    full-surface re-renders, the fix lives in
    `semadraw/src/apps/term/` and likely warrants its own
    ADR sequence. This ADR provides the diagnostic data;
    the design decision belongs in a separate document.
  - **Not a replacement for the BACKLOG AD-25 entry.** The
    BACKLOG entry remains the operational tracker; this ADR
    is the long-term record of the discovery framing. The
    BACKLOG entry will reference this ADR once it lands.

## Round 1 findings (added 2026-05-12)

Round 1 instrumentation landed and was bench-collected on
`pgsd-bare-metal-test-machine`. The findings invalidate this
ADR's original framing of Round 1's question and redirect
Round 2.

### What the bench data showed

Across a roughly 10-second bench run with `semadraw-term
--fullscreen` and continuous cursor motion, the captured log
window (limited by s6-log retention) showed 9,998
`pump_diagnostic` events spanning 148 ms of wall time:

  - **Pump rate: ~67,500 events/second** (average 14.8 us per
    pump; minimum delta between consecutive events ~4 us).
  - **Position-change events in the captured window: 1 out of
    9,998.** The pump fires at this rate regardless of whether
    the cursor is moving; nearly every invocation sees
    `pos_changed:false`.
  - **`ad25_diagnostic` events in the captured window: 0.** The
    composite instrumentation env var was not set during this
    bench, so no comparison data was collected. Composite
    cadence is therefore not directly measured here, but the
    8.7 Hz figure from the original 2026-05-10 bench stands as
    the reference point.

### Why the original prediction was wrong

The ADR's Context section identified the main loop's
`posix.poll(poll_slice, 100)` timeout as the cadence floor.
That reading missed a critical detail: the drawfs backend's
`/dev/draw` is in the polled fd set, and during normal
operation the kernel reports `/dev/draw` as readable
continuously (inputfs delivers events through the drawfs event
ring, and any pending event keeps the fd in the readable
state). `poll(2)` returns immediately when any fd is ready, so
the 100 ms timeout never bites during input activity.

The poll-timeout reasoning was technically true for the
**idle** case (no input fds readable, no client sockets
active). It is not true for the **cursor-motion** case. The
daemon is never idle while a client is connected and inputfs
is feeding events.

### Implications for Round 2 and Round 3

  - **Round 2's framing changes.** Rather than instrumenting
    render-phase breakdown (the original plan, which targeted
    the 7.8 ms render cost question), Round 2 now targets the
    **composite gating** question: of the ~67,500 main-loop
    iterations per second, only ~9 result in a composite. Why
    do the other 7,400-or-so iterations have
    `needsComposite() == false`? Two candidate gates per
    `compositor.zig`:
      - `damage_tracker.hasDamage()`: if false most
        iterations, then damage marking is failing to
        propagate (or being consumed faster than expected).
      - `scheduler.shouldComposite()`: if false most
        iterations, then the FrameScheduler is gating
        composite at a rate well below its configured 60 Hz
        target.

    Round 2's instrumentation extends the existing
    `ad25_diagnostic` (or adds a sibling event) to record
    which gate(s) returned what value on each composite-check
    iteration. The render-phase breakdown is not abandoned;
    it is deferred to a later round if composite gating turns
    out not to be the dominant smoothness cause.

  - **Round 3's value is reduced.** The poll-timeout
    experiment was framed as "what happens if we tighten the
    cadence floor?" Round 1's data shows the floor is not the
    limiter during cursor motion. Round 3 is therefore not
    the highest-value next step. It may still be informative
    for **idle** behaviour (when no input fds are active and
    the loop does reach the timeout), and remains on the
    plan, but it is downgraded relative to Round 2.

  - **A new finding warrants its own track.** The 67 kHz
    busy-spin is not the cursor-smoothness cause, but it is
    a real concern in its own right: CPU usage, power
    consumption on the sparrow laptop, and cache-line
    behaviour from the per-iteration mmap reads of the
    inputfs state region. This concern is broader than AD-25
    and has been opened as a separate track. See BACKLOG
    AD-32.

### Status of Round 1

  - Instrumentation: landed in commit `6d670b9`. Lives in
    `pumpCursorPosition` behind the `UTF_PUMP_INSTRUMENT` env
    var. Retained in the tree for future regression checks.
  - Bench-collection: complete (single run, 2026-05-12).
  - Findings recorded: this addendum.
  - Decision call: redirect Round 2 to composite gating per
    the discussion above. Reframe Round 3 as informative for
    idle behaviour, not cursor motion.

### Honest limitations of the Round 1 bench

  - **Log retention truncation.** The s6-log default
    (`s1000000 n3` = 1 MB current, 3 archived) holds ~14,000
    pump events at the observed rate, which is ~210 ms of
    wall time. The bench ran for ~10 seconds, so >97% of the
    pump data was rotated off and lost. The 9,998 events we
    have are a sample, not the full record. A separate commit
    (the s6-log retention bump) addresses this for future
    rounds.
  - **No composite cadence data.** `UTF_COMPOSITOR_INSTRUMENT`
    was not enabled during this bench, so the comparison
    against composite rate relies on the 8.7 Hz figure from
    the prior bench (2026-05-10). A future Round 2 bench
    should enable both env vars concurrently.
  - **One bench run.** The findings are based on a single
    bench on a single machine. The pump rate of 67 kHz is
    bench-specific (it depends on what the loop is doing per
    iteration and what the bench's CPU can sustain); other
    machines may differ. The qualitative finding (loop is not
    idle-paced; composite gating is the smoothness bottleneck)
    is structural and likely transfers.

## Round 2 findings (added 2026-05-12)

Round 2 instrumentation landed (commit `b345984`) and was
bench-collected on `pgsd-bare-metal-test-machine`. The findings
isolate the gating mechanism with high confidence and surface a
new question that does not resolve inside this ADR's scope.

### What the bench data showed

Bench cycle: install.sh fresh; semadrawd running with both
`UTF_PUMP_INSTRUMENT=1` and `UTF_COMPOSITE_GATE_INSTRUMENT=1`
in the environment (verified via `procstat -e`); single
`semadraw-term --fullscreen` client with continuous cursor
motion for ~10 seconds; clean Ctrl+D exit. Log collection
across `current` plus rotated `@*.s` files under
`/var/log/utf/semadrawd/`.

Captured window: 73.6 ms (limited by s6-log rotation even at
the 10 MB-per-file retention bumped in commit `b062f3f`).

Composite-gate distribution (9,998 calls):

  - `has_damage:true,  should_composite:true`:  **1** (0.01%)
  - `has_damage:true,  should_composite:false`: 0
  - `has_damage:false, should_composite:true`:  7,291 (72.9%)
  - `has_damage:false, should_composite:false`: 2,706 (27.1%)
  - `state_valid:false`: 0

Pump cadence from the same bench session (9,998
pump_diagnostic events):

  - `pos_changed:true`: **1** (0.01%)
  - `pos_changed:false`: 9,997 (99.99%)
  - `state_valid:false`: 0

### Interpretation

**The 1-to-1 correspondence between pump_diagnostic
pos_changed:true (1 event) and composite_gate_diagnostic
has_damage:true (1 event) confirms the pump-to-composite path
is wired correctly.** When the pump sees a position change, it
marks damage; on the next `needsComposite` call, has_damage
returns true. No bug in damage marking, propagation, or
consumption.

**The FrameScheduler is not the gate.** `should_composite`
returns true on 72.9% of calls, well above any rate the
8.7 Hz observed composite cadence could imply. The scheduler
is willing to fire ~73% of the time; composite doesn't run
because there is no damage to consume.

**The 27.1% (has_damage:false, should_composite:false)
fraction** represents the ~3-4 ms intervals between scheduler
deadlines. Cumulatively consistent with a 60 Hz frame interval
across a 73.6 ms window. Not concerning.

### The new question

The pump observed `pos_changed:true` exactly once in 9,998
reads spanning 73.6 ms (extrapolated ~14 Hz rate). But
independent observation of inputfs's state region via
`inputdump state --watch --interval-ms 50` shows the
`last_seq` field advancing at ~6-7 ticks per 50 ms window
(~130 Hz) during the same bench conditions. And
`inputdump events --stats` reports ≥204 events/sec on the
event ring.

**The pump and inputdump are both consumers of the same
mmap'd state file** (`/var/run/sema/input/state`), opened
through the same `StateReader` code path in
`shared/src/input.zig`. Yet they observe radically different
update rates: inputdump sees the pointer position changing
across snapshots, the pump (operating at ~67 kHz and
sampling far more often than inputdump's 50 ms polls) does
not.

Candidate explanations enumerated, in approximate order of
likelihood:

  - **Mmap page visibility.** The kernel writes the state
    file via `vn_rdwr(UIO_WRITE, ..., IO_SYNC)` against a
    tmpfs vnode. The userspace mmap of that file is
    `MAP_SHARED, PROT_READ`. In theory the VM object backing
    the file is shared and writes are visible immediately
    to readers; in practice some pathway in the kernel may
    be presenting cached pages that don't reflect recent
    writes for some pump-side read patterns. inputdump's
    less-frequent reads may dodge whatever effect this is.
  - **Read-then-compare against stale-cached-value.** The
    pump caches `last_cursor_pos_x`/`_y` as f32. After the
    first read with `pos_changed:true`, the pump updates
    these and returns; subsequent reads compare against the
    new value. If subsequent reads happen to return the same
    integer pixel value as the first (because the underlying
    state happens to be at the same value at that moment),
    `pos_changed` correctly reports false. This would
    require the state to be at the same value across 9,997
    consecutive reads, which contradicts the inputdump
    observation. Unlikely but mentioned for completeness.
  - **A race with the kernel writer.** The pump's seqlock
    spin discards reads where v1 != v2 (writer was active).
    At the pump's 67 kHz rate and the writer's ~200 Hz rate,
    overlap probability is ~0.3%. That is not enough to
    explain 99.99% of pump_diagnostic events seeing the same
    value. Also unlikely.
  - **Some other effect not yet considered.** The next
    diagnostic round would resolve this by adding raw
    `ps.x, ps.y` values to the `pump_diagnostic` event
    payload, so the analysis can see the actual values the
    pump is reading (not just whether they changed).

### Implications for Round 3

Round 3 (poll-timeout experiment) was downgraded in the
Round 1 addendum and remains downgraded after Round 2. It
does not investigate the new question; the new question is
about what the pump *sees* in the mmap, not about the loop's
pacing.

### A new track is opened

This investigation does not fit cleanly into a "Round 4 of
AD-25" framing. The question has narrow scope (one specific
mmap-visibility mystery), uncertain cause (multiple candidate
explanations, requires more instrumentation to disambiguate),
and unclear connection to cursor motion smoothness (it may
be the dominant cause; it may not). A dedicated BACKLOG entry
opens for it; see **AD-34**.

### Status of Round 2

  - Instrumentation: landed in commit `b345984`. Lives in
    `Compositor.needsComposite()` behind the
    `UTF_COMPOSITE_GATE_INSTRUMENT` env var. Retained in the
    tree for future regression checks.
  - Bench-collection: complete (single run, 2026-05-12).
  - Findings recorded: this addendum.
  - Decision call: open AD-34 for the mmap-visibility
    question; revisit AD-25's plan once AD-34's data is in
    hand.

### Where AD-25 stands

The "cursor motion smoothness" complaint that opened AD-25
remains the user-visible symptom. The investigation has now
ruled out:

  - Per-frame `clearRegion` cost (ruled out 2026-05-10).
  - Full-repaint promotion (ruled out 2026-05-10).
  - Main loop poll-timeout pacing (ruled out by Round 1,
    surfacing AD-32 instead).
  - FrameScheduler gating composite (ruled out by Round 2).
  - Damage marking failing to propagate (ruled out by
    Round 2 via the 1:1 pump-to-damage correspondence).

What remains: the gap between inputfs's reported
publication rate (≥130-200 Hz) and the pump's observed
pos_changed rate (~14 Hz extrapolated). AD-34 owns this
question. AD-25 stays open as the umbrella tracker; it
closes when cursor motion smoothness is fixed on the bench,
which depends on whatever AD-34 reveals (plus any
follow-up).
