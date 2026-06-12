# AD-2a Phase 2.5: bare-metal verification runbook

This runbook is the verification checklist for AD-2a Phase 2.4
(gesture event wire and recogniser-as-service). It uses the
`gesture_inspect` diagnostic tool to observe what arrives at a
client when a human exercises the canonical input scenarios on
real hardware.

The success condition for each scenario is a specific output line
or sequence of lines from `gesture_inspect`. An operator can step
through this document, perform each input, and grep the
`gesture_inspect` output against the expected pattern.

Phase 2.4 closes when this runbook passes end-to-end on
`pgsd-bare-metal-test-machine`.

## Setup

UTF uses s6 supervision under AD-20, with thin rc.d wrappers
that translate `service` commands to `s6-svc` calls against
the supervision tree at `/var/service/utf/`. The
operator-facing service name is `semadraw` (not `semadrawd` —
the trailing `d` is on the binary, not the rc.d wrapper). See
`s6/README.md` for the full supervision model.

**Run this verification over SSH from another machine, not
from the bench's local console.** On a PGSD kernel there is
no vt(4) fallback console (AD-39 compiled the in-tree console
drivers out), so inputfs is the only local input path. The
build and install drive enough load that the local input
path can become unresponsive for the duration - the terminal
stops accepting keystrokes including Ctrl-C - with nothing to
fall back to. This is not an install.sh defect (it
deliberately does not unload inputfs.ko; the build itself
completes fine) and it is not a deadlock; it is local input
starvation on a console-less kernel. Observed 2026-05-17: a
local-console `sudo ./install.sh` appeared to hang at the
inputfs userland build with dead input; the same install run
over SSH completed cleanly. SSH bypasses inputfs entirely and
is unaffected. Keep an SSH session to the bench open
throughout; it is also the recovery path if anything wedges
(`pkill -f install.sh; pkill -9 zig`, then drive the rest
over SSH). Driving the actual click/gesture scenarios still
requires physical input at the machine, but all build,
install, service-control, and `gesture_inspect`-watching
steps should be done in the SSH session.

There are two distinct mechanisms here, not one. The
paragraph above is load-related input starvation on the
local console (intermittent, depends on build load). The
second is deterministic and unconditional: **never run
install.sh from inside a semadraw-term session.**
install.sh's pre-install teardown stops semadrawd
(`stop_service_if_running semadraw semadrawd`, with a
SIGKILL fallback after a 5s timeout). semadraw-term is a
*client* of semadrawd; when semadrawd dies the compositor is
gone and the semadraw-term session collapses, taking the
shell running install.sh with it. The script dies after the
daemon-stop step but before the post-install restart block,
leaving a half-completed install and no running daemons (the
restart block never executes because its own process tree
was killed). This is not a defect to fix in install.sh - a
process cannot reliably tear down and rebuild the session it
is running in - it is an ordering constraint: install.sh
must be run from a session that does not depend on
semadrawd. An SSH shell qualifies (it is not a child of
semadrawd and survives the stop). A semadraw-term session
never does, and the failure is 100%, not load-dependent.
Observed 2026-05-17: `sudo sh install.sh` from a
semadraw-term session fails every attempt; the same command
over SSH succeeds.

### One-time installation

Build in Debug mode for this verification. ReleaseSafe's
optimizer produced misleading panic messages and a multi-day
source-line misattribution during AD-14 (the diagnostic value
of accurate traces matters here because scenario 2 is the
first-ever on-bench gesture-line observation; if a scenario
deviates you want to debug the actual gesture path, not an
optimizer artifact). AD-14's underlying bug is fixed, and
INSTALL.md's position is that the daemons have no known
ReleaseSafe issues - but for a verification run, trustworthy
diagnostics across all components outweigh ReleaseSafe's
speed, which is irrelevant to a functional gesture-path check.

```sh
cd ~/Development/UTF
sudo zig build -Doptimize=Debug         # build all binaries (Debug:
                                        # accurate traces if a
                                        # scenario deviates; see AD-14)
sudo ./install.sh                       # install binaries, rc.d
                                        # wrappers, s6 service tree,
                                        # log directories
```

`install.sh` populates:

- `/usr/local/bin/semadrawd`, `gesture_inspect`, `semaaud`,
  `pgsd-sessiond`, `chrono_dump`, etc. (semainputd was
  retired under AD-2a Phase 3 step 2, 2026-05-08; it is no
  longer built or installed.)
- `/usr/local/etc/rc.d/{inputfs,utf-supervisor,semaaud,semadraw,pgsd-sessiond}` -
  thin wrappers, mode 555.
- `/var/service/utf/{semaaud,semadrawd,pgsd-sessiond}/` - the s6
  scan-directory tree with `run`, `finish`, and `log/run`
  scripts per service.
- `/var/log/utf/{semaaud,semadrawd,pgsd-sessiond}/` - log
  destinations for `s6-log`.

### One-time `/etc/rc.conf` enablement

Each service has an rc.conf gate that defaults to `NO`. Enable
the ones needed for verification (at minimum: inputfs,
utf-supervisor, semadraw):

```sh
sudo sysrc inputfs_enable=YES
sudo sysrc utf_supervisor_enable=YES
sudo sysrc semadraw_enable=YES
# Optional, only if exercising semaaud as well:
# sudo sysrc semaaud_enable=YES
```

### Bring up the supervision stack

The order matters: `inputfs` first (kld load, REQUIRE for the
rest), then `utf-supervisor` (brings up `s6-svscan` against
`/var/service/utf/`), then `semadraw`:

```sh
sudo service inputfs start
sudo service utf-supervisor start
sudo service semadraw start
```

`service semadraw start` translates to `s6-svc -uwu` against
`/var/service/utf/semadrawd`, which tells s6-supervise to
bring the service up and waits up to 5 seconds for it to be
ready. A clean start prints:

```
Starting semadraw via s6-svc -uwu (timeout 5s)...
```

Verify the daemon is actually running:

```sh
sudo service semadraw status
```

Expected output is `s6-svstat` format (start time, uptime,
ready state). If it reports "not under supervision," the
`utf-supervisor` step didn't complete; rerun it.

### Run the helper

In another terminal:

```sh
gesture_inspect
```

Expected first lines:

```
# gesture_inspect: connecting to semadrawd...
# connected; creating surface (400x300)...
# surface visible (id=N); waiting for events. Ctrl-C to quit.
```

`gesture_inspect`'s surface is registered as visible and becomes
the focused surface in the absence of any other client (Phase
2.4's routing per ADR 0017-rev2: gestures go to the focused
surface). Drive subsequent inputs while this terminal is
showing the helper's output.

If `# connecting to semadrawd...` is followed by an error rather
than `# connected`, the daemon is not running, the socket path is
not accessible to the helper's user, or the daemon's startup is
incomplete. None of the scenarios below will work until the
helper successfully connects.

## Scenario 1: single click

**Input:** click the left mouse button once anywhere on the
attached display.

**Expected output:** two lines, in order:

```
event_kind=mouse surface=N type=press button=left x=X y=Y modifiers=none
event_kind=mouse surface=N type=release button=left x=X y=Y modifiers=none
```

`X` and `Y` are the click coordinates; `surface=N` matches the
surface ID printed at startup. No `event_kind=gesture` line —
single click is not yet a gesture. This scenario verifies the
existing pre-Phase-2.4 mouse path still works after the daemon
gained the gesture-recogniser machinery.

**If this fails:** the regression is not in Phase 2.4; it's in
the mouse-event path that has been working since AD-2a Phase 1.
Stop and investigate before continuing — the rest of the runbook
assumes mouse routing is intact.

## Scenario 2: double click

**Input:** click the left mouse button twice in rapid succession
(< 500ms between clicks, < ~10px apart) on the attached display.

**Expected output:** four lines, in order:

```
event_kind=mouse surface=N type=press button=left x=X y=Y modifiers=none
event_kind=mouse surface=N type=release button=left x=X y=Y modifiers=none
event_kind=mouse surface=N type=press button=left x=X y=Y modifiers=none
event_kind=mouse surface=N type=release button=left x=X y=Y modifiers=none
event_kind=gesture type=n_click phase=update surface=N fingers=1 modifiers=none t_current_ns=T button=1 count=2 x=X y=Y
```

Five lines total: the four raw mouse events of the two clicks,
plus the gesture event the recogniser produced after seeing the
second press.

The gesture line's load-bearing fields:
- `type=n_click`: recogniser identified the multi-click sequence.
- `phase=update`: n_click is a discrete gesture with no lifecycle
  to express; daemon emits phase=update per the rev2 ADR.
- `fingers=1`: pointer-driven gesture, hardcoded to 1.
- `count=2`: the recogniser's tally of consecutive clicks.
- `button=1`: left button (MouseButtonId.left wider to u32).
- `t_current_ns=T`: chronofs ns timestamp of the second mouse
  press. Should be strictly greater than the timestamps of the
  preceding mouse events (visible if the daemon also emitted
  mouse_event lines with timestamps; gesture_inspect prints
  modifiers but not timestamps for mouse events — this is by
  design since the t comparison would be a separate manual
  step).

**If this fails:** the recogniser is not being fed from the
side-channel buffer (Phase 2.4.2 + 2.4.4), or the wire-format
emission is broken (Phase 2.4.5), or the side-channel buffer is
not seeing the input.Events at all (Phase 2.4.2's drawfs change
not delivering). Debug order:
1. Confirm the four mouse_event lines appear — if not, the
   problem is upstream of the recogniser.
2. Use `inputdump events` from inputfs to confirm raw events are
   reaching the kernel ring.
3. Confirm `gesture_recognizer.handleEvent` is being called
   (add a temporary log line in `forwardGestureEvents` or its
   feed loop in `semadrawd.zig`).

## Scenario 3: triple click

**Input:** click left three times rapidly (same window as
double-click).

**Expected output:** the four mouse events of clicks 1 and 2,
then `count=2` n_click, then the two mouse events of click 3,
then `count=3` n_click:

```
event_kind=mouse  ... (click 1 press)
event_kind=mouse  ... (click 1 release)
event_kind=mouse  ... (click 2 press)
event_kind=mouse  ... (click 2 release)
event_kind=gesture type=n_click phase=update fingers=1 ... count=2 ...
event_kind=mouse  ... (click 3 press)
event_kind=mouse  ... (click 3 release)
event_kind=gesture type=n_click phase=update fingers=1 ... count=3 ...
```

Verifies the recogniser's n_click counter increments correctly
across consecutive presses without the timer expiring between
them.

## Scenario 4: shift + double-click

**Input:** hold the SHIFT key, then double-click left.

**Expected output:** key events for shift down, then mouse +
gesture events with `modifiers=shift`, then a key event for
shift up:

```
event_kind=key surface=N key_code=SC pressed=1 modifiers=shift
event_kind=mouse surface=N type=press button=left ... modifiers=shift
event_kind=mouse surface=N type=release button=left ... modifiers=shift
event_kind=mouse surface=N type=press button=left ... modifiers=shift
event_kind=mouse surface=N type=release button=left ... modifiers=shift
event_kind=gesture type=n_click phase=update fingers=1 modifiers=shift ... count=2 ...
event_kind=key surface=N key_code=SC pressed=0 modifiers=none
```

Load-bearing: the gesture line's `modifiers=shift` field. This
verifies the daemon's `last_modifiers` tracking (Phase 2.4.5)
correctly propagates from the keyboard event to subsequent
gesture events. The same modifier string format is used for
both mouse and gesture events, so a single grep
(`grep modifiers=shift`) finds them all.

## Scenario 5: ctrl + double-click

**Input:** hold CTRL, double-click left.

**Expected output:** identical to Scenario 4 except every
`modifiers=shift` becomes `modifiers=ctrl`.

Verifies a different modifier bit position works correctly. The
bit ordering — bit 0 shift, bit 1 alt, bit 2 ctrl, bit 3 meta —
is shared between the backend's `last_modifiers: u8` and
`GestureFlags`'s packed-struct bit layout (the layouts agreed by
construction at the daemon level; this scenario confirms the
agreement persists through the wire).

## Scenario 6: shift + ctrl + double-click

**Input:** hold both SHIFT and CTRL, double-click left.

**Expected output:** all gesture and mouse lines show
`modifiers=shift+ctrl`. The order of the parts is fixed by
`formatModifiers` (shift, alt, ctrl, meta), so the exact string
"shift+ctrl" should appear regardless of which key was pressed
first.

Verifies multiple simultaneous modifier bits combine correctly
on the wire.

## Scenario 7 (multitouch only): pinch

**Skip if the test machine has no multitouch device.**

**Input:** with two fingers on the multitouch surface, perform a
pinch (move fingers apart or together).

**Expected output:** a sequence of pinch gesture events bracketed
by begin/update/end phases:

```
event_kind=gesture type=pinch_begin phase=begin fingers=2 ... delta=D scale=S
event_kind=gesture type=pinch phase=update fingers=2 ... delta=D scale=S direction=DIR
event_kind=gesture type=pinch phase=update fingers=2 ... delta=D scale=S direction=DIR
... (more update events as the pinch continues)
event_kind=gesture type=pinch_end phase=end fingers=2 ... payload=none
```

Load-bearing fields:
- `fingers=2` on every line: the recogniser's contact-count
  tracking (Phase 2.4 step 3) reports two active touches.
- `phase=begin / update / end`: the daemon's variant-to-phase
  mapping is correct (Phase 2.4.5).
- The `intent_hint` event may also appear early in the sequence,
  with `predicted=pinch` and an axis hint. Its absence is not a
  failure; presence confirms the recogniser's prediction layer.

## Scenario 8 (multitouch only): two-finger scroll

**Skip if no multitouch.**

**Input:** drag two fingers in the same direction across the
surface.

**Expected output:** scroll_begin → repeated two_finger_scroll →
scroll_end:

```
event_kind=gesture type=scroll_begin phase=begin fingers=2 ... payload=none
event_kind=gesture type=two_finger_scroll phase=update fingers=2 ... dx=DX dy=DY
... (repeated as fingers move)
event_kind=gesture type=scroll_end phase=end fingers=2 ... payload=none
```

## Scenario 9 (multitouch only): three-finger swipe

**Skip if no multitouch with three-finger support.**

**Input:** swipe three fingers in the same direction across the
surface.

**Expected output:** three_finger_swipe_begin → repeated
three_finger_swipe → three_finger_swipe_end with axis-locked
direction:

```
event_kind=gesture type=three_finger_swipe_begin phase=begin fingers=3 ... axis=horizontal confidence=C ...
event_kind=gesture type=three_finger_swipe phase=update fingers=3 ... axis=horizontal ...
... (repeated)
event_kind=gesture type=three_finger_swipe_end phase=end fingers=3 ... payload=none
```

## Pass criteria

Phase 2.4 is verified when:
1. Scenarios 1, 2, 3, 4, 5, 6 all produce the expected output.
2. If multitouch hardware is available: scenarios 7, 8, 9 also
   produce the expected output.
3. No spurious gesture events appear during scenarios 1
   (single click should NOT produce a gesture).
4. `gesture_inspect` runs cleanly without crashing for the
   duration of the verification (typical session: 5-10 minutes
   of input variety).

## Troubleshooting

**No mouse events at all:** the helper's surface is not the
focused surface, or the mouse path is broken upstream of the
daemon. Try clicking directly on the helper's drawn surface
(if it has visible pixels) to ensure focus, or close all other
clients before running the helper.

**Mouse events but no gesture events:** Phase 2.4 emission is
not happening. Verify the daemon binary is the post-Phase-2.4
build (commit 59cd5b7 "AD-2a Phase 2.4.5: forwardGestureEvents
body" or later). `semadrawd --version` if available, otherwise
`strings $(which semadrawd) | grep "forwardGestureEvents"`.

**Gesture events with wrong modifiers:** the daemon's
`last_modifiers` tracking is not in sync. Check whether the key
events that set modifiers reach the daemon at all (the helper
prints `event_kind=key` lines if `--filter all` is in effect).

**Wrong gesture types or phases:** the variant-to-phase mapping
in `forwardGestureEvents` may have drifted from the rev2 ADR.
Cross-reference `semadraw/src/daemon/semadrawd.zig`'s switch
statement against the ADR's phase derivation table.

## What this runbook does NOT verify

- **Latency.** The chronofs timestamps on each event allow a
  manual computation of input-to-client latency (subtract
  `t_current_ns` from a wall-clock measurement at observation),
  but this runbook does not enforce a latency budget. A separate
  performance pass would.
- **System-gesture interception.** The rev2 ADR deferred
  compositor-handled gestures (e.g. three-finger swipe for
  window switching) to Phase 2 of gesture-event work. All
  gestures route to the focused surface today; verifying
  interception is for a future phase.
- **Gesture-grab semantics.** Mid-gesture focus changes are
  deferred per rev2; this runbook does not exercise focus
  changes during an in-flight gesture.
- **Late-joiner semantics.** The push-delivery model means
  clients only see gestures that arrive after they connect; the
  rev2 addendum's t_begin removal makes this explicit. The
  runbook does not test connecting a second client mid-gesture.

These deferrals are recorded in the rev2 ADR's open questions
and are appropriate scope for a future Phase 2.6 or later if a
real client surfaces a need.
