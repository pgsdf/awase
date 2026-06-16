# UTF Backlog: History

This file is the archive of closed and superseded BACKLOG
entries for the Unified Temporal Fabric, split off from
`BACKLOG.md` on 2026-05-27 evening to keep that file focused
on outstanding work. Every entry here was marked `[x]` Done,
`Superseded`, or explicitly preserved as an investigation
record at the time of the split.

**This file is append-only and historical.** New work goes to
`BACKLOG.md`. Entries here are preserved as written, including
any cross-references to other historical entries. If a
historical entry needs correction (as happened with B3.3's
status on the day of the split), the correction lands in the
active BACKLOG entry that supersedes the historical claim,
not by editing the archive.

Section headers (`##`) are preserved from the original
BACKLOG.md where they contain at least one historical entry.

**Second wave (2026-06-05, operator instruction).** This file
also receives historical RECORD entries: the closed sub-milestone
chronicle of an entry that remains open in `BACKLOG.md`, moved
here verbatim and marked as a record. The active entry, its
status, and its live obligations stay in `BACKLOG.md`.

---

## Shared infrastructure (`shared/`)

Cross-cutting code used by all four daemons: protocol constants, the
event schema, session identity, clock publication.

### `[x]` S-1: Protocol Constants Code Generator  *(Done, Small)*

Single source of truth for protocol constants across drawfs, semadraw
IPC, and SDCS. `shared/tools/gen_constants.py` reads
`protocol_constants.json` and emits C headers and Zig constant
declarations with a validation mode that diffs against the
hand-written sources. Two of the four critical PROTOCOL_MISMATCH
findings were drift that this generator now prevents structurally.

### `[x]` S-2: Unified Event Log Schema  *(Done, Small; blocks: A-3, I-1, D-1)*

All four daemons emit JSON-lines to stdout with a common envelope:
`type`, `subsystem`, `session`, `seq`, `ts_wall_ns`,
`ts_audio_samples`. Documented in `shared/EVENT_SCHEMA.md`.
Filesystem state surfaces (e.g. semaaud's `/tmp/draw/audio/…`) are a
separate concern, retained for introspection, not for chronofs.

### `[x]` S-3: Session Identity  *(Done, Small; blocks: S-2, all event-log convergence)*

`u64` token rendered as 16 hex chars, written to
`/var/run/sema/session` at fabric startup. Whichever daemon starts
first calls `readOrCreate`; the rest read the existing token. Survives
individual daemon restarts, dies with the tmpfs on reboot.
`shared/src/session.zig`.

### `[x]` S-4: Clock Publication Interface  *(Done, Small–Medium; depends: A-2; blocks: I-3, C-1)*

20-byte mmap region at `/var/run/sema/clock` with magic `SMCK`, version,
`clock_valid`, `sample_rate`, `samples_written`. Seq-cst atomic stores
by semaaud; atomic loads by every other daemon, no IPC round-trip.
`shared/src/clock.zig` provides `ClockWriter`, `ClockReader`, and
`toNanoseconds(samples, sample_rate)`.

---

## `drawfs`: kernel spatial substrate

`/dev/draw` character device, surface lifecycle, mmap-backed pixel
buffers, framed binary protocol, input event injection.

### `[x]` DF-1: Verify Integration Against Repaired semadraw Backend  *(Done, Small)*

Integration smoke test covering `RESET`, `SET_BLEND`, `SET_ANTIALIAS`,
`FILL_RECT`, `STROKE_RECT`, `STROKE_LINE`, `END` against a loaded
`drawfs.ko`. Surface pixel output matches software renderer golden
images. Python integration test lives in `drawfs/tests/`.

### `[x]` DF-2: Input Event Delivery  *(Done, Medium; depends: I-1)*

Kernel-side input injection via `DRAWFSGIOC_INJECT_INPUT` ioctl. Event
types `EVT_KEY`, `EVT_POINTER`, `EVT_SCROLL`, `EVT_TOUCH` in the
`0x9xxx` event range. Delivery is non-blocking on the rendering path
and observes the existing surface-event backpressure rules.

### `[x]` DF-3: DRM/KMS Display Bring-up (Phase 2)  *(Done, skeleton, Large; depends: DF-1)*

`drawfs_drm.c` skeleton present: connector/CRTC enumeration, mode set
on `DISPLAY_OPEN`, dumb buffer allocation, page flip on
`SURFACE_PRESENT`. Gated behind `hw.drawfs.backend` sysctl. **The
skeleton compiles only when `DRAWFS_DRM_ENABLED` is passed to
make(1)**, which is the build-system change tracked under the
DRM-optional theme below. Actual hardware bring-up is deferred until
someone has matching hardware to exercise it.

**Closeout precision (added 2026-05-21)**: "Done, skeleton" means
the symbols compile and the per-routine logic is in place;
**the runtime call path from `drawfs_reply_surface_present` to
`drawfs_drm_surface_present` is not wired**. Today `grep`
finds no callers of `drawfs_drm_surface_present`; the
SURFACE_PRESENT handler in `drawfs.c` replies and emits the
SURFACE_PRESENTED event without dispatching to the DRM backend.
That wiring is its own piece of work and is filed separately
as DF-6. AD-18.7 (the locking-discipline fix for
`drm_ioctl_kern` under `dd->drm_mtx`) is deferred to DF-6,
not to DF-3, because the buggy code exists in the skeleton
but has no live caller to trigger it until DF-6 connects
the path.

### `[x]` DF-4: Verify on FreeBSD 15 debug kernel (WITNESS)  *(Done 2026-05-08, Small)*

Rerun the drawfs test suite against a FreeBSD 15 kernel built with
`WITNESS`, `WITNESS_SKIPSPIN`, and `INVARIANTS` enabled. This stresses
the locking-order discipline in `drawfs.c` and `drawfs_surface.c`
(session mutex, surface mutex, vm_object lock) in a way that the
release kernel does not.

**Closeout 2026-05-08**: complete except for AD-18.7, which is
structurally deferred to DF-6 (re-tagged 2026-05-21,
previously DF-3).

The static audit (2026-05-05) produced seven findings, all
recorded in `docs/DF4_VERIFICATION.md` and filed as AD-18.
Runtime verification under PGSD-DEBUG on `pgsd-bare-metal-test-machine`
confirmed-and-fixed six of the seven over the 2026-05-07 →
2026-05-08 work window:

  - AD-18.1 (recursive `s->lock` acquire, panic on first boot):
    fixed in commit `03c3898`. Verified by absence of panic on
    subsequent boots and successful exercise of the
    INJECT_INPUT ioctl path.
  - AD-18.2 (`vm_pager_allocate` under `s->lock`): fixed in
    `8f3edec`. Verified by absence of WITNESS warning at
    `drawfs_surface.c:227` and counter checks
    (`hw.drawfs.vmobj_install_lost == 0`,
    `vmobj_allocs == vmobj_deallocs`) under live mmap workload.
  - AD-18.3 + AD-18.4 (malloc-under-lock at two sites in the
    `drawfs_write` codepath): fixed in `ea710da`. Verified by
    absence of warnings under exercise and
    `hw.drawfs.{inbuf_grow_race_lost, frame_extract_race_lost} == 0`.
    First-boot misattribution noted: the WITNESS lock-site
    line number identified `drawfs_try_process_inbuf` (AD-18.4)
    rather than `drawfs_ingest_bytes` (AD-18.3), but the fix
    landed both together since they share the same shape.
  - AD-18.5 (unprotected stats updates, five sites): fixed in
    `30ff3ad`. Originally filed as a single bytes_in site,
    expanded after audit to all five `s->stats.*` updates that
    violated the locking-model invariant. Verified by code
    review against the invariant (WITNESS does not catch
    data-race-class bugs of this kind without KCSAN).
  - AD-18.6 (surface-list teardown without `s->lock`): fixed
    in `0e083a5`. Latent in practice (priv_dtor invocation
    serializes), but the structural pattern was misleading
    and inconsistent with the rest of the codebase. Defense-
    in-depth fix.

AD-18.7 (DRM PAGE_FLIP path with `dd->drm_mtx` held) cannot
be runtime-verified until the DRM backend's runtime call
path is wired (DF-6, filed 2026-05-21 after a status audit
revealed DF-3 closed as "skeleton" with no caller of
`drawfs_drm_surface_present`). The fix design is captured
in the audit (capture flip parameters under lock, release,
perform `drm_ioctl_kern`, re-acquire to install the result);
its eventual implementation should land in the same commit
that wires SURFACE_PRESENT to the DRM backend. **AD-18.7 is
re-tagged as a DF-6 sub-task** rather than blocking DF-4
indefinitely. The previous tag of "DF-3 sub-task" was
imprecise because DF-3 closed as a compile-clean skeleton
without that wiring.

**Build-pipeline lessons** (recorded in DF-4 doc): two
deployment-ordering bugs surfaced during this work and have
been documented for future runtime-verification work.
install.sh now does `kldunload && kldload` after deploy
(commit `d21b68d`); stale dmesg can mislead the verifier
unless cleared with `sudo dmesg -c` before exercise.

Migrated from `drawfs/docs/ROADMAP.md` as part of B5.3.

### `[x]` DF-5: Fix async-event drain races in input-injection tests  *(Done; depends: DF-2)*

Running the full test suite (after SPRINT-04a's `build.sh` test-verb
fix made that possible) surfaced four pre-existing failures, all with
the same shape: tests expect a specific reply message but read an
asynchronous event that arrived in the queue first, plus a fourth
test (`test_event_queue_backpressure`) whose underlying design was
incompatible with normative coalescing behavior.

**Root cause**: `drawfs_test.py` already had the infrastructure to
skip events (`drain_until`, `skip_events=True` parameters on
`surface_destroy` / `surface_present`). The input-injection tests
just didn't use it after paths that enqueue events, but one of them
had a queue too large for `drain_until`'s default `max_msgs=20` to
handle. The `test_limits.py` backpressure test fought the protocol:
per `docs/PROTOCOL.md` line 167, "Multiple SURFACE_PRESENTED events
for the same surface may be coalesced under backpressure", coalescing
is normative, and a test loop that read one reply per present could
never accumulate enough queue pressure to hit ENOSPC with a single
surface.

**Fixes**:

- `test_input_injection.py::test_evt_touch_delivery`: cleanup
  destroy uses `skip_events=True`.
- `test_input_injection.py::test_event_delivery_does_not_block_present`:
  replaced a hand-rolled event-skip loop (which had a subtle bug
  where it swallowed events without reading past them on the
  "other event" branch) with `drain_until(fd, RPL_SURFACE_PRESENT,
  max_msgs=40)`; cleanup destroy uses `skip_events=True`.
- `test_input_injection.py::test_backpressure_enospc`: explicit
  `receiver.drain_all()` before cleanup destroy (queue of ~200
  events exceeds `drain_until`'s default message cap).
- `test_limits.py::test_event_queue_backpressure`: rewritten per
  the specification. The test now does what `docs/TEST_PLAN.md`
  § Step 19 actually says: write presents without reading, catch
  ENOSPC as an `OSError` from `write(2)` itself (matching the
  kernel's behavior at `drawfs.c:997-999`), drain the queue, send
  one more write to verify recovery. No helper, no reading during
  accumulation, no fighting with coalescing.

**Verification**: full 11/11 test suite green on the FreeBSD target.
Backpressure test hits ENOSPC after 169 presents (= 169 × 48 byte
replies + overhead ≈ `max_evq_bytes=8192`) and recovers cleanly
after drain.

**Not a regression** from B3.1–B3.3 pass 1. The validator added in
pass 1 still has no callers, so it cannot affect any code path.
These failures reached the surface only because `./build.sh test`
had been broken long enough that the full suite hadn't been
exercised in a while.

## `semadraw`: semantic rendering substrate

`libsemadraw` for clients, `semadrawd` compositor, SDCS command stream
format, backends (software, drawfs, Vulkan, DRM/KMS, X11, Wayland,
vulkan_console, headless).

### `[x]` D-1: Event Emission in Unified Schema  *(Done, Small–Medium; depends: S-2, S-3)*

`surface_created`, `surface_destroyed`, `frame_complete`,
`client_connected`, `client_disconnected` events emitted on stdout in
the unified schema. `frame_complete` includes `ts_audio_samples` taken
from the frame scheduler's target sample position, not the wall clock.

### `[x]` D-2: drawfs Backend Render State  *(Done, Small; depends: DF-1)*

`RenderState` in `src/backend/drawfs.zig` tracks `blend_mode`,
`antialias`, `stroke_join`, `stroke_cap`. Golden-image parity with the
software renderer for state-change mid-sequence scenes. Render state
does not leak between client sessions.

### `[x]` D-3: Frame Scheduler Clock Abstraction  *(Done, Small; blocks: C-4)*

`ClockSource` interface in `src/compositor/frame_scheduler.zig`;
`WallClockSource` is the default, `MockClockSource` supports
deterministic testing. No `std.time` calls remain directly in the
scheduler. This was the preparatory refactor for audio-driven
scheduling.

### `[x]` D-4: `DRAW_GLYPH_RUN` in drawfs Backend  *(Done, Medium; depends: D-2)*

Opcode `0x0030` implemented in the drawfs backend with correct CJK
double-width handling. `semadraw-term` now runs on the drawfs backend.
Output matches software-renderer golden images within a 1-pixel
tolerance.

### `[x]` D-5: Remote Transport Hardening  *(Done, Small; revised 2026-04-23)*

TCP loopback round-trip test; abrupt-disconnect test does not crash
`semadrawd` or leak surfaces; read timeout prevents stalled remote
clients from holding surfaces indefinitely. `docs/API_OVERVIEW.md`
documents the TCP transport alongside the Unix socket.

**Latent regressions, found and fixed 2026-04-23.** The original
acceptance for "abrupt-disconnect test does not crash `semadrawd`"
held against the specific test harness that exercised it but did
not generalise. Two pre-existing use-after-free bugs reached the
surface during unrelated mouse-pipeline work, when frequent
test-driven restarts of `semadraw-term` gave the disconnect path
many opportunities to fire. Both presented as repeating segfaults
at addresses ending in `...20b0` (byte 176 of a freed allocation)
immediately after a `failed to send key event to client N:
error.BrokenPipe` warning. 27 such segfaults accumulated in
`/var/log/semadrawd.log` across multiple daemon lifetimes before
the pattern was investigated.

**Bug 1:** borrowed `inline_data` (`semadraw/src/daemon/surface_registry.zig`):
`SurfaceRegistry.attachInlineBuffer`'s "not compositing" branch
borrowed the caller's `data` slice into `AttachedBuffer.inline_data`
without copying. Both call sites (`semadrawd.zig:477` and
`semadrawd.zig:793`) pass `session.sdcs_buffer.?`, which is owned by
the client session and freed when the session is destroyed during
disconnect. The next composite read the stale `inline_data` pointer
at the SDCS header offset and segfaulted. The deferred (compositing)
branch already copied correctly, but its copy was never freed at
buffer-replace or surface-destroy time, a separate latent leak.

  Fix: `attachInlineBuffer` now always copies, whether compositing
  or not; both paths converge on the same ownership story (the
  surface owns the copy). `AttachedBuffer.deinit` now takes an
  allocator and frees `inline_data` when non-null, closing both the
  use-after-free and the leak.

**Bug 2:** session double-disconnect race (`semadraw/src/daemon/semadrawd.zig`):
The poll loop's local-client-event branch ran `handleClientMessage`
under `POLL.IN` and called `disconnectClient(session.id)` on error;
it then unconditionally checked `POLL.HUP | POLL.ERR` and called
`disconnectClient(session.id)` again, dereferencing the now-freed
`session` pointer to read `session.id`. `POLL.IN | POLL.HUP` is the
normal kernel response when a client closes its end of a socket
that still has readable data pending, so this race fired on every
clean disconnect with any in-flight message.

  Fix: capture `session.id` into a local `sid` before any disconnect
  call, and track a `disconnected` flag so the HUP branch is skipped
  if the IN branch already cleaned up. Same pattern applied
  symmetrically to the parallel remote-client branch (which had the
  same hazard via `disconnectRemoteClient`).

**Verification**: three back-to-back `pkill -KILL -x semadraw-term`
runs with no growth in the segfault count (29 → 29 → 29 → 29), where
previously each disconnect grew the count by one. `semadrawd`
remains alive and producing `frame_complete` heartbeats across
client respawns, which is what the original D-5 acceptance was
trying to assert.

**Why D-5's original acceptance missed this.** The "abrupt-disconnect
test" in the original D-5 work exercised the *remote* transport
(TCP) path, where the disconnect arrives as a clean `recv`-returns-
zero on a separate fd that the daemon polls in isolation. That path
does not see `POLL.IN | POLL.HUP` in the same revents and never hits
the local-client double-disconnect race. The `inline_data` path was
also not exercised because the original test client did not attach
inline buffers between connect and disconnect. Both bugs were latent
behind test gaps rather than recent regressions; they had been
shipping in `master` for the entire history of the affected code.

### `[ ]` D-6: Mouse coordinate translation  *(Superseded, 2026-04-23)*

**Superseded by**: `inputfs/docs/inputfs-proposal.md`, tracked as
AD-1 in the Architectural Discipline section of this backlog.

This item proposed a compositor-side shim in
`semadrawd.forwardMouseEvents` to translate device-accumulated
coordinates into surface-local pixels. The `inputfs` proposal replaces
the entire evdev-based input path and produces screen-absolute
coordinates at source; the compositor-side shim is unnecessary under
that architecture. Mouse coordinates will remain wrong in production
until `inputfs` Stage D lands. This is an accepted transient bug, not
work to schedule.

The original scope and acceptance criteria are preserved below for
traceability and will not be revived. A fresh `inputfs`-era item will
supersede this when the relevant stage begins.

---

**Original scope** (superseded, retained for history):

**Depends on**: D-1 (event emission), mouse pipeline through `forwardMouseEvents` (landed 2026-04-22 via commit 6be3a74).
**ADR**: `semadraw/docs/adr/0003-mouse-coordinate-translation.md` (Superseded).

semainputd injects device-accumulated coordinates (running sum of
evdev REL_X/REL_Y since device open) via the kernel. semadrawd
forwards these unchanged to clients, which expect surface-local
pixels. `semadraw-term`'s cell-index math divides by cell size and
clamps to `[0, cols)`/`[0, rows)`; negative device-accumulated
values (observed `y=-568`) collapse every click to row 0. Chord
menus, drag selection, and any coordinate-sensitive gesture are
therefore broken despite the full event pipeline being verified
end-to-end.

Fix location: `semadrawd.forwardMouseEvents`. Translate
`event.x`/`event.y` to surface-local pixels using the target
surface's `position_x`/`position_y` and scale before constructing
the `MouseEventMsg`. Motion deltas (`dx`/`dy`) pass through
unchanged; they are frame-local.

**Acceptance**:
- Hold left mouse button, click middle → chord menu appears at the
  cursor position (not at the top-left corner).
- Drag a selection → highlighted cells correspond to the actual
  cursor path.
- No client handler receives negative `x` or `y` for any mouse
  event.
- Motion tracking in `vttest` mouse mode (or equivalent) reports
  sensible cell coordinates.

**Out of scope** for this item (tracked separately when reached):
- Initial offset seeding for the evdev accumulator (`y=-568` arose
  because the accumulator starts at zero and the test setup drove
  it upward relative to that origin; the right seed depends on
  display center vs focused-surface center and is deferred).
- Routing to the surface under the cursor rather than
  `getTopVisibleSurface`. Depends on focus tracking, which depends
  on NDE-1.
- Scaling semantics when `rend.scale` differs per surface; current
  translation assumes a single scale factor.

---

### `[x]` D-11: publish last_input_ts_ns for idle detection  *(CLOSED 2026-06-09, operator-ratified; ADR 0013 drafted, ratified, implemented, and bench-green the same day)*

Idle signal for SM-2 (ADR 0010 D5) and SM-3 (ADR 0009). semadrawd
publishes `last_input_ts_ns` (chronofs ns) via the
`idle_query`/`idle_reply` round-trip (MsgType 0x0037 / 0x8037), not a
shared region: the consumer may be non-root and the inputfs
state-region mmap is AD-34-stale for non-root readers, so a socket reply
is the fresh, uid-independent path. The consumer computes idle against
chronofs now. Coverage needed no code change: `drain()` appends every
raw inputfs event to the side-channel before dispatch, so the timestamp
advances on every input class, not just gestures. Shipped: the protocol
constants and regen, the local and remote query handlers in semadrawd,
`Connection.queryIdle`, and the `idle_probe` bench tool.

ADR: `semadraw/docs/adr/0013-publish-last-input-timestamp.md`.
Bench-verified 2026-06-09 on pgsd-bare-metal per
`semadraw/docs/D11_VERIFICATION.md`: the sentinel returned 0 on a fresh
daemon; keyboard, pointer, and touch each advanced the value
independently; and a non-root caller (`vic`) received fresh advancing
values.

### `[x]` AD-53: semadraw-term IRM (insert/replace mode, CSI 4 h/l) unimplemented  *(CLOSED 2026-06-10, operator-confirmed; fix bench-verified on pgsd-bare-metal)*

semadraw-term advertises `TERM=xterm-256color`, whose terminfo offers the
insert-mode capabilities (`smir`/`rmir`, i.e. `CSI 4 h` / `CSI 4 l`), so
readline brackets mid-line inserts in insert mode rather than rewriting the
tail. The non-private SM/RM dispatch in `vt100.zig` was a no-op and no
insert-mode state existed, so the inserted glyph overwrote the cell and the
tail never shifted; the user-visible symptom was that correcting or adding
characters mid-line appeared to overwrite the remaining text. ICH (`CSI @`,
`insertChars`) was already correct, so the gap was IRM specifically.

Fix: added `screen.insert_mode` (cleared on RIS), honored it in
`putCharWithWidth` by opening a gap with the existing `insertChars(width)`
shift before writing, and handled non-private `CSI 4 h` / `CSI 4 l` in
`vt100.zig`. Three parser tests cover the shift, the reset-to-overwrite, and
RIS clearing the mode. Bench-confirmed on pgsd-bare-metal: a mid-line insert
now shifts the tail, and `printf 'hello\r\033[4hXX\033[4l\n'` prints
`XXhello` rather than `XXllo`. Files: `semadraw/src/apps/term/screen.zig`,
`semadraw/src/apps/term/vt100.zig`. No ADR (AD-fix). Scope note: only IRM
(mode 4) is implemented; DECSTR soft reset (`CSI ! p`) would also be a
correct place to clear `insert_mode` but is not in the tree. Owner: semadraw.

### `[x]` AD-36: replace pumpCursorPosition's state-region poll with event consumption  *(CLOSED 2026-06-05, operator-ratified; surfaced 2026-05-12; bench-blocked on AD-43 2026-05-27 through 2026-06-05)*

ADR 0008's Direction 2 implementation. The cursor pump
currently reads pointer position via the state-region mmap
(`StateReader.pointerSnapshot`) on every loop iteration; AD-34
established that this mmap is frozen for `_semadraw`. The
inputfs event ring works as `_semadraw` (Probe 5 in
`docs/FREEBSD_ISSUES.md`) and already flows through the
compositor's input backend.

#### Observation

The work is smaller than ADR 0008 first framed it. The
event-ring consumption path is already wired into semadrawd:

  - `semadraw/src/backend/inputfs_input.zig` `InputfsInput`
    drains the ring inside the drawfs backend's
    `pollEventsImpl`.
  - `semadraw/src/backend/drawfs.zig`
    `getInputfsEventsImpl` (line 1319) snapshots a raw
    `input.Event` slice of everything drained since the
    previous call. Added by AD-2a Phase 2.4.2 specifically
    so future consumers can read the unfiltered stream.
  - `semadraw/src/backend/backend.zig` exposes this via
    `Backend.getInputfsEvents()` (line 320).
  - `semadraw/src/daemon/semadrawd.zig` (line 1086)
    already calls `self.comp.getInputfsEvents()` on every
    loop iteration to feed the gesture recogniser.

The pump can read from the slice that is already in
semadrawd's hand. No new `EventRingReader`, no new fd,
no new poll, no new bootstrap concern.

#### Scope of change

  - `pumpCursorPosition` (semadrawd.zig:645) loses its
    `state_reader` dependency for the position-tracking
    purpose. The function gains a new input: the most
    recent `pointer.motion` event seen this iteration, if
    any. Source: the slice from `self.comp.getInputfsEvents()`.
  - The pump's main-loop site already has the slice (the
    gesture-recogniser call site at line 1086). Either:
    (a) call the pump after the slice is in hand and pass
    it through, or (b) move the scan-for-latest-motion
    inside `pumpCursorPosition` after the slice is
    available. (a) is structurally cleaner; (b) is a
    smaller diff. Implementation chooses based on what the
    code looks like at the time.
  - The `StateReader` field on `Daemon` is not deleted
    (other state-region consumers may remain, e.g.,
    focus-tracking and smoothing-parameter reads). It
    just stops being used for cursor position. The pump's
    `state_reader == null` lazy-open path becomes unused
    for this caller and can be left in place or removed
    based on whether anything else still depends on it.
  - Bootstrap: if no `pointer.motion` event has been seen
    since the daemon started, the pump returns without
    updating position, exactly as it does today when
    `pointerSnapshot()` returns null. The first cursor
    motion seeds `last_cursor_pos_*`. No special initial
    drain is needed; the existing `InputfsInput.init()`
    code already skips to current writer_seq at startup
    so the pump does not get a historical replay.
  - Overrun: `InputfsInput.drainOnce` already handles
    overrun and resets `last_consumed`. The pump sees a
    gap (events lost) but the next motion event seeds
    correctly; the visible effect is a single cursor jump
    rather than a smooth tween over the lost frames.
    Acceptable; matches the behaviour of any input system
    under sustained drop.

#### Closure criterion

Bench: `semadraw-term --fullscreen` running, cursor moves
across the screen, visual update is smooth and tracks the
pointer continuously. The pump_diagnostic event (AD-38
below) shows non-stale `ps_x, ps_y` values. AD-25 closes
contingent on this.

*Implementation landed 2026-05-12 (this commit); bench
verification pending. `semadrawd.zig` adds three Daemon
fields (`last_motion_x`, `last_motion_y`,
`last_motion_seen`); the main-loop inputfs_events scan
harvests `pointer.motion` x/y into them inside the existing
loop that feeds the gesture recogniser; `pumpCursorPosition`
reads from those fields instead of opening a `StateReader`.
The `state_reader` field is left in place but no longer
assigned (its docstring records why). Resolves AD-25 in
principle; bench confirms.*

#### Risks

  - **Coupling to the gesture-recogniser call site.** If
    the gesture recogniser's call to `getInputfsEvents()`
    drains the slice before the pump runs, the pump sees
    nothing. Mitigation: order the pump call before the
    gesture recogniser, or have both consume a single
    snapshot taken once per iteration. The current code
    structure has only one call site for
    `getInputfsEvents` so this is straightforward, but
    the ordering needs to be made explicit.
  - **Other state-region consumers stay on the broken
    path.** AD-34's bug affects any state-region mmap by
    `_semadraw`. Today the pump is the only frequent
    consumer; focus tracking and smoothing parameters
    read infrequently and have not been observed to
    misbehave. If a new bug surfaces in any of those
    consumers, AD-34's underlying cause should be the
    first hypothesis.

#### Related

  - **ADR 0008**: the design decision that schedules this work.
  - **AD-25**: cursor smoothness umbrella; closes when this lands.
  - **AD-34**: the underlying FreeBSD-side bug; stays open as a
    kernel-investigation track.
  - **AD-38**: instrumentation refresh; lands with or near this.

#### Update 2026-05-27

AD-36's *code change* (replace state-region pump with
event-ring harvest) is already in place and has been for
some time. The closure criterion ("`state_valid:true`
pump_diagnostic events under cursor motion") could not be
demonstrated on bench because of three compounding issues,
peeled apart through the day:

  - AD-41 (no wake source for inputfs events): **closed
    2026-05-27 morning**. semadrawd's main loop now wakes
    on `/dev/inputfs_notify` instead of waiting for the
    100 ms timeout.
  - AD-43.1 (per-pixel fillRect dominates CPU): **closed
    2026-05-27 afternoon**. fillRect now uses row-major
    `@memset` over `[*]u32` for the common no-blend cases.
    lldb sampling confirms the per-pixel writePixel loop
    is no longer hot.
  - AD-43.3b (full-screen 4K blit per composite cycle):
    **active as of 2026-05-27 evening**. Even with
    AD-43.1's fast path on the inner fill, each composite
    still copies a full 3840 x 2160 RGBA surface (33 MB)
    via the BLIT_TO_EFIFB ioctl. At ~45 fps that costs
    most of one CPU. Subrect blit (passing the damage
    rect's bounding box instead of the full surface)
    reduces this cost proportionally.

AD-43.3a (compose-gate audit) was originally filed as a
parallel blocker on the hypothesis that
damage_tracker/scheduler was spinning unnecessarily. The
gate instrumentation that landed in commit 3991931 showed
the hypothesis was wrong about the current system; AD-43.3a
is now open but blocked on reproduction. See AD-43's
2026-05-27 evening update for the detailed reasoning.

The AD-36 closure criterion remains the same; the bench
verification is now contingent on AD-43.3b. AD-36 stays
Open as a documentation-state matter; its underlying
code-state work is complete.

#### Closure record (2026-06-05)

Closed by the 19:11 bench, verdict verbatim: "AD-36 chain works
end-to-end. Motion reached the inputfs ring; pump consumed it.
Closes AD-36 (and AD-25 contingent on AD-36)." The nine-day
bench blockage was the AD-43 composite cost compounded by the
events.zig emission bug that silenced every observation window;
see the AD-43 record for the full saga. Evidence transcript:
2026-06-05 19:11 run, recorded in the operator's session.

### `[x]` AD-46: client-socket send hardening (the "freeze" it was filed against did not exist)  *(CLOSED 2026-06-05, operator-ratified)*  *(Reframed 2026-06-05 by the freeze-stack capture: the loop never wedged; the socket work stands as hardening; the real P1 cost is composite re-execution, see the capture findings and fork below)*

The semadrawd main loop performs blocking I/O to clients from
inside the loop body: forwardMouseEvents and forwardKeyEvents
call session.send -> socket.sendMessage on client fds that are
accepted without O_NONBLOCK (no NONBLOCK anywhere in the daemon
socket layer). One client that stops draining its socket
therefore wedges the entire compositor: harvest, pump, composite,
logging, everything, until the client drains or disconnects. A
synchronous client makes the mutual-deadlock variant possible:
the client blocked sending its next request (semadrawd not
reading) while semadrawd is blocked sending events to it
(client not reading).

Evidence (2026-06-05 bench, daemon pid 358, uptime 108 s):
during the 10-second AD-36 capture window with 1,651
pointer.motion events arriving at the inputfs ring, the daemon
emitted ZERO log lines of any kind; pre and post counts are
byte-identical (9,613 lines, 4,805 pump_diagnostic, all
state_valid:true). pumpCursorPosition runs unconditionally every
loop iteration and had been emitting at ~44/s, so a silent
10-second window means the loop did not iterate: it was wedged
in one blocking call. lldb after the window found it parked
healthily in posix.poll(timeout=100) at semadrawd.zig:1105, the
wedge having resolved when the focused client (pgsd-sessiond at
the 4K login surface, plausibly slow to drain while software-
rendering) caught up. The 2026-05-27 stall (session
16d3d9453307a617: 88 seconds of zero emission, high CPU,
early-life daemon) matches this signature exactly and predates
AD-43.3b, so this is not a .3b regression; it is the latent
issue AD-43.3a was filed to catch.

Fix paths:

  (a) Durable: accept client fds with SOCK_NONBLOCK and give
      each session a bounded outbound queue flushed on POLLOUT;
      coalesce pointer-motion events in the queue (only the
      freshest position matters); disconnect a client whose
      queue stays full past a threshold. The compositor never
      sleeps on a client again, by construction.

  (b) Minimal first step: set client fds non-blocking and treat
      EAGAIN on send as a drop for coalescible event classes
      (mouse motion, where the next event supersedes the
      dropped one) and as a disconnect-after-N-consecutive
      failures for everything else. Small change at the two
      forward sites plus accept; unblocks the AD-43 bench
      immediately. (a) can supersede it later if drop-on-full
      proves too crude for key events.

Recommendation: (b) now, (a) if field experience demands it.

Path (b) RULED by the operator and IMPLEMENTED 2026-06-05:

  - Client fds are set non-blocking at both accept sites
    (handleNewConnection, handleNewRemoteConnection) via fcntl
    F_SETFL O_NONBLOCK.
  - New ClientSocket.trySendMessage and RemoteClient.
    trySendMessage send one protocol message as a SINGLE write of
    the fully serialized frame, returning a four-way result:
    sent / would_block (nothing written; clean drop) / partial
    (stream corrupt mid-frame; must disconnect) / err. The
    single-write design exists because drop-on-EAGAIN is only
    safe when nothing was written; the old two-write
    header-then-payload path could corrupt the stream.
  - forwardMouseEvents: motion drops cleanly on would_block
    (per-session dropped_motion counter); press/release feed a
    per-session send_fail_streak (reset on any successful send),
    disconnect at 64 consecutive failures; partial/err disconnect
    immediately. forwardKeyEvents: streak policy for everything
    (no coalescible class). Remote clients: any stall on
    non-coalescible or any partial/err disconnects (remote
    desktops reconnect).
  - Hardened the legacy blocking-path sendMessage on both socket
    types to detect short writes (error.PartialWrite) instead of
    discarding the byte count: with non-blocking fds every legacy
    send site (replies, clipboard, gestures' catch paths) must
    fail loudly into its existing disconnect path rather than
    corrupt silently. Known remaining: sendMessageWithFd
    (SCM_RIGHTS handshake path) keeps its sendmsg semantics; a
    stall there surfaces as an error to the handshake's existing
    error path.

SECOND BENCH (2026-06-05 17:30) AND REVISION: the freeze
reproduced IDENTICALLY with path (b) installed (window log lines
0, pump frozen at 14,803, 1,156 motions in the ring). Two
conclusions, recorded plainly:

  1. The blocking-write hypothesis is INSUFFICIENT as the sole
     cause of the freeze. The freeze predates and survives the
     write fix; its real cause is still unidentified. The next
     step is observation, not theory: scripts/ad43-freeze-stack.sh
     samples semadrawd's stack every 2 seconds DURING a
     mouse-motion window (plus one procstat -kk kernel stack) so
     the blocking call is caught in the act and named. Three
     reproductions in three runs says the next run will catch it.

  2. The fd-level O_NONBLOCK of the first implementation was a
     REGRESSION, found via the bench tail's reconnect churn
     (clients 2, 3, 4 handshaking in sequence): readLargeMessage
     maps WouldBlock to 0 and treats 0 as ConnectionClosed, so
     every large SDCS message (the 4K login surface's draws)
     disconnected its client. Fixed by redesign, not by patching
     the read path: client fds are BLOCKING again, restoring the
     receive path's field-proven semantics, and trySendMessage is
     non-blocking PER CALL via send(MSG_DONTWAIT). That is the
     property AD-46 actually needs: sends that cannot wedge,
     reads untouched. The short-write hardening in the legacy
     sendMessage stays (correct on blocking fds too, under signal
     interruption).

FREEZE-STACK CAPTURE (2026-06-05 17:48, six in-window samples,
delta 0 log lines): THERE IS NO FREEZE. The verdict overturns
the entry's premise. The six samples show a working loop in
different phases: two in the BLIT_TO_EFIFB ioctl, one mid
full-screen fillRectFast (x0=0, y0=0, y1=2160, opaque black,
via executeSdcs FILL_RECT), one allocating a 186,720-byte
client message in readLargeMessage, two parked in poll. The
loop iterated, read client messages, composited, and blitted
across the whole silent window. Three reproductions of "the
freeze" were observations of a log that stops, not a daemon
that stops; the blocking-write diagnosis (and the fix-path work
above) addressed a wedge that never existed as diagnosed. The
socket changes stand as hardening on their own merits.

What the samples prove instead:

  1. Under mouse motion, loop passes collapse from ~176/s
     (idle, no-change pump, no composite) to seconds per pass.
     The pass anatomy: the focused client (pgsd-sessiond)
     submits ~186 KB full-redraw SDCS buffers, and composite
     re-executes the full surface SDCS at 4K (the per-pixel
     glyph path is not fast-pathed) plus the blit.

  2. AD-43.3b's subrect blit is NULLIFIED in practice by the
     full-screen background fill inside the client's SDCS:
     the damage accumulator correctly records a full-screen
     write, so every blit is the full 33 MB. The implementation
     is correct; the composite architecture re-paints
     everything, so there is never a subrect to blit. This is
     why CPU stayed at 99 percent.

  3. Residual anomaly, recorded honestly as UNRESOLVED: the
     loop crossed pumpCursorPosition at least twice in-window
     (poll parks bracket completed passes), every guard before
     the unconditional instrumented emission provably held
     (cursor surface never destroyed after init, motion seen,
     output dimensions present), yet zero pump lines landed.
     Expected a handful; got none. This stays open and will
     either dissolve when passes are fast again or stand
     starkly exposed for direct investigation.

THE REAL PROBLEM, named: composite re-executes every surface's
full SDCS into the shared output buffer on every composite,
regardless of how small the damage is. Cursor-move frames pay a
full 4K software re-render of a text-heavy login surface plus a
33 MB blit. Two fix shapes, the operator's fork:

  (1) Retained per-surface composition: each surface renders to
      its own offscreen buffer only when its SDCS changes;
      composite blends cached buffers. The durable architecture
      (and the road toward LT-1's layer tree), but a large
      change: per-surface buffers, blend pass, memory cost at
      4K per surface.

  (2) Damage-clipped re-execution within the current
      architecture: composite passes the frame's damage rect as
      a clip; renderImpl sets it; every primitive (fillRect,
      strokes, glyphs) clamps against the clip exactly as it
      already clamps against the framebuffer. Commands fully
      outside the clip cost a comparison; the full-screen
      background fill becomes a damage-sized fill; AD-43.3b's
      subrect blit immediately regains its meaning (damage
      stays small, blit stays small). render_state already has
      a clip concept (RESET "clears any clip"), so this extends
      an existing mechanism rather than inventing one.
      Surgical relative to (1); cost proportional to damage.

Recommendation: (2) now; (1) remains the long-term shape under
LT-1.

RULED by the operator 2026-06-05: 2 now, 1 as the long-term
shape under LT-1. IMPLEMENTED same day, four files:

  - damage.zig: SurfaceDamage.boundingBox() returns the union
    of accumulated regions (surface-local); null on full_damage
    or no regions, which callers read as "no clip."
  - backend.zig: RenderRequest gains clip: ?ClipRect = null
    (framebuffer coordinates); null preserves pre-existing
    behaviour bit for bit.
  - compositor.zig: composite computes each damaged surface's
    clip as its damage bounding box offset to framebuffer
    coordinates; needs_full_repaint or full_damage passes null.
    Damage gating per surface already existed; the clip is the
    missing hand-off from tracker to backend.
  - drawfs.zig: renderImpl installs the clip for one render
    (defer-reset, so clearRegion outside renderImpl stays
    unclipped); fillRect clamps against it as against the
    framebuffer; the clear_color clear covers only the clip via
    the AD-43.1 fast row fill (replacing the per-byte
    full-buffer loop, which survives only as the non-mod-4
    stride fallback); strokeLine tests the clip per plotted
    pixel; the glyph path skips whole glyphs whose cell rect
    misses the clip (the largest single win for the text-heavy
    login surface) and clip-tests the survivors per pixel;
    noteDamage intersects the clip, so damage and drawing share
    one point of truth and the AD-43.3b subrect blit regains
    its meaning. An empty post-clamp clip stays active as a
    zero rect (everything clipped out), the correct meaning for
    damage entirely off the framebuffer.

Status [~]: implementation in the tree, bench owed.

THIRD BENCH (2026-06-05 18:34), mixed verdict, recorded in
three parts:

  1. The clip binary is RUNNING and the loop is FAST. Stack
     line numbers match the new code exactly (fillRectFast
     moved 1721 to 1818, renderImpl 899 to 954, composite call
     450 to 472, the size of the added clip code). Five of six
     in-window samples sit parked in poll DURING sustained
     motion, against zero of six (pre-fix runs were all
     mid-work). The single working sample is a full-height
     opaque-black fillRectFast, consistent with a legitimate
     full-damage frame from a sessiond buffer commit (full
     damage passes a null clip by design). The 99.1 percent
     CPU reading is ps's lifetime-decayed average over a
     117-second-old process whose first seconds were the
     instrumented early-life burst; it does not contradict the
     samples. Re-measure with top -P after minutes of settled
     uptime, idle vs motion.

  2. The seq:9999 line in the tail belongs to the PREVIOUS
     boot (its timestamp predates this boot's start by
     seconds; it is where the old daemon's counter happened to
     be when the reboot killed it). No emission cap exists;
     seq is a plain u64 fetchAdd.

  3. The log pipeline is the proven unreliable observer and
     now the last unknown. THIS boot emitted ZERO structured
     events from process start, including the ungated
     client_connected, whose std.log info twin DID land, and
     both fds reach the same pipe object (the run script's
     exec 2>&1). The emitters, the pipe, and s6-log have each
     been individually exonerated by reads; what remains is
     observation: scripts/ad43-logpath-diag.sh ktraces fd 1/2
     writes for five seconds under motion, dumps the fd table,
     the log directory rotation state, the s6-log process
     state, a per-archive structured-event census, and the
     daemon's environment, with a verdict guide mapping each
     outcome to its cause. The AD-36 criterion is unobservable
     until this is resolved; the clip's efficacy is currently
     evidenced by the sample distribution alone.

ROOT CAUSE FOUND (2026-06-05 18:52 logpath probe). The census
showed two consecutive boots whose final structured event was
seq 9999 EXACTLY, with instrument flags present in the live
environment and the ktrace showing zero fd-1 write calls, not
failed writes, no calls. The kill is one byte in events.zig:
the seq/timestamp scratch buffer was [64]u8, and the fragment
`,"seq":N,"ts_wall_ns":T,"ts_audio_samples":` is 41 literal
bytes plus a 19-digit 2026 timestamp plus the seq digits. Four
digits of seq total exactly 64 and fit; at seq 10000 the
fragment is 65 bytes, bufPrint returns NoSpaceLeft, and the
emitter's `catch return` swallows it. From its 10,000th event
onward every daemon process emitted NOTHING, every type,
silently, while std.log stderr lines continued through the same
pipe. Every "freeze" chased across AD-43.3a, AD-46, and three
bench days, and the pump-line residual recorded above as
unresolved, was this byte. Fixed: the scratch is now a named
SEQTS_SCRATCH_LEN = 96 (worst case is 80: u64-max seq plus
19-digit ts), with the history recorded at the constant and a
regression test pinning maximum-width fit so the buffer can
never silently shrink again. The instrument env flags remain
ON in the run script; with observability restored they are now
genuinely heavy (one gate diagnostic per loop iteration) and
their removal is part of AD-43.3a's own closure as already
noted there.

GREEN SHEET (2026-06-05 19:11 bench transcript). The AD-36
bench passed its criterion in its own words: "AD-36 chain
works end-to-end. Motion reached the inputfs ring; pump
consumed it. Closes AD-36 (and AD-25 contingent on AD-36)."
Emission alive at seq 41,931 and climbing (the one-byte fix
proven on bench). top: cores 81-95 percent idle where one was
pegged; semadrawd 39.2 percent WCPU as a decaying average that
includes the bench's motion window and the per-iteration
instrument emission. Consecutive idle iterations 105 ms apart
(the poll timeout), a calm loop. Diagnostics flowed throughout
a SIGSTOPped-sessiond window: the loop survives a stalled
client.

Bonus finding, free in the tail: gate diagnostics read
has_damage:false with should_composite:true, answering
AD-43.3a's standing question with data: the SCHEDULER is the
always-true gate. Composite with no damage renders nothing
(every surface skips), so this is cheap, but it is the
analysis .3a was opened to perform.

PROPOSED DISPOSITIONS, one ratification covers the batch:

  1. AD-43.3b: CLOSE. The subrect blit is meaningful under the
     clip and the criterion that gated it passed.
  2. AD-43.2 deferral: CLOSE, same evidence.
  3. AD-43: P1 RESOLVED; downgrade to Open, Small. Remaining
     scope: the .3a gate analysis (the scheduler finding above
     is its starting data) and removal of the two instrument
     env flags from the run script at .3a closure, as the run
     script already plans.
  4. AD-36: CLOSE per the bench's own verdict; entry moves to
     BACKLOG-history beside the evidence reference.
  5. AD-25: UNBLOCKED, not closed. Its discovery rounds can now
     run on valid emission. CAUTION recorded: any prior
     instrumentation dataset collected after a daemon had
     emitted 10,000 events was silently truncated by the
     events.zig bug; pre-fix long-window datasets are suspect
     and re-collection is part of the rounds.
  6. AD-46: CLOSE with residual noted. Loop survival under a
     stalled client is verified; the 64-streak disconnect path
     remains unexercised and stays as an optional
     defense-in-depth exercise, not a gate.
  7. Events fix: zig build test (the width test) still owed,
     one command, the only line left open on the day.

RATIFIED by the operator, 2026-06-05. Dispositions executed
same day: AD-36 and AD-46 closed and moved to BACKLOG-history;
AD-43.3b and the AD-43.2 deferral marked closed in place;
AD-43 downgraded; AD-25 annotated unblocked.

Item 7 discharged same day: operator reports zig build test
green (the events.zig width regression test). Nothing remains
owed from 2026-06-05. Client-side note for later: pgsd-sessiond submitting full
186 KB redraws on pointer motion is its own inefficiency (SM
backlog candidate), but the compositor must be cheap under that
behaviour regardless, and (2) makes it so.

Verification owed once the ruling lands: the AD-36 bench
criterion (now expected to pass at fast pass rates); CPU under
sustained motion well below saturation; the pump-line residual
re-examined at speed; the slow-client SIGSTOP test for the
socket hardening.

#### Closure record (2026-06-05)

Closed with the residual noted. The hardening stands on its own
merits: single-frame MSG_DONTWAIT sends, per-class backpressure
policy, short-write detection on the legacy path. Loop survival
under a stalled client verified by the 19:11 sheet (diagnostics
flowed throughout a SIGSTOPped-sessiond window). The 64-streak
disconnect path remains unexercised; it stays as an optional
defense-in-depth exercise, not a gate. The freeze the entry was
filed against was the events.zig scratch-buffer bug recorded in
AD-43; this entry's chronicle preserves the full investigation,
including the two wrong hypotheses, as the record of how it was
found.

### `[x]` AD-43: software composite hogs semadrawd main loop on 4K bench  *(Open, Small; surfaced 2026-05-27 during AD-41.4; **P1 RESOLVED 2026-06-05** by damage-clipped re-execution (fix path 2, ruled and ratified) plus the events.zig one-byte fix that restored observability; AD-43.1 closed 2026-05-27, AD-43.2 and AD-43.3b closed 2026-06-05; remaining scope is the .3a gate analysis (starting data: the scheduler is the always-true gate) and removal of the two instrument env flags at .3a closure)*

Surfaced during AD-41.4 bench verification. After AD-41.3
landed (wake source via /dev/inputfs_notify), the bench
re-run still showed zero pump_diagnostic events during a
10-second cursor-motion window. The notify fd was open,
in the poll set, and would have been wakeable - but the
main loop never returned to poll().

#### Observation

`procstat -k -w 1` sampled semadrawd over 10 seconds:
**all 10 samples** showed the thread in `<running>`
state, never parked in `kern_poll`/`seltdwait`. The
sibling processes (s6-supervise, s6-log) were parked in
`seltdwait` every sample. `ps -o pcpu,time` confirmed
99.1% CPU sustained, with TIME advancing 1:1 with wall
clock (5 seconds of CPU per 5 seconds of wall).

`lldb -p $(pgrep -x semadrawd) -o "thread backtrace"`
sampled three times spaced 2 seconds apart, all
three landed in the same userspace stack:

```
frame #0: drawfs.DrawfsBackend.fillRect at drawfs.zig:1134
frame #1: drawfs.DrawfsBackend.executeChunkCommands
frame #2: drawfs.DrawfsBackend.executeSdcs at drawfs.zig:856
frame #3: drawfs.DrawfsBackend.renderImpl at drawfs.zig:818
frame #4: backend.Backend.render at backend.zig:273
frame #5: compositor.Compositor.composite at compositor.zig:450
frame #6: semadrawd.Daemon.run at semadrawd.zig:1267
```

One sample caught the innermost pixel write
(`drawfs.writePixel`) with `idx=27957156`, partway
through the framebuffer:

```
frame #0: drawfs.writePixel(idx=27957156, r=0, g=0, b=0, a=255, blend_mode=0) at drawfs.zig:1491
```

The framebuffer dimensions are confirmed by dmesg:

```
info(drawfs_backend): display 1: 3840x2160@60000mHz
info(drawfs_backend): efifb available: 3840x2160 stride=15360 bpp=32
```

3840 x 2160 x 4 bytes = 33,177,600 bytes per full frame.
idx 27,957,156 is row 1820 (27957156 / 15360 ~= 1820),
showing fillRect is mid-way through filling the screen
to opaque black, one 4-byte pixel at a time, in a Zig
software loop.

The implementation at `drawfs.zig:1131-1136`:

```
while (px < x1) : (px += 1) {
    const idx = @as(usize, @intCast(py)) * stride
              + @as(usize, @intCast(px)) * 4;
    if (idx + 3 < fb.len) {
        writePixel(fb, idx, cr, cg, cb, ca,
                   self.render_state.blend_mode);
    }
}
```

The bounds check (`idx + 3 < fb.len`) runs once per pixel,
the `writePixel` call may dispatch on blend_mode at each
call, and there is no vectorisation. Estimated cost:
~5 seconds wall-clock per full-screen fillRect at 4K on
the bench's single-core software path.

`composite()` likely calls fillRect at least once per
frame for the background, plus once per surface for
fills. With each frame costing seconds, the main loop
iterates at ~0.2 Hz under load.

#### Why this matters

The cursor pump (AD-36) cannot demonstrate its closure
criterion (`state_valid:true` pump_diagnostic events
under motion) until the main loop iterates fast enough
for the 10-second bench window to observe at least one
iteration where pump runs after harvest has seen a
motion event. With composite at ~5 seconds per frame,
iteration rate is ~0.2 Hz; bench window of 10 seconds
sees 2-3 iterations at best. The harvest may not happen
to coincide with a motion event in any of them. AD-36's
closure is therefore bench-blocked on this.

Transitively, AD-25 (cursor smoothness umbrella) is
contingent on AD-36 and so is also blocked.

Beyond the AD-36 chain: at ~0.2 Hz iteration rate, all
of semadrawd's responsiveness suffers - keyboard event
forwarding latency, click handling, surface damage
processing, anything that the main loop owns. The
practical user-facing effect on bench is "the
compositor appears completely unresponsive during
sustained motion". This isn't an AD-36-specific
problem; it's a general bench-usability problem on
4K hardware.

#### Fix paths

Three options, roughly in increasing scope, the way
AD-42's were laid out:

  (a) **Vectorise fillRect via `@memset` or `@as([*]u32,
      ...)[i] = packed_argb` row-fills.** When the
      blend_mode is `NONE` (opaque source), each row of
      a fillRect is identical: stride/4 words of the
      same 32-bit ARGB pixel. `@memset` on a `[*]u32`
      slice is one instruction per write-buffer cache
      line on amd64 (`rep stos` or vectorised). Expected
      speedup: 30-100x. Does not address the blended
      case, which still needs per-pixel work, but the
      bench's "fillRect to opaque black" path is the
      no-blend case and would benefit most.

  (b) **Add dirty-rect tracking to the composite path.**
      Recompose only the area that actually changed
      since the previous frame. Most frames have small
      damage (cursor moved, single character typed) and
      would touch ~0.1% of the screen. Larger change;
      requires Composite to track previous-frame
      damage state. Independent of (a) - they
      compound.

  (c) **Move composite to a GPU path.** drawfs has the
      EFI framebuffer mapping; a Vulkan or OpenGL
      backend would render to that buffer at hardware
      speeds. Largest scope; multi-week. The
      pre-existing UTF/BACKLOG discussion of Vulkan
      backend lives separately; this entry does not
      duplicate it.

(c) is the durable answer but is multi-week work and
the wrong granularity for this entry. (a) is a half-day
fix that would unblock AD-36 and the rest of the AD-25
chain. (b) is the right next step after (a), since (a)
alone still re-renders the whole screen every frame.

#### Sub-tasks

  - **AD-43.1** *(Done 2026-05-27, commit 3fb055d; follow-up
    commit a12dc33 fixed the test-only struct literal that
    blocked the manual test invocation)*: Implemented (a) for
    the three blend-mode cases where every pixel resolves to
    the same destination value: Clear (mode 2), Src (mode 1),
    and SrcOver (mode 0) with alpha == 255. Per-pixel
    writePixel loop is replaced with a row-major `@memset`
    over a `[*]u32` slice via a new `fillRectFast` helper.
    The remaining cases (SrcOver alpha < 255, Add, and the
    misaligned-stride fallback) stay on the per-pixel slow
    path.

    Three unit tests landed in drawfs.zig:

      - `fillRectFast: writes only the rect, leaves
        surroundings untouched`: small buffer, byte-checks
        that only the intended rect is touched.
      - `fillRectFast: pixel layout matches writePixel for
        Src mode`: fills an 8-pixel row two ways
        (per-pixel writePixel vs fillRectFast with composed
        u32), byte-compares across a 7-colour palette
        including alpha != 0xFF. This is the parity test
        that validates the BGRA-to-u32 endianness assumption.
      - `fillRectFast: Clear mode equivalence`: validates
        pixel=0 matches writePixel(blend_mode=2).

    All 12 inline tests (3 new + 4 pre-existing in drawfs.zig
    + 5 in inputfs_input.zig) pass via the manual
    `zig test --dep backend --dep input -Mroot=drawfs.zig`
    invocation documented in build.zig:967-973.

    Bench evidence that the change took effect (2026-05-27
    post-install, post-reboot lldb sampling, 10 samples):

      - 1 sample landed in fillRect at line 1163, the
        early-return at the bottom of the fast-path branch,
        i.e. the fast path completed and returned.
      - 0 samples landed in the per-pixel writePixel inner
        loop (vs 3/3 samples deep in writePixel pre-AD-43.1).

    The fillRect bottleneck is resolved. semadrawd is no
    longer wedged in software pixel-fill for seconds at a
    time.

  - **AD-43.2 (verification)** *(Ran 2026-05-27, criterion not
    met then; CLOSED 2026-06-05, operator-ratified: the 19:11
    bench met the deferred criterion under the fix-path-2
    clip)*:
    Re-ran `scripts/ad36-bench.sh` after AD-43.1 landed and
    the machine was rebooted to ensure all components were on
    fresh binaries.

    Closure criterion: at least one `state_valid:true`
    pump_diagnostic event during the bench's 10-second
    window with cursor motion.

    Result: not met. Window pump count 0; pre-bench pump
    count and post-bench pump count both 33,399 (unchanged).
    inputdump captured 2,178 pointer.motion events arriving
    at the inputfs ring during the same window. Log lines
    written by the daemon during the window: 0 (the entire
    log was static across the bench window).

    The daemon's uptime at bench start was 118 seconds.
    Pre-bench pumps emitted: 33,399. That's an average of
    ~283 pumps/s across the daemon's full life, well above
    the AD-25 target of 10/s, so the loop *can* iterate
    fast when it gets the chance. But for 10 seconds during
    the bench, it didn't. CPU was 99.1% sustained across
    the same 10 seconds.

    Stack-sampling via `sudo lldb -p $(pgrep -x semadrawd)
    -o "thread backtrace"` repeated 10 times found:

      - **6 / 10 samples**: in `drawfs.doIoctl` called from
        `DrawfsBackend.blitToEfifb` at drawfs.zig:675, which
        invokes the `DRAWFSGIOC_BLIT_TO_EFIFB` kernel ioctl
        to copy the rendered surface into the EFI
        framebuffer. The kernel-side handler at
        `drawfs.c:864-877` copies one row at a time via
        `copyin` plus `memcpy` (15,360 bytes per row at
        3840 wide, 2160 rows per full blit). Per-blit cost
        is on the order of 3 ms in theory; at the
        composite rate the daemon is achieving, the
        ioctl is now the dominant CPU consumer.

      - **3 / 10 samples**: parked in `posix.poll` at
        semadrawd.zig:1105 with timeout=100. The loop does
        reach poll; this confirms the AD-41.3 wake source
        is in place and AD-43.1's fast path has removed
        the pre-AD-43.1 "stuck in fillRect" condition.

      - **1 / 10 samples**: in fillRect at drawfs.zig:1163,
        the return after AD-43.1's fast path completed.
        Not the per-pixel inner loop. AD-43.1 worked.

    Per-fd state at the same moment (procstat -f):

      - fd 4: /dev/draw (backend cdev)
      - fd 5: /var/run/sema/input/events (mmap'd ring)
      - fd 6: /dev/inputfs_notify (AD-41.3 wake source)
      - fd 7: UDS /var/run/semadraw.sock

    `dd if=/dev/draw bs=12 count=5` blocked indefinitely
    when probed, meaning the /dev/draw event queue was
    empty, ruling out the initial hypothesis that the
    daemon was poll-spinning on a permanently-readable
    /dev/draw evq.

    **What this shifts in the AD-43 fix-path order:**
    AD-43.3 (dirty-rect tracking / don't recomposite when
    nothing changed) is no longer "if needed"; it's the
    next required step. The bench evidence indicates
    composite is being called continuously even when the
    only input is cursor motion (or nothing at all),
    causing back-to-back full-screen blits at whatever rate
    the frame scheduler allows. Even with AD-43.1 making
    each fillRect fast, the *per-frame* work (compositing
    surfaces, computing damage, blitting to efifb) saturates
    the CPU and prevents the main loop from reaching
    pumpCursorPosition at a rate visible to the bench
    window.

    The two layered improvements that AD-43.3 should now
    target:

      1. **Don't composite when there's no real damage.**
         Investigate why `damage_tracker.hasDamage()` and
         `scheduler.shouldComposite()` (compositor.zig:236)
         are both returning true on every loop iteration
         despite no apparent input or surface change. This
         is the larger win: eliminate the work entirely
         when no work is needed.

      2. **Pass a subrect to `DRAWFSGIOC_BLIT_TO_EFIFB`
         instead of the full surface.** When composite does
         have to run, the damage area is typically far
         smaller than 3840x2160. Passing the actual damage
         rect through to the blit reduces the ioctl's
         per-call cost proportionally. This is the smaller
         win, and can land independently of (1).

  - **AD-43.3 (compose / blit reduction)** *(Open as of
    2026-05-27; 3a blocked on reproduction, 3b active)*:
    Two layered improvements. AD-43.3b is the active next
    step; AD-43.3a is blocked on reproducing the spin
    behaviour. Each can land independently; both compound.

    **AD-43.3a (compose-gate audit)** *(Analysis complete
    2026-06-06, census and ruling pending; originally filed
    2026-05-27 afternoon,
    cannot proceed as of 2026-05-27 evening)*: Originally
    filed on the hypothesis that `damage_tracker.hasDamage()`
    and/or `scheduler.shouldComposite()` was returning true
    on every loop iteration, driving composite() and
    BLIT_TO_EFIFB unnecessarily on every iteration of the
    main loop. The bench evidence at filing time (AD-43.2,
    daemon session `16d3d9453307a617`) was consistent with
    that hypothesis: 99 percent CPU, 6/10 lldb samples in
    BLIT_TO_EFIFB, zero log emission for 88 seconds.

    Diagnostic added: enabled `UTF_COMPOSITE_GATE_INSTRUMENT`
    in the semadrawd s6 run script (commit 3991931) so the
    daemon emits a `composite_gate_diagnostic` event per
    `needsComposite()` call, recording the (has_damage,
    should_composite, state_valid) tuple. The instrumentation
    works; events.zig:357 produces clean JSON lines that
    survive s6-log retention.

    Result on bench: the symptom did not reproduce after
    reboot. A new daemon (session `8e8d6e77f7e9b71d`) shows
    healthy behaviour:

      - has_damage oscillates true/false correctly,
        approximately tracking surface activity.
      - should_composite oscillates true/false correctly
        per the frame_scheduler cadence.
      - frame_complete events fire at ~45 fps total across
        two surfaces (cursor + pgsd-sessiond UI), or
        ~22 fps per surface.
      - Diagnostic emission rate is ~300 lines/sec
        (mostly pump_diagnostic + composite_gate_diagnostic
        pairs). The loop iterates at a sustainable cadence,
        not the early-life 410K iter/sec burst that filled
        the log faster than s6-log could drain it.
      - CPU still 99 percent, but this is now legitimate
        work (software composite of two surfaces at 4K +
        full-screen BLIT_TO_EFIFB per composite). Not a
        spin bug.

    Tuple distribution on the healthy daemon (typical
    100-line tail):

         4   has_damage:false, should_composite:false
        10   has_damage:true,  should_composite:false
         2   has_damage:true,  should_composite:true

    The 2 instances of (true, true) are followed immediately
    by frame_complete events; the 10 (true, false) reflect
    damage marked but the scheduler not yet at the next
    deadline. The (false, false) entries are post-frame
    quiet periods. This is exactly the intended state
    machine.

    Conclusion: the AD-43.3a hypothesis was wrong about the
    *current* system. Whether it was wrong about the earlier
    daemon (session `16d3d9453307a617`) is undeterminable
    without reproduction. The session ended (likely killed
    by `install.sh` during one of the cycles between
    bench runs and this evening's investigation), so the
    state that produced the zero-emission stall cannot be
    inspected.

    To resume AD-43.3a, a reproduction is required. Two
    candidate scenarios to try:

      - install.sh + reboot sequence repeated several times,
        watching for a daemon that locks up shortly after
        startup.
      - Stress test: kill and relaunch pgsd-sessiond while
        the daemon is up. Disconnect/reconnect cycles may
        trip the issue.

    If a reproduction is captured, the existing
    UTF_COMPOSITE_GATE_INSTRUMENT instrumentation will record
    the tuple distribution during the stall, which is the
    diagnostic data AD-43.3a was originally trying to obtain.

    Estimated effort once reproduced: a day or two,
    depending on what the data shows.

    REPRODUCTION CAPTURED (2026-06-05, AD-43.3b bench run):
    identical signature (zero log emission for the full
    10-second window, pump count frozen, early-life daemon,
    healthy poll-parked stack afterwards). The instrumentation
    delivered its answer by silence: even the gate diagnostics
    stopped, proving the loop itself was not iterating, so the
    compose-gate hypothesis is ruled out for this stall class.
    Root cause identified as blocking client-socket writes
    wedging the loop body; filed as AD-46 with evidence and fix
    paths. AD-43.3a's open question transfers there; this
    sub-item closes when AD-46's fix lands and a slow-client
    test shows the loop iterating through a stalled client.

    ANALYSIS (2026-06-06, code reading): shouldComposite() is
    now >= next_deadline_ns, and next_deadline_ns advances only
    inside advanceFrame, which runs only when a composite
    actually executes. At idle the deadline therefore parks in
    the past and shouldComposite() reads true forever, so the
    conjunctive gate (has_damage AND should_composite)
    degenerates to has_damage alone. The resulting semantics:
    the first frame after idle composites immediately (no
    pacing latency on wake), and advanceFrame restores pacing
    for every subsequent frame under sustained load. The
    damage tracker arbitrates WHETHER, the scheduler arbitrates
    WHEN, and only during activity. The original hypothesis
    (a gate stuck true driving composite every iteration) is
    disproven for the damage side and benign for the scheduler
    side: composite is damage-gated and idle composites are
    zero. Side finding: the 2026-06-05 19:11 tail shows idle
    iterations 105 ms apart (the poll timeout pacing the
    loop), so AD-32's 67 kHz busy-wait does not reproduce on
    current code; the census below measures it directly.

    Proposed ruling (2026-06-06 morning, FALSIFIED by the
    census the same morning, retained for the record): the
    parked-deadline behaviour is intended; document and close.

    CENSUS RESULT AND THE REAL BUG (2026-06-06 07:59): under
    motion, 8,245 iterations in 30 s with has_damage true on
    91.8 percent, should_composite true on TWO, and THREE
    composites total: the cursor composited at 0.1 fps while
    damage was pending. The deadline is parked in the FUTURE,
    not the past. Code reading completes the mechanism:
    Compositor.start() adopts the chronofs audio clock if
    isValid() at that single moment and never revalidates;
    ChronofsClockSource.nowNs() converts the published sample
    count to ns whenever the reader reports valid; and the
    chronofs closure record (ADR 0001 findings, 2026-06-05)
    established that clock_valid NEVER resets and
    valid-with-paused-samples is a designed state. On a fresh
    boot where the audio engine has not clocked, the scheduler
    adopts a valid-but-frozen clock, next_deadline parks one
    interval ahead of a now() that never advances, and
    should_composite is false until audio plays, at which point
    the cursor springs to 60 fps. The previous evening's
    "always true" tail was the wall-or-advancing-clock case
    (the engine had clocked all day); both observations were
    real, from the two states of the same adopt-once design.
    The audit's original 2026-05-27 hypothesis was wrong in
    direction but right that this gate hides a bug.

    Side notes: the idle-phase zeros in the census are suspect
    (the script does not detect a current-file rotation between
    snapshots; guard added) and are superseded by the motion
    findings. The 19:11 idle cadence of 105 ms stands as the
    valid idle measurement for AD-32 purposes.

    Fix fork for ruling:
      (a) Adoption gate: start() adopts chronofs only if valid
          AND ADVANCING (two reads a few ms apart, require a
          positive delta). Cheap; fixes the boot-frozen case;
          does not cover a clock that pauses mid-life
          (kldunload audiofs with the desktop up).
      (b) Runtime watchdog: compositor detects deadline stall
          (wall time since last should_composite-true exceeds N
          intervals while damage is pending), rewires the
          scheduler to the wall clock once, and warns.
          Covers boot-frozen and mid-life pause.
      (c) Both: the gate keeps the common boot correct and
          cheap; the watchdog is the safety net. Re-adoption of
          the audio clock when it becomes live again is left to
          future AV-sync work where it belongs.
      (d) Wall clock for pacing always; chronofs reserved for
          AV-sync timestamps. Reverses the drift-free pacing
          design intent; not recommended without that intent
          being separately reconsidered.

    Recommendation: (c).

    VERIFICATION ATTEMPT (2026-06-06 13:18) AND A LIVE AD-32
    REPRODUCTION: the pacing grep, the warn-delta check, and
    the census all returned empty or zero, and all three were
    observation artifacts of one underlying condition: the
    daemon is BUSY-SPINNING (seq past one billion at ~88
    minutes of uptime, consecutive events 1.5 microseconds
    apart, ~200,000 lines/s, all three rotation archives
    stamped within the same second). At that rate the n3 x
    10 MB retention holds ~6 seconds of history: the adoption
    line rotated away moments after boot, and line-count
    census windows are meaningless when current is replaced
    every second. Every gate line reads has_damage:false,
    should_composite:true: the loop spins without blocking,
    which is AD-32's filing reproducing live, with AD-37's
    permanently-readable /dev/draw the standing hypothesis for
    what defeats poll. Tooling consequences, owned and fixed:
    the logpath probe's ktrace leg passed -t w (context
    switches, not syscalls), so its section 5 was vacuous in
    both June 5 runs (the June 5 conclusion stood on the seq
    census, independently valid); corrected to -t c. The
    census script is rewritten to capture the stream itself
    via tail -F, rotation-proof. NEW scripts/ad32-spin-capture.sh
    takes the evidence while the spin is live: stream-measured
    event rate, three stacks, and a two-second syscall trace
    histogrammed by call, poll return value, and the fds
    named in post-wakeup read/ioctl calls. The .3a verification
    is BLOCKED behind capturing and clearing the spin; the
    spin itself is the AD-32/AD-37 investigation handed to us
    running.

    SPIN DIAGNOSED (2026-06-06 13:30 capture, code-confirmed),
    AND IT UNIFIES AD-32 AND AD-37 INTO ONE BUG:

      The capture: ~195,000 events/s from the stream; the
      steady-state iteration is poll, ret 1, two writevs (the
      gate and pump lines), poll again, NO read of anything;
      63,836 poll returns of exactly one ready fd against ZERO
      timeouts; fd 5 (/dev/draw) read only ~73/s around
      composites; fd 8 (sessiond's socket) drained correctly at
      ~120/s.

      The code: semadrawd's poll set includes the backend fd
      with a comment that convicts itself: "/dev/draw is no
      longer an input source and is currently a no-op in the
      poll set (reserved for future backend-side events)". A
      polled fd with no revents handler and no dispatch-path
      drain. drawfs_poll (drawfs.c:699) is CORRECT
      level-triggered code: POLLIN while the session's event
      queue is non-empty. The daemon's own presents enqueue
      PRESENTED events into its own evq at the
      sessiond-animation rate (~60/s), the synchronous reply
      reads do not keep the queue empty between composites, so
      POLLIN is held high essentially always and poll returns
      instantly forever: AD-32's spin, ~32k iterations/s,
      amplified by the instrument flags into ~200k log lines/s
      and one-second log rotation. Regime dependence explained:
      a boot with no animating client has an empty evq and the
      calm 105 ms cadence; the login screen's animation makes
      the spin perpetual. The inputfs notify cdev is
      exonerated: its poll handler is edge-only and its own
      comment documents this exact disease as found and fixed
      there (the writer_seq level-check history at
      inputfs.c:1593).

    Fix fork for ruling:
      (1) Remove the backend fd from the poll set. The comment
          already calls it a no-op; the reservation returns
          WITH a drain handler when hotplug events actually
          exist. Smallest correct change; the loop returns to
          timeout-plus-notify pacing.
      (2) Keep it and add a dispatch-path drain: read and
          dispatch all pending drawfs events per wakeup.
          Builds event-consumer machinery for events nothing
          in the daemon consumes yet; speculative.
      (3) Kernel-side opt-out of PRESENTED enqueue for the
          compositor's session. The kernel is correct as
          written; this is ADR-scale and unnecessary for the
          bug.
    Recommendation: (1), with the poll-set comment rewritten
    to state why the fd must never return without a drain
    handler, citing this spin. Closing this also closes AD-32
    (the spin is this) and AD-37 (the always-readable fd is
    correct kernel behaviour observed through a polling bug),
    and unblocks the .3a verification, whose every observation
    failure today was this spin's log churn.

    RULED by the operator 2026-06-06: option 1. IMPLEMENTED
    same day: the backend-fd append is removed from the poll
    set; the site now carries the full history (the AD-2a
    no-op reservation, the spin mechanism with measured rates,
    drawfs_poll's exoneration) and the standing rule that a
    polled fd must never return without a dispatch-path drain
    handler. getPollFd() remains on the backend interface,
    unused by the loop, for the day hotplug events exist.
    Dispatch safety verified before the cut: the revents loop
    matches by fd value, not index, so the removal shifts
    nothing.

    Status [~]: bench owed, one install carries the spin fix
    AND the long-blocked .3a verification: (1) seq rate sane
    after the install's restart (tail twice, seconds apart;
    expect tens of lines/s, not hundreds of thousands); (2)
    idle census near 10/s iterations with the rotation-proof
    script; (3) the adoption line, now survivable: grep "frame
    pacing:" within the first minutes; (4) the warn-delta
    check across a settled session (expect 0); (5) census under
    motion. Green closes AD-32 and AD-37 alongside, then the
    instrument flags come out and AD-43 closes.

    VERIFICATION COMPLETE (2026-06-06 afternoon): (1) seq at
    ~297 events/s, a 650-fold drop from the spin; (2) the
    rotation-proof census clean and discriminating (idle 52.1
    percent damage vs motion 98.9, composites steady at 58/s,
    iterations ~120/s paced by sessiond's client traffic, zero
    invalid states); (3) the adoption line caught live under
    tail -F across a controlled restart: "frame pacing: adopted
    audio hardware clock", corroborated in-band by non-null
    ts_audio_samples on surface-0 frame_complete events; (4)
    warn delta 0 across the session (the stale-reset fix
    holds); (5) motion census bounded. The grep failures that
    chased this line for two days were rotation timing at every
    scale: ~200k lines/s under the spin (seconds of retention)
    and ~240 lines/s after it (minutes); the adoption line was
    emitted on every boot and outlived none of the windows. The
    instrument flags are REMOVED from the run script with a
    closure note; the daemon-side hooks remain for ad hoc use.

    PROPOSED TRIPLE CLOSURE, for ratification:
      AD-43: the freeze family is fully resolved. The original
        P1 (events.zig scratch overflow), .3b (clip), .2
        (deferral honoured), .3a (adoption gate, watchdog, and
        this verification) are all bench-green.
      AD-32: the busy-wait is diagnosed (the no-op /dev/draw
        pollfd), fixed (option 1), and verified (650-fold).
      AD-37: the always-readable /dev/draw is correct
        level-triggered kernel behaviour observed through the
        polling bug; closed by the same cut, with the standing
        rule recorded at the poll-set site.
    On ratification all three move to BACKLOG-history.

    RULED by the operator 2026-06-06: (c). IMPLEMENTED same day:
    ChronofsClockSource.isAdvancing() (two reads across a 50 ms
    window, sized above the 1024-sample interrupt period across
    supported rates); start() adopts chronofs only when valid AND
    advancing; needsComposite carries the watchdog (damage
    pending, gate refusing, 500 ms wall time, measured by the
    wall clock since the suspect clock cannot judge itself:
    rewire to wall once via scheduler.start(), which re-seeds
    the deadline in the new clock's epoch, warn, and stop
    tracking since the wall clock cannot stall). Re-adoption of
    a revived audio clock is left to future AV-sync work.

    FIRST BENCH AND CORRECTION (2026-06-06 10:08). The census
    is healthy: under motion 97.1 percent damage with composites
    tracking it; pacing live from boot. The operator then
    reports audiofs.ko was NOT loaded during the test, which
    falsifies my first reading of the watchdog warn ("pacing
    clock stalled 522 ms"): with no clock file on a fresh tmpfs
    /var/run, start() adopted WALL, and a wall-paced gate cannot
    legitimately stall (any deadline crossing resets tracking
    within 16.7 ms). Re-derivation exposed the real explanation:
    the watchdog's reset ran only on should_composite, so a
    stale stall timestamp survived damage clearing and the next
    damage-plus-false coincidence fired instantly with an
    arbitrary delta. On a wall-paced boot the rewire is a
    harmless wall-to-wall no-op, which is why the census stayed
    healthy. FIXED: tracking resets whenever the stall condition
    is not currently present (plain else). Second gap fixed in
    the same pass: start() now logs which pacer it adopted and
    why (absent/invalid vs valid-but-frozen vs adopted), so the
    decision is auditable per boot instead of inferable.

    Census interpretation notes: frame_complete is composites
    PLUS per-submission client acks (call sites at
    semadrawd.zig:1284, 1534, 2010), so it is not a pure
    composite counter; and the "idle" phase showed 51.4 percent
    damage with ~60 frame_completes/s, meaning pgsd-sessiond
    animates continuously at idle, fresh data for the ledgered
    SM candidate.

    Status [~]: bench owed, now with the adoption line as
    ground truth. Verification: (1) fresh boot, grep "frame
    pacing:" names the pacer; with audiofs unloaded expect the
    wall fallback and NO watchdog warn over a multi-minute
    desktop session (the spurious-fire fix); (2) kldload
    audiofs, restart semadraw, expect "adopted audio hardware
    clock" if the engine clocks, then kldunload audiofs and
    expect the genuine watchdog warn with a live cursor; (3)
    census under each pacer. Then the flag removal and closure
    batch.

#### Closure record (2026-06-06, operator-ratified)

Filed as a P1 freeze eleven days ago; closed as a family. The
"freeze" was the events.zig 64-byte scratch overflow silencing
emission at seq 10000; the 0.1 fps pacing was the frozen
chronofs clock adopted on a single validity check, fixed by the
adoption gate plus runtime watchdog (fix c, ruled); the clip
(.3b) took composite cost down; the .2 deferral was honoured;
and the verification that closed it surfaced and killed the
AD-32/AD-37 poll spin along the way. Final state bench-green on
all five legs, with the adoption line witnessed live and the
instrument flags retired from the run script.


### `[x]` AD-32: semadrawd main loop busy-waits at ~67 kHz  *(Open, Medium; surfaced 2026-05-12)*

Surfaced by AD-25 Round 1 instrumentation (ADR 0007 addendum,
commit `6d670b9`). The daemon's main run loop iterates at
roughly 67,500 iterations per second on the bench
(`pgsd-bare-metal-test-machine`, drawfs backend, single client
connected via Unix socket, semadraw-term --fullscreen
running). Each iteration runs `pumpCursorPosition`,
`pumpCursorFocus`, `comp.pollEvents`, and the
`needsComposite + composite` block, then re-enters
`posix.poll`.

#### Observation

Pump-event cadence measured directly:

  - Average inter-event delta: **14.8 us** (across 9,998
    captured events spanning 148 ms wall time).
  - Minimum inter-event delta: **~4 us** (back-to-back
    iterations doing no work).
  - The loop is not gated by the `posix.poll(timeout=100)`
    floor. `/dev/draw` (the drawfs backend's pollable fd)
    shows readable continuously while inputfs is delivering
    events, so `poll` returns immediately with `n > 0` rather
    than timing out.

The 8.7 Hz composite cadence observed in earlier benches
(2026-05-10) is **not** caused by the loop being slow. The
loop is fast; `needsComposite()` returns false on the vast
majority of iterations. That smoothness-relevant question is
tracked under AD-25 Round 2, separately.

This entry is concerned with the loop's busy-spin in its own
right, not its effect on cursor smoothness.

#### Implications

  - **CPU.** Continuous main-loop activity consumes CPU even
    when there is no productive work. On a desktop bench
    this is invisible against other load; on the sparrow
    laptop (1024x768 portable target, battery-powered) the
    impact is meaningful.
  - **Power.** A CPU that never reaches a deep idle state
    burns power proportional to the loop's per-iteration
    cost.
  - **Cache.** Each iteration reads the inputfs state mmap.
    If the state region's cache lines ping-pong between
    cores (inputfs writer on one core, semadrawd reader on
    another), the apparent cost of the loop may include
    cache-coherence traffic that does not show up as
    user-CPU time.

#### Open questions

  - **What is each iteration doing?** The 14.8 us average is
    larger than a "do nothing" loop should be on modern x86;
    something is consuming time per iteration. Is it the
    mmap read in `pointerSnapshot`, the
    `getCompositionOrder` walk in `pumpCursorPosition`'s
    visibility check, the `comp.pollEvents` drain, or the
    `posix.poll` syscall itself returning immediately? A
    per-phase timing inside one loop iteration would settle
    this.
  - **Why isn't `posix.poll(timeout=100)` reaching its
    timeout?** If `/dev/draw` shows readable
    continuously, that means the drawfs event ring has
    pending events not being drained, or the ring's
    readable-condition isn't clearing after a drain. Either
    is a bug in drawfs or the backend's `pollEvents`
    consumer.
  - **Is the cost of `pumpCursorPosition` itself
    significant?** At 67 kHz the pump runs ~67,000 times per
    second even when nothing has changed. The change-detection
    fast-paths return early, but the cost of reaching them
    (mmap read, hotspot subtract, fb-dims fetch, two
    visibility-comparison branches) is not free.

#### Next steps

A discovery round similar to AD-25's, but targeting the
loop itself rather than the cursor pipeline. Likely sequence:

  - **D1 (instrumentation):** add a loop-iteration counter
    and per-phase timing inside one iteration, gated on a
    new `UTF_LOOP_INSTRUMENT` env var. Sample every Nth
    iteration to keep log volume bounded.
  - **D2 (data collection):** bench-run with the new
    instrumentation under the same conditions that surfaced
    the 67 kHz finding.
  - **D3 (analysis and ADR):** based on findings, write an
    ADR for the fix. Candidate fix directions, none of
    which are committed to here:
    - Replace `posix.poll(100)` with a deadline-driven sleep
      using the existing `FrameScheduler.getTimeUntilDeadline()`
      plus an event-aware wake mechanism.
    - Add an eventfd-style wake from inputfs so the pump only
      runs when the cursor actually moved.
    - Investigate why `/dev/draw` is continuously readable
      (the underlying drawfs event ring may have a
      level-triggered readable bit when it should be
      edge-triggered, or the consumer may not be draining
      to empty).

#### Estimate

**Medium**. Discovery sequence is roughly two to four hours.
The actual fix depends entirely on D3 findings; could be
small (one-line drain fix in drawfs) or medium (loop-pacing
redesign with a new wake mechanism). A dedicated ADR will
follow D3.

#### Related

  - **AD-25** (cursor motion smoothness): sibling track,
    surfaced concurrently from the same Round 1 bench.
    AD-25 owns the composite-gating question; AD-32 owns
    the loop-pacing question.
  - **ADR 0007** addendum (2026-05-12): records the bench
    finding that surfaced this entry.

#### Closure record (2026-06-06, operator-ratified)

Diagnosed by live capture during the AD-43.3a verification: the
poll set carried /dev/draw as an acknowledged no-op with no
dispatch-path drain, while drawfs correctly reported POLLIN
whenever the session's event queue held the daemon's own
PRESENTED events, which the login screen's animation made
perpetual. Regime dependence explained (no animating client, no
spin). Fixed by operator-ruled option 1, the fd removed from the
poll set with the standing rule recorded at the site: a polled
fd must never return without a drain handler. Verified at a
650-fold rate drop with a clean, discriminating census.


### `[x]` AD-37: investigate why /dev/draw stays continuously readable in poll  *(Open, Small-Medium; surfaced 2026-05-12)*

ADR 0008 claimed Direction 2 would close AD-32 (semadrawd
main loop busy-spin) "as a side effect" by sleeping on
`/dev/draw`. Pre-implementation reading of the main loop
shows the claim was optimistic: `/dev/draw` is **already
in the poll set** (semadrawd.zig:1029, backend.zig
`getPollFd`), and `posix.poll` is **already called** with
that fd as a wake source. The 67 kHz busy-spin observed
under AD-25 Round 1 happened anyway, because the fd shows
readable continuously while inputfs is active (per the
AD-32 entry's Observation section).

The work to actually close AD-32 is therefore an
investigation, not an implementation. Why does the fd
stay readable, and what would make `poll` block when no
new event has arrived?

#### Possible causes (to investigate, not yet ruled out)

  - **Level-triggered semantics.** `/dev/draw` may signal
    readable as long as any unconsumed data exists on the
    backend. If `pollEvents()` does not drain to the bottom
    of the kernel-side queue, residual data keeps the fd
    readable forever. Fix: drain to empty per iteration,
    or use edge-triggered semantics if available.
  - **Spurious wakeups.** The drawfs character-device
    driver may signal readable on internal events not
    relevant to userland (e.g., bookkeeping in the kernel
    driver). Fix: filter the readable signal to only fire
    on user-visible event arrivals.
  - **Multiple producers.** inputfs publishes to /dev/draw
    via DRAWFSGIOC_INJECT_INPUT (legacy path) and via the
    inputfs-event drain at the same time. If both keep the
    queue non-empty in alternation, the fd never quiesces.
    Fix: identify which producer is responsible and gate
    it.
  - **Polling at the wrong layer.** AD-32 may be best fixed
    by sleeping on the ring's writer_seq advancing rather
    than on /dev/draw at all. The ring is mmap'd; sleeping
    on a memory location requires umtx or a futex
    primitive; not obviously cheaper than poll. This is
    the architecturally most invasive option.

#### Scope of investigation

Discovery-driven, similar to AD-25's earlier rounds. Likely
sequence:

  - **E1 (instrumentation)**: log the revents bitmask
    returned by `posix.poll`, the count of events drained
    by `pollEvents`, and `getInputfsEvents().len` for each
    main-loop iteration. UTF_LOOP_INSTRUMENT=1 gate.
  - **E2 (bench)**: run for ~10 seconds with cursor
    motion, then with no input. Compare which fd is
    keeping the loop hot.
  - Outcome dictates whether the fix is a one-line drain
    correction, a kernel-side filter in drawfs, or a more
    substantial wake-source rework.

#### Closure criterion

The main loop sleeps in `posix.poll` when no input is
arriving and wakes within one inputfs sync interval (1 ms
at INPUTFS_SYNC_HZ=1000) when input arrives. AD-32 closes
when this is bench-verified.

#### Risks

  - **AD-36 lands without AD-37.** This is fine. AD-36
    fixes cursor smoothness; AD-37 fixes CPU/power on
    idle. They are orthogonal concerns the ADR mistakenly
    coupled. AD-37 can proceed at its own priority.

#### Related

  - **AD-32**: the busy-spin entry that this investigation
    resolves.
  - **ADR 0008**: the source of the original (optimistic)
    "side effect" framing; this entry corrects it.
  - **AD-36**: the cursor pump fix; independent.

#### Closure record (2026-06-06, operator-ratified)

Answered: /dev/draw stays readable because drawfs_poll is
correct level-triggered code (POLLIN while the session event
queue is non-empty) and the daemon's own presents keep that
queue populated. The kernel was never wrong; the daemon polled
the fd without draining it (AD-32's spin). Closed by the same
cut, with the inputfs notify cdev's edge-only design noted as
the in-tree precedent that had already documented and cured
this exact disease.


### `[x]` AD-48: semadraw-term renders checkerboard fallback cells in tree output  *(CLOSED 2026-06-06, operator-ratified; filed, diagnosed, fixed, and bench-green the same day)*

The operator's photo of `tree` in semadraw-term shows the
branch glyphs (corner and horizontal: U+251C, U+2514, U+2500)
rendering as clean lines while column-aligned cells, where the
vertical continuation U+2502 would sit, render as the font's
checkerboard fallback glyph.

INVESTIGATION SO FAR (all by reading, 2026-06-06): the obvious
suspects are each individually verified correct. font.zig's
getBoxSegments has a correct U+2502 entry; charToIndex covers
the full U+2500-257F range; the atlas generation loop covers
all 128 box glyphs; vt100.zig's UTF-8 state machine buffers
across PTY read boundaries and decodeUtf8's 3-byte math yields
exactly 0x2502 for E2 94 82; renderer.zig uses the single
shared charToIndexWithFallback path. Crucially, the generation
mechanics for U+2502 and U+251C are identical except the
horizontal arm, so nothing in the pipeline can discriminate
between the glyph that renders and the one that does not. The
premise is therefore suspect: the failing cells may not contain
U+2502 at all. Byte-level probes issued to the operator:
  (1) in semadraw-term: printf followed by the three characters
      vertical bar, tee, horizontal (U+2502, U+251C, U+2500)
      on one line, and report which render as lines vs boxes;
  (2) tree piped through head -3 and hexdump -C, first lines,
      to see the exact bytes tree emits on this system.
Verdict table: if printf's U+2502 renders as a LINE, the
pipeline is innocent and tree emits something else on this
host (the hexdump names it); if it renders as a BOX, the
pipeline fails for 0x2502 specifically and the investigation
resumes inside screen.putChar and the renderer with that fact.

LATENT BUG FOUND IN PASSING, to fix in the same pass:
generateAtlas declares the atlas undefined; the ASCII loop and
the fallback/block blocks fully initialize their cells, but
generateBoxGlyph writes via "if (pixel > atlas[idx])", which
READS UNDEFINED MEMORY for every non-segment pixel of every box
glyph. Whatever comptime semantics let this build, the fix is
to zero each box cell before drawing segments (or write the
else branch), making the atlas fully defined by construction.

PROBE VERDICT (2026-06-06, operator hexdump): the pipeline is
acquitted and so is U+2502. The bytes per continuation line are
e2 94 82 c2 a0 c2 a0 20: vertical bar, then TWO NO-BREAK SPACES
(U+00A0). FreeBSD's tree indents with NBSP, which charToIndex
did not cover, so each NBSP drew the checkerboard fallback. The
twin hatched columns in the original photo were the NBSP pairs;
the thin vertical-bar glyph beside them rendered correctly all
along. (The printf probe failed as expected: FreeBSD sh printf
lacks backslash-u escapes; the hexdump carried the verdict.)

IMPLEMENTED same day, both fixes in font.zig:
  - charToIndex maps U+00A0 to the space glyph, with the
    hexdump evidence in the comment;
  - generateBoxGlyph assigns pixels directly instead of the
    max-write conditional, so every box cell is fully
    initialized by construction and the undefined read is gone.

BENCH GREEN (2026-06-06, operator: tree "renders correctly
now"): clean indent columns, vertical bars intact, box glyphs
unchanged by the direct-assignment fix.

PROPOSED: CLOSE AD-48. The checkerboard cells were FreeBSD
tree's NBSP indents hitting an uncovered codepoint, fixed by
mapping U+00A0 to the space glyph; the undefined-atlas read
found in passing is fixed in the same file. The diagnostic arc
is itself the entry's value: the pipeline was exonerated
component by component until the premise (that the failing
cells held U+2502) was questioned, and one hexdump settled what
no amount of code reading could. On ratification the entry
moves to BACKLOG-history.

#### Closure record (2026-06-06)

Filed from a photo, closed on a hexdump. The checkerboard cells
were never box-drawing characters: FreeBSD tree indents
continuation lines with NO-BREAK SPACE, an uncovered codepoint
that drew the fallback glyph. Fixed by mapping U+00A0 to the
space glyph; the undefined-atlas read in generateBoxGlyph,
found while exonerating the pipeline, fixed in the same file.
Operator-confirmed green: tree renders correctly, bars intact,
box glyphs unchanged. The method is the entry's legacy: every
component read innocent until the premise itself was tested at
byte level, and one hexdump settled what code reading could
not.

### `[x]` AD-40: semadraw-term does not reconnect when semadrawd restarts  *(CLOSED 2026-06-06, operator-ratified; the reconnect layer, scope-bounded)*

**Tracks**: `semadraw/src/apps/term/` (no reconnect path
exists there as of 2026-05-17), `install.sh` (the trigger
that surfaced it).

**Symptom and how it surfaced.** Running `sudo sh
install.sh` from inside a semadraw-term session fails every
attempt. Diagnosed (see the Phase 2.5 runbook SSH-hazard
note, commit caa0e2c and its predecessor): install.sh's
pre-install teardown stops semadrawd
(`stop_service_if_running semadraw semadrawd`, SIGKILL
fallback after 5s) and also stops utf-supervisor.
semadraw-term is a client of semadrawd; when semadrawd dies
the compositor is gone and the semadraw-term session
collapses, taking the shell running install.sh with it,
before the post-install restart block runs. The immediate
operational fix is "run install.sh over SSH, not from
semadraw-term" and is documented in the runbook. This entry
is the underlying robustness gap that fix works around.

**The actual gap.** `semadraw/src/apps/term/` has no
reconnect / re-establish logic. If semadrawd disappears and
later comes back (install restart, supervised respawn after
a crash, manual `service semadraw restart`), an existing
semadraw-term process does not reattach - the session is
dead even though a healthy semadrawd is running again. The
operator must start a fresh semadraw-term.

**What this is NOT (precision against existing work).** This
is distinct from and not a duplicate of the D-5-area
disconnect-robustness work (BACKLOG ~310-365, the
2026-04-23 use-after-free / double-disconnect-race fixes).
That work hardened the *daemon* to survive a *client*
dying: kill semadraw-term, semadrawd stays alive and clean
(verified, segfault count flat across `pkill -KILL -x
semadraw-term` runs). AD-40 is the opposite direction: the
*client* surviving the *daemon* restarting. The existing
verification explicitly covers "daemon survives client
death"; nothing covers "client recovers from daemon death".
The directions are independent; closing one did not address
the other.

**Scoping question (deliberately left open, not decided
here).** Whether semadraw-term *should* reconnect is a
genuine design decision, not an obvious yes:
  - For: makes the terminal robust to any semadrawd restart
    (supervised respawn, upgrade, manual restart), not just
    the install case; aligns with s6 already auto-respawning
    semadrawd by default (see the AD-20 finish-script flap
    policy - a single restart is well under threshold).
  - Against / unresolved: even with client reconnect,
    install.sh SIGKILLs semadrawd and there is a hard window
    where the compositor is simply absent; a terminal's
    on-screen state and scrollback cannot be reconstructed
    from a new compositor connection without the daemon
    having persisted per-surface state, which it does not.
    Reconnect might restore a live connection but not the
    session's visible contents - partial recovery only.
  - Therefore the requirement is unclear: full session
    survival across semadrawd restart is a much larger piece
    (daemon-side surface-state persistence) than connection
    reconnect alone. This entry records the gap and the
    question; it does not commit to a design. A decision on
    scope (connection-reconnect-only vs full-session-
    persistence vs accept-and-document-the-limitation)
    should precede any implementation.

**Not blocking.** Does not block AD-2 (the runbook
SSH-over-semadraw-term guidance is the working mitigation)
or any current critical-path item. Robustness/quality work
for the NDE/semadraw-term area; priority unset pending the
scoping decision.

DIAGNOSED (2026-06-06, first read; SECOND in the ratified
sequence): semadraw/src/apps/term/main.zig:689 handles the
compositor's .disconnected event with running = false, so the
terminal EXITS on disconnect, taking its PTY and the shell with
it. Nothing forces this: the grid, scrollback, and VT100 state
are client-side (screen.zig, vt100.zig) and the shell hangs off
a PTY (pty.zig) owned by the term process; none of it depends
on the dead socket. Proposed fix shape, the semasound device
layer transplanted (AD-47 precedent): on .disconnected, keep
the PTY pumping and the screen model updating, retry the socket
at ~1 s cadence, re-handshake, recreate and remap the surface,
and repaint the full grid from client-side state (the one full
redraw that is warranted). The shell survives a compositor
restart with at most a second of blank window. Open
implementation questions for the next read: which init steps
the reconnect must replay and what they assume, and whether the
event loop can poll the PTY independently while the connection
is down (it must, or the shell blocks on a full PTY buffer
during the outage). AD-fix under this entry per the AD-43.1
precedent: no new ADR.

IMPLEMENTED (2026-06-06): the reconnect layer, all in
apps/term/main.zig. The .disconnected handler drops to a
reconnecting state instead of exiting (the PTYs keep pumping
and the screen model keeps updating throughout; the poll set
simply omits the conn fd during the outage). A 1 Hz reconnect
replays connect, Surface.create at the original dimensions (no
size re-query: a mid-session resize would disturb the grid),
and show, then forces a full repaint from client-side screen
state. Old connection and surface objects are abandoned, never
destroyed (their teardown would touch the dead socket; the
semasound never-close policy). Both mid-stream commit sites
convert errors into the same disconnect transition, with
scr.dirty preserved on failure so the reconnect repaint has
everything. Two pre-existing em dashes in the touched file
cleaned per house rule.

Status [~], bench owed:
  (1) open semadraw-term, generate state (run ls, scroll some
      output, start a long-running command like top);
  (2) sudo s6-svc -r /var/service/utf/semadrawd: expect the
      window to vanish and return within ~2 s with the full
      grid intact and the shell alive (type a command);
  (3) the log pair: "semadrawd disconnected; terminal state
      held, reconnecting" then "reconnected to semadrawd;
      surface recreated, repainting";
  (4) the ungraceful variant: pkill -9 semadrawd (s6 restarts
      it); same expectations through the harder path;
  (5) multi-session: two terminal sessions, restart, both
      grids intact, background session's PTY drained during
      the outage (run yes briefly in it beforehand and confirm
      no shell stall).

BENCH GREEN (2026-06-06, operator: "everything works as
expected"): state generated and held (ls, top, scrollback),
window vanishes and returns with the grid intact and the shell
alive across a supervised restart, and the ungraceful pkill -9
path recovers identically through s6's restart.

CLOSURE PROPOSAL WITHDRAWN (2026-06-06 evening): a full
install froze a live semadraw-term, a path the s6-svc -r bench
did not exercise. The reconnect layer performs blocking
request/reply IO with no timeout against a peer in an unknown
lifecycle state: if the 1 Hz retry's connect handshake,
Surface.create, or a mid-flight commit reply lands in
semadrawd's pre-accept init window or its dying moments, the
single-threaded loop wedges forever, PTYs included, breaking
the design's own "PTYs keep pumping" promise. The install's
longer down window and staggered service starts created the
race the quick bench restart never opened. A stack capture of
the frozen process is requested before recovery; it names the
exact blocking call and therefore the fix (bounded-timeout IO
on the reconnect path end to end).

EXONERATED BY OBSERVATION (2026-06-06, stack plus truss): the
blocking-IO theory above was WRONG, recorded as such. The stack
shows the loop alive in its normal 16 ms poll with nfds=1 (the
reconnecting state's signature: one PTY fd, no conn fd), and
truss shows a textbook retry cycle, one non-blocking socket,
connect, ECONNREFUSED, close per second with clean fd hygiene
and the PTY pumped throughout. The reconnect layer behaved
exactly as designed. ECONNREFUSED with the socket file present
means SEMADRAWD WAS DOWN; a down semadrawd also explains the
"frozen" appearance directly (efifb holds the last composited
frame), and the return to a fresh login screen during the truss
window is what a semadrawd coming back looks like (s6 backoff
expiring, sessiond restarting), coincident with the trace, not
caused by it. The real incident is upstream: semadrawd crashed
or was held down after the install, daemon source unchanged by
the AD-48 term-only patch, possibly sitting in an AD-20
flap-protection backoff for the freeze's duration. Probes
issued: s6-svstat for both services, pgrep for the term (alive
means it reconnected to the new daemon and AD-40 passed its
hardest real-world test, shell intact behind the login screen),
the frame-pacing boot count in current, and the previous
incarnation's last non-event log lines across the archives,
which name the crash if it spoke. AD-40's closure stays
withdrawn only until the term's fate in this incident is known;
the withdrawal's original reasoning is retracted.

THE TERM'S FATE, RESOLVED (probes, 2026-06-06 evening): the
frozen term (pid 9528) survived the entire semadrawd outage
retrying correctly, and died only when the daemon's death
collapsed the login session and the session teardown killed its
process group. Correct Unix behaviour, outside any terminal's
power to survive, and outside AD-40's scope: a terminal cannot
outlive its own session's teardown. The reconnect layer passed
its hardest real-world test. CLOSURE PROPOSAL RE-ARMED with
this scope boundary recorded: AD-40 covers compositor restarts
within a living session (the s6-svc -r bench, green) and
outages up to session collapse (this incident, green to the
boundary). On ratification the entry moves to BACKLOG-history. The same install also
produced "pgsd-sessiond did not exit within 5s, sending
SIGKILL": stopping semadraw first crashes sessiond's
connection, s6 restarts it into a connect-fail loop, and the
AD-20 flap-protection finish sleep can collide with the
install's 5 s stop wait. A pre-existing timing lottery,
cosmetic in effect (the install restarts everything at the
end), ledgered here rather than filed.

#### Closure record (2026-06-06)

The terminal exited on .disconnected, killing its PTY and shell;
the fix is the reconnect layer on the semasound device-layer
pattern: the conn fd leaves the poll set during an outage, the
PTYs keep pumping, a 1 Hz retry replays connect, surface
creation at original dimensions, and show, then repaints from
client-side state; mid-stream commit errors convert into the
same transition. Scope boundary recorded: compositor restarts
within a living session (benched green), and outages up to
session collapse, a terminal cannot outlive its own session's
teardown. Vindicated three times in one evening: it survived a
multi-minute daemon outage retrying correctly (truss-verbatim),
reconnected 55 microseconds after the login handoff freed the
daemon, and was exonerated by stack capture when the outage was
first misattributed to it. The entry's closing irony is the
record's to keep: the bug fixed here, a process exiting when its
peer vanished, is the same shape as semasound's AD-47, and the
same cure worked twice in one day.

### `[x]` AD-38: refresh pump and composite-gate instrumentation for the new code path  *(CLOSED 2026-06-07, operator-ratified)*

The AD-25 Round 1 `pump_diagnostic` event and the AD-34 E1
extension (`ps_x, ps_y`) emit from inside `pumpCursorPosition`
at the point where the state-region mmap is read. AD-36
removes that read; the diagnostic emit site must follow the
new shape.

#### Scope of change

  - The `pump_diagnostic` event payload schema stays the
    same: surface_id, deltas, last_cursor_pos_*, ps_x,
    ps_y. After AD-36, ps_x and ps_y carry the absolute
    coordinates from the latest consumed `pointer.motion`
    event payload (rather than from a state-region mmap
    read).
  - The emit gate stays `UTF_PUMP_INSTRUMENT=1`. No new
    env var.
  - The emit site moves from the state-region read in the
    old pump body to the post-event-scan path in the new
    pump body.
  - AMENDED 2026-06-07, operator-ruled (a): the original
    scope here prescribed emit-only-on-motion-iterations,
    which would blind U1 to the very cadence it measures
    (absent emissions are ambiguous between idle, stalled,
    rate-limited, and no-motion). The implemented semantics,
    which landed inside AD-36 and which this entry now
    records as design intent: pump_diagnostic emits at loop
    cadence once motion has ever been observed; pos_changed
    reports whether the sampled position changed this
    iteration; ps_x, ps_y carry the current motion payload
    coordinates; before any motion has been observed, a
    state_valid=false diagnostic distinguishes "pump ran,
    no data" from "pump did not run". Idle periods are
    EXPECTED to produce continuing emissions with
    pos_changed:false, a stable heartbeat rather than a
    sparse event-only trace. The historical 67 kHz flood
    concern died with AD-32; idle emission cost is loop
    cadence (~10/s), environment-gated, off by default.
  - `composite_gate_diagnostic` (AD-25 Round 2) does **not**
    change. It fires from `needsComposite`, which is
    unaffected by AD-36.

#### Closure criterion

AMENDED 2026-06-07 with the scope ruling. Two-phase capture
under UTF_PUMP_INSTRUMENT=1:
  (1) idle phase: pump_diagnostic continues at loop cadence
      and reports pos_changed:false throughout;
  (2) steady-motion phase: pos_changed transitions occur at
      approximately the observed motion-event rate (~130 Hz
      by the Round 2 era inputdump measurements, against the
      stale-view era's 1 in 9,998), and ps_x, ps_y track the
      coordinates inputdump reports.
The capture is simultaneously AD-38's closure evidence and
the validation of AD-36's observation-path fix: pos_changed
still near zero under active motion means the instrumentation
move did not bridge the gap and the investigation returns to
the AD-25 class; pos_changed at roughly the motion rate with
aligned coordinates means AD-36 functions and AD-38 closes
with confidence.

CAPTURE GREEN AS AN INSTRUMENT, MARGINAL AS A SYSTEM, AND THE
MARGINAL IS THE DISCOVERY (2026-06-07 20:02, evidence tar
analyzed): idle 196 emissions in 20 s (~9.8/s heartbeat, zero
pos_changed) and motion 201 emissions with 181 pos_changed
(90%) and real coordinates (ps_x 0 to 1654). The inter-emission
gap histogram under ACTIVE MOTION: min 100.9 ms, median 104,
max 107.3, not one sub-100 ms gap in twenty seconds. The loop
is strictly poll-timeout paced; the inputfs notify fd never
wakes it while ~130 Hz of motion fills the event ring. Cursor
cost quantified in the same capture: median 116 px, p90 197,
max 621 per update at 3840 wide. Every element of the
instrumentation criterion that tests the INSTRUMENT is green;
the motion-rate element conflated instrument-works with
system-performs, and the system's 10 Hz answer is AD-25 Round
U1's finding, not an instrumentation defect.

PROPOSED: CLOSE AD-38. The refreshed instrumentation measures
heartbeat, change rate, coordinates, and timing to
sub-millisecond resolution; its closure bench answered U1. The
U1 findings transfer to AD-25's entry. On ratification this
entry moves to BACKLOG-history.

scripts/ad38-pump-capture.sh (REWRITTEN 2026-06-07 evening:
capture is now ts_wall_ns-bounded extraction from current plus
the newest archives, immune to the first version's buffered
tail losses and to mid-phase rotation, and the script gates on
slot state and slot process identity before arming, AD-50's
lesson applied) runs the two-phase capture end to end: arms UTF_PUMP_INSTRUMENT in the
deployed run script, restarts the daemon, streams the idle and
motion phases via tail -F into an evidence dir, computes
emission and pos_changed rates plus ps coordinate ranges, and
prints pass/marginal/fail verdicts against the criterion (idle:
heartbeat with zero pos_changed; motion: pos_changed at 50/s or
better, with the ~130/s Round 2 reference and the 1-in-9,998
stale-view era printed for context). The flag is removed and
the daemon restarted on every exit path (trap). Run from ssh:
the two daemon restarts collapse the login session.

FIRST CAPTURE: BOTH PHASES ZERO (2026-06-07 17:38). Zero
pump_diagnostic events of any kind, including the
state_valid:false heartbeat a fresh daemon must emit. The
log itself confirms the daemon never emitted (not a capture
artifact alone, though the capture's buffered tail is also
suspect and owed a rewrite). Eliminated by probe: the binary
contains the emitter (strings count 1); the source chain reads
correct end to end (export before exec, runtime getenv at
construction, non-empty enables, pump called every iteration,
line numbers in the chronicle's working notes). A manual armed
restart then found the env var ABSENT from the daemon process
per procstat, twice, despite the verified export in the run
file. The unverified link is the restart itself: nothing
TERM-restarted semadrawd today before these probes, so
"semadrawd no longer dies on s6-svc -r" is live as a
regression candidate, and would retroactively explain every
zero. scripts/ad38-arm-verify.sh (NEW) verifies each link with
its own verdict: the arm in the file, the restart by pid
change, the environment by procstat, the emission by count
delta, with disarm on every exit path. Four exhaustive
outcomes: pid unchanged (restart regression, today's parent
finding), pid changed env absent (supervisor spawning from
other than the edited file), env present delta zero (silent
emit-path failure, the catch-return swallows), env present
delta positive (chain works; earlier zeros were settle or
capture artifacts; rerun the two-phase capture).

THE OUTCOMES TABLE WAS NOT EXHAUSTIVE, AND LINK 0 HELD THE
ANSWER UNREAD (first arm-verify run, 2026-06-07 18:42): svstat
reported the supervised semadrawd slot DOWN, exitcode 1, for
18654 seconds, down since 13:31 JST, while an unsupervised
semadrawd (pid 4913) served the desktop. "Normally up" plus
five hours of no respawn means the flap giveup (exit 125)
fired, which became possible for the first time this morning
when the fixed finish deployed. Every zero of the afternoon
follows: the capture script and every manual probe edited the
run file and restarted a slot with no process in it, while pid
4913 sailed on with its morning environment. No instrumentation
mystery, no daemon restart regression, no emit-path failure:
the investigation was interrogating the wrong process. The
script's "restart regression" verdict is retracted; its design
flaw is that link 0 printed the down state and did not gate on
it. Autopsy probes issued (the new finish logging captured the
13:31 giveup in full, the exact capability benched twelve hours
earlier): the five fast-crash lines and the giveup line in the
service log, pid 4913's age and parentage, the crash log
epochs. Recovery deliberately sequenced AFTER the autopsy: if
the fast crashes were socket-bind failures against 4913, the
slot must come up before 4913 dies or it crash-loops again.

#### Related

  - **AD-36**: the pump refactor; this entry refreshes its
    instrumentation.
  - **AD-25 Round 1**: the original pump_diagnostic
    schema.
  - **AD-34 E1**: added ps_x, ps_y to the schema.

#### Closure record (2026-06-07)

The instrumentation move had landed inside AD-36; this entry's
work became ruling the semantics (operator-ruled: loop-cadence
heartbeat preserved, the entry's emit-only-on-motion scope
retracted as cadence-blind) and proving the instrument. Proven
it was, through a day that first had to expose AD-50 before
any armed daemon could exist: idle heartbeat exact at loop
cadence, pos_changed on 90% of motion reads, real coordinates,
sub-millisecond timing. The closure bench answered AD-25 Round
U1 outright (the loop is strictly poll-timeout paced; the
notify fd never delivers through poll(2) by construction) and
the root cause was found in kernel source the same evening.
The instrument's marginal motion verdict was the system
answering a question, not the instrument failing one.

## `semaaud`: audio daemon

OSS output, two named targets (`default`, `alt`), policy engine with
allow/deny/override/group semantics, preemption, fallback routing.

### `[x]` A-1: Phase 12 Durable Policy Validation  *(Done, Small)*

`policy-valid` and `policy-errors` surface files; `#` comment support;
`version=1` recognised and validated; unknown-directive and unsupported-
version errors surface correctly. Spec in
`docs/SemaAud-Phase12-DurablePolicy-Spec.md`.

### `[x]` A-2: Audio Sample Position Counter  *(Done, Small; blocks: S-4, C-1)*

`samples_written: std.atomic.Value(u64)` in `Shared`, advanced by
`n / bytes_per_sample_frame` after every successful
`posix.write(audio_fd)`. Monotonic across streams (does not reset on
preempt/override). Exposed in `RuntimeState.renderJson` alongside
`sample_rate`.

### `[x]` A-3: Unified Event Log Schema Adoption  *(Done, Medium; depends: S-2, S-3)*

`emitEvent` in `state.zig` writes JSON-lines to stdout in the unified
schema. Every `stream_begin`/`stream_end`/`stream_reject`/
`stream_preempt`/… event appears on stdout in addition to the
filesystem surfaces. `ts_audio_samples` is non-null during an active
stream and null otherwise.

### `[x]` A-4: Sample Rate Negotiation  *(Done, Small; depends: A-2)*

`parseHeader` no longer hardcodes 48000Hz/stereo/s16le. `SNDCTL_DSP_SPEED`
and `SNDCTL_DSP_CHANNELS` negotiate with the OSS device; `s16le` and
`s32le` are both accepted. Clients are rejected with a clear error on
unsupported rates. `samples_written` remains accurate because the
division uses the negotiated `channels` and `format`.

---

### `[x]` AD-47: semasound engine death on device loss (filed as a tone hang)  *(CLOSED 2026-06-06, operator-ratified; filed, diagnosed, ruled, implemented, and verified the same day)*

Repro (2026-06-06 morning, post-fix boot): unprivileged
`semasound-tone 440 1` returns AccessDenied (expected under the
device/socket permission model); `sudo semasound-tone 440 1`
hangs with no tone until interrupted. Context muddies the
diagnosis: the operator reports audiofs.ko was not loaded during
the session, yet `sudo kldunload audiofs` immediately afterwards
exited cleanly, which normally means the module was loaded.
The audio chain itself remains CLOSED (F.5 suites passed in
production mode 2026-06-05); this entry is a new observation
about the tone tool or semasound's behaviour when the device or
engine is absent or in an unexpected state, not a reopening.
DIAGNOSED (2026-06-06, kldstat-bracketed repro plus semasound
log tail). The mechanism, confirmed in code at
semasound/src/output.zig:118: the engine loop's device write is
`writeAll(fd, &out) catch { print; break; }`, so ONE write error
(error.NoDevice at kldunload) permanently exits the engine
thread. The accept path is a separate thread and keeps admitting
clients into the dead mixer: the log shows "audiofs write error
error.NoDevice", then no further playing heartbeats, then
"client 1 accepted", "client 2 accepted". Clients hang because
nothing drains their rings. Reloading the module does not
recover (no reopen path exists); only a daemon restart does.
This also retro-explains the morning hang IF that boot started
without the module (engine dead from startup); this boot's
bracketed repro stands regardless.

Fix proposal, for ruling:
  (a) Null-sink degraded mode: on device write error, do not
      exit the loop. Close the device fd, log "device lost"
      once, and keep consuming client rings at the chunk
      cadence, paced by a wall sleep of one chunk duration in
      place of the blocking device write, discarding the mix.
      Clients never block; tools complete silently. Each pass
      (rate-limited to ~1 s) retries opening the device; on
      success, log "device reopened" once and resume real
      output. kldload then recovers audio with no restart.
  (b) Heartbeat compatibility: the healthy "playing[default]"
      heartbeat line is consumed by the F.5 suites and stays
      byte-identical. Degraded state emits a distinct
      "degraded[default]" heartbeat instead; the suites never
      run degraded, so nothing breaks.
  (c) Client policy while degraded: keep accepting (with (a)
      they function correctly, just silently). No rejection
      path needed.

The audio chain's closed status is unaffected: this is a
robustness gap outside the F-chain's bench conditions (the
device never vanished mid-run in any suite). AD-fix under an
existing entry per the AD-43.1 precedent: no new ADR.

RULED by the operator 2026-06-06, directive verbatim: "Never
let writeAll() terminate the render loop; convert device errors
into a backend state transition (real -> null sink) and keep
the audio engine running with a reconnecting device layer."
IMPLEMENTED same day:

  - output.zig: run() carries a DeviceState (real / null_sink).
    The write step is a state machine: a device write error
    logs once, transitions to null_sink, and the loop continues
    on the F.5.c timer pacing (chunk-duration sleeps at the
    canonical rate, mix discarded, clients stream silently at
    real-time cadence). The null state retries the device open
    once per second; success republishes the fd, reseeds
    election state (a reloaded module rests at its own rate),
    transitions back to real, and logs once. frames_written
    advances in both states (the runNull/ADR 0025 precedent:
    paced consumption is production). The healthy
    "playing[...]" heartbeat is byte-identical for the F.5
    suites; the degraded state emits its own
    "degraded[...] device absent, reconnecting" line.
  - main.zig: g_out_fd is an atomic shared between the accept
    path (election ioctls load it per use) and the reconnect
    path (sole writer after startup). Dead fds are never
    closed, a bounded leak per device-loss cycle, so no reader
    can race a close. A missing device at startup no longer
    aborts the daemon: it logs, starts the output thread on the
    null sink, and the device layer reconnects; election
    seeding moves to the reopen path in that case.

FIRST VERIFICATION RUN (2026-06-06) AND TWO RESOLUTIONS:

  The device layer VERIFIED on the legs it owns: kldunload with
  the desktop up produced "degraded[default] ... device absent,
  reconnecting" heartbeats with the engine alive through the
  loss, and kldload restored "playing[default]" within two
  seconds with no daemon restart. The real-to-null-to-real
  cycle works.

  THE TONE "HANGS" RESOLVED, all of them, including the
  observation AD-47 was filed on: semasound-tone's positionals
  are [seconds [freq_hz [amp]]], SECONDS FIRST (tone_client.zig
  usage header). Every invocation in this saga was
  "semasound-tone 440 1": four hundred forty seconds of a 1 Hz
  tone, inaudible by definition and 7m20s long. Every "hang"
  was the tool doing exactly what it was asked. The wrong
  argument order originated in MY bench sheets and propagated
  through every test; recorded as such. The engine-death bug
  stands independently of this: the bracketed repro's
  heartbeats CEASED after the NoDevice error, which is the
  engine loop dying regardless of any client's semantics, and
  the fix above is what restored heartbeats through today's
  device-loss cycle.

  Leg 3 was a procedure artifact, not a failure: the rc.d
  semasound start path loads audiofs (install.sh:883), so
  "service semasound start" after kldunload silently reloads
  the module and the daemon starts healthy. The
  boot-without-module path must bypass rc.d via s6-svc.

  f5prod.sh takes one suite argument; the sheet's bare
  invocation was wrong.

Status [~], corrected verification owed:
  (1) healthy: sudo semasound-tone 1 440, expect an audible
      beep, exit within ~1 s, exit code 0;
  (2) degraded: kldunload audiofs, then the same command,
      expect silence, exit within ~1 s (the null sink draining
      the client at cadence);
  (3) recovery: kldload audiofs, ~2 s, the same command,
      audible again;
  (4) boot-without-module, bypassing rc.d:
      s6-svc -d /var/service/utf/semasound, kldunload audiofs,
      s6-svc -u /var/service/utf/semasound, expect the
      starting-on-null-sink line and degraded heartbeats, then
      kldload audiofs and an audible tone ~2 s later;
  (5) suites: from the semasound/ directory (f5prod resolves
      semasound-tone via ./zig-out/bin), f5prod.sh against
      f5b_election.sh, f5c_targets.sh, f5d_policy.sh,
      f5e_state.sh, all green.

SECOND VERIFICATION RUN (2026-06-06): legs 1 through 3 PASS.
The tone exits with its summary line in every state: audible
healthy, SILENT WITH A CLEAN ~1 s EXIT in degraded mode (the
null sink draining the client at cadence, the exact behaviour
the fix promises), audible again after kldload. Leg 4 is
DISCHARGED AS COVERED BY ARCHITECTURE: the s6 run script
carries its own defensive load (kldstat -q || kldload), so a
supervised module-less start is unreachable by design, two
layers deep (rc.d at install.sh:883 and the run script); the
null-sink startup path exists for the case where that load
itself fails, and its logic is byte-identical to the post-error
degraded state leg 2 verified. The run script's stale comment
("the broker exits on device open") updated to the AD-47
behaviour. Leg 5 stalled on invocation, not substance: f5prod
resolves semasound-tone relative to the working directory and
must run from semasound/; the root-level attempt plus a sudo
zig build also left root-owned semasound/.zig-cache and
semasound/zig-out (chown -R back to the operator before the
next unprivileged build). Leg 5 remains the only line owed for
closure.

LEG 5 GREEN (2026-06-06): all four production suites pass
against the supervised broker, every scripted case, with both
fd-count and RSS stability checks ok and the operator
confirming all ear checks (F.5.c cases 6 and 7, F.5.d case 5
ducking). The healthy heartbeat compatibility held: the suites
grep the playing lines and passed unchanged against the AD-47
build, which is the no-regression criterion for the healthy
path.

PROPOSED: CLOSE AD-47. Every verification line is discharged:
state transition and degraded service (leg 2's silent clean
exit), reconnection without restart (leg 3), startup defense
covered by architecture with the run-script comment corrected
(leg 4), and suite compatibility on the healthy path (leg 5).
On ratification the entry moves to BACKLOG-history under the
semaaud/semasound section beside the F.5 record.

    **AD-43.3b (subrect blit)** *(Implemented 2026-06-05;
    CLOSED same day, operator-ratified: meaningful under the
    fix-path-2 clip, verified by the 19:11 green sheet)*: When composite runs, pass the damage area's
    bounding rect through `BlitToEfifb` rather than the full
    surface. The kernel handler at drawfs.c:864-877 already
    accepts dst_x, dst_y, width, height parameters; the
    userspace caller in drawfs.zig:666-673 currently passes
    the full surface dimensions, but the damage tracker
    knows the actual changed region. Plumb damage_rect into
    blitToEfifb.

    Now the load-bearing next step. Today's bench evidence
    confirms the composite scheduler is well-behaved; the
    cost is in the work each composite *does*. A full-screen
    3840 x 2160 RGBA blit copies 33 MB into the EFI
    framebuffer per call. At ~45 fps that is 1.5 GB/sec of
    memory bandwidth on the kernel-side blit path alone,
    which is enough to saturate one CPU on its own. Most
    composites only need to update small regions (cursor
    moved a few pixels, a single character was typed); a
    subrect blit reduces the cost proportionally.

    Two implementation notes from today's reading of the
    code:

      - The kernel side at drawfs.c:864-877 mallocs a
        per-row temp buffer (stride bytes), copyins one
        row at a time, memcpys into the efifb mapping, and
        frees the buffer at the end. The temp-buffer cost
        is fixed; only the loop body scales with rows. So
        subrect blit reduces both the copyin work and the
        memcpy work proportional to dst_height /
        surface_height.

      - The userspace caller at drawfs.zig:666-673 has the
        request struct already, so adding dst_x / dst_y /
        width / height parameters requires changing only
        the call site, not the ABI between userspace and
        kernel.

    Estimated effort: a couple of hours, including bench
    measurement of the CPU delta.

    Implementation (2026-06-05, in tree): a damage
    accumulator on DrawfsBackend (dmg_* fields plus
    noteDamage/noteDamageAll) is fed by every buffer writer:
    fillRect at its clamp point (strokeRect and strokeLine's
    point case flow through it), strokeLine's general case
    via a conservative endpoint bbox expanded by the stroke
    half-width, the glyph run per glyph at its scaled
    destination extents, renderImpl's clear_color full-clear,
    and clearRegionImpl. Damage is PERSISTENT across calls,
    not per-frame: clearRegion writes the buffer outside
    renderImpl, and under a subrect blit its pixels would
    otherwise never reach the screen; accumulate-everywhere,
    consume-on-successful-blit closes that hole, and a failed
    blit keeps the region for the next attempt. blitToEfifb
    passes the rect by offsetting the src pointer (src = base
    + y*stride + x*4, stride unchanged); the kernel handler
    needs no change since it reads width bytes per row from
    src, exactly as the 2026-05-27 reading predicted. The
    userspace clamp against both surface and efifb geometry
    is load-bearing: the kernel does not bounds-check dst_x +
    width against the efifb row. Two bonuses fall out: a
    render that drew nothing skips the ioctl entirely, and
    efifb (re)availability seeds full damage so the first
    blit always covers the whole screen. Container gates
    passed (brace balance, hooks at all five writer sites);
    eleven pre-existing em dashes in the touched file cleaned
    per the dash discipline.

    Bench attempt (2026-06-05): criterion not evaluable; the
    AD-46 wedge froze the loop for the entire capture window
    (zero emission), so neither the pump criterion nor the CPU
    delta could be measured (the ps sample predates the
    window). The subrect blit itself is in tree, container-
    gated, and unfalsified; its bench re-runs after AD-46's
    minimal fix lands.

    Closure: when the bench window
    observes at least one state_valid:true pump_diagnostic
    event under motion. That closes AD-43.2's deferred
    criterion and transitively closes AD-36 and AD-25.
    AD-43.3a's closure is no longer on the critical path
    for AD-36 closure; it stays open as a latent issue
    awaiting reproduction.

  - **AD-43.4 (GPU backend, separate)**: Not scoped
    under this entry; the existing Vulkan backend
    discussion is the durable home for (c).

#### Relationships

  - **Surfaced by AD-41.4** (the AD-41 bench
    verification). AD-41.3's wake source works; AD-43
    is a separate, independent cause of the same
    user-visible symptom.
  - **Blocks AD-36 closure.** AD-36's code change is
    in place but cannot be bench-verified at 0.2 Hz
    iteration rate.
  - **Blocks AD-25 closure** via AD-36.
  - **Affects AD-32 / AD-37** (busy-spin
    investigation). The lldb stack identifies the spin
    site precisely (`composite -> render -> fillRect ->
    writePixel`) which is much more actionable than
    the previous bench data was. AD-32 / AD-37 should
    update their framing to point at AD-43; the busy
    spin observed on bench was always primarily this,
    not whatever AD-32 / AD-37 originally hypothesised.

#### Filing trace

  - 2026-05-27 morning: surfaced during AD-41.4 bench
    verification. lldb userspace backtrace, procstat
    `<running>` stack samples, and dmesg framebuffer
    geometry captured in the filing.
  - 2026-05-27 afternoon: AD-43.1 landed (commit 3fb055d;
    follow-up a12dc33 for the test-only struct literal).
    fillRect fast-path verified by unit tests (3 new tests,
    all 12 inline tests pass) and by lldb sampling (1/10
    samples in fillRect tail, 0/10 in writePixel inner
    loop, vs 3/3 deep in writePixel pre-AD-43.1).
  - 2026-05-27 afternoon: AD-43.2 bench run. The fillRect
    bottleneck moved; the new dominant cost is
    `DRAWFSGIOC_BLIT_TO_EFIFB` (6/10 lldb samples) plus
    the underlying question of why composite is being
    called continuously. AD-43.3 was sketched as "if
    needed"; the bench evidence makes it required. AD-43.3
    was refined to enumerate AD-43.3a (compose-gate audit)
    and AD-43.3b (subrect blit) as the two layered next
    steps.
  - 2026-05-27 evening: AD-43.3a's gate instrumentation
    landed (commit 3991931, UTF_COMPOSITE_GATE_INSTRUMENT
    enabled in the s6 run script). Bench captures after
    reboot show the symptom did not reproduce; the new
    daemon session is healthy with the scheduler oscillating
    correctly and frame_complete events firing at ~45 fps
    total. AD-43.3a moved to "blocked on reproduction"
    status; AD-43.3b promoted to active. The AD-43.2
    bench's pathological state (zero log emission for 88
    seconds despite 99 percent CPU) remains unexplained.
    See "Update 2026-05-27 evening" below for the
    detailed reasoning.

#### Update 2026-05-27

The AD-43 entry now records two distinct bottlenecks that
were never visible in the same lldb sampling pass because
the first one masked the second:

  - **Pre-AD-43.1**: fillRect inner loop, per-pixel
    writePixel calls. 100 percent of CPU went here on the
    bench. Resolved by AD-43.1.
  - **Post-AD-43.1 (AD-43.2 bench, session
    `16d3d9453307a617`)**: DRAWFSGIOC_BLIT_TO_EFIFB ioctl,
    daemon at 99 percent CPU, zero log emission for 88
    seconds. This was hypothesised to be
    damage_tracker/scheduler logic spinning unnecessarily,
    and AD-43.3a was filed to investigate. AD-43.3a's
    diagnostic instrumentation (commit 3991931) landed but
    the symptom did not reproduce; see the 2026-05-27
    evening update below.

AD-36 / AD-25 remain bench-blocked. After the evening
investigation the blocker is now AD-43.3b (subrect blit),
not AD-43.3 generally.

The pattern is worth noting for future bench work: a
single perf bottleneck removal often exposes the next
layer. Three layers of fixing may yet land here before
the bench window observes a `state_valid:true` pump
event. The blit-and-compose path is well-understood
and the diagnosis is concrete.

#### Update 2026-05-27 evening

After the gate instrumentation landed, two bench captures
were taken with the new daemon (session
`8e8d6e77f7e9b71d`). The captures showed healthy behaviour:

  - Frame_complete events at ~45 fps total across two
    surfaces (cursor + pgsd-sessiond UI).
  - composite_gate_diagnostic tuple distribution roughly
    25 percent (false, false), 60 percent (true, false), 15
    percent (true, true). The (true, true) entries are
    immediately followed by frame_complete events; the
    scheduler is correctly gating composite on the deadline.
  - All pump_diagnostic events show state_valid:false
    because no cursor motion was harvested in the bench
    window; that is consistent with no input, not a bug.
  - Daemon still at 99 percent CPU. That CPU is now
    understood as the legitimate cost of two software-
    composited surfaces at 4K, each producing a full
    33 MB BLIT_TO_EFIFB per frame.

The original AD-43.3a hypothesis ("damage_tracker /
scheduler is spinning on every iteration") was wrong about
the current system. Whether it was wrong about the earlier
daemon (session `16d3d9453307a617`) cannot be determined
because that session ended.

What we did learn from the bench data:

  - The composite + blit work is *expensive*, not
    *spurious*. Even when the scheduler does its job
    correctly, 45 fps of full-screen 4K software composite
    saturates one CPU. The fix is not to call composite
    less often; the fix is to make each composite cheaper.
  - AD-43.3b (subrect blit) addresses exactly that.
    Reducing each blit's region from 3840 x 2160 to the
    actual damage rect shrinks the kernel-side copyin /
    memcpy proportionally. Most composites only need a
    small damage rect (cursor movement, single character
    typed, blink toggle); the bandwidth saving compounds
    across the 45 fps rate.
  - AD-43.3a is parked. The gate instrumentation stays
    enabled in case the spin recurs; if it does, the
    composite_gate_diagnostic events captured during the
    stall will give us the data we wanted today.

Pivot: AD-43.3b is the active next step. AD-43.3a is open
but blocked on reproduction. AD-43 header status string
updated accordingly.

#### Closure record (2026-06-06)

Filed on a tone hang that turned out to be argument-order
confusion (seconds-first; recorded above), but the filing led
straight to the real defect: the engine loop died permanently on
one device write error with no reopen path. Closed on the
operator's directive, implemented as the reconnecting device
layer (real to null sink and back), and verified on every line:
degraded service with clean silent client completion, reconnect
without restart, startup defense covered by the two-layer module
autoload architecture, and all four F.5 production suites green
against the new build with ear checks confirmed. One same-day
arc, filing to closure.

## `semainput`: input daemon

evdev device discovery, classification and fingerprinting, logical
identity aggregation, pointer smoothing, gesture recognition.

### `[x]` I-1: Unified Event Log Schema Adoption  *(Done, Small; depends: S-2, S-3)*

`emitSemanticEvent` and `emitGestureEvent` include `subsystem`,
`session`, `seq`, `ts_wall_ns`, and (initially null) `ts_audio_samples`.
`seq` increments monotonically across all event types. `jq` parses the
stream without errors.

### `[x]` I-2: Keyboard Event Passthrough  *(Done, Small; depends: I-1)*

Keyboard discovery verified; `KEY_*` evdev events translate to
`key_down`/`key_up`; key-repeat suppression (evdev `value=2` ignored);
`identity_snapshot` includes `has_keyboard` per logical device.

### `[x]` I-3: Audio Clock Timestamping  *(Done, Small; depends: S-4, I-1)*

`ClockReader` opened at startup against `/var/run/sema/clock`;
`ts_audio_samples` populated at event emission time when
`clock_valid == 1`, null otherwise. Clock-reader failure is non-fatal.

### `[x]` I-4: Gesture Tuning: Pinch Scale Factor  *(Done, Small)*

`scale_factor = cur_distance / prev_distance` added to `pinch_begin`
and `pinch` events as f32. The `delta` formula recalibrated to
`sqrt(cur²) - sqrt(prev²)`. Backward-compatible `delta` and
`scale_hint` retained.

---

## `chronofs`: temporal coordination layer

Clock, event streams, resolver, audio-driven frame scheduler, diagnostic
tool. All items below are complete; chronofs is the working realisation
of the `docs/Thoughts.md` design.

### `[x]` C-1: Clock Module  *(Done, Small; depends: S-4)*

`chronofs/src/clock.zig` wraps `shared.clock.ClockReader` with `now()`,
`isValid()`, `toNs()`, `sampleRate()`. `MockClock` for deterministic
tests.

### `[x]` C-2: Event Stream Buffers  *(Done, Medium; depends: C-1)*

`EventStream(T, capacity)` generic ring buffer with thread-safe
`append`, `query(t_start, t_end)`, `at(t)`, `latest()`. `DomainStreams`
owns one per domain (audio/visual/input). Event payload types defined:
`AudioEvent`, `VisualEvent`, `InputEvent`.

### `[x]` C-3: Resolver  *(Done, Medium; depends: C-2)*

`Resolver` with `resolveVisual`/`resolveInput`/`resolveAudio`/
`currentTime`. JSON-lines ingest helpers per subsystem
(`ingestSemaaudLine`, `ingestSemainputLine`, `ingestSemadrawLine`).
Ingestion driver spawns a thread per subsystem reading a pipe.

### `[x]` C-4: Audio-Driven Frame Scheduler Integration  *(Done, Medium; depends: C-3, D-3)*

`ChronofsClockSource` adapts `chronofs.Clock` to the `ClockSource`
interface. `nextFrameTarget(clock, refresh_rate_hz)` computes the next
sample-aligned frame boundary (800 samples at 48kHz/60Hz). Frames are
rendered at the target position, not the current one. `ts_audio_samples`
in `frame_complete` events derives from the same counter, drift-free
AV synchronisation by construction.

### `[x]` C-5: `chrono_dump` Diagnostic Tool  *(Done, Small; depends: C-3)*

Live timeline view; `--drift` computes frame-vs-audio-position deltas;
`--replay <file>` reads a recorded log and prints resolved state at
1000-sample intervals. Drift during steady-state playback < 1 frame
period.

---

## DRM-optional build system

Makes the DRM/KMS path a strictly opt-in feature while preserving the
swap-backed default as the unbreakable invariant.

### `[x]` B1.1: `configure.sh` DRM checklist item  *(Done)*

Adds `drawfs_drm` to the bsddialog checklist (default off), writes
`DRAWFS_DRM=true|false` to `.config`.

### `[x]` B1.2: `build.sh` reads DRAWFS_DRM  *(Done)*

Exports `DRAWFS_DRM` from `.config` to the environment so
`drawfs/build.sh` and any nested make(1) invocations see it.

### `[x]` B1.3: `install.sh` propagates DRAWFS_DRM  *(Done)*

Reads `.config` before the kernel build so `drawfs/build.sh` inherits
the flag via environment.

### `[x]` B1.4: `drawfs/build.sh` honors DRAWFS_DRM  *(Done)*

Translates `DRAWFS_DRM=true` into `DRAWFS_DRM_ENABLED=1` on the
`make(1)` command line for both the dev and modules kernel builds.

### `[x]` B1.5: Kernel Makefile conditional  *(Done)*

Both `sys/dev/drawfs/Makefile` and `sys/modules/drawfs/Makefile` guard
`drawfs_drm.c` and `-DDRAWFS_DRM_ENABLED` behind
`.if defined(DRAWFS_DRM_ENABLED)`. Default builds produce a
`drawfs.ko` with zero DRM references.

### `[x]` B2.1: `hw.drawfs.backend` sysctl  *(Already implemented; drawfs.c:1164)*

Defaults to `"swap"`, 16-byte string, `CTLFLAG_RW`.

### `[x]` B2.2: DRM init fallback-to-swap  *(Already implemented; drawfs.c:1189)*

`MOD_LOAD` calls `drawfs_drm_init()` only when backend is `"drm"`.
Failure logs a warning and resets the sysctl to `"swap"`. Broken drm
drivers cannot prevent `drawfs.ko` from loading.

### `[x]` B2.3: Regression test for `hw.drawfs.backend`

`drawfs/tests/test_backend_sysctl.py`. Asserts the sysctl exists,
defaults to `"swap"`, is read/write, and round-trips both `"swap"` and
`"drm"` as plain strings. Protects invariants 2.2, 3, and 4 above.

### `[x]` B4.1–B4.4 OS detection  *(Done; simplified for FreeBSD-only target)*

`scripts/detect-os.sh` exports `UTF_OS` and `UTF_OS_VERSION` by
checking `uname -s`. `configure.sh` records them in `.config` and
tailors the drm-kmod advisory. `build.sh` re-detects at build time
and warns on a host mismatch. `install.sh` and `drawfs/build.sh`
inherit or re-detect. The original implementation distinguished
multiple BSD variants; with PGSD-on-FreeBSD as the single target,
the detection collapsed to FreeBSD-versus-unknown.

### `[x]` B5.1: README "Graphics Backends" section  *(Done)*
### `[x]` B5.2: Consolidated root `BACKLOG.md`  *(Done, this file)*

### `[x]` B5.3: Cross-link from `drawfs/docs/ROADMAP.md`  *(Done)*

`drawfs/docs/ROADMAP.md` now carries a blockquote at the top pointing
at this file as the source of truth for task tracking, and its
bottom-of-file `## Backlog` section has been removed. The surviving
"Remaining" item (WITNESS debug-kernel verification) was migrated to
DF-4 above.

---

## Deferred

### `[x]` B3.1: Design `DRAWFS_REQ_SURFACE_PRESENT_REGION`  *(Done)*

Opcode assignment, wire format, semantics, error conditions, backward-
compatibility analysis, and design-alternatives writeup. Full spec lives
at `drawfs/docs/DESIGN-surface-present-region.md`. Key choices:

- New opcode `0x0023` with reply `0x8023` and event `0x9003`, rather
  than extending `SURFACE_PRESENT` (0x0022) via its reserved `flags`
  field. Preserves the fixed-size invariant of the existing struct.
- New shared `drawfs_rect` type (16 bytes).
- `DRAWFS_MAX_PRESENT_RECTS = 16` as a protocol-level cap.
- Server-side coalescing controlled by a 75% area threshold
  (`hw.drawfs.region_coalesce_threshold`).
- Clients are free to receive `EVT_SURFACE_PRESENTED_REGION` even for
  requests made via the old opcode (server-side flexibility).

Implementation (B3.2–B3.5) remains deferred pending sprint scheduling.

### `[x]` B3.2: Protocol constants and struct headers  *(Done; depends: B3.1)*

Three entries added to `shared/protocol_constants.json`
(`REQ_SURFACE_PRESENT_REGION = 0x0023`,
`RPL_SURFACE_PRESENT_REGION = 0x8023`,
`EVT_SURFACE_PRESENTED_REGION = 0x9003`). Headers regenerated by
`shared/tools/gen_constants.py`, no generator changes needed. Struct
definitions (`drawfs_rect`, request, reply, event) hand-added to
`drawfs_proto.h` outside the sentinel blocks. `DRAWFS_MAX_PRESENT_RECTS
= 16` defined. Python test helpers in `drawfs/tests/drawfs_test.py`
updated with matching constants. Struct sizes verified by compile:
`drawfs_rect` 16 B, request header 24 B, reply 16 B, event header 16 B.
A pre-existing cosmetic drift on `EVT_POINTER`'s description was fixed
as a side effect of running the generator.

## NDE: Native Desktop Environment

NDE is the policy and user experience layer above semadraw and drawfs.
It lives at https://github.com/pgsdf/NDE and defines versioned contracts
for windowing policy, input, settings, session management, and
compatibility. NDE does not redefine kernel graphics transport or
semantic rendering; those remain the responsibility of drawfs and
semadraw respectively.

NDE Milestone 0 (vocabulary freeze, charter, design specification,
repository skeleton) is complete. The items below correspond to NDE
Milestone 1 (substrate validation) and beyond.

**Relationship to LT-1 through LT-3.** NDE is usable today without
the long-term Quartz equivalent items; it can manage semadraw-term
sessions and basic SDCS applications using the current immediate-mode
rendering model. LT-1 (layer tree) would make NDE's own UI smoother
and enable proper animated transitions. LT-3 (GNUstep backend) would
make GNUstep applications first-class NDE citizens without X11.

### `[x]` NDE-4: Session Manager  *(Superseded 2026-05-10 by SM-1)*

**Superseded by SM-1** (`pgsd-sessiond/docs/adr/0001-design.md`).

Session management was originally scoped here as a sub-item of NDE
under the assumption that startup sequencing and lifecycle handling
were a desktop-internal concern coupled to the NDE architecture.
The 2026-05-10 working session re-evaluated that framing and
established session management as a desktop-agnostic concern, with
its own track (SM) and its own daemon (`pgsd-sessiond`). The new
design is graphical login via PAM (Option Y), system-wide semadrawd
with per-user clients, and session types as first-class via
`.session` files. NDE provides one such session type when present;
it is not a precondition.

The original NDE-4 scope (rc.d ordering, application crash restart,
clean shutdown) is partially absorbed into SM-1 (lifecycle hooks
via PAM `pam_open_session` / `pam_close_session`) and partially
remains under NDE (per-application crash restart for NDE-managed
windows). The NDE side has no current item; it can be opened as
NDE-4-rev2 if it becomes load-bearing.

See SM-1 entry below and `docs/sessions/2026-05-10.md` for the
full discussion.

## SM: Session Management

SM is the PGSD distribution layer's session-management track,
covering authentication, login, session lifecycle, and related
concerns. It is desktop-agnostic by design: SM components do not
depend on NDE, do not encode NDE-specific behaviour, and could in
principle be reused by a different distribution built on UTF.

The track was opened on 2026-05-10 to replace the original NDE-4
"Session Manager" entry, which conflated session management with
desktop work. See `docs/sessions/2026-05-10.md` for the
architectural reasoning and `pgsd-sessiond/docs/adr/0001-design.md`
for the SM-1 design.

The `pgsd-` prefix marks distribution-layer components, distinct
from UTF userland's `sema-` prefix. UTF has stable substrate
contracts; PGSD is one set of choices on top of those contracts.

### `[x]` SM-1: `pgsd-sessiond` graphical login daemon  *(Done 2026-05-17; Stages 1-9 landed, clean display via AD-39, multi-cold-boot verified)*

**Depends on**: AD-31 (semadrawd multi-user refactor, done).
The clean-display prerequisite for stage 9 was originally
tracked as AD-10; **AD-39 (2026-05-13/14) superseded AD-10
and structurally solved it** by removing vt(4)/vt_efifb from
the PGSD kernel, so there is no vt(4) overdraw to wait on.
SM-1 no longer depends on AD-10 (superseded) for anything.
Stages 1-8 have no substrate prerequisites and may proceed
against the current bench.
**Tracks**: `pgsd-sessiond/docs/adr/0001-design.md`.

**Status (2026-05-17): DONE.** All nine implementation stages
have landed and pgsd-sessiond boots to a working,
keyboard-live graphical login on a PGSD-kernel bench. The
visual-cleanliness blocker (vt(4) and drawfs both drawing
the EFI framebuffer) is resolved structurally by AD-39: a
PGSD kernel has no in-tree console driver, so there is no
console overdraw - drawfs owns the framebuffer exclusively
once drawfs.ko loads. The final gate - multi-cold-boot
verification, since the inputfs-ring startup-race fix
(5e17071) had only been confirmed working once - is now
**closed**: the operator cold-booted and logged in
successfully several times with no discrepancies (reported
2026-05-17). "Keyboard-live on every cold boot" is
confirmed; the retry latches deterministically as designed.
No code, no AD-10 work, and no verification remains; the
loader.conf/AD-10.2 path is obsolete (see the superseded
AD-10 entry and the AD-39 entry). Input, auth, session
launch, the session loop, and the power menu all work. See
the per-sub-stage SHAs below
and `docs/sessions/2026-05-16.md` for the boot-integration
debugging history.

Two implementation deviations from the ADR's stage wording,
both deliberate and documented at their commits:

  - **Stage 8** shipped as a keyboard-invoked power *menu*
    (Ctrl-Q opens a centered Shutdown/Restart/Suspend overlay
    with confirmation), not inline corner *buttons* as the ADR
    text says. v1 has no pointer hit-testing for inline
    buttons; the menu is the v1 realisation of the same
    requirement. Documented in commit 5b802c7.
  - **Stage 9** "boot integration" required two follow-on
    fixes beyond the stage commit before it actually worked at
    cold boot: an install.sh kldstat-predicate correction
    (451b642) and a semadrawd inputfs-ring startup-race retry
    (5e17071). The stage commit alone (bb0588e) installed the
    s6 wiring but the login was keyboard-dead at boot until
    those two landed. See the session memo.

A privileged system service that authenticates users via PAM and
launches per-user UTF sessions. Replaces vt(4)'s `getty` / `login`
pair as the normal login path on PGSD systems, with vt(4) retained
in the kernel as a recovery / single-user fallback only.

Architecture: system-wide semadrawd serves all users via per-uid
surface namespacing; `pgsd-sessiond` runs as a privileged client
with high-z-order surfaces; on successful auth, the daemon
`setuid`s to the authenticated user and execs that user's chosen
session leader from `/usr/local/share/pgsd/sessions/*.session`.

Authentication uses `pam_unix` against `/etc/master.passwd` by
default. User enumeration is `UID > 1000` with shell in
`/etc/shells`. Per-user attributes (display name, default
session, capability flags, age bracket) live in
`/etc/utf/users/<name>.conf`. Login UI ships with shutdown
buttons and a session picker; no avatars in v1.

The ADR documents nine implementation stages, the first eight of
which had no substrate prerequisites (AD-31 is done; the
stage-9 clean-display prerequisite was AD-10, superseded by
AD-39). Each stage produces
a bench-testable artefact:

  - `[x]` SM-1.1: PAM scaffolding (CLI tool).  *(922edca)*
  - `[x]` SM-1.2: User enumeration and attribute file reader.
    *(f34ff18)*
  - `[x]` SM-1.3: Session leader exec path.  *(3b57df6)*
  - `[x]` SM-1.4: `.session` file enumeration and parsing.
    *(3b9ce3d; build fix 60dbbaa)*
  - `[x]` SM-1.5: Login UI minimal version (no password yet).
    *(f8e0748)*
  - `[x]` SM-1.6: Login UI password entry and auth integration.
    *(a652aa1; build fix 155caeb)*
  - `[x]` SM-1.7: Login UI session picker dropdown.  *(c494844)*
  - `[x]` SM-1.8: Login UI shutdown / restart / suspend.
    Shipped as a keyboard-invoked power menu, not inline
    buttons (v1 has no pointer hit-testing); same requirement,
    different realisation.  *(5b802c7)*
  - `[x]` SM-1.9: Boot integration. Depends on AD-31 (done);
    the clean-display prerequisite (was AD-10) is solved by
    AD-39 (vt(4) compiled out), not AD-10. s6 wiring landed
    bb0588e; sigaction build fix e89b00f; required two
    follow-on fixes to work at cold boot: kldstat predicate
    451b642 and inputfs-ring startup-race retry 5e17071.

See the ADR for the full design and the Consequences section's
list of items that are explicitly out of v1 scope.

### `[x]` SM-4: sessiond redraws the full scene 30 times a second forever  *(CLOSED 2026-06-06, operator-ratified; filed, diagnosed, ruled, implemented, and bench-green the same day)*

**Evidence** (compositor census, 2026-06-06): at a hands-off
login screen the compositor sees ~60 frame_completes/s split
across two surfaces (sessiond at ~30/s, exactly TARGET_FPS,
plus the cursor surface), idle damage 52 percent, and the main
loop paced at ~120/s by sessiond's client traffic. This
continuous stream was also the perpetual fuel for the AD-32
poll spin (the PRESENTED events that held POLLIN high were
sessiond's own presents) and is the confound that makes
"idle" unmeasurable for AD-25's rounds.

**Diagnosis** (code-confirmed): main.zig's inner loop runs an
UNCONDITIONAL encoder.reset, ui.draw, finishBytesWithHeader,
attachAndCommit on every pass at TARGET_FPS=30 (ui.zig:116),
shipping the full SDCS scene (the ledgered ~186 KB) whether or
not anything changed. The only animated element in the entire
UI is the caret: ui.zig:1517 derives blink_phase from the frame
counter (flips every 0.5 s), the caret draws only on the active
field, and before the first keystroke it does not blink at all
(show_cursor = !typing_started or phase == 0). handleAction's
own comment concedes the design: "the cursor blink redraws
every frame anyway". The UI's legitimate redraw demand is
therefore: ~0/s before typing, 2/s while a caret blinks, plus
event-driven changes (input actions, network string
replacement, auth-state transitions).

**Acceptance criteria**:
  1. Hands-off login screen before any keystroke: sessiond
     commits ~0/s (network-refresh commits only when the
     string actually changes).
  2. Caret blinking on an active field: commits at 2/s.
  3. Pointer motion causing no UI state change: zero sessiond
     commits (kills the 186 KB-per-pointer-event waste; the
     cursor is semadrawd's surface, not sessiond's concern).
  4. Compositor census at idle: composites bounded to cursor
     plus blink, loop iterations at last near the documented
     poll-timeout 10/s.
  5. No visual regression: blink correct after typing starts,
     network updates render, submitting status renders, power
     menu and picker unaffected.

**Fix fork, for ruling**:
  (a) Dirty-flag gating, loop cadence kept: a needs_redraw flag
      set by the first frame, any state-mutating event in
      drainUiEvents, a maybeRefreshNetwork that returns
      changed (it already computes equality), auth-state
      transitions, and time-based blink phase flips (only when
      a caret is actually drawn: active field and
      typing_started). Render-encode-commit runs only when the
      flag is set; the 30 Hz wakeup itself remains (cheap
      timestamp checks, no draw, no traffic). draw()'s frame
      parameter becomes a blink phase computed from wall time.
      Smallest correct change; the waste was the
      render-commit-composite chain, not the wakeup.
  (b) Fully event-driven: block in poll on the connection fd
      with a timeout to the next blink flip. Maximal; correct
      long-term shape, but restructures drainUiEvents and the
      connection layer, and belongs to the LT-2 animation-
      engine era when a frame clock exists to integrate with.
  Recommendation: (a) now, (b) recorded as the LT-2-era shape.

RULED by the operator 2026-06-06: option (a). IMPLEMENTED same
day:
  - main.zig: needs_redraw flag, set by the first frame, key
    events (drainUiEvents gains a dirty out-parameter; only
    .key events qualify, since frame_complete arrives for every
    commit we make and counting it would turn the flag into a
    self-sustaining redraw loop, and pointer events never reach
    handleEvent), network string replacement
    (maybeRefreshNetwork now returns changed), entry into the
    submission block (any outcome changes visible state), and
    wall-clock blink phase flips gated on typing_started. The
    render-encode-commit chain runs only under the flag; the
    30 Hz wakeup remains (cheap timestamp checks, no traffic).
  - ui.zig: the caret blink is wall-clock phased
    (CURSOR_BLINK_MS=500, same period as the old 15-frames-at-
    30fps); draw() and drawField() take blink_phase instead of
    the frame counter, which is gone; the handleAction comment
    that conceded the old design is rewritten.
  Note: zig fmt will settle the indentation of the newly gated
  render block.

Status [~], bench owed:
  (1) hands-off login screen before any keystroke: 30 s of
      tail -F on the compositor log counting frame_complete,
      expect ~0 (acceptance 1);
  (2) type one character, hands off again: expect ~4/s of
      frame_complete (2 blink redraws/s times two scene
      surfaces; acceptance 2);
  (3) mouse motion without typing: completes rise with cursor
      composites and return to ~0 when hands come off,
      sessiond itself silent throughout (acceptance 3);
  (4) the compositor census: idle iterations at last near the
      documented poll-timeout cadence (acceptance 4);
  (5) visual and functional: caret solid before typing,
      blinking after, network text updates when the interface
      changes, full login end to end including a failed
      attempt's retry message (acceptance 5).

BENCH RESULTS (2026-06-06 16:34): acceptance 1 EXACT (0
frame_completes in 30 s hands-off; the login screen draws
nothing), acceptance 2 EXACT (120 in 30 s after one keystroke:
2 blink redraws/s times two surfaces), acceptance 3 met (census
idle 4.0/s composites, all blink; motion 11.8/s, bounded,
returning), acceptance 4 met in substance (idle composites
collapsed from 58/s to 4.0/s; the iteration leg is dark because
the instrument flags retired with AD-43; a one-off flag
re-export can measure it if wanted). The census script now
prints a note when the instrument is off so the zero iteration
rows cannot mislead.

DISCOVERY, cross-referenced to AD-25: the operator reports the
POINTER no longer flickers and "appears solid most of the
time". Mechanism: thirty full-surface commits per second meant
constant whole-screen damage, and every composite repainted the
region under the pointer; the alternation between background
blit and cursor redraw WAS the flicker. With sessiond silent
the pointer sits composited and untouched. Part of AD-25's
cursor-smoothness symptom set was therefore sessiond-induced;
the residual flicker (at blink redraws and under motion) is the
true remainder for AD-25's rounds, which now run against a real
baseline.

ACCEPTANCE 5 CONFIRMED (2026-06-06, operator: "works as
expected"): failed-attempt retry message renders, successful
login launches the session, caret solid before typing and
blinking after. All five acceptance criteria are met.

PROPOSED: CLOSE SM-4. The login screen now draws nothing when
nothing changes (0 commits hands-off), 2/s while a caret
blinks, and event-driven otherwise; the compositor's idle
collapsed from 58 to 4 composites/s; the pointer flicker that
was sessiond-induced is gone, shrinking AD-25's symptom set;
and the desktop has the verified idle state the ratified
sequence requires before AD-25's rounds. On ratification the
entry moves to BACKLOG-history.

#### Closure record (2026-06-06)

The ledgered census candidate became a same-day arc. Diagnosis:
an unconditional render-encode-commit at TARGET_FPS=30 against a
UI whose only animation is one caret. Fix (ruled option a):
redraws gated on actual change, with the blink wall-clock phased
and the dirty signal sourced from key events only. Bench: 0
commits hands-off, 120-on-the-digit after a keystroke, idle
composites 58/s to 4/s, all five acceptance criteria met. Side
discovery: the pointer flicker was sessiond-induced whole-screen
damage and is gone, shrinking AD-25's symptom set and giving its
rounds a real baseline. The desktop now has a verified idle
state, the precondition the ratified sequence placed before
AD-25.

### `[x]` AD-50: deployed semasound slot ran semadrawd; flap giveup downed the real slot for five hours  *(CLOSED 2026-06-07, operator-ratified; filed, decoded, and recovered the same evening)*

The day's AD-38 instrumentation hunt, three scripts and a
dozen probes of zeros, resolved into one deployed-state fact:
/var/service/utf/semasound/run was semadrawd's run script
(the repo copy is clean, verified against the operator's
uploaded tree, so the corruption is deploy-side only; the
file's mtime, probe issued, timestamps the write). The 13:31
event decoded line by line from the finish logging deployed
twelve hours earlier: the healthy semadrawd TERM'd at
13:31:08 (signal 15, lifetime 1485 s); the semasound slot
respawned at 13:31:10 (pinned by leg 1's lifetime arithmetic
from the 14:04 bench) into the corrupt run, and its semadrawd
won the socket and /dev/draw; the real semadrawd slot's five
respawns exited 1 against the bind conflict inside three
seconds; flap protection counted five fast crashes and gave
up, CORRECTLY, its first live firing an exemplary one against
an unwinnable loop. Consequences carried silently all
afternoon: the desktop ran on a semadrawd supervised by the
semasound slot (pid 4913, the survivor of the flap bench's
leg 3 bounce, meaning that bench bounced the live compositor
four times); the real semasound never ran after 13:31 (audio
silently absent); and every probe and capture of the AD-38
hunt edited and restarted the semadrawd slot, a corpse, while
the live daemon never saw an armed environment.

Lessons, each owed follow-through: (1) svstat output must be
READ AND GATED ON, not printed past, twice today the answer
sat in unexamined output (the arm-verify script's link 0; the
tail -3 class before it); (2) bench scripts that bounce a
service should verify the slot's process identity first (one
pgrep under the supervisor pid), the flap bench TERM'd a
compositor four times believing it was bouncing audio;
(3) deploys into /var/service deserve a post-copy
verification line (exec target per slot); (4) this is AD-45's
first concrete exhibit (the deferred supervision evaluation):
slot content and process identity are unverified invariants
in the current architecture.

Recovery sequence issued and then encoded as
scripts/ad50-recover.sh (NEW), which practices the entry's own
lessons: the corrupt file's mtime is captured as evidence
before repair, every slot operation is verified by process
identity afterward (the binary under each supervisor pid),
and the final state is gated rather than printed past. Repair
from the repo copy, -t semasound to kill the usurper and
respawn real semasound, -u semadrawd into the freed socket,
one-instance check. Entry closes on the operator's green
paste. The exact keystroke vector that wrote semadrawd's run
into the semasound slot is unknown and may stay so; shell
history around 13:2x to 13:31 could settle it if the operator
cares to look.

SECOND CORRUPTION EVENT, DECODED (2026-06-07 19:29 recovery
attempt): the recovery script's repair gate aborted correctly,
the repaired file still exec'd semadrawd, because THE REPO's
s6/utf/semasound/run was itself corrupt, as an UNCOMMITTED
local modification (git status M, committed history clean,
diff stat 65 insertions over the 28-line file: semadrawd's run
wholesale). The operator's 19:14 git pull plus install.sh then
faithfully deployed the dirty tree, refreshing the deployed
corruption (mtime 19:14). The repo was provably clean at
~14:00 (the uploaded tar), so the 13:31 deployed-side write
and the later repo-side write are two separate strikes of the
same mistake class; cp with sema<TAB> resolving ambiguously
between semadrawd and semasound is the suspected shape, twice,
leaving no memory. Healing: git checkout of the file, a
whole-tree dirty check for sibling damage, recovery script
rerun. LESSON SHARPENED: install.sh is a proven
corruption-propagation vector for a dirty working tree; the
deploy-verification follow-through becomes concrete as (a) a
post-deploy exec-target check per slot in install.sh and (b) a
dirty-s6-tree warning at install start. The recovery script's
own verification gates are the reason this was caught at the
file stage rather than after another slot mismatch went live.

THE 19:14 INSTALL INVERTED THE TOPOLOGY (decoded from the
second recovery run, 19:42): the install's stop phase killed
the usurper (pid 4913), its start phase brought the REAL
semadrawd slot up first (up 1726 s at the run, since
19:14:02), real semadrawd won the socket, and the corrupt
semasound slot then crash-looped against it to giveup at
19:14:05, the mirror image of 13:31 with the slots' roles
reversed. The desktop has been on the correctly supervised
compositor since 19:14. The recovery script's -t fired at a
DOWN slot, a no-op that neither spawns nor clears giveup; the
script assumed the usurper still lived there and its gates
correctly refused to call the result success. The repair leg
succeeded from the now-clean repo. Remaining recovery is one
command, no desktop collapse: s6-svc -u the semasound slot.
Follow-through noted: the first aborted attempt's cp ran
before its verify (mtime 19:29, corrupt-over-corrupt,
harmless but backwards); repair steps verify the source
before writing the destination.

RECOVERY COMPLETE, BENCH GREEN (2026-06-07 19:5x): semasound
up under its own supervisor (pid 7436), semadrawd up under its
own (pid 7126, since 19:14), one instance each, and
semasound-tone produced a solid tone, the first sound since
13:31. The unprivileged AccessDenied on semasound-tone is
noted without filing: root-only audio-socket access is likely
the configured state, not a regression; it becomes an entry
only if unprivileged use is shown to have worked before.

PROPOSED: CLOSE AD-50. The incident is fully decoded end to
end: two corruption strikes of one mistake class (deployed
side at 13:31, repo side later, install propagating the
latter at 19:14), two flap giveups both correct, one topology
inversion by the 19:14 install, and a recovery whose gates
caught every wrong assumption including its own script's.
The four lessons stand as the entry's legacy, with three
concrete follow-through items (slot-identity guard in bench
scripts, post-deploy exec-target verification plus dirty-tree
warning in install.sh, verify-source-before-write in repair
steps) recorded for the board. On ratification the entry
moves to BACKLOG-history.

#### Closure record (2026-06-07)

Closed on the operator's green recovery: both daemons under
their own supervisors, one instance each, and audio's first
tone since 13:31 confirmed by ear. The entry archives the full
decode: two corruption strikes of one mistake class, two flap
giveups both correct (the machinery's first live firings, on
its first day of functioning), one topology inversion by the
19:14 install, and a recovery whose verification gates caught
every wrong assumption including its own script's. Three
follow-through items remain on the live board under the AD-50
lessons: slot-identity guards in bench scripts, post-deploy
exec-target verification plus a dirty-tree warning in
install.sh, and verify-source-before-write in repair steps.

### `[x]` AD-25: cursor motion smoothness  *(Open, Medium-Large; reframed 2026-05-10 after instrumentation; **UNBLOCKED 2026-06-05**: AD-43 resolved and AD-36 closed)*  *(RESOLVED 2026-06-07, operator-ratified)*

**Unblocked 2026-06-05, with a data caution.** The discovery
rounds below can now run on valid emission. Any instrumentation
dataset collected before the events.zig width fix, from a daemon
that had emitted 10,000 or more events, was silently truncated
at event 10,000 (see the AD-43 root-cause record); pre-fix
long-window datasets are suspect and re-collection is part of
the rounds, not an extra.

**Reframed 2026-05-10.** Instrumentation patch landed (the
`ad25_diagnostic` event emitted from
`semadraw/src/compositor/compositor.zig` per composite cycle
when `UTF_COMPOSITOR_INSTRUMENT=1` is set in semadrawd's
environment). Bench-collected with cursor in steady motion on
`pgsd-bare-metal-test-machine`. The original two hypotheses
below were both ruled out; the actual bottleneck lives
elsewhere. The original entry is preserved at the end of this
section for historical context.

**Discovery plan landed 2026-05-12** as
`semadraw/docs/adr/0007-ad25-cursor-motion-discovery-plan.md`.
The ADR commits to three instrumentation rounds: pump cadence
(U1), render-phase breakdown (U2), and a poll-timeout
experiment (U3), with explicit decision criteria for each.
Fix ADR(s) are deferred to 0008+ once round data is in hand.
This BACKLOG entry remains the operational tracker; ADR 0007
is the long-term record of the discovery framing.

**Round 1 findings recorded 2026-05-12.** Round 1
instrumentation landed in commit `6d670b9`
(`pump_diagnostic` event in `pumpCursorPosition`, gated on
`UTF_PUMP_INSTRUMENT=1`) and was bench-collected on
`pgsd-bare-metal-test-machine`. The captured 148 ms log
window (limited by current s6-log retention) showed 9,998
pump events at an average rate of **~67,500 events/second**
(14.8 us per pump), with **1 of 9,998 events reporting
`pos_changed:true`**.

This finding invalidates the ADR's original framing of
Round 1's question. The main loop is **not** paced by the
100 ms `posix.poll` timeout during cursor motion; the
`/dev/draw` pollable fd shows readable continuously while
inputfs is active, so the timeout never bites. The pump
rate of 67 kHz is bounded by per-iteration loop work, not
by any deliberate cadence floor. Composite cadence (still
~8.7 Hz per the 2026-05-10 bench) is gated by
`needsComposite()` returning false on the vast majority of
iterations, not by the loop being slow.

Round 2 redirects from "render-phase breakdown" to
**composite-gate instrumentation** per the ADR's
addendum. The 67 kHz busy-spin finding is broader than
AD-25 and has been opened as a separate track; see AD-32.
Round 1 instrumentation remains in the tree, gated on the
env var, for future regression checks.

**Round U1 ANSWERED 2026-06-07** (by AD-38's closure capture;
evidence tar on file): the main loop is STRICTLY poll-timeout
paced under active input. Inter-pump gaps during twenty seconds
of steady motion: min 100.9 ms, median 104, max 107.3, zero
early wakeups; the inputfs notify fd in the poll set never
fires while the event ring carries ~130 Hz of motion. Per-read
freshness is confirmed (pos_changed on 90% of motion-phase
reads, real coordinates), so AD-36's data path works and the
smoothness bottleneck is THE WAKEUP, not the data. The user
cost, measured: median 116 px, p90 197, max 621 per cursor
update. ROOT CAUSE FOUND IN SOURCE (2026-06-07 evening, same
session): the notify cdev's d_poll is edge-only by deliberate
design, always selrecord then return 0, never POLLIN. The
in-code comment documents why: an earlier level check on
writer_seq made the cdev permanently ready after the first
event (no read syscall to consume the level) and consumers
spun at max rate. The fix overcorrected into a cdev that can
NEVER deliver POLLIN through poll(2): selwakeup from a publish
interrupts the daemon's sleep, the kernel rescans by calling
each d_poll again, this d_poll returns 0 again by
construction, and the kernel resumes sleeping out the
remaining timeout. The measured gap histogram (min 100.9 ms,
max 107.3, zero early returns) is this mechanism to the
millisecond. The comment itself notes the kqueue path tracks
per-knote level correctly: the cdev works for kqueue consumers
and is decorative for poll consumers, and semadrawd polls.
Side finding: per ADR 0021 Decision 7 the wake fires
unconditionally per publish, so during motion the daemon is
woken and lulled back ~130 times per second, wasted
wakeup-rescan churn delivering zero information.

FIX FORK, operator's ruling requested (fix ADR per the
discovery plan's 0008+ once chosen):
  (a) kernel pending-bit: publish sets an atomic pending flag;
      d_poll returns POLLIN when pending and clears it
      (poll-consumes-edge, coalescing wake-hint semantics,
      correct for a seq-numbered ring). Clean long-term cdev
      contract; costs a module rebuild and a bare-metal reload
      cycle.
  (b) implement d_read, the conventional consume-by-read
      pattern; same kernel reload cost, more code.
  (c) daemon-side kqueue bridge: a kqueue fd with the notify
      fd registered EVFILT_READ EV_CLEAR, the kqueue fd itself
      added to the existing poll set (kqueue fds are
      pollable); POLLIN on it means drain kevent and run the
      input path. Zero kernel change, deployable with a normal
      install, uses the path the kernel already implements
      correctly, benchable immediately, and moves the loop
      toward the event-driven shape LT-2 records as the
      destination.
RECOMMENDATION: (c) now, with (a) noted as later kernel-side
cleanup so the cdev's poll interface stops being a trap for
future consumers (at minimum ADR 0021 and the cdev comment
must say "kqueue only" until then).

OPERATOR RULING (2026-06-07): (c) ratified, with (a) as the
later kernel-side cleanup and the kqueue-only documentation
note owed to ADR 0021 and the cdev comment in the interim.
Fix ADR drafted and accepted as semadraw ADR 0009
(0008 was already taken by the mmap-staleness direction):
docs/adr/0009-ad25-notify-kqueue-bridge.md records the
decision, the alternatives including the kernel pending-bit
as companion cleanup, the kqueue-only documentation debt to
ADR 0021 and the cdev comment, and the bench criteria (the
unchanged two-phase capture; motion heartbeat toward the
event rate, step distribution shrinking from the 116 px
median baseline, the census as the no-spin regression guard).
IMPLEMENTED (2026-06-07 evening, five files): the backend
(inputfs_input.zig) builds the bridge at init, best-effort
like the notify open itself (kqueue created, notify fd
registered EVFILT_READ EV_CLEAR, one boot line either way;
local ABI constants with a naming-drift note; failure falls
back to poll-timeout cadence), owns getWakeFd and drainWake
(a zero-timeout kevent consume; lost wake costs one timeout),
and closes the kqueue in deinit. The plumbing mirrors the
existing pattern: backend vtable gains optional
drainInputWake, drawfs implements both (getInputfsPollFdImpl
now returns the BRIDGE fd), the compositor wraps it. The main
loop's AD-41.3 comment is rewritten (its event-rate claim was
wrong for the design's entire life, falsified by U1's gap
histogram), the variable renamed input_wake_fd, and the
dispatch loop gains the wake fd's drain branch per the AD-32
rule, the branch whose absence would otherwise convert the
fix into a spin. Five pre-existing em dashes cleaned in the
touched backend file. Container cannot compile Zig: brace
balance verified on all five files; the operator's zig build
is the arbiter, then the unchanged two-phase capture is the
bench.

Documentation debt cleared (2026-06-07): the cdev's in-code
comment block now carries the KQUEUE ONLY warning with the
mechanism and the pending-bit cleanup pointer, and ADR 0021
gained an addendum recording the U1 measurement, the corrected
contract (consumers must use kqueue; a poll(2) consumer
observes nothing), and the reference to semadraw ADR 0009's
bridge pattern. Comment-and-docs only; no kernel rebuild
required for behaviour.

BRIDGE BENCH (2026-06-07 20:48, build clean, bridge boot line
present, evidence tar analyzed): the fix works and the numbers
moved like a real fix moves them. Idle unchanged (9.9/s
heartbeat, zero pos_changed, median gap 107 ms: no spin, the
EV_CLEAR coalescing held). Motion: loop rate 10/s to 45.7/s,
pos_changed 9/s to 38/s, and the step distribution collapsed
from median 116 px / p90 197 to MEDIAN 16 PX / p90 40. The gap
histogram is bimodal and each mode tells its story: median
8.0 ms, the full event rate of a 125 Hz mouse, the bridge
waking the loop on every publish; and 138 gaps of 100 to
107 ms, the loop going dead for a full timeout roughly seven
times a second while motion continues, about 5 to 6 fast wakes
per stall, the stalls accounting for some 14 of the 20
seconds. The kernel filter is exonerated by reading: kn_data
is the attach snapshot and never updates, f_event is
permanently true after the first publish, every KNOTE
reactivates the knote, so per-publish delivery is proven both
by code and by the 8 ms mode. THE STALLS ARE DAEMON-SIDE:
either the main poll truly slept (contradicting the filter
analysis) or the loop thread spent those 100 ms blocked in the
body, prime candidate the synchronous /dev/draw request/reply
chain doing composite work, the stall cadence sitting in the
historical composite-rate ballpark. This is ADR 0007's Round
U2, render-phase breakdown, returning home after its 2026-05
redirect: the wakeup is fixed and the render cost is the next
pacer. Probes issued: a 3 s truss under motion (the stall's
anatomy: main-poll timeout versus fd-5 block) and the
operator's perceptual datum (fluid with periodic hitches is
the histogram made flesh).

ROUND U2 MECHANISM (2026-06-07 21:xx, motion truss, 6297
lines in 5 s): the loop is WORK-PACED, not wakeup-stalled.
Main poll woken 521 times, timed out only 6; fd-5 render
replies prompt 750 of 750 with zero 5000 ms hangs; the bridge
fires (521 kevent drains, EV_CLEAR, fd-7 events delivered).
The pacer is per-composite cost: a 252 KB mmap plus several
munmaps EVERY FRAME (500 mmap, 1477 munmap in 5 s) around a
handful of synchronous /dev/draw write/poll/read round-trips
and a blit ioctl. The earlier capture's ~7/s of 100 ms stalls
did NOT reproduce here (6 timeouts in 5 s, healthier under
steadier motion), so the bimodal stall is motion-pattern
dependent and wants a timestamped truss to catch in the act;
it is a separate, smaller question than the dominant cost.
TWO FIX CANDIDATES for a U2 ADR (semadraw 0010): (a) a
persistent compositor scratch buffer to erase the per-frame
252 KB map/unmap churn (roughly 100 mmap and 300 munmap
syscalls/s plus page-table and TLB cost), the clean win
regardless of the stall; (b) batch or pipeline the per-frame
/dev/draw round-trips to cut the serial reply waits. Both
lower per-pass cost so the loop rate rises toward the event
rate the bridge already delivers. Outstanding: the operator's
perceptual datum, and a timestamped capture if the
motion-dependent stall is to be pinned rather than designed
around.

U2 ROOT AND FIX ADR (2026-06-07): the mmap/munmap churn is
traced to the daemon backing all allocation through
GeneralPurposeAllocator(.{}), which returns pages to the OS on
free, so per-frame transient allocations in the synchronous
render path (the makeFrame buffer per /dev/draw op and per-pass
scratch) re-map and unmap every frame. Fix accepted as semadraw
ADR 0010: a per-frame arena reset with retain_capacity at the
top of each loop pass, routing the render hot path's transients
through it while the GPA keeps startup and long-lived state, so
steady-state compositing maps nothing. The escape audit (ADR 0010's
mandated first step) was run and refined the fix: the hot path
has exactly one per-frame heap consumer (makeFrame in the
drawfs send path; events emit to stack, composite and loop
bodies allocate nothing per pass), strictly frame-local (reply
is a persistent-buffer slice, not an allocation). So the fix is
simpler than the proposed loop arena: a persistent inline
frame_buf [4096]u8 in the backend mirroring read_buf, fillFrame
writing into it, zero heap in the hot path. IMPLEMENTED in
drawfs.zig (ADR amended with the audit result); brace-balanced,
zig build is the arbiter.

DECISIVE BENCH (2026-06-07, post-ADR-0010 capture): the fix
did more than raise throughput, it collapsed the stall. Motion
loop rate 45.7/s to 121/s, pos_changed ~120/s (the full 125 Hz
event rate); gap median 8.0 ms with P90 8.0 ms (90% of wakes at
the event interval); stalls over 90 ms went from 138 to 7;
cursor steps median 19 px, p90 34, max 70 (max was 171 after
U1, 621 at the start). The reading: the 100 ms stalls WERE the
allocator churn (GPA per-frame mmap/munmap occasionally costing
~100 ms of page-table work), so removing it both raised the
rate and erased the stalls in one change. The serial /dev/draw
round-trips, named as the expected next pacer, did NOT bind:
the loop reached the event rate without them, so the deferred
batching ADR is likely unnecessary and U3's poll-timeout
experiment is moot (the loop is event-driven). Idle unchanged
(193 emissions, 107 ms median, zero pos_changed: no spin, no
regression).

PROPOSED: RESOLVE AD-25. The smoothness symptom that opened the
entry is gone, measured: 10 Hz / 116 px median strides at the
start of 2026-06-07, 120 Hz / 19 px at its end, across two
ratified fixes (ADR 0009 the kqueue wakeup bridge, ADR 0010 the
per-frame buffer). Round U1 (wakeup) and Round U2 (throughput)
are both resolved; U3 is moot. Closure owes only the operator's
perceptual confirmation and, for the mechanism record, a motion
truss showing steady-state mmap/munmap near zero (the outcome
already proves the fix; the truss confirms why) plus the census
as the no-spin no-leak guard. The 7 residual >90 ms stalls per
window (~0.35/s) are noted as negligible; reopen only if felt.

PERCEPTUAL CONFIRMATION (2026-06-07, operator): "It is smooth."
The histogram and the hand agree. On ratification the AD-25
chain closes to BACKLOG-history with its ADRs; the optional
mmap-near-zero motion truss remains available for the mechanism
record but is not a closure gate (the outcome and the feel both
prove the fix). Bench: a motion truss with
steady-state mmap/munmap near zero, the pump capture's motion
rate rising from the 45.7/s baseline, the census as no-spin
no-leak guard. The serial /dev/draw round-trips are the named
NEXT pacer, deferred to a follow-up ADR; the motion-dependent
100 ms stall remains the separate timestamped-truss question. Round U3's poll-timeout
experiment remains available as a control but is superseded
as a fix: the root cause is identified and the proper fix is
cheap.

**Round 2 findings recorded 2026-05-12.** Round 2
instrumentation landed in commit `b345984`
(`composite_gate_diagnostic` event from
`Compositor.needsComposite()`, gated on
`UTF_COMPOSITE_GATE_INSTRUMENT=1`) and was bench-collected on
`pgsd-bare-metal-test-machine` with both
`UTF_PUMP_INSTRUMENT=1` and `UTF_COMPOSITE_GATE_INSTRUMENT=1`
active. The captured 73.6 ms log window showed 9,998
needsComposite calls with the following gate-state
distribution:

  - `has_damage:true, should_composite:true`: 1 (0.01%)
  - `has_damage:true, should_composite:false`: 0
  - `has_damage:false, should_composite:true`: 7,291 (72.9%)
  - `has_damage:false, should_composite:false`: 2,706 (27.1%)
  - `state_valid:false`: 0

**Findings**: the FrameScheduler is not the gate
(`should_composite` returned true on 72.9% of calls). The
damage path is wired correctly (the 1 has_damage:true event
corresponds 1:1 with the 1 pos_changed:true pump_diagnostic
event from the same session). Composite is gated because the
pump observed `pos_changed:true` only once in 9,998 reads.

But: independent observation of inputfs's state region via
`inputdump state --watch --interval-ms 50` shows the
pointer position changing at ~130 Hz during the same bench
conditions; `inputdump events --stats` reports ≥204
events/sec on the event ring. The pump and inputdump are
both consumers of the same mmap'd state file, opened through
the same `StateReader` code path; yet they observe radically
different update rates.

This mmap-visibility question is opened as a separate track;
see AD-34. AD-25 stays open as the umbrella tracker; the
"cursor motion smoothness" symptom will not resolve until
AD-34's question is resolved (plus any follow-up). Round 2
instrumentation remains in the tree, gated on the env var,
for future regression checks.

#### What the instrumentation showed

Sample lines from `/var/log/utf/semadrawd/current` during steady
cursor motion:

    {"type":"ad25_diagnostic","frame":233,"clear_calls":6,
     "clear_px":3456,"clear_ns":119617,
     "full_entry":false,"full_clearpath":false,
     "surfaces_rendered":1,"render_ns":8088460}
    {"type":"ad25_diagnostic","frame":234,"clear_calls":2,
     "clear_px":1152,"clear_ns":35764,
     "full_entry":false,"full_clearpath":false,
     "surfaces_rendered":1,"render_ns":7817949}

Findings, in priority order:

  - `full_entry` and `full_clearpath` are `false` on every
    sampled frame. The compositor is not promoting to full
    repaint during cursor motion. **Hypothesis (a) below is
    ruled out.**
  - `clearRegion` cost is small. The 2-call frames spend
    ~35,500 ns total in `clearRegion` for 1152 pixels (~30
    ns/px, ~17.8 us per call). The 6-call frames spend ~120,000
    ns for 3456 pixels (the same per-pixel cost; the variation
    is in call count, not per-call cost). **Hypothesis (b)
    below is mostly ruled out as a cause of perceived
    unsmoothness.** A per-pixel optimization is real future
    work but would not move the needle on smoothness.
  - `render_ns` is the dominant per-frame cost. The render
    loop spends ~7,800,000 ns (~7.8 ms) per composite cycle to
    render a single surface. That is roughly 70x more
    expensive than the entire `clearRegion` work and consumes
    a large fraction of any reasonable per-frame budget.
  - Inter-frame gap is ~115 ms (~8.7 Hz). Consecutive
    `ad25_diagnostic` events' `ts_wall_ns` deltas land at
    ~114-115 million ns. At 8.7 Hz the cursor visibly steps
    rather than glides, regardless of clearRegion cost.
  - `clear_calls` cycles between 2, 4, and 6 per cycle. Two
    rects per cursor pump tick (old and new); when multiple
    pump ticks queue between composites, the rects accumulate
    (4 = two ticks queued, 6 = three). Confirms the pump is
    firing faster than the compositor is consuming.

#### Real bottleneck

Two issues compound, neither named in the original entry:

  - **Composite cadence is ~8.7 Hz.** Between consecutive
    composites, ~115 ms passes. At that cadence, the cursor
    visibly chunks. Whether this is the scheduler holding off
    composite, the cursor pump rate, or the render itself
    bounding the cadence, is not yet measured.
  - **Per-composite render cost is ~7.8 ms for one
    surface.** That single surface (a fullscreen
    `semadraw-term`) is being fully re-rendered every time
    the cursor moves a single pixel. The cursor's region
    damage propagates to the term as surface damage; the term
    re-renders its entire buffer; the compositor presents.
    7.8 ms on a 16.6 ms 60 Hz frame budget is ~47% of one
    frame; on a 9 ms 110 Hz budget that earlier
    `frame_complete` data showed, it is most of the frame. A
    per-character or per-region damage path inside
    `semadraw-term` would let small-region cursor motions
    skip the term's full re-render, which is probably the
    largest single win available.

These are both substantially larger pieces of work than "memcpy
the clear loop." The original Small-Medium estimate is
revised upward.

#### Open questions for the next diagnostic round

Before designing a fix, three measurements are still needed:

  - **Cursor pump cadence in isolation.** Instrument
    `pumpCursorPosition()` to log every invocation with
    timestamp and whether the position actually changed. If
    the pump fires at >=60 Hz but composite still runs at 9
    Hz, the scheduler is the bottleneck. If the pump itself
    fires at 9 Hz, the inputfs side is the bottleneck and
    AD-25 is misdiagnosed (the input substrate is slow, not
    the compositor). The `clear_calls` cycling between 2 and
    6 suggests the pump is faster than composite, but a
    direct measurement would confirm.
  - **Scheduler cadence.** What is `FrameScheduler` actually
    targeting and what does it return when asked? The 110
    Hz target seen in earlier `frame_complete` events versus
    the 8.7 Hz observed during cursor motion is suspicious;
    is the scheduler holding off composite while damage is
    pending?
  - **Render-cost breakdown.** Where in the render path do
    the 7.8 ms go? Is it SDCS interpretation, blit to
    framebuffer, font rasterization in the term's render
    cycle, or something else? A per-phase timing inside the
    backend's `render` would tell us whether the
    semadraw-term render fix is in the term itself or in the
    backend.

#### Revised estimate

**Medium-Large**, not Small-Medium. Both real bottlenecks
require design work:

  - Per-region damage inside `semadraw-term` so it can
    re-render only the cells the cursor's old/new rects
    intersect, not the whole buffer. Estimated own-ADR work,
    likely Medium.
  - Compositor scheduler review to understand the gap between
    target Hz and observed cadence. Possibly small if the
    cause is a single-line bug; possibly large if the
    scheduler model needs revision.

These two items may want their own BACKLOG entries (AD-25.1
and AD-25.2) once their scopes are clearer. AD-25 itself
remains Open as the umbrella tracking item until the
underlying work is enumerated and assigned.

#### Status note on the instrumentation patch

The instrumentation lives in
`semadraw/src/compositor/compositor.zig` (the
`UTF_COMPOSITOR_INSTRUMENT` env-var-gated path) and
`semadraw/src/daemon/events.zig` (the `emitAd25Diagnostic`
typed emitter). Zero runtime cost when the env var is unset.
The instrumentation is intended to remain in place until the
underlying issue is understood and fixed; remove only after
AD-25 closes.

---

**Original entry, preserved for historical context:**

Surfaced during AD-21 sub-item 9 verification: with the
region-damage fix in place, the cursor follows the pointer
correctly but motion is described as "not smooth." Two
candidate causes worth profiling before optimising:

(a) The fallback path firing more than expected. When a
backend doesn't implement `clearRegion`, the compositor
promotes to full repaint via `markFullRepaint()`, which clears
the entire framebuffer and re-renders every visible surface.
At 3840×2160, full repaint is expensive even for a 24×24
cursor move. drawfs and software backends both implement
`clearRegion`, so this should never fire on the bench — but
worth confirming with a `log.debug` count on the fallback
branch.

(b) Per-pixel loops in `clearRegionImpl`. Both backends
write pixels one at a time in a tight nested loop. For a
24×24 rect that's 576 pixel writes per region, two regions
per cursor move (old + new), so up to 1152 pixel writes per
move. At 60 Hz cursor motion that's ~70k pixel writes per
second — should be negligible, but worth measuring; on
slow EFI framebuffers the per-pixel loop may stall on
write-combine flushes or similar.

**Fix candidates** (after profiling identifies the actual
bottleneck):

  - Memcpy-based clear: precompute the row of background
    pixels once, memcpy that row across each scanline of
    the rect. ~3-5x speedup on x86-64 vs per-pixel loops.
  - Region damage rect coalescing: if the cursor moves twice
    within a composite cycle (rare but possible at >60Hz
    input rates), the pump emits four rects (two old, two
    new). Coalescing overlapping or adjacent rects into a
    single bounding rect would save clearRegion calls.
  - Surface-walk damage propagation: currently the pump
    walks all visible surfaces via `getCompositionOrder` on
    every cursor move. With many surfaces this is O(N×2);
    a spatial index would make it O(log N) but adds
    structure complexity.

Estimate **Small-Medium**: profiling + one of the above is
small; multiple of the above is medium. Defer until a user
reports the smoothness as an actual problem; the current
behaviour is correct.

#### Closure record (2026-06-07)

The cursor-motion symptom is gone, measured and felt: 10 Hz with
116 px median strides at the day's start, 120 Hz with 19 px steps
at its end, the operator confirming "it is smooth." Three ADRs
across the arc: 0008 (the AD-34 mmap-staleness data-path fix),
0009 (the kqueue wakeup bridge, after U1 found the loop strictly
poll-timeout paced because the notify cdev's edge-only d_poll
never delivered through poll(2)), and 0010 (the per-frame buffer,
after U2 found the loop work-paced by GPA mmap/munmap churn whose
~100 ms page-table stalls were the bimodal hitching; the audit
narrowed the fix to the single frame-local consumer). The serial
/dev/draw round-trips named as the next pacer did not bind and
U3 is moot. Residual: ~0.35 stalls/s over 90 ms, negligible,
reopen if felt. The optional mmap-near-zero mechanism truss was
left available but not required. The investigation method holds
as the entry's legacy: every theory falsified against
instrumented measurement (the stale-view 1-in-9998, the gap
histograms, the syscall tallies), the answer always in the data
before it was in a theory.

### `[x]` AD-34: pump's mmap view of inputfs state appears stale vs inputdump  *(RESOLVED 2026-06-07, operator-ratified; surfaced 2026-05-12)*

Surfaced by AD-25 Round 2 (ADR 0007 second addendum, commit
`b345984`). The cursor pump in semadrawd reads pointer state
from `/var/run/sema/input/state` via `mmap(MAP_SHARED,
PROT_READ)`. The pump fires at ~67 kHz; inputfs publishes
state updates at ≥130 Hz under continuous cursor motion (as
observed independently via `inputdump state --watch
--interval-ms 50`). The pump should therefore see a new
position on a meaningful fraction of reads. It does not.

#### Observation

Bench cycle on `pgsd-bare-metal-test-machine`, single
`semadraw-term --fullscreen` client, continuous cursor
motion for ~10 seconds, both `UTF_PUMP_INSTRUMENT=1` and
`UTF_COMPOSITE_GATE_INSTRUMENT=1` set. Captured window
(73.6 ms, log-rotation-limited):

  - `pump_diagnostic` events: 9,998.
  - `pos_changed:true` events: **1** (0.01%).
  - `state_valid:false`: 0.

Same bench, `inputdump state --watch --interval-ms 50`
observes the pointer position changing every 50 ms poll
across the full bench duration (~33 snapshots, all marked
"changed", pointer coordinates spanning x ∈ [1600, 3000],
y ∈ [800, 1600] across the 3840×2160 framebuffer).

The two consumers use the same `StateReader.init` path in
`shared/src/input.zig`: same mmap flags, same seqlock
discipline, same x/y offsets.

#### Implications

This is the *only* unresolved gate between AD-25's
"cursor motion smoothness" symptom and its resolution.
Round 2 ruled out all other candidates (clearRegion cost,
full-repaint, poll-timeout pacing, FrameScheduler gating,
damage propagation). If the pump saw position updates at
inputfs's actual publication rate (~130-200 Hz), composite
would fire at the same rate, and the smoothness complaint
would dissolve.

Whatever this is, it is also blocking AD-25 from closing.

#### Open questions

  - **What raw `ps.x, ps.y` values does the pump actually
    read across iterations?** The current pump_diagnostic
    event reports the *boolean result* of change detection
    but not the underlying values. Adding `ps.x, ps.y` to
    the event payload would directly answer "is the pump
    seeing the same value repeatedly, or different values
    that compare-equal somehow?"
  - **Is the mmap view consistent with the file content
    via `read(2)`?** A test that mmap's the state file and
    `read()`'s it simultaneously, comparing the two views,
    would distinguish "mmap pages are stale" from "the
    file's bytes are themselves stale."
  - **Does the pump need higher-precision pos_changed
    detection?** Current logic compares f32 surface
    positions against cached f32 values. The conversion
    `i32 → f32 → !=` is exact for integer pixel values
    within ±2^24, which the bench's 3840×2160 framebuffer
    is well inside. Not a likely cause, but listed for
    completeness.
  - **Is the kernel's `vn_rdwr` write of the state file
    coherent with userspace mmap reads at this rate?** The
    tmpfs vnode is the same VM object as the mmap; in
    principle writes should be visible immediately. If
    they are not (e.g., write goes through one cache layer
    while mmap reads go through another), this is the
    mechanism.

#### Findings (2026-05-12)

E1 instrumentation (commit applies this session) added raw
`ps.x, ps.y` fields to the `pump_diagnostic` event. Bench
cycle on `pgsd-bare-metal-test-machine` with continuous
cursor motion for ~10 seconds, both `UTF_PUMP_INSTRUMENT=1`
and the E1 patch active.

**Bench results**:

  - Total `pump_diagnostic` events: 39,992.
  - Unique `(ps_x, ps_y)` tuples among `state_valid=true`
    events: **1** (the value `(461, 273)`).
  - First and last tuples: identical, `(461, 273)`.
  - `state_valid=false`: 0.

The pump read the same value 39,991 times in a row during a
bench cycle where the cursor was visibly moving across the
3840×2160 framebuffer. The mmap view is fully stale: it
freezes at whatever value was published at mmap-open time
and never updates again.

**Cross-process probes** (same bench session):

  - `sudo inputdump state --watch --interval-ms 50` (running
    as **root**): sees pointer position change every poll,
    covering positions across the full framebuffer
    (x ∈ [1960, 3337], y ∈ [106, 1641]). Live state visible.
  - `sudo -u _semadraw inputdump state --watch --interval-ms 50`
    (running as the **`_semadraw` system user**, uid 1002,
    the same uid semadrawd runs as after privilege drop):
    sees only the initial `=== snapshot ===` block. No
    `=== changed ===` blocks fire during ~10 seconds of
    cursor motion. **Same staleness symptom as the pump.**
  - `sudo -u _semadraw xxd /var/run/sema/input/state` taken
    twice with a cursor move in between: **bytes differ**
    at the pointer x/y offsets and the last_seq offset.
    `_semadraw` can read fresh data via `read(2)` but not
    via `mmap(MAP_SHARED, PROT_READ)`.

**Root cause localised**: the staleness is specific to
**`mmap(MAP_SHARED, PROT_READ)` opened by a non-root group
member** against a tmpfs file that the kernel is writing via
`vn_rdwr(IO_SYNC)`. Root mmaps of the same file work
correctly. The same `_semadraw` process gets fresh content
via `read(2)` on the same fd; only mmap is affected.

**Ruled out by these findings**:

  - Pump-side bugs (f32 conversion, hotspot subtraction):
    the 1 unique tuple result means there's nothing to
    convert or subtract; raw integer bytes are identical
    across reads.
  - Inputfs not publishing: it is publishing, demonstrably,
    to anyone reading via `read(2)`.
  - Generic mmap staleness: it works for root.

**Standing question**: why does FreeBSD 15 tmpfs+`vn_rdwr`
not invalidate mmap pages held by a non-root credential
when it does for root? This is a kernel-side question for
which the answer requires reading tmpfs/vm internals. The
specific issue is recorded in `docs/FREEBSD_ISSUES.md`
("Issue #1: tmpfs mmap staleness for non-root group
members") for future reference.

**Implication for AD-25**: the "cursor motion smoothness"
symptom is fully explained. The pump cannot see fresh
positions; composite cannot fire on damage that wasn't
marked; damage cannot be marked because the change-detection
sees no change. The fix direction is now a design question,
not a measurement question; see **AD-35**.

#### Follow-up finding (2026-05-12, during AD-35 D1)

While drafting ADR 0008 to evaluate the three fix directions,
a probe of the event-ring file as `_semadraw` was run as a
sanity check (`sudo -u _semadraw inputdump events --watch
--interval-ms 50`). It returned **live pointer.motion events
streaming at ~110 events/sec, with absolute x/y coordinates
updating across the framebuffer**. The event ring uses the
same `mmap(MAP_SHARED, PROT_READ)` primitive against a
tmpfs file written by the same kernel kthread via
`vn_rdwr(IO_SYNC)` -- structurally identical to the state
region's broken read path -- yet works correctly for
`_semadraw`'s mmap.

This narrows the AD-34 localisation. The bug is not the
generic "tmpfs + mmap + non-root credential" combination as
originally characterised; it is that combination plus the
**access pattern of the state-region writes**. Two
candidate distinguishing factors:

  - The state region's writes always overwrite the same pages
    (whole-buffer rewrites of a ~5 KB region) on every sync.
    The event ring writes per-slot at varying offsets across
    a ~65 KB file, hitting different pages over time.
  - The state region is small enough (~5 KB) that a single
    write touches a small number of pages repeatedly. The
    ring is large enough that the bulk of writes land on
    pages that have not been recently touched.

The current best guess (not verified) is that
`vm_object_page_clean` or its equivalent is effective only
on pages freshly dirtied since the previous sync, and the
state-region's repeated rewrites of the same pages somehow
fail to mark those pages dirty in a way that invalidates
non-root mmaps.

AD-34 stays open as a kernel-side investigation track; the
narrower characterisation makes a future fix more
tractable. The UTF-side workaround chosen in ADR 0008
(Direction 2, event-ring consumption) avoids the broken
access pattern entirely and does not depend on the
kernel-side fix.

#### Next steps

A focused discovery round, narrower than AD-25's Round 2.
Likely sequence:

  - **E1 (instrumentation)**: extend the pump_diagnostic
    event with raw `ps.x, ps.y` values. Bench-collect.
    Determine whether the pump is reading stale identical
    values or reading varying values that the comparison
    misses.
    *Instrumentation landed 2026-05-12 (this commit); bench-
    collection pending. The `pump_diagnostic` event payload
    now includes `ps_x: i32` and `ps_y: i32` carrying the
    raw mmap-read coordinates. Activation is the existing
    `UTF_PUMP_INSTRUMENT=1` env var; no new gate.*
    **Findings recorded 2026-05-12**: 1 unique tuple in
    39,992 events; mmap is fully stale. Cross-process probes
    further localised the issue to non-root mmap of tmpfs
    files written by `vn_rdwr`. See **Findings (2026-05-12)**
    above.
  - **E2 (cross-tool test)**: write a small standalone
    tool that mmap's the state file and `read(2)`'s the
    same file simultaneously, comparing the two views.
    Run it during cursor motion. Verifies whether the
    mmap path is the staleness source or something
    upstream.
    **Resolved 2026-05-12 by an `xxd` probe** without
    needing a dedicated tool. `sudo -u _semadraw xxd` of
    `/var/run/sema/input/state` taken twice with a cursor
    move in between showed differing bytes at the pointer
    offsets, while the same user's `inputdump --watch`
    saw stale data. `read(2)` works for `_semadraw`; mmap
    does not. The dedicated tool is no longer needed.
  - **E3 (analysis and ADR if needed)**: based on E1 and
    E2 findings, decide whether the fix is in:
      - semadrawd's mmap usage (e.g., msync(2) hints,
        re-mmap on detected staleness)
      - inputfs's write path (e.g., vm_object_page_clean
        after vn_rdwr)
      - the architectural choice itself (consume events
        from the event ring instead of polling the state
        mmap, which would also benefit AD-32's busy-spin
        concern)
    **Promoted 2026-05-12 to its own BACKLOG entry**: see
    **AD-35**. The decision is substantial enough to warrant
    a dedicated tracker; E1 and E2 findings give the
    foundation it needs.

The E3 decision likely warrants a dedicated ADR (0008+) if
the fix is structural rather than tactical.

#### Estimate

**Medium**. E1 is small (mirrors Round 1's instrumentation
shape). E2 is small (a focused diagnostic tool, ~100 lines
of Zig). E3 depends on findings: could be a one-line msync
addition, could be a substantial event-ring consumer rewrite.
A dedicated ADR may be needed depending on which direction
E3 points.

#### Related

  - **AD-25**: the umbrella tracker for cursor smoothness.
    AD-25 cannot close until AD-34's question is resolved.
  - **ADR 0007** second addendum (2026-05-12): records the
    bench finding that surfaced this entry.
  - **AD-32**: the loop busy-spin concern. If E3 selects
    the "consume events from the ring" direction, AD-32's
    fix may fall out naturally (the ring is pollable; the
    loop could sleep instead of spin).

#### Closure record (2026-06-07)

Resolved by ADR 0008 Direction 2: route the cursor pump to the
inputfs event ring instead of the state region's frozen mmap,
implemented as AD-36. The event ring's mmap (per-slot offset
writes to changing pages) does not trigger the staleness; the
state region's mmap (whole-buffer writes to the same pages under
the _semadraw credential) did. Verified this session: under
continuous motion the pump now reports pos_changed:true on about
90% of reads (766 of 914, then 2443 of 2460 in the AD-25 decisive
bench), against the 1-in-9998 (and the damning 39,991 identical
reads of (461, 273)) that opened the entry. AD-25 closed on the
strength of it.

Root disposition: this is not a UTF defect. The underlying
FreeBSD tmpfs mmap-staleness for non-root group members is
documented as FREEBSD_ISSUES #1 (Open); ADR 0008 worked around
it rather than fixing the kernel, and the state region remains
correct for root and for read(2). No latent exposure remains in
the cursor path: semadrawd's state_reader field is vestigial
post-AD-36 (declared, initialised null, only deinit'd, never
assigned or read), so nothing live consumes the input
state-region mmap; audio's StateReader is a different region.

Cleanup done (2026-06-07): the vestigial state_reader field in
semadrawd.zig (declared, null-initialised, only deinit'd, never
assigned or read after AD-36) was removed along with its doc
comment, its null init, and the deinit guard. The input import
remains in use for other types; the one surviving StateReader
mention is explanatory prose on the pump's ring source. Brace-
balanced; zig build is the arbiter.

### `[x]` AD-51: AD-50 hardening follow-through  *(CLOSED 2026-06-07, operator-ratified; bench green; the three defensive items AD-50 argued for)*

The AD-50 incident (a deployed semasound slot ran semadrawd,
crash-looping to a flap giveup that downed real audio for five
hours) closed with three owed hardening items, now implemented.

1. install.sh: a per-slot exec-target verification after the s6
   cp loop. Each slot named X must `exec $PREFIX/bin/X`; mismatch
   aborts before any service starts. This is the direct guard
   against the AD-50 vector (semadrawd's run in the semasound
   slot). Plus a dirty-tree WARNING (not abort) at build start: if
   git reports uncommitted changes under s6/, they are listed,
   since install deploys those files verbatim and the incident
   reached production through a dirty working tree.
2. scripts/ad50-recover.sh: verify the repo SOURCE execs semasound
   before the repair cp. The repo copy was itself corrupt once
   that evening; deploying it unchecked merely refreshed the
   corruption.
3. scripts/ad20-flap-verify.sh: a slot-identity precheck. The
   bench bounces the semasound slot repeatedly; if that slot held
   a different daemon it would TERM the wrong process. It now
   refuses unless the slot runs semasound. (The ad38 capture
   scripts already carried this guard.)

All four touched files parse via sh -n and are dash-clean
(install.sh had 19 pre-existing em dashes in comments and echo
text, cleaned on contact).

Verification tool (2026-06-07): scripts/ad51-guard-verify.sh
exercises both guards without a full install. It stages the
AD-50 corruption shape in a /tmp scratch dir and runs install's
exact exec-target grep, asserting it rejects a mis-slotted tree
(Leg 1) and accepts a correct one with no false abort (Leg 2),
then runs install's git status -- s6/ check (Leg 3). Root-free,
instant, touches nothing live; mirrors the install.sh logic
verbatim with a keep-in-sync note. Smoke-tested in the
container: Legs 1 and 2 green, Leg 3 skips where the tree is not
a git checkout (it exercises the real path on pgsd-dev).

DISCHARGE: AD-51 closes fully on (a) ad51-guard-verify.sh
reporting ALL LEGS GREEN on pgsd-dev, and (b) the next routine
clean install printing "verified each slot execs its own binary
(AD-50 guard)", which confirms live integration and no false
abort. The dirty-tree warning's live firing is optional (touch a
tracked s6 file to watch it). Closes the last thread of the
AD-50 arc.

#### Bench (2026-06-07, pgsd-bare-metal)

scripts/ad51-guard-verify.sh reported ALL LEGS GREEN: Leg 1 the
exec-target guard rejected the AD-50 corruption shape (a semasound
slot execing semadrawd), Leg 2 it accepted a correct tree with no
false abort, Leg 3 the git status -- s6/ check ran on the real
tree and found it clean (warning correctly silent). The guard
logic is proven on the target machine. The live "verified each
slot execs its own binary" line will be observed on the next
routine clean install; it is not a closure gate (the inserted
lines passed sh -n and the logic is proven), and a false abort
there would be cause to reopen. AD-51 closed; the AD-50 arc is
finished end to end.

### `[x]` AD-18: drawfs locking-discipline fixes from DF-4 audit  *(RESOLVED 2026-06-07, operator-ratified; .1-.6 done 2026-05-08, .7 landed with DF-6)*

**Tracks**: `drawfs/sys/dev/drawfs/drawfs.c`,
`drawfs/sys/dev/drawfs/drawfs_surface.c`,
`drawfs/sys/dev/drawfs/drawfs_drm.c`. Audit findings recorded
in `docs/DF4_VERIFICATION.md` section "Findings".

The DF-4 static audit (`docs/DF4_VERIFICATION.md`) walked every
lock acquisition site in the drawfs kernel module and found
seven WITNESS-detectable bugs. None affect the substrate's
operational behaviour under the release kernel; all surface
under WITNESS or under the specific race conditions WITNESS is
designed to catch.

**Status 2026-05-08, re-tagged 2026-05-21**: AD-18.1 through .6
are done and bench-verified under PGSD-DEBUG. AD-18.7 (DRM
PAGE_FLIP path) is structurally deferred to DF-6 since the
calling site (KMS page-flip ioctl wiring) does not yet exist;
the fix design is captured but cannot be implemented or
verified until DF-6 wires `drawfs_reply_surface_present` to
`drawfs_drm_surface_present`. The previous deferral target
of DF-3 was imprecise because DF-3 closed as a
compile-clean skeleton without that wiring.

The seven fixes:

- **AD-18.1** *(Done 2026-05-07)*: recursive `s->lock` acquire
  via `surface_lookup` call from inside
  `find_session_for_surface_locked`. Fixed by adding a
  `drawfs_surface_lookup_locked` variant in drawfs_surface.c
  that asserts `s->lock` is held and walks the list without
  acquiring; switched
  `drawfs_find_session_for_surface_locked` to use it. The
  public `drawfs_surface_lookup` is preserved for callers that
  don't hold the lock (e.g. drawfs_reply_surface_present)
  and now delegates to `_locked` to avoid duplicated walk
  code.

- **AD-18.2** *(Done 2026-05-07)*: `vm_pager_allocate` with
  `s->lock` held in `surface_get_vmobj`. Fixed by pinning the
  selected surface's id and bytes_total under the first lock-hold,
  releasing the lock for vm_pager_allocate, then re-acquiring to
  re-find the surface by id and either install (we won) or yield
  to a concurrent installer (deallocating our redundant
  vm_object outside the lock). Added
  `hw.drawfs.vmobj_install_lost` sysctl to count install-race
  losses; should remain 0 on single-threaded workloads. Surface
  bytes_total is immutable post-create and ids are monotonic
  (never reused), so the pinned values stay correct across the
  unlocked window.

- **AD-18.3** *(Done 2026-05-07)*: `malloc(M_WAITOK)` with
  `s->lock` held in input buffer growth path. Fixed by
  rewriting `drawfs_ingest_bytes` as a loop with drop-and-retry
  around the M_WAITOK malloc. Each iteration takes the lock,
  decides whether to fast-path (existing in_cap fits), install
  a pre-allocated buffer (if any), or compute a new newcap and
  drop lock to allocate. Loop bound is log2(MAX_FRAME / initial
  cap) ≈ 8 iterations worst case, almost always 0 or 1 in
  practice. Added `hw.drawfs.inbuf_grow_race_lost` sysctl to
  count races where our pre-allocated buffer was unneeded after
  re-acquire (another writer grew us, or process_inbuf consumed
  enough to make room).

- **AD-18.4** *(Done 2026-05-07)*: same shape as AD-18.3, frame
  extraction path. Fixed by rewriting `drawfs_try_process_inbuf`
  with drop-and-revalidate around the per-frame extraction
  malloc. The lock is released for the malloc, then re-acquired;
  the frame at the head of inbuf is re-validated by header
  memcmp against the pinned copy. If validation fails (another
  extractor consumed our frame, or the session is closing),
  drop our buffer and retry the loop. Added
  `hw.drawfs.frame_extract_race_lost` sysctl. Both AD-18.3
  and AD-18.4 land in the same commit since they share the
  drawfs_write codepath, the same fix shape, and the same file.

- **AD-18.5** *(Done 2026-05-08)*: unprotected stats updates,
  five sites in total. The originally-filed site at
  drawfs.c:639 (now line 681 after AD-18.1-.4 line shifts) was
  `s->stats.bytes_in += n` in `drawfs_write`, completely
  outside any lock. Audit of the file revealed four more
  unprotected updates in the same family:
  `frames_invalid` and `frames_processed` in
  `drawfs_try_process_inbuf` (after `mtx_unlock` for
  validation/process calls), and `messages_processed` and
  `messages_unsupported` in `drawfs_process_frame` (no lock
  at all). All five violated the documented locking-model
  invariant (drawfs.c:218-235: "Statistics counters (stats.*)
  protected by s->lock"). Fixed by:
  - moving the `bytes_in` increment into `drawfs_ingest_bytes`
    where the lock is already held (with a `counted` flag
    to prevent double-counting on grow-race retries; minor
    semantic refinement: closing sessions no longer count
    rejected bytes);
  - wrapping each of the other four updates in a
    take-update-release pattern (`mtx_lock; stats.X++;
    mtx_unlock; reply_call()`) so the stats update is
    serialized but the reply call (which itself takes the
    lock via `drawfs_enqueue_event`) is not nested.
  Also expanded the locking-rules comment to document the
  take-update-release pattern as the canonical idiom for
  stats updates around reply calls. WITNESS does not
  directly catch this kind of data race (no lock-order
  violation), so verification is by code review against the
  invariant; absence of any unprotected `s->stats.` site
  outside `s->lock` confirms the fix.

- **AD-18.6** *(Done 2026-05-08)*: surface-list teardown
  without `s->lock` in `drawfs_surfaces_free_all`. The function
  walked `s->surfaces` and called `TAILQ_REMOVE` outside any
  lock, and updated `s->map_surface_id`, `s->surfaces_count`,
  `s->surfaces_bytes` partly outside the lock. All violated
  the locking-model invariant (drawfs.c:218-235: "Surface list
  (s->surfaces) is also protected by s->lock" and "Statistics
  counters / session state under s->lock"). Latent in
  practice because by the time priv_dtor invokes this function,
  the session has already been removed from the global
  registry (drawfs.c:904-906) and no concurrent access is
  possible. Fixed by restructuring the loop into the standard
  drop-lock-around-vm_object_deallocate pattern: each iteration
  takes s->lock; if the surface list is empty, snaps stat
  drift to zero and returns; otherwise unlinks the head
  surface, captures its vmobj, decrements counters, all under
  the lock; releases the lock; calls vm_object_deallocate;
  free()s the surface struct. Defense-in-depth fix; signed
  off by code review against the documented invariants.

- **AD-18.7**: `drm_ioctl_kern` with `dd->drm_mtx` held in
  DRM PAGE_FLIP path. Currently latent (the function
  `drawfs_drm_surface_present` is unreached; DF-6 has not
  yet wired SURFACE_PRESENT to dispatch into it).
  Capture flip parameters under lock, drop, ioctl, re-acquire,
  install. Fix should land in the DF-6 wiring commit.

**Sequencing**: each sub-stage is independent and can land in
any order. Recommended order is by audit number — AD-18.1 first
because it's the most clearly fatal (recursive acquire on
non-recursive mutex), then the M_WAITOK bugs as the most
common sleep-with-lock-held class.

**Verification**: ideally each sub-stage is verified by the
DF-4 WITNESS run going green for that specific finding. In the
absence of a debug kernel, code review against the documented
locking invariants (drawfs.c:182-198) is the available bar.

**Why filed as a separate AD rather than rolled into DF-4**:
DF-4 is the verification work. AD-18 is the fix work that
DF-4's audit identified. Keeping them separate lets DF-4 close
when verification runs (and findings are confirmed) without
needing to wait on every fix to land first.

**Discovered**: DF-4 static audit, 2026-05-05.

#### Closure record (2026-06-07)

The DF-4 audit's seven WITNESS findings are all addressed. .1
through .6 were done and bench-verified/code-reviewed 2026-05-08.
.7 (the page-flip ioctl under dd->drm_mtx) had no calling site until
DF-6 created one; its fix landed in the DF-6 implementation per ADR
0002 D4 (claim flip_pending, drop, ioctl, re-acquire, swap or
rollback, the same shape as .2/.3/.4). AD-18's audit is fully
discharged in code. Note: .7's runtime verification shares DF-6's
hardware-bench gate, it is written but not yet exercised on DRM/KMS
hardware. The audit deliverable is complete; hardware validation of
the .7 path rides with DF-6.

## Architectural Discipline

The project's discipline (UTF depends only on code written with UTF's
guarantees in mind) is stated in full at
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md`. This section tracks the work
streams that apply the discipline to subsystems where external
dependencies currently sit inside UTF's guarantee path. Items here
represent multi-stage replacements, not individual features; each
item typically has its own design document or proposal that details
the stages.

### `[x]` AD-2: Retire semainputd  *(Done 2026-05-17; Phase 2.5 scenarios 1-6 verified bare-metal; multi-touch 7-9 verified 2026-05-06)*

**Tracks**: `inputfs/docs/inputfs-proposal.md` Stage E (cutover).

Once inputfs owns input classification, device identification, and
routing, the userspace semainputd daemon has no remaining
responsibilities. Classification and device-role logic move into the
kernel module. Gesture recognition moves into the compositor or
per-client libraries. The `start.sh` sequence drops semainputd
entirely. evdev-related code in `semainput/src/adapters/` is removed.

**Hardening precondition cleared** (2026-04-30): AD-9 closed.
The inputfs HID parser is both crash-resistant (no faults on
24 corpus entries under AddressSanitizer) and output-correct
(14 of those entries have explicit expected outputs that the
parser produces). The button-bitmap truncation bug found by
AD-9.4 was fixed in commit `3887091`. Stage E cutover may now
proceed without inheriting known-unsafe parser behaviour.

**AD-2 sub-structure** (2026-05-01): the original "gesture
recognition moves into the compositor or per-client libraries"
sentence above is resolved into two concrete sub-items:

- **AD-2a: libsemainput reshape and semainputd retirement.**
  Strip evdev reader, classification, aggregation, identity,
  and event-queue code from semainput (all owned by inputfs
  after Stage D). Promote `gesture.zig` (1,044 lines) into
  `libsemainput`, a userland library consumed by clients and
  by semadrawd. Retire the standalone `semainputd` daemon
  binary. semadrawd hosts system-level gesture recognition
  (three-finger swipe etc.) using the same library. No
  design ADR required (no new shared-memory contract).

  Substructure:
    - **AD-2a Phase 1 (cutover) — DONE 2026-05-06.** semadrawd
      reads input from the inputfs event ring at
      `/var/run/sema/input/events` instead of the legacy
      `/dev/draw` injection path. Verified bare-metal: keys
      arrive both with semainputd up and down; pointer events
      flow into clients (click-and-drag in semadraw-term
      registers); modifier bits arrive correctly. See
      `inputfs/docs/STAGE_E/PHASE_1.md` for the verification
      record. Implementation lives in
      `semadraw/src/backend/inputfs_input.zig` (411 lines)
      and `semadraw/src/backend/inputfs_translate.zig` (309
      lines), both already in the tree from the seed commit.
      Translation tests are wired into `zig build test` and
      green.
    - **AD-2a Phase 2.1-2.3 (libsemainput extraction) — DONE
      2026-05-04.** `semainput/src/gesture.zig` promoted into
      `semainput/libsemainput/libsemainput.zig` as a userland
      library with no IO dependencies. semainputd's gesture.zig
      reduced to a JSON-emitting shim that delegates all
      recognition to the library. ADR 0016 governs the
      extraction. semainput's shim continues to exist for
      diagnostic compatibility until Phase 3.
    - **AD-2a Phase 2.4 (gesture event wire and recogniser-as-
      service) — DONE 2026-05-04.** semadrawd hosts a single
      `libsemainput.GestureRecognizer` instance per Daemon,
      fed via a side-channel buffer in the drawfs backend that
      captures every drained `input.Event` before the typed
      KeyEvent/MouseEvent dispatch path drops touch and pen
      events. The recogniser produces `LibsemainputOutput`
      values which the daemon translates into `gesture_event`
      messages (`MsgType = 0x9030`) sent over the existing
      semadraw connection to the focused surface's client.
      Wire format is a 24-byte flat header carrying surface_id,
      gesture_type, phase (begin/update/end/cancel),
      finger_count, modifier flags, and a single chronofs ns
      timestamp; per-variant payload follows (0..20 bytes,
      total wire size 24..44 bytes).

      Sub-phases (all upstream):
        - 2.4.1: protocol additions (`gesture_event = 0x9030`,
          GestureEventMsg, 7 payload variants, 27 tests).
        - 2.4.2: drawfs backend side-channel buffer
          (`injected_inputfs_events`, `getInputfsEvents`
          vtable).
        - 2.4.3: recogniser ownership in semadrawd
          (`gesture_recognizer` field on Daemon, init in
          `initCompositor`, deinit in reverse order).
        - 2.4.4: feed-and-forward (input.Event ->
          LibsemainputInput translation, drain loop, stub
          `forwardGestureEvents`).
        - 2.4.5: forwardGestureEvents body (phase derivation,
          GestureEventMsg construction, payload packing,
          routing).

      Two design pauses produced rev2 of ADR 0017
      (`inputfs/docs/adr/0017-rev2-gesture-event-wire-format-
      and-routing.md`) and a 2026-05-04 addendum that removed
      `t_begin` from the wire format. The current design is
      event-stream-shaped (each event self-sufficient at the
      moment it occurs; clients accumulate gesture-as-object
      themselves if needed) rather than gesture-object-shaped
      (each event materialises the full gesture lifecycle).
      Recogniser-internal state (gesture-begin timestamps,
      contact tracking) does not leak into the wire format.
      See `docs/PROTOCOL_NAMESPACE_CONVENTION.md` for the
      MsgType-namespace clarification that surfaced during
      this work.
    - **AD-2a Phase 2.5 (bare-metal verification) — DONE
      2026-05-17.** Confirm gesture events flow on real hardware:
      single click + double-click on a focused surface
      produces a mouse_event followed by a gesture_event with
      `gesture_type = n_click`, `phase = update`,
      `finger_count = 1`, `count = 2` in the NClickPayload;
      modifier bits set on the wire when shift/ctrl is held;
      pinch/scroll/three-finger-swipe if the test machine has
      multitouch hardware available. Phase 2 closes when
      verification passes. Existing semainputd JSON-line
      output via the shim should also still work for diagnostic
      backwards-compatibility.

      **Verified 2026-05-17 on `pgsd-bare-metal`** via the
      corrected runbook (Debug build, over SSH per the
      runbook hazard notes). Scenario-by-scenario, observed in
      `gesture_inspect` output:
        - Sc.1 single click: discrete press/release, no
          spurious gesture line. Pass.
        - Sc.2 double-click: four mouse lines then
          `event_kind=gesture type=n_click ... count=2`,
          observed repeatedly across independent
          double-clicks. First-ever bare-metal observation of
          the `forwardGestureEvents` path (commit 59cd5b7)
          producing a gesture line. Pass.
        - Sc.3 triple-click: `count=2` then `count=3` with a
          ~168us inter-click delta inside the interval
          threshold, confirming the recogniser's `extends`
          path increments rather than caps (an earlier
          all-`count=2` capture was discrete double-clicks,
          not a Sc.3 failure - the source showed the counter
          uncapped and the re-run confirmed it). Pass.
        - Sc.4 shift+double-click: `event_kind=key
          key_code=42 pressed=1 modifiers=shift`, mouse and
          gesture lines `modifiers=shift`, shift release.
          Pass.
        - Sc.5 ctrl+double-click: identical with key_code=29,
          every line `modifiers=ctrl`. Pass (confirms a
          different modifier bit position).
        - Sc.6 shift+ctrl+double-click: modifier mask builds
          `shift` then `shift+ctrl` as keys go down; gesture
          line `modifiers=shift+ctrl` in the fixed
          formatModifiers order. Pass (confirms multiple
          simultaneous bits combine on the wire).
      One intermediate capture showed no `event_kind=key`
      lines at all; diagnosed (not assumed) as keyboard input
      not reaching the daemon in that attempt rather than a
      modifier-propagation bug - the subsequent capture with
      keyboard correctly routed to surface 3 showed all of
      Sc.4-6 passing, confirming the diagnosis. Scenarios 7-9
      (multitouch) were separately verified 2026-05-06 (next
      entry). All nine runbook scenarios are now verified.
      A cosmetic note for future operators: gesture_inspect
      prints `button=left` on `type=motion` lines because the
      button enum has no none-variant and printMouse formats
      it unconditionally; this is a display artifact in the
      helper, not a held-button state error, and does not
      affect the recogniser.

      Status as of 2026-05-05 in
      `semadraw/docs/PHASE_2_5_VERIFICATION_STATUS.md`:
      daemon bring-up, surface registration, and the mouse-
      event 1:1 invariant are verified end-to-end on
      `pgsd-bare-metal-test-machine`. A pre-fix duplication
      bug (synthesise-from-bitmask path in
      `dispatchPointerMotion`) was found and closed during
      verification (commit 0487a66). The n_click gesture
      emission and modifier-propagation scenarios, wired in
      code at that date, are now exercised and verified on
      bare metal (2026-05-17, above).
      Multi-touch scenarios were carved out into a separate
      deferred work item (next entry) on 2026-05-05 so this
      phase can close on scenarios 1-6 without waiting for
      hardware.
    - **AD-2a Phase 2.5 multi-touch verification — DONE
      2026-05-06.** Scenarios 7-9 of
      `semadraw/docs/PHASE_2_5_VERIFICATION.md` (pinch,
      two-finger scroll, three-finger swipe) require
      `SOURCE_TOUCH` events from a multi-touch HID device.
      Hardware was identified and characterized 2026-05-05
      (HAILUCK USB touchpad, vendor=0x258a, product=0x000c;
      505-byte Win8+ multi-touch HID descriptor verified
      end-to-end via `hw.inputfs.debug_descriptor`). The
      descriptor presents a fully-conformant Microsoft-
      precision-touchpad-class digitizer (Report ID 7) with
      tip switch, contact identifier, per-contact X/Y at
      15-bit precision, scan time, contact count, and
      Win8+ feature reports. The HUP_DIGITIZERS parser
      sub-item under AD-1 closed 2026-05-06 with the
      classifier extension, locator, parser, and Touchpad
      Mode feature-report send all implemented and
      verified bare-metal on the HAILUCK. The
      `inputfs2: Device Mode set to MT Touchpad
      (report_id=11 rlen=2)` dmesg line plus inputdump
      traces showing correct touch_down / touch_move /
      touch_up lifecycle across single- and multi-finger
      gestures (with monotonic timestamps and clean
      per-contact tracking) close this entry. Phase 2.5
      status doc section 7 marked Verified. A second
      multi-touch device (Apple Bluetooth Magic Trackpad)
      remains available for future verification under a
      separate Apple-protocol parser sub-item rather
      than this one.
    - **AD-2a Phase 3 (deletions) — UNBLOCKED by Phase 2.4
      recogniser-as-service decision.** Remove `semainputd`
      binary, `semainput/src/adapters/evdev.zig`,
      `semainput/src/adapters/drawfs_inject.zig`, the
      `DRAWFS_EVT_KEY/POINTER/SCROLL` decode arms in
      semadrawd's `sendAndRecv`, the `semainput` rc.d shim,
      the `/var/service/utf/semainputd` service directory,
      and the install.sh blocks that wire them up. Phase 3
      also swept the documentation that described
      semainputd as a present-tense daemon (semainput/docs/
      Architecture.md / SystemInterface.md / GestureLayer.md /
      NClickDesign.md / FreeBSDEvdevAdapterImplementation.md).
      **Doc sweep done 2026-05-08:** all five files now carry
      an "Archived 2026-05-08" banner, frame their bodies as
      pre-retirement historical record, and point to the
      live components (inputfs ring, `libsemainput`,
      `shared/EVENT_SCHEMA.md`). The string "semainputd"
      still appears in them by design - a doc explaining a
      retired daemon necessarily names it - so a grep for
      that token is not a sweep-completeness test; the files
      were read end-to-end during the 2026-05-17 audit and
      are correctly archival.

      Phase 3 also includes a small structural cleanup
      surfaced during Phase 2.4: the per-source-role
      event_type constants (POINTER_MOTION,
      POINTER_BUTTON_DOWN, POINTER_BUTTON_UP, POINTER_SCROLL,
      TOUCH_DOWN, TOUCH_MOVE, TOUCH_UP) are duplicated across
      `semadraw/src/backend/inputfs_input.zig` and
      `semadraw/src/daemon/semadrawd.zig`. Promote them to
      `shared/src/input.zig` as public constants alongside
      SOURCE_POINTER etc. One-commit refactor; the TODO
      comments in the duplicated declarations point here.

      Phase 3 was split into two ordered steps:

        - **Phase 3 step 1 (event_type promotion) — DONE
          2026-05-07** in commit `c39db1b`. The duplicated
          constants moved into `shared/src/input.zig`; the
          callers `semadraw/src/backend/inputfs_input.zig`
          and `semadraw/src/daemon/semadrawd.zig` now
          import them.

        - **Phase 3 step 2 (semainputd retirement) — DONE
          2026-05-08.** Code+config commit:
            - Deleted `semainput/src/` (entire directory:
              the daemon binary plus 11 source-only modules
              including device_*.zig, output.zig,
              gesture.zig as a libsemainput shim, and the
              two adapters).
            - Rewrote `semainput/build.zig` to libsemainput-
              only (still produces tests so the top-level
              `zig build test` dispatcher finds something to
              run).
            - Deleted `scripts/rc.d/semainput`.
            - Deleted `s6/utf/semainputd/` (run, finish,
              log/run).
            - Removed the `DRAWFS_EVT_KEY/POINTER/SCROLL`
              constants and decode arms from
              `semadraw/src/backend/drawfs.zig`'s
              `sendAndRecv`, plus the orphaned helpers
              `parseEvtKey`/`stashEvtKey`/`stashEvtPointer`/
              `stashEvtScroll`/`pushScrollPair` and
              `drainInjectedEvents` and its caller in
              `pollEventsImpl`. The `injected_keys` and
              `injected_mice` arrays themselves stay (still
              consumed by `inputfs.drain()`); the
              "injected_" prefix is now historical naming
              rather than literal.
            - Removed `last_button_state` field (was only
              used by the deleted `stashEvtPointer`).
            - Top-level `build.zig` lost the `run-semainput`
              convenience step.
            - install.sh: header comment, BINARIES list,
              uninstall rc.d loop, `stop_service_if_running`
              call and comment, `install_bin` line, the
              `cat > $RCDDIR/semainput` heredoc block, the
              s6 install loop and log dir loop, the
              `sysrc semainput_enable=YES` line, the
              post-install restart loop, and the final
              summary lines all dropped semainput. Two
              new cleanup blocks reap obsolete
              `$SVC_ROOT/semainputd` and `$LOG_ROOT/semainputd`
              from prior installs (s6-svc -dx with timeout,
              then rm -rf, since install.sh creates SVC_ROOT
              contents but didn't previously reap stale
              service dirs). The uninstall path still has
              `sysrc -x semainput_enable` to clear stale
              rc.conf entries on upgrade.

            - **Accounting correction (2026-05-17 audit).**
              The install.sh enumeration above was not
              complete: it missed the `build_sub "semainput"
              "semainput"` call in the build loop, which the
              retirement left in place. That line was pure
              cruft (semainput/build.zig is libsemainput-only
              and produces no artifact; libsemainput is
              consumed by semadraw as a compile-time source
              module per semadraw/build.zig; install.sh
              consumes nothing from semainput/zig-out), so it
              was behavior-neutral - its only effect was
              printing a misleading "Building semainput" on
              every install, contradicting this entry's own
              reaper blocks. Removed 2026-05-17 in commit
              `33662e7` (build loop now lists only semaaud,
              semadraw, chronofs, inputfs userland). The
              header/BINARIES/uninstall/restart/summary
              claims above were accurate when checked against
              the current tree; only the build-loop line was
              the gap. Separately: the "Top-level build.zig
              lost the run-semainput step" line above is
              correct but narrow - build.zig still carries a
              `semainput` sub-build dispatch entry whose
              `test-semainput` step runs libsemainput's
              recogniser tests. That is intentionally retained
              (the recogniser library is the surviving useful
              core of the retirement; its tests should keep
              running) and is not a gap.

          The kernel-side `DRAWFSGIOC_INJECT_INPUT` ioctl,
          the four `DRAWFS_EVT_*` opcodes in `drawfs_proto.h`,
          and the kernel switch arms that handle them
          (`drawfs.c:749` and following) are intentionally
          retained. They are unused by current userland but
          their removal is ABI-breaking and orthogonal to
          this retirement; tracked separately when the
          kernel ABI is next revised.

          Documentation sweep (semainput/docs/*.md) is the
          companion second commit, lower-risk and
          independent of bench correctness.

          Verification:
            - `cd semainput && zig build` (libsemainput
              builds clean; no executable emitted).
            - `cd semainput && zig build test` — 11 of 11
              recogniser tests pass.
            - `cd semadraw && zig build && zig build test`
              — 65 of 65 tests pass; backend compiles
              clean with the inject path removed.
            - Bench post-deploy: no `semainputd` in `ps
              auxw`; no rc.d/semainput; no
              /var/service/utf/semainputd directory after
              install.sh runs; semadrawd starts cleanly,
              receives input from the inputfs ring, no
              regressions in the AD-29 verification surface.

      With Phase 3 step 2 done, AD-2a as a whole is
      complete: the legacy semainputd daemon has no
      remaining userland surface. libsemainput continues to
      live under semainput/ and is consumed by semadrawd's
      gesture-recogniser-as-service path (Phase 2.4
      decision).

- **AD-2b: Per-user pointer smoothing via published region.**
  Design landed (2026-05-01) in
  `inputfs/docs/adr/0015-per-user-pointer-smoothing.md` and
  `shared/INPUT_SMOOTHING.md` (commit `329197b`). Discipline-
  doc addendum landed (2026-05-01) in
  `docs/UTF_ARCHITECTURAL_DISCIPLINE.md` (commit `1285753`).

  **Parked at stage 3 (2026-05-09).** Stages 1-3 landed and
  pushed:

    - Stage 1 (commit `fd4a8bf`): `shared/src/input.zig`
      gains `SmoothingWriter` / `SmoothingReader` types
      mirroring the `FocusWriter` pattern.
    - Stage 2 (commit `da9ed7c`): `inputfs_smooth.{c,h}` with
      Q16.16 EMA and One-Euro implementations. Compiled into
      the module, not yet called.
    - Stage 3 (commit `7338407`): inputfs's existing kthread
      worker gains a 32-byte cache of the smoothing region,
      refreshed once per tick from
      `/var/run/sema/input/smoothing` if present.
      Bench-neutral: file is absent today, refresh logs
      "absent" once and goes silent.

  **Stages 4-9 explicitly deferred.** During design re-
  evaluation on 2026-05-09 the original framing ("smoothing
  has to live somewhere, semainputd is going away, so AD-2b
  has to ship before the daemon can retire") was identified
  as obsolete. semainputd was already retired by AD-2a Phase 3
  (2026-05-08); pointer behaviour without smoothing is
  acceptable on bench (verified across multiple `kldload`
  cycles); the visible cursor artefact during fast motion that
  was sometimes attributed to "lack of smoothing" is in fact
  AD-25 (region damage clearing efficiency), a separate
  rendering-side issue that smoothing would not fix and might
  worsen. With the original justification gone and substrate
  work (AD-3, AD-4) being the actual critical path, completing
  the apply path (stage 4) and writer (stage 5) is premature.
  The kernel-side machinery from stages 1-3 sits dormant
  (cache_valid stays 0, no smoothing fires) at zero ongoing
  cost; revival is a future-session decision.

  **AD-2c (placeholder, future).** The semantic-model
  question that surfaced during the AD-2b design re-
  evaluation, whether smoothing is naturally per-device,
  per-user, or per-task, was left unresolved and is the
  right framing for a future design pass. ADR 0015 is
  written around a single global parameter set published by
  the compositor; the per-user paragraph in §5 was a
  premature commitment to a model not yet validated by use.
  When this work resumes (under AD-2c or a successor name),
  expected order: (i) survey inputfs's existing device-
  classification path to establish per-device defaults as
  the natural lowest layer; (ii) decide whether per-user or
  per-task overrides are warranted; (iii) revise ADR 0015 §5
  accordingly; (iv) only then implement stages 4-9. ADR 0015
  amendments owed at that time: the path correction
  (`semainput/` → `inputfs/`, typo from before semainputd
  retired) and the integration-point clarification
  ("smoothing applies inside `inputfs_state_update_pointer`,
  not between it and the focus resolver") that the parked
  stage 4 draft already encoded in code comments.

AD-2a and AD-2b are independent and may proceed in either
order. AD-2a has no design dependency on AD-2b; AD-2b's
implementation does not depend on the daemon retirement.

### `[x]` AD-5: Formalise ZFS as accepted dependency  *(Done 2026-05-05, Small)*

**Tracks**: `docs/UTF_STORAGE_DEPENDENCY.md` (new),
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md` (updated),
`docs/FREEBSD_SUBSYSTEMS.md` (updated).

The acceptance is now explicit. UTF the substrate is
filesystem-agnostic; PGSD the distribution requires ZFS. The
chain is recorded in `docs/UTF_STORAGE_DEPENDENCY.md` along with
what UTF actually does with storage (POSIX file I/O via VFS,
`mmap` of regular files, atomic rename, `tmpfs` for
`/var/run/sema/` publications), what UTF does *not* use (no
`libzfs`, no ZFS-specific APIs), and how UTF behaves under
storage failure (Posture 3 degradation per AD-12.5).

The previous "UTF uses ZFS for persistent storage" statement in
the discipline doc was anticipatory rather than reflective of
actual code. Corrected to "UTF runs on whatever filesystem the
host platform provides via VFS; PGSD requires ZFS for its own
reasons (boot environments, Axiom, sysrebase)."

Practical consequence: UTF stays portable across BSDs and across
filesystems. PGSD's ZFS requirements are tracked at the
distribution level, not in UTF.

Doc-only commit; no code changes.

### `[x]` AD-6: Audit Zig stdlib usage at determinism boundaries  *(Done 2026-05-05, Small-Medium)*

**Tracks**: `docs/UTF_ZIG_STDLIB_BOUNDARY.md` (new),
`shared/src/posix_safe.zig` (new),
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md` (updated reference),
`chronofs/build.zig` (wires posix_safe into resolver_mod),
`chronofs/src/resolver.zig` (uses safeRead in ingestionThread).

The discipline says UTF accepts the Zig stdlib but verifies its
behaviour at determinism boundaries rather than assuming it.
AD-6 makes the boundary explicit and mitigates the one concrete
risk that has surfaced.

The audit walked the stdlib surface in UTF (98 files using
`std.posix`, `std.fs`, `std.io`, `std.fmt`, `std.mem`,
`std.atomic`) and identified five determinism-boundary areas:
kernel cdev I/O, inter-daemon socket and ring I/O,
shared-memory publication, wire-format parsing, time-sensitive
scheduling. Out of scope: build scripts, error formatting, log
emission, test harness, dump-and-print tools.

The audit's findings are recorded in
`docs/UTF_ZIG_STDLIB_BOUNDARY.md`. The most concrete boundary
issue UTF has hit is `std.posix.read`/`write` panicking via
`unexpectedErrno` on errnos that fall outside stdlib's
"known" set. UTF's kernel cdevs (drawfs, inputfs) and accepted
cdevs (`/dev/dsp`) return such errnos legitimately. The
existing inline `safeRead` in `semadraw/src/backend/drawfs.zig`
demonstrated the mitigation pattern; AD-6 promotes that to a
shared helper.

**Code changes landing under AD-6**:

- `shared/src/posix_safe.zig` (new): `safeRead` and `safeWrite`
  helpers that call `posix.system.read`/`write` directly and
  convert any error to `error.ReadFailed`/`error.WriteFailed`.
  Four inline tests cover EOF, normal write, invalid fd read,
  invalid fd write.

- `chronofs/build.zig`: adds `posix_safe_mod` and wires it as
  an import to `resolver_mod`. Also runs `posix_safe_tests`
  under `chronofs test`.

- `chronofs/src/resolver.zig`: `ingestionThread` now uses
  `posix_safe.safeRead`. Previous code would have panicked on
  any non-stdlib-known errno (rare but documented under SIGINT
  during shutdown).

- `docs/UTF_ARCHITECTURAL_DISCIPLINE.md`: the existing line
  about stdlib determinism-boundary verification now references
  the new doc and the `posix_safe` helper.

Other call sites reviewed:

- Sockets in semaaud, semadrawd, semadraw-term — no change.
  Socket errno set is small and well-known to stdlib.
- inputfs ring reads — no change. Use mmap, not read.
- semaaud audio_fd writes — no change. OSS errnos mostly in
  stdlib's known set; the one uncertain case (`EBUSY` from
  contested DSP) is acceptable to surface as a Zig error.
- drawfs.zig inline `safeRead` — preserved unchanged. Future
  cleanup could route this site through the shared helper, but
  that is a refactor not required by AD-6.

Doc-and-helper commit; no behavioural changes to existing code
beyond the chronofs ingestion site. Same shape as AD-5
(`UTF_STORAGE_DEPENDENCY.md`) and AD-7
(`UTF_USB_HID_BOUNDARY.md`); together AD-5, AD-6, and AD-7 form
the explicit-boundary trilogy for UTF's three largest accepted
dependencies (storage, language toolchain, USB/HID transport).

### `[x]` AD-7: Audit and document USB / HID dependency boundary  *(Done 2026-05-05, Small)*

**Tracks**: `docs/UTF_USB_HID_BOUNDARY.md` (new),
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md` (updated),
`docs/FREEBSD_SUBSYSTEMS.md` (updated).

The boundary is now explicit. inputfs uses eleven entry points
across `<dev/hid/hid.h>` and `<dev/hid/hidbus.h>`; the surface
has been stable across FreeBSD 14 and 15. UTF accepts everything
below those entry points (USB host controllers, the USB stack,
`usbhid` as transport) and owns everything above (the kernel
publication ring at `/var/run/sema/input` and the userspace
consumers).

The new doc `docs/UTF_USB_HID_BOUNDARY.md` enumerates:

- The eleven `hidbus_*` and `hid_*` entry points inputfs depends
  on, each with the required behaviour.
- The TLC match table inputfs uses to claim devices.
- What UTF deliberately does not use (USB endpoint I/O, USB
  controller drivers, kernel HID parser internals, Bluetooth
  HID, HID-over-I²C beyond the hidbus surface).
- Which platform changes would break inputfs (entry-point
  rename, hidbus naming-convention change, `hid_item` ABI
  change, removal of kernel-mode parser).
- Which changes would silently affect inputfs (USB controller
  bugs, power-management transitions, firmware-driven PNP
  changes).
- Which changes UTF will not notice (USB controller swaps,
  `usbhid` internal refactoring, descriptor-preserving firmware
  updates).
- Failure modes at the boundary and inputfs's response.

Practical consequence: the work to port UTF to a non-FreeBSD
platform (NetBSD, OpenBSD, future major-version FreeBSD with
significant HID changes) is bounded by this document.

Doc-only commit; no code changes. Same shape as AD-5
(`UTF_STORAGE_DEPENDENCY.md`); together they form the
explicit-boundary pair for UTF's two largest accepted
dependencies. AD-6 (Zig stdlib) and AD-10 (vt(4)) remain as
the next boundaries to formalise.

### `[x]` AD-8: PGSD kernel: omit drivers superseded by inputfs  *(Done 2026-05-05, Small)*

**Tracks**: `pgsd-kernel/PGSD` and `pgsd-kernel/README.md`.

PGSD ships its own FreeBSD-derived kernel that omits drivers
inputfs supersedes. The config at `pgsd-kernel/PGSD` is a
self-contained derivative of FreeBSD GENERIC (re-merged on
upstream-release-tracking) that omits the `hkbd` and `ukbd`
device lines and adds `makeoptions WITHOUT_MODULES=...` listing
all eleven HID class drivers ADR 0007 enumerates plus `hidmap`.
`hidbus`, `usbhid`, and the generic `hid` layer remain.

**Status:** Done 2026-05-05. Self-contained PGSD config landed.
The modules build is suppressed via `WITHOUT_MODULES` passed
on the `make buildkernel` and `make installkernel` command
line; with that, the `.ko` files for the listed drivers do
not appear under `/boot/kernel/` and `linker.hints` has no
PNP entries to match — the runtime auto-load contention
path is closed.

The pre-AD-8 path that this commit replaced:

- Pre-2026-05-05: the config was an `include GENERIC` plus
  `nodevice` overrides. `nodevice` removed the driver from the
  static kernel image but did not affect the modules build, so
  `.ko` files appeared under `/boot/kernel/`, `linker.hints`
  registered their PNP signatures, and the kernel auto-loaded
  them at boot when matching USB devices appeared. The
  verification workflow worked around this by moving the `.ko`
  files aside between builds.

The post-AD-8 path landing in this commit:

- `pgsd-kernel/PGSD` is a self-contained config: a full copy of
  GENERIC with the AD-8 deltas (file header, ident, removed
  `hkbd`/`ukbd` device lines).
- The modules-build suppression mechanism (`WITHOUT_MODULES=...`)
  is documented in `pgsd-kernel/README.md` as a build-command
  argument, **not** as a `makeoptions` directive in the config.
  We tried the `makeoptions` form first and it did not suppress
  the modules: the kernel-config `makeoptions` reaches the
  kernel-link step but the modules tree is invoked from
  `/usr/src/Makefile.inc1` via a separate make that does not
  inherit those options. The command-line argument is the
  supported path. The PGSD config has no `WITHOUT_MODULES`
  declaration to avoid presenting a false sense of closure.
- Trade-off: PGSD must be re-merged with upstream GENERIC on
  each FreeBSD release. The `WITHOUT_MODULES` argument lives
  outside the config so it does not enter the re-merge
  calculation.
- README updated to document the new shape, the build/install
  command-line procedure, the re-merge procedure for upstream
  tracking, the disk-side verification checks
  (`ls /boot/kernel/`, `strings /boot/kernel/linker.hints`),
  and a recovery section for the case where modules slipped
  through (delete the leaked `.ko` files, rerun `kldxref`).

**Out of scope (deliberately):**

- A future `pkg upgrade` of `FreeBSD-kernel-generic` will
  reinstall the omitted modules. PGSD eventually needs its own
  pkg repository (or a `pkg-lock(8)` discipline). Out of scope
  for AD-8; relevant once PGSD has its own pkg infrastructure.
- Removing `evdev`, `uinput`, and `EVDEV_SUPPORT` from the kernel
  is a separate decision deserving its own track. Not folded
  into AD-8.

**Drift hazard occurred 2026-05-08.** The first bullet's hazard
materialised on `pgsd-bare-metal-test-machine` between
2026-05-05 (AD-8 verification passed) and 2026-05-08 (AD-30
investigation found legacy drivers loaded again). The detection
and recovery procedure is documented under
`pgsd-kernel/README.md` "Periodic drift on a running system
(the pkg-upgrade hazard)"; AD-30.1 is the operational
re-application of AD-8's discipline on the bench. Until PGSD
has its own pkg repository, drift detection becomes a periodic
operator check rather than a one-time install verification.
The "Operational discipline" subsection of the README documents
the suggested cadence (re-check after every `pkg upgrade`).

**Verification on bare metal**: confirmed 2026-05-05. First
attempt (`make buildkernel` / `make installkernel` with the
`makeoptions WITHOUT_MODULES` directive in the kernel config)
produced the modules anyway, demonstrating that the kernel-config
`makeoptions` form did not work and surfacing the recovery
procedure now documented in the README. Re-run with the argument
on the build command line is the durable path. Bare-metal
post-recovery `kldstat` shows none of the suppressed drivers
loaded; only the kernel image, drawfs, zfs, ichsmb/smbus,
inputfs, and the Bluetooth/netgraph stack.

### `[x]` AD-9: HID descriptor and report fuzzing  *(Done, Medium)*

**Tracks**: `inputfs/docs/adr/0014-hid-fuzzing-scope.md`.

Harden inputfs's parser-output consumer code against
malformed HID descriptors and reports. ADR 0014 establishes
the scope precisely: the fuzz target is *not* the HID
descriptor walker (which is FreeBSD's `hid_locate` /
`hid_get_data` / `hid_start_parse` etc., accepted as
platform transport), but inputfs's locate phase
(`inputfs_pointer_locate`, `inputfs_keyboard_locate`) and
extract phase (`inputfs_extract_pointer`,
`inputfs_keyboard_diff_emit`), which trust the walker's
outputs and read HID reports using cached bit-positions
those outputs produced.

Bug surfaces: trust assumptions about `hid_locate` outputs,
report-buffer bounds checks, modifier and keys-array bit
walking, descriptor-derived state used as bounds. The fuzz
oracle treats assert failures, segfaults, infinite loops,
and allocation explosions as bugs; incorrect-but-non-crashing
parses are out of scope (they need correctness oracles, not
crash oracles).

**Sub-stages** (full detail in ADR 0014):

- AD-9.1 *(landed, `b79e8d6`)*: parser-state refactor in
  `inputfs.c`. Extracted 25 parser-output fields into
  `struct inputfs_parser_state` embedded in softc as
  `sc_parser`. Four pure-parser functions take
  `inputfs_parser_state *` directly. Production behaviour
  unchanged; verified by C.5 (26/26) and D.6 (14/14) on
  PGSD-bare-metal.
- AD-9.2a *(landed, `64cd245`+`5071ad7`)*: extracted the
  four parser functions and `inputfs_report_id_matches`
  helper from `inputfs.c` into a new translation unit
  `inputfs_parser.c`, with `struct inputfs_parser_state`
  declared in `inputfs_parser.h`. `inputfs.c` shrank by
  395 lines net; the kernel module Makefile compiles both
  files. Production behaviour unchanged; verified by C.5
  (26/26), D.6 (14/14), and a comprehensive smoke test on
  PGSD-bare-metal (pointer motion + buttons + scroll plus
  keyboard key_down/up events). The linkage-fix follow-up
  removed `static` from the four function definitions
  after the kernel build caught the linkage conflict.
- AD-9.2b *(landed, `7d4eaec`)*: harness build
  infrastructure under `inputfs/test/fuzz/` (kernel_shim.h,
  shim_includes/ including 8 empty kernel-header stubs and
  the opt_hid.h / hid_if.h replacements, vendored
  hid.c/hid.h/hidquirk.h byte-identical to upstream,
  main.c, Makefile, README.md, corpus/known-good.bin from
  the USB HID 1.11 boot-protocol mouse spec).
  AddressSanitizer enabled. Verified on PGSD-bare-metal:
  `make` builds clean, `make smoke` passes all three
  checks (empty input, known-good descriptor, 4 KiB
  random data).
- AD-9.2c *(landed, this commit)*: retrospective ADR 0014
  update marking AD-9.2a, AD-9.2b, and AD-9.2 itself as
  landed. The harness README originally planned for
  AD-9.2c shipped in AD-9.2b instead, because it
  documented files landing in the same change; AD-9.2c is
  therefore the doc retrospective only.
- AD-9.3 *(landed, `b480432`)*: 23-entry hand-rolled
  malformed-input corpus under `inputfs/test/fuzz/corpus/`
  with five-line `.txt` companions (CATEGORY, TARGETS,
  INPUT, EXPECTED BEHAVIOR, EXPECTED FAILURE MODE IF
  BROKEN). Coverage by ADR 0014 category: 5 truncated
  descriptors, 3 recursive-collection cases, 3 out-of-range
  usages, 3 lying descriptors, 5 pathological reports, 2
  cross-paired blobs, 2 baselines (boot mouse, boot
  keyboard). Generated declaratively from
  `gen-corpus.py`. `fuzz-verify.sh` runs the harness against
  every entry; result on PGSD-bare-metal: 23/23 PASS, exit
  0, no ASan reports. Same commit also fixed a leaked
  6 MB `inputfs-fuzz` binary tracked accidentally by
  AD-9.2b (root cause: heredoc-escaping bug in the AD-9.2b
  commit script's safety regex; AD-9.3's commit script uses
  a self-testing regex without backslash escapes).
- AD-9.4 *(landed, `3887091`)*: ran the AD-9.3 corpus
  through the parser with output-value inspection; found
  and fixed one bug. `inputfs_extract_pointer` was reading
  only the low bit of the button bitmap because
  `loc_buttons.size = 1` (the location of Button 1 alone)
  rather than `button_count` (the parser's count of all
  button usages). Effect: every multi-button mouse on UTF
  systems would lose buttons 2-N once inputfs becomes the
  active input path, post-Stage E cutover. Fix is 10 lines
  in `inputfs_extract_pointer`'s button block: build a
  temporary `hid_location` at `loc_buttons.pos` with
  `size = button_count`, read via `hid_get_udata`. Same
  commit shipped output-correctness infrastructure
  (verbose mode in `main.c` triggered by
  `INPUTFS_FUZZ_VERBOSE=1`, `check-corpus.py` runner with
  per-entry expected values, regression test entry
  `23-multi-button-mouse`, `findings.md` documenting the
  bug). Verified on PGSD-bare-metal: 24/24 crash-resistance
  PASS, 14/14 output-correctness PASS, identical to the
  Linux dev environment.

**Out of scope:** coverage-guided (AFL-style) fuzzing,
state-leak detection across extract calls, fuzzing FreeBSD's
hid.c upstream. Each is named in ADR 0014 with a reopen
criterion.

**Why before AD-2:** AD-2 makes inputfs the sole input path
on UTF systems. Panics in the parser become load-bearing
once semainputd is retired. AD-9.1's refactor and AD-9.4's
fixes are cheaper to land while semainputd still exists as
a fallback against inputfs misbehaviour (it is a fallback
that operators can return to without losing input
entirely). Hardening before cutover, not after.

**Depends on:** none. Can land independently of AD-2; the
ordering is preference, not a hard dependency.

**Status:** AD-9 closed. All four sub-stages (AD-9.1,
AD-9.2 a/b/c, AD-9.3, AD-9.4) landed and verified on
PGSD-bare-metal across 14 commits between `4ec0d3b`
(initial ADR) and `3887091` (AD-9.4 with the bug fix),
plus this doc-update commit making 15.
One bug found and fixed (button-bitmap truncation in
`inputfs_extract_pointer`). The corpus +
`fuzz-verify.sh` (24/24 crash-resistance) +
`check-corpus.py` (14/14 output-correctness) form a
regression gate for future parser changes. AD-2 is now
unblocked.

### `[ ]` AD-10: drawfs takes the framebuffer at boot (vs `vt(4)`)  *(Superseded by AD-39, 2026-05-13; goal achieved via kernel compile-out, not this entry's loader.conf mechanism)*

**SUPERSEDED BY AD-39 (2026-05-13/14).** AD-10's *goal* -
drawfs owns the EFI framebuffer at boot with no vt(4)
overdraw - was achieved, but by a different mechanism than
this entry proposed. AD-10's plan was a runtime loader.conf
tunable (`hw.syscons.disable="1"`) that would make `vt_efifb`
decline the framebuffer at attach. AD-39 instead removed
`vt`/`vt_vga`/`vt_efifb`/`vt_vbefb`/`sc`/`vga`/`splash` from
the PGSD kernel config entirely, build-enforced, so there is
no `vt_efifb` to disable. The loader.conf approach (and the
AD-10.2 installer work it implied) is therefore obsolete and
must not be implemented - adding `hw.syscons.disable="1"` on
a PGSD kernel is meaningless (nothing to act on) and on a
generic kernel reintroduces exactly the black-screen risk
AD-39 structurally eliminated. See the AD-39 entry. The
sub-stage detail below is retained for history; AD-10.5
(keystroke handover) closed independently via ADR 0019 and
remains relevant under AD-39 (kbdmux is still compiled in).

**Correction (2026-05-17 audit):** the "vt(4) remains
compiled into the kernel for recovery purposes only" text
below is itself now stale - AD-39 removed vt(4) from the
kernel entirely. Recovery on a PGSD kernel is SSH / serial /
rescue media, not a vt(4) single-user console. The original
re-scope text is preserved unedited below for history; read
it through the AD-39 supersession.

**Tracks**: `drawfs/dev/drawfs/drawfs_efifb.c` and
`drawfs/docs/adr/0001-framebuffer-ownership-at-boot.md`
(written 2026-05-15; drawfs's first ADR file). The ADR
predates the AD-39 decision being recorded; its loader.conf
mechanism is superseded though its problem analysis stands.

**Re-scoped 2026-05-10 under Option Y.** The original framing
of AD-10 was cooperative VT switching: `vt(4)` and drawfs would
share the framebuffer over the system's lifetime, handing off
via `VT_GETMODE` / `VT_SETMODE` ioctls when entering and
leaving UTF sessions. That was the right design when AD-11
(retire vt(4)) was treated as a far-future maybe-never item
and vt(4) was assumed to coexist with UTF indefinitely.

Under Option Y (decided 2026-05-10, recorded in
`docs/sessions/2026-05-10.md`), PGSD systems run a
UTF-native graphical login daemon (`pgsd-sessiond`, SM-1) at
boot. drawfs is the framebuffer driver from the moment the
boot loader hands off; vt(4) does not attach to the
framebuffer in the normal boot path. vt(4) remains compiled
into the kernel for recovery purposes only (boot to
single-user mode with `boot -s`).

This **narrows AD-10's scope**: instead of a runtime VT
handshake, AD-10 becomes "drawfs takes the framebuffer at
early boot before vt(4) attaches in the normal path, and
yields it back when explicitly entering single-user mode."
The cooperative-runtime parts of AD-10.1-.4 below describe
the original design and remain useful as fallback if the
boot-time-takeover approach proves untenable; under Option Y
the simpler boot-time-takeover model is preferred.

**Status 2026-05-15**: the AD-10 ADR has been written
(`drawfs/docs/adr/0001-framebuffer-ownership-at-boot.md`) and
adopts the Option Y boot-time-takeover framing from the start,
as called for here. No AD-10 *code* has landed yet, so there
is still nothing to undo on the implementation side; the
re-scope remains documentation-and-design-only until AD-10.2
begins. The ADR is the authoritative design now; the
sub-stage sketch below predates it and is superseded by the
ADR's own staging where the two differ (the ADR did not
adopt the cooperative-runtime VT-handshake sub-stages; see
its Decision section).

**AD-10.5 closed** independently of the re-scope. The
keystroke-handover sub-stage (kbdmux bridge inside inputfs)
landed via ADR 0019 on 2026-05-09 and is unaffected by Option Y
because it solves a different problem (vt(4) needing keystrokes
during the migration window, regardless of who owns the
framebuffer).

When drawfs maps the EFI framebuffer for its own use,
FreeBSD's `vt(4)` console keeps writing to the same
physical memory. Boot messages, daemon startup logs, and
`dmesg` entries written after semadrawd takes over flash
across the screen behind the UTF surface, and typing into
semadraw-term may produce visible artifacts as `vt(4)`
redraws its scrollback over the just-rendered cells.

**Operator workaround**: `sudo conscontrol mute on` silences
the console immediately without restarting any daemon. This
is documented in INSTALL.md Hazard 7 and is the recommended
mitigation until AD-10 lands.

**Why this is structural, not a quick fix**: `vt(4)` and
drawfs both believe they own the framebuffer. Neither side
currently performs the handshake that would make ownership
exclusive. X11 servers do this with the FreeBSD-specific
`VT_GETMODE` / `VT_SETMODE` ioctl pair (process-controlled
VT switching with `VT_PROCESS` mode and `VT_RELDISP`
acknowledgements). Wayland compositors do the same thing.
UTF needs the same dance — but at the drawfs layer rather
than per-client, since drawfs is the framebuffer owner from
the kernel's perspective.

**Sub-stages** (original sketch, predates the ADR). The ADR
(`drawfs/docs/adr/0001-framebuffer-ownership-at-boot.md`) is
now authoritative for AD-10's design and staging. The sketch
below is retained for history; where it and the ADR differ,
the ADR wins. In particular the ADR did **not** adopt the
cooperative-runtime `VT_PROCESS` / `VT_SETMODE` handshake that
AD-10.2-.4 describe; it chose boot-time takeover instead. Do
not treat AD-10.2-.4 below as the implementation plan; consult
the ADR's Decision and Consequences sections.

- `[x]` AD-10.1: write the ADR. Captured the design space,
  why drawfs is the right layer for the takeover (versus
  per-client), and the lifecycle: who acquires, who releases,
  what happens on crash. Landed 2026-05-15 as
  `drawfs/docs/adr/0001-framebuffer-ownership-at-boot.md`
  (relocated to its correct path in a follow-up; the ADR
  adopts boot-time takeover under Option Y, not the
  cooperative-VT model the next three sub-stages sketch).
- `[ ]` AD-10.2: implement `VT_PROCESS`-mode acquisition in
  drawfs's efifb attach. Drawfs registers itself as the VT
  owner via `VT_SETMODE`, suspends `vt(4)` output, and
  unmaps the console's framebuffer view. Release on
  drawfs unload or panic-recovery.  *(Superseded by the
  ADR's boot-time-takeover design; retained for history.)*
- `[ ]` AD-10.3: handle the VT-switch signals (`SIGUSR1` /
  `SIGUSR2` in classic Linux semantics; FreeBSD uses a
  similar but not identical model). Drawfs needs to
  cooperate with operator-initiated VT switches if any
  remain meaningful in a UTF system, or document why it
  doesn't.  *(Superseded; see ADR.)*
- `[ ]` AD-10.4: bare-metal verification. Boot, take over, write
  to dmesg from another SSH session, confirm no flashes
  appear in the UTF surface. Reverse: release ownership,
  confirm `vt(4)` resumes drawing correctly.  *(The ADR
  defines its own bench-verification stage; this item's
  intent survives but its mechanism is superseded.)*
- AD-10.5: keystroke handover. While AD-10.1-.4 address the
  framebuffer side of vt-versus-UTF coexistence, the keystroke
  side needs the same cooperation. Originally framed
  (2026-05-08) as a `conscontrol mute on/off` symmetric with
  the framebuffer takeover. **Re-scoped 2026-05-08 (later
  same day) after AD-30.1 made the operational gap concrete:**
  with the legacy HID modules (hkbd, ukbd, hms, etc.) removed
  per AD-8's discipline, vt(4) has no keystroke producer and
  console login at ttyv0 stops working. `conscontrol mute`
  cannot solve this; muting vt(4) doesn't restore its
  keystroke input.

  The right design is a kbdmux bridge: a kbd-layer keyboard
  driver inside inputfs that observes inputfs's existing
  keyboard transitions and pushes the corresponding AT
  scancodes into a kbdmux slave ring. vt(4) consumes from
  kbdmux exactly as it would from hkbd. inputfs's exclusive
  HID consumer status (ADR 0018 §3a) is preserved because
  the bridge sits downstream of inputfs's HID parser, not
  at the hidbus attachment layer.

  **Design tracked in ADR 0019** (`inputfs/docs/adr/0019-kbdmux-bridge.md`).
  ADR 0019 supersedes the AD-28 (original) BACKLOG entry's
  pre-implementation source-reading work, lifting it into the
  ADR proper so it is durable design history rather than
  preserved BACKLOG context. The ADR's 8-step implementation
  outline is the work plan; each step is a self-contained
  commit with bench verification.

  Estimate: Medium. ~600-800 lines of kernel C (skeleton +
  softc + intr callback + kbd_register integration + sysctl
  gate), spread across multiple sessions. Bench-verifiable
  per-step. Default-off-then-default-on two-commit pattern
  for safety.

  **STATUS (2026-05-09): closed.** All 8 steps in ADR 0019's
  outline plus a follow-up step 2.5 (extended-key 0xE0 prefix
  encoding) landed and bench-verified. Bridge is active by
  default; `hw.inputfs.kbdmux_bridge=1` since step 8.

  Steps as committed:
    step 1  Skeleton (kbdsw vtable, module load hooks).
    step 2  Per-keyboard softc, lockless SPSC ring, HID-to-AT
            translation table.
    step 3  Producer hook (inputfs_kbd_intr_cb), deferred
            kbdmux notification via taskqueue_fast.
    step 4a Bridge attach/detach lifecycle, kbd_register
            integration. Took three iterations to nail down:
            (i) SI_ORDER_FIRST so kbd_add_driver runs before
            DRIVER_MODULE's NEWBUS attach cascade; (ii) success
            check changed from `error != 0` to `error < 0`
            because kbd_register returns the slot index, not 0,
            on success.
    step 4b Producer wiring at the four publish sites in
            inputfs_keyboard_diff_emit, gated on the sysctl.
            Switched from taskqueue_swi (sleep mutex) to
            taskqueue_fast (spin-safe) after WITNESS caught a
            sleep-from-spin violation on the first bench run.
    step 5  Sysctl gate hw.inputfs.kbdmux_bridge.
    step 6  Bench verification with sysctl off (zero behavior
            change).
    step 7  Bench verification with sysctl on. Console login
            at ttyv0 verified working with HAILUCK touchpad
            keyboard, Broadcom Bluetooth keyboard, Apple
            Aluminum keyboard.
    step 8  Default flipped from 0 to 1.
    step 2.5 Extended-key 0xE0 prefix encoding for arrow keys,
            Right Ctrl/Alt/GUI, Home/End/PgUp/PgDn,
            Insert/Delete, keypad-Enter, keypad-/. Trtab
            widened from uint8_t[256] to uint16_t[256] with
            (prefix << 8) | scancode encoding.

  AD-10.5 closes. AD-10.1-.4 (framebuffer ownership) remain
  open and are tracked separately within this AD-10 entry.
  AD-11 (UTF-native console replacement) supersedes the bridge
  long-term; until AD-11 lands, the bridge is the path that
  keeps ttyv0 login working without legacy hkbd.

**Risks**: getting this wrong manifests as either
(a) `vt(4)` and drawfs both drawing (the current state,
visible flashing), or (b) neither drawing (black screen,
no recovery without serial or SSH). The latter is worse.
Test with serial console available, or with `conscontrol
mute on` already set as a fallback so the failure mode is
the milder one.

**Depends on**: nothing structural. Can land anytime.
Practical ordering: lower priority than AD-2 Phase 2/3
(libsemainput extraction and semainputd retirement), since
AD-10 is a cosmetic/operator-experience fix while AD-2
closes a substrate-level architectural debt.

**Discovered**: bare-metal verification on 2026-05-02.
Symptom: kernel log messages flashing across the screen
behind semadraw-term during the first end-to-end Phase 1
test. Workaround verified on the same session: `conscontrol
mute on` silenced the console without disturbing the
already-running compositor.

**2026-05-04 follow-up**: the operator workaround documented
in INSTALL.md Hazard 7 — adding `conscontrol mute on` to
`/etc/rc.local` to make the mute persist across reboots —
has a real operational cost we did not name in the original
hazard text. With the console muted from boot, the vt(4)
login prompt is also invisible. A bare-metal PGSD machine
configured this way comes up with no working physical
console: SSH access is the only login path. For
single-user dev machines this is acceptable; for multi-user
systems or unattended bare metal it is a footgun. Hazard 7
should reflect this, and AD-10's structural fix (proper
VT_PROCESS-mode handshake) becomes more valuable because it
preserves vt(4)'s login functionality while suppressing
vt(4)'s draw on the framebuffer only when drawfs is the
active owner. The cooperation model is correct precisely
because total mute is operationally too coarse.

There is also a contributing factor that AD-13 names
separately: inputfs's interrupt handler emits a
`device_printf` for every HID report received, which means
typing produces console writes regardless of whether
anything else is logging. Even on an otherwise silent
system, the inputfs spam would make the login prompt
unusable without muting. AD-13 removes that source.
With AD-13 closed and AD-10 not yet landed, the residual
flashing is only legitimate boot/dmesg traffic — annoying
but not constant — and the rc.local mute may not even be
desirable. AD-13 lands first as a correctness fix; AD-10
afterward addresses what remains.

### `[x]` AD-12: Service lifecycle: starts, stops, and dependency ordering  *(Done 2026-05-05, Medium)*

**Tracks**: `install.sh` rc.d generation, `start.sh`,
`inputfs/` (no rc.d service today), and a future ADR
covering daemon-under-dependency-absence behaviour.

UTF's daemons (`semaaud`, `semainput`, `semadrawd`) and
kernel modules (`drawfs`, `inputfs`) have real ordering
relationships — clock publication, surface ownership,
event ring consumption — that are not declared anywhere
the operating system can act on. Friday's bare-metal
verification (2026-05-02) surfaced four distinct symptoms
that all share the same root cause: services start without
their preconditions in place, stop without confirming
death, and accumulate as zombies across debug cycles.

**Symptoms observed** during 2026-05-02 verification:

1. **Zombie semadrawd accumulation across debug sessions.**
   Multiple foreground `sudo semadrawd -b drawfs` invocations
   from earlier debug cycles never died on Ctrl+C. Each
   subsequent service start added another semadrawd to
   `sockstat -u`, each bound to the same socket path.
   Bug 1's fix (commit `f7c71af`) prevents the *symptom*
   (silent displacement) but does not address the orphaning.
   The orphaning is itself a lifecycle problem: stop happens,
   the daemon does not actually die, the next start spawns
   alongside it.

2. **`install.sh` "Text file busy" on running daemons.**
   `cp` cannot replace a binary that is currently being
   executed. `install.sh` does not stop services before
   replacing their binaries, so an upgrade workflow requires
   the operator to stop services manually, run `install.sh`,
   then start services manually. The operator-side dance
   is unnecessary.

3. **rc.d daemon-wrapper edge cases.** `service status` on
   2026-05-02 claimed `semadrawd is running as pid X` while
   `sockstat -u` showed no listener and `lsof` showed no
   process holding the socket fd. The daemon process existed
   but was hot-spinning with no useful work — possibly a
   poll race between fork and bind under `daemon -f`'s
   stdio redirection. We never fully understood this; the
   workaround was to kill the wrapper and run semadrawd in
   the foreground.

4. **"Bug 4": input dead and rendering stuck.** End of
   session 2026-05-02. semadraw-term reaches "session 1
   started", surface allocates, but no rendering and no
   input acceptance. Plausibly a service-ordering issue:
   semadrawd connected before inputfs had attached devices
   or before keystrokes started flowing through the ring,
   and the compositor sat in a state where input was
   nominally enabled but no event delivery happened.

   **2026-05-04 update**: AD-12.3 (rc.d service for inputfs)
   landed and was verified across a reboot. inputfs loads
   automatically before the daemons; semadrawd connects to
   a populated ring with six HID devices attached and 81
   events on the ring. Pointer position confirmed moving
   from default (1920,1080) to (3171,955) under real
   hardware input — the substrate path works end-to-end.
   But typed keystrokes still do not reach the
   semadraw-term prompt. "Bug 4" therefore is **not** a
   service-ordering issue; AD-12.3 closed the
   lifecycle-shaped variant of it without resolving the
   underlying symptom. The remaining "Bug 4" is a real
   input-routing issue downstream of the inputfs ring,
   investigated separately. AD-12.5
   (daemon-under-dependency-absence ADR) is still
   relevant to "what does semadrawd do when the ring
   exists but is silent for too long" but that is a
   different question from "events flow but the prompt
   does not see them."

5. **"Bug 2": semadraw-term `screen.zig:380` panic.**
   Discovered 2026-05-02; characterized 2026-05-04 as
   timing-sensitive. On non-instrumented release builds,
   semadraw-term panics with `index out of bounds: index
   N, len M` at the first character of prompt rendering.
   Three reproductions on 2026-05-02 produced three
   different N/M pairs (`1,1`; `5,4`; `0,0`); the
   2026-05-04 reproduction was `0,0` again. Adding
   `std.debug.print` instrumentation at every array
   access in `putCharWithWidth` makes the panic stop
   reproducing — the prompt renders correctly with the
   instrumented build, no panic on any character.
   Hypothesis: the bug is timing-sensitive, and the
   added latency from print statements on the
   per-character path closes whatever race window
   exists. The interrupt-side per-report
   `device_printf` from inputfs (see AD-13) adds
   similar latency on a different path, and may be a
   confounding factor in why timing has been hard to
   pin down. Filed as a known bug; needs a different
   diagnostic approach (counter-based instrumentation
   rather than print-based, or post-mortem on a
   release-build core dump). Not blocking AD-12
   sub-stages.

   **2026-05-04 update**: AD-13.1 (per-report
   `device_printf` gated behind sysctl, default off)
   landed and was verified on bare metal. Re-running
   release-mode semadraw-term against the new inputfs
   produced **a different panic, in a different file**:
   `vt100.zig:183` rather than `screen.zig:380`. The
   screen.zig panic family (`index 0,0`; `1,1`; `5,4`)
   no longer reproduces; the latency hypothesis is
   confirmed for that bug. What surfaced instead is
   Bug 5 below — the inputfs interrupt-path latency
   was masking a different bug downstream in the
   UTF-8 decoder. With Bug 5 fixed and Bug 2's
   screen.zig family also no longer reproducing,
   "Bug 2" as a separate entry is effectively
   subsumed: the panics on screen.zig were always
   the same Bug 5 path, with release-mode optimization
   pointing at the wrong line. Verification of this
   claim is on the next reproduction attempt with
   AD-13.1 + the Bug 5 fix in place.

6. **"Bug 5": semadraw-term `vt100.zig:183` UTF-8
   decoder out-of-bounds.** Discovered 2026-05-04 after
   AD-13.1 unmasked it. semadraw-term reaches "session 1
   started", prompt renders fully, typing reaches the
   shell — and then the shell's response (typing `ls`
   plus Enter) triggers `panic: index out of bounds:
   index 4, len 4` at `vt100.zig:183` in `decodeUtf8`.
   Root cause: `decodeUtf8` sliced `utf8_buf` by
   `utf8_len` (the number of continuation bytes
   collected) but switched on `utf8_expected` (the
   total bytes the lead byte declared). When the two
   disagreed — through any state-machine path or
   release-mode optimization quirk — the switch arm
   read past `buf.len`. Fix slices by `utf8_expected`
   (so `buf.len` always matches the switch arm) and
   adds a guard that returns null when the lengths
   disagree (so a partial sequence is treated as
   invalid input rather than decoded with stale
   bytes). Two-line guard plus one-line slice change.

   **What this entry does not claim**: the fix
   prevents the panic, but the underlying state-machine
   path that lets `utf8_len` and `utf8_expected`
   disagree (if such a path exists) is not
   identified. The defensive guard makes the
   disagreement impossible to observe; the path may
   still need investigation if Bug 5 turns out to be
   reachable via legitimate input rather than only
   via release-mode optimization quirks.

7. **"Bug 6": semadraw-term `vt100.zig:351` CSI param
   index out-of-bounds.** Discovered 2026-05-04 after
   the Bug 5 fix landed. Re-running release-mode
   semadraw-term with both AD-13.1 and the Bug 5 fix
   in place produced a new panic: `index 3, len 3` at
   `vt100.zig:351:24`, line `self.params[idx] = ...`
   in `handleCsiParam`. Triggered by pressing Enter at
   the prompt — the shell's prompt redraw emits CSI
   sequences, parsing them touches this code path.

   The reported `len 3` is suspicious: `self.params`
   is declared as `[16]u32` and `param_count` is
   bounded at 16 by all writes, so `idx = param_count
   - 1` is in 0..15 and `params[idx]` cannot panic
   with "len 3". Two possibilities: the panic is
   actually in a different array of length 3 that
   release-mode optimization mis-attributed to this
   line, or there is a state-machine path that grows
   `param_count` past 16 that the read didn't find.

   Fix is a defensive cap at the access site:
   `idx = min(param_count - 1, params.len - 1)`. The
   cap costs one min op per CSI digit and makes the
   `params[idx]` access safe by construction
   regardless of whether `param_count` ran away or
   not. If the panic moves to a new file:line on the
   next reproduction, that is a different bug
   downstream and the cap was a useful safety net
   regardless.

   **What this entry does not claim**: the cap
   prevents the panic at this line but does not
   identify the actual source of `len 3` if it is
   elsewhere. Like Bug 5, the fix may be a safety net
   over a deeper state-machine bug. Verification on
   next bare-metal test.

8. **"Bug 7": semadraw-term `main.zig:265` sessions
   index out-of-bounds.** Discovered 2026-05-04 after
   Bug 6 fix landed. Re-running release-mode
   semadraw-term with all of AD-13.1, Bug 5 fix, and
   Bug 6 fix in place produced a new panic: `index 1,
   len 1` at `main.zig:265:31`, line `return
   &(self.sessions[self.active].?);` in
   `activeSession()`. Triggered by typing `ls` and
   pressing Enter at the prompt.

   The reported `len 1` is impossible from any plain
   reading of the source: `sessions` is declared as
   `[MAX_SESSIONS]?Session` where `MAX_SESSIONS = 8`,
   so `sessions.len = 8`, not 1. The implausible
   length value matches the same pattern as Bug 2
   (panic `len M` against `cells.len = 15840`), Bug 5
   (panic `len 4` against `utf8_buf` of length 4 with
   bounds-checked access), and Bug 6 (panic `len 3`
   against `params` of length 16). Four release-mode
   panics in a row with `len M` values that do not
   match the array on the reported line.

   At this point the pattern is unambiguous: **Zig's
   release-mode optimization is mis-attributing panic
   line numbers in semadraw-term**. The actual
   panicking access is somewhere else in the inlined
   call chain that gets attributed to `run`. Adding
   defensive guards at the reported lines (Bug 5 fix,
   Bug 6 fix) made the panic move to a new
   mis-attributed line each time without addressing
   any real bug. The defensive guards are still
   correctness improvements — bounds-cap at the
   access site is cheap insurance — but they were not
   the right diagnostic strategy.

   Bug 7 was not given its own defensive-guard fix.
   Instead, semadraw-term was rebuilt with
   `-Doptimize=Debug` (no inlining, accurate debug
   info), and the panic stopped reproducing entirely
   under the same input sequence. The Debug build
   runs the prompt, types, runs `ls`, displays
   output, returns to a fresh prompt — operationally
   correct end-to-end. ReleaseSafe panics were
   masking real terminal functionality that has been
   working all along.

   Whether the underlying panics are (a) real bugs
   that ReleaseSafe's optimizer triggers and Debug
   avoids, (b) Zig optimizer bugs producing incorrect
   bounds-check code, or (c) timing-sensitive races
   that Debug's slower execution dodges — is open.
   See AD-14 for the structural investigation.

**Wrap-up (2026-05-04 close)**:

The bug-chasing arc above proceeded as a sequence of
defensive guards against panics whose reported
locations did not match any source-readable cause.
After four iterations of this pattern, switching to a
Debug-mode build of semadraw-term produced a
fully-functioning UTF terminal: prompt renders, input
reaches the shell, shell output renders, scrolling
works, the operator can type `ls` and see directory
listings. End-to-end Phase 1 substrate verification
on PGSD bare metal is complete in the operational
sense. The terminal works; only the optimization mode
is degraded.

What this means for AD-12's framing: the lifecycle
work (12.1, 12.2, 12.3, 12.4, 12.5, 12.6 all landed)
is complete as scoped, and AD-12.3 in particular
delivered exactly what it promised — inputfs is
loaded by rc.d in correct dependency order with the
daemons, no manual `kldload` ever needed. The "Bug 4"
input-routing variant attributed to AD-12 was not
service-lifecycle after all; it dissolved naturally
once Bug 5 / Bug 6 / Bug 7 were addressed (or
masked, in the Debug-mode case). AD-12 closes its
named substrate-side scope. The verification gaps
named in `docs/AD12_VERIFICATION.md` are
operator-runnable items rather than open work; the
one item that requires new code (the
deliberate-misordering test) depends on Posture 3
implementation scoped under AD-12.5's ADR for
future daemon work.

The new findings spawn AD-14 (ReleaseSafe vs Debug
build mode investigation) and AD-15 (semadraw-term
cosmetic gaps — partial-screen rendering, missing
status bar). Both filed as separate entries because
they are distinct concerns with their own
investigation paths.

These symptoms are not bugs in the daemons themselves.
They are bugs in the *lifecycle* — what happens during
start, what happens during stop, what each daemon does
when its preconditions are absent.

**The dependency graph that should be declared:**

```
drawfs.ko        (loaded by /boot/loader.conf at boot)
   |
   v
semadrawd        REQUIRE: FILESYSTEMS
   ^
   |
inputfs.ko       (currently /etc/rc.local; should be rc.d)
   ^
   |
semaaud          REQUIRE: FILESYSTEMS  PROVIDES: utf_clock
   ^                                   (via /var/run/sema/clock)
   |
semadrawd        REQUIRE: utf_clock inputfs_loaded
   |
   v
semainputd       REQUIRE: semadraw    (legacy; retiring under AD-2)
```

The drawfs.ko load happens at loader time, so all rc.d
services are guaranteed to start after it. The other
relationships are all currently undeclared.

**Sub-stages**:

- **AD-12.1** *(landed, this commit)*: install.sh hardening
  for upgrade. Stop services before copying binaries; copy
  to temp file and rename for atomicity; restart services
  in the correct order; skip restart if the service was not
  previously running. The `stop_service_if_running` helper
  uses `pgrep -x` (catches both rc.d-managed and direct
  invocations), tries `service NAME stop` first, waits with
  a 5-second timeout, falls through to SIGKILL on timeout.
  The atomic-copy `install_bin` writes to a `.NEW.$$` temp
  path then renames over the destination. The post-install
  restart block restarts in dependency order (`semaaud`
  before `semadraw` before `semainput`) regardless of the
  order services were stopped in. Services that were not
  running before the install are deliberately not started:
  install.sh is an upgrade tool, not a "start everything"
  tool. Also: BINARIES list grew to include `semadraw-term`
  (terminal client documented in INSTALL.md Step 9) and
  `inputdump` (inputfs diagnostic CLI), neither of which
  was being installed despite documentation referencing
  them.

- **AD-12.2** *(landed, this commit)*: rc.d scripts
  declare REQUIRE/PROVIDE per the BACKLOG dependency
  graph. `inputfs` provides `inputfs_loaded`; `semaaud`
  provides `utf_clock`; `semadraw` requires
  `FILESYSTEMS utf_clock inputfs_loaded`; `semainput`
  requires `FILESYSTEMS semadraw` (the dependency
  direction was previously inverted: pre-AD-12.2,
  semadraw required semainput, which made the server
  wait for its client). All four daemons now require
  `FILESYSTEMS` rather than `LOGIN`, since UTF daemons
  run as root via `daemon(8)` and do not depend on
  user-login state. The `BEFORE: semadraw semainput`
  line on inputfs (which expressed the inverse of
  consumer dependency on the provider side) was
  removed in favour of consumer-side `REQUIRE:` lines.

- **AD-12.3** *(landed, this commit)*: rc.d service for
  inputfs. `install.sh` now generates
  `/usr/local/etc/rc.d/inputfs` with `REQUIRE: FILESYSTEMS`
  (so `kldload` runs only after `/var/run` is mounted,
  avoiding Hazard 1's early-boot panic) and
  `BEFORE: semadraw semainput` (so `rcorder(8)` runs
  inputfs before the daemons that read its ring). Enables
  `inputfs_enable="YES"` in `/etc/rc.conf`. install.sh's
  AD-12.1 stop-and-restart sequence detects whether
  inputfs was loaded before the install and, if so, does
  `kldunload` then `kldload` after the userland daemons
  stop and before they restart, so semadrawd is never left
  holding a stale ring view. INSTALL.md Step 7 reduced to
  just drawfs; Step 8 starts inputfs alongside the
  daemons. Hazard 1 rewritten to point at the rc.d
  service as the supported path; the
  `kldload inputfs` in `/etc/rc.local` recipe explicitly
  superseded.

- **AD-12.4** *(landed, this commit)*:
  stop-with-confirmation. The three daemon rc.d scripts
  (semaaud, semainput, semadraw) generated by install.sh
  now have stop functions that send SIGTERM, wait up to
  STOP_TIMEOUT seconds (default 5) for the process to
  exit polling with `kill -0`, escalate to SIGKILL on
  timeout, and preserve the pidfile if SIGKILL also
  fails so a subsequent operator action can find the
  still-alive process. The previous behaviour
  (`kill ${pid}; rm -f ${pidfile}; echo Stopped`)
  could lie when the daemon ignored or didn't receive
  SIGTERM. Mirrors the AD-12.1 install.sh
  `stop_service_if_running` pattern, so install.sh's
  upgrade path and operator-driven `service NAME stop`
  now behave consistently. inputfs's rc.d stop is not
  changed by this sub-stage: kldunload is synchronous
  (the kernel either succeeds or returns EBUSY), no
  timeout is meaningful for it.

- **AD-12.5** *(landed, this commit)*:
  daemon-under-dependency-absence ADR.
  `docs/UTF_DAEMON_DEPENDENCY_ABSENCE.md` states the policy:
  Posture 3 (degraded mode with rigorous advertising) for soft
  substrate dependencies, Posture 2 (exit and let rc.d retry)
  for hard platform dependencies. The ADR explicitly forbids
  Posture 1 (silent retry without advertising) which is the
  Bug 4 shape. Per-daemon application sketched (semaaud,
  semadrawd, semainputd-during-retirement, future daemons).
  Implementation lands as part of AD-12.6, AD-2 Phase 3, and
  future daemon work; the ADR is policy not code. inputfs's
  existing focus-file retry is cited as the precedent and
  template.

- **AD-12.6** *(landed, this commit)*: bare-metal
  verification sign-off. `docs/AD12_VERIFICATION.md`
  records the verification state across the four
  AD-12.6 items: rc.d ordering at boot (verified
  yesterday, full-reboot retest pending after AD-12.2
  changes), install.sh upgrade path (verified
  yesterday with one partial-verification item on
  inputfs.ko refresh detection), SIGTERM-then-SIGKILL
  stop (verified today for normal stop; SIGKILL
  escalation path not yet exercised), and the
  deliberate-misordering test (not yet verified
  because it depends on the Posture 3 implementation
  work that the AD-12.5 ADR scopes for future
  daemon work). Verification gaps are named as
  operator-runnable items rather than hidden under
  a blanket sign-off.

**What this entry does not claim**:

- It does not claim Bugs 2, 3, or 4 from 2026-05-02 are
  *all* lifecycle issues. Bug 2 (semadraw-term putChar
  panic) is plausibly a screen.zig off-by-one that
  reproduces on certain timings; Bug 3 (`/bin/sh`
  silent exit) is plausibly TIOCSCTTY semantics. Both
  may be lifecycle-adjacent (they reproduce only when
  certain timing happens), but they have their own
  investigation paths separate from AD-12. AD-12
  addresses the *class* of issues that arise when
  daemons start without preconditions; some specific
  bugs may dissolve as a side effect, but that's not
  AD-12's commitment.

- It does not propose replacing FreeBSD's rc.d
  framework. rc.d is the platform mechanism for
  service ordering and UTF accepts it as platform
  transport. AD-12 makes UTF use rc.d *correctly*
  rather than working around it.

- It does not commit AD-12 to landing before AD-2
  Phase 2/3 (libsemainput extraction, semainputd
  retirement). AD-12.1 is small enough to land
  immediately; the larger sub-stages can interleave
  with AD-2 work as scheduling permits.

**Discovered**: bare-metal verification 2026-05-02
surfaced symptoms 1-4 above. Discussion 2026-05-04
named the common root cause and filed this entry.
The naming itself is the first piece of work; the
sub-stages are the next.

**2026-06-08 follow-up (install.sh footgun guard).** install.sh now
refuses, with guidance, when launched from inside a semadraw-term
session while semadrawd is running. The AD-12.1 daemon-stop step stops
semadrawd to replace its binary; because semadraw-term draws through
semadrawd, that froze the terminal at "Installing to PREFIX/bin" and
looked like a hang (the terminal kept pumping its PTY and recovered on
the post-install restart, but the frozen display read as a wedge).
Detection is by process ancestry, which survives sudo's environment
scrub and works against the already-running old term binary with no
rebuild; SSH is the recommended path and --allow-semadraw-term
overrides. A SEMADRAW_TERM marker was added to the term's pty child
env (semadraw/src/apps/term/pty.zig) as a secondary signal. install.sh
passes sh -n.

### `[x]` AD-13: inputfs debug logging audit  *(Done 2026-05-05, Small)*

**Tracks**: `inputfs/sys/dev/inputfs/inputfs.c`, specifically
the per-report `device_printf` in `inputfs_intr`
(line 2237 as of `e680358`).

inputfs's interrupt handler logs every HID report to the
kernel console:

```
inputfs5: inputfs: report id=0x00 len=8 data=00 00 0e 00 00 00 00 00
```

The line above is from a real keystroke during 2026-05-04
bare-metal verification; the byte at offset 2 (`0x0e`) is the
HID keycode for the letter 'k'. **inputfs is logging every
keypress and pointer report to /dev/console.** With `vt(4)`
active, those console lines flash across the framebuffer in
real time, including over a vt(4) login prompt. The flashing
"Bug 4" symptom that surfaced 2026-05-02 is partially this:
typing produces console writes that displace whatever was
under the framebuffer, including the legitimate login.

**Impact** has two dimensions:

1. **Operational.** A bare-metal PGSD machine with vt(4)
   visible at boot shows kernel log spam over its login
   prompt as soon as the operator starts typing. The
   workaround (`conscontrol mute on` in `/etc/rc.local`)
   silences the spam but also silences the legitimate
   login prompt — a multi-user machine becomes effectively
   headless. Documented as the AD-10 follow-up below.

2. **Latency.** `device_printf` from interrupt context is
   technically safe on FreeBSD but takes a non-trivial
   amount of CPU per call: a sprintf into the message
   buffer, a console-lock acquire, a memcpy into the
   ring, a `cnputs` per receiver (vt + serial if
   present). On every HID report. For a fast scrolling
   mouse or a typing burst, this adds measurable latency
   to the interrupt path — which is precisely the kind
   of latency that may be implicated in Bug 2's
   timing-sensitive panic, since instrumentation in
   semadraw-term that adds similar latency masks the
   panic. The hypothesis is testable: silencing the
   per-report `device_printf` may be the timing change
   that closes Bug 2 without any further work in
   semadraw-term.

**Origin**: this print is a Stage B/C verification
artifact. During inputfs's bring-up, raw HID report
visibility was useful for confirming the interrupt path
worked end-to-end and that descriptor parsing produced
the expected report shapes. The post-verification
expectation was that this print would be gated behind a
sysctl flag, default off. The gating did not happen and
the print landed in production.

**Sub-stages**:

- **AD-13.1** *(landed, this commit)*: per-report
  device_printf gated behind `hw.inputfs.debug_reports`
  sysctl, default 0 (silent). The hexbuf formatting and
  the device_printf call are both inside the gate, so
  the per-event interrupt-path cost when the sysctl is
  0 is a single int read. Operators reproducing a
  report-decode issue can enable at runtime
  (`sysctl hw.inputfs.debug_reports=1`) and disable
  again with no module reload.

- **AD-13.2** *(landed, this commit)*: audit `inputfs.c`
  for *other* high-frequency `device_printf` /
  `printf` calls. Five hot-path sites identified
  and fixed:

  - `inputfs_intr` (line 2253): report-truncation log
    fires per-report under a malformed device that
    persistently emits oversized reports. Per-softc
    flag `sc_logged_truncated` suppresses repeats
    until a non-truncated report arrives.

  - `inputfs_state_sync_to_file` (line 1119): state
    file write failure fires per kthread tick (~100 Hz)
    under disk full / read-only fs. File-static flag
    `inputfs_state_sync_logged_failure` suppresses
    repeats until a successful write.

  - `inputfs_events_sync_to_file` (line 1358 slot
    write, line 1371 header write): same pattern,
    same per-tick frequency. Flags
    `inputfs_events_slot_logged_failure` and
    `inputfs_events_header_logged_failure`.

  - `inputfs_focus_refresh` (line 1466): focus file
    read failure fires per refresh tick (~100 ms)
    under fs error. Flag
    `inputfs_focus_refresh_logged_failure`.

  Applied the project's existing once-per-error-state
  suppression pattern (mirror of
  `inputfs_focus_logged_absent` from Stage D.1):
  log on entry to error state; clear flag on first
  success after error. Produces exactly one log per
  failure-and-recovery cycle, regardless of how
  long the failure persists. Better suited to error
  paths than ppsratecheck (which logs N per second
  even during a stable error condition); equivalent
  for diagnostic value.

  Sites left as-is because they are not hot:

  - lines 1834, 1846: D.5 valid-byte writes are
    once per `hw.inputfs.enable` edge, operator
    driven.
  - lines 1938, 1949: D.5 publication-gate logs,
    once per `hw.inputfs.enable` edge.
  - lines 1020, 1058, 1073, 1259, 1274, 1418, 1775,
    1784, 963, 968: file-open failures, geometry
    discovery, transform setup — once per attach
    or once per configuration change. Operator
    diagnostic value with no spam risk.
  - line 2278: per-report hex dump already gated
    by AD-13.1's `hw.inputfs.debug_reports` sysctl.
  - lines 2607-2780: attach/detach logs, once per
    device lifecycle.

- **AD-13.3**: same audit for `drawfs.c`, `chronofs/`,
  and the userspace daemons. **Done 2026-05-05.**

  Audit findings:

  - `drawfs/sys/dev/drawfs/drawfs.c`,
    `drawfs_efifb.c`, `drawfs_frame.c`,
    `drawfs_surface.c` — clean. Init/error
    printfs only or zero printfs. No fix needed.
  - `drawfs/sys/dev/drawfs/drawfs_drm.c` line 636 —
    PAGE_FLIP failure printf inside per-frame
    `drawfs_drm_surface_present()`. Same hot-path
    bug class as AD-13.2. **Fixed**: new
    `flip_failure_logged` field on
    `struct drawfs_drm_display` (per-display, mirrors
    AD-13.2's per-softc `sc_logged_truncated`); printf
    gated on the flag, flag cleared on first
    successful flip.
  - `chronofs/` — zero `std.debug.print` calls,
    no hot-path logging surface. Clean.
  - `semadraw/src/daemon/semadrawd.zig`,
    `inputfs_input.zig` — control-path log calls
    only (connect/disconnect, surface lifecycle).
    Clean.
  - `semadraw/src/backend/drawfs.zig` `readFrame()`
    — per-reply log calls in error paths.
    **Deferred**, not landed under AD-13.3:
    userland output is syslog-routed under rc.d,
    not kernel-console; the AD-13 bar (kernel
    console writes that compete with framebuffer)
    does not apply.
  - `semainput/src/device_aggregate.zig` lines
    286-294 — per-event `std.debug.print`
    calls in `writeMappedEvent()`. **Deferred,
    superseded by AD-2 Stage E**: semainputd is
    being retired. Fixing prints in code
    scheduled for deletion is wasted work.
  - `semaaud/src/main.zig` startup `std.debug.print`
    — should use `std.log.scoped` for consistency.
    Cosmetic, not landed.

  Verification: code review only. See
  `docs/AD13_VERIFICATION.md` section 3 for the
  full audit notes.

**Why this matters for AD-2 verification**: AD-2 Phase 1
verification has consistently shown semadraw-term reaching
"session 1 started" but input-routing producing strange
behaviour ("Bug 4"). The inputfs logging makes every
keystroke a console write that competes with the
framebuffer surface, *and* adds latency to the interrupt
path that may or may not be implicated in Bug 2. Closing
AD-13 removes a confounding variable from the Bug 4
investigation: with no console spam from inputfs, the
remaining "input doesn't reach the prompt" symptom is
unambiguously a semadrawd-or-semadraw-term issue, not a
substrate issue.

**What this entry does not claim**:

- Does not claim AD-13 closes Bug 2 or Bug 4. The
  hypothesis that latency reduction will close Bug 2
  is testable but unproven; the hypothesis that
  removing the spam makes Bug 4 visible is also
  testable. Either way, AD-13 is on its own merits a
  correctness fix (production drivers should not
  emit per-event console writes), independent of
  whether it dissolves either bug.

- Does not propose removing the print entirely. The
  per-report visibility is genuinely useful during
  development; the fix is a sysctl gate, not a
  deletion. ADR 0009 (interrupt handler registration)
  treats per-report logging as a verification feature;
  AD-13 makes it a verification feature that is opt-in
  rather than always-on.

- Does not address `dmesg`-archived messages. The
  console-spam issue is about live writes during
  operation; what remains in `dmesg` after the fact is
  fine. The fix is to stop *new* lines from appearing
  per HID report, not to suppress retrospective viewing.

**Discovered**: bare-metal verification 2026-05-04.
Symptom: physical-console login on PGSD shows kernel log
spam interleaved with the login prompt while typing.
`dmesg | tail` revealed the source. Same line that
displaces the login prompt also displaces UTF surfaces,
which is part of the "Bug 4" symptom we have been
chasing as a semadrawd issue.

### `[x]` AD-14: ReleaseSafe vs Debug build-mode discrepancy in semadraw-term  *(Done 2026-05-05, Medium)*

**Root cause (diagnosed and fixed 2026-05-05 Sunday afternoon)**:
`Session.init` in `semadraw/src/apps/term/main.zig` initialised
the vt100 parser with `&scr` where `scr` was a stack-local screen.
The returned `Session` contained a fresh copy of `scr` (Zig
copy-by-value), but `parser.scr` still pointed at the dead
local. Subsequent stack reuse (the next stack frame after
`Session.init` returned) overwrote the dangling target's
`cells.len` with arbitrary values, producing the ReleaseSafe
`index 0, len 0` panic in `putCharWithWidth` at the point of
first dereference.

The bug was timing-sensitive because the dangling target's
contents depended on what other locals the optimizer placed
in the same stack slot. Debug-mode builds added enough
guard padding around variables that the dangling target
remained valid-looking long enough to never panic; ReleaseSafe
builds with aggressive stack layout reused the slot
immediately. Sub-1080p compositor surfaces (pre-AD-15.1)
produced fewer SDCS commands per frame, less stack churn,
and a non-reproducing pattern. The 4x-larger compositor
surface (post-AD-15.1) produced more stack churn, reliable
overwriting of the dangling target, and reliable panic.

The diagnostic path:

- Saturday 2026-05-02: panic first observed; mis-attributed
  to `main.zig:265` (`sessions[active]` against a
  `[8]?Session` array). The `len 1` in the panic message
  was a misleading optimizer artifact.
- Sunday morning: lldb attempted with stripped binary;
  no debug symbols, no diagnosis. Bug stopped reproducing
  at the same time (smaller compositor surface meant less
  stack churn).
- Sunday afternoon: AD-15.1 lands; compositor matches
  framebuffer; bug reproduces reliably again.
- Sunday afternoon (continued): lldb with
  `-Doptimize=ReleaseSafe -Dstrip=false` reveals true
  fault site (`screen.zig`'s `putCharWithWidth` at +829
  bytes into the function). Stack frame analysis shows
  `parser.scr` pointing at deallocated location.

**Fix landed (this commit)**:

- `Session.init` now leaves `parser.scr` set to the
  to-be-discarded local (effectively a placeholder); the
  contract is documented in a comment.
- New method `Session.bindParser` rebinds `parser.scr` to
  point at the session's actual `scr` field. Must be called
  after the Session is in its final memory location.
- Both call sites (`run` for the initial session, `newSession`
  for additional sessions) updated to call `bindParser` after
  the Session is in its array slot.
- The renderer rebinding (`rend.scr = &state.sessions[0].?.scr`)
  that was already present pre-AD-14 is preserved unchanged;
  it indicates the original author understood this issue for
  the renderer but missed it for the parser.

**This closes**:

- AD-14 (the build-mode discrepancy class).
- Bug 2 from 2026-05-02 (`screen.zig:380` panic family).
  The line attribution was a release-mode optimizer
  artifact; the actual fault was always inside
  putCharWithWidth in the dangling-pointer dereference.
- Bug 7 from 2026-05-04 (`main.zig:265` panic).
  Same root cause, different mis-attribution (optimizer
  picked a different bounds check to blame).

**This does not affect**:

- Bug 5 (`vt100.zig:183` decodeUtf8 OOB) — defensive
  guard landed Saturday; kept regardless of AD-14
  outcome since it is correctness insurance for
  malformed UTF-8 input.
- Bug 6 (`vt100.zig:351` handleCsiParam OOB) — same.
- Bug 3 (`/bin/sh` silent exit on TIOCSCTTY) — separate
  pty issue, not a screen issue. May or may not have
  been masked by Bug 2 in earlier sessions.

**Sub-stages (all closed by this commit)**:

- **AD-14.1**: lldb diagnosis. Closed via Sunday-afternoon
  session that produced the actual stack trace and frame
  analysis. Required `scripts/build-releasesafe-symbols-semadraw-term.sh`
  (now in tree) to produce a debuggable optimized binary.
- **AD-14.2**: source audit for UB patterns. Findings
  remain valid as `AD-16` latent screen.zig bugs; none
  was the AD-14 fault. The audit was not the path to
  resolution but is independently useful.
- **AD-14.3**: minimal reproducer. Skipped; the lldb
  trace gave a definitive diagnosis without needing a
  reduced repro.

**Verification on bare metal (pending)**:
operator runs `sudo sh install.sh` (rebuilds binaries
ReleaseSafe-stripped without the diagnostic
`-Dstrip=false`), then `semadraw-term --scale 2`,
types `ls` + Enter at framebuffer keyboard. Expected:
the prompt appears, command runs, no panic.

**Why this took multiple sessions**:
- Saturday: the bug class was characterised but
  mis-attributed (Bug 2/Bug 7 names).
- Sunday morning: lldb attempt without debug symbols
  failed; bug appeared transient (was actually
  geometry-sensitive).
- Sunday afternoon: AD-15.1 created reliable repro
  conditions; debug-symbol build under lldb produced
  the clean diagnosis.

The non-determinism of the panic across runs led to
multiple hypotheses (Zig optimizer bug, timing race,
build-mode-specific UB) that competed for attention
across sessions. The actual cause (dangling pointer
to a stack-local with timing-sensitive overwrite)
fit all observations cleanly in retrospect but was
not the leading hypothesis until the lldb trace
showed `parser.scr` pointing at a freed location.

**Same-day follow-up (HID modifier byte translation)**:
operator verified the AD-14 fix worked (no panic;
prompt visible; can run commands), and immediately
discovered Alt+N (new session) and Alt+W (close
session) had no effect on the framebuffer keyboard.
Diagnosed as a separate latent bug in
`semadraw/src/backend/inputfs_input.zig`: the raw
HID Boot Keyboard modifier byte was forwarded
directly to the backend KeyEvent.modifiers field,
but the two layouts differ. HID modifier byte:
bit 0 = LCtrl, bit 1 = LShift, bit 2 = LAlt,
bit 3 = LMeta (and bits 4-7 the right-side equivalents).
Backend KeyEvent.modifiers byte (per backend.zig
documentation): bit 0 = Shift, bit 1 = Alt,
bit 2 = Ctrl, bit 3 = Meta. The bit positions for
Alt and Ctrl are swapped, and the layout collapses
left/right pairs that HID keeps distinct. Pre-fix:
Alt+N arrived at semadraw-term as Ctrl+N;
session-switch handler's `if (modifiers & ALT == 0)
return false` was always true on Alt presses; the
new-session and close-session paths could never
fire from the framebuffer keyboard.

Fix added a `hidModifiersToBackend` translation
function in `inputfs_translate.zig` (alongside the
existing `hidUsageToEvdev`) and called it in
`inputfs_input.zig` at the point where the
modifier byte is read from the inputfs payload.
The translation folds left/right pairs together
and reorders bit positions. Tests cover the
left-only, right-only, combined, and all-modifiers
cases.

This bug was latent before AD-14 closed. The
single-session terminal worked because typing,
Enter, and arrow keys do not depend on modifier
bits. Multi-session features (Alt+N, Alt+W,
Alt+F1..F8) were not exercised under release-mode
verification until AD-14 was closed; the bug
surfaced immediately when verification continued
past the AD-14 fix. Filed as the same-day
follow-up rather than a separate AD because it
is a single-call-site fix discovered during
AD-14 verification rather than a new
investigation thread.

---

**Original entry, preserved for historical context.** The
Tracks line below and the investigation framing belong to the
2026-05-02 filing of AD-14, before the root cause was
diagnosed. The "future ADR to be written" commitment was
fulfilled implicitly by the closure note above: the diagnostic
work characterised the fault as a stack-local pointer
escaping its frame, and the fix landed as a single-call-site
correction rather than as a new ADR. The original entry is
preserved verbatim so the investigation history remains
readable.

**Tracks**: a future ADR to be written; depends on
diagnostic work to characterize the actual fault.

semadraw-term built with `-Doptimize=ReleaseSafe`
(install.sh's default) panics under normal terminal
operation. Four panic sites have been observed
across 2026-05-02 and 2026-05-04 verification:

- `screen.zig:380` (`putChar`) — Bug 2.
- `vt100.zig:183` (`decodeUtf8`) — Bug 5.
- `vt100.zig:351` (`handleCsiParam`) — Bug 6.
- `main.zig:265` (`activeSession`) — Bug 7.

Every panic reports an `index N, len M` pair where the
`len M` value does not match the array on the reported
source line. `cells.len = 15840` for Bug 2 reported
`len 0`/`len 1`/`len 4`. `params.len = 16` for Bug 6
reported `len 3`. `sessions.len = 8` for Bug 7
reported `len 1`. The only consistent explanation is
that release-mode optimization inlines call chains
into a single function (`run`, in main.zig) and
attributes the panic site to the call-site rather
than the actual access site.

Building semadraw-term with `-Doptimize=Debug` (no
inlining, accurate debug info) makes the panics stop
reproducing entirely under the same input sequence.
The terminal runs correctly: prompt renders, typing
reaches the shell, `ls` runs and displays output, the
operator can use the terminal. **This is the actual
operational state of Phase 1**; ReleaseSafe was
hiding it.

**Hypothesis (not verified)**: there are three
plausible causes, and the diagnostic work is to
determine which:

1. **Real source bug that ReleaseSafe's optimizer
   exposes.** A subtle undefined-behavior pattern in
   the source (e.g., aliasing assumption, signed
   wraparound, uninitialized access) that the
   optimizer assumes-away in a way Debug does not.
   Most likely. A code audit of the hot paths for
   common UB patterns would find this.

2. **Zig optimizer bug.** The optimizer produces
   incorrect bounds-check code or wrong control flow
   in ReleaseSafe mode that would not occur in Debug.
   Less likely given Zig's stability, but possible.
   A minimized reproducer (a small test program
   exhibiting the same panic shape) would
   characterize this.

3. **Timing-sensitive race.** ReleaseSafe runs faster
   than Debug, and faster execution opens a window
   that Debug does not. Bug 2 was characterized this
   way against AD-13's interrupt-path latency; even
   with that latency removed, semadraw-term may
   internally race against semadrawd's surface
   updates or pty I/O. A counter-based instrumentation
   build (low-overhead, doesn't disturb timing) would
   help.

**Sub-stages**:

- **AD-14.1**: build with `-Doptimize=ReleaseSafe
  -Dstrip=false`, run under `lldb`, catch the actual
  fault address. The kernel-reported program counter
  combined with the binary's debug info will name
  the actual access site, regardless of how
  ReleaseSafe inlined the call chain. This is the
  authoritative diagnostic.

  **First attempt (2026-05-05, Sunday)**: built
  semadraw-term with ReleaseSafe + `-Dstrip=false`,
  installed over the install.sh-built binary, ran
  under lldb on bare metal. Result: **the panic did
  not reproduce**, neither under lldb nor when run
  directly without lldb on the same binary. Tested
  with both `--scale 1` (the lldb-default that
  produced 480x134 cells) and `--scale 2` (yesterday's
  240x66 repro path). Neither configuration panicked
  on `ls` + Enter under any condition tried.

  This is itself a result: the AD-14 bug is
  **non-deterministic and state-dependent**, not a
  reliable function of binary contents and input.
  Yesterday's four panics were against the same
  binary class (ReleaseSafe, install.sh-built) with
  the same input (`ls` + Enter); today the same
  configuration is operational. Something in the
  system state — probably daemon ordering, inputfs
  load history, drawfs surface state, or accumulated
  uptime — affects whether the bug fires.

  Implications:

  - The Bug 5 / Bug 6 defensive guards landed
    yesterday may have actually fixed some real bugs;
    we can't tell because the surrounding bug class
    is now intermittent.

  - lldb diagnosis is blocked while the bug doesn't
    reproduce. AD-14.1 cannot make progress without
    a reliable repro.

  - Hypothesis 3 (timing-sensitive race) gains
    weight against hypothesis 1 (deterministic source
    UB), since deterministic source UB would
    reproduce on the same binary with the same input.
    Hypothesis 2 (Zig optimizer bug) remains
    possible if the optimizer's output exhibits
    timing sensitivity.

  - The Debug-mode workaround documented in AD-14
    main entry may be unnecessary as permanent
    operational guidance, since ReleaseSafe is
    sometimes operational. Keep the workaround
    available but stop describing it as the only
    working build.

  Next moves for AD-14.1 when bug next fires:

  - Capture exact system state at the moment of
    successful repro (uptime, daemon start times,
    `kldstat -m inputfs`, `sockstat -l | grep
    semadraw`, recent dmesg).
  - Re-run lldb attempt. If the bug is truly
    transient even within a session, may need
    a panic-pause approach (override
    `std.builtin.Panic` to capture fault info and
    sleep so lldb can attach post-panic).

  **Second observation (2026-05-05, Sunday continuation,
  after AD-15.1 landed)**: bug reproduces reliably
  again. Same machine, same session, same input
  sequence (`ls` + Enter). The change between
  Sunday-morning's non-reproduction and now is
  AD-15.1: semadrawd was restarted with
  `-r 3840x2160` instead of the default 1920x1080.
  The compositor surface is now 4x larger (3840x2160
  vs 1920x1080), and semadraw-term's 3840x2144
  surface fits entirely inside rather than being
  clipped at the 1080-pixel ceiling.

  The correlation suggests the bug is sensitive to
  compositor-surface geometry. Two interpretations:

  - **More rendering work per frame** changes timing
    in semadraw-term's run loop. Compositing 4x more
    pixels takes longer; present() returns later;
    the next iteration starts later. A race between
    PTY drain and frame events would manifest at the
    new timing.

  - **Less SDCS clipping** means more commands
    actually execute against the compositor surface.
    Pre-AD-15.1, most of semadraw-term's SDCS
    commands targeted coordinates outside 1920x1080
    and were silently clipped. Post-AD-15.1, all
    commands execute. A bug exposed only when the
    full render path runs would now manifest.

  Either reading is consistent with hypothesis 2
  (Zig optimizer) or 3 (timing race). Discriminating
  between them remains the AD-14.1 diagnostic
  question.

  Workflow for next lldb attempt (now that the bug
  reproduces reliably): run
  `scripts/build-releasesafe-symbols-semadraw-term.sh`
  (lands in this commit, alongside the AD-14.1
  workflow), then `sudo lldb /usr/local/bin/semadraw-term`,
  set run-args, run, trigger panic on framebuffer
  keyboard. If lldb's presence does not hide the
  bug today (Sunday morning's attempt produced
  non-reproduction under lldb), the `bt`,
  `frame select 0`, and `frame variable` commands
  will name the actual fault site.

- **AD-14.2**: source audit for common UB patterns
  in the panic-path code: integer wraparound on
  unsigned types (`u8 - 1` when the value is 0,
  `usize` arithmetic that overflows), aliasing
  between `*Self` and slice borrows, uninitialized
  memory reads, switch statements that miss cases.
  Concentrate on `vt100.zig`'s state machine and the
  inlined call chain `feed -> handleX -> ...`.

  **First-pass audit findings (2026-05-04, completed
  on Sunday)**: read-through of `screen.zig` (1600 lines),
  `vt100.zig` (1358 lines), `main.zig` (1068 lines), and
  partial `renderer.zig`. Found several latent bugs
  reachable only from specific input sequences not
  exercised by the test that triggered the panics:

  - `screen.zig:386-403` (`putCharWithWidth`): width=0
    combining characters can land on cursor_col == cols
    after a prior put advanced the cursor to the right
    edge, then call `getCellMut(cols, row)` which
    silently returns a pointer one cell into the next
    row (or past `cells.len` at last row, panic).
    Reachable only with combining diacriticals in the
    output stream; not produced by `ls` or basic prompt.

  - `screen.zig:478` (`scrollUp`): `end_row -
    lines_to_scroll` underflows on u32 when
    `lines_to_scroll == end_row + 1`. Reachable from
    CSI `M` (delete lines) with n equal to scroll
    region height. Not produced by basic shell input.

  - `screen.zig:699-703` (`insertChars`): backward
    loop `while (col >= cursor_col + chars_to_insert)`
    runs forever when `cursor_col + chars_to_insert
    == 0`. Reachable from CSI `0@`. Not produced by
    basic shell input.

  - `screen.zig:253` (`getCellMut`): no bounds check.
    Silently corrupts adjacent rows when called with
    `col == cols`. Multiple call sites depend on
    callers honoring the implicit precondition.

  - `screen.zig:1043` (`getVisibleCell`): `rows -
    scrollback_lines_visible` underflows when scroll
    view exceeds screen size. Reachable only with
    active scrollback view, not first-render path.

  None of these fires on the boot-time input
  sequence (init -> render empty -> shell prompt ->
  `ls`). The actual Bug 2/5/6/7 panic vector is
  elsewhere. Filed as separate latent-bug items for
  later cleanup; not the AD-14 root cause.

  **Conclusion of first-pass audit**: hypothesis 1
  (real source UB that ReleaseSafe exposes) became
  less likely. Weight shifted to hypothesis 2 (Zig
  optimizer producing incorrect bounds-check code)
  or hypothesis 3 (timing-sensitive race).
  Discriminating between 2 and 3 needs AD-14.1
  (lldb on the optimized binary, authoritative fault
  address).

- **AD-14.3**: minimal reproducer. Strip
  semadraw-term down to a unit test that panics
  under ReleaseSafe and works under Debug, with the
  smallest possible input sequence. Useful for
  filing upstream if the bug turns out to be a Zig
  optimizer issue, and for regression testing if the
  bug is in our source.

- **AD-14.4**: fix and verify. Whatever root cause
  AD-14.1/2/3 identifies, land the fix and confirm
  ReleaseSafe semadraw-term runs `ls` end-to-end on
  bare metal without panic.

**Operational impact**: install.sh currently builds
ReleaseSafe. Until AD-14 closes, operators running
semadraw-term against the install.sh-installed
binary will hit the panics. Two options for the
interim:

- **Operators run a Debug build of semadraw-term**
  via the `build-debug-semadraw-term.sh` diagnostic
  script in the handoff archive. Slower runtime,
  works correctly. Re-running install.sh restores
  ReleaseSafe (panics return).
- **install.sh option to choose optimization mode.**
  Add `--optimize=Debug` flag that propagates to all
  Zig builds. Documented as "for diagnosing
  AD-14 until closure." This makes the workaround
  first-class without committing to Debug as the
  permanent default.

**Why this matters for AD-2 verification**: AD-2
Phase 2 (libsemainput extraction) and Phase 3
(semainputd retirement) need a working
semadraw-term to demonstrate the cutover works
end-to-end. The Debug-mode workaround is sufficient
for verification but not for production. AD-14 is
not a hard blocker on AD-2 — Debug mode delivers
the verification — but is on the critical path for
shipping a release-quality terminal.

**Discovered**: bare-metal verification 2026-05-04.
Pattern surfaced after four release-mode panics
exhibited the same implausible `len M` attribution.
Debug-mode rebuild produced the working terminal
and confirmed the pattern is build-mode-specific,
not source-defect-specific. The diagnostic strategy
of defensive guards at reported sites (Bug 5 fix,
Bug 6 fix) was abandoned in favour of correct
build-mode diagnosis.

### `[x]` AD-15: semadraw-term cosmetic gaps  *(Done 2026-05-05, Small)*

**Tracks**: `semadraw/src/apps/term/` rendering and
layout code, plus `install.sh` rc.d generation; no
design ADR required.

After Phase 1 verification on 2026-05-04 produced a
working UTF-native terminal on PGSD bare metal, two
cosmetic-or-feature gaps were observed: the surface
did not fill the entire framebuffer, and the virtual
terminal status bar was not visible.

**AD-15 root cause (diagnosed 2026-05-05 Sunday)**:
both gaps share a single root cause — semadrawd's
compositor surface defaults to 1920x1080 (the
hardcoded default in semadrawd's Config struct) but
the actual EFI framebuffer on the development
machine is 3840x2160. The compositor renders
client SDCS commands onto its 1920x1080 surface,
and the drawfs backend's `blitToEfifb` then blits
that 1920x1080 region to the framebuffer at
(0, 0). Result: only the top-left 1920x1080
quarter of the framebuffer is touched.

semadraw-term itself queries drawfs for the
framebuffer geometry via `queryDisplaySize` and
correctly sizes its surface to 3840x2144 (66 rows
of cells plus one row of status bar). The status
bar is rendered at y=2112 within the terminal's
3840x2144 surface — but the compositor's 1080-pixel
ceiling clips everything below y=1080, so the
status bar is invisible. The terminal's "fills
the screen" behaviour fails for the same reason:
the compositor only paints to 1920x1080.

Both gaps therefore have one fix.

**Sub-stages**:

- **AD-15.1** *(landed, this commit)*: install.sh's
  semadraw rc.d script's `start_cmd` queries
  `hw.drawfs.efifb.width` and `hw.drawfs.efifb.height`
  sysctls (already published by drawfs since Stage D)
  and passes `-r WIDTHxHEIGHT` to semadrawd. semadrawd
  now starts with the actual framebuffer geometry
  rather than the 1920x1080 default. The compositor's
  surface matches the framebuffer; the entire
  framebuffer gets painted; semadraw-term's full
  3840x2144 area renders including the status bar.
  Operator workaround until AD-17 lands a principled
  runtime auto-detection in semadrawd itself. Falls
  through to the default if the sysctls are absent
  (drawfs not loaded, or older version).

- **AD-15.2** *(landed by side effect of AD-15.1)*:
  status bar visibility. Was not actually broken in
  the rendering code — the status bar is rendered
  at `bar_y = height_px` within semadraw-term's
  surface, but the compositor clipped it because of
  the AD-15.1 issue. Once the compositor's surface
  matches the framebuffer, the status bar appears
  automatically. No code change in main.zig or
  renderer.zig needed.

**Verification on bare metal**:

  sudo sh install.sh
  sudo service semadraw restart
  service semadraw status
  # expect: "Starting semadraw."
  # expect: "  detected framebuffer: -r 3840x2160" (or whatever
  #         the test machine's framebuffer reports)
  sudo conscontrol mute on
  sudo /usr/local/bin/semadraw-term --scale 2
  # expect: terminal fills the entire screen
  # expect: status bar visible at the bottom (dark gray strip
  #         with " 1 " highlighted in blue for the active session)

**Why AD-17 is filed for the principled fix**:
operator-side resolution detection in install.sh's
rc.d script works for the typical case but bakes
the framebuffer geometry into the start path. If
the framebuffer changes (monitor swap, BIOS
reconfiguration, multi-output setup) without a
restart of the rc.d script, the compositor stays at
the old size. AD-17 captures the runtime fix:
semadrawd queries the drawfs backend at startup
(and on resize) for the detected framebuffer size
and resizes its compositor surface accordingly. The
backend interface gets a new optional method
`getDetectedDisplaySize`; the compositor uses it if
present, falls back to OutputConfig if not. AD-17
is medium-sized (interface change + drawfs backend
+ compositor + semadrawd init); AD-15.1's
operator-side fix is the small immediate fix.

**Discovered**: bare-metal verification 2026-05-04
running the working Debug-mode semadraw-term.
Operator confirmed: black background, white text,
prompt visible, typing produces visible output,
`ls` produces output, fresh prompt appears below
output. Surface does not fill screen; no status
bar visible. Both observations against the same
single-session run.

**Diagnosis recorded**: Sunday session 2026-05-05.
The compositor-vs-framebuffer geometry mismatch was
found by tracing the SDCS rendering path from
semadraw-term through semadrawd's compositor through
drawfs's blitToEfifb. Both reported gaps were
explained by the same hardcoded default in
semadrawd's Config struct, with semadraw-term's own
auto-detection working correctly in isolation.

### `[x]` AD-16: semadraw-term latent edge-case bugs in screen.zig  *(Done 2026-05-05, Small)*

**Tracks**: `semadraw/src/apps/term/screen.zig`; no
ADR required.

The AD-14.2 source audit (Sunday session) found
several latent bugs reachable only via specific
input sequences not exercised by the panic-vector
test. Filed here so they don't get lost; none
blocks AD-14, AD-15, or current operational use.

All five sub-stages landed 2026-05-05.

**Sub-stages**:

- **AD-16.1** (Done): `getCell` and `getCellMut`
  now assert `col < cols and row < rows` before
  computing the cell index. Out-of-range arguments
  are a caller bug; silently returning a pointer
  to the wrong cell would corrupt adjacent rows
  or read past the buffer. The explicit assert
  makes the panic name the actual failure rather
  than appearing later as rendering corruption.

- **AD-16.2** (Done): `putCharWithWidth` now
  rejects `width == 0` codepoints with an early
  return. The Unicode-correct behaviour (merge
  combining marks into the preceding cell as an
  attribute) requires restructuring `Cell` to
  hold a combining-marks list and is out of
  scope for AD-16. The practical-and-safe
  behaviour is to drop the codepoint, which
  prevents the cursor from advancing into a
  position where `getCellMut` (post-AD-16.1)
  asserts.

- **AD-16.3** (Done): `scrollUp` now detects the
  whole-region case explicitly and clears the
  region directly. Pre-fix, when
  `lines_to_scroll == region_height` (or larger
  but capped to it), `end_row - lines_to_scroll`
  underflowed `u32` and the shift-up loop
  computed a garbage upper bound. Post-fix the
  function also returns early for `n == 0`.

- **AD-16.4** (Done): `insertChars` now returns
  early when `chars_to_insert == 0`. Pre-fix the
  backward-copy loop's terminator was
  unreachable because `col >= cursor_col + 0`
  is always true once `col` reaches `cursor_col`,
  and the next `col -= 1` step underflowed
  `u32` to `MAX_U32` and produced an infinite
  loop (or out-of-bounds panic).

- **AD-16.5** (Done): `getVisibleCell` now caps
  `screen_lines_visible` at zero explicitly
  rather than computing `rows -
  scrollback_lines_visible` directly. When the
  user has scrolled back further than the
  screen is tall, the subtraction underflows
  `u32` and produces a near-`MAX_U32` value
  that lets the `screen_row >=
  screen_lines_visible` check wrongly admit
  out-of-range row indices.

- **AD-16.6** (Done 2026-05-11): `deleteChars`
  no longer uses `@memcpy` for the leftward
  shift. Pre-fix, when `chars_to_delete > 0`
  and `chars_to_shift > chars_to_delete`, the
  source and destination slices overlapped,
  and Zig's `@memcpy` panics with "arguments
  alias" on overlapping slices. Triggered in
  practice during 2026-05-11 bench testing by
  running `ls` in `semadraw-term`. Post-fix
  uses a manual forward loop (safe for
  left-shift overlap; symmetric with the
  backward loop `insertChars` uses for
  right-shift, established by AD-16.4). Two
  new test cases cover the overlapping-shift
  case and the `n == 0` no-op case.

**Tests**: nine new test cases added at the
bottom of `screen.zig` exercising each sub-stage's
input sequence. Tests are kept together rather
than scattered into existing test sections so the
audit-to-fix-to-test mapping stays visible.

**Discovered**: AD-14.2 source audit 2026-05-04 /
Sunday continuation. None of these is the AD-14
bug; the panics there fire on input sequences
that don't trigger any of these paths. AD-14
closed independently with the `Session.bindParser`
fix.

### `[x]` AD-17: semadrawd runtime framebuffer auto-detection  *(Done 2026-05-05, Medium)*

**Tracks**: `semadraw/src/backend/backend.zig` (interface +
`DisplaySize` type), `semadraw/src/backend/drawfs.zig` (drawfs
implementation), `semadraw/src/compositor/compositor.zig`
(`initOutput` query path), `install.sh` (rc.d comment block
update reflecting new layering).

semadrawd previously defaulted its compositor surface to
1920x1080 (Config struct hardcoded default in semadrawd.zig
line 35-36). Operators on machines with larger framebuffers
had to pass `-r WIDTHxHEIGHT` explicitly, or AD-15.1's rc.d
workaround had to read the drawfs sysctls and pass `-r WxH`
on their behalf, or the compositor only rendered to the
top-left 1920x1080 region. AD-17 closes this structurally.

All four sub-stages landed in one commit.

**Sub-stages**:

- **AD-17.1** (Done): backend interface adds optional vtable
  method `getDetectedDisplaySize: ?*const fn (ctx: *anyopaque)
  ?DisplaySize = null`. New `DisplaySize` struct with `width`
  and `height` fields, deliberately separate from
  `FramebufferConfig` (which carries format and scale that
  aren't backend-detected). Wrapper method on `Backend` does
  the standard optional-vtable dispatch returning `null` for
  backends that don't implement detection. Pattern matches
  existing optional methods (`getKeyEvents`, `getMouseEvents`,
  `getPollFd`, clipboard methods).

- **AD-17.2** (Done): drawfs backend implements
  `getDetectedDisplaySizeImpl`, returning `{efifb_width,
  efifb_height}` when `efifb_avail` is true and both
  dimensions are non-zero, null otherwise. The fields are
  populated during `init` via `probeEfifb` (one
  `DRAWFSGIOC_GET_EFIFB_INFO` ioctl), so the query path has
  no detection cost — just returns already-known values.
  Vtable entry added.

- **AD-17.3** (Done): compositor's `initOutput` queries the
  backend's `getDetectedDisplaySize` after creation. If
  non-null and different from the configured `width`/`height`,
  builds `actual_config` with the backend's reported size and
  uses that for the rest of the function. `output.config`
  stores the resolved size so subsequent compositor code
  (damage tracker at line 232-233, frame scheduler) reads
  consistent values. Override is logged at info level so
  operators see when it happens.

- **AD-17.4** (Done): install.sh's rc.d-side detection
  retained as defense-in-depth, comment block rewritten to
  reflect the new layering. AD-17 is now the primary
  mechanism (semadrawd's drawfs backend reports the size
  directly to the compositor); the rc.d detection remains
  as a fallback that runs before semadrawd starts. Both paths
  read the same `hw.drawfs.efifb.{width,height}` sysctls so
  they agree by construction. Cost is ~12 lines of
  well-commented shell; benefit is that operators get the
  right resolution even if AD-17's backend path has a subtle
  bug or regresses in a future commit. Start log message
  updated to reflect that the negative case (rc.d detection
  unavailable) is no longer a degradation — semadrawd's
  backend detection still runs.

**Design decisions captured in commit message**:

- `DisplaySize` is a new type rather than reusing
  `FramebufferConfig`. Format and scale are compositor-side
  choices, not backend-detected.
- Detection runs at `initOutput` only, not on a periodic
  poll or via backend-pushed events. PGSD bare metal does
  not hot-plug displays; EFI framebuffer geometry is fixed
  at boot. Hot-plug or window-resize support would be a
  separate AD if it ever becomes needed.
- AD-15.1 retained, not removed. Belt-and-suspenders: both
  paths read the same sysctls, agree by construction, and
  the rc.d path provides defense-in-depth against bugs in
  the AD-17 path.
- Single commit covers all four sub-stages because each
  individual change is small and they only make sense together.

**Discovered**: AD-15 diagnosis on Sunday 2026-05-05.

### `[ ]` AD-19: rc.d daemon supervision and log capture  *(Superseded by AD-20, 2026-05-06)*

**Status**: This AD attempted to solve daemon log capture and
restart-on-exit through `daemon(8)`'s built-in supervision mode
(`-r -R -C -P -p -S -T`). The first implementation shipped with
two flag mistakes (an invented `--restart-enable-grace` and a
redundant `-r` alongside `-R`), surfaced when vic tried to start
the supervised wrappers on bare metal — the failure prompted a
re-read of `daemon(8)`'s actual man page. After that re-read, the
supervision capabilities `daemon(8)` actually offers were
clearly weaker than initially described. In particular,
`-C / --restart-count` is a *total* restart cap (1-128 over
process lifetime), not a time-windowed flap detector. Calling it
"flap protection" was misleading.

After the re-read, vic chose to switch to s6-based supervision
instead. Reasoning: s6 is purpose-built for supervision, has
proper foreground execution conventions (no auto-backgrounding
hack), supports readiness notification, and exposes the
primitives needed to implement a real time-windowed flap
detector through the `./finish` script and death-tally tracking.
`daemon(8)` was being asked to do something it was not designed
to do well. AD-20 captures the s6 work; the daemon(8) approach
documented here is left as historical record.

**Tracks (historical)**: `install.sh` rc.d generation for
semaaud, semainputd, semadrawd. Original gap (logging): the
`daemon -f` invocations sent stdin/stdout/stderr to `/dev/null`,
discarding all daemon output under rc.d launch. Second gap
surfaced during AD-19 design (supervision): no restart-on-exit.

**What was attempted**: rewrite each rc.d wrapper to use
`daemon(8)`'s full supervision mode with two pidfiles
(supervisor + child), `-R` for restart delay, `-C` for total
restart cap, `-S -T` for syslog routing. Two intermediate
commits landed (e94dfaa, with the flag mistakes; a follow-up
flag-correction was sketched in sandbox but not pushed before
the s6 pivot).

**Why superseded rather than fixed**: even with the daemon(8)
flag mistakes corrected, the result would not have offered
real flap protection. The total-restart-cap semantic is
adequate as a backstop but it is not what a supervisor with
a proper supervision-tree design provides. s6 makes the
distinction visible: `max-death-tally` records death events,
the `./finish` script applies operator-defined policy, and a
flap detector that genuinely tracks deaths-per-time-window is
straightforward to write. Choosing s6 trades a small
operational complexity increase (an additional supervisor
running, a service-directory layout to maintain) for a
substantial robustness improvement and a cleaner discipline
fit (FreeBSD's existing tool, used as it was meant to be used,
rather than `daemon(8)` stretched into a role it does not fit).

**Discovered**: 2026-05-05, while verifying AD-17.
**Superseded**: 2026-05-06, after vic tested the broken
supervised wrappers on bare metal and we collectively
re-read `daemon(8)`'s man page, then re-read s6's
documentation, and concluded s6 is the right primitive.

### `[x]` AD-20: switch to s6-based daemon supervision  *(Closed 2026-05-09, Medium)*

**Tracks**: `install.sh` rc.d generation for semaaud, semainputd,
semadrawd, plus a new scan-directory layout and
`s6-svscan` rc.d entry. Replaces AD-19's `daemon(8)`-based
approach.

**What changes**:

The three UTF daemons (semaaud, semainputd, semadrawd) move
from `/usr/sbin/daemon` supervision to s6-based supervision
provided by the `sysutils/s6` FreeBSD package. The change
gets us proper supervision-tree semantics, foreground daemon
execution (no `-f` hack), real time-windowed flap protection
through a custom `./finish` script, and clean log capture
with optional `s6-log` chaining.

**Architectural choices** (from the AD-20 design discussion
2026-05-06):

- **Plain s6, not s6-rc.** Three daemons with simple linear
  ordering already encoded by rc.d's `REQUIRE`/`BEFORE` lines.
  s6-rc would add a compiled service database with no
  benefit at this scope.
- **Compose, not replace, the rc.d interface.** Operators
  continue to use `service semaaud start|stop|restart|status`.
  The wrappers become thin shims that translate to
  `s6-svc -u`/`-d`/`-r` commands against the corresponding
  service directory. UTF stays friendly to the standard
  FreeBSD service ecosystem; the s6 plumbing is hidden by
  default but available to operators who want it directly.
- **Scan directory at `/var/service/utf/`.** Matches s6/runit
  convention. Keeps configuration-ish content out of
  `/usr/local/etc/`. The directory contains one
  subdirectory per UTF daemon, plus a `.s6-svscan/`
  control directory for scan-level configuration.
- **One `s6-svscan` for UTF specifically, not system-wide.**
  We do not take over the operator's system supervision
  tree. A single `s6-svscan` process, started by an rc.d
  entry, supervises only the three UTF daemons.
- **Flap-protection policy via `./finish` script.**
  s6 has no built-in time-windowed flap detector, only a
  death tally. Each UTF daemon's `finish` script reads the
  tally, decides whether the recent death pattern indicates
  a permanent failure, and exits 125 if so (which tells
  s6-supervise to leave the service down). Default policy:
  if the service died <10 seconds after starting, count it
  as a "fast crash"; if ≥5 fast crashes accumulated in the
  last ~45 seconds, exit 125. Operators can tune via
  per-daemon environment variables.

**Layout**:

```
/var/service/utf/
├── .s6-svscan/
│   └── finish              # what to do when s6-svscan exits
├── semaaud/
│   ├── run                 # exec semaaud in foreground
│   ├── finish              # flap-protection policy
│   ├── max-death-tally     # how many deaths to remember
│   └── env/                # optional environment vars
├── semainputd/
│   ├── run
│   ├── finish
│   └── max-death-tally
└── semadrawd/
    ├── run
    ├── finish
    └── max-death-tally
```

**rc.d layer**:

- New: `/usr/local/etc/rc.d/utf-supervisor` launches and
  controls `s6-svscan /var/service/utf` as the single UTF
  supervision-tree entry point. Provides `utf_supervisor`
  rcvar.
- Modified: `/usr/local/etc/rc.d/{semaaud,semainput,semadraw}`
  rewritten as thin shims. `start` translates to
  `s6-svc -u /var/service/utf/<name>`; `stop` to
  `s6-svc -d ...`; `restart` to `s6-svc -r ...`;
  `status` to `s6-svstat /var/service/utf/<name>` plus
  exit-code interpretation.

**Sub-stages**:

- **AD-20.1**: scan-directory layout. Service directories,
  `run` scripts, `finish` scripts (flap protection), and
  `.s6-svscan/finish` written into the repo at `s6/utf/`
  for `install.sh` to copy.
- **AD-20.2**: install.sh integration. Add `pkg install s6`
  prerequisite check; install the scan directory to
  `/var/service/utf/`; rewrite the three rc.d wrappers as
  thin s6-svc shims; add the new `utf-supervisor` rc.d
  entry. Strip the `daemon(8)` supervision flags introduced
  in AD-19.
- **AD-20.3**: bare-metal verification protocol. Bring up
  `service utf-supervisor start`; verify
  `s6-svscan` is running; `service semaaud start` brings
  the daemon up via s6-svc; kill the daemon by hand and
  verify s6-supervise restarts it; trigger 5 fast crashes
  and verify the finish script exits 125 and s6-supervise
  honors that; verify clean shutdown via
  `service utf-supervisor stop`.

  **Verification finding (2026-05-06)**: The first AD-20.2
  install.sh shipped with `daemon -P pidfile -f` for the
  utf-supervisor rc.d. On bare metal, this caused
  `s6-svscan` to start and stay alive but **never spawn its
  s6-supervise children**. The supervision tree was silent:
  no per-service supervisors, no log processes, no daemons.

  Initial wrong diagnosis (claude, 2026-05-06): hypothesised
  that `-f`'s /dev/null'd stdio was the cause. Patched
  install.sh to drop `-f` and use `-o /var/log/utf/svscan.log`
  instead. The patch landed and was tested on bare metal; the
  bug persisted unchanged. The hypothesis was wrong.

  Correct diagnosis (after reading
  /var/log/utf/svscan.log post-fix-attempt and re-reading
  s6-svscan.c): the FreeBSD port of s6 (sysutils/s6 2.14.0.1)
  compiles s6-svscan with `S6_EXTBINPREFIX` as the empty
  string. s6-svscan calls `cspawn("s6-supervise", ...)` —
  bare name, no absolute path. cspawn delegates to
  posix_spawnp which does PATH lookup. rc.subr's default
  PATH is `/sbin:/bin:/usr/sbin:/usr/bin` — does not include
  `/usr/local/bin` where s6-supervise lives. The lookup
  fails with ENOENT, surfaced in svscan.log as:

    s6-svscan: warning: unable to spawn s6-supervise for
      <name>: No such file or directory

  Manual sudo invocations of the same daemon(8) command
  succeed because the operator's interactive shell has
  /usr/local/bin in PATH. Direct invocation of s6-supervise
  by absolute path also works (we have an absolute path to
  give it). Only the rc.d-launched code path is broken, and
  only because of PATH inheritance.

  The actual fix: prepend `/usr/local/bin` to `PATH` in the
  utf-supervisor rc.d script, before invoking daemon(8).
  daemon(8) inherits PATH and propagates it to s6-svscan,
  which then finds s6-supervise via posix_spawnp. The `-o
  /var/log/utf/svscan.log` flag is kept (precisely how this
  bug got diagnosed — without that capture, the
  posix_spawnp ENOENT message would have been silently
  discarded to /dev/null).

  Lesson on diagnostic discipline: the first hypothesis
  ("-f's stdio handling") was unverified speculation. The
  correct diagnosis required reading svscan.log AND reading
  s6-svscan.c. Empirical fix-and-test without source
  reading produced a wrong patch that wasted a round-trip.

  Separately, the same diagnostic round surfaced a second
  bug: `.s6-svscan/finish` invoked `exec /bin/true`, but
  FreeBSD's /bin does NOT include `true` — it ships only as
  a shell builtin in /bin/sh. Replaced with `exit 0` which
  has no external dependency.
- **AD-20.4**: README.md / INSTALL.md note: where logs
  appear (s6-supervise's stderr by default; route to
  `s6-log` for proper rotation if desired); how operators
  interact with s6 directly when they want to.

**Cost reality check**: This is Medium, not Small. The
substrate is small (a handful of shell scripts and rc.d
entries) but the verification surface is broader than
AD-19's: the s6-svscan tree itself has to come up cleanly,
shutdown ordering matters (s6-svscan stop must propagate
to children), and the flap-protection finish script needs
its own test for the time-window math. Worth the cost.

**Discovered**: 2026-05-06, when vic discovered the AD-19
daemon(8) approach was producing the wrong shape of solution
and proposed s6 as the better-designed alternative. Confirmed
through reading skarnet.org's s6 documentation (overview,
servicedir, s6-supervise, s6-svc) plus the FreeBSD ports
listing.

**STATUS (2026-05-09): closed.** All three substages plus the
2026-05-06 verification finding's bench-discovered fixes
landed in source. Bench-verified active: 2-service supervision
tree (semaaud + semadrawd) running under s6-svscan via the
`utf-supervisor` rc.d entry, ten total processes (eight
supervision processes plus two supervised daemons), per-service
logs at `/var/log/utf/<name>/`, flap protection wired through
`./finish` with default thresholds (10s lifetime, 45s window,
5 fast crashes).

  **AD-20.1** scan-directory layout, landed at `s6/utf/`:
    `.s6-svscan/finish`, `finish.template`, and per-service
    `run`, `finish`, `log/run` for `semaaud` and `semadrawd`.
    `semainputd/` correctly absent (retired 2026-05-08, AD-2a
    Phase 3 step 2).
  **AD-20.2** install.sh integration, landed: pkg dependency
    check (s6-svscan / s6-svc / s6-svstat / s6-svok / s6-log);
    scan-directory copy to `/var/service/utf/`; per-service log
    directories at `/var/log/utf/`; `utf-supervisor` rc.d entry
    launching `s6-svscan` via `daemon(8)`; two thin shims
    (`semaaud`, `semadraw`) translating to `s6-svc`; daemon(8)
    supervision flags from AD-19 stripped; semainputd cleanup
    block for upgrades (reaps the binary, the rc.d shim, the
    rc.conf enable flag, and any stale
    `/var/service/utf/semainputd` directory).
  **AD-20.3** bench-discovered fixes, landed in source as
    code with diagnostic comments preserved:
      (i) `/usr/local/bin` PATH prepend in the `utf-supervisor`
          rc.d so `s6-svscan` can `posix_spawnp("s6-supervise")`
          (rc.subr's default PATH excludes `/usr/local/bin`).
          The original wrong hypothesis (`-f`'s stdio handling)
          and its lesson are kept as a comment in the rc.d
          generator.
      (ii) `/usr/local/bin` PATH prepend in the `semaaud` and
          `semadraw` rc.d shims so `s6-svc -uwu` can exec
          `s6-svlisten` internally.
      (iii) `-o /var/log/utf/svscan.log` on `s6-svscan` so its
          own diagnostic stderr survives capture; this is what
          let the original PATH bug get diagnosed.
      (iv) `.s6-svscan/finish`: `exec /bin/true` →  `exit 0`
          (FreeBSD's `/bin` ships no `true` binary; only the
          shell builtin).
      (v) Early-boot `supervise/` directory guards in `run` and
          `finish`: skip the start-marker write and the
          flap-accounting bookkeeping if `<svcdir>/supervise`
          doesn't yet exist (s6-supervise creates it on first
          invocation; cold boot can race the run script).
      (vi) Explicit `/var/log/utf/` creation in install.sh.
  **AD-20.4** documentation, landed: INSTALL.md Step 6, Step 8,
    Step 8.5 cover install / start / verify; `s6/README.md`
    covers layout, supervision model, operator interaction,
    flap protection, and editing notes.

  AD-20 closes. AD-19 (superseded) remains marked superseded in
  its own entry; the bridge from `daemon(8)` to s6 is complete.

**Tracks**: `install.sh` rc.d generation for semaaud, semainputd,
semadrawd. Originally filed as a logging-only gap; expanded
during implementation to cover restart-on-exit and flap
protection alongside, since both are configurable on the same
`daemon(8)` invocation and the cost of doing them together is a
single line edit.

**Original gap (logging)**. `daemon(8) -f` redirects stdin,
stdout, and stderr from/to `/dev/null`. semaaud, semainputd, and
semadrawd all write log output via `std.log` (stdlib default
`logFn`, which writes to stderr). Result: when any of the three
daemons was started via its rc.d service, **its log output was
discarded entirely**. No log file, no syslog forwarding, no
capture path. AD-13.2's once-per-error-state log suppression and
AD-17's override message both produced output that was
operationally invisible under rc.d launch.

**Second gap surfaced during AD-19 design (supervision)**. The
original `daemon -f -p ${pidfile}` wrappers also lacked
restart-on-exit. If any of the three daemons crashed, it
stayed dead until manual `service start`. No flap protection
either, since there was no restart logic to flap.

**Fix landed**: rewrite each rc.d wrapper to use full
`daemon(8)` supervision instead of the degenerate
fork-and-detach mode. Both gaps close in a single change set.

The fix uses FreeBSD's existing `daemon(8)` capabilities —
**no UTF-specific supervisor was built**. Reasoning recorded
in the discussion of this AD: the systemd / dinit / s6 shape
of supervisor solves problems we don't have (dependency
graphs beyond rcorder, socket activation, cgroup tracking,
unified config language), and would be substrate work in
AD-3-and-after territory. `daemon(8) -r -R -S -T` plus
`--restart-count` plus `--restart-enable-grace` covers the
operational requirements (restart, backoff, flap protection,
log capture, syslog tagging) at zero new infrastructure cost
and no discipline-test failures.

**Per-daemon flag pattern** (semaaud shown; semainput and
semadraw use the same shape with their own pidfile and tag):

```
/usr/sbin/daemon \
    -P "${supervisor_pidfile}" \    # rc stop targets this
    -p "${pidfile}" \                # child pid for status checks
    -r -R "${semaaud_restart_delay}" \
    --restart-count "${semaaud_restart_count}" \
    --restart-enable-grace "${semaaud_restart_grace}" \
    -S -T "${name}" \                # syslog with tag
    -f ${command} ${semaaud_flags}
```

Defaults: `${semaaud_restart_delay}=5`, `${semaaud_restart_count}=5`,
`${semaaud_restart_grace}=10`. Operators can override via rc.conf
the standard FreeBSD way (e.g. `semaaud_restart_count="10"`).

**Pidfile semantics**. The wrapper now writes two pidfiles per
daemon:

- `${supervisor_pidfile}` (e.g. `/var/run/semaaud.supervisor.pid`):
  the long-lived `daemon(8)` process. `service stop` SIGTERMs
  this, which causes the supervisor to exit cleanly and SIGTERM
  the child as part of its shutdown.
- `${pidfile}` (e.g. `/var/run/semaaud.pid`): the current child
  pid. Refreshed by `daemon(8)` after each restart. Useful for
  status checks and for operator visibility into what the live
  child pid is at any moment, but not the kill target.

**Status command**. `service semaaud status` (and equivalents)
distinguish three states:

- Running normally: both supervisor and child alive.
- Supervisor running but child not currently alive (transient,
  during a restart backoff window): "supervisor running but
  child not currently alive (restarting?)".
- Not running: no supervisor pidfile, or stale.

**Logging destination**. `-S -T <name>` routes child output
through syslog with a tag. `tail -f /var/log/messages | grep
semaaud` works. Operators who want per-daemon files can add a
`syslog.conf` rule directing `local0.*` (or the chosen tag) to
`/var/log/sema/<name>.log` with `newsyslog.conf` for rotation.

**Sub-stages**:

- **AD-19.1**: install.sh rc.d generation rewritten for all
  three daemons. Each gets `-P` + `-p` + `-r -R` + flap
  protection + `-S -T`. Stop function targets supervisor pid
  not child pid. Status function distinguishes the three
  states above. *Landed.*
- **AD-19.2**: bare-metal verification — kill child manually
  and confirm supervisor restarts it; kill 5 times in 10s
  and confirm flap protection kicks in; check that
  `service stop` cleanly stops both supervisor and child;
  check syslog shows daemon output. *Pending vic's bare-metal
  test.*
- **AD-19.3**: README.md / INSTALL.md note where logs live
  and how to filter. *Pending.*

**Discovered**: 2026-05-05, while verifying AD-17. Expanded to
combined scope when the design discussion surfaced that the
supervision question was a one-flag-away problem on the same
`daemon(8)` invocation we were already touching for the log
capture.

### `[x]` AD-21: Mouse cursor sprite rendering  *(Closed 2026-05-07, Medium-Large)*

Surfaced during AD-2a Phase 1 verification on 2026-05-06.
Pointer events flow correctly end-to-end (verified via
`inputdump events` on the kernel side, and click-and-drag in
semadraw-term confirms events route to the client), but **no
visible cursor sprite tracks the pointer position** anywhere
on screen. Searching the tree:

  - `semadrawd` does not draw a cursor sprite. The compositor
    routes pointer events to the focused surface but does not
    own a screen-level cursor.
  - `semadraw-term`'s "cursor" rendering (renderer.zig) is
    the terminal text cursor (block at `cursor_col`,
    `cursor_row`), not a mouse pointer.
  - No file under `semadraw/src/` matches a `drawCursor` /
    `pointer_cursor` / `mouse_cursor` / `drawSprite` pattern.

This is **not a Phase 1 regression**. Pre-cutover (semainputd
era), the cursor was equally invisible — the legacy injection
path also didn't draw a sprite. It is a missing feature that
becomes more visible now that the input substrate is stable
and operators are exercising the system.

**Architecture decided 2026-05-06** in
`semadraw/docs/adr/0005-cursor-surface.md` (semadraw ADR 0005).
Cursor is a compositor-managed surface owned by semadrawd; sits
at a reserved high z-order above all client surfaces; receives
position updates each composition cycle from the inputfs state
region; supports a SET_CURSOR IPC for focused clients to
replace the sprite. Damage propagation when the cursor moves
walks underlying surfaces in z-order and marks intersected
rectangles dirty, using existing damage_tracker APIs (no
new damage tracker public surface needed).

Re-estimated **Medium-Large** (was Small-Medium) because the
ADR design includes a SET_CURSOR IPC, hotspot semantics,
position-pump damage propagation, default-sprite SDCS encoding,
and the visibility-toggle for the no-geometry case. The
implementation breakdown:

  1. **ADR 0005** — design captured, reviewed, accepted.
     *Done 2026-05-06 (commit a2ce729).*
  1.5. **drawfs and software backend offset support** —
     surfaced 2026-05-06 during sub-item 3 design work as
     a latent prerequisite. The drawfs and software
     backends currently ignore `request.offset_x` /
     `request.offset_y` (only Vulkan, X11, vulkan_console
     apply the offset); SDCS commands inside their
     `executeSdcs` paths write pixels at the SDCS-supplied
     coordinates directly into the full-screen framebuffer
     with no offset applied. The cursor surface is the first
     surface that genuinely needs to render at a non-origin
     position while another surface occupies origin, so the
     fix becomes load-bearing here. Thread `offset_x`/`y`
     through `renderImpl` → `executeSdcs` →
     `executeChunkCommands` → each opcode handler; add the
     offsets to the x/y arguments at each `fillRect` /
     `strokeLine` call site. ~50-100 lines per backend.
     Documented as ADR 0005 section 3a. *Done 2026-05-06
     (commit pending push).* Came in at +41/-19 lines
     across both backends — under the estimate because the
     change is a mechanical parameter thread plus
     coordinate addition at four opcode handlers in drawfs
     and one in software (FILL_RECT, STROKE_RECT,
     STROKE_LINE, DRAW_GLYPH_RUN in drawfs; FILL_RECT in
     software). Helpers (fillRect / strokeRect / strokeLine)
     remain unchanged. Regression-safe for surfaces at
     position (0, 0) — bit-for-bit identical behaviour.
  2. **Z-order reservation** — define `Z_ORDER_CURSOR` and
     `Z_ORDER_CLIENT_MAX` constants; clamp client setZOrder
     requests to the client range. *Done 2026-05-06
     (commit pending push).* Small.
  3. **Cursor surface init** — semadrawd creates the daemon-
     owned surface during init(); attaches an embedded
     default-arrow SDCS buffer; sets z_order to
     `Z_ORDER_CURSOR`. Depends on sub-item 1.5 for visible
     output. *Done 2026-05-06 (commit pending push).* Small;
     +78 lines on `semadraw/src/daemon/semadrawd.zig`. The
     cursor surface sits at (0, 0) until the position pump
     (sub-item 5) lands. Marks the cursor for initial damage
     so the first composite cycle renders it.
  4. **Default sprite generation** — small build-time helper
     producing the 24×24 arrow as an embedded SDCS byte
     array. Reuses the existing `sdcs_make_glyph` utility
     pattern. *Done 2026-05-06 (commit pending push).* Small;
     stepped-triangle arrow, 16 rows, 1328-byte SDCS asset
     at `semadraw/src/daemon/cursor_arrow.sdcs` (daemon-local
     so `@embedFile` resolves without extra build wiring).
  5. **Position pump in composite loop** — read inputfs
     state, compute cursor position with hotspot offset,
     propagate damage to underlying intersected surfaces,
     update cursor surface position. Depends on sub-item
     1.5 to actually move pixels around the screen. *Done
     2026-05-06 (commit pending push).* Medium; ~140 lines
     of pump method on `semadrawd.zig` plus a 38-line
     `pointerSnapshot` addition to `shared/src/input.zig`
     (ships as a separate prior commit). Lazy-opens the
     StateReader so semadrawd can start before inputfs is
     up; runs every main-loop iteration with a cheap
     no-change path (one atomic load + a few f32 compares,
     no syscalls past the open). Damage propagation walks
     visible surfaces with `z_order < Z_ORDER_CURSOR`,
     intersects bounds with old and new cursor rects, and
     records damage in surface-local coords. Per ADR §4,
     damage runs before the position update so underlying
     surfaces are repainted for both the old and new
     cursor positions before the cursor moves.
  6. **Hotspot fields on Surface struct** — extend the
     surface struct with `hotspot_x`, `hotspot_y` (i32);
     used only by the cursor surface; default 0. *Done
     2026-05-06 (commit pending push).* Small.
  7. **SET_CURSOR IPC** — request/reply opcodes,
     focus-validated handler, sprite size limits,
     buffer-replace path. *Done 2026-05-06 (commit pending
     push).* Medium; ~370 lines across three commits:

     a. Regression fix (commit pending push):
        `getTopVisibleSurface` skips daemon-owned surfaces.
        Surfaced during sub-item 7 design as a regression
        introduced by sub-item 3 — after the cursor surface
        existed, every key/mouse/gesture event was dropped
        because input routing landed on the cursor surface
        (owner = `CLIENT_ID_DAEMON`). 23 lines on
        `surface_registry.zig`.

     b. Protocol additions (commit pending push):
        `SET_CURSOR = 0x0033` and `CURSOR_SET = 0x8033` in
        `shared/protocol_constants.json` (regenerated into
        `protocol.zig`); `SetCursorMsg` (variable-length,
        28-byte header) and `CursorSetMsg` (4-byte status)
        message structs; `SPRITE_FORMAT_SDCS = 1` and
        `SPRITE_MAX_DIM = 256` constants. ADR amended for
        the opcode reassignment from the original `0x0030`
        which collided with the existing `set_visible`.
        ~129 lines.

     c. Handler implementation (commit pending push):
        `handleSetCursor` (local) and `handleRemoteSetCursor`
        (remote) with nine fail-fast validation steps;
        `setLogicalSize` added to the surface registry for
        the sprite-replace path. ~227 lines.

     ADR §5's "reset to default cursor on focus loss" is not
     implemented in this commit; it requires daemon-side
     focus-change tracking and is straightforward to add
     later. The "client A sets cursor, focus stays on A"
     case suffices for sub-item 9 verification.
  8. **Hide-when-outside** — visibility toggle when geometry
     is unknown and pointer is outside the framebuffer
     area. *Done 2026-05-06 (commit pending push).* Small;
     +128/-39 lines, single file (`semadrawd.zig`).
     Refactors `pumpCursorPosition` to handle visibility as
     a second axis of state alongside position. Adds
     `last_cursor_visible: bool` to the Daemon struct,
     computes `should_be_visible` from raw pointer coords
     against `[0, fb_width) × [0, fb_height)`, and walks
     damage against "displayed" rects (geometric rect when
     visible, empty otherwise). Four state transitions all
     resolve correctly through the empty-rect skip; fast-
     path when cursor stays invisible across cycles.
     Per ADR §4 ordering: damage propagation runs before
     setVisible/setPosition.
  9. **Bare-metal verification** — full chain works on
     pgsd-bare-metal-test-machine; cursor visible, follows
     pointer, doesn't trail at edges, SET_CURSOR works
     from a small test client. Closes both this entry and
     unblocks the AD-1 D.3 edge-clamp verification that
     surfaced this work. *Done 2026-05-06.*

     The verification surfaced two real bugs that landed as
     fixes during the run before the chain passed cleanly:

     a. *Region damage* (commit `18976be`). The pre-AD-21
        compositor damage model was strictly surface-bound:
        damage marks "this surface needs to re-render," and
        the framebuffer is cleared only on full repaint.
        With the cursor surface in place but no client surface
        (no semadraw-term) under it, every cursor move left
        the previous cursor pixels on screen — multiple arrows
        accumulated as the cursor swept. Fix: a second damage
        axis on the compositor (output region damage) tracking
        framebuffer-coordinate rects that need clearing to the
        background colour at the start of each composite cycle.
        New `clearRegion` vtable entry on Backend, drawfs and
        software impls, pump emits region damage for old/new
        cursor rects alongside the existing surface-damage
        walk. ~244 lines.

     b. *Visibility uses live output dimensions* (commit
        `f562d27`). The visibility check from sub-item 8
        sourced framebuffer dimensions from `Daemon.config`,
        which retains the daemon-configured size even after
        the compositor's AD-17 path overrides them with the
        backend-reported native display size. Cursor
        disappeared at x>=1920 / y>=1080 mid-screen on a
        3840×2160 framebuffer. Fix: new compositor accessor
        `outputDimensions()` returning the live output size;
        pump reads from there. ~37 lines.

     The verification also surfaced two infrastructure issues
     that were resolved by procedure rather than code: a stale
     `/usr/local/bin/semadrawd` was running under s6 supervision
     (deployed 17 hours before the AD-21 work; manual `cp`
     hit ETXTBSY), and the runbook's foreground-only command
     pattern bypassed install.sh's stop / atomic-install /
     restart cycle. The runbook update (commit `3f81c71`)
     captures both as "Phase 0 troubleshooting" so the next
     verification run on a supervised bench skips both
     pitfalls. install.sh itself was not changed; AD-12.1 and
     AD-20 had already wired the right machinery, only the
     runbook was telling operators to bypass it.

     Verification record:
       - Phase 0 (preconditions): pass after install.sh ran
         and md5sums matched.
       - Phase 1 (cursor surface created): pass; "cursor
         surface created: id=1 z=1000000 hotspot=(0,0)
         size=24x24" log line confirmed.
       - Phase 2 (cursor follows pointer): pass; cursor
         tracks across full 3840×2160 framebuffer with no
         stale-pixel trail. Cursor sprite clipping at the
         framebuffer edge is expected and correct (sprite
         hotspot at 0,0 means tip is sprite top-left; near
         the bottom-right edge, only the tip pixel remains
         on-screen as the rest of the sprite extends off-
         framebuffer).
       - Phase 3 (underlying surface redraw): pass; with
         semadraw-term running as a windowed client, the
         cursor sweeps over its content and the term
         re-renders cleanly behind the cursor.
       - Phase 4 (input routing not broken): pass; keystrokes
         reach semadraw-term, which means
         `getTopVisibleSurface` correctly skips daemon-owned
         surfaces (the regression fix from sub-item 7's
         leading commit holds).
       - Phase 5 (edge clamp / AD-1 D.3 follow-up): pass;
         pulling the cursor away from each edge leaves no
         trail of stale pixels.
       - Phase 6 (no-geometry visibility, optional): not
         exercised; not gating.
       - Phase 7 (SET_CURSOR test client, optional): not
         exercised; no test client built; orthogonal to
         AD-21 chain.

       *Note: a further verification gap was found
       post-closeout. The phases above don't include
       "cursor persists during underlying-surface repaint
       while the pointer is stationary." Sub-item 10 below
       captures the bug that gap allowed through, and the
       runbook adds a corresponding Phase 8.*

  10. **Upper-z damage propagation** — the compositor
      propagates damage upward through z-order so that a
      lower-z surface re-rendering automatically dirties
      any visible higher-z surface with intersecting
      bounds. Without this, the cursor surface (z=1000000,
      no damage during idle) is skipped by the compositor's
      render loop while underlying surfaces re-render, and
      their renders overwrite the cursor's pixels — cursor
      visually disappears during idle over an active
      semadraw-term. *Done 2026-05-07 (commit `07e100d`).*

      This is the dual of sub-item 9's region-damage fix in
      the opposite axis. Sub-item 9: cursor moves; framebuffer
      regions where the cursor was need clearing because no
      surface covers them. Sub-item 10: lower-z surface
      re-renders during higher-z surface idle; higher-z must
      re-render too, or its pixels at the intersection are
      lost. Both are manifestations of the same general rule:
      a surface's visible pixels depend on what's drawn above
      and below it, and the damage model has to capture both
      directions.

      The cursor case is the first instance where this
      visibly matters; the same fix automatically handles
      future high-z overlays (notifications, panels, drag
      previews, OSDs) without per-surface special-casing.

      Implementation: a propagation pass in `composite()`
      between the region-damage clearing and the surface
      render loop. For each lower-z surface that has damage
      and will render this cycle, walks strictly higher-z
      surfaces in `composition_order`; if one is visible and
      its bounds intersect the lower's, marks it as fully
      damaged via `markSurfaceFullDamage`. The render loop
      then renders it normally. Skipped entirely on
      `needs_full_repaint` cycles. ~68 lines.

      Cost: O(N×M) where N is damaged-surface count and M is
      surfaces above each. Negligible for typical workloads;
      spatial indexing could make it sub-linear if profiling
      shows it matters (deferred as part of AD-25).

      Bench verification: with semadraw-term running and
      cursor stationary over its surface, cursor remained
      visible across multiple 10+ second idle windows.
      Pre-fix it disappeared within ~1-2 seconds.

**Out of scope** (per ADR 0005 sections 8-9): themed
cursors, animated cursors, hide-on-type, per-client cursor
caching across focus changes, hardware cursor overlay,
multi-pointer/multi-seat. Each is potentially worth doing
later but none gates the main verification chain.

**Effect on AD-1 edge-clamp verification:** the original
operator-time verification of D.3's payload-dx/dy fix is
blocked behind this work (no visible cursor, no way to
deliberately drive the pointer against an edge). Once
AD-21 lands, the D.3 verification runs immediately as a
small follow-up. *Verified 2026-05-06 as Phase 5 of the
AD-21 verification run: cursor clamps cleanly at each
framebuffer edge with no stale-pixel trail when pulled
away. Closes the long-standing D.3 operator-time
follow-up.*

### `[x]` AD-22: semainputd silent post-startup; opens devices but emits no semantic events  *(Closed 2026-05-07, resolved by AD-2a Phase 3)*

**Closing note (2026-05-07).** Investigation under AD-22 (run via
`ad22-diagnose.sh` on pgsd-bare-metal-test-machine) surfaced the
root cause and confirmed it is architectural rather than a bug.

semainputd's reader threads are alive and parked in the `evread`
wait channel — sleeping in `read()` on `/dev/input/event0–3`,
having opened the devices and grabbed them via `EVIOCGRAB`. The
events never come because **PGSD's kernel has no driver
publishing to `/dev/input/event*`.** Per ADR 0018 §3a (commit
`6386360`, "ADR 0018 amendment — Device Mode feature, exclusive
HID consumer"), inputfs is the *exclusive* HID consumer; the
kernel configuration explicitly omits the legacy HID-class
drivers (`hms`, `hkbd`, `ukbd`, `ums`, `usbhid`, `wmt`, `hmt`,
`hconf`, `hpen`, etc.) that would historically populate evdev
nodes. Input flows through `hidbus(4)` → `inputfs.ko` exclusively.

The `/dev/input/event*` device nodes still exist on the bench
(probably for compatibility, or persisted across an older
kernel) but no kernel driver writes to them. semainputd's
evdev-based design pre-dates ADR 0018's exclusive-consumer
model and is structurally incompatible with the current PGSD
kernel architecture.

This is **not a fixable bug in semainputd.** semainputd as
written cannot work on this kernel. The resolution is
retirement, which is already scoped under AD-2a Phase 3:

  - Strip evdev reader, classification, aggregation, identity,
    and event-queue code from the semainput tree.
  - Delete `semainput/src/semainputd.zig`,
    `semainput/src/adapters/evdev.zig`, and
    `semainput/src/adapters/drawfs_inject.zig`.
  - Delete the `semainputd` rc.d shim and
    `/var/service/utf/semainputd` service directory.
  - Delete the install.sh blocks that wire them up.
  - Delete the `DRAWFS_EVT_KEY/POINTER/SCROLL` decode arms in
    semadrawd's `sendAndRecv` (they exist solely to ignore
    semainputd's injection traffic on systems mid-transition;
    once semainputd is gone they are dead code).
  - Sweep documentation that still describes semainputd as a
    present-tense daemon. **Done 2026-05-08:** the five
    `semainput/docs/` files (Architecture, SystemInterface,
    GestureLayer, NClickDesign,
    FreeBSDEvdevAdapterImplementation) are archived with
    retirement banners and historical framing; verified
    end-to-end in the 2026-05-17 audit.

semadrawd has been consuming inputfs directly since AD-2a Phase
1 cutover (2026-05-06; commit set documented in
`inputfs/docs/STAGE_E/PHASE_1.md`), so the daemon retirement
removes orphaned code rather than load-bearing infrastructure.
Phase 3 is "UNBLOCKED by Phase 2.4 recogniser-as-service
decision" per the AD-2a entry above.

**Why this entry is closed rather than rolled into AD-2a:**
AD-22 was filed as an investigation; the investigation has
delivered its result. Keeping AD-22 open as "Investigation"
when the answer is known would be misleading. The remaining
work (the deletion itself) is tracked in a place where it
already belongs (AD-2a Phase 3), so closing AD-22 doesn't
lose any tracking; it just records that the question AD-22
was asked has been answered.

The "evdev compatibility nodes still exist with no publisher"
side observation (the `/dev/input/event*` orphan nodes) is not
covered by AD-2a Phase 3 and may warrant a separate kernel-
config investigation later. Not gating anything; the orphan
nodes are harmless empty channels. Filed neither under AD-22
nor as a new entry; can be added if it becomes operationally
relevant.

---

*Original entry retained below for historical context.*

**Original status:** Open, Investigation.

Surfaced during AD-2a Phase 2.3 Stage B bare-metal
verification. The s6-supervised semainputd starts cleanly,
opens all four `/dev/input/event*` devices (grabs events
1/2/3 successfully; event0 falls back to non-grabbed open
with the standard non-fatal `EVIOCGRAB failed` message),
emits its `daemon_start` and `daemon_state` JSON-line banners
into `/var/log/utf/semainputd/current`, and then **goes
permanently silent**. Clicking, moving the mouse, touching
the touchpad — none produce any further log output. No
`mouse_button`, no `mouse_move`, no semantic events of any
kind reach the daemon's stdout.

This is **not a Phase 2.3 regression**. Verified by checking
out commit b49de30 (Stage A, pre-migration), rebuilding, and
running the binary directly: same silence. The Aggregator,
classifier, evdev reader, and event queue paths were
untouched by Phase 2.3 Stage B's migration; the silence
predates Stage B and predates the migration entirely.

The 9 libsemainput unit tests (`zig build test`) pass, so
the recogniser logic is sound. The issue is upstream of the
recogniser — events aren't reaching the recogniser to begin
with.

A previous verification record (inputfs/docs/STAGE_E/PHASE_1.md
dated 2026-05-06) documented end-to-end pointer event flow
working: ELECOM mouse on dev=0, HAILUCK touchpad on dev=2,
both producing inputdump events on the kernel side AND
semantic events through semainputd. Something between then
and now broke the userland-readable event flow, while the
kernel-side inputfs ring is presumably still healthy
(otherwise drawfs cursor injection would not have worked
during the same Phase 1 testing).

Persists across reboot.

### `[x]` AD-23: semadrawd `pwritev: Illegal seek` corrupts piped logs  *(Closed 2026-05-07, Small)*

**Superseded (2026-06-16, P3-T2b).** The writerStreaming workaround this entry
shipped no longer exists. During the Zig 0.16 filesystem migration, events.zig's
`emitWithSamples` was rerouted to write through `compat.fs.stdout()`, whose
`Stream.writeAll` calls raw `posix.system.write` (posix_safe.safeWrite). That
path never constructs a `File.Writer` and never issues pwritev, so the
positional-vs-streaming distinction, and the ESPIPE failure mode that motivated
AD-23, can no longer arise. The `std.fs.File.stdout()` call and the
`writerStreaming` constructor are both gone (the latter is also removed because
0.16 relocated `std.fs.File` to `std.Io.File` and compat.fs owns that boundary).
The regression test was kept and renamed (`... (AD-23 superseded)`); it now pins
`compat.fs.Stream`'s pipe-write behaviour instead of the writerStreaming choice.
The original closing note and analysis are retained below for historical context.

**Closing note (2026-05-07).** Fix shipped: `events.zig`'s
`emitWithSamples` now constructs its stdout writer via
`std.fs.File.writerStreaming(&out_buf)` rather than
`writer(&out_buf)`. writerStreaming initialises File.Writer
in `.streaming` mode, which calls writev directly; the
prior `writer()` initialised in `.positional` mode, which
called pwritev and got ESPIPE on every emission whenever
stdout was a pipe. A regression test at the bottom of
events.zig (`emitWithSamples-style writes through pipe fd
succeed`) mirrors the call shape against a `pipe(2)` fd
and locks in the writerStreaming choice against future
refactors.

**Refinement to the original analysis.** The original entry
claimed "subsequent log writes are partially truncated,
reordered, or dropped entirely." Careful read of Zig 0.15.2's
`File.Writer.drain` (lib/std/fs/File.zig:1747-1758) shows the
built-in `error.Unseekable` fallback transitions to streaming
mode within the same drain on ESPIPE, so a single emission's
data does still land via the streaming-mode retry. Worst
pre-fix effect: an extra failed pwritev syscall per emission
(wasteful but not data-corrupting in itself).

The corrupted log lines observed during AD-21 verification
yesterday are likely attributable to a different cause —
possibly a race between `std.log`'s stderr writer and
events.zig's stdout writer interleaving on the same pipe with
partial writes from buffered fixed-buffer streams. `std.log`'s
stderr writer is initialised to `.streaming` by the standard
library (Progress.zig:642) and was never affected by the
pwritev bug; that path was a red herring. The std.log /
stdout interleaving hypothesis is not yet investigated and
is left out of scope for AD-23.

So AD-23's fix is correct (the daemon now stops paying the
doomed syscall on every emission, and the regression test
locks the choice in) but the original "corrupts logs" framing
was overconfident. The actual effect of the pre-fix code on
this Zig version was performance noise rather than corruption.

If log corruption is observed again on the bench after this
fix lands, the std.log / stdout interleaving hypothesis is
the next thread to pull. File a new AD entry at that point.

---

*Original entry retained below for historical context.*

**Original status:** Open, Small.

Surfaced repeatedly during AD-21 sub-item 9 bare-metal
verification. When semadrawd's stdout/stderr is piped (e.g.
`semadrawd 2>&1 | tee /tmp/log`), the daemon's first log line
arrives intact, then subsequent log writes are partially
truncated, reordered, or dropped entirely. ktrace surfaced
the syscall: `pwritev(0x1, ..., 0x1, 0)` returns `-1 errno 29
Illegal seek` (ESPIPE). pwritev with a positional offset
fails on non-seekable file descriptors — which pipes are.

Root cause is the daemon's logging code path using pwritev
unconditionally, regardless of whether the destination
supports seeking. The behaviour is correct on regular files
(stderr redirected to a normal path) and on the s6-supervised
service (s6-log writes to a file, not a pipe). The bug
manifests only when an operator pipes stderr to `tee`,
`logger`, or similar.

Two bench-time consequences during AD-21 verification:
  - Diagnostic uncertainty. The runbook initially recommended
    `2>&1 | sudo tee /tmp/log`. Resulting logs misled
    diagnosis (frame_complete events arriving out of order,
    truncated init lines) and led to a chain of false
    hypotheses about pump behaviour before ktrace surfaced
    the real issue.
  - Workaround in the runbook (commit `3f81c71`): use
    `sudo sh -c '... > /tmp/log 2>&1 &'` to redirect inside
    an elevated shell, sidestepping the pipe entirely. Notes
    the bug; doesn't fix it.

**Fix shape.** Either (a) use `writev` instead of `pwritev`
for log writes, since logs are append-only and don't need a
positional offset; or (b) detect ESPIPE and fall back to
write/writev. Option (a) is cleaner; the offset parameter
was never meaningful for log output.

Estimate **Small**: localised to whichever logging utility
the daemon uses, ~5-20 lines plus a test that pipes stderr
and asserts log-line integrity.

### `[x]` AD-24: cursor surface reset to default on focus loss  *(Done 2026-05-10, Small)*

**Closure note (2026-05-10).** Implemented in
`semadraw/src/daemon/semadrawd.zig` (+124 lines, single file).
Two new Daemon fields track the relevant state across ticks:

  - `last_top_surface: ?protocol.SurfaceId`: observation cache
    of the previous tick's `getTopVisibleSurface()` result.
  - `cursor_is_default: bool`: whether the cursor surface
    currently holds the embedded default sprite versus a
    client-set custom sprite.

Two new methods:

  - `resetCursorToDefault()` re-attaches the embedded
    `cursor_arrow.sdcs` buffer (same `@embedFile` source that
    `initCursorSurface` uses), restores hotspot to (0, 0),
    restores logical size to 24x24, marks damage. Mirrors the
    canonical attach pattern.
  - `pumpCursorFocus()` runs once per main-loop iteration
    alongside `pumpCursorPosition`. State machine over
    `(last, current)`:

        (null, null)       no-op
        (null, Some(B))    no-op (B may SET_CURSOR if it wants)
        (Some(A), Some(A)) no-op (no transition)
        (Some(A), Some(B)) no-op per ADR §5 (B's call)
        (Some(A), null)    RESET if !cursor_is_default

    Cheap on the no-change path: one list walk inside
    `getTopVisibleSurface` plus an optional compare. Allocations
    zero.

Both `handleSetCursor` and `handleRemoteSetCursor` flip
`cursor_is_default = false` immediately after the
`attachInlineBuffer` call succeeds, so subsequent focus-loss
events trigger the reset.

**Bench verification passed (2026-05-10).** Built clean,
applied via `s6-svc -d /var/service/utf/semadrawd` followed by
`-u`, semadrawd restarted at PID 4703 with healthy supervision
tree (s6-svscan and the per-service `s6-supervise` PIDs from
22:51 unchanged), no new warnings in
`/var/log/utf/semadrawd/current`. `sudo grep "AD-24"` on the
log returned empty as expected: the bench has no
SET_CURSOR-using clients today (semadraw-term doesn't issue
SET_CURSOR), so `cursor_is_default` stays `true`, the focus-
loss reset is correctly gated off, and the new code paths sit
dormant exactly as designed.

**Per-client cursor caching across focus changes** is
explicitly out of scope per ADR §9. A client that wants a
custom cursor must `SET_CURSOR` each time it gains focus;
`focus-A → focus-B` is not a reset trigger.

### `[x]` AD-26: semadraw-term fullscreen / auto-scale option  *(Done 2026-05-10, Small)*

**Closure note (2026-05-10).** Implemented option (a): the
`-f` / `--fullscreen` flag. Single-file change:
`semadraw/src/apps/term/main.zig` (+61 lines, -3 lines).

Composes with `-z` (scale): `-f` alone gives maximum density
(small font, lots of cells); `-f -z 4` gives large fonts that
still fill the screen. Both are useful and a single flag would
have conflated them.

Four touchpoints:

  - `Config.fullscreen: bool = false` field.
  - Arg-parser arm for `-f` / `--fullscreen` (no value).
  - `--help` text adds the flag and notes it composes with `-z`.
  - `run()` flow refactored from "auto-detect when cols/rows
    are at defaults" into three explicit branches:
      - `config.fullscreen`: `queryDisplaySize` fires
        unconditionally; explicit `-c/-r` are overridden with
        a log line; `queryDisplaySize` failure falls back to
        configured cols/rows with a warning.
      - default-args auto-detect: unchanged.
      - explicit cols/rows without `-f`: unchanged.

Reuses `queryDisplaySize` as-is. The function already subtracts
one row for the status bar; `run()` adds it back via
`actual_rows * cell_h + cell_h`. Math works out exactly when
the framebuffer divides cleanly by cell dimensions; can leave
up to one cell row of unused margin at the bottom edge at
non-divisible scales. Documented in the Config field's
docstring as expected.

**Bench verification passed (2026-05-10).** Built clean,
installed to `/usr/local/bin/semadraw-term`. Running
`sudo semadraw-term --fullscreen` produced the correct log
sequence:

    starting semadraw-term 80x24 scale=1 fullscreen=true
    fullscreen: framebuffer 3840x2160 -> 480x134 cells at scale 1
    surface created 3840x2160

Math checks out: 480×8 = 3840 (full width), 134×16 + 16 (status
bar row) = 2160 (full height). Surface fills the framebuffer
exactly at scale 1.

Confirmed during verification that `semadraw-term` requires
root privileges to open `/dev/draw` (the device node is
root-owned). When invoked without sudo, `queryDisplaySize`
correctly returns null, the warning fires, and the term falls
back to 80x24, which is the designed failure mode. The
existing README convention (`sudo semadraw-term`) was already
the supported invocation path; AD-26 inherits this.

**Sub-stage**:

- **AD-26.1** (Done 2026-05-11): replace the direct
  `/dev/draw` ioctl with a daemon-mediated query. AD-31.1
  formalised what AD-26's closure note already acknowledged
  as a limitation: `/dev/draw` is restricted to the daemon's
  runtime user (per ADR 0006 §5), so clients running as the
  operator cannot open it directly. The original
  `queryDisplaySize` opens `/dev/draw` and calls
  `DRAWFSGIOC_GET_EFIFB_INFO`, which silently failed for
  non-root clients, producing the warning "queryDisplaySize
  failed; continuing at 80x24" and defeating `--fullscreen`.

  Post-fix routes the query through new protocol messages
  `output_info_request` / `output_info_reply` handled by the
  daemon. Adds three things: (a) the protocol pair (constants
  in `shared/protocol_constants.json` regenerated via
  `gen_constants.py`, struct types in `protocol.zig`),
  (b) daemon handlers in `semadrawd.zig` for both Unix and
  TCP dispatchers, reading from `Compositor.outputDimensions()`,
  (c) `queryOutputInfo(output_id) !OutputInfo` method on both
  `Connection` (Unix) and `RemoteConnection` (TCP) client
  types.

  Refactors `semadraw-term`'s `run()` to connect to the
  daemon before computing display size, then call
  `queryDisplaySizeViaIpc(conn, ...)` in place of the
  removed direct ioctl path. Removes `DRAWFS_DEV`,
  `EfifbInfoIoctl`, `DRAWFSGIOC_GET_EFIFB_INFO`, `iocOut`,
  and the `extern fn ioctl` declaration from `main.zig`.

  Bench-verifiable: `semadraw-term --fullscreen` as the
  operator user produces the correct framebuffer-sized
  surface; the warning is gone.

### `[x]` AD-27: trackpad pointer updates not reaching cursor surface  *(Done 2026-05-08, Small-Medium)*

**Closure note (2026-05-08).** Bench verification passed
all seven closure criteria on `pgsd-bare-metal-test-machine`
with the AD-27 fix (commit 705fec1) deployed:

  1. **Single-finger trackpad moves cursor sprite.** Visual
     confirmed. The cursor follows the finger on the
     3840×2160 framebuffer with no perceptible lag.
  2. **Two-finger touch freezes the cursor.** Visual
     confirmed. Putting two fingers on the trackpad and
     sliding them does not move the cursor; libsemainput's
     gesture recogniser remains the authority for
     multi-finger interactions.
  3. **Lifting one finger of two-finger resumes tracking.**
     Visual confirmed. The cursor does NOT jump to the
     remaining finger's coordinates; instead it stays at
     its frozen position and resumes relative motion from
     there. The "no synthesis on 2→1 transition" rule
     behaved as designed.
  4. **Mouse continues to work.** Visual confirmed.
     External ELECOM mouse (dev=0) produces pointer.motion
     events and moves the cursor; no regression from the
     touch synthesis path.
  5. **State region pointer slot advances.** Two
     consecutive `inputdump state` snapshots showed
     `pointer x=726 y=377 last_seq=1587` →
     `pointer x=838 y=504 last_seq=1941`, confirming the
     state-region writer is being driven by motion.
  6. **WITNESS-clean.** `dmesg | grep -iE
     'witness|kassert|deadlock'` shows only the four
     standard startup notices ("WITNESS option enabled,
     expect reduced performance"); no lock-order
     violations, no KASSERT failures, no DEADLKRES
     reports under PGSD-DEBUG.
  7. **drawfs counters at 0; semadrawd healthy.**
     `vmobj_install_lost`, `inbuf_grow_race_lost`,
     `frame_extract_race_lost` all 0;
     `vmobj_allocs=1, vmobj_deallocs=0` (one cursor
     surface live); semadrawd uptime 224s+ climbing.

**The transition rules behaved exactly as designed.** The
2→1 gesture-to-cursor handover is the case most likely to
glitch in a naive implementation; observing it work
cleanly confirms the primary-contact tracking and the
"no synthesis on transition" rule are correct.

**This closes the trackpad-cursor pipeline end-to-end.**
The full path now works: HAILUCK trackpad → hidbus2 →
inputfs2 (HUP_DIGITIZERS parser, single-attach with
Device Mode = MT Touchpad) → touch dispatcher
(emits TOUCH_DOWN/MOVE/UP, synthesises pointer.motion
from primary contact) → state region pointer slot →
semadrawd cursor pump → drawfs cursor surface →
framebuffer.

**With AD-27 closed, AD-22 stays closed** (its retirement
of semainputd was correct; the trackpad-cursor case did
not need a userland synthesiser after all because the
synthesis lives in the kernel where event-time
information is freshest). **AD-30 stays closed** (its
purpose was to restore inputfs's HID attachment, which is
done; AD-30.2 / AD-30.3 remain parked for portability work).
**AD-28 stays closed** (the keyboard-side coexistence
question is orthogonal; AD-10 / AD-11 remain the long-term
path for vt(4) retirement).

---

*Pre-fix entry below; preserved for the diagnostic record.
The synthesis-needed framing recorded under "Diagnosis"
matches what was implemented in commit 705fec1; the closure
criteria are exactly what was verified on the bench.*

### `[ ]` AD-27 (original): trackpad pointer updates not reaching cursor surface  *(Was Open, Investigation — diagnostic data contradicts symptom)*

**Status update (2026-05-07).** Diagnostic run via
`ad22-diagnose.sh` (which captured AD-22 and AD-27 in one
pass) returned data that does not match the reported
symptom. Re-test with tighter device labelling needed before
this entry can be acted on.

What the diagnostic showed:

  - During the trackpad-only window (5 seconds, operator
    instructed to drive only the trackpad): inputfs's event
    ring received 250+ `pointer.motion` events on `dev=0`,
    with x/y values progressing through realistic motion
    paths.
  - During the mouse-only window (5 seconds, operator
    instructed to drive only the mouse): inputfs's event
    ring received zero new pointer events. Only the
    boot-time `lifecycle.attach` burst was visible
    (replayed from the historical ring).
  - inputfs state region delta across all three windows:
    `pointer x=1920 y=1080 → x=1568 y=1433`,
    `last_seq 6 → 424`. So inputfs is publishing pointer
    updates and the state region is being consumed.

Reading: at least one device on `dev=0` is publishing
trackpad-shape motion to inputfs successfully. The mouse
window captured no pointer activity, which is the inverse of
the reported symptom. Three possible explanations:

  - **Device-labelling mismatch.** The physical device the
    operator was treating as "the trackpad" is registered in
    inputfs as `dev=0`, but the cursor pump may be reading
    that data correctly and the cursor *was* moving — perhaps
    not in a way the operator noticed. The diagnostic's state
    delta shows pointer x decreased by 352 and y increased by
    353, which is real motion, not stuck.
  - **Capture-window timing.** 5 seconds may not be enough
    for the operator to react to the banner and start moving;
    the mouse window may have ended before any mouse motion
    began. The trackpad window's 250+ events suggest motion
    *was* sustained throughout that window.
  - **`inputdump events` ring semantics.** `inputdump events`
    dumps the ring from sequence 1 to current writer-seq each
    invocation, so two consecutive runs see overlapping
    windows. The mouse-window invocation may have completed
    before any new motion arrived; the trackpad-window one
    captured everything since boot plus the trackpad activity.

Bottom line: the diagnostic does not reproduce the symptom as
described. inputfs is alive, the state region is updating,
and a `dev=0` device is producing trackpad-shape motion. The
cursor pump should be following those updates.

### `[x]` AD-28: Console keyboard input does not reach kbdmux  *(Closed 2026-05-08 — original diagnosis contradicted by bench observation; proper end state defers to AD-10 / AD-11)*

**Status update 2026-05-08.** AD-28 is closed without
implementing the proposed kbdmux bridge. The premise —
"kbdmux has no producer because inputfs is the only HID
consumer" — was contradicted by a re-check on
pgsd-bare-metal-test-machine after the AD-29 and AD-2a
Phase 3 step 2 work landed.

The bench's actual state on 2026-05-08:

  - Console login at ttyv0 works. Vic typed his
    password; it reached `getty(8)`/`login(1)`; the
    session opened.
  - `kldstat | grep -iE "inputfs|kbd|hid|ukbd|atkbd"`:
    `hidmap.ko`, `hkbd.ko`, and `inputfs.ko` are all
    loaded. (The 2026-05-07 diagnosis recorded only
    `inputfs.ko` here, which is what motivated the
    "kbdmux has no producer" framing. Either the kernel
    config changed since then or that earlier
    observation was incomplete.)
  - `sysctl dev.hkbd` shows three hkbd instances
    attached: `hkbd0` (HAILUCK USB touchpad keyboard),
    `hkbd1` (Broadcom Bluetooth USB Host Controller
    Keyboard), `hkbd2` (Apple Aluminum Mini Keyboard).
    All three live under hidbus, route through hkbd
    into the FreeBSD kbd layer, and are aggregated
    by kbdmux0.
  - `/dev/kbd0` through `/dev/kbd3` plus `/dev/kbdmux0`
    exist. They report `Device busy` to `kbdcontrol -i`,
    which is what is expected when vt(4) and kbdmux
    have them open.

So the standard FreeBSD keyboard pipeline (hidbus →
hkbd → kbd → kbdmux → vt) is **alive**. inputfs is
loaded and publishing into its event ring (verified by
the boot screen's `inputfs: state region buffer ready`
line), but it is running *alongside* hkbd, not in place
of it.

**This contradicts ADR 0018 §3a's claim** that inputfs is
"the exclusive HID consumer for any device it attaches
to." The ADR describes a target architecture; the code
implements a coexistence model where inputfs reads HID
data for its own ring while hkbd continues to register
keyboards into kbdmux. ADR 0018 §3a is amended in the
companion commit to describe what's actually happening
and to defer the exclusive-consumer end state to
AD-10 / AD-11 (the vt(4)/kbdmux deprecation path).

**Why the original diagnosis differed.** The 2026-05-07
filing recorded `kldstat` showing only `inputfs.ko`. The
2026-05-08 re-check shows hkbd loaded as a kld. Several
candidate explanations:

  - Module load order changed across reboots, with hkbd
    autoloaded in the later case but not the earlier
    one. usbus picks up a newly-attached HID keyboard
    and may load hkbd via its `module_metadata`-based
    autoload. A semainputd crash loop in the earlier
    state (since fixed by AD-29 and AD-2a Phase 3
    step 2) may have been thrashing usbus during boot
    enough to inhibit hkbd attachment.
  - PGSD-DEBUG kernel re-built between 2026-05-07 and
    2026-05-08 with a different module set. The AD-8
    discipline note says PGSD omits hkbd; AD-28's
    earlier filing assumed that was honored. It may
    not have been.
  - The earlier `kldstat` snapshot was taken after a
    targeted unload, e.g. someone running
    `kldunload hkbd` for testing. Possible but not
    verified.

The exact causal chain doesn't matter for closure: the
behaviour today is that hkbd attaches and feeds kbdmux,
console login works, and AD-28 has no remaining
operational gap to fill.

**Future double-delivery question.** When a UTF
compositor session activates and demands focus, the
same physical keystrokes will be received by both:

  - hkbd → kbd → kbdmux → vt(4) (which routes to the
    foreground tty, blocked or not)
  - inputfs HID parser → inputfs event ring →
    semadrawd → focused UTF surface

Both paths fire on the same hidbus interrupt. For
console-only use that's harmless: the UTF compositor
isn't doing anything with the events; semadrawd just
buffers them. For combined console+UTF use it would
mean a single keystroke ends up in two places.

The standard transition mechanism is `conscontrol mute`,
which suspends vt(4)'s ingestion of new keystrokes
during the UTF session and resumes it when UTF yields.
That's a small piece of session-management work, not a
kernel bridge, and it's clearly within the scope of
AD-10's existing entry ("`vt(4)` console writing through
the drawfs surface; structural fix can wait"). When
AD-10 progresses, the mute-on-UTF-activation handover
gets specified there, not here.

**Long-term end state.** AD-10 deprecates `vt(4)` for
UTF sessions. AD-11 replaces `vt(4)` entirely with a
UTF-native terminal compositor. Once both land,
ADR 0018 §3a's "exclusive HID consumer" claim becomes
true by retirement of the alternative consumer rather
than by displacement: kbdmux has nowhere to deliver to,
so hkbd-on-kbdmux falls out as a no-op path even if the
modules remain loaded. The forced kld-omission approach
becomes unnecessary at that point.

**Original AD-28 body preserved below** for reference.
The pre-implementation source-reading work
(`sys/dev/kbd/`, `sys/dev/usb/input/ukbd.c`) and the
ukbd-as-structural-reference analysis remain valid if
the kbdmux bridge ever needs to be implemented for some
other reason (e.g. a future kernel that removes the
hkbd autoload path, or a compatibility need that
specifically wants UTF-rendered keystrokes to also
appear in tty consumers). The detailed `kbd_register` /
`kbdsw` notes are not work that needs redoing.

---

### `[x]` AD-29: shared-memory readers must size-check before mmap  *(Done 2026-05-08, Small)*

**Tracks**: `shared/src/input.zig`, `shared/src/clock.zig`. Bug
discovered while investigating semadrawd's signal-6 crash loop
on `pgsd-bare-metal-test-machine` 2026-05-08.

The four shared-memory readers (`StateReader`, `EventRingReader`,
`FocusReader` in `input.zig`; `ClockReader` in `clock.zig`) all
followed the same pattern: open the file, mmap with the spec'd
fixed length, then read a magic byte at offset 0+ for validation.
The mmap call succeeds even when the backing file is shorter
than the requested length — but accessing bytes beyond the
file's actual end faults with SIGBUS or SIGSEGV.

Failure mode: during semainputd's bringup (or when semainputd
has crashed mid-init), `createFileAbsolute(.truncate=true)`
produces a 0-byte file, which is grown to STATE_SIZE only by the
subsequent `setEndPos(STATE_SIZE)` call. Any reader that opens
the file in that window — for instance, semadrawd's
`pumpCursorPosition` (called every composition cycle, so once
per frame at 60Hz) — passes the open-succeeded check, mmaps
successfully, and then SIGSEGVs on the magic-byte read at
input.zig:445. The Zig stdlib's segfault handler converts the
segfault to abort(), which is what the bench saw as the signal
6 (SIGABRT) crash loop.

This bug is **independent of any AD-18 work**. It predates the
2026-05-07 → 2026-05-08 drawfs locking work entirely; it just
manifested visibly because PGSD-DEBUG's debug build of semadrawd
made every iteration of the s6 supervision loop drop a core
into `/var/crash`.

Fix: defensive `getEndPos()` check in each of the four reader
init paths. Same pattern as the existing "open failed" branch:
on size-too-small, close the fd and return an empty reader.
The caller's existing retry path (the file-not-yet-present
case) takes over, and the daemon stays alive.

Verification:

  - `shared/src/input.zig` test "state reader rejects truncated
    file (smaller than STATE_SIZE)" added. Three sub-cases:
    zero-byte file, partial 100-byte file, STATE_SIZE - 1
    bytes. All return empty readers per the post-fix contract.
  - All 33 existing input-spec tests continue to pass.
  - `semadraw` 65-test suite continues to pass.
  - Bench verification: deploy the new semadrawd binary, watch
    `s6-svstat /etc/s6/utf/semadrawd` for restart-count
    convergence. Pre-fix: restart count climbs continuously
    while semainputd is also looping. Post-fix: semadrawd
    survives semainputd's bringup window.

The same backtrace triage may also apply to semainputd's
own crash loop, but that's a separate investigation —
semainputd does not call any of the readers fixed here, so
its signal-6 source is in a different code path.

### `[x]` AD-30: inputfs loses the hidbus probe race against legacy HID drivers  *(Closed 2026-05-08 via AD-30.1)*

**Closure note (2026-05-08).** AD-30.1 (re-apply AD-8
discipline) successfully restored inputfs's HID
attachment on `pgsd-bare-metal-test-machine`. Six HID
TLCs are now claimed by inputfs (mouse, trackpad
keyboard+pointer+touch, BT keyboard+mouse, Apple
keyboard); the state region is valid; the cursor sprite
responds to mouse motion. The architectural invariant
documented in ADR 0018 §3a holds again on this bench
under the option-3 (kld omission) path; option 1
(probe-priority bump) remains parked as future work
for portability across non-PGSD kernels but is not
operationally needed today.

The trackpad-specific symptom that originally surfaced
under AD-27 — cursor not following trackpad despite
events arriving — survived AD-30.1: the trackpad's
HUP_DIGITIZERS reports correctly produce TOUCH_MOVE/UP
events on the event ring, but the touch dispatcher
does not synthesize pointer.motion events for the
single-finger-touch case, so the state region's
pointer slot is never updated by the trackpad. AD-27
re-opens with the narrowed scope; see AD-27 entry.

AD-30 itself closes — its purpose was to restore
inputfs's HID attachment, and that's done. Future
options (AD-30.2 probe-priority bump, AD-30.3
loader.conf bootstrap) remain parked under this
entry's Cross-references section but are not
required for any currently-known operational need.

---

*Original AD-30 entry below; preserved as the
investigation record. The four structural options
documented under "The four structural options" remain
relevant if the operational state changes (e.g., a
future kernel build that omits option 3 discipline,
or a portability requirement against a non-PGSD
kernel).*

### `[~]` AD-30 (original investigation): inputfs loses the hidbus probe race against legacy HID drivers  *(Investigation complete; option 3 applied via AD-30.1)*

**Tracks**: `inputfs/sys/dev/inputfs/inputfs.c` (probe priority,
modevent rescan), `pgsd-kernel/PGSD` and `pgsd-kernel/README.md`
(AD-8 enforcement against pkg-upgrade drift), `inputfs/sys/dev/inputfs/`
kthread (loader.conf bootstrap path; longer-term).

The architectural problem inputfs was always meant to solve has
become operationally visible. inputfs is supposed to be the
kernel-side owner of HID input — one driver, attached to every
HID Top-Level Collection (TLC), publishing a unified state
region and event ring. Userland (semadrawd's cursor pump,
libsemainput's gesture recogniser, semadraw-term's click
events) is built on this assumption. The kernel-side machinery
was supposed to make it true via AD-8's discipline of omitting
the legacy HID drivers (`hms`, `hkbd`, `hmt`, `hconf`, `hsctrl`,
`hcons`, `hpen`, `ums`, `ukbd`).

On the bench today (2026-05-08, pgsd-bare-metal-test-machine),
the discipline has drifted and the kernel loads the full legacy
HID driver set. Every TLC of every HID device is claimed by a
legacy driver before inputfs even gets a chance to probe.
inputfs loads, finds nothing to attach to, runs its kthread
producing the publish-side scaffolding, and emits a 0-byte
state file because no devices ever populate any state slot.
semadrawd's StateReader correctly rejects the file under the
AD-29 size check; the cursor pump's `pumpCursorPosition` returns
early on every cycle; the cursor sprite never moves; AD-27,
AD-22, and any future input-related work cannot be tested.

This entry consolidates the architectural failure, lays out the
four structural options, and tracks the fix.

#### Bench evidence (2026-05-08)

```
$ sudo dmesg | grep -iE 'inputfs|hkbd|hidbus|hms|hmt|hconf|hsctrl|hcons'
hidbus0: <HID bus> on usbhid0
hidbus1..6: <HID bus> on usbhidN
hms0: <ELECOM ELECOM BlueLED Mouse> on hidbus0
hkbd0: <HAILUCK CO.,LTD USB touchpad Keyboard> on hidbus1
hms1: <HAILUCK CO.,LTD USB touchpad Mouse> on hidbus2
hsctrl0: <HAILUCK CO.,LTD USB touchpad System Control> on hidbus2
hcons0: <HAILUCK CO.,LTD USB touchpad Consumer Control> on hidbus2
hmt0: <HAILUCK CO.,LTD USB touchpad> on hidbus2
hconf0: <HAILUCK CO.,LTD USB touchpad Configuration> on hidbus2
hkbd1: <Broadcom Bluetooth USB Host Controller Keyboard> on hidbus3
hms2: <Broadcom Bluetooth USB Host Controller Mouse> on hidbus4
hkbd2: <Apple Inc. Apple Keyboard> on hidbus5
hcons1: <Apple Inc. Apple Keyboard Consumer Control> on hidbus6
inputfs: Stage C.3 loading ...
inputfs: D.3 transform active; pointer seeded at (1920, 1080)
inputfs: state region buffer ready (11328 bytes), events ring buffer ready (65600 bytes), kthread started
inputfs: opened state file /var/run/sema/input/state (size=11328 bytes ...)
inputfs: opened events file /var/run/sema/input/events (size=65600 bytes ...)

$ sudo ls -la /var/run/sema/input/state
-rw-------  1 root wheel 0 May  7 23:52 /var/run/sema/input/state

$ sudo /home/vic/Development/UTF/inputfs/zig-out/bin/inputdump state
inputdump: state region not valid at /var/run/sema/input/state
  (file absent, wrong magic/version, or state_valid=0)
  load inputfs and attach at least one device, then retry.

$ sudo /home/vic/Development/UTF/inputfs/zig-out/bin/inputdump devices
inputdump: state region not valid at /var/run/sema/input/state
  ...
```

Read carefully: the kernel attached `hms`, `hkbd`, `hmt`,
`hsctrl`, `hcons`, `hconf` to every TLC of every HID device on
the bus. There are zero `inputfs<N>: ... attached` lines. inputfs
loaded, set up its kthread, opened its file at full size (11328
bytes), but the file then truncated to 0 bytes (the writer's
`createFileAbsolute(.truncate=true)` ran as expected; the
follow-up `setEndPos(STATE_SIZE)` on the disk-backing path
either failed or was skipped because the in-memory state stayed
empty without devices to populate it). The reader correctly
rejects the file via AD-29's defensive size check. The whole
publish path is intact; there is just nothing to publish.

#### How this happened

NEWBUS, FreeBSD's device hierarchy, calls every candidate
driver's `probe()` on each new bus child, then picks the
highest-priority probe match. Constants:

  - `BUS_PROBE_VENDOR` (-500): vendor-specific drivers
  - `BUS_PROBE_DEFAULT` (0 historically; varies by bus): generic match
  - `BUS_PROBE_GENERIC` (-100): catch-all
  - `BUS_PROBE_LOW_PRIORITY` (-2000): explicit low-priority

When two drivers return equal priorities, NEWBUS picks based on
**registration order**: first-registered wins.

inputfs's `inputfs_probe` (`inputfs.c:3434`) returns
`BUS_PROBE_DEFAULT`. So do `hms`, `hkbd`, `hmt`, `hconf`. The
kernel-config drivers (built statically into the kernel image
or loaded as `/boot/kernel/<driver>.ko` via `MODULE_PNP_INFO`
auto-load) register first, at usbus-enumeration time. inputfs
loads later via post-rc.d `kldload` (because of its kthread's
`/var/run/` bootstrap dependency, INSTALL.md Hazard 1). By the
time inputfs registers, hidbus has already attached every TLC
to a legacy driver.

NEWBUS does not normally re-probe a device after a new driver
registers. Even if inputfs had a higher probe priority than the
incumbent, a simple `kldload inputfs` after the fact does not
displace the incumbent. A `devctl detach hidbus0/<child>` plus
`devctl rescan hidbus0` is required to reopen the probe race —
mechanical, but each option below has to handle this somehow.

#### How AD-8 was supposed to handle this

AD-8 (closed 2026-05-05) addressed the structural fix at the
kernel-config level: PGSD's kernel build omits `hms`, `hkbd`,
`ukbd`, `ums`, `hmt`, `hconf`, `wmt`, `hpen`, `hsctrl`, `hcons`,
`hidmap`, and the related modules. With those drivers absent
from `/boot/kernel/`, `linker.hints` has no PNP entries to match
and the runtime auto-load contention path is closed. inputfs is
the only HID consumer because the alternatives don't exist on
the kernel image.

That worked on 2026-05-05. It does not work today. The
"out of scope (deliberately)" note in AD-8 itself flagged the
hazard: *"A future `pkg upgrade` of `FreeBSD-kernel-generic`
will reinstall the omitted modules. PGSD eventually needs its
own pkg repository (or a `pkg-lock(8)` discipline)."* The bench
shows that hazard has now occurred. Either a `pkg upgrade`
pulled the modules back, or the kernel was rebuilt without the
`WITHOUT_MODULES=...` argument, or someone re-enabled them
manually. AD-8's discipline drifted; the assumption decayed; the
operational symptom surfaced.

#### Why this isn't AD-22 or AD-27 or AD-28

  - **AD-22** (closed 2026-05-07): semainputd reading evdev
    devices that have no kernel publisher. Closed under the
    interpretation that inputfs *was* the publisher and the
    bug was semainputd's evdev-reading design. AD-22's closure
    was correct in retiring semainputd, but it underread the
    severity of the underlying gap: inputfs being "the
    publisher" was conditional on AD-8's discipline holding,
    which it doesn't today. Same root cause, surfaced in
    a different process.

  - **AD-27** (open until today, see closure note below):
    trackpad pointer not reaching cursor surface. Diagnosed
    on 2026-05-07 by `ad22-diagnose.sh`, which captured
    motion events on `dev=0` in inputfs's event ring — i.e.,
    inputfs had at least one device attached on 2026-05-07.
    Today inputfs has zero. The bench drifted between then
    and now (probably the same `pkg upgrade` or kernel
    rebuild). AD-27's symptom is unobservable without
    inputfs receiving any HID input at all; it's superseded
    by AD-30, see closure note.

  - **AD-28** (closed 2026-05-08, yesterday): console
    keyboard input not reaching kbdmux. Closed under the
    interpretation that the standard kernel keyboard
    pipeline (hidbus → hkbd → kbd → kbdmux → vt) was alive
    on the bench because hkbd was loaded. That observation
    was correct; the closure rationale was correct. But
    yesterday's ADR 0018 §3a amendment that documented
    "inputfs runs alongside hkbd" assumed inputfs was
    *also* attaching (just not exclusively). Today's
    evidence shows inputfs is attaching to nothing on
    keyboard TLCs either. The §3a amendment is therefore
    too generous; see the §3a re-amendment below.

The three earlier entries each saw one face of the same
structural problem. AD-30 names it once, plants the master
investigation here, and supersedes the affected dependents.

#### Why this is the right architectural call

UTF's input pipeline is built on the design choice that one
kernel driver owns HID end-to-end, publishing a unified state
region and event ring. The legacy FreeBSD HID stack has many
consumers (`hms`, `hkbd`, `hmt`, ...), each owning one slice,
each with incompatible interfaces, each timestamped at a
different layer. Three independent properties drive the
unification:

  1. **Sharp timing.** UTF needs audio-synchronized timestamps
     for every input event so gesture recognition,
     accessibility tools, and music software can correlate
     input with audio frames. The legacy stack timestamps at
     every layer (USB completion, HID parser, evdev, sysmouse)
     and they don't agree to within a frame. inputfs stamps
     once at the HID interrupt and that timestamp propagates
     to the event ring with no rewriting. Cannot be retrofitted
     onto evdev/sysmouse without rewriting them.
  2. **Coherent state.** Modern UI needs to answer "where is
     the pointer right now, what buttons are pressed, what
     touch contacts are active, what's the keyboard's modifier
     state" — atomically, from any process. The legacy stack
     scatters this across `/dev/sysmouse`, `/dev/kbd*`,
     `/dev/input/event*` with nothing aggregating. inputfs
     publishes one shared-memory state region under a seqlock;
     readers get a consistent snapshot in nanoseconds without
     syscalls. ADR 0007 documents the design.
  3. **Clean device identity and routing.** inputfs preserves
     device identity (every event has a `device_slot` field;
     state region's device array exposes vendor/product/role)
     enabling per-user pointer smoothing (AD-2b), gesture
     routing per device class, and fine-grained policy that
     desktop environments traditionally have to layer back on.
     The legacy stack throws this away by `/dev/sysmouse`.

These three together are why every modern input architecture —
Linux's evdev plus libinput, macOS's IOHIDFamily, Windows's
Raw Input — converges on the same shape: one consumer, one
channel, one timestamping authority. inputfs is UTF's
implementation of that pattern in BSD. The replacement is the
right call, not a workaround.

#### The four structural options

Each addresses the gap at a different layer.

**Option 1: Bump inputfs's probe priority + force rescan.**

Change `inputfs_probe`'s return from `BUS_PROBE_DEFAULT` to
`BUS_PROBE_VENDOR` (or a similarly elevated constant). When
NEWBUS sees a higher-priority probe match, it prefers it.

But the elevated priority is only consulted on *new* probe
events. After the legacy drivers attach at boot, simply
loading inputfs with a higher priority won't displace them.
inputfs's modevent (its `MOD_LOAD` callback) needs to walk
hidbus's children, detach the incumbents, and trigger a
rescan. NEWBUS's `device_detach` plus `BUS_RESCAN(hidbus)`
restarts the probe race; with the elevated priority, inputfs
wins.

The rescan dance is delicate. Detaching a driver mid-flight
that has open file descriptors (e.g., `/dev/kbd<N>` held by
kbdmux, in turn held by `vt(4)`) has cascading consequences;
detach may fail; getting it wrong leaves devices in a stuck
state. The implementation needs careful sequencing and
shutdown-tolerance.

  - **Pros**: structural; works on any FreeBSD kernel build,
    not just PGSD's; doesn't require build-system enforcement
    elsewhere; portable to any future kernel that resurrects
    the legacy modules.
  - **Cons**: detaching kbdmux's slaves at runtime breaks
    console keyboard input (the symptom AD-28 closed
    yesterday). Workaround: have inputfs re-publish to kbdmux
    via the kbd_register interface as a bridge — but that's
    AD-28's original-and-now-rejected proposal. Better: ship
    option 1 alongside AD-10/AD-11 progress so vt(4)'s loss is
    intentional rather than a regression.
  - **Cost**: ~50-100 lines of kernel C in inputfs's modevent
    plus a few in `inputfs_probe`. Bench cycles to verify the
    detach-rescan sequence. **Medium.**

**Option 2: Load inputfs at /boot/loader.conf.**

If inputfs registers *before* usbus enumerates HID devices,
inputfs is the first registered driver and wins probe ties
under the existing `BUS_PROBE_DEFAULT` priority — no
displacement work needed.

The blocker today is INSTALL.md Hazard 1: inputfs's kthread
starts publishing files into `/var/run/sema/input/` before
`/var/run` is mounted. Loader.conf-load runs the modevent
during early kernel init when `/var` is unavailable. The
publish path needs to defer file creation until `/var/run` is
available — listen for a mount notification, or have the
kthread retry the file creation with backoff, or split the
publish path into "in-memory state" (early) and "file-backed
publication" (post-mount).

  - **Pros**: structural in a different way; inputfs naturally
    has priority because it's first; no detach-rescan dance.
    Once the bootstrap is solved, this is the cleanest layout.
  - **Cons**: the bootstrap fix is the hard part. Subtle
    timing dependencies, harder to test (need to control when
    /var mounts), has its own race conditions (event arriving
    before file is ready, kthread blocked on file write
    holding interrupt lock, etc.).
  - **Cost**: 100-200 lines in inputfs kthread plus a
    publish-readiness state machine. Substantial verification
    burden. **Large.**

**Option 3: Re-enforce AD-8's kernel-config discipline.**

The cleanest short-term fix. AD-8 was Done 2026-05-05 but
drifted. Re-apply: rebuild the PGSD kernel without the legacy
HID modules, and document the discipline maintenance procedure
(pkg-lock or PGSD pkg repository). With the modules absent,
inputfs faces no probe contention.

  - **Pros**: small, quick, well-understood — AD-8 has the
    procedure documented in `pgsd-kernel/README.md`. Restores
    the operational state UTF was tested against.
  - **Cons**: removes vt(4) console keyboard (the path AD-28
    confirmed alive yesterday goes away). Until AD-10/AD-11
    ship a UTF-native console, console login is SSH-only.
    Doesn't help portability — any non-PGSD FreeBSD kernel
    will still load the legacy modules.
  - **Cost**: kernel rebuild + verify. **Small.**

**Option 4: Sequenced combination.**

Short-term: option 3 to restore UTF input testing on the
bench. Medium-term: option 1 for portability across kernel
configs. Long-term: option 2 if the bootstrap fix is judged
worth the complexity (probably not — option 1 plus AD-10/AD-11
covers the same ground without bootstrap risk).

  - **Pros**: each step's cost is bounded, each step's value
    is independently realisable, and the order matches
    operational priority (working bench first, portability
    second, structural elegance third).
  - **Cons**: three commits across three sessions instead of
    one. More overhead; more re-verification.
  - **Cost**: option 3 cost + option 1 cost; option 2 stays
    parked unless its specific value clarifies later.

#### Recommendation

**Option 4, sequenced.** Start with option 3 to unblock UTF
input testing immediately; the bench has been usable for one
day in five and that's a coordination cost. Schedule option 1
once AD-10's framebuffer-cooperation work lands so vt(4)'s loss
is a planned transition rather than a regression. Park option 2
as a future consideration; revisit if option 1 proves brittle
across FreeBSD versions.

Bench operational note for option 3: enforcing AD-8 again means
console keyboard will stop working until AD-10/AD-11 land. Vic
needs SSH access from another machine throughout that period.
That's the same constraint AD-28 was originally filed against
(before yesterday's closure note observed hkbd was actually
loaded). Re-applying AD-8 re-creates that constraint
deliberately.

#### What this entry does NOT include

This entry is investigation-and-plan only. The actual fix —
whichever options ship and in what order — is separate
engineering work tracked under sub-items added here as they
land. AD-30.1 = option 3 re-application; AD-30.2 = option 1
probe-priority work; AD-30.3 = option 2 bootstrap (parked).

#### AD-30.1: re-apply AD-8 discipline on the bench  *(Done 2026-05-08, Small)*

**Closure note (2026-05-08).** Recovery procedure executed
on `pgsd-bare-metal-test-machine`. Bench post-reboot
verification confirms every closure criterion met:

  - **kldstat clean.** `kldstat | grep -iE 'hkbd|ukbd|hms|hgame|hcons|hsctrl|utouch|hpen|hmt|hconf|hidmap'`
    returns no lines. The legacy HID drivers are absent
    from the loaded module set.
  - **inputfs attached to all HID TLCs.**
    `dmesg | grep 'inputfs.*attached'` shows six lines:
    ELECOM external mouse (vendor 0x056e/product 0x00e3,
    pointer); HAILUCK touchpad keyboard (0x258a/0x000c,
    keyboard); HAILUCK touchpad pointer+touch (0x258a/0x000c,
    pointer,touch); Broadcom Bluetooth keyboard (0x05ac/0x8294);
    Broadcom Bluetooth mouse (0x05ac/0x8294, pointer); Apple
    Aluminum Mini Keyboard (0x05ac/0x021d, keyboard).
  - **State region valid.** `inputdump state` reports
    `magic: INST` `version: 1` `dev_count: 6`
    `pointer x=1920 y=1080`. `inputdump devices` reports
    `device_count: 6` with all six slots populated.
  - **semadrawd healthy.** s6-svstat reports steady uptime
    (274 seconds at the time of verification, climbing).
  - **Mouse cursor responsive.** External ELECOM mouse
    motion produces visible cursor sprite movement on the
    framebuffer at 3840×2160. The substrate is alive.

**Console keyboard expectation realised.** Login at ttyv0
no longer works — vt(4) has no keystroke producer because
hkbd is not loaded. SSH from a separate machine is the
working login path during the AD-30.1 → AD-10/AD-11
transition. This is the deliberate cost of the discipline,
documented in advance in this entry.

**AD-27 partially supersedes back to open.** The trackpad
case did NOT close along with AD-30. The HAILUCK trackpad
(inputfs2, slot 2, roles=pointer,touch) produces touch
events on the event ring (`dev=2 touch.type2/type3` for
TOUCH_MOVE/TOUCH_UP) but no `pointer.motion` events and
no state-region pointer-slot updates. The cursor sprite
does not follow the trackpad. The diagnosis localised
precisely to the touch dispatcher at
`inputfs/sys/dev/inputfs/inputfs.c:2849-2902`: it emits
touch events but does not synthesize pointer.motion from
the primary touch contact. AD-27's status flips back from
`[x] superseded` to `[ ] open`, with a narrowed scope
described under the AD-27 entry below. AD-30 itself
closes — its purpose was to restore inputfs's HID
attachment, and that's done.

---

*Original AD-30.1 entry below; preserved for historical
context. The detection commands and recovery procedure
described match what was actually run on the bench
2026-05-08, with the closure-criteria results recorded
in the closure note above.*

**Operational re-application** of AD-8's
build-time-and-install-time discipline on a system that
previously passed AD-8 verification (2026-05-05) and
subsequently drifted (by 2026-05-08). The static kernel
image of PGSD-DEBUG never included `hkbd`, `ukbd`, etc. —
those `device` lines are not in `pgsd-kernel/PGSD` (which
PGSD-DEBUG includes via `include "PGSD"`). The drift is
in the loadable-modules tree under `/boot/kernel/`, where
the legacy modules' `.ko` files reappeared (most likely via
a `pkg upgrade` of `FreeBSD-kernel-generic`, per AD-8's
"out of scope" hazard note).

This means AD-30.1 does not require a kernel rebuild. It is
a recovery operation: delete the leaked `.ko` files, run
`kldxref` to rebuild `linker.hints`, reboot. The detailed
procedure is documented in `pgsd-kernel/README.md` under
"Periodic drift on a running system (the pkg-upgrade
hazard)".

##### Bench operator action

Run on `pgsd-bare-metal-test-machine`:

```
# 1. Detection — confirm the drift before recovering
sudo kldstat | grep -iE 'hkbd|ukbd|hms|hgame|hcons|hsctrl|utouch|hpen|hmt|hconf|hidmap'
sudo dmesg | grep 'inputfs.*attached'  # expect 0 lines on drifted system
ls /boot/kernel/ | grep -E "^(hkbd|ukbd|hms|hgame|hcons|hsctrl|utouch|hpen|hmt|hconf|hidmap)\.ko"

# 2. Recovery
for m in hkbd ukbd hms hgame hcons hsctrl utouch hpen hmt hconf hidmap; do
    sudo rm -f /boot/kernel/${m}.ko /boot/kernel/${m}.ko.debug
done
sudo kldxref /boot/kernel

# 3. Verify on-disk state
ls /boot/kernel/ | grep -E "^(hkbd|ukbd|hms|hgame|hcons|hsctrl|utouch|hpen|hmt|hconf|hidmap)\.ko"
strings /boot/kernel/linker.hints | grep -E "(hkbd|ukbd|hms|hgame|hcons|hsctrl|utouch|hpen|hmt|hconf|hidmap)"
# both should print no lines

# 4. Reboot to clear the in-memory module set
sudo shutdown -r now
```

##### Post-reboot bench verification

After the bench reboots, the legacy drivers are not on disk
to auto-load and not in `linker.hints` for usbus to discover
on PNP match. Verify:

```
# Modules not loaded (should be empty)
sudo kldstat | grep -iE 'hkbd|ukbd|hms|hgame|hcons|hsctrl|utouch|hpen|hmt|hconf|hidmap'

# inputfs attached to HID TLCs (should be one or more lines)
sudo dmesg | grep 'inputfs.*attached'

# State region populated by inputfs
sudo /home/vic/Development/UTF/inputfs/zig-out/bin/inputdump devices
# expect device_count > 0; HAILUCK trackpad listed with vendor=0x258a

sudo /home/vic/Development/UTF/inputfs/zig-out/bin/inputdump state | head
# expect state region valid; pointer x/y, device_count, last_seq populated

# semadrawd healthy
sudo s6-svstat /var/service/utf/semadrawd
# expect uptime climbing
```

##### Console keyboard expectation

After AD-30.1, console keyboard input via vt(4) will stop
working. This is the deliberate cost of re-applying AD-8: with
`hkbd` not loaded, vt(4) has no keystroke producer and console
login at ttyv0..N is unusable. SSH from another machine
remains the working login path. This is the same constraint
AD-28 was originally filed against (before yesterday's closure
note observed hkbd was actually loaded on the bench at that
time). AD-30.1 deliberately re-creates the constraint; AD-10
plus AD-10.5 plus AD-11 are the long-term path that removes
the constraint by retiring vt(4) entirely.

If console keyboard becomes operationally needed during AD-30.1
to AD-10/11 transition, the workaround is `kldload hkbd` on
demand, accepting that this re-introduces the probe-race
problem until a reboot. Reverse with `kldunload hkbd`. This
escape hatch is undocumented in the README intentionally — it
defeats the discipline AD-30.1 is establishing — but is
mentioned here so the operator knows the option exists.

##### Closure criteria

AD-30.1 closes when:

  1. The recovery procedure has been run successfully on the
     bench. Disk state is clean (no `.ko` files; no
     `linker.hints` entries).
  2. After reboot, `sudo dmesg | grep 'inputfs.*attached'`
     returns one or more lines.
  3. `inputdump state` reports a valid state region with
     `device_count > 0`.
  4. semadrawd is healthy (uptime climbing).
  5. The cursor sprite is visible on the framebuffer at its
     seeded position (1920, 1080), and trackpad/mouse motion
     moves it.

Once closed, AD-27's superseded status can be revisited: if
the cursor follows the trackpad, AD-27 stays closed (the
original symptom was a downstream consequence of AD-30's
exclusion); if the cursor does not follow despite the state
region being valid, AD-27 reopens with a narrowed scope per
its preserved original-entry diagnostic protocol.

##### Why this is Small

  - No kernel build required (the static kernel image already
    omits the legacy drivers).
  - No code changes required.
  - The recovery procedure is six shell commands.
  - The verification is mostly passive (one reboot, six
    diagnostic commands).
  - The README already documents the procedure; this commit
    only adds the maintenance/drift-detection framing.

The work is operator action plus documentation. Total bench
time including reboot is ~5 minutes.

#### Cross-references

  - **AD-1** (in progress): inputfs as the native input
    substrate. AD-30 is the operational invariant that makes
    AD-1's design true at the kernel level. Without AD-30
    resolved, AD-1's downstream verification is not
    reproducible.
  - **AD-8** (Done 2026-05-05): originally enforced the
    discipline; drifted. Option 3 of AD-30 re-applies AD-8.
    AD-8 should gain a maintenance subsection documenting the
    `pkg upgrade` hazard and the periodic re-verification
    procedure once AD-30 lands.
  - **AD-22** (closed 2026-05-07): semainputd silent.
    Same root cause surfaced in semainputd's process; AD-22's
    closure (retire semainputd) was correct but didn't address
    the kernel-side gap. AD-30 now names that gap.
  - **AD-27** (closing here, see below): trackpad pointer not
    reaching cursor. Same root cause. Superseded by AD-30.
  - **AD-28** (closed 2026-05-08): console keyboard not
    reaching kbdmux. Closure was correct *for that day's
    bench state* (hkbd was loaded; vt's path worked). AD-30
    documents that the same observation has the inverse
    interpretation for inputfs (inputfs got nothing). The
    AD-28 closure itself is not invalidated, but its
    relationship to AD-30 deserves explicit cross-reference;
    AD-28's closure note is preserved as written.
  - **AD-10** / **AD-11**: vt(4) deprecation. Provides the
    long-term path that lets AD-30 option 3 not be a
    regression by removing vt(4)'s reliance on hkbd entirely.
  - **ADR 0018 §3a**: the architectural invariant document.
    Yesterday's amendment described coexistence; AD-30
    surfaces that the bench reality is exclusion (inputfs gets
    nothing). §3a needs a stronger amendment, see the
    companion commit.

#### AD-27 superseded

The AD-27 entry above describes a symptom (trackpad pointer
not reaching cursor surface) that requires inputfs to be
receiving HID input at all. On 2026-05-07 inputfs was attaching
to at least one device (the diagnostic captured `dev=0`
trackpad-shape motion). On 2026-05-08 inputfs is attaching to
zero devices. The AD-27 symptom can be re-tested only after
AD-30's fix restores inputfs's attachment.

AD-27 status flips to `[x]` with the closure note: superseded
by AD-30. If after AD-30 lands, the trackpad still doesn't
reach the cursor surface, the entry can be re-opened with the
narrowed scope.

### `[x]` AD-31: semadrawd multi-user refactor  *(Done 2026-05-11, Medium-Large)*

**Tracks**: `semadraw/docs/adr/0006-multi-user-refactor.md`.

**Context.** semadrawd today runs as `root` and assumes a
single-user world. There is no per-uid surface namespacing, no
per-uid event routing, and the TCP listener on port 7234
accepts unauthenticated connections. This was acceptable while
UTF was a single-user research substrate; it is unacceptable
once `pgsd-sessiond` (SM-1) starts authenticating multiple
users and serving them through one shared semadrawd.

The Option Y session model (decided 2026-05-10, recorded in
`docs/sessions/2026-05-10.md` and detailed in
`pgsd-sessiond/docs/adr/0001-design.md`) is "system-wide
semadrawd, per-user clients." That requires semadrawd to know
which uid each connection belongs to, namespace surfaces by
owner, route events appropriately, and clean up when a uid
disconnects. None of that exists today.

**Scope.** AD-31 implements the substrate-side changes
required for the system-wide-semadrawd-with-per-user-clients
architecture:

  - **Privilege drop.** semadrawd starts as root in early
    init for device opens (`/dev/draw`, `/dev/inputfs`, audio
    device), then drops to a dedicated `_semadraw` system uid
    via `setuid(2)` before accepting any client connections.
    Pattern: open device fds while privileged, retain them
    across the privilege drop, work with them as
    `_semadraw` thereafter.
  - **Peer-uid identification.** Each incoming local-socket
    connection's uid is established via `getpeereid(3)`. The
    connection's session structure stores the uid; all
    subsequent operations are tagged with it.
  - **Privileged-client recognition.** A specific uid (the
    `_pgsd_sessiond` system uid) is recognised as the login
    daemon and granted high-z-order surface privileges.
    Other uids are ordinary user clients.
  - **Per-surface owner tagging.** Every `Surface` struct in
    semadrawd records the uid that owns it. Surface
    enumeration, focus targeting, and event delivery filter
    by owner where appropriate.
  - **devfs rules.** `/dev/draw`, `/dev/inputfs`, and the
    audio device need devfs rules that grant access to
    `_semadraw` (and not to ordinary users, to prevent
    bypassing semadrawd as the gatekeeper). Tracked in
    `/etc/devfs.rules`.
  - **rc.d updates.** The supervisor configuration needs to
    start semadrawd under the right user with the right
    capabilities.
  - **TCP listener handling.** Disable the listener by
    default. Re-enable only via an explicit operator opt-in
    that requires authentication (auth design deferred to
    an authfs-shaped ADR; not part of AD-31).

**Out of scope for AD-31.** authfs (the network-side auth
model for cross-machine UTF), capsicum sandboxing of
semadrawd, fast user switching at the substrate level. These
have their own future ADRs.

**Why this is substrate work, not SM-1 work.** semadrawd is
UTF substrate. The changes here are general-purpose substrate
capabilities (peer-uid identification, owner-tagged surfaces,
privilege drop) that any consumer can use, not just SM-1. A
different distribution built on UTF could adopt the same
multi-user semadrawd without taking SM-1's design choices.
Filing this as AD-31 (under Architectural Discipline) rather
than as a sub-item of SM-1 reflects that.

**Depends on**: nothing structural. Independent of AD-3, AD-4,
AD-10. Could be implemented now against the bench's current
state without waiting for substrate co-changes.

**Blocks**: SM-1.9 (`pgsd-sessiond` boot integration). SM-1.1
through SM-1.8 do not depend on AD-31; they can proceed
against the current single-user semadrawd as user-invoked
tools, then be promoted to boot-time once AD-31 lands.

**Sub-stage status** (added 2026-05-11):

  - **AD-31.1 (privilege drop)**: Done 2026-05-11. Four commits
    on origin: `aa88638` (initial), `a731889` (broken Zig fix
    attempt), `4088345` (final fix dropping gid-side verification
    after discovering Zig 0.15.2's `std.posix` does not expose
    `getgid`/`getegid`), plus a follow-up commit relaxing inputfs
    publication file permissions to `_semadraw`-readable (mode
    0640) so semadrawd's `pumpCursorPosition` can lazy-open
    `/var/run/sema/input/state` post-drop. The permission change
    uses the operator escape hatch ADR 0013 contemplated. The
    follow-up was not anticipated by the initial AD-31.1 design;
    it surfaced during bench testing when the cursor sprite
    stopped moving. Bench-verified: semadrawd runs as uid 1002
    (`_semadraw`), `procstat -e` shows the configured environment
    variables, semadraw-term connects and renders normally.
    See `docs/sessions/2026-05-11.md` for the full verification
    trail.
  - **AD-31.2 (peer-uid identification)**: Done 2026-05-11.
    Commit `57311e9`. Adds `privilege.zig` module with
    NOBODY_UID/GID sentinels and `getPeerCredentials(fd)` wrapping
    `getpeereid(3)` via libc extern (neither `std.posix` nor
    `std.c` exposes it on Zig 0.15.2). `ClientSession` and
    `RemoteSession` gain `peer_uid`/`peer_gid` fields; Unix
    connections populate via getpeereid, TCP connections via
    NOBODY_UID. Bench-verified: client connections log
    `peer uid=1001 gid=1001` (for vic-run clients).
  - **AD-31.3 (privileged-client recognition and surface owner
    tagging)**: Done 2026-05-11. Three commits on origin:

      - **Part 1/3** (commit `69e8f2b`): SurfaceRegistry
        and privilege.zig core changes. Surface gains the
        `owner_uid` field; createSurface gains the `owner_uid`
        parameter; privilege.zig gains `isPrivilegedUid(peer_uid,
        configured)`. The three existing createSurface call
        sites pass `NOBODY_UID` as a placeholder; part 2
        replaces those with real values. No enforcement change
        yet, so visible behaviour is identical to pre-AD-31.3.
        Unit tests added for owner_uid plumbing (1 case) and
        isPrivilegedUid (4 cases including the NOBODY-cannot-be-
        privileged guarantee). Bench-verified: clean compile,
        all tests pass, semadraw-term --fullscreen unchanged.
      - **Part 2/3** (commit `9d1e201`): Daemon-level
        configuration and enforcement. Daemon gains `run_uid`
        and `privileged_uid` fields, read from SEMADRAW_RUN_UID
        and SEMADRAW_PRIVILEGED_UID in Daemon.init. Cursor
        surface carries `run_uid` as its owner_uid (no longer
        the part-1 placeholder); Unix-side handleCreateSurface
        passes `session.peer_uid`; TCP-side
        handleRemoteCreateSurface uses the (already-NOBODY)
        `session.peer_uid` for uniform code. New
        `Daemon.canModifySurface(surface_id, peer_uid)` method
        implements the ADR §4 rule: surface owner_uid match OR
        privileged-uid bypass. All 14 `isOwner` call sites
        migrate to canModifySurface. `SurfaceRegistry.isOwner`
        removed (the per-ClientId check it implemented is no
        longer the permission concept; Surface.owner remains
        for lifecycle bookkeeping). Test rewritten to verify
        Surface.owner field is set at creation time without
        re-introducing the removed function. Bench-verified:
        --fullscreen --scale 2 produces a 240x66-cell terminal
        at 3840x2160; startup log shows the new
        "SEMADRAW_PRIVILEGED_UID unset" resolution message.
      - **Part 3/3 (this entry's commit)**: ADR 0006
        implementation-status block updated to mark AD-31.3
        Done. Session memo (`docs/sessions/2026-05-11.md`)
        gains a continuation section covering AD-31.2, AD-16.6,
        AD-31.1 follow-up, AD-26.1, install.sh hardening, and
        AD-31.3 parts 1-3. BACKLOG entry (this one) closes the
        AD-31.3 sub-stage.

    The privileged-uid bypass is dormant in production because
    `SEMADRAW_PRIVILEGED_UID` is unset until pgsd-sessiond
    integrates with AD-31; the bypass branch is exercised only
    by the `isPrivilegedUid` unit tests in `privilege.zig`.

  - **AD-31.4 (devfs rules and TCP listener tightening)**: In
    progress 2026-05-11. Split into three parts:

      - **Part A (this entry's commit)**: devfs rule for
        `/dev/draw`. install.sh adds a markered managed region
        to `/etc/devfs.rules` defining the `utf_devices=10`
        ruleset (`add path 'draw' mode 0660 group _semadraw`).
        Sets `devfs_system_ruleset=utf_devices` in
        `/etc/rc.conf` **gracefully**: empty → set; already
        `utf_devices` → no-op; pointing elsewhere → refuse to
        override, leave operator's setting alone, print a
        NOTICE with two manual-integration options. The
        `utf_devices` block is written to `/etc/devfs.rules`
        regardless so an operator who later wants to merge
        has the canonical text on hand. Applies live via
        `service devfs restart` only when the install actually
        set or confirmed the ruleset. Uninstall removes the
        markered region and the rc.conf setting if it still
        points to `utf_devices`. No daemon-side code change.
        Bench-verifiable in three cases: clean bench (set +
        apply), re-install (no-op + apply), operator already
        has a different ruleset (refuse + leave alone +
        NOTICE).
      - **Part B (this entry's commit)**: event schema additions
        per ADR 0006 §9. `emitClientConnected` and
        `emitClientDisconnected` gain `peer_uid` field;
        `emitSurfaceCreated` and `emitSurfaceDestroyed`
        gain `owner_uid` field. All 8 call sites updated.
        Buffer sizes in events.zig bumped to accommodate the
        new field width. Two disconnect call sites and two
        destroy call sites added defensive lookups (with
        NOBODY_UID fallback) to capture the uid before the
        session/surface is deallocated. Bench-verifiable:
        surface-created log events include `owner_uid`
        matching the connecting client's uid; disconnect
        events include `peer_uid` matching the original
        connect event.
      - **Part C (this entry's commit)**: doc close.
        ADR 0006 implementation-status block updated to
        mark AD-31.4 Done with a recap of the three-part
        landing. AD-31 top-level entry in this BACKLOG
        flipped `[ ]` to `[x]`. Session memo
        (`docs/sessions/2026-05-11.md`) gains a third
        continuation section covering AD-31.4 parts A-C
        and the bench-verification work that surfaced the
        wholesale-cp / strings-grep / use-pattern lessons.

      TCP listener tightening per §6 is **already in place**
      from AD-31.3: TCP clients have `peer_uid = NOBODY_UID`,
      `canModifySurface` denies cross-uid modify, no
      enumeration message exists. §6 documents the posture;
      no additional code change is needed for AD-31.4 in
      that area.

**Estimate**: Medium-Large. The privilege drop is small; the
per-uid surface namespacing is medium; the testing matrix is
where the size comes in (multiple users connecting
concurrently, login-daemon-recognises-correctly, hostile
client testing). Multiple sessions of work, with each major
component bench-verifiable independently.

### `[x]` AD-33: UTF source tree should live at /usr/local/src/UTF/ per hier(1)  *(Done 2026-05-22, Small)*

**Closeout 2026-05-22**:

  - **Script audit clean.** Confirmed all top-level shell scripts
    (`install.sh`, `configure.sh`, `start.sh`, `clean.sh`,
    `build.sh`) and the `scripts/utf-up.sh` / `scripts/utf-down.sh`
    helpers use `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` to
    resolve paths relative to themselves. No script has a
    hardcoded source location. The lighter "documentation
    recommendation" option from the original AD-33 entry's "Next
    steps" applies: no relocation step in install.sh is needed.
  - **INSTALL.md Step 3** updated to recommend
    `/usr/local/src/UTF/` as the canonical clone location, with
    rationale (hier(7) alignment, parallel to
    `/usr/local/bin/`, easy operator discoverability) and the
    explicit note that developer workflows cloning elsewhere
    work correctly because no script is path-locked.
  - **INSTALL.md Step 6** gained a brief paragraph on post-install
    source retention: the source tree at `/usr/local/src/UTF/`
    can be kept (useful for future rebuilds) or removed
    (`rm -rf` is safe; all deployed artifacts are under
    `/usr/local/`, `/boot/`, `/var/service/`, and `/etc/`, none
    of which reference the source location).
  - **README.md Build section** gained a two-sentence pointer
    to the canonical location with a cross-reference to
    INSTALL.md.

No code changes.

Surfaced 2026-05-12 during the AD-25 Round 1 / AD-32 work, but
predates that discussion: UTF's source tree on bench machines
typically lives at `~/Development/UTF/` (a developer
convention) or wherever the operator chose to git-clone.
hier(1) specifies conventional locations for FreeBSD
filesystem layout, and the closest match for a third-party
source tree of locally-built software is `/usr/local/src/`.

#### Observation

  - install.sh deploys binaries to `/usr/local/bin/`, kernel
    modules to `/boot/modules/`, rc.d scripts to
    `/usr/local/etc/rc.d/`, and the s6 supervision tree to
    `/var/service/utf/`. All of these match FreeBSD
    conventions.
  - The source tree itself, however, is wherever the
    operator placed it. After `install.sh` runs, the source
    is no longer needed for runtime; an operator can
    `rm -rf` it without affecting the deployed system.
  - FreeBSD's `/usr/src` is reserved for OS source.
    `/usr/local/src/` is the conventional location for
    locally-managed third-party source per FreeBSD
    practice.

#### Implications

  - **Discoverability.** A new operator who installs PGSD
    and later wants to find the source has no canonical
    place to look.
  - **Removal.** Operators who want to reclaim disk after
    install have no documented "this is the source tree;
    safe to delete" pointer.
  - **Convention.** Aligning with hier(1) makes UTF feel
    native to FreeBSD operators rather than a developer
    project that happens to run on FreeBSD.

#### Open questions

  - **Should install.sh itself relocate sources?** Probably
    not for the in-tree build it currently does (the user
    already cloned somewhere); a documentation change
    saying "the recommended location is `/usr/local/src/UTF`"
    is lighter-weight than a relocation step.
  - **Does anything in the build assume a specific path?**
    install.sh uses `$SRCDIR` from `dirname "$0"`, so most
    of it is path-agnostic. An audit would confirm.
  - **Does the periodic / cleanup work landing this week
    interact with the source location?** No: log cleanup
    operates on `/var/log/`, which is independent of where
    the source lives.

#### Next steps

  - Audit install.sh and related scripts (`clean.sh`,
    `configure.sh`, `start.sh`, `scripts/utf-up.sh`,
    `scripts/utf-down.sh`) for any hardcoded paths.
  - Update README.md and INSTALL.md to recommend
    `/usr/local/src/UTF/` as the canonical source location.
  - Confirm git-clone instructions and tarball-extract
    instructions reflect the convention.
  - Decide whether `install.sh` itself should move sources
    on first install (probably no; the operator already
    chose a path), or whether to leave that as operator
    discipline.

#### Estimate

**Small**. Documentation and audit; no architectural change.
Could be done in a single session.

#### Related

  - **AD-32**: separate concern but surfaced in the same
    session. Not blocking; can land independently.
  - **hier(1)** FreeBSD manual page: the authoritative
    reference for the layout convention.

### `[x]` AD-35: design decision for AD-34's mmap-staleness workaround  *(Done 2026-05-12; surfaced 2026-05-12)*

AD-34's investigation has fully characterised the
mmap-staleness symptom and localised the cause to a FreeBSD
tmpfs+mmap+non-root-credential interaction (see
`docs/FREEBSD_ISSUES.md` Issue #1). The remaining work is a
design decision: which fix direction does UTF pursue?

Three credible directions, listed without ordering pending
the design analysis:

  - **Direction 1 (FreeBSD-side)**: investigate FreeBSD
    tmpfs/vm internals to identify why `vn_rdwr(IO_SYNC)`
    fails to invalidate non-root mmaps. Possible fixes:
    `vm_object_page_clean` (or equivalent) after the write
    in `inputfs_state_sync_to_file`; switching from
    `vn_rdwr` to a different write mechanism that
    invalidates uniformly; a tmpfs-side fix if the issue is
    in that subsystem. *Pros*: surgical, leaves UTF's
    architecture unchanged; benefits any future inputfs
    consumer. *Cons*: kernel work, depth unknown, may
    require carrying a FreeBSD patch out-of-tree
    indefinitely if upstream-FreeBSD is slow to accept it.
  - **Direction 2 (semadrawd-side, event-ring consumption)**:
    have semadrawd consume the inputfs event ring at
    `/var/run/sema/input/events` instead of (or in addition
    to) polling the state mmap. The ring is pollable
    (consumers can sleep on it); state mmap is not. This
    would also resolve **AD-32** (the loop busy-spin),
    because the loop could sleep on the ring's pollable fd
    and wake on real events rather than busy-spinning
    waiting for the next state change to (eventually) become
    visible. *Pros*: addresses two AD entries with one
    structural change; no kernel work; ring is already the
    canonical event delivery channel for keyboard, button,
    scroll, focus, lifecycle. *Cons*: substantial semadrawd
    refactor; the pump and all other inputfs consumers in
    semadrawd would need rewiring; `shared/src/input.zig`
    would need a parallel `EventReader` to the existing
    `StateReader`; need careful thought about how the ring
    consumption integrates with the existing
    `pumpCursorPosition` structure.
  - **Direction 3 (cursor-plane / root-helper)**: put the
    cursor sprite on a separate plane (process boundary)
    that's updated by a root-privileged helper daemon
    reading inputfs. The compositor would composite the
    plane like any other surface but would not need to read
    inputfs for cursor position. *Pros*: bypasses the
    privilege boundary without semadrawd-side or kernel-side
    work; opens the door to future hardware cursor overlay
    support; clean separation of concerns. *Cons*: adds
    another long-running daemon to the supervision tree;
    cursor latency now includes an extra IPC hop; only
    solves the cursor case (keyboard/scroll/etc. still need
    one of the other directions if they hit the same issue);
    semadrawd's `pumpCursorPosition` machinery becomes
    irrelevant for production but stays in the tree for
    development-mode (no helper).

A design ADR (likely **0008**) should evaluate these
directions against each other and select one (or a
combination). The ADR is not drafted yet because the
analysis itself is substantial work; pencilling in pros and
cons as a starting point above.

#### Open questions for the design ADR

  - Does Direction 1 require a FreeBSD-source modification,
    or can `inputfs_state_sync_to_file` add an mmap-
    invalidation call from kernel module code? The latter
    is far cheaper in maintenance terms.
  - Does Direction 2 require changes to inputfs's event
    ring on-the-wire format, or is the ring already
    sufficient for semadrawd's needs as-is? (The pointer
    state lives in the state region; events on the ring
    are deltas/transitions. If semadrawd needs absolute
    pointer position, it would need to integrate deltas
    starting from a known baseline, which is a state
    question, which loops back to staleness.)
  - Is Direction 3's root helper a long-term answer or a
    short-term workaround? If the underlying tmpfs+mmap
    issue is ever fixed, the helper becomes dead code.
  - How do other inputfs consumers (e.g. semainput) handle
    this? If they also run unprivileged and read state via
    mmap, they'll hit the same wall. The design needs to
    account for the whole consumer space, not just
    semadrawd's pump.

#### Next steps

  - **D1 (design analysis)**: draft ADR 0008 evaluating
    Directions 1-3 against each other. Include latency
    analysis (any hops added or removed), code volume
    estimate, kernel-vs-userland split, and operational
    impact (additional daemons, additional sysctls, etc.).
    **Complete 2026-05-12**: ADR 0008 drafted in
    `semadraw/docs/adr/0008-ad25-mmap-staleness-workaround.md`.
    A late probe of the event-ring file as `_semadraw`
    (`sudo -u _semadraw inputdump events --watch`) showed
    live events flowing, narrowing the bug's characterisation
    and reshaping the three-direction analysis into a
    two-direction comparison plus an explicit rejection of
    Direction 3. See the ADR.
  - **D2 (decision)**: select a direction (or combination)
    based on D1. Update ADR 0008 to "Accepted."
    **Complete 2026-05-12**: ADR 0008 Status set to Accepted.
    Direction 2 (event-ring consumption) selected. Direction 3
    rejected. Direction 1 retained as a kernel-investigation
    track under AD-34. See the ADR's Decision section for the
    reasoning.
  - **D3 (implementation)**: spec out the chosen direction
    in BACKLOG entries (likely one per major work item),
    schedule against AD-25's open umbrella, deliver.
    **Complete 2026-05-12**: AD-36, AD-37, AD-38 added to
    the open section above. Pre-implementation reading of
    semadrawd's main loop reshaped two of the three entries
    relative to ADR 0008's framing: AD-36 turned out smaller
    (the side-channel for raw events is already plumbed) and
    AD-37 turned out larger (the /dev/draw fd is already in
    the poll set; closing AD-32 requires an investigation
    into why the fd stays continuously readable, not just
    a one-line wake-source change). AD-38 is unchanged.
    The ADR's "AD-32 closes as a side effect" framing was
    optimistic and is corrected in AD-37's entry.

#### Estimate

**Medium-Large**. D1 (analysis) is the heavy intellectual
work; the directions span FreeBSD kernel internals,
semadrawd architecture, and process-boundary design. D2 is
a decision moment, small. D3 depends on which direction
wins; could be small (Direction 1, single function tweak)
to large (Direction 2, multi-day refactor).

#### Related

  - **AD-34**: the investigation entry; provides the data
    foundation for this design.
  - **AD-25**: cursor smoothness umbrella; will close
    contingent on this design's implementation.
  - **AD-32**: loop busy-spin; Direction 2 resolves this
    as a side effect.
  - **`docs/FREEBSD_ISSUES.md`** Issue #1: the underlying
    FreeBSD-side issue. Direction 1 attempts to address
    this directly; Directions 2 and 3 work around it.
  - **ADR 0007** (AD-25 discovery plan): records the
    investigation that led here.

### `[x]` AD-39: compile in-tree console drivers out of the PGSD kernel  *(Done 2026-05-13/14; landed in config + build-enforced; bench-verification of AD-39 itself not independently confirmed in this entry)*

**Tracks**: `pgsd-kernel/PGSD` (the kernel config),
`pgsd-kernel/pgsd-kernel-build.sh` (the enforcing build
tooling), `pgsd-sessiond/docs/adr/0007-bench-test-protocol.md`
(treats AD-39 as a required closure precondition).

**Why this exists / what it supersedes.** AD-10 ("drawfs takes
the framebuffer at boot vs vt(4)") originally proposed a
runtime mechanism: set `hw.syscons.disable="1"` in
`/boot/loader.conf` so `vt_efifb` declines the framebuffer at
attach and drawfs takes it. During the 2026-05-13 bench
session vt(4) and drawfs were found both writing the same
physical framebuffer address (0xc0180000), cursor sprites
overwritten by vt(4) repaints. The decision taken was
structural rather than runtime: **remove the in-tree console
drivers from the PGSD kernel config entirely** so there is no
`vt_efifb` to race or to half-disable. This supersedes AD-10's
loader.conf-tunable approach; AD-10 is marked superseded-by-
AD-39 (see its entry).

**What landed.** `pgsd-kernel/PGSD` removes, with a documented
rationale block (config lines ~238-260): `sc`, `vga`,
`splash`, `SC_PIXEL_MODE` (syscons legacy console + VGA
backend); `vt`, `vt_vga`, `vt_efifb`, `vt_vbefb` (vt(4) and
its framebuffer backends). `kbdmux` is retained (the inputfs
kbdmux bridge, AD-10.5 / ADR 0019, refers to it at the
kbd-layer protocol level). Note that with `vt(4)` removed,
`kbdmux` has no consumer for the bridge's mux'd output on
PGSD; the bridge continues to publish scancodes but they reach
no `ttyvN` console. AD-44 (filed 2026-05-27 evening) tracks
the disposition question and the conditions that would
trigger revisiting the bridge's default-on setting on PGSD.
Consequence, stated in the config itself: no kernel-level
console on the framebuffer; boot messages and panic traces do
not appear on the display; recovery requires SSH, serial
console (uncommon on iMac hardware), or rescue media. drawfs
gets exclusive framebuffer ownership the moment `drawfs.ko`
loads, which `install.sh` already arranges via the existing
`drawfs_load="YES"` line (no `hw.syscons.disable` is added or
needed; install.sh was already correct to omit it).

**Build-time enforcement.** `pgsd-kernel-build.sh` runs
`config -x` on the built kernel and greps for
`^device (vt|vt_vga|vt_efifb|vt_vbefb|sc|vga|splash)`. The
build phase fails if any leaked; the install phase re-checks
and **refuses to install** a kernel where they reappear
("REFUSING to install. Re-run build with --clean."). AD-39 is
thus not merely a config edit but a tooling-enforced
invariant.

**Status accuracy note.** Marked `[x]`: the config change is
landed on master, the build tooling enforces it, and
`pgsd-sessiond/docs/adr/0007-bench-test-protocol.md` (Proposed
2026-05-14) treats "the AD-39 / AD-1 closure work from
2026-05-13 and 2026-05-14 must be present" as a hard bench
precondition. What this entry does **not** assert: an
independent bench-verification record of AD-39 itself (i.e. a
captured boot on a PGSD kernel confirming no console driver
attaches and drawfs owns the framebuffer cleanly). ADR 0007
consumes AD-39 as a precondition rather than proving it. If a
dedicated AD-39 bench-verification artifact is wanted, it is
small follow-up work; the `[x]` reflects landed-and-enforced,
consistent with how other config/tooling AD items in this
file are marked.

**Recovery-path check: present and build-enforced.** The PGSD
config comment previously named a standalone
`pgsd-kernel-preflight.sh` as the recovery-path safety check.
No standalone script by that name exists; the functionality
was **consolidated into `pgsd-kernel-build.sh`'s pre-flight
phase** (`phase_check`), not lost. That phase performs a
three-method sshd recovery-readiness check (SSH_CONNECTION
env var; `sockstat -l` for a :22 listener; `service sshd
status`) and is **enforced, not advisory**: `phase_build`
runs `phase_check` first and refuses to build the kernel if
it fails. So the safety net the config comment promised does
exist and gates the build.

The previously-noted documentation debt (config comment
pointing at the old standalone filename) was fixed 2026-05-27
evening; the comment in `pgsd-kernel/PGSD` now points at
`pgsd-kernel-build.sh`'s `phase_check` with a cross-reference
to this subsection. (An earlier draft of this entry
called the recovery check a safety gap; that was an overclaim,
corrected here after reading the build script's pre-flight
phase.)

### `[x]` AD-41: semadrawd main loop has no wake source for inputfs events  *(Done 2026-05-27; AD-41.1 closed 2026-05-24, AD-41.3 kernel+userspace landed 2026-05-26/27, AD-41.4 bench reframed AD-36 closure as unrelated to wake source, AD-43 opened)*

Surfaced by `docs/AD36_VERIFICATION.md` (2026-05-24 bench
session). AD-36's implementation is correct as designed -
the harvest at `semadrawd.zig:1117-1140` reads
`source_role == SOURCE_POINTER and event_type == POINTER_MOTION`
events out of `self.comp.getInputfsEvents()` and assigns
`last_motion_x/y` plus `last_motion_seen = true`. Constants
agree across the kernel-side publisher (inputfs.c) and the
semadrawd-side consumer. There is no type-filter mismatch,
no payload-offset mismatch, no missing wiring inside the
harvest.

The criterion in AD-36 ("pump_diagnostic events show
state_valid=true with non-stale ps_x, ps_y under cursor
motion") is not met because the harvest is not being
called when motion is present, not because the harvest
itself is wrong.

#### Observation

semadrawd's main loop blocks in `posix.poll` at
`semadrawd.zig:1075`. The poll set is rebuilt every iteration
(`:1011-1067`) and includes:

  - the Unix socket server fd
  - the TCP server fd (if enabled)
  - each connected client's fd
  - the backend's pollable fd (`getPollFd()`)

For the drawfs backend, `getPollFd()` returns `/dev/draw`
(see `drawfs.zig:1397-1401`). **The inputfs events ring fd
is not in the poll set.** Cursor motion arrives at
`/var/run/sema/input/events` and increments the kernel's
`writer_seq`, but no fd that semadrawd is polling becomes
readable on that write. The loop sleeps until something
*else* wakes it - a client message, a new connection,
`/dev/draw` activity, or the 100 ms fallback timeout.

The comment at `semadrawd.zig:1052-1059` describing
`/dev/draw` as the input wake source is stale: it dates from
before AD-2a (2026-05-08) retired `semainputd`. Under the
old architecture, `semainputd` injected EVT_KEY/POINTER/
SCROLL/TOUCH frames into `/dev/draw`, making it the
correct wake source. After AD-2a, inputs arrive at the
inputfs ring instead, and the poll-set wiring was not
updated to follow.

The 100 ms fallback timeout *should* give the harvest 10
chances per second to drain the inputfs ring even without a
dedicated wake source. Empirically it does not - the
observed long-term pump emission rate is 91,742 events /
349,366 s = ~0.26 events/s across the full recorded daemon
history. Why the 100 ms timeout does not fire at the
documented rate is a separate diagnostic question, tracked
in this item's sub-task list because the fix for the
primary missing-wake-source issue should not depend on
resolving the timeout question first.

Evidence: `docs/AD36_VERIFICATION.md` sections 2.1-2.4.
Specifically:

  - `inputdump` captured 1,993 `pointer.motion` events at
    the inputfs ring layer in a 10-second window
    (`/tmp/ad36-bench-20260524-164755/inputdump.txt`).
  - semadrawd emitted 0 `pump_diagnostic` events during
    the same window
    (`/tmp/ad36-bench-20260524-164755/pump_diagnostic-window.txt`).
  - Across the full 349,366-second log history, 91,742 pump
    events were emitted with `state_valid:true` count zero
    and ring overrun count zero
    (`/tmp/ad36-harvest-diag-20260524-183914/REPORT.txt`,
    post `cd655ca` fix to the script's diagnosis logic).
  - A manual semadrawd run with stdout captured directly
    to a file produced 9,999 unique-seq events in the
    first 322 ms then went silent for 14.7 s, confirming
    the main-loop iteration is bursty-then-silent rather
    than steadily quiet.

#### Sub-tasks

  - **AD-41.1** *(Done 2026-05-24)*: Investigated
    inputfs's kernel-side pollable surface. Code-read of
    `inputfs/sys/dev/inputfs/inputfs.c` (4,478 lines):

      - `d_poll`: not implemented. Zero matches for
        `d_poll`, `.d_poll`, `inputfs.*poll`.
      - `d_kqfilter`: not implemented. Zero matches for
        `d_kqfilter`, `kqfilter`, `kevent`.
      - `cdevsw`: **inputfs has no character device at
        all**. Zero matches for `cdevsw`, `make_dev`,
        `make_dev_p`, `destroy_dev`. No
        `<sys/poll.h>` or `<sys/selinfo.h>` includes.

    Inputfs publishes events by writing to a tmpfs file
    at `/var/run/sema/input/events` via `vn_open` +
    `vn_rdwr` (see `inputfs_events_open_file` at
    `inputfs.c:1623-1669`). The buffer is also held in
    kernel memory (`inputfs_events_buf`) and slot writes
    happen in-place; the mmap-shared file makes those
    writes visible to userspace immediately. There is
    no kernel-side notification surface.

    Userspace currently consumes events by
    `openFileAbsolute` + `mmap(PROT.READ, SHARED)` on
    the regular tmpfs file (see
    `shared/src/input.zig:808-849`). The file's fd is
    held for the mmap's lifetime but is not used for
    poll/select - and poll on a regular-file fd would
    return READY immediately on every call, which would
    turn semadrawd into a busy-spin.

    **Finding**: the wake-source gap cannot be closed by
    adding the events file fd to semadrawd's poll set
    (that fd has no poll/kqueue surface), and cannot be
    closed by adding `d_poll` to the existing publishing
    path (there is no character device to attach it to).
    The fix requires a new notification surface.
    AD-41.2's design space is therefore different from
    the original sketch in this entry's first version.

  - **AD-41.2**: Design the notification surface.
    Three structural approaches, each with different
    trade-offs:

      (a) **Add a `/dev/inputfs_notify` character
          device to inputfs.** A small cdev (open,
          close, poll, kqfilter, no read/write needed)
          whose only purpose is to wake pollers when
          an event is published. `inputfs_publish` (the
          existing slot-write function around
          `inputfs.c:1559-1605`) calls `selwakeup` or
          `KNOTE` after the slot publish. Userspace
          opens `/dev/inputfs_notify` for the side
          purpose of waking semadrawd's main loop;
          actual event data still comes from the mmap.
          Smallest kernel-side change; well-trodden
          FreeBSD driver pattern.

      (b) **Use a kqueue-only mechanism via
          EVFILT_VNODE or EVFILT_AIO.** Could
          theoretically wake on writes to the events
          file from kernel-space. Investigation cost
          is high; semantics are subtle (EVFILT_VNODE
          NOTE_WRITE fires on userspace writes too).
          Likely a dead end.

      (c) **Add a UNIX-domain pipe or socketpair
          shared between inputfs and a per-consumer
          registry.** Inputfs maintains a list of
          registered consumer fds and `write()`s one
          byte per event (or per N events). Each
          consumer registers via an ioctl on a new
          inputfs control device. Largest change;
          requires per-consumer state in the kernel
          and a registration protocol.

    (a) is the recommended path. It changes inputfs
    from "no character device" to "one tiny notify
    cdev"; the existing events file remains the data
    plane. A short ADR documenting the split between
    data (mmap'd tmpfs file) and notification (new
    cdev) should accompany this work because the
    current architecture's "no cdev at all" is
    semi-unusual for a FreeBSD kernel module exposing
    streaming data to userspace, and the rationale
    for split should be on the record.

    Estimated effort for design + ADR: a few hours.

  - **AD-41.3** *(Done 2026-05-26/27, two commits)*: Implement (a) from AD-41.2.

    Kernel-side (`inputfs/sys/dev/inputfs/inputfs.c`):
      - Add `<sys/poll.h>` and `<sys/selinfo.h>`
        includes.
      - Add a `cdevsw` with `d_open`, `d_close`,
        `d_poll`, `d_kqfilter` entries. `d_poll`
        returns `POLLIN` when the consumer's view of
        `writer_seq` is behind the publisher's.
      - Add a `struct selinfo` field for the notify
        cdev.
      - Call `selwakeup` / `KNOTE_UNLOCKED` in
        `inputfs_publish` after the slot write but
        before returning, parallel to the existing
        `wakeup(&inputfs_state_dirty)` call.
      - Register the cdev in module init,
        `destroy_dev` in module unload.

    Userspace-side (`semadraw/src/backend/`):
      - `inputfs_input.zig`: open `/dev/inputfs_notify`
        alongside the existing events file mmap.
        Expose the notify fd via a getter.
      - `drawfs.zig`: add a second backend method
        `getInputfsPollFd()` returning the notify fd,
        keep `getPollFd()` returning `/dev/draw` for
        backwards compatibility.
      - `backend.zig`: declare `getInputfsPollFd` on
        the interface.
      - `semadrawd.zig:1052-1067`: replace the stale
        comment, add the inputfs notify fd to the
        poll set.

    rc.d / devfs (`scripts/devfs/`): if
    `/dev/inputfs_notify` needs ownership/mode
    handling parallel to the events file, add the
    rule.

    Estimated effort: a day or two for the kernel
    side plus userspace plumbing, plus bench
    verification.

  - **AD-41.4** *(Done 2026-05-27; verified the wake source works, discovered AD-36's closure is blocked by a different problem)*:
    Re-ran `scripts/ad36-bench.sh` after AD-41.3 landed and
    semadrawd was rebuilt and restarted.

    What the bench confirmed about AD-41.3:

      - semadrawd opens `/dev/inputfs_notify` cleanly at
        startup. Log line: `info(inputfs_input): inputfs
        notify cdev opened at /dev/inputfs_notify (fd=6)`.
      - `procstat -f` against the live semadrawd shows fd 6
        is the cdev, held open for the daemon's lifetime.
      - The cdev's permissions on bench resolve correctly
        (`root:_semadraw 0640`); semadrawd reads it as the
        `_semadraw` group.
      - `dd if=/dev/inputfs_notify` as root returns
        `Operation not supported by device` (EOPNOTSUPP),
        confirming the cdev has no data path and the
        no-read/write/ioctl/mmap design from ADR 0021 is
        enforced.

    Closure criterion (state_valid=true pump_diagnostic
    events during a 10 s bench window with cursor motion)
    **was not met** in the AD-41.4 bench. Window
    pump_diagnostic count: 0. inputdump captured 1,629
    pointer.motion events arriving at the inputfs ring
    during the same window. The ring publish path works;
    the daemon was not iterating its main loop.

    `procstat -k -w 1` sampled the daemon over 10 seconds
    while motion was happening: **10 of 10 samples** caught
    the thread in the `<running>` state, never parked in
    `kern_poll`/`seltdwait`. The other three processes
    (s6-supervise, s6-log) were parked in `seltdwait`
    every sample for comparison. `ps -o pcpu,time`
    confirmed 99.1% CPU sustained, with TIME advancing
    1:1 with wall clock (5 s of CPU per 5 s of wall).

    `lldb -p $(pgrep -x semadrawd) -o "thread backtrace"`
    pinned the spin to a specific code path. Three
    samples spaced 2 seconds apart all landed in the
    same place:

    ```
    frame #0: drawfs.DrawfsBackend.fillRect at drawfs.zig:1134
    frame #1: drawfs.DrawfsBackend.executeChunkCommands
    frame #2: drawfs.DrawfsBackend.executeSdcs at drawfs.zig:856
    frame #3: drawfs.DrawfsBackend.renderImpl at drawfs.zig:818
    frame #4: backend.Backend.render at backend.zig:273
    frame #5: compositor.Compositor.composite at compositor.zig:450
    frame #6: semadrawd.Daemon.run at semadrawd.zig:1267 (composite call)
    ```

    One sample caught the innermost pixel write
    (`drawfs.writePixel`) with `idx=27957156`, partway
    through a 3840 x 2160 framebuffer (which dmesg
    confirmed: `efifb available: 3840x2160 stride=15360
    bpp=32`). The daemon was writing pixels one at a time
    in a Zig software loop, partway through a full-screen
    fill on the bench's 5K iMac display.

    **Conclusion**: AD-41.3's wake source works as
    designed; the bench observation that motivated AD-41
    (no pump events during cursor motion) had a second,
    independent cause that the wake-source fix could not
    address. Composite is so slow under software
    rendering at 4K that a single `composite()` call
    occupies the entire 10-second bench window, so the
    loop never iterates back to poll and never picks up
    inputfs notify-fd wakes regardless of how promptly
    they arrive. The 30,735 historical
    `state_valid:false` pump emissions seen during AD-36
    verification were from the brief intervals between
    composite calls; once composite has been running
    continuously, those intervals close.

    Filed as **AD-43**. AD-36's closure criterion is now
    transitively blocked on AD-43, not on AD-41.

  - **AD-41.5 (independent, now plausibly explained by AD-43)**: Diagnose the 100 ms
    poll-timeout under-firing. Possible causes
    enumerated in `docs/AD36_VERIFICATION.md` section
    5.3: timeout-argument-unit error at the call
    site, loop-body cost overrunning the timeout,
    poll-fd list rebuild overhead.

    **Update 2026-05-27**: The AD-41.4 bench finding
    (composite hogging the loop, ~5 s per full-screen
    fillRect at 4K, AD-43) is the second hypothesis
    from this list in concrete form. "Loop-body cost
    overrunning the timeout" is exactly what is
    happening: when composite takes seconds to return,
    the next poll call is correspondingly delayed and
    its timeout fires far below the documented 10 Hz.
    AD-41.5 may therefore close once AD-43 lands and
    the loop iteration rate becomes measurable.
    Re-confirming this empirically is the bench-side
    follow-up; one log-line per iteration plus a
    timestamp is still the right probe shape.

#### Relationships to other items

  - **Did NOT close AD-36.** The original framing of
    AD-41 as "blocks AD-36 closure" turned out to be
    only partly right. AD-41.3's wake source is in
    place, but AD-41.4 bench surfaced AD-43 (composite
    bottleneck) as a second, independent cause of the
    AD-36 closure criterion failing. AD-36 is now
    transitively blocked on AD-43. See AD-36's own
    "Update 2026-05-27" note.
  - **Did NOT close AD-25.** Same reasoning: AD-25 was
    contingent on AD-36, and AD-36 is now contingent
    on AD-43.
  - **Refines AD-32 / AD-37 (busy-spin).** The AD-41.4
    bench's 99% CPU finding is sustained busy-spin
    behaviour, not a startup burst. AD-32 / AD-37's
    earlier framing as "startup burst followed by
    quiet" is contradicted by the 200-second-uptime
    observation. The lldb stack identifies the spin
    site precisely (composite -> render -> fillRect ->
    writePixel) which is much more actionable for
    AD-32 / AD-37 than the previous bench data was.
    See AD-43 for the durable record of the lldb
    evidence.
  - **Touched the stale comment from AD-2a.** AD-2a
    (2026-05-08) retired semainputd. The poll-set
    comment at `semadrawd.zig:1052-1059` was the most
    visible residue. AD-41.3 (commit 3084da5) cleaned
    it up.

#### Priority and scheduling

Was P1 while open. Closed 2026-05-27.

Effort actuals vs estimate:
  - AD-41.1 (investigation): ~half a day, on estimate.
  - AD-41.2 (ADR-0021 drafted): ~half a day, on estimate.
  - AD-41.3 (implementation + bench): two days across
    kernel side and userspace side, on estimate. One
    kernel-side bug discovered during userspace review
    (the level-check in d_poll); rolled into the
    userspace patch.
  - AD-41.4 (bench verification): half a day, surfaced
    AD-43 unexpectedly.
  - AD-41.5: still open as a residual diagnostic; now
    plausibly explained by AD-43 but not bench-verified
    to be the sole cause.

ADR-0021 (commit fa42e6d) needs a small amendment: its
"Decision 4" reasoning about level-check semantics was
wrong; the correct semantics are edge-only (selrecord on
every poll, no level state). Tracked separately, low
priority since the code now does the right thing.

Title remains "wake source for inputfs events" since the
gap that motivated the entry was real and has now been
closed.

### `[x]` AD-42: semaaud crashes on startup post-AD-3 (/dev/sndstat absent)  *(Done 2026-05-27; AD-42.1 + AD-42.2 landed; AD-42.3 lives under AD-3 follow-on)*

Surfaced on the 2026-05-24 bench session (recorded in
`docs/AD36_VERIFICATION.md` section 3.4). The supervised
semaaud service crash-loops with `error: FileNotFound` as
its only output. The cause is direct: AD-3 Option A
removed FreeBSD's snd(4) framework in full (commit
164ae8e, 2026-05-21), which also removed `/dev/sndstat`.
semaaud's `device_detect.zig:5` reads `/dev/sndstat` as
its first file operation:

```
const data = try std.fs.cwd().readFileAlloc(
    allocator, "/dev/sndstat", 1024 * 1024);
```

The `try` propagates the `FileNotFound` error up to
`main`'s error-reporting path, which prints the bare
error name and exits 1. s6-supervise restarts; the cycle
repeats indefinitely.

#### Observation

semaaud predates the snd(4) removal. Its purpose under
the original architecture was to publish the audio
hardware clock to `/var/run/sema/clock`, sourcing the
clock signal from OSS-side `/dev/dsp*` and using
`/dev/sndstat` to discover which DSP device to use.
AD-3 / AD-39 retired this whole layer; semasound (the
intended userspace replacement, not yet implemented) was
the planned next state.

semaaud was not updated for AD-3's removal. The
operational consequence is that any deployment with
`semaaud_enable=YES` and a fresh AD-3-built kernel
has a crash-looping service from the moment the supervisor
starts.

#### Operational mitigation (already applied)

The 2026-05-24 bench session disabled semaaud:

```
sudo sysrc semaaud_enable=NO
sudo s6-svc -d /var/service/utf/semaaud
sudo touch /var/service/utf/semaaud/down
```

The first persists the disable across reboots via rc.d.
The second tells the running s6 supervisor to stop the
service. The third marks the service down so even if
something later re-enables it, supervision will not start
it until the down file is removed.

These three steps should be applied on any other PGSD
deployment that hits this regression until AD-42.1 lands
to do it automatically. install.sh does not currently
apply them; the case for adding the disable to install.sh
by default is straightforward (a crash-looping service is
worse than a disabled one; every new deployment will hit
this until semasound exists). See AD-42.1 below.

#### Fix paths

Three options, roughly in increasing order of scope:

  (a) **Make semaaud fail gracefully when /dev/sndstat is
      absent.** Detect the absence at startup, emit a clear
      log line ("OSS audio infrastructure not present;
      semaaud requires snd(4) and PGSD has removed it; see
      AD-3"), exit 0 with a status message. s6 would still
      restart, so this requires either a finish script that
      tells s6 to stop restarting or a longer-lived idle
      state. Small but operationally awkward.

  (b) **Disable semaaud by default in install.sh.** Set
      `semaaud_enable=NO` and create the `down` marker as
      part of the deploy. Operators can opt back in if
      they have a custom setup that still provides
      `/dev/sndstat`. Smaller change; loses the
      operational signal that semaaud is broken.

  (c) **Retire semaaud and stand up semasound.** The
      intended end state under AD-3's follow-on. Largest
      change; the audio publication path needs designing
      against whatever audiofs ends up providing rather
      than OSS. Tracked separately under the
      semasound work.

(c) is the durable answer; (a) or (b) is a stopgap. For
this entry, (b) is the recommended immediate action so
that fresh deployments stop crash-looping; (c) is the
real fix and lives under its own scoping.

#### Sub-items

  - **AD-42.1** *(Done 2026-05-27, commit bcb1017)*: Apply (b) in install.sh. A few lines
    in the deploy block to set `semaaud_enable=NO` and
    create `/var/service/utf/semaaud/down`. Update
    INSTALL.md to mention that semaaud is disabled by
    default pending semasound. Estimated effort:
    half an hour.

  - **AD-42.2** *(Done 2026-05-27, commit 5468591)*: Update INSTALL.md and any other
    documentation that promotes semaaud as part of the
    standard setup. Audit for any cross-references that
    suggest semaaud is currently functional. Estimated
    effort: an hour.

  - **AD-42.3 (separate, AD-3 follow-on)**: Implement
    semasound. Not scoped under this entry; this is the
    semasound work that AD-3's BACKLOG entry already
    tracks. Closing AD-42 requires only AD-42.1 and
    AD-42.2; the long-term cure lives elsewhere.

#### Priority and scheduling

P2: not on the critical path, not blocking any current
work, operational mitigation is already documented.
Worth doing before the next deployment to any new
machine so the bring-up is clean rather than requiring
the three-step mitigation from the start.

#### Relationships

  - **Caused by AD-3** (Option A snd(4) removal, landed
    2026-05-21 as commit 164ae8e). AD-3 noted the
    semasound replacement as a follow-on but did not
    audit semaaud for runtime breakage at the moment
    of snd(4) removal. This entry closes that audit
    gap.

  - **Loosely related to AD-41.5** through AD-36's
    verification: semaaud's clock publication to
    `/var/run/sema/clock` is consumed by chronofs's
    frame scheduler and read by semadrawd. With
    semaaud disabled, that clock region is not
    populated. We confirmed on the 2026-05-24 bench
    that semadrawd works without it (the consumer
    handles absent clock data gracefully). But this
    interaction is on the record in case some future
    semadrawd change makes the clock region
    load-bearing.

#### Filing trace

  - 2026-05-24: surfaced and mitigated on bench.
  - 2026-05-25: filed as this entry. AD-3 entry is
    not retroactively updated; the audit gap is
    captured here.
  - 2026-05-27: AD-42.1 and AD-42.2 landed; entry marked
    Done. AD-42.3 (semasound) remains the long-term
    cure and lives under AD-3 follow-on.


---

**Note: the following Priority section is preserved from
the pre-split BACKLOG.md as historical reference. It was
stale at the time of the split (it referenced entries
AD-22 and AD-17 as pending when they had been closed
since 2026-05-07 and 2026-05-05 respectively). A fresh
Priority section for current outstanding work may live
in `BACKLOG.md` if Vic writes one.**

### Priority

Rough priority ordering within this section, not strict:

1. **AD-1**: in progress; unblocks AD-2; closes the most visible
   current bug (input coordinates).
2. **AD-8**: in progress; supports AD-1's bare-metal verification
   substrate.
3. **AD-9**: done; hardened AD-1's parser before AD-2 makes it
   load-bearing. One bug found and fixed (button-bitmap
   truncation) plus regression-test infrastructure left in
   place.
4. **AD-2**: now unblocked; cutover after AD-9 hardening (which
   produced one real fix). The recommended ordering held: the
   button-bitmap bug would have manifested as silently-dropped
   mouse buttons post-cutover.
5. **AD-5, AD-7**: small doc tasks; make the discipline honest.
6. **AD-6**: small-medium; applies the discipline's verification
   rule to existing code.
7. **AD-10**: medium; cosmetic/operator-experience fix for
   `vt(4)` console writing through the drawfs surface. Workaround
   exists (`conscontrol mute on`); structural fix can wait.
8. **AD-13**: small; inputfs interrupt handler logs every HID
   report to /dev/console. Discovered 2026-05-04. Five-line
   sysctl gate. Lands ahead of further Bug 2 and Bug 4
   investigation because it removes a confounding latency
   source from the interrupt path and resolves the
   physical-console-unusable consequence of the rc.local
   `conscontrol mute on` workaround.
9. **AD-16**: small; semadraw-term latent edge-case bugs in
   screen.zig found during AD-14.2 audit. Five targeted fixes
   across `getCellMut`, `putCharWithWidth`, `scrollUp`,
   `insertChars`, `getVisibleCell`. Not blocking AD-14 or
   operational use; cleanup work.
10. **AD-17**: medium; semadrawd runtime framebuffer
    auto-detection. Diagnosed Sunday 2026-05-05 during AD-15
    investigation. Backend interface change (new optional
    `getDetectedDisplaySize` vtable method); drawfs implements;
    compositor uses it. Removes the AD-15.1 operator-side
    workaround; semadrawd becomes self-configuring at startup.
11. **AD-22**: investigation; semainputd silent post-startup.
    Surfaced during AD-2a Phase 2.3 Stage B verification; not a
    Stage B regression (b49de30 reproduces the silence). Step 1
    (`dd if=/dev/input/event0` to confirm kernel evdev is alive)
    is cheap and disambiguates the whole chain. Investigation
    cost is low; downstream-fix scope unknown until step 1 runs.
    Doesn't block forward AD-2a work (Phase 2.4 routes through
    semadrawd, not semainputd) but does break the legacy input
    stack for end-users.
12. **AD-3**: large; not scheduled.
13. **AD-4**: largest; not scheduled.
14. **AD-11**: large; not scheduled. Long-term replacement of
    `vt(4)` for UTF sessions; depends on AD-10 working and on
    AD-4 progress. Filed as documented direction; may stay open
    indefinitely if AD-10's cooperation model proves sufficient.

"Not scheduled" here means: no commitment to start, no commitment to
an outcome date, but explicitly tracked so the discipline's forward
implications are visible.

### AD-3: F-chain record (F.0 through F.6, 2026-05-17 to 2026-06-05)  *(historical record, moved 2026-06-05; the ACTIVE AD-3 entry remains in BACKLOG.md with the maintenance model owed)*

The active entry's closing status narrative as of the move:

> In progress, Large; sequenced under ADR 0008 with F-stage reconciliation in ADR 0011 (2026-05-28); chipset scope decided and codec enumeration discharged for confirmed target pgsd-bare-metal; commit-6.x series landed 2026-05-21 with audible output verified on pgsd-bare-metal iMac internal speaker; audit-as-gate retired by ADR 0010 (2026-05-27 evening); F.1 (state file) bench-verified `[x]` on pgsd-bare-metal 2026-05-28; F.2 (events ring) bench-verified `[x]` on pgsd-bare-metal 2026-05-28; F.3.a (continuous streaming) bench-verified `[x]` on pgsd-bare-metal 2026-05-29; F.3.b (user-controlled playback) bench-verified `[x]` on pgsd-bare-metal 2026-05-30; F.3.c (interrupt-driven position tracking) bench-verified `[x]` on pgsd-bare-metal 2026-05-31; F.3.d (xrun detection) bench-verified `[x]` on pgsd-bare-metal 2026-05-30 (per ADR 0017 with two post-bench amendments: detection point moved to user-ring shortfall at audiofs.c line 4353, and coalescing reframed as opportunistic); F.4 (clock writer) bench-verified `[x]` on pgsd-bare-metal 2026-06-01 (ADR 0018 Accepted: kernel becomes the clock writer via a wired shared mapping of /var/run/sema/clock; monotonic across stop-start verified, no leak across 70 kldload/kldunload cycles); F.3.e (format negotiation) bench-verified `[x]` on pgsd-bare-metal 2026-06-01 (ADR 0019 Accepted: rate-only negotiation 32k/44.1k/48k, 16-bit stereo fixed, native-only per ADR 0007; GET/SET_FORMAT ioctls on /dev/audiofs0; SET reconfigures the running stream and emits format_change; F.4 republishes the negotiated rate); F.3.f (HDMI bring-up) deferred 2026-06-01 (blocked on a UTF-provided display capability; see the F.3.f deferral note below); audiofs output DMA-boundary hum found during F.5.a bench and fixed 2026-06-02 (ADR 0022 localized it below the software path via refill-miss instrumentation and a byte-exact capture fork, then ADR 0023 resolved it: per-fragment interrupt servicing on a slack-free 2-entry DMA ring, fixed by deepening the ring to 4 entries/16KB after a depth sweep and under-load test; refill-miss counters retained as permanent observability); F.5.a (semasound mixer core) bench-verified `[x]` on pgsd-bare-metal 2026-06-02 (ADR 0021 Accepted and closed: Unix-socket broker, sole writer to /dev/audiofs0, sum-clip-zerofill mixer paced by blocking-write backpressure, reader-thread-per-client plus single mixer/output thread, xrun consumer polling the F.2 notify/events ring; all 11 criteria passed including multi-client mix, non-canonical rejection, stall and disconnect isolation, induced-xrun observe-and-continue, and ADR 0018 clock stop-start monotonicity; the ADR 0023 audiofs fix was a prerequisite for the clean mix); F.5.b (format adaptation) bench-verified `[x]` on pgsd-bare-metal 2026-06-04 (ADR 0024 Accepted and closed, all ten criteria: windowed-sinc resampler (TAPS=32, seven rate pairs >= 60 dB SNR), arbitrary 16-bit mono/stereo input at supported rates with mono duplication, unsupported-format rejection with broker survival, and the rate-correcting predictor made real per ADR 0007: per-client ring-fill-trend estimator with EMA, PI control plus a weak necessary level term (pure rate correction provably lets occupancy diffuse), bench system-ID'd envelope KP=0.2/KI=0.05/EPS=0.005 verified by a two-hour soak (trim mean within ~5 ppm of injected +1000 ppm drift, trim std stationary at ~155 ppm, fill bounded, where fixed-ratio would wall in ~3 min); Stage 2 hardware-rate election per the ratified 0-to-1 invariant with Decision 1 amended to session-opener semantics (opener's hardware rate elected natively for bit-exact passthrough, else 48k; joiners resample to the session rate, no live client ever observes a rate change; lazy rest state), SET_FORMAT via the F.3.e ioctls only at session boundaries, fd/RSS stable across 24 election cycles); F.5.c (targets and routing) bench-verified `[x]` on pgsd-bare-metal 2026-06-04 (ADR 0025 Accepted and closed, all ten criteria: target as a named isolated mixing domain instantiating the full F.5.a/b spine; static two-target topology with default on /dev/audiofs0 and a timer-paced null discard sink; Hello v2 target naming with immutable per-connection routing (transparent stream migration explicitly not permitted, constraining F.5.d fallback design), v1 rejected; per-target session-opener election with the election-isolation invariant verified in strong form, the full F.5.b election suite passing unchanged under a persistent null-routed client; cross-target stall isolation, fd/RSS exactly stable across mixed-target cycles); F.5.d (policy) bench-verified `[x]` on pgsd-bare-metal 2026-06-04 (ADR 0026 Accepted and closed, all ten criteria: grammar v1 parity with the semaaud Phase 12 durable-policy contract, exact diagnostics, precedence, live reload-per-connection, never-fatal validation; source of truth in /usr/local/etc/semasound with atomic policy-valid/policy-errors/policy-state surfaces under /var/run/sema/audio (recorded hier(7) layout divergence); Hello v3 label/class identity; override_class translated to reference-counted ducking via a bit-exact-at-unity mixer gain seam (the recorded parity divergence from kill-preemption, operator litmus: semaaud with a mixer would not have killed the stream); group exclusivity with the one protocol-visible STATUS_PREEMPTED preemption; one-hop admission-only fallback; inertness gate: f5b and f5c suites unchanged with no policy files); F.5.e (state publication) bench-verified `[x]` on pgsd-bare-metal 2026-06-04 (ADR 0027 Accepted and closed, all ten criteria: the full per-target surface tree under /var/run/sema/audio with parity filenames, clients replacing stream/current (recorded mixing divergence), constrained in-memory event rings (O(1) append, no audio-thread filesystem IO) drained by a 1 Hz publisher deriving every surface from one snapshot per cycle, every-cycle liveness heartbeat, monotonic non-resetting seq with gap-detectable overflow, semasound-dump read-only inspector; verified inert: all three prior suites unchanged under the publisher and a 15-minute drift soak held the F.5.b envelope during continuous publication; operator ruling recorded in ADR 0024: native-passthrough clients intentionally uncorrected, auto-resampler insertion rejected, fill-trend telemetry a potential future enhancement), F.5.f (supervision) bench-verified `[x]` on pgsd-bare-metal 2026-06-04 (ADR 0028 Accepted and closed, all ten criteria; the operator ruling retained s6 per ADR 0020's scoping, recording the rc(8)/daemon(8) analysis as considered and deferred to a whole-of-project supervision evaluation after field experience, a ruling vindicated by the discovery that AD-20 already operates project-wide s6 supervision; semasound realized inside that architecture: s6/utf/semasound service directory with the AD-20 flap-protection finish, signal-safe immediate-teardown SIGTERM/SIGINT handling in the broker (no drain, no tombstone, publish_ts staleness the stop signal), install.sh integration end to end including the audiofs module deploy and rc.d shims (audiofs PROVIDEs audiofs_loaded with rc-deferred loading; semasound REQUIREs utf_supervisor audiofs_loaded, deliberately not claiming utf_clock), enablement verified by transcript including an unattended cold boot, all four suites passing unchanged against the supervised broker; semasound installs enabled while semaaud stays dormant under its AD-42.1 down marker, staging the cutover). F.5 COMPLETE. F.6 (semaaud retirement) CLOSED 2026-06-05 (ADR 0029 Accepted 2026-06-04 and closed: the parity audit found ZERO live dependents, with the control plane, session tokens, and layout prefix all consumer-free, the clock already audiofs-written since F.4, and chronofs's semaaud ingestion unwired at the code-path level; utf_clock transferred to the audiofs rc service (PROVIDE audiofs audiofs_loaded utf_clock) with semadraw's REQUIRE untouched, AD-12.2 working as designed; semaaud removed entirely (sources, s6 service, rc script, build aggregation, conf section) along with the pre-AD-20 operational scripts (start.sh, utf-up.sh, utf-down.sh), whose job belongs to the supervision architecture; upgraded systems reaped by install.sh via the semainputd pattern, verified live against reconstructed supervise state; documentation and provenance comments reconciled with history left true; all ten criteria evidenced by transcript on pgsd-bare-metal including a 48000.0 Hz clock measurement under the audiofs writer and a clean uninstall round trip. The criterion 7 allowlist is named in ADR 0029's closure revision). AD-3 retains only the MAINTENANCE MODEL, plus the housekeeping ledger from closure week: uninstall stop-before-delete ordering, chrono_dump's blocking read, the bench-tone strings marker, utf.conf.sample's stale [semainput] section and clock_path, scripts/rc.d wholesale retirement (operator's open question), and svscan.log rotation

The entry body chronicle, preserved verbatim:

semaaud currently uses OSS (FreeBSD's kernel audio framework) for
audio output. OSS is accepted as platform transport today
(`docs/UTF_ARCHITECTURAL_DISCIPLINE.md`). Direct hardware driving,
analogous to how inputfs replaces evdev, would remove this
dependency entirely.

The native substrate is named **audiofs** on the kernel side and
**semasound** on the userland side, mirroring inputfs / semainput.
audiofs is a direct PCI driver that class-matches on PCI HDA
controllers (class `MULTIMEDIA`, subclass `MULTIMEDIA_HDA` per
the PCI spec). The match is vendor-agnostic: any controller
the PCI spec calls HDA-class is in scope, regardless of
silicon vendor. On `pgsd-bare-metal` this includes both the
Intel Sunrise Point analog HDA controller and the ATI Oland
HDMI audio controller; the same audiofs binary attaches to
both. Other HDA controllers (NVIDIA HDMI, VIA, SiS, ULI, and
the rest of the Intel and AMD lineages) would also attach by
the same class probe, but only Intel and AMD/ATI are
observationally verified today. "Class-matched" and "verified
on every controller in the class" are deliberately separate
claims; the latter accumulates as bench evidence with real
hardware. The `snd(4)` framework is removed from the PGSD
kernel in full: the generic `sound` shim, the `snd_hda` driver,
and the other in-tree snd drivers (cmi, csa, emu10kx, es137x,
ich, via8233) are all absent. `snd_hda` had to go for
audiofs to take the codec-attach slot without a name-locked
binding from snd_hda's hdacc children intercepting it; the
others are removed under the broader principle that if PGSD
does not target the hardware, the kernel does not compile in
the driver (consistent with AD-8 HID exclusions and AD-39
console-driver removals). audiofs uses
`dev/sound/pci/hda/hda_reg.h` and `hdac_reg.h` as
header-only sources of HDA register definitions; there is no
runtime dependency on `snd(4)` code, and with the framework
removed there is no `/dev/dsp*` surface for anything to fall
back to. The removal is documented in-situ at
`pgsd-kernel/PGSD` (sound section) and propagated through
`WITHOUT_MODULES_NAMES` in `pgsd-kernel/pgsd-kernel-build.sh`.
audiofs publishes `/var/run/sema/audio/{state,events}` and
takes over clock-writing duty from semaaud (the kernel knows
the actual sample position more accurately than userland
readback). semasound, when implemented, will talk to those
files directly. semasound inherits semaaud's durable-policy
work (Phase 12), named-target topology, mixer logic, control
socket, and runtime UI state, but talks to audiofs instead of
`/dev/dsp*`. semaaud retires once semasound is verified
end-to-end (analogous to AD-2 for semainput).

This is substantial work. Real-time audio has harder timing
constraints than input (buffer underrun is immediately audible),
vendor-specific audio hardware programming is complex, and the
existing OSS interface is reasonably stable. The proposal landed
2026-04-29 (commit `88b9405`) and identifies six open
architectural questions that subsequent ADRs will resolve before
any kernel code is written: Q1 data path (tmpfs ring vs
kernel-mapped DMA vs hybrid), Q2 mixer location, Q3 OSS
coexistence model, Q4 format negotiation, Q5 latency targets,
and Q6 serialization format for semasound's userland surfaces.
The pre-survey BACKLOG entry counted only four; Q5 (latency)
and Q6 (serialization) were added to the proposal during
review and the BACKLOG entry is corrected here.

Stage F.0 (architectural ADRs) is in progress under
`audiofs/docs/adr/`. ADR 0001 establishes the per-question
ADR structure; ADR 0002 resolves Q3 (OSS coexistence) with
end-state Exclusive, migration-time per-device sysctl
assignment, Layered rejected. Q1, Q2, Q4, Q5, and Q6 remain
open as of this commit.

Implementation (Stage F.1 onward) depends on AD-2 closing
first and on F.0's six ADRs being accepted. F.0 ADR work
itself is documentation, not implementation, and can proceed
in parallel with AD-2 thinking.

**Status update 2026-05-17 (supersedes the F.0-in-progress
text above; original retained as the record of where F.0
stood mid-stream).** F.0 is complete. The architectural ADR
set is 0001-0007, all Accepted: 0002 (OSS coexistence), 0003
(clock writer, plus section 8 the snd(4)-dependency
analysis), 0004 (mixer location), 0005 (userland
architecture), 0006 (replace snd(4) in full, with
governance independence as the primary recorded rationale),
0007 (the physics/semantics boundary governing audiofs
content). The work exceeded the original six-question frame:
0006 and 0007 are architectural decisions beyond the Q1-Q6
list. AD-2 has closed (see AD-2 entry). The
governance-independence rationale and its inputfs/`hms(4)`
precedent are recorded in
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md`. The premise-
validation method is specified (not performed) in
`audiofs/docs/snd4-gap-governance-audit.md`.

AD-3 is now sequenced and gated by ADR 0008 (Stage F scope).
It is still Open and not started, and deliberately so: ADR
0008 makes the gap-and-governance audit a strict gate that
runs before any audiofs code, and makes two scope inputs
(the target chipset list and the maintenance model) owed,
gating preconditions that ADR 0008 explicitly does not
invent. Scheduling a start date is a separate act that
requires those owed inputs and the audit to exist first.
The Q1 data-path question remains the one F.0-era question
without its own ADR; it is folded into F.3's own sub-stage
ADR per ADR 0008 section 5 rather than left as a standalone
F.0 gap.

**Status update 2026-05-17 (chipset scope partially
discharged).** ADR 0008 section 3a now records the chipset
scope *rule* as decided (HDA-class and USB-audio-class,
2016+, confirmed-target machines) and pins the
controller-level targets from real `pgsd-dev`
`pciconf`/`usbconfig` output (Intel Comet Lake PCH HDA;
NVIDIA GP108 HDMI; Logitech G433 USB-audio). The owed item
is narrowed: not "produce the chipset list" but the
specific action of recording `hdacc`/`hdaa` codec
identities via `cat /dev/sndstat` and verbose `dmesg` on
confirmed-target machines. The maintenance model remains
fully owed and unchanged. HDMI audio is in scope at full
guarantee; its dependency on third-party GPU/display
infrastructure is recorded in ADR 0008 section 3a as
transitional (not an accepted architectural exception),
with a flagged future-overlap note that full HDMI
guarantee may require UTF-owned display/GPU work
overlapping AD-4, the extent of which is deferred for
future analysis and explicitly not declared a merged
AD-3/AD-4 scope here.

**Status update 2026-05-17 (machine correction; codec
discharged; regime and platform questions open).** The
preceding status block recorded controller-level targets
from `pgsd-dev`. That was the wrong machine: `pgsd-dev`
is not the AD-3 confirmed target. ADR 0008 section 3a is
superseded accordingly (not amended): the confirmed
target is `pgsd-bare-metal` (the PGSD bare-metal machine,
Apple/Skylake, where Phase 2.5 input verification ran).
Its codec enumeration is now discharged from the real
machine's dmesg: primary analog is a Cirrus Logic CS4206
(classic HDA; pcm6 internal speaker, pcm7 headphones,
pcm8 digital), and the HDMI path is an ATI R6xx HDA codec
on an ATI Oland controller (pcm0-pcm5), AMD/ATI not
NVIDIA. No USB audio device is present on the confirmed
target. F.scope.a is therefore discharged for
`pgsd-bare-metal`; it re-opens per the scope rule only
for any future confirmed-target machine. The maintenance
model remains fully owed and unchanged. Two questions are
recorded in 3a as explicitly open, deliberately not
decided as ADRs: (1) ADR 0006's ownership strategy is
established only for the classic-HDA regime; its
applicability to post-HDA SST/cAVS/SoundWire/SOF
firmware-pipeline hardware is an unresolved risk gating
any extend-as-needed step into non-classic-HDA hardware;
(2) whether PGSD should be designed for a specific
hardware platform (e.g. PCIe-slot desktop/server only, in
the manner Apple targets controlled hardware) is a
foundational project-identity question under deliberate
consideration by the decision owner, not settled here and
deliberately not recorded as an ADR to avoid a
platform-class commitment being made as a side effect of
the audio thread.

**Status update 2026-05-20 (experimental implementation
started; gate posture corrected).** Implementation of
audiofs as a FreeBSD PCI driver for HDA controllers began
this date on `pgsd-bare-metal`, with explicit decision-owner
ratification. The work crosses what ADR 0008 framed as a
gate against "any audiofs code before the audit clears" and
the BACKLOG previously framed as "not started"; both
framings are corrected here rather than papered over.

The correction is doctrinal, not casual: discipline bites on
*decay* of provisional state into silent canonical truth,
not on the existence of provisional implementation work
itself. Running code that knows itself to be experimental,
labeled as such, accepted by an informed decision owner as
such, and producing empirical evidence that informs (does
not pre-empt) audit and ratification, is a legitimate mode
of substrate research. The handoff packet for independent
verification of the original audit surface remains frozen
and available; this implementation work runs in parallel
with that, not in place of it.

What landed today as `audiofs/sys/dev/audiofs/audiofs.c`
(478 lines, em-dash-clean, no normative-status assertions):

- Attaches as a PCI class driver (PCIC_MULTIMEDIA /
  PCIS_MULTIMEDIA_HDA) to HDA controllers. Verified
  attaching to both controllers on `pgsd-bare-metal`:
  audiofs0 on Intel Sunrise Point HDA (the CS4206 host),
  audiofs1 on ATI Oland HDA (HDMI).
- Maps BAR0, reads HDA version and GCAP, logs capability
  counts via dmesg and a per-instance sysctl-readable
  eventlog ring.
- Resets the controller per HDA 1.0a section 4.3, with the
  reset sequence mirroring `hdac.c`'s `hdac_reset()`
  verbatim (no fabrication; source-grounded against
  releng/15.0 `sys/dev/sound/pci/hda/hdac.c`).
- Exposes `dev.audiofs.N.{num_iss,num_oss,num_bss,
  support_64bit,pci_vendor,pci_device,eventlog}` sysctls.

Empirical findings from first contact, recorded here as the
substrate-evidence stream the gate ultimately rests on:

- audiofs0 (Intel/Cirrus host): HDA v1.0, GCAP=0x9701, ISS=7
  OSS=9 BSS=0, 64-bit DMA supported.
- audiofs1 (ATI Oland HDMI): HDA v1.0, GCAP varies between
  loads (0x0000 first cold load, 0x6003 on reload). ISS=0
  OSS=6 BSS=0 on the working read, 64-bit supported. Power-
  state interaction with the GPU power well is the most
  likely cause; deferred for later investigation.
- Both controllers reset cleanly. No panics, no resource
  leaks across multiple load/unload cycles.

Out of scope for this commit (explicitly):

- CORB/RIRB ring setup. No codec command dispatch yet; no
  codec enumeration, no widget walk, no pin configuration,
  no streaming, no CLOCK region writing, no AUDIO_STATE /
  AUDIO_EVENTS. These land in subsequent commits.
- Power-state management for the ATI HDMI block. Cold-load
  GCAP=0 is a deferred investigation, not a regression.
- snd(4) coexistence behavior. ADR 0002's posture is
  unaffected; this PCI driver claims the HDA controllers
  by `BUS_PROBE_DEFAULT` and snd_hda is no longer in the
  PGSD kernel (see PGSD kernel config commit, this date).

The PGSD kernel config (`pgsd-kernel/PGSD`) removed
`device snd_hda` and added `hda` to `WITHOUT_MODULES_NAMES`
in `pgsd-kernel/pgsd-kernel-build.sh` to suppress the
module from the build. This was the precondition for
audiofs taking the PCI HDA controllers directly without
contesting `hdac.c`'s name-locked codec-child probe. The
maintenance-model owed item now includes responsibility for
the kernel configuration delta this introduces.

The original audit specification
(`audiofs/docs/snd4-gap-governance-audit.md`) and its
handoff packet remain authoritative. Their relationship to
this implementation work: the audit was specified to
validate ADR 0006's premise that gaps in `snd(4)`
substantively justify replacement. This implementation
demonstrates that replacement is mechanically achievable at
the controller layer; it does not retire the audit's
question, which concerns whether the premise was correctly
analyzed. The audit's verdict and this implementation's
empirical evidence are both inputs to eventual
ratification, not substitutes for each other.

Next concrete substrate steps (not constitutional acts):

- Commit 2: CORB/RIRB rings, codec enumeration via STATESTS
  + GET_PARAMETER. Identifies Cirrus CS4206 at its
  codec address, ATI R6xx at its.
- Commit 3: function-group walk, widget enumeration, pin
  configuration for analog headphone output on CS4206.
- Commit 4+: stream descriptor allocation, DMA buffer
  setup, audible-output target.

CLOCK region writing (the audit's central concern) lands no
earlier than commit 4 and remains explicitly provisional
until ADR 0003's transition from `semaaud` to `audiofs`
as canonical clock writer is independently verified.

**Status update 2026-05-20 (commit 2: CORB/RIRB +
codec enumeration).** Codec layer first contact achieved
through audiofs' own command path. Both HDA controllers
on `pgsd-bare-metal` now respond to verb dispatch through
audiofs-owned CORB/RIRB rings:

- audiofs0 (Intel Sunrise Point host): Cirrus Logic CS4206
  at cad=0, vendor=0x1013 device=0x4206 rev=0x03.02. This
  is the analog codec driving internal speaker, headphone
  jack, and S/PDIF.
- audiofs1 (ATI Oland HDMI): ATI R6xx codec at cad=0,
  vendor=0x1002 device=0xaa01 rev=0x03.00. HDMI audio
  block.

CORB and RIRB both 256 entries, DMA-allocated through
`bus_dma_tag_create` + `bus_dmamem_alloc` +
`bus_dmamap_load`, with the same alignment and 64-bit
coherent settings hdac(4) uses. Commands sent via CORB
writes with `bus_dmamap_sync` PREWRITE/POSTWRITE; responses
read by polling RIRB write pointer with PREREAD/POSTREAD
sync. No interrupts, no unsolicited handling beyond
logged-and-discarded.

This commit makes the substrate claim in ADR 0006 (audiofs
owns the codec command path) operationally true. The
specific call site the original audit cared about
(`hdaa_channel_getptr` and its 128-byte alignment) is now
reachable from audiofs's own code via `HDA_CMD_GET_PARAMETER`
verb dispatch.

What this commit explicitly does not establish:

- Function-group walk, widget enumeration, pin
  configuration. Those land in commit 3.
- Stream descriptors, DMA buffers, audible output. Commit 4+.
- CLOCK region writing. Still no earlier than commit 4,
  still gated on ADR 0003 transition verification.
- Any retirement of the original audit. The audit's
  question (whether ADR 0006's premise was correctly
  analyzed) is independent of this implementation's
  mechanical correctness; both remain inputs to
  ratification.

**Status update 2026-05-20 (commit 3: function-group
walk and widget enumeration).** Codec topology now visible
through audiofs's own command path. For each populated
codec on `pgsd-bare-metal`, audiofs queries sub-node counts,
classifies function groups (audio vs modem), reads
subsystem id, walks every widget under audio FGs, queries
each widget's audio-widget-cap, and for pin complexes reads
the configuration-default register.

Substantive cross-check against the previous snd_hda
attach: subsystem ids match (CS4206 = 0x106b8200, ATI R6xx
= 0x00aa0100), widget counts match (CS4206: 20 widgets at
nid 2-21; ATI: 12 widgets at nid 2-13), and pin
configuration defaults decode to the same role assignments
snd_hda's pcm devices implied:

- CS4206 nid=10 pin_cfg=0x002b4020 -> HP_Out, jack, front,
  black. The headphone jack (was pcm7 under snd_hda).
- CS4206 nid=11 pin_cfg=0x90100112 -> Speaker, fixed,
  internal. The internal speaker (was pcm6 under snd_hda).
- CS4206 nid=14 pin_cfg=0x90a60100 -> Mic_In, fixed,
  internal. The internal microphone.
- CS4206 nid=16 pin_cfg=0x004be030 -> SPDIF_Out, jack,
  top. The optical S/PDIF (was pcm8 under snd_hda).
- ATI R6xx nids 3,5,7,9,11,13: all pin_cfg=0x185600f0,
  i.e. Digital_Other_Out, all internal-special locations.
  The six HDMI streams (were pcm0-pcm5 under snd_hda).

audiofs's view of the hardware is now operationally
identical to snd_hda's, through completely independent
code: our CORB/RIRB rings, our verb dispatch, our
parameter parsing. This is independent corroboration of
the codec layer's content, not a confirmation that the
content was correctly analyzed (which remains the audit's
question).

Commit-3 scope deliberately stops at enumerate-and-log.
What this commit does not establish:

- Connection-list reads (which widgets feed which).
- Amplifier capability and current state.
- Stream format capability per converter.
- Graph construction: a path from a DAC widget through
  any intermediate mixers/selectors to a pin. Commit 4.
- Pin widget control (turning the headphone pin's output
  enable on; setting EAPD/HP-Amp-Enable). Commit 4.
- Stream descriptor allocation, BDL setup, DMA buffer
  binding, audible output. Commit 5+.
- CLOCK region writing. Still no earlier than commit 4,
  still gated on ADR 0003 transition verification.

**Status update 2026-05-21 (commit 6e: audible test signal,
spec-complete with empirical limit on this hardware).** All
spec-defined steps required to produce audible output have
been implemented and verified by hardware readback. The
analog signal nevertheless does not reach the speaker on
the pgsd-bare-metal iMac. The remaining gap is vendor-
specific (Apple iMac downstream Class-D amplifier enable,
not surfaced through HDA spec verbs) and is deliberately
left for separate work so audiofs's spec-defined surface
stays clean and small.

What landed in this commit:

  Audio buffer:
    - Replaced the zero-filled buffer with a precomputed
      750 Hz sine wave table (64 samples per period at
      48 kHz, amplitude 16384, 32 complete periods per
      8 KB buffer for seamless loop).
    - bus_dmamap_sync(PREWRITE) on the buffer after fill.
    - audiofs_sine_table[] at file scope, static const.

  Output selection priority:
    - Replaced "first matching pin wins" with a priority
      table favoring outputs a developer is most likely
      to hear at their desk: Speaker (10) > HP_Out (5) >
      Line_Out (3) > Digital_Other_Out (2) > SPDIF_Out (1)
      > CD (0).
    - This is the attach-time test-signal policy. Real
      output policy with jack-presence detection is
      separate.

  Power state management:
    - audiofs_power_up_widget: sends SET_POWER_STATE(D0)
      via verb 0x705, then polls GET_POWER_STATE until ACT
      = D0 with a 100 ms timeout. HDA widgets with the
      POWER_CTRL bit in their wcap come out of reset in
      D3 (sleep); D0 is required for them to process
      audio.
    - audiofs_power_up_codec_paths: powers up the FG and
      every widget on every discovered output path.
    - New pass in audiofs_walk_topology between path
      discovery and pin enable.

  LPIB sampling extended:
    - AUDIOFS_LPIB_SAMPLES bumped 5 -> 30 (290 ms run
      total, audibly long if the analog stage emits a
      signal).
    - dmesg prints every 10th sample plus the last to
      keep the log readable; eventlog still has every
      sample for the empirical record.

Verified on pgsd-bare-metal at the spec-defined surface:

  Audiofs0 (CS4206):
    DAC nid=4 (Speaker) selected (priority 10).
    Power states transitioned to D0:
      nid=10 (pin HP) ACT=D0 SET=D0
      nid=3  (DAC HP) ACT=D0 SET=D0
      nid=4  (DAC Speaker) ACT=D0 SET=D0
      nid=8  (DAC SPDIF) ACT=D0 SET=D0
    Pin enable, amp unmute, DAC format binding, stream
    descriptor, BDL, sine fill, DAC stream bind, RUN bit -
    all writes confirmed by readback.
    LPIB advances at exactly 192000 bytes/sec across 290 ms
    run, wrapping the 8 KB buffer cleanly.

  Audiofs1 (ATI Oland HDMI):
    Same sequence on DAC nid=2. All registers verified.
    LPIB advancement varies by run (see earlier
    observations).

What this commit does not achieve:

  Audible signal on the pgsd-bare-metal iMac's internal
  speaker. Honest assessment: every HDA-spec-defined step
  in the analog path is performed and verified, but no
  sound emerges from the speaker. The remaining gap is
  almost certainly the downstream Class-D amplifier
  enable, which on Apple hardware is asserted via a codec
  GPIO that requires vendor-quirk knowledge to address.

  This is a substantive limit, not a coding error. The
  exact bring-up audiofs performs (pin OUT_ENABLE, amp
  unmute at OFFSET gain, format 0x0011, stream tag bind,
  RUN) is sufficient to drive a discrete codec on a board
  whose analog output is not gated by an external amp
  enable. The iMac's internal speaker happens to be such
  a gated output.

  Documenting this here so a future reader sees the limit
  clearly. ADR 0006's hypothesis (a clean reimplementation
  can match the spec-defined path) remains supported. The
  vendor-quirk surface is separate work, accumulating as
  needed.

Out of scope, deferred:

  - Apple iMac Class-D amplifier enable via codec GPIO.
    Would need consultation of Linux's patch_cirrus.c
    quirks for CS4206 on subsystem 0x106b8200, or Cirrus
    data sheet for the same.
  - Per-codec quirk infrastructure generally. The clean
    way to integrate this is a small table keyed on
    (vendor_id, device_id, subsystem_id) producing
    callbacks that run after the spec-defined bring-up.
  - HDMI presence detection (HDMI's intermittent LPIB
    behavior remains a separate question).
  - Continuous streaming, ioctl/sysctl playback control,
    multiple concurrent streams.
  - Interrupt-driven position tracking.
  - Format negotiation beyond fixed 48k/16/stereo.
  - CLOCK region writing.

This concludes the commit-6.x series. audiofs implements
the full HDA-spec-defined controller and codec bring-up
for output, end-to-end from PCI attach to DMA-driven
position advancement, in around 3100 lines of code with
no dependency on snd_hda or its sub-layers.

**Status update 2026-05-21 (commit 6f: platform-policy
diagnostic, empirical finding documented).** The "honest
limit" of commit 6e turned out to be more precisely
characterized once the HDA spec's GPIO surface (sections
7.3.3.22-27) and the codec's GP I/O Count parameter
(section 7.3.4.14) were inspected. Result: the gap
between commit 6e and audible output on the iMac speaker
sits inside the standard verb surface, not outside it.

What landed in this commit:

  Platform-policy diagnostic pass at attach:
    - GP I/O Count query (parameter 0x11) at each
      populated codec's audio function group; logs
      NumGPIOs / NumGPOs / NumGPIs and the Wake / Unsol
      capability flags.
    - Pin EAPD_CAP enumeration (already-stored pin_cap
      walked, EAPD_CAP bit reported per pin).
    - If a codec advertises any GPIO lines AND no
      platform codec has been adopted yet, that codec
      becomes the "platform codec" for runtime GPIO
      control: SET_GPIO_ENABLE_MASK, SET_GPIO_DIRECTION
      (all outputs), SET_GPIO_DATA=0 are issued at
      attach. data=0 is a safe default (active-high
      amp gates leave amps powered down).

  Runtime controls:
    - dev.audiofs.N.gpio_data (read/write int).
      Writes drive SET_GPIO_DATA on the platform codec's
      FG nid; reads return the last-written value.
      ENXIO if no platform codec was adopted.
    - dev.audiofs.N.play_test_tone (read/write int).
      Any write re-runs audiofs_run_output_stream
      (DAC bind + RUN + 290 ms LPIB poll + clear) so
      the empirical sweep for "which GPIO bit enables
      the speaker amp" can happen without unloading
      the module.

  Eventlog entries added:
    gpio_cap, gpio_enable_mask_set, gpio_direction_set,
    gpio_data_init, gpio_data_set, pin_eapd_cap,
    play_test_tone_req.

Empirical finding (pgsd-bare-metal, iMac, CS4206 codec,
PCI subsystem 0x106b8200):

    audiofs0 GPIO inventory: GPIO=4 GPO=0 GPI=0
    audiofs0 pins with EAPD_CAP: none
    audiofs1 (ATI HDMI) GPIO inventory: GPIO=0

  Runtime sweep results (gpio_data value -> tone):

    0x00 -> silent
    0x01 -> silent       (bit 0 alone)
    0x02 -> silent       (bit 1 alone)
    0x04 -> silent       (bit 2 alone)
    0x08 -> AUDIBLE      (bit 3 alone)
    0x09 -> AUDIBLE      (bits 0+3)
    0x0a -> AUDIBLE      (bits 1+3)
    0x0c -> AUDIBLE      (bits 2+3)
    0x0f -> AUDIBLE      (all four bits)
    0x00 -> silent       (confirms bit 3 gates, doesn't latch)

  Conclusion: GPIO bit 3 on the CS4206 (subsystem
  0x106b8200) enables the iMac's internal Class-D
  speaker amplifier, active-high. Other GPIO bits
  have no observable effect on amp state. The
  mechanism is fully spec-defined (SET_GPIO_DATA
  verb 0x715 at the FG nid); the policy (which bit,
  which subsystem) is board-specific.

Architectural framing:

  - audiofs core (this commit) implements the standard
    HDA GPIO control surface. No vendor-specific verbs.
  - Platform policy (commit 6g) will codify the empirical
    finding as a small data table keyed on PCI subsystem
    ID producing an initial gpio_data value. On no match,
    gpio_data stays at 0 (safe).

  This shape replaces the "honest limit" framing of
  commit 6e: the limit was not "outside the HDA spec"
  but rather "inside the standard verb surface, outside
  generic autodiscovery." Inspection of capability
  registers gave us a controllable surface; empirical
  sweep through standard verbs gave us the policy.

Out of scope, deferred to commit 6g:

  - Automatic gpio_data assertion based on PCI subsys.
  - The policy table itself, with the Apple iMac entry.

**Status update 2026-05-21 (commit 6g: platform-policy
table, iMac speaker enabled automatically).** Adds the
small data table that codifies the empirical finding from
commit 6f as a (PCI subvendor, PCI subdevice) -> initial
gpio_data mapping. With this commit loaded on the
pgsd-bare-metal iMac, the audible test signal at attach
plays through the internal speaker without operator
action; on hardware with no matching entry, gpio_data
stays 0 (safe) and the runtime sysctls remain available
for empirical investigation.

Entries:

  Apple iMac (subvendor 0x106b, subdevice 0x8200,
  gpio_data=0x08). Comment in source cites the empirical
  sweep documented in commit 6f.

The table is data with comments, not vendor-quirk code.
Adding hardware requires adding one row plus a one-line
comment pointing to the commit message that contains
the empirical evidence.

The HDA-spec-defined surface (audiofs core) stays
unchanged: SET_GPIO_DATA verb at the audio function
group node, identical for every codec. Per-board policy
lives in the table.

This concludes the commit-6.x series. audiofs implements
the full HDA-spec-defined output bring-up plus the
inspection and policy surfaces needed to make real
hardware produce sound. Approximately 3500 lines, no
dependency on snd_hda or its sub-layers.

**Status update 2026-05-27 evening (audit-as-gate retired by
ADR 0010).** The gap-and-governance audit specified at
`audiofs/docs/snd4-gap-governance-audit.md` is no longer a
gate for AD-3's progression. ADR 0010
(`audiofs/docs/adr/0010-retire-audit-as-gate.md`, Accepted
2026-05-27 evening) records the framing change: UTF operates
by build-and-replace, the audit's purpose was evidentiary
not dispositive, and the audit's gate role is misaligned
with UTF's actual operating mode. F.3 and onward may
proceed under standard ADR-before-code discipline (each
sub-stage gets its own ADR) without audit clearance.

What this changes for AD-3's outstanding-work list: the
"audit-gate verification still owed" item is removed. Three
substantive items remain: F.5 semasound (the userland
semantic audio system per ADR 0004/0007), F.6 semaaud
retirement (modelled on AD-2), and the maintenance model
(the policy decision Vic owns; an explicitly-owed input per
ADR 0008).

What this does NOT change: ADR 0006's decision to replace
snd(4) in full stands (its rationale is principled, not
measurement-contingent, per ADR 0006 lines 50-54). ADR
0008's overall structure stands (F.0-F.7 sub-stage
breakdown, dependency ordering, owed inputs). The
governance-independence principle in
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md` stands. ADR-before-
code discipline holds. What is retired is one specific
procedural step (the audit gate), not the broader
discipline that produced ADRs 0001-0009.

The trade made by this retirement is recorded in ADR 0010
"Trade made by this decision": pre-implementation
evidence-gathering is replaced by during-and-after
implementation evidence (the substrate either works on
real hardware or doesn't). The audible-output milestone of
2026-05-21 is itself such evidence; F.3+ work will produce
more. The audit spec at
`audiofs/docs/snd4-gap-governance-audit.md` is preserved
as background reference material with a Status section
addendum recording the role change.

**Status update 2026-05-28 (F-stage reconciliation by ADR
0011).** ADR 0011
(`audiofs/docs/adr/0011-fstage-reconciliation.md`, Accepted
2026-05-28) reconciles the F-stage map in ADR 0008 with the
vertical-slice path actually taken in commits 1-6g. The
reconciliation observes that the audible-output milestone
proved the controller-to-DAC path is mechanically achievable
end-to-end (real evidence value), but did not close F.1
(state-file publication), F.2 (events ring), or F.3 (full
data path with user control) in the form ADR 0008 / the
proposal required.

What this changes for AD-3's outstanding-work list: the
three-item list (F.5, F.6, maintenance model) from ADR 0010
is replaced with the more honest seven-item list (F.1, F.2,
F.3 sub-milestones a-f, F.4, F.5, F.6, maintenance model).
The substantive requirements are not softened; the closure
criteria are reframed to reflect what audiofs.c actually
contains versus what each sub-stage owes. The status string
above is updated accordingly.

F.3 is decomposed by ADR 0011 into six named sub-milestones
(continuous streaming, user-controlled playback, interrupt-
driven position tracking, underrun detection, format
negotiation, HDMI bring-up) each of which will receive its
own ADR before implementation. ADR 0008 had anticipated the
F.3 decomposition needing its own ADR; ADR 0011 names the
sub-milestones; per-sub-milestone ADRs supply the scoping
for each.

What this does NOT change: ADR 0006's decision stands, ADR
0008's overall structure stands, ADR 0010's retirement of
the audit-as-gate stands, ADR-before-code discipline holds
(F.1, F.2, F.3.a-f, F.4 each need their own ADR before
implementation). What is added is structure for the
remaining work: a closure-dependency map (F.1 -> F.2 ->
F.3.a -> F.3.b; F.3.c independent of F.3.a, feeds F.3.d
and F.4; F.3.e and F.3.f parallel; F.4 -> F.5 -> F.6) and
reframed closure criteria for F.1, F.2, F.3 that match
their substantive requirements.

The next ADR after this one will scope F.1 (the state-file
publication) per its reframed closure criteria.

**Status update 2026-05-28 (F.1 scoped by ADR 0012).** ADR
0012 (`audiofs/docs/adr/0012-f1-state-file.md`, Proposed
2026-05-28) scopes F.1: the state-file machinery at
`/var/run/sema/audio/state`. The companion byte-level spec
lives in `shared/AUDIO_STATE.md` (analogous to how
`shared/INPUT_STATE.md` accompanies inputfs ADR 0002 and
`shared/CLOCK.md` accompanies ADR 0003).

The state file is physics-only per ADR 0007: it publishes
hardware capability (controller inventory, endpoint
inventory with format-capability bitmasks) and runtime
state (which endpoints are stream-active, current format if
active), not policy. It uses the established UTF idiom
(magic 0x54535541 "AUST", little-endian, seqlock-protected
multi-field reads, 4-byte ASCII magic mnemonic encoding
mirroring CLOCK and INST). Total file size in v1 is 2,624
bytes (64-byte header + 8 controller slots × 64 bytes + 32
endpoint slots × 64 bytes).

The F.1 implementation lands as a separate commit (or small
series). ADR 0012 and `shared/AUDIO_STATE.md` are
specification; the kernel-side publish/unpublish code is
the F.1 implementation that follows. Expected scope: 200-400
lines of C in the kernel publish path, plus a small Zig API
layer in `shared/src/audio.zig` (analogous to
`shared/src/input.zig`), plus optional diagnostic reader.

ADR 0012 is Accepted (ratified 2026-05-28). F.1
implementation (kernel publish path, Zig API, optional
diagnostic reader) follows.

**Status update 2026-05-28 (F.1 implementation landed,
`[~]` awaiting bench verification).** The F.1 state-file
publication is implemented across three commits: ADR 0012
ratified to Accepted; `audiofs_state.h` plus the kernel
publish path in `audiofs.c` (module-global controller
registry, endpoint enumeration from the topology walk, VFS
publication mirroring inputfs, modeventhand for clean
load/unload); and `shared/src/audio.zig` (the userspace
reader, unit-tested 4/4 under Zig 0.15.1).

Verification state is split honestly:

  - Kernel publish path: `[~]`. The `audiofs_state.h`
    byte-level layout is compile-verified (all
    `_Static_assert` size and offset checks pass under
    gcc), but the code has not been built in a full PGSD
    kernel or loaded on hardware.
  - Zig reader: `[x]`. Unit-tested under Zig 0.15.1
    (constants match the spec; a hand-built region
    round-trips; state_valid=0 and seqlock-contention edge
    cases behave correctly).
  - End-to-end: `[~]`. Owed: build the PGSD kernel with
    audiofs, kldload on pgsd-bare-metal, confirm
    `/var/run/sema/audio/state` exists with magic
    0x54535541 and version 1, parse it (hexdump or a tool
    over the Zig reader), confirm the controller and
    endpoint inventory including the iMac internal speaker
    endpoint, then kldunload and confirm clean
    removal/invalidation. That bench pass closes F.1 per
    ADR 0012's criteria and flips this entry's F.1 line
    from `[~]` to `[x]`.

Once F.1 is bench-verified, F.2 (events ring) is unblocked
per the ADR 0011 closure-dependency map (F.1 -> F.2).

**Status update 2026-05-28 (F.1 bench-verified `[x]` on
pgsd-bare-metal).** The kernel publish path is verified on
real hardware. After clearing three deployment/build issues
(none in the F.1 logic itself: a 14-commits-behind checkout
on the bench machine, a missing `vnode_if.h` in the module
SRCS, and an unused-variable `-Werror` stop), the module
builds clean, `nm` confirms the `audiofs_state_*` symbols
are in the `.ko`, and loading publishes the state file.

Verified results:

  - `/var/run/sema/audio/state` exists, root:wheel 0644,
    exactly 2624 bytes.
  - Header parses: magic 0x54535541 "AUST", version 1,
    state_valid 1, controller_count 2, endpoint_count 11,
    inventory_seq 2, slot counts 8/32, slot sizes 64/64.
  - Controller 0: Intel 0x8086:0xa170, subsystem
    0x8086:0x7270, ISS=7 OSS=9, 64-bit. Controller 1: ATI
    0x1002:0xaab0 (Oland HDMI).
  - 11 endpoints enumerated. The iMac internal speaker is
    present (endpoint_id 8, kind=speaker, direction=output,
    electrically_ready=1, runtime_active=1, current_format
    0x0011), satisfying the F.1 closure criterion. Other
    endpoints: Line_Out, HP_Out, SPDIF_Out, a second
    Line_Out on the CS4206, and six Digital_Other_Out HDMI
    endpoints on the Oland.
  - MOD_UNLOAD fires the invalidating write (state_valid
    set to 0; file mtime advances), and reload cleanly
    republishes a valid region. This satisfies ADR 0012
    closure criterion 4 ("removed, OR marked invalid by
    zeroing state_valid"); the code takes the invalidate
    path.
  - No lock or sleep warning in dmesg: VFS publication
    inline in device_attach works under kldload process
    context. The kthread-deferral pattern inputfs uses was
    not needed.

F.1 is closed `[x]`. F.2 (events ring) is now the next
unblocked sub-stage per the ADR 0011 dependency map.

Two non-blocking follow-ups the bench surfaced, filed so
they are not lost:

  - **F.1-fu1 (unload removes vs invalidates): RESOLVED
    2026-05-28.** The MOD_UNLOAD handler writes an invalid
    region (state_valid=0) and vn_close()s the file but does
    not unlink it, so the file persists on disk (invalidated)
    when audiofs is not loaded. Investigation found inputfs
    does the same (invalidate-and-close, no unlink), so this
    is the established UTF substrate pattern, not an audiofs
    defect. ADR 0012 closure criterion 4 permits invalidation.
    Disposition: keep invalidate-and-close to stay consistent
    with inputfs; the only actual fix was correcting the
    inline comment, which had claimed "remove" while the code
    invalidates. Comment corrected. No behavior change.
  - **F.1-fu2 (SPDIF classified as HDMI): RESOLVED
    2026-05-28.** SPDIF_Out endpoints were published with
    kind=6 (HDMI) because audiofs_state_fill_output_endpoint
    treated all digital output pins as HDMI. Fixed: added
    AUDIOFS_EP_KIND_SPDIF (value 8, first of the previously
    reserved range) and branched the digital-output
    classifier so pin-config device kind 0x4 (SPDIF_Out) maps
    to SPDIF while 0x5 (Digital_Other_Out) stays HDMI.
    Updated in lockstep across the four schema surfaces:
    audiofs_state.h (kernel enum), audiofs.c (classifier),
    shared/AUDIO_STATE.md (kind table), and
    shared/src/audio.zig (KIND_SPDIF + kindName). Purely
    additive; no region-layout change, header static-asserts
    and the 4 Zig reader tests still pass. The reserved range
    is now 9..15. DisplayPort-vs-HDMI discrimination within
    the 0x5 family remains deferred to F.3.f as before.

Deployment lesson recorded for future bench work: changes
flow pgsd-dev -> push -> pgsd-bare-metal pull -> install ->
build -> load, and a verification gate runs at each hop
(grep the source the next stage will consume; nm the .ko
before loading). Three separate "fix did not reach the
build" incidents this session were all caught by those
gates rather than by a misleading load result. The gates
belong in the audiofs bench-test doc.

**Status update 2026-05-28 (F.2 scoped by ADR 0013).** ADR
0013 (`audiofs/docs/adr/0013-f2-events-ring.md`, Proposed
2026-05-28) scopes F.2: the events ring at
`/var/run/sema/audio/events`. The companion byte-level spec
is `shared/AUDIO_EVENTS.md`.

The ring mirrors `shared/INPUT_EVENTS.md` closely (decision
owner chose maximal consistency with the established
substrate): 64-byte header, 64-byte event slots, power-of-two
slot count (256 in v1, total 16,448 bytes), lock-free single-
producer/multi-consumer with the seq-published-last writer
protocol and seq-revalidation reader protocol, plus a
pollable notification fd mirroring inputfs ADR 0021's
`/dev/inputfs_notify`. Magic 0x41554556 "AUEV", version 1.

Event taxonomy uses two-level (source_role, event_type)
dispatch like inputfs: role 1 = stream (stream_begin,
stream_end, xrun, format_change), role 2 = endpoint-lifecycle
(endpoint_attach, endpoint_detach, inventory_full). Physics-
only per ADR 0007: the xrun payload reserves gap_sample_pos
and gap_frames (the physics fact of where/how-big the gap
was), and each event carries ts_sync (audio sample position).
Both fields are reserved now so F.3.d (xrun detection) and
F.4 (clock writer) populate existing fields rather than
breaking the wire format.

F.2 emits endpoint-lifecycle events immediately (endpoints
exist as soon as controllers attach). Stream events have
their schema fully specified but are emitted only once the
data path creates real streams (stream_begin/end at F.3.a,
format_change at F.3.e, xrun at F.3.d). The events publisher
writes the state region's last_event_seq, closing the
correlation loop F.1 left open.

ADR 0013 is Accepted (ratified 2026-05-28). F.2
implementation (kernel publish path, audiofs_events.h, notify
cdev, Zig EventRingReader) follows.

**Status update 2026-05-28 (F.2 implementation landed, `[~]`
awaiting bench verification).** F.2 is implemented across two
commits: the kernel publish path (`audiofs_events.h` plus the
events code in `audiofs.c`: in-kernel ring buffer, seq-last
publish protocol, endpoint_attach emission wired into the
controller register, the `/dev/audiofs_notify` pollable cdev
mirroring inputfs AD-41.3, and the last_event_seq correlation
into the state region) and the Zig `EventRingReader` in
`shared/src/audio.zig`.

Verification state, split honestly as for F.1:

  - Kernel publish path: `[~]`. The `audiofs_events.h`
    byte-level layout is compile-verified (all
    `_Static_assert` checks pass under gcc), and the publish
    code is audited for the -Werror traps this session has
    hit (unused symbols, missing includes sys/poll.h /
    sys/event.h, the atomic u64 casts, uid/gid constants),
    but it has not been built in a full PGSD kernel or loaded
    on hardware.
  - Zig reader: `[x]`. 8/8 audio.zig tests pass under Zig
    0.15.1 (4 F.1 state + 4 new F.2 events: constants,
    endpoint_attach drain, xrun payload decode, overrun
    detection).
  - End-to-end: `[~]`. Owed: build the PGSD kernel, run the
    nm gate (audiofs_events_* and audiofs_notify_* symbols in
    the .ko), kldload on pgsd-bare-metal, confirm
    /var/run/sema/audio/events exists (16448 bytes, magic
    0x41554556, version 1, ring_valid 1), endpoint_attach
    events flow (writer_seq == endpoint count, 11 on the
    bench iMac), the state region last_event_seq matches the
    ring writer_seq, and /dev/audiofs_notify wakes a reader.
    Then kldunload clean, reload clean. That bench pass closes
    F.2 per ADR 0013 and flips the F.2 line to `[x]`.

The deployment-gate discipline from the F.1 bench session
applies: pull/apply on the build machine, grep the deployed
source, nm the .ko for the expected symbols, then load. F.2
adds more symbols to check (the events and notify functions).

Once F.2 is bench-verified, F.3.a (continuous streaming) is
the next sub-stage per the ADR 0011 dependency map (F.1 ->
F.2 -> F.3.a -> F.3.b).

**Status update 2026-05-28 (F.2 bench-verified `[x]` on
pgsd-bare-metal).** The events-ring publish path is verified
on real hardware. After one build fix (knlist_init takes 5
args on this FreeBSD, not 6; the in-tree inputfs was the
authoritative reference), the module builds clean, nm
confirms the audiofs_events_* and audiofs_notify_* symbols
in the .ko, and loading publishes the ring.

Verified results:

  - /var/run/sema/audio/events exists, root:wheel 0644,
    exactly 16448 bytes.
  - Header parses: magic 0x41554556 "AUEV", version 1,
    ring_valid 1, event_size 64, slot_count 256, writer_seq
    11, earliest_seq 1.
  - writer_seq 11 equals the endpoint count: one
    endpoint_attach event per enumerated endpoint (the same
    11 endpoints F.1 publishes). First slot decodes to seq 1,
    source_role 2 (endpoint), event_type 1 (attach), a real
    nanouptime ts_ordering, ts_sync 0 (correct; F.4 not yet),
    payload endpoint_id 6 kind 3 (Line_Out) direction 1
    (output), matching the F.1 inventory's slot 0.
  - The correlation loop is closed: the state region's
    last_event_seq now reads 11 (was 0 under F.1 alone),
    matching the events ring writer_seq. The events publisher
    correctly writes back into the state region.
  - No lock or sleep warning in dmesg: the selwakeup / KNOTE
    calls from the publish path and the VFS-in-attach-context
    both work under kldload. The kthread-deferral pattern was
    not needed (same result as F.1).
  - /dev/audiofs_notify cdev created (symbols present); the
    publish path calls selwakeup + KNOTE_UNLOCKED on each
    event. A poll/kqueue wake test would exercise criterion 6
    end to end; the cdev and wake calls are in place.

F.2 is closed `[x]`. F.3.a (continuous streaming) is now the
next unblocked sub-stage per the ADR 0011 dependency map.

One build fix recorded (folded into the consolidated patch):
knlist_init arg count 6 -> 5. This was the only signature
mismatch; knlist_add/remove/destroy, seldrain, selwakeup,
selrecord, KNOTE_UNLOCKED, and make_dev_p all matched in-tree
inputfs on the first try. The build gate caught the
knlist_init mismatch before load, consistent with the
deployment-gate discipline from the F.1 session.

**Status update 2026-05-29 (F.3.a scoped by ADR 0014).** ADR
0014 (`audiofs/docs/adr/0014-f3a-continuous-streaming.md`,
Proposed 2026-05-29) scopes F.3.a: continuous streaming via
a kthread-driven buffer refill loop, in-kernel
`audiofs_stream_begin` / `audiofs_stream_end` lifecycle
entry points, F.2 `stream_begin` / `stream_end` event
emission, and conversion of the attach-time test tone to use
the new continuous-stream API.

Key design decisions (decision-owner choices):

  - Refill cadence: per-stream kthread polling LPIB at 10 ms
    intervals. ADR 0011 places interrupt-driven position
    tracking in F.3.c; F.3.a stays cleanly within its scope
    by polling. The kthread is intentionally the placeholder
    F.3.c will replace with an interrupt handler.
  - Data source: continuous sine wave (the existing
    commit-6 waveform, looped). Hearable proof at bench;
    F.3.b will replace with a real source.
  - Attach behavior: the existing one-shot test tone is
    converted to a `stream_begin` call. After `kldload`, the
    speaker plays continuously until `kldunload`. That is
    the F.3.a closure proof. Bench iteration of F.3.a uses
    `kldunload` as the off switch. The operational
    consequence is documented; this is deliberate, not a
    surprise.
  - One-shot helpers removed: `audiofs_run_output_stream`
    and the LPIB sampling loop, along with the related
    one-shot diagnostic log events, are retired. The
    information they provided (does LPIB advance) is now
    ambient in the refill kthread's continuous polling. This
    is the build-and-replace framing from ADR 0010 applied:
    when an idea is superseded, it goes, not parked.

What F.3.a populates: the `stream_begin` and `stream_end`
event payloads reserved by ADR 0013 / `shared/AUDIO_EVENTS`.
`stream_begin` carries stream_id, format (0x0011), channels
(2), rate_hz (48000). `stream_end` carries stream_id and
`frames_total` derived from cumulative LPIB delta with wrap
accounting. xrun (type 3) and format_change (type 4) stay
schema-reserved until F.3.d and F.3.e. ts_sync stays 0
until F.4. No wire-format change.

What F.3.a does NOT do (per ADR 0011's sub-milestone
boundaries):

  - F.3.b: user-facing API. F.3.a's entry points are
    in-kernel callable; F.3.b wraps them.
  - F.3.c: interrupts. F.3.a polls LPIB from a kthread.
  - F.3.d: xrun detection. F.3.a's kthread keeps refills
    ahead of consumption under normal conditions; observed
    xruns are diagnostic only until F.3.d wires them to the
    events ring.
  - F.3.e: format negotiation. F.3.a hardcodes 48k/16/stereo.
  - F.3.f: HDMI bring-up.
  - F.4: clock writing. ts_sync stays 0.

ADR 0014 is Accepted (ratified 2026-05-29). F.3.a
implementation (audiofs.c changes for the kthread, entry
points, attach rewrite, removal of one-shot helpers, plus
small Zig event-helper additions) follows.

**Status update 2026-05-29 (F.3.a implementation landed,
`[~]` awaiting bench).** F.3.a is implemented across two
code commits on top of the intermediate removals:

- Kernel publish path (audiofs.c): audiofs_stream_begin /
  audiofs_stream_end as the in-kernel lifecycle entry points
  (F.3.b will wrap them in a user surface, F.3.c will
  replace the kthread refill with an interrupt path);
  audiofs_refill_worker kthread polling SDnLPIB at 10 ms;
  audiofs_refill_sine_fragment helper. Lock ordering: hw_lock
  for register writes / CORB commands, state_sx for F.2 event
  emission, no recursive locks. The stream_begin call moved
  out of audiofs_walk_topology (which runs under hw_lock) and
  into audiofs_attach (after the lock is released and after
  audiofs_state_register so the endpoint inventory is
  published), so stream_begin can take hw_lock cleanly
  without recursion.

- Zig EventRingReader (shared/src/audio.zig):
  Event.streamBegin and Event.streamEnd payload decoders.
  10/10 audio.zig tests pass under Zig 0.15.1 (4 F.1 +
  4 F.2 endpoint/xrun/overrun + 2 new F.3.a stream events).

Verification state:

  - Zig reader: [x]. 10/10 tests pass.
  - Kernel path: [~]. Compile-audited (braces balanced,
    em-dash check clean, all symbols defined and referenced,
    lock ordering reviewed: walk_topology no longer calls
    stream_begin so no recursion; stream_end called from
    detach before hw_lock is taken for reset). Not yet built
    in a full PGSD kernel.
  - End-to-end: [~]. Owed: build the PGSD kernel, run the nm
    gate (audiofs_stream_begin, audiofs_stream_end,
    audiofs_refill_worker, audiofs_refill_sine_fragment
    symbols in the .ko), kldload on pgsd-bare-metal, confirm
    the iMac internal speaker plays a continuous 750 Hz sine
    wave, the F.2 events ring shows a stream_begin event at
    attach (writer_seq advances to 12 from 11), and on
    kldunload the speaker stops cleanly with a stream_end
    event whose frames_total is consistent with the elapsed
    runtime.

Operational reminder per ADR 0014: bench iteration of F.3.a
uses kldunload as the off switch. The iMac sings until then.

The deployment-gate discipline from earlier sessions
applies: pull on the build machine, grep the deployed source
for new symbols, nm the .ko for them before loading. The
predictable -Werror traps were audited (the audit caught a
recursive-lock bug in the first draft and a missing hw_lock
around a CORB-using send_command; both were fixed before
patch generation).

**Status update 2026-05-29 (F.3.a bench-verified `[x]` on
pgsd-bare-metal).** F.3.a is closed on real hardware with
the amended closure criteria from ADR 0014 (post-bench
safety amendment, same date).

Bench history, three iterations:

  1. First load: `stream_begin` succeeded, `stream_end` hung
     the machine on kldunload (msleep_spin used on an
     MTX_DEF mutex). Operator had to restart. Fixed:
     msleep_spin -> msleep.
  2. Second load: clean kldunload, frames_total 272157
     consistent with ~5.7 seconds elapsed, all events
     correlated, but speaker was silent. Diagnosis: the
     platform-policy table lookup keyed on controller PCI
     subsystem (Intel) instead of codec FG subsystem
     (Apple); never matched the iMac entry; the speaker
     amp gate stayed off. Fixed: lookup uses
     codec->fg_subsystem.
  3. Third load: sound came out. Loud. Operator could not
     silence through SSH; had to pull power. Fixed: sine
     amplitude dropped 100x (-6 dBFS -> -40 dBFS) AND
     autoplay made opt-in via hw.audiofs.test_tone tunable
     (default 0). ADR 0014 amended to reflect the new
     operational consequence.
  4. Fourth load (this one): clean default-silent load
     (stream_begin_skipped_tone_off events in the log,
     writer_seq=11 with no stream_begin), runtime tunable
     toggle 0->1 produced quiet sine, toggle 1->0 stopped
     it cleanly. kldunload clean after toggling. The
     in-band off switch works. F.3.a closed.

Verified bench results:

  - default kldload: silent, stream_begin_skipped_tone_off
    events emitted (one per controller). writer_seq=11.
  - `sysctl hw.audiofs.test_tone=1`: iMac internal speaker
    plays continuous 750 Hz sine at room-comfortable volume
    via the F.3.a kthread refill loop. writer_seq advances
    (stream_begin event).
  - `sysctl hw.audiofs.test_tone=0`: stream_end fires
    cleanly via the in-band off switch. Speaker stops with
    no click. writer_seq advances (stream_end event).
  - `build.sh unload` after the toggle cycle: clean, no
    hang, no kthread leak.
  - State <-> events correlation invariant preserved
    throughout (last_event_seq tracks writer_seq).

Three real bugs surfaced and fixed during F.3.a bench:

  - msleep primitive mismatch (msleep_spin requires MTX_SPIN;
    hw_lock is MTX_DEF). Fixed in commit d760589.
  - Platform-policy lookup key (controller PCI subsystem vs
    codec FG subsystem; the latter identifies the board on
    Macs). Fixed in commit b2d3439. This was a pre-existing
    commit-6g bug, invisible until F.3.a required audibility.
  - Bench-safety operational miscalibration (-6 dBFS at gain
    115 was unbearable continuously; no in-band off switch).
    Fixed in commit 1365098 with ADR 0014 amendment.

Discipline lesson recorded in ADR 0014's amendment section:
the design contract is on paper, but bench reality reserves
the right to amend when the original framing was wrong about
real operational impact.

F.3.a is closed `[x]`. F.3.b (user-facing control API) is
the next sub-stage per the ADR 0011 dependency map
(F.3.a -> F.3.b). The audiofs_stream_begin /
audiofs_stream_end signatures and the F.2 stream event
payloads are now stable; F.3.b will wrap them.

**Status update 2026-05-30 (F.3.b implementation landed,
`[~]` awaiting bench).** F.3.b ratified to Accepted (ADR
0015) and implemented in two coordinated commits:

  - **Kernel publish path (audiofs.c)**: new cdevsw with
    open / close / write / read / poll / ioctl handlers;
    32 KB user ring per controller (malloc'd at attach,
    head/tail size_t cursors with power-of-2 mask); new
    user_ring_mtx (MTX_DEF, also the back-pressure msleep
    address); 3-state source machine (stopped /
    running-sine / running-user); audiofs_source_set
    helper; audiofs_refill_user_fragment with shortfall
    zero-fill and underflow counting;
    audiofs_refill_fragment dispatcher consulting source
    under user_ring_mtx. cdev created in attach via
    make_dev_s, destroyed FIRST in detach via destroy_dev
    so in-flight ops drain before stream teardown. The
    test_tone sysctl handler updated to respect cdev_open
    (cdev consumer wins; tunable still recorded so
    cdev_close consults it).

  - **Userland bench tool (audiofs/tools/playtone/)**: a
    small C program that writes a bounded N seconds of
    quiet sine to /dev/audiofs<N> and exits. This is the
    bench-safety gate from ADR 0015: bounded process
    lifetime bounds audible time, preventing a repeat of
    F.3.a's pulled-power scenario.

Verification state:

  - Kernel path: [~]. Compile-audited (braces 282/282,
    em-dashes 0, all 9 new symbols defined and referenced,
    lock-ordering reviewed: state_sx -> user_ring_mtx ->
    hw_lock; no recursive locks; destroy_dev sequenced
    first in detach so in-flight cdev ops drain before
    stream teardown). Not yet built in a full PGSD kernel.

  - playtone: not yet built or run.

  - End-to-end: [~]. Owed: build the PGSD kernel; nm the
    .ko for new symbols (audiofs_cdev_open / _close /
    _write / _read / _ioctl / _poll, audiofs_source_set,
    audiofs_refill_fragment, audiofs_refill_user_fragment);
    kldload on pgsd-bare-metal; ls -l /dev/audiofs0 (mode
    0666 root:wheel); build playtone; run
    `./playtone /dev/audiofs0 1` and hear ~1 second of
    quiet sine; verify F.2 stream_begin event on open and
    stream_end event on close with frames_total ~48000
    (1 second at 48 kHz); verify EBUSY on double-open;
    verify SIGKILL on a running writer cleans up state;
    test source swap (test_tone=1; cdev_open should swap
    sine to user data without a stream restart, single
    stream_begin in the F.2 ring); test back-pressure
    (slow writer triggers msleep without crashing the
    kthread); kldunload clean after all the above.

Known v1 behavior (acceptable per ADR 0015 closure
criteria):

  - Cold-open path has ~85 ms of pre-existing sine leak
    from the BDL initial fill before the kthread's first
    refill iteration switches to user data. Documented in
    cdev_open block comment; F.3.c may address.

  - close() in v1 does not drain queued audio (up to
    ~210 ms lost on close). Documented in ADR 0015.

  - Underflow counter accumulates but emits no F.2 event;
    F.3.d will surface as xrun events.

The deployment-gate discipline applies: pull, install,
build, nm gate for the new symbols, then load. Bench
iteration uses playtone (bounded process lifetime) rather
than indefinite manual writers. The F.3.a discipline lesson
holds: design contract on paper, bench reality reserves the
right to amend if the operational impact differs from the
predicted one.

**Status update 2026-05-30 (F.3.b bench-verified `[x]` on
pgsd-bare-metal).** F.3.b is closed on real hardware. All
seven ADR 0015 closure criteria are met across two bench
sessions:

Bench session 1 (basic audibility, ADR 0015 criteria 1-3):

  - /dev/audiofs0 cdev exists, mode 0666 root:wheel.
  - playtone /dev/audiofs0 1 wrote 192000 / 192000 bytes;
    iMac internal speaker played 1 second of quiet
    750 Hz sine via the kthread refill loop drawing from
    the user ring.
  - F.2 stream_begin event on cdev_open, stream_end on
    cdev_close. frames_total=40815 (~850 ms of consumed
    fragments before close-doesn't-drain truncated; v1
    behavior documented in ADR 0015).
  - State <-> events correlation invariant preserved
    (writer_seq=13 at end of session matched state file's
    last_event_seq).

Bench session 2 (criteria 4-7, scripted via
audiofs/bench-f3b.sh): 14 PASS / 0 FAIL / 0 WARN.

  - Criterion 4 (source swap): with `hw.audiofs.test_tone=1`
    set first, cdev_open swapped source from SINE to USER
    atomically without a stream restart. cdev_open
    arg=0x0 confirmed needs_stream_begin=0; writer_seq
    advanced 11 -> 13 (one tunable-driven stream_begin pair
    spanning both controllers) but did NOT advance through
    the cdev_open / cdev_close window. cdev_close arg=0x1
    confirmed want_sine=1, swapping back to SINE without
    a stream_end.

  - Criterion 5 (back-pressure): 3-second playtone took
    2.857 sec wall-clock (would be ~0 sec if back-pressure
    were broken; would be infinity if deadlocked). Ring
    drain rate gating write(2) is working as designed.
    frames_total=136788 in expected 100k-150k range.

  - Criterion 6 (exclusive open / cleanup): double-open
    correctly returned EBUSY ("playtone: open
    /dev/audiofs0: Device busy"). After holder released,
    second playtone succeeded. SIGKILL on a 10-sec
    playtone victim triggered D_TRACKCLOSE-driven cleanup;
    subsequent open succeeded immediately. No stuck
    cdev_open flag, no leaked kthread, no DMA leak.

  - Criterion 7 (no deadlock/panic/leak): clean kldunload
    after the full test sequence; no panic, LOR, or
    abandoned-kthread indicators in dmesg.

audiofs1 anomaly resolution: the previous bench session's
"audiofs1 emitted stream events without OSS" puzzle was
my misreading of an earlier dmesg. The current bench
confirms audiofs1 has OSS=6 (AMD discrete GPU HDMI
controller with six Digital_Other_Out paths); stream_begin
on audiofs1 succeeds, the kthread runs, LPIB advances. The
F.3.b cdev exists for audiofs1 as well; whether HDMI sound
reaches an attached display is F.3.f territory, but the
audiofs kernel side works on the controller.

Three real bugs surfaced and fixed during the F.3.b bench:

  - playtone Makefile man-page wart (NO_MAN=1 deprecated;
    fixed to MAN= empty). The binary built but make rc was
    non-zero; bench-f3b.sh's pre-build check would have
    masked it. Fixed in commit 20f8c69.
  - bench-f3b.sh path bug (script placed at audiofs/tools/
    but referencing ${SCRIPT_DIR}/tools/playtone/playtone,
    yielding audiofs/tools/tools/playtone/playtone). Fixed
    by relocating script to audiofs/bench-f3b.sh alongside
    build.sh. Fixed in commit 20f8c69.
  - (No kernel bugs surfaced during F.3.b bench; both
    issues were tooling, not the kernel implementation.
    The F.3.a session's audit discipline caught the
    kernel-side bugs before bench.)

F.3.b is closed `[x]`. The audiofs kernel side now has a
complete user-controlled output path: applications open the
cdev, write samples, close; the kthread refills BDL
fragments from the user ring with back-pressure on full and
silence on empty. semasound (per ADR 0005) is the intended
consumer; it can be written against the F.3.b surface as
soon as F.5 work begins.

F.3.c (interrupt-driven position tracking) is the next
sub-stage per ADR 0011's dependency map. F.3.c swaps the
F.3.a kthread polling for the real HDA interrupt handler.
F.3.d (xrun detection) depends on F.3.c. F.3.e (format
negotiation) depends on F.3.b (now closed). F.3.f (HDMI)
is parallel and can be taken at any time.

**Status update 2026-05-30 (F.3.c implementation landed,
`[~]` awaiting bench).** F.3.c ratified to Accepted (ADR
0016) and implemented in one substantive commit
(64d6716). Changes:

  - **Kernel interrupt path (audiofs.c)**: new
    audiofs_intr_filter (filter context, MTX_SPIN
    intr_lock, three register I/Os max) and
    audiofs_intr_thread (ithread context, hw_lock +
    user_ring_mtx) replace the F.3.a polling kthread.
    audiofs_refill_worker deleted along with its
    kproc_create/exit, stop_requested signalling, and
    msleep-on-hw_lock wait. output_stream_running
    renamed to output_stream_active (12 sites).

  - **IRQ resource lifecycle (audiofs_attach /
    audiofs_detach)**: pci_alloc_msi attempted first
    (single vector); fall back to INTx
    (RF_SHAREABLE | RF_ACTIVE) if MSI not granted with
    count=1. bus_setup_intr registers filter+ithread
    handlers under INTR_TYPE_AV | INTR_MPSAFE.
    bus_teardown_intr in detach blocks until any
    in-flight ithread completes; then IRQ release and
    pci_release_msi as appropriate. Setup failure is a
    hard attach error (no polling fallback per ADR 0016).

  - **stream_begin / stream_end ordering** (the critical
    race-free choreography):
      stream_begin: configure -> DAC bind -> events
        publish -> active=1 (intr_lock) -> SIE+GIE+CIE in
        INTCTL (hw_lock) -> dma_sync -> RUN (hw_lock).
        First interrupt fires within ~21 ms.
      stream_end: active=0 (intr_lock; ithread entry
        guard now rejects) -> SIE clear (hw_lock) -> RUN
        clear (hw_lock) -> final LPIB read -> DAC unbind
        -> stream_end event. No msleep wait; no
        abandonment timeout.

  - **BDL IOC bits flipped**: configure_output_stream
    writes ioc=htole32(1) on both entries (was 0). One
    interrupt per ~21 ms fragment, ~47 interrupts/sec/
    stream at 48k/16/stereo.

  - **Diagnostics**: new sysctls
    dev.audiofs.<N>.interrupts_setup (read-only string:
    "msi" / "intx" / "none") and underflow_count
    (read-only uint64). New audiofs_log entries
    intr_setup_msi / intr_setup_intx at attach;
    intr_teardown at detach; irq_alloc_failed and
    irq_setup_failed on attach error paths.

  - **Comment refresh**: F.3.a streaming-header block
    rewritten to document the F.3.c interrupt model and
    the four-tier lock order (state_sx -> user_ring_mtx
    -> hw_lock -> intr_lock). F.3.b user-ring comments
    updated to "ithread drain" instead of "kthread drain".
    The historic "mirrors hdac.c" scaffolding comments
    were left alone where they refer to register-level
    sequences (still spec-accurate); only the runtime
    descriptions that referenced the kthread were
    updated.

  - **Removed**: AUDIOFS_REFILL_POLL_TICKS,
    AUDIOFS_STREAM_STOP_TIMEOUT macros (unused after
    kthread retirement); #include <sys/kthread.h>.

Audit performed BEFORE commit (the F.3.b discipline
lesson, expanded for F.3.c's hardware-shaped surface):

  - Brace balance 297/297, 0 em-dashes.
  - All three new symbols (audiofs_intr_filter,
    audiofs_intr_thread, audiofs_sysctl_interrupts_setup)
    have forward decl + definition + call site.
  - No msleep_spin on MTX_DEF anywhere. The one msleep
    remaining is F.3.b's back-pressure msleep on
    user_ring_mtx (MTX_DEF), correct.
  - Lock acquisitions in ithread never overlap (intr_lock
    released before hw_lock acquired; hw_lock released
    before refill_fragment takes user_ring_mtx). No
    recursive locking.
  - Filter handler accesses only INTSTS and SDnSTS, both
    of which are exclusively owned by the interrupt
    path (verified by grep). Other registers (INTCTL,
    SDnCTL, SDnLPIB, etc.) are hw_lock-only. No
    torn-read risk between filter and other paths.
  - stream_begin order (active=1 -> SIE -> RUN) and
    stream_end order (active=0 -> SIE clear -> RUN clear
    -> final LPIB) close the
    SIE-cleared-but-ithread-already-scheduled race via
    the entry guard.
  - pci_alloc_msi failure handling distinguishes "did
    not succeed" (do not release) from "succeeded but
    wrong count" (release before retry to INTx).
  - LPIB delta wrap arithmetic same as F.3.a's polling
    worker (proven correct in F.3.a/b bench).

Verification state:

  - Kernel path: [~]. Compile-audited (braces balanced,
    em-dashes 0, all new symbols defined and referenced,
    lock-ordering reviewed). Not yet built in a full
    PGSD kernel.
  - End-to-end: [~]. Owed: build the PGSD kernel; nm the
    .ko (audiofs_intr_filter / _thread /
    sysctl_interrupts_setup present; audiofs_refill_worker
    ABSENT); kldload; verify dmesg shows intr_setup_msi
    or intr_setup_intx; verify dev.audiofs.0.
    interrupts_setup reports "msi" or "intx"; rerun
    bench-f3b.sh (the F.3.b 14-PASS suite is the F.3.c
    gate per ADR 0016 closure criterion 2); verify
    `ps -auxw | grep audiofs_refill` is empty (kthread
    really gone); verify `vmstat -i` shows ~47 audiofs
    interrupts/sec under sustained playtone load (not
    thousands; not zero); confirm clean kldunload.

The deployment-gate discipline applies: pull, install,
build, nm gate for the new symbols and absence of the
kthread, then load. Bench iteration via bench-f3b.sh
remains the same (the suite is unchanged; F.3.c's
behavioral invariants are required to be identical to
F.3.b's from userland's perspective).

Known v1 caveats (unchanged from F.3.b):
  - ~85 ms cold-open sine leak from BDL initial fill.
  - close() does not drain queued audio.
  - Underflow counter accumulates internally; F.3.d
    will surface as F.2 xrun events.

If a bench iteration surfaces a kernel bug despite the
pre-bench audit, the F.3.a discipline lesson applies:
when two successive fix iterations fail, stop theorizing
and read the spec.

**Status update 2026-05-31 (F.3.c bench-verified `[x]` on
pgsd-bare-metal).** F.3.c is closed on real hardware.
bench-f3b.sh, the F.3.b verification suite, runs unchanged
under the new interrupt path and produces 14 PASS / 0
FAIL / 0 WARN. ADR 0016's closure criterion 2 (F.3.b's
14-PASS suite must continue to pass) is met, which is the
strongest evidence the userland-visible behavior of
audiofs is unchanged from F.3.b's verified baseline.

Two bench iterations were needed before close; both
surfaced real kernel bugs that the pre-bench audit had
missed:

  - **Iteration 1 (commit 7237d41)**: SDnCTL IOCE / FEIE
    / DEIE bits were not set. The HDA spec
    (section 3.3.35) gates the BDL IOC honoring on the
    stream-level IOCE bit; without it, the controller
    treated the IOC=1 BDL entries as undefined-state
    triggers and stalled DMA after one fragment. Bench
    symptom: brief audible audio (one fragment) then
    silence; writer blocked indefinitely on
    back-pressure msleep; frames_total reported < 5 ms
    over 35 sec wall-clock windows.

  - **Iteration 2 (commit fc03609)**: INTSTS / INTCTL
    bit positions for stream interrupts use the GLOBAL
    stream-descriptor enumeration (input streams first,
    then output streams), but the code used the local
    output-stream-index (1 << output_stream_idx) without
    the num_iss offset. For the Intel HDA in the iMac
    (num_iss=4), this set/checked bit 0 instead of bit 4,
    so the filter handler returned FILTER_STRAY on every
    interrupt and the ithread never ran. Bench symptom:
    audible continuous looping sine (the prefilled BDL
    looping forever); writer still blocked; frames_total
    still tiny because the ithread's LPIB-delta
    accumulation never executed. (The bug did not affect
    audiofs1 because num_iss=0 on the AMD HDMI
    controller, so output stream 0 happens to map to
    bit 0 there.)

After both fixes, bench-f3b.sh's 14 closure criteria all
pass: cdev semantics, back-pressure timing (~3 sec
wall-clock for 3-sec writes), exclusive open with EBUSY
on double-open, SIGKILL cleanup via D_TRACKCLOSE,
writer_seq advancement, no panic / LOR / abandoned
indicators, clean kldunload.

Discipline lesson recorded: pre-bench audit caught all of
F.3.b's potential kernel bugs (zero bench iterations for
kernel issues; only tooling), but caught zero of F.3.c's
kernel bugs (two bench iterations to surface both). The
difference is hardware-shaped semantics: F.3.b's risks
were concurrency (lock-class mismatch, race windows,
recursive locks) which the audit reasoned about well;
F.3.c's risks were spec-derived register semantics where
the audit needed to verify against the HDA 1.0a spec,
not just against the source code. **Future
hardware-shaped sub-stages: the audit must include a
spec re-read alongside the code re-read.** Specifically:
when the design touches register-level enable bits, the
audit must trace each enable from its register
definition in the spec through to the code that
sets/clears it, verifying that the bit position matches
the enumeration order documented in the spec.

The four-level enable structure that bit us:

  - PCI level: pci_alloc_msi / bus_setup_intr (caught
    correctly in design).
  - Controller level: INTCTL GIE / CIE / SIE (SIE bit
    position bug, iteration 2).
  - Stream level: SDnCTL IOCE / FEIE / DEIE (missing
    entirely, iteration 1).
  - Source level: BDL entry IOC (caught correctly in
    design).

Each layer can independently gate the interrupt path.
The audit should enumerate all four explicitly.

The interrupt path is now the only path for stream
progression: the F.3.a polling kthread is fully retired
(audiofs_refill_worker gone, audiofs_refill kproc absent
from ps), the ithread refills BDL fragments from the
user_ring as interrupts fire (~47/sec/stream at
48k/16/stereo), the back-pressure msleep on the writer
side gets woken correctly when the ring drains, and
stream_end completes synchronously without msleep waits
because the active flag gates ithread entry and
bus_teardown_intr blocks until in-flight ithread
invocations complete.

F.3.c is closed `[x]`. F.3.d (xrun event surfacing) is
the next unblocked sub-stage; it converts the
output_stream_underflow_count counter (already
accumulated by the F.3.c ithread on FIFOE) into F.2
xrun events. F.4 (clock writer) can now be designed
against the interrupt-paced frames_played value F.3.c
maintains. F.3.e (format negotiation) is unblocked and
parallel. F.3.f (HDMI) is parallel and can be taken at
any time.

### `[x]` AD-3: Audio output: replace OSS dependency  *(DONE; maintained end-state 2026-06-05 under ADR 0030. F.0 through F.6 complete, ADRs 0001-0029; the maintenance model Closed, all seven criteria discharged (the operator mark given 2026-06-05; stewardship and scope ratified; the first maintenance batch bench-verified; the takeover protocol documented; handoffs recorded; scripts/rc.d retired by ruling; this end-state entry), with change classes K/B/P/T/R governing all subsequent audio-subsystem work. The F-chain chronicle is the preceding record entry; F.3.f remains deferred as a live entry in BACKLOG.md)*

**Tracks**: `audiofs/docs/audiofs-proposal.md` (Stage F).

**F.3.f (HDMI bring-up) deferral (2026-06-01).** HDMI audio is
not self-contained on the HDA codec. The HDMI/DisplayPort audio
codec is the GPU's HDA function, separate from the analog codec,
and it only reports pin presence, exposes an ELD, and clocks
audio once the GPU display side has detected the sink,
programmed the mode/transcoder/port, lit the link, and enabled
the audio path, including writing the sink's ELD into the codec.
That coordination is the role `drm-kmod` fills. PGSD will not use
`drm-kmod`; the equivalent display/modeset and HDMI-audio-enable
capability is to be provided within UTF and does not yet exist.
Until it does, audiofs has no powered or populated HDMI codec to
act on, so the ADR 0011 F.3.f scope (presence detection, audio
infoframes, stream verification) cannot be implemented or
bench-verified. F.3.f is therefore deferred, blocked on that
UTF-provided display capability, not on hardware and not on
audiofs. It is off the AD-3 critical path: ADR 0011 makes F.3.f
parallel to F.3.a-e, and F.5 depends on F.3.b-e (all closed), so
AD-3 proceeds via F.5 then F.6 without it. When unblocked,
verification moves to a laptop with a working HDMI/DP output and
an audio sink; `pgsd-bare-metal` (the iMac) cannot drive HDMI
audio end to end. This dependency is distinct from DF-6 (drawfs
DRM-backend wiring), which targets the existing `drm-kmod` KMS
path; the no-`drm-kmod` direction means the UTF-native display
capability F.3.f waits on is a separate, yet-to-be-scoped effort.


**Remaining work.** The maintenance model (ADR 0030, Accepted
2026-06-05, in force; criteria 2 through 4 discharged 2026-06-05
by the first maintenance batch with bench evidence, and the
Decision 5 production mode landed and passed all four suites
against the supervised broker the same day; remaining: the
scripts/rc.d ruling, the end-state entry, the operator mark):
named stewardship and the bus factor, confirmed-target
scope with ADR-gated extension, change classes K/B/P/T/R with
per-class bench obligations, the s6-first takeover protocol in both
directions, a production mode for the verification suites as the
first work item under the model, and the disposition of the
closure-week ledger. The ledger: uninstall stop-before-delete
ordering (required under ADR 0030 Decision 4); chrono_dump's
blocking read (handed to chronofs); the bench-tone strings marker
and utf.conf.sample's stale [semainput] section and clock_path
(T-class, first maintenance batch); scripts/rc.d wholesale
retirement (operator's open question); svscan.log rotation (handed
to the whole-of-project supervision evaluation, ADR 0028
Decision 1).

**Standing obligations carried forward.** The chipset scope rule
and its two open fences (post-classic-HDA ownership, the
specific-platform question) per ADR 0008 section 3a; the
pgsd-kernel snd(4)-removal configuration delta (the maintenance
model carries responsibility for it across FreeBSD rebases,
BACKLOG-history "AD-3: F-chain record", 2026-05-21 entry); the
F.3.f deferral above. The complete decision record is ADRs
0001-0029; the day-by-day chronicle is the history record entry.

### `[x]` AD-27: trackpad pointer updates not reaching cursor surface  *(CLOSED 2026-06-08: motion fix bench-verified on pgsd-bare-metal; the discrete button-event defect carved out to AD-52; reopened entry, supersedes the 2026-05-08 Done record above; Small-Medium)*

**Resolution (2026-06-08, operator-ratified).** The motion fix is
verified on pgsd-bare-metal across four interactive bench runs
(scripts/ad27-cursor-verify.sh, root-run; ~5,700 synthesized
pointer.motion records total from the touchpad slot, x/y advancing
smoothly, cursor follows single-finger touch). The original symptom
(trackpad pointer not reaching the cursor surface) is resolved. The
reading-time state-region-buttons caveat was DISPROVEN: during a
drag the held button rides every motion record (buttons=0x1 carried
across hundreds of motions per run), so click-and-drag does carry
the button.

One defect surfaced during the button benching and is carved out to
its own entry (AD-52), not a blocker on the motion resolution: the
discrete pointer.button_down / button_up events are unreliable.
Across four runs button_down fired exactly once (the first-ever
press) and button_up never. The button STATE is read correctly (it
appears in motion), but the discrete transition events are emitted
only on a btn != sc_touch_prev_button change evaluated solely when a
Report 7 is dispatched, and sc_touch_prev_button (inputfs.c:723) is
assigned in exactly one place (3546) and never reset on
contact-end. So a release whose 1->0 transition is not carried by a
dispatched Report 7 latches the previous-button state at 1,
suppressing all later button_down and never emitting button_up. See
AD-52 for the fix (ADR before code).

A note for the record: the bench was repeatedly blocked first by the
state region reading invalid, which proved to be AD-34 / FREEBSD_ISSUES
 #1 biting inputdump's non-root mmap (the region was valid; root reads
were correct), and then by test instructions that assumed a clickpad
surface when this HAILUCK pad has separate physical buttons. Both are
captured in scripts/ad27-cursor-verify.sh (root gate with the AD-34
reason; physical-button prompts; unfiltered drag capture).

----
*(Original reopened-entry content preserved below.)*


**Status correction (2026-06-08).** The diagnosed fix is ALREADY
IN THE TREE and was never closed (the entry's line numbers
2849-2902 are stale; the code now lives at inputfs.c 3255-3560).
The touch dispatcher synthesizes pointer.motion and updates the
state-region pointer slot when exactly one contact is active
(3255-3491), with the full transition handling (no jump on
touchdown, freeze at 1->2, re-resolve without jump at 2->1, hold
at 1->0) and pointer.enter/leave focus parity beyond the original
spec; and a clickpad-button block (3513-3560) emits pointer
button_down/up. Implementation is done; what remains is bench
verification on the attached HAILUCK touchpad. One reading-level
caveat to confirm at bench: the click block writes button events to
the event ring but does not appear to update the state-region
button bits the motion path reads, so click-and-drag may not carry
the button even though motion and discrete clicks work. Bench tool:
scripts/ad27-cursor-verify.sh (interactive; three phases MOTION,
CLICK, DRAG; the drag phase WARNs rather than FAILs on the
state-region-buttons gap, isolating it as a follow-up). On a green
or core-green run AD-27 closes; a drag WARN spins out the small
follow-up.

**Status update (2026-05-08, post-AD-30.1).** AD-27 was
filed 2026-05-07, superseded 2026-05-08 by AD-30 (because
inputfs was attaching to zero HID devices, making the
trackpad question unobservable), and now re-opens with a
precisely localised scope after AD-30.1 restored
inputfs's HID attachment.

The bench state after AD-30.1:

  - inputfs2 attached the HAILUCK touchpad at hidbus2
    with `roles=pointer,touch`. Diagnostic dmesg lines:

    ```
    inputfs2: <HAILUCK CO.,LTD USB touchpad inputfs HID device> on hidbus2
    inputfs2: inputfs: descriptor 505 bytes, 48 input items, 0 output, 1319 feature, depth=2
    inputfs2: inputfs: pointer locations cached (x=yes y=yes wheel=yes buttons=1 count=6)
    inputfs2: inputfs: digitizer locations cached (report_id=7 tip=yes x=yes y=yes confidence=yes contact_id=yes scan_time=yes contact_count=yes button=yes x_range=[0..1535] y_range=[0..1023])
    inputfs2: inputfs: roles=pointer,touch
    inputfs2: inputfs: Device Mode set to MT Touchpad (report_id=11 rlen=2)
    ```

    All HUP_DIGITIZERS fields located. Device successfully
    flipped from Mouse Mode to Multi-touch Touchpad Mode
    (the AD-1 step 5 feature-report write succeeded;
    `report_id=11 rlen=2`).

  - **Touch events are produced.** `inputdump events` during
    trackpad-only motion shows a stream like:

    ```
    seq=542 ts=... dev=2 touch.type2
    seq=543 ts=... dev=2 touch.type2
    ...
    seq=557 ts=... dev=2 touch.type3
    ```

    `touch.type2` is `INPUTFS_TOUCH_MOVE` (constant at
    `inputfs.c:479`); `touch.type3` is `INPUTFS_TOUCH_UP`.
    The dispatcher at `inputfs.c:2849-2902` is firing
    correctly: each Report ID 7 packet decodes into a
    touch event.

  - **No pointer.motion events from dev=2.** During the
    same trackpad-only motion window, no
    `dev=2 pointer.motion` lines appear on the event
    ring. By contrast, `dev=0` (the ELECOM external
    mouse) produces `pointer.motion x=N y=M dx=N dy=M
    buttons=0x0 session=...` correctly - confirming
    the publish path is alive for HUG_MOUSE devices.

  - **State region pointer slot unchanged.** Two
    consecutive `inputdump state | head -8` snapshots
    flanking a 5-second trackpad motion window show
    identical output: `last_seq: 234 pointer: x=1036
    y=989`. The trackpad's TOUCH_MOVE events advanced
    the event-ring sequence but did not advance the
    state-region sequence (which only increments when
    the pointer slot is touched).

  - **Cursor sprite does not move under trackpad.** The
    direct visual: external mouse moves the cursor
    fine; trackpad does not.

#### Diagnosis

The touch dispatcher emits `INPUTFS_TOUCH_DOWN`,
`INPUTFS_TOUCH_MOVE`, `INPUTFS_TOUCH_UP` to the event
ring via `inputfs_events_publish`, with payloads
containing the contact's pixel coordinates and session
id. It does NOT also synthesize a `pointer.motion`
event for the cursor-control case, and it does NOT
update the state region's pointer slot. Single-finger
touch - the canonical "touchpad as cursor" interaction
- therefore reaches userland touch consumers
(libsemainput's recogniser, future gesture tools) but
not the cursor pump (semadrawd) which reads only the
state region's pointer slot.

The fix is in the touch dispatcher at
`inputfs/sys/dev/inputfs/inputfs.c:2849-2902`. The
shape:

  1. Maintain an `active_contact_count` field on
     `struct inputfs_softc` (or compute it from the
     `sc_touch_contacts[]` array when needed).
  2. After updating `sc_touch_contacts[cid]` in either
     the touch_down, touch_move, or touch_up branch,
     count active contacts.
  3. **When `active_contact_count == 1`**: this is the
     single-finger-touch case. Synthesize pointer
     motion: compute deltas from the previous primary
     contact's last_x/last_y to the current contact's
     px/py; call `inputfs_state_update_pointer(dx, dy,
     synthetic_buttons, &actual_dx, &actual_dy)` under
     the seqlock; emit a `pointer.motion` event with
     payload `(new_x, new_y, actual_dx, actual_dy,
     synthetic_buttons, session)`. The synthetic
     buttons mask comes from the touchpad's
     button-pad state (the `button=yes` field in the
     digitizer locations).
  4. **When `active_contact_count == 0`**: contact
     lifted. No pointer motion to synthesise; emit
     touch_up only (current behaviour).
  5. **When `active_contact_count > 1`**: multi-finger
     gesture in progress. Suppress pointer motion;
     libsemainput's gesture recogniser owns these
     interactions at the userland layer. (Current
     behaviour is fine for this case - touch events
     keep flowing without polluting cursor state.)
  6. **Transition handling.** When count goes
     1 → 2, a second finger has touched down; cursor
     should freeze in place rather than jump to the
     new finger's coordinates. When count goes
     2 → 1, the user lifted one finger; cursor should
     resume tracking the remaining finger from its
     CURRENT position (no jump). The implementation
     uses a "primary contact" pointer that points at
     the first active contact; on transition, the
     primary contact is re-resolved before the next
     pointer.motion synthesis.

#### Why this didn't bite earlier

ADR 0018 §3 documents the touchpad-mode flip and the
HUP_DIGITIZERS parser thoroughly. Section 4 describes
the per-contact event-emission model (touch_down /
touch_move / touch_up). Section 4 does NOT cover
"touchpad as cursor" - the cursor-motion synthesis
path was implicitly assumed to live downstream
(originally semainputd; later libsemainput). With
semainputd retired (AD-2a) and libsemainput consumed
only by semadrawd's gesture path (not its pointer
pump), there is no surface left that synthesizes
pointer motion from touch events, and the kernel
needs to do it directly to keep the cursor responsive.

This is a design completion, not a bug regression -
the kernel never had this code, and the userland
consumer that used to do it is gone. The fix lives in
the kernel because that's where the event-time
information is freshest and the synthesis is cheapest.

#### Alternative considered: do the synthesis in semadrawd

Have semadrawd's cursor pump read both the state
region's pointer slot AND the event ring's recent
touch events, integrating touch_move deltas into a
"derived pointer" that overrides the state region's
pointer when present. The kernel would not need to
change.

Rejected because:

  - Two paths to the cursor's authoritative position
    (state region for mouse; derived from event ring
    for touchpad) is more state to manage in the
    pump and harder to reason about.
  - Latency: the kernel writes the state region every
    HID interrupt; userland would have to drain the
    event ring and integrate deltas at compositor
    frame rate, adding ~16ms of cursor lag versus
    the kernel doing it in the interrupt handler.
  - Multiple state-region readers: `inputdump state`
    becomes lying about cursor position when the
    cursor is touchpad-driven; userland tools that
    read state for cursor coordinates (current and
    future) need a special-case path.
  - The state region is the documented authoritative
    source per ADR 0007; making the event ring
    co-authoritative weakens that guarantee.

The kernel-side synthesis is the right place. Touch
consumers (libsemainput) keep getting their
TOUCH_DOWN/MOVE/UP events unchanged; cursor consumers
(semadrawd's pump) keep reading the state region as
they always have. Both surfaces remain
single-authoritative.

#### Closure criteria

  1. `inputdump events` during single-finger trackpad
     motion shows interleaved `dev=2 touch.type2`
     and `dev=2 pointer.motion` events.
  2. `inputdump state` shows the pointer slot
     advancing during trackpad motion (last_seq and
     pointer x/y both updating).
  3. The cursor sprite follows single-finger touchpad
     motion on the framebuffer.
  4. Two-finger gestures (e.g., pinch, scroll) do
     NOT move the cursor; only `touch.type*` events
     fire.
  5. The mouse-driven cursor still works (no
     regression in the existing pointer.motion
     publish path).
  6. WITNESS-clean (no lock-order violations
     introduced by the touch-side state-region
     update).
  7. No drawfs counter regression
     (vmobj_install_lost, inbuf_grow_race_lost,
     frame_extract_race_lost remain 0; semadrawd
     uptime climbs steadily).

#### Estimate

**Small-Medium.** The change touches one function
(`inputfs.c:2849-2902` plus a new "primary contact"
field on softc), adds a counter, and synthesizes a
pointer.motion event using the existing
`inputfs_events_publish` and
`inputfs_state_update_pointer` helpers. No new
data structures, no ADR amendment needed (the design
is consistent with ADR 0018 §3 and ADR 0007). The
test surface is the existing fuzz harness (HUP_DIGITIZERS
descriptors) plus bench verification. ~150 lines of
kernel C; ~50 lines of test scaffolding. One bench
reboot for verification.

---

*Pre-supersede entry below; preserved for the
investigation history and the ad22-diagnose.sh
diagnostic record. The 2026-05-07 framing is
superseded by the 2026-05-08 narrowed-scope
diagnosis above.*
