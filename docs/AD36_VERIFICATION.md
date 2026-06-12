# AD-36 Cursor pump source verification

Status: Stated, 2026-05-24.

This document records the verification work done on 2026-05-24 for
AD-36 (pumpCursorPosition reads from `Daemon.last_motion_x/y`
populated by an inputfs event-ring harvest in the main loop). The
goal was to demonstrate that `pump_diagnostic` events show
`state_valid=true` with non-stale `ps_x`, `ps_y` under cursor
motion, the closure criterion specified by AD-36's BACKLOG entry.

The verification did not demonstrate the criterion. The bench-side
diagnostic work converged on a separate finding upstream of AD-36's
code path that prevents AD-36 from being exercised in the current
runtime configuration. This document records:

- What was verified (AD-36's implementation correctness by reading)
- What was not (end-to-end demonstration on a bench)
- Why the bench could not demonstrate it (the upstream finding)
- What the upstream finding implies for next corrective actions

The upstream finding is filed in BACKLOG as a separate item; see
"Next corrective actions" below.

## 1. AD-36's implementation, reviewed by reading

The AD-36 code path is correct as designed. The relevant sites:

- **Harvest**: `semadraw/src/daemon/semadrawd.zig:1117-1140`. Each
  main-loop iteration calls `self.comp.getInputfsEvents()` and
  iterates the returned slice. For each event matching
  `source_role == input.SOURCE_POINTER and event_type ==
  input.POINTER_MOTION`, the payload's `x` and `y` (i32 LE at
  offsets 0 and 4) are read into `self.last_motion_x` and
  `self.last_motion_y`, and `self.last_motion_seen` is set to
  `true`. The constants `SOURCE_POINTER` and `POINTER_MOTION` are
  both `1` (see `shared/src/input.zig:649` and `:669`).

- **Consume**: `semadraw/src/daemon/semadrawd.zig:683-700`.
  `pumpCursorPosition` returns early via
  `self.cursor_surface_id orelse return` at line 684 if no cursor
  surface is registered. With a cursor surface present, it then
  emits a `pump_diagnostic` with `state_valid=false` on the
  `!self.last_motion_seen` branch (line 695), or proceeds into
  the position-update path with `state_valid=true` once
  `last_motion_seen` is true.

- **Backend wiring**: `semadraw/src/backend/drawfs.zig:1295-1333`'s
  `pollEventsImpl` calls `ifs.drain` which appends to
  `injected_inputfs_events`. `getInputfsEventsImpl` at
  `:1378-1386` returns and resets the buffer. Both functions are
  straightforward and have no conditional that would silently
  drop pointer events.

- **Drain mechanics**: `semadraw/src/backend/inputfs_input.zig:138-174`
  copies events into the side-channel before dispatch (line
  166-169), avoiding the issue that touch/pen events would be
  dropped by the typed-event dispatch's `else => return` arm.
  The drain itself is `shared/src/input.zig:875-921`, which
  reads the kernel-published `writer_seq` and `earliest_seq`,
  fast-forwards `last_consumed` on overrun, and copies slots
  into the output buffer with a torn-write check.

Every line in the harvest path is consistent with AD-36's design
as described in `BACKLOG.md` and `docs/AD25_VERIFICATION.md`. The
event constants match what `inputdump` uses to decode the same
ring, so a type-filter mismatch is ruled out at the source level.

## 2. Bench demonstration attempt

The bench machine `pgsd-bare-metal` was used. Three tools were
employed in sequence:

- **`scripts/ad36-bench.sh`** (added in commit `be61c0b`). Runs
  `inputdump events --watch --role pointer` for 10 seconds
  during which the operator moves the mouse, then compares
  inputfs ring activity against semadrawd's log output.
- **`scripts/ad36-harvest-diag.sh`** (added in commit
  `202ca7c`). Scans all `/var/log/utf/semadrawd/` files
  (`current` plus archives) and counts daemon-state markers,
  attach evidence, harvest activity, and pump output across
  the full daemon history.
- **A direct-stdout capture experiment**: stop the s6-supervised
  semadrawd, run a fresh semadrawd manually with stdout
  redirected to a file, capture for 15 seconds, kill, restart
  under s6.

### 2.1 ad36-bench.sh result (2026-05-24)

Output saved at `/tmp/ad36-bench-20260524-164755/`. Key counters:

| Marker | Value |
|---|---|
| `inputdump` pointer.motion events in the 10-second window | 1,993 |
| semadrawd new log lines in the window | 0 |
| semadrawd new `pump_diagnostic` events | 0 |
| semadrawd new `state_valid:true` events | 0 |
| semadrawd uptime (at start of window) | 4,440 s |

Diagnosis from the script: "BUG IN SEMADRAWD HARVEST". The ring
clearly had motion events (`inputdump` captured 1,993 of them);
semadrawd's harvest produced none. This script's diagnosis
pointed at `inputfs_input.zig` / `drawfs.zig` files. That pointer
turned out to be incorrect for reasons elaborated in 2.4.

### 2.2 ad36-harvest-diag.sh result (2026-05-24)

Output saved at `/tmp/ad36-harvest-diag-20260524-175920/`. Key
counters across all four log files (3 archives + current,
spanning 339,992 s of recorded history):

| Marker | Value |
|---|---|
| Daemon startup banners | 2,587 |
| `/dev/draw` open successes | 9 |
| Cursor surface created | 9 |
| Cursor surface init failures | 0 |
| Privilege drops | 9 |
| inputfs ring opened | 9 |
| inputfs ring unavailable (init-time race) | 8 |
| **inputfs ring overrun warnings** | **0** |
| `gesture_recognizer.handleEvent` failures | 0 |
| `pump_diagnostic` total | 81,744 |
| `pump_diagnostic` with `state_valid:true` | 0 |
| `pump_diagnostic` with `state_valid:false` | 81,744 |

The script's diagnosis branch has a shell variable-scoping bug
and printed the wrong final verdict; the per-marker counts are
correct. Reading the counts directly: cursor surface attached
in every session, inputfs ring latched in every session, no
ring overrun warnings in 339,992 s of operation, no
`state_valid:true` events ever.

The zero ring-overrun count was the first hard signal that
something architectural was wrong: with `inputdump` seeing motion
arriving at the ring, and a 1,024-slot ring, the writer should
have lapped the reader within seconds of starting cursor motion
unless the reader was keeping up - which it cannot be, since
the harvest never produces a state_valid event.

### 2.3 Direct-stdout capture experiment (2026-05-24)

To rule out s6-log as a lossy element, semadrawd was started
manually with stdout redirected to `/tmp/semadrawd-direct.log`
for 15 seconds with the operator moving the mouse. Results:

- 10,018 total lines captured
- 9,983 `pump_diagnostic` events
- 0 with `state_valid:true`
- seq values: 1 through 9,999 (sequence counter advancing
  normally)
- `ts_wall_ns` range: `1779613793063869165` (seq=1) through
  `1779613793386173004` (seq=9999), a window of **322 ms**.

The daemon emitted 9,999 events in the first 322 ms of life and
then went silent for the remaining 14.7 s. With one
`pump_diagnostic` emitted per main-loop iteration (the no-data
branch at semadrawd.zig:697), this means the main loop ran ~31,000
iterations in 322 ms then stopped iterating for the rest of the
window. CPU usage on the long-running supervised daemon over the
preceding hours was ~50-75% of one core sustained, consistent
with periodic bursts of similar shape between long quiet periods.

### 2.4 Synthesis

The harvest at semadrawd.zig:1135-1140 is called on every main
loop iteration. The main loop iterates many thousands of times in
brief bursts at startup, then sits in `posix.poll` essentially
indefinitely. Cursor motion arrives at the inputfs event ring
*after* the burst has ended. The 100 ms poll timeout would in
principle give the harvest 10 chances per second to drain the
ring, but the long-term observed pump rate is 81,744 events
/ 339,992 s = 0.24 events/s. The 100 ms timeout is not
firing at the documented rate.

The reason is structural: semadrawd's `posix.poll` set
(semadrawd.zig:1011-1067) includes the Unix socket server, TCP
server, per-client sockets, and the backend's pollable fd. The
backend's pollable fd, for the drawfs backend, is `/dev/draw`
(see `drawfs.zig:1397-1401`). **The inputfs events ring fd is not
in the poll set.**

The original design (per the comment at
`semadrawd.zig:1052-1059`) anticipated `/dev/draw` as the wake
source for input events, because the now-retired `semainputd`
injected input frames via `/dev/draw`. After `semainputd` was
retired (AD-2a, 2026-05-08) and input moved to the inputfs ring,
`/dev/draw` was no longer the input wake source, but the
poll-set wiring was not updated. The comment at
`semadrawd.zig:1052-1059` is stale and should be corrected once
the underlying issue is resolved.

The reason the 100 ms timeout *also* fails to fire often enough
is not yet established. Possible causes: a signal-mask issue
with `ppoll`'s semantics on FreeBSD, `posix.poll` returning
early without consuming the timeout when a client fd is
readable, or the timeout being reset by handler activity that
takes long enough to fall just under the threshold. This is left
open and discussed in section 5.

## 3. Other findings surfaced during the verification

These are not AD-36 findings but were noticed while
investigating AD-36 and should be tracked separately.

### 3.1 ad36-harvest-diag.sh diagnosis bug

The shell script (`scripts/ad36-harvest-diag.sh`) has a
variable-propagation bug between `count_marker` and the
diagnosis block. The counts themselves are correct (and were
used for the values in 2.2 above), but the per-marker totals
are not reaching the diagnosis variables, so the script
always prints the first branch's verdict regardless of input.
The smoke test in `/tmp/smoke2/` passed because the values
were small; the bench-scale logs surface the bug. Worth fixing
in a follow-up for future runs.

### 3.2 1920x1080 vs. 3840x2160 display detection in direct capture

The direct-stdout capture experiment in 2.3 used the command
line `-r 3840x2160`, and `sysctl hw.drawfs.efifb.width` returns
3840, but the daemon initialized the compositor at 1920x1080:
`info(drawfs_backend): display 1: 1920x1080@60000mHz`. The
`-r` flag is either not being parsed or being overridden by the
backend's detected display size. This affects rendering area
but not AD-36's correctness.

### 3.3 Connection to AD-32 / AD-37 (busy-spin)

The 31 kHz burst at startup observed in 2.3 is consistent with
the AD-32 / AD-37 busy-spin pattern. /dev/draw signaling readable
continuously at startup would cause `posix.poll` to return
immediately on every loop iteration until the underlying queue
empties; the burst rate is bounded by the loop body's compute
cost, not by the poll timeout. The current AD-32 / AD-37 items
should be re-read in light of this observation: the busy-spin is
a *startup* event followed by a *long quiet*, not a sustained
high-rate condition.

### 3.4 semaaud crash-on-startup regression

Tangential to AD-36 but observed during the bench setup:
`semaaud` crashes on startup because it reads `/dev/sndstat`
in `semaaud/src/device_detect.zig:5`, which was removed by AD-3
Option A (snd(4) framework removal). semaaud was disabled via
`sudo sysrc semaaud_enable=NO` and `sudo s6-svc -d
/var/service/utf/semaaud` so the rest of the system could be
exercised. The proper fix is the semasound replacement work
already tracked under AD-3 follow-on, but a BACKLOG item
calling out the immediate crash regression should be filed.

### 3.5 install.sh does not kldload drawfs on refresh

Also observed during bench setup. `install.sh` builds and
deploys `drawfs.ko` to `/boot/modules/` and lists `kldload
drawfs` in its post-install "To start now without rebooting"
operator instructions, but does not run it itself. On
incremental redeploy this leaves the previously-running daemon
unable to open `/dev/draw`. Parallel to how `install.sh`
already runs `service inputfs start` after deploying
`inputfs.ko`, the drawfs deploy should similarly `kldload
drawfs` (or `kldunload + kldload` if loaded) in the
restart-services epilogue. Worth a small follow-up patch.

## 4. What was not verified

- **End-to-end AD-36 correctness on a bench.** Cannot be
  demonstrated until the main-loop wake gap (see "Next
  corrective actions") is resolved. The implementation is
  correct as designed, but the closure criterion in BACKLOG
  remains unmet by direct demonstration.
- **The exact failure mode of the 100 ms poll timeout.** It is
  not firing at the documented rate, but the diagnostic work
  to date has only established that it is not firing, not why.
- **Whether inputfs publishes a pollable signal at all.** The
  kernel-side `inputfs.c` may or may not implement `d_poll` (or
  `d_kqfilter`) for the events region. This needs to be checked
  before designing the wake-source addition; if inputfs has no
  pollable surface, a different mechanism (kqueue with a kernel
  event source, or a separate eventfd-style file descriptor) is
  needed.

## 5. Next corrective actions

The following are candidate next actions in rough priority
order, with rationale. No code changes are committed by this
document; the intent here is to enumerate options so a
sequencing decision can be made before implementation.

### 5.1 File a new BACKLOG item: main-loop input wake source

The substantive finding from this verification: semadrawd's
`posix.poll` set wakes on /dev/draw, but inputfs events arrive
on a separate fd that the daemon does not poll. The 100 ms
fallback timeout is not firing at the documented rate either,
so input latency degenerates from "near zero" (the design goal
per the comment at semadrawd.zig:1052-1059) to "indefinite".

This item should describe the gap, name the affected files and
line numbers, and reference this verification document for
evidence. It does not need to prescribe a fix; the fix design
depends on what inputfs's kernel-side surface supports.

### 5.2 Investigate inputfs kernel-side pollable surface

Before designing the wake source addition, confirm whether
`inputfs.c` implements `d_poll` (or `d_kqfilter`) on the events
device. Three possibilities and what each implies:

- **inputfs implements `d_poll`**: simplest fix. semadrawd
  retrieves the inputfs events fd (currently only used via mmap),
  adds it to the poll set, and pollEvents drains the ring when
  the fd signals readable. Roughly a 20-line change in
  semadraw/src/backend/drawfs.zig and semadraw/src/backend/
  inputfs_input.zig, plus the poll-set addition at
  semadrawd.zig:1060.

- **inputfs implements `d_kqfilter` but not `d_poll`**: less
  uniform but workable. semadrawd would need a small kqueue
  setup. FreeBSD's kqueue is the more idiomatic mechanism here
  and the existing semadrawd loop could plausibly be migrated to
  kevent entirely; that is a larger structural change but a more
  modern one.

- **inputfs implements neither**: requires kernel-side work
  before semadrawd-side work is possible. Either add `d_poll`
  to inputfs (small kernel-side change with established
  pattern), or design a sideband notification mechanism
  (e.g., an eventfd-style fd that inputfs signals on each ring
  write).

The investigation is a code-read, not a bench experiment. One or
two hours.

### 5.3 Fix the 100 ms poll timeout independently

Even with the wake source added, the 100 ms fallback should be
reliable for diagnostic and edge-case wakes. The failure mode is
not yet diagnosed. Candidate causes to inspect:

- The poll timeout argument is in milliseconds (`posix.poll`'s
  third argument is documented in milliseconds on FreeBSD;
  verify the call site at semadrawd.zig:1075 passes 100, not
  100 * 1000 or 100 / 1000).
- The compositor's `needsComposite()` and `composite()` calls
  in the loop body (semadrawd.zig:1236-1240) may consume more
  than 100 ms per call, making "ten wakes per second" arithmetic
  not match reality. Worth measuring.
- The poll-fd list rebuild (semadrawd.zig:1013-1067) allocates
  on every iteration; if that takes appreciable time, the
  effective loop rate is loop-body-cost-bounded, not
  timeout-bounded.

These are diagnostic questions answerable by adding a single
log line at the top of each loop iteration with a timestamp,
running for a known interval, and comparing the count against
expected. Tractable bench experiment.

### 5.4 Update the stale comment at semadrawd.zig:1052-1059

Once 5.1 has a filed item, the stale comment about semainputd
injecting events into /dev/draw should be corrected to reflect
the actual current architecture (inputfs ring is the input
source; the comment should describe what /dev/draw is *now*
used for, if anything, in the poll set). Small cleanup, can land
with the wake-source fix.

### 5.5 Fix the ad36-harvest-diag.sh diagnosis bug

The script's per-marker counts are correct but the final
diagnosis branch reads zeros. The bug is in how the totals
are propagated from `count_marker` to the diagnosis variables.
A subsequent run of the script after 5.1 closes will be useful
for confirming the fix worked, so the script should be in good
shape by then.

### 5.6 Close AD-36 with a non-Done resolution

AD-36's BACKLOG closure criterion is "pump_diagnostic events
show state_valid=true with non-stale ps_x, ps_y under cursor
motion". This document does not demonstrate that criterion. The
honest dispositions are:

- **Mark AD-36 implementation correct, defer closure pending the
  new item from 5.1.** AD-36's code is right; demonstration is
  blocked on a separate issue. AD-25 (which depends on AD-36)
  is similarly deferred.
- **Re-run ad36-bench.sh after 5.1 lands** and update this
  document with the new result. If `state_valid:true` events
  appear, close AD-36 then.

The first is the immediate action; the second is the follow-up
once 5.1 has been resolved.

## 6. Evidence

The captured bench-run outputs supporting this verification:

- `ad36-bench.sh` run, 2026-05-24 16:47 JST:
  `/tmp/ad36-bench-20260524-164755/REPORT.txt` (and adjacent
  files in the same directory).
- `ad36-harvest-diag.sh` run, 2026-05-24 17:59 JST:
  `/tmp/ad36-harvest-diag-20260524-175920/REPORT.txt`.
- Direct-stdout capture, 2026-05-24 ~17:30 JST:
  `/tmp/semadrawd-direct.log` (10,018 lines, 9,999 events with
  unique seq values).
- Log archive set at the time of investigation:
  `/var/log/utf/semadrawd/@400000006a*.s`, `current`. The
  TAI64N timestamps in the archive names range from 2026-05-20
  17:01 (`@400000006a0d6bde0732de51.u`) to 2026-05-24 15:33
  (`@400000006a129bf71ac5736c.s`). The current daemon's
  startup at 15:33 corresponds to the most recent archive
  rotation point.

The capture files live on `pgsd-bare-metal` under `/tmp/` and
are subject to tmpfs eviction on reboot. They should be copied
into the repository's `docs/evidence/` subtree (if such a
convention is wanted), or pasted into this document's appendix
verbatim, before the bench machine is rebooted. As of writing,
this has not been done.

## 7. Resolution (added 2026-05-27)

Three days after the original 2026-05-24 bench session, the
two predicted next actions from section 5 both completed:

  - **5.1 / AD-41 (main-loop input wake source)**: closed.
    AD-41.1 (investigation) and AD-41.2 (ADR 0021) landed
    2026-05-24/25. AD-41.3 implemented the `/dev/inputfs_notify`
    kernel cdev and userspace plumbing across two commits
    (0a59343 kernel-side, 3084da5 userspace). AD-41.4 ran the
    re-verification bench.

  - **5.6 / AD-36 closure**: still pending, but for a
    different reason than the wake source.

The AD-41.4 bench (2026-05-27) re-ran `ad36-bench.sh` after
AD-41.3 deployed. The notify cdev was open in semadrawd's
fd table (procstat -f confirmed fd 6 was
`/dev/inputfs_notify`). The wake-source change was in place.
But the bench output still showed zero `state_valid:true`
pump events, and post-window pump_diagnostic count was equal
to pre-window count - the main loop did not iterate once
during the 10-second window.

`procstat -k -w 1` sampled the daemon 10 times over 10
seconds. **All 10 samples** caught the thread in
`<running>` state, never parked in `kern_poll`/`seltdwait`.
`ps -o pcpu,time` confirmed 99.1% CPU sustained, with 1:1
CPU-to-wall-clock ratio.

`lldb -p $(pgrep -x semadrawd) -o "thread backtrace"`
identified the spin precisely:

```
frame #0: drawfs.DrawfsBackend.fillRect at drawfs.zig:1134
frame #1: drawfs.DrawfsBackend.executeChunkCommands
frame #2: drawfs.DrawfsBackend.executeSdcs at drawfs.zig:856
frame #3: drawfs.DrawfsBackend.renderImpl at drawfs.zig:818
frame #4: backend.Backend.render at backend.zig:273
frame #5: compositor.Compositor.composite at compositor.zig:450
frame #6: semadrawd.Daemon.run at semadrawd.zig:1267
```

The daemon was writing pixels one at a time in a Zig
software loop, partway through a full-screen fillRect at
3840x2160 (the bench iMac's EFI framebuffer geometry). At
~5 seconds per full-screen frame on the single-core
software path, the main loop iterates at ~0.2 Hz under
load - too slowly for the bench window to ever observe
the harvest-then-pump path even once.

This is filed as **AD-43** with the full diagnostic
evidence preserved in the BACKLOG entry. AD-36's closure
criterion is now bench-blocked on AD-43, not on AD-41.

Several of section 5's predicted failure modes turn out
to be partly explained by this single finding:

  - **5.3** (100 ms poll-timeout under-firing) is exactly
    what would happen if composite returns slower than
    the timeout. The diagnostic stays open as AD-41.5 but
    is no longer mysterious.
  - The 30,735 historical `state_valid:false` pump
    emissions seen pre-bench were emitted during the
    brief gaps between composite calls, not at the
    documented 10 Hz cadence; the rate was always
    composite-paced, not timeout-paced.
  - The "startup burst then quiet" pattern from
    section 2.3 was likely also composite-paced: a
    burst while composite was idle at startup, then
    quiet once composite became continuously busy.

The AD-32 / AD-37 busy-spin entries should be updated to
point at AD-43 as the spin source.

Sections 5.4 (stale comment cleanup) and 5.5 (harvest-diag
script fix) both landed during the AD-41 cycle and are
not described separately here.

## 8. Second iteration (added 2026-05-27 evening)

A few hours after section 7 was written, AD-43.1 landed
(commit 3fb055d plus follow-up a12dc33) and AD-43.2 ran on
the rebooted bench. The fillRect fast path worked. The
unit tests pass, lldb confirms the per-pixel writePixel
inner loop is no longer hot. But the bench window still
showed zero state_valid:true pump events. The closure
criterion did not move.

Why: a second bottleneck, previously masked, became
visible. Ten lldb stack samples post-AD-43.1 land:

  - 6 / 10 in `DRAWFSGIOC_BLIT_TO_EFIFB` ioctl path
    (`drawfs.DrawfsBackend.blitToEfifb` at drawfs.zig:675),
    which copies the rendered surface row-by-row into
    the EFI framebuffer
  - 3 / 10 in `posix.poll` with timeout=100, parked at
    semadrawd.zig:1105 (loop does reach poll)
  - 1 / 10 in `fillRect` at line 1163, the early-return
    after the AD-43.1 fast path completed

CPU stays at 99% sustained. The loop iterates fast
(283 pumps/s historical average since startup), but
during the 10-second bench window the daemon emitted
zero log lines of any kind, meaning all 10 seconds
were consumed by composite + blit cycles that never
reached the pumpCursorPosition call site.

This is filed as **AD-43.3**, now broken into:

  - **AD-43.3a (compose-gate audit)**: figure out why
    `damage_tracker.hasDamage()` and
    `scheduler.shouldComposite()` (compositor.zig:236) are
    both returning true on every iteration. Enabling
    `gate_instrument` to emit per-iteration diagnostics
    is the suggested starting probe.
  - **AD-43.3b (subrect blit)**: when composite does run,
    pass the actual damage rect to BLIT_TO_EFIFB rather
    than the full-surface 3840x2160. Smaller win but
    cheap.

AD-36 / AD-25 are still bench-blocked, now on AD-43.3
rather than AD-43.1. The diagnostic chain has narrowed
from "something between input and pump output is wrong"
(2026-05-24 framing) to "compose-gate logic causes
unnecessary work on every iteration" (2026-05-27 evening
framing). Each iteration of bench has surfaced one layer
and removed it.

The pattern is worth noting: removing a perf bottleneck
often exposes the next one. Three layers may yet land
under AD-43 before the bench window observes a
state_valid:true pump event. The AD-43 entry's "Fix
paths" section enumerated three layered options
(memset, dirty-rect, GPU); each compounds with the
previous.
