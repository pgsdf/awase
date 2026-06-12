# AD-21 verification: cursor surface end-to-end on bare metal

Acceptance test for AD-21 (mouse cursor sprite rendering) on
`pgsd-bare-metal-test-machine`. The AD-21 closeout in `BACKLOG.md`
flips only after this protocol passes end-to-end. AD-21 closure
also closes the long-standing AD-1 D.3 edge-clamp verification
follow-up that originally surfaced the need for a visible cursor
(see Phase 5 below).

The verification is primarily visual rather than scripted: most
of what must be observed is "the cursor is on screen and behaves
correctly," which no shell script can decide on its own. A small
amount of log scraping is automated to catch the obvious failure
shapes.

## Recipe

The short version, for someone who already knows the project.

**On a bench with the s6 supervisor configured (the production
shape).** Run install.sh; it stops the supervised daemon, atomically
replaces the binary at `/usr/local/bin/semadrawd`, and restarts the
service. After it returns, the supervised daemon is the just-built
code:

```
cd ~/Development/UTF
sudo ./install.sh

# confirm the deployed binary matches your build
md5sum /usr/local/bin/semadrawd \
       ~/Development/UTF/semadraw/zig-out/bin/semadrawd
# the two MD5s must be identical; if not, the install didn't take

# the supervised daemon's log is captured by s6-log
sudo tail -f /var/log/utf/semadrawd/current
```

Then drive the cursor with the trackpad / mouse and walk the
manual checks below.

**On a bench without supervision** (no s6, or the supervisor is
deliberately disabled for development). Build and run the daemon
in the foreground; this is the only path that works pre-AD-20:

```
cd ~/Development/UTF/semadraw
zig build                                 # produces zig-out/bin/semadrawd
sudo killall semadrawd 2>/dev/null         # nothing to fight if no supervisor
sudo zig-out/bin/semadrawd --backend drawfs -r 3840x2160 \
    2>&1 | sudo tee /tmp/semadrawd-ad21.log
```

The `--backend drawfs` and `-r WxH` flags are not optional for
bare-metal verification. The daemon's defaults
(`backend_type = .software`, `width = 1920`, `height = 1080`) put
the renderer on a backend that doesn't reach the EFI framebuffer
and report dimensions smaller than the actual display, both of
which break the verification in non-obvious ways. The supervised
service script passes the right flags; the foreground command
must too. Substitute the real native resolution from
`dmesg | grep efifb`.

If the manual checks pass and the log assertions in Phase 1
match, AD-21 is verified on this machine and `BACKLOG.md` can
flip the AD-21 entry to `[x]` along with the AD-1 D.3 follow-up.

## Preconditions

The verification assumes the following are in place. Failure to
meet a precondition produces misleading downstream observations
("cursor doesn't appear" can mean any of: cursor surface not
created, drawfs framebuffer not attached, inputfs state region
empty). Phase 0 below makes each one a separate check so the
failure is localised.

1. The PGSD-flavoured FreeBSD kernel is running with `inputfs.ko`
   loaded and `/var/run/sema/input/state` valid (see
   `inputfs/docs/C_VERIFICATION.md` Phase 0–6 for the inputfs-side
   acceptance gate).

2. drawfs is loaded and has attached a framebuffer device. The
   compositor's `initOutput` path uses drawfs as the rendering
   backend; without it, the cursor surface has nowhere to render.

3. semadrawd has been built from a tree that contains AD-21
   sub-items 1, 1.5, 2, 3, 4, 5, 6, 7, and 8. Quick sanity:

   ```
   cd ~/Development/UTF/semadraw
   git log --oneline -20 | grep -E 'AD-21|cursor'
   ```

   should show the eight sub-item commits.

4. semadraw-term is built and ready to run as a client. The
   verification needs at least one visible client surface so
   that (a) sub-item 7's focus model has something to validate
   against, and (b) the cursor passing over a non-cursor surface
   exercises the damage-propagation walk from sub-item 5. A
   blank framebuffer with only the cursor would pass Phases 1
   and 2 but skip the more interesting Phase 3.

5. The operator has determined whether the bench is running the
   AD-20 s6 supervision tree or not. The two scenarios use
   different "start the daemon" commands and read different log
   sources; mixing them produces confusing failures (the most
   common: a supervised stale daemon holds the IPC socket while
   the operator runs a foreground build, which then refuses to
   start with `error.AlreadyRunning`). To check:

   ```
   pgrep -lf 's6-supervise.*semadrawd'
   ls /var/service/utf/semadrawd 2>/dev/null
   pgrep -x semadrawd
   ```

   If the first two return matches, the bench is supervised; use
   the install.sh path in the Recipe section above. If they
   return nothing but `pgrep -x semadrawd` shows a daemon, that
   daemon is a stray foreground run; kill it before proceeding.
   If all three are empty, no daemon is running and either path
   will work.

## Phase 0: cleanliness

**Action.** Before anything else, decide which scenario applies
and act accordingly.

If the bench is supervised (precondition 5 returned matches):

```
ls /var/run/sema/input/state
kldstat | grep -E 'inputfs|drawfs'
sudo ./install.sh             # rebuilds, stops, installs, restarts
md5sum /usr/local/bin/semadrawd \
       ~/Development/UTF/semadraw/zig-out/bin/semadrawd
# the two must match; if not, the supervisor refused to take
# down the running daemon (rare), or install.sh failed silently
```

If the bench is not supervised:

```
sudo killall semadrawd 2>/dev/null
ls /var/run/sema/input/state
kldstat | grep -E 'inputfs|drawfs'
```

**Expect.** No semadrawd running (or the supervised one running
the just-built binary). The inputfs state file present. Both
`inputfs.ko` and `drawfs.ko` loaded.

**Acceptance.** All preconditions visibly met. If inputfs or
drawfs is not loaded, abort and load them first.

**Common failure: `Text file busy` from a manual `cp`.** If you
manually `cp ~/.../semadrawd /usr/local/bin/semadrawd` while the
supervised daemon is running, FreeBSD returns ETXTBSY because
the file is being executed. Use install.sh; it handles the stop
/ install / restart cycle correctly. Direct `cp` only works if
no daemon is using the file.

**Common failure: stale binary survives an apparent install.**
If the md5sum check in the supervised path shows a mismatch
between `/usr/local/bin/semadrawd` and the dev tree's
`zig-out/bin/semadrawd`, the supervised daemon is running stale
code. install.sh stops the rc.d service then issues an atomic
mv; if the supervisor never received the stop signal (rc.d
shim broken, supervisor not actually under rc.d, etc.) the mv
proceeded but the running daemon kept executing the unlinked
inode. The rc.d service path (`/usr/local/etc/rc.d/semadraw`)
must be wired to s6-svc against the right service directory;
see install.sh's rc.d shim block for what's expected.

## Phase 1: semadrawd starts cleanly with cursor surface created

**Action (supervised path).** install.sh from Phase 0 has already
restarted the supervised daemon. Tail the s6-managed log:

```
sudo tail -f /var/log/utf/semadrawd/current
```

**Action (foreground path).** Start semadrawd in the foreground
with the explicit drawfs backend and native resolution:

```
cd ~/Development/UTF/semadraw
sudo zig-out/bin/semadrawd --backend drawfs -r 3840x2160 \
    2>&1 | sudo tee /tmp/semadrawd-ad21.log
```

Substitute the real native resolution from `dmesg | grep efifb`.

**Expect.** Three log lines, in approximately this order:

- `info: semadrawd starting on /var/run/semadraw.sock`
- `info: cursor surface created: id=N z=1000000 hotspot=(0,0) size=24x24`
  (where N is whatever surface id the registry assigned; usually 1)
- the compositor's normal start banners, then a quiet steady state

In the supervised path the log lines come through s6-log so
they're prefixed with timestamps; in the foreground path they
come through stderr without timestamps. The content is the same.

**Acceptance.** The "cursor surface created" line appears exactly
once, with `z=1000000` matching `Z_ORDER_CURSOR` from sub-item 2
and `hotspot=(0,0) size=24x24` matching the default sprite from
sub-item 4. No `cursor surface init failed` warning.

If the sprite rendering Phase below fails, return here first and
re-confirm: a missing "cursor surface created" line is the
load-bearing root cause; everything downstream is meaningless
without it.

**Worth knowing about the log path.** semadrawd's log writes use
`pwritev`, which returns ESPIPE ("Illegal seek") when stdout is
a pipe. The first write succeeds; subsequent writes can be
mangled or lost. The `2>&1 | sudo tee /tmp/...` pattern is
therefore an unreliable foreground log source: lines arrive
out of order, partially truncated, or are silently dropped.
The supervised path (s6-log writes to a regular file) is
unaffected. For the foreground path on a bench that needs
trustworthy logs, use a redirect inside an elevated shell:

```
sudo sh -c 'zig-out/bin/semadrawd --backend drawfs -r 3840x2160 \
    > /tmp/semadrawd-ad21.log 2>&1 &'
```

This sidesteps the pipe entirely. The pwritev/ESPIPE issue is
a pre-existing daemon bug, tracked as a follow-up; it's not
AD-21 work.

## Phase 2: cursor follows pointer

**Action.** Move the trackpad or mouse. Sweep the pointer in a
broad circle covering most of the framebuffer.

**Expect.**

- A 24×24 white-and-black arrow is visible, with its tip at
  the pointer's framebuffer position (hotspot is (0, 0) so the
  tip equals the pointer position).
- The arrow follows the pointer without a perceptible lag at
  composite-rate motion (60 Hz is target).
- When the pointer is stationary, the arrow is stationary.
  No flicker, no jitter.
- The semadrawd log shows no warnings during quiescence
  ("cursor pump: …" warnings during normal operation indicate
  a failure on the pump's hot path).

**Acceptance.** The arrow tracks the pointer in real time across
the full framebuffer. Stationary state is quiet in the log.

If the cursor appears at (0, 0) and never moves: the position
pump is failing to read the inputfs state region. Check that
`/var/run/sema/input/state` is valid (see inputfs C_VERIFICATION
Phase 3) and re-check Phase 0.

If the cursor moves but with visible lag: investigate the
compositor frame rate; the cursor uses the same composite cycle
as everything else, so any frame-rate problem is a compositor
issue rather than an AD-21 issue. Out of scope here.

## Phase 3: underlying surfaces redraw correctly under cursor sweep

**Action.** With semadrawd running from Phase 1, open semadraw-term
in another terminal and let it occupy its full-screen surface.
Type a few lines of recognisable text into the term so it has
visible content. Sweep the cursor across the term content,
including:

- horizontal sweep across a single line of text
- vertical sweep across a column of characters
- diagonal sweep across the screen
- circle sweep within a small region (~100 px radius)

**Expect.**

- Text under the cursor is occluded by the arrow while the
  cursor is over it.
- Text is fully restored as soon as the cursor moves past
  (no stale arrow pixels left behind).
- The rest of the term (areas the cursor never visited)
  shows no flicker, no redraws, no visible artefacts.
- The cursor itself remains crisp throughout.

**Acceptance.** Text restoration is clean. No trailing pixels.
No artefacts on uncovered regions of the term.

If stale cursor pixels remain after a sweep: the damage
propagation walk in `pumpCursorPosition` is failing to mark
the underlying surface as damaged for the old cursor rect. Check
`comp.damageRegion` warnings in the semadrawd log. Most likely
cause is a `getCompositionOrder` failure; less likely is a
miscalculated surface-local rect (corner case at framebuffer
edge).

If the entire term re-renders on every cursor move: damage
propagation is over-eager, marking the entire underlying surface
rather than just the cursor's old/new rects. Check that the
walk is using `damageRegion` and not `damageAll` or
`damageSurface`. (Wasteful but not failing; downgrade to a
warn-and-continue rather than a fail if visually nothing else
is wrong.)

## Phase 4: input routing is not broken (regression check)

**Action.** With the cursor visible (semadrawd running, cursor
following pointer), test that input still reaches semadraw-term:

- Type a recognisable phrase into the term ("hello cursor").
- Click anywhere in the term and observe whether the click is
  delivered (e.g. semadraw-term's own debug logging shows the
  click).

**Expect.**

- Keystrokes appear in the term as typed.
- Mouse clicks reach the term (whether or not the term acts on
  them depends on the term, but the daemon-side log should show
  the click in `forwardMouseEvents`).

**Acceptance.** Input routing works as before AD-21. The cursor
surface does not steal input.

If input is not reaching the term: the `getTopVisibleSurface`
fix from sub-item 7's regression-fix commit (the one that
predates the SET_CURSOR opcode work) is missing or wrong.
Confirm that `surface_registry.zig:getTopVisibleSurface` walks
back-to-front and skips daemon-owned surfaces; without that
fix, the cursor surface is "the topmost" and every input event
gets routed to its non-existent client.

## Phase 5: edge clamp (closes AD-1 D.3 follow-up)

**Action.** With the cursor visible:

- Drive the pointer slowly toward the **top edge** of the
  framebuffer; keep pushing past the edge for several seconds
  (the trackpad's reported dy continues; inputfs's clamp must
  not let the pointer escape).
- Pull the pointer back from the edge.
- Repeat for each of the **bottom, left, right** edges.
- Drive the pointer into each of the four **corners** (top-left,
  top-right, bottom-left, bottom-right) by simultaneously pushing
  in two axes against the corner.

**Expect.**

- The cursor's visible position clamps at the edge; the arrow's
  tip never disappears off the framebuffer.
- When the pointer is pulled back from an edge, the cursor moves
  inward immediately, with no "stale pixels at the edge" trail.
- In each corner, the cursor sits exactly at the corner pixel
  (or one pixel away if the cursor sprite extends past the
  pointer; the tip pixel should match the framebuffer's corner
  pixel).
- Pulling out of a corner: same as pulling away from a single
  edge, no trail.

**Acceptance.** All four edges and four corners clamp correctly,
no trail.

This phase is the verification that originally blocked AD-1 D.3:
the inputfs payload-dx/dy fix in commit 344a7f5 is correct iff
the cursor's edge behaviour here is clean. Failure here means
either:

- The clamp itself is wrong (inputfs side; out of AD-21 scope
  but would re-open the AD-1 D.3 work).
- The clamp is right but the cursor's position pump is reading
  pre-clamp values (semadrawd side; check that
  `pointerSnapshot` reads from the inputfs state region, which
  is post-clamp by construction).

## Phase 6: visibility toggle for the no-geometry case (optional)

**Status.** Optional. The production stack always has
`inputfs_geom_known == 1` after drawfs attaches, so this branch
of the visibility logic is not exercised in normal operation.
Reproduce it by deliberately bringing semadrawd up in a state
where inputfs has not yet seen drawfs.

**Action.**

```
sudo kldunload drawfs    # forces inputfs to lose geometry
sudo zig-out/bin/semadrawd
```

then move the pointer beyond what the framebuffer dimensions
would normally allow, and observe whether the cursor disappears
when the pointer reads as out-of-range.

**Expect.** When the pointer's reported coordinates fall outside
`[0, fb_width) × [0, fb_height)`, the cursor is invisible. When
the pointer comes back into range, the cursor reappears at the
new in-range position (no stale pixels at the previous out-of-
range position because there were no pixels there to begin with).

**Acceptance.** Toggle behaviour matches the four state
transitions documented in `pumpCursorPosition`'s docstring and
sub-item 8's commit message.

Skip this phase if drawfs cannot be unloaded on the test bench
without disrupting other ongoing work; it is informational.

## Phase 7: SET_CURSOR exercised by a test client (optional)

**Status.** Optional. No test client currently exists in the
tree that sends the SET_CURSOR opcode. Writing one is orthogonal
to verifying the rest of the chain and may ship as a follow-up.

**If a test client is available.** Run it while semadraw-term has
focus; observe that the cursor sprite changes to whatever the
test client sent. Verify error paths (oversized sprite rejected
with `validation_failed`; wrong format rejected with
`invalid_message`; non-focused client rejected with
`permission_denied`).

**Acceptance.** Sprite changes on success; error replies match
the validation order documented in sub-item 7's handler
commit message.

Skip this phase if no test client is available. The handler's
straight-line validation logic is covered by code review;
runtime exercise can defer to whenever a client is built.

## Phase 8: cursor persists during underlying-surface idle repaint

**Status.** Required. Added 2026-05-07 after sub-item 10 surfaced
a verification gap missed by the original Phase 0–5 chain: the
cursor surface visually disappeared during cursor idle while
semadraw-term repainted itself periodically. The pre-sub-item-10
compositor's render loop skipped the cursor surface (no damage
during idle) while the term re-rendered, and the term's render
overwrote the cursor's pixels.

**Action.** With semadrawd running and semadraw-term as a client
(the same setup as Phase 3), move the cursor over a region of
the term's surface. Stop moving the trackpad / mouse and let the
cursor sit stationary for **at least 10 seconds**. Watch the
cursor sprite during this window.

**Expect.** The cursor remains continuously visible for the full
window. Underlying term content may re-render around / under the
cursor (cursor-blink in the term's own internal cursor, terminal
output if any, time-based repaints), but the cursor sprite
persists at its position throughout. No flicker, no disappearance,
no partial sprite.

**Acceptance.** Cursor stays visible across the entire idle
window. If the term is stationary too (no activity), the test is
weaker — the term may not be re-rendering at all, in which case
sub-item 10's propagation never gets exercised. To strengthen
the test: type into the term during the idle window so the term
emits damage and re-renders while the cursor is stationary. The
cursor must remain visible.

If the cursor visibly disappears during this window: sub-item
10's upper-z damage propagation is not firing or not propagating
correctly. Check the compositor log for upper-z propagation
failures (the warning string is `"upper-z damage propagation
failed for surface N"`). Most likely cause: the cursor surface's
bounds are zero or empty (logical_width / logical_height
defaulted to 0 somehow), so `Rect.intersects` returns false and
the propagation skips. Check the cursor surface state via the
compositor's debug logging.

If the cursor flickers but doesn't fully disappear: composite
cycles are alternating between "term re-renders, cursor doesn't"
(flicker off) and "cursor re-renders" (flicker on). Sub-item 10's
propagation is firing inconsistently, possibly racing with damage
clearing in `clearAll()`. Investigate the order of damage
clearing and propagation in the composite cycle.

## Closeout

If Phases 0–5 and 8 pass (and Phases 6–7 either pass or are
skipped deliberately), AD-21 is verified on this machine. Commit
a closeout marker:

```
git commit -m "docs: AD-21 verified end-to-end on pgsd-bare-metal-test-machine

Closes AD-21 in BACKLOG.md. Closes the AD-1 D.3 edge-clamp
verification follow-up (Phase 5). Phase 8 (cursor persists
during underlying-surface idle repaint) added 2026-05-07 to
catch the upper-z damage propagation case that sub-item 10
addresses. The reset-cursor-on-focus-loss refinement noted in
ADR 0005 §5 is opened as its own backlog entry; it is small,
ergonomic, and not gating anything."
```

then flip the AD-21 entry in `BACKLOG.md` from `[ ]` to `[x]`,
and add a similar tick to the AD-1 D.3 follow-up note in the
AD-1 entry.

## Troubleshooting matrix

If a phase fails, the table below maps the failure to the most
likely cause.

### Phase 0 (deployment / cleanliness)

- "Text file busy" from `cp /usr/local/bin/semadrawd`: the
  supervised daemon is holding the file. Use `sudo ./install.sh`
  instead of manual `cp`; install.sh stops the service before
  the install. Direct `cp` only works if no daemon is using the
  file (verify with `pgrep -x semadrawd`).
- md5sum mismatch between `/usr/local/bin/semadrawd` and the
  dev tree's `zig-out/bin/semadrawd` after install.sh ran: the
  supervised daemon kept running its old binary. install.sh's
  rc.d shim couldn't reach the supervisor. Either the rc.d
  service file at `/usr/local/etc/rc.d/semadraw` is missing or
  malformed, or the s6 service directory at
  `/var/service/utf/semadrawd` doesn't exist. Falling back:
  manually take the supervisor down via `s6-svc -d
  /var/service/utf/semadrawd`, then re-run install.sh.
- `error.AlreadyRunning` from a foreground daemon launch: a
  supervised daemon is already holding `/var/run/semadraw.sock`.
  The diagnostic on the daemon's stderr points to `sockstat -u
  | grep semadraw`. If the listening daemon is the supervised
  one, switch to the supervised path (Recipe section above);
  the foreground path is for unsupervised benches only.
- `service semadraw status: not under supervision` while
  `s6-supervise` is running: the rc.d shim and s6 disagree
  about whether the service is active. install.sh's rc.d
  shim writes a service file that translates `service
  semadraw stop/start` into `s6-svc -d/-u`; if it's missing
  or a hand-edited replacement, `service status` will return
  the unsupervised reading. Re-run install.sh to restore the
  rc.d shim.

### Phase 1 (cursor surface init)

- "no cursor surface created log line": `initCursorSurface`
  failed during `initCompositor`; the log will carry a `cursor
  surface init failed: <error>` warning. Most likely causes:
  asset embed path wrong (`@embedFile` resolution failed),
  `attachInlineBuffer` allocator failure (extreme memory
  pressure, unlikely on the bench).
- "cursor surface created with z != 1000000": sub-item 2's
  Z_ORDER_CURSOR constant has been changed without updating
  the init code. Re-grep `Z_ORDER_CURSOR` across the tree to
  find the divergence.

### Phase 2 (cursor follows pointer)

- "cursor stuck at (0, 0)": position pump is not reading from
  inputfs. `/var/run/sema/input/state` may be missing or
  invalid. Run `sudo zig-out/bin/inputdump state` and confirm
  the pointer fields update as the trackpad is moved.
- "cursor jitters": likely a coordinate-rounding issue at the
  pump. The pump uses `@intFromFloat` truncation; for negative
  fractional positions this floors-toward-zero rather than
  toward-negative-infinity, which can produce a 1-pixel jitter
  near (0, 0). Acceptable; not a bug for the production case
  where positions are non-negative.
- "cursor follows pointer with > 1 frame lag": composite-rate
  problem rather than an AD-21 problem; the pump sets damage
  in the same loop iteration as composite, so a fresh
  composite picks up the new cursor immediately.

### Phase 3 (underlying redraw)

- "stale cursor pixels left behind": damage propagation walk
  in `pumpCursorPosition` is failing. Check the semadrawd log
  for `cursor pump: damageRegion(surface N) failed` warnings.
  If absent, the walk is succeeding but the compositor is not
  re-rendering on the marked damage; re-check the compositor's
  damage-tracker integration (out of AD-21 scope).
- "entire term re-renders on every cursor move": damage walk
  is over-eager. Verify it uses `damageRegion(rect)` not
  `damageSurface(id)` for underlying surfaces.

### Phase 4 (input routing regression)

- "no key/mouse events reach the term": `getTopVisibleSurface`
  is returning the cursor surface (owner = `CLIENT_ID_DAEMON`)
  rather than the topmost client surface. Confirm the regression
  fix from sub-item 7 is in tree by grepping for `s.owner ==
  protocol.CLIENT_ID_DAEMON` in `surface_registry.zig`.

### Phase 5 (edge clamp)

- "cursor leaves the framebuffer": inputfs is not clamping the
  pointer, or AD-1 D.3 was reverted. Check
  `inputfs_pointer_publish` for the post-clamp dx/dy fix.
- "stale pixels at edge after pulling away": damage propagation
  for the old cursor rect at the edge is being lost, possibly
  because the rect computation produces an empty/invalid rect
  at the boundary. Check the cursor old-rect computation in
  `pumpCursorPosition`.

### Phase 6 (no-geometry visibility)

- "cursor stays visible at out-of-range positions": the
  visibility test in `pumpCursorPosition` is using cursor surface
  position rather than raw pointer coords. Per ADR §7 the test
  is on `ps.x / ps.y`, not `new_x / new_y`.

### Phase 7 (SET_CURSOR)

- "all SET_CURSOR requests rejected with permission_denied":
  the requester does not own the focused surface. Either fix
  the test client to take focus first, or the focus model has
  drifted since sub-item 7. Recheck `getTopVisibleSurface` and
  `isOwner`.
- "valid SET_CURSOR returns error": check the validation order
  in `handleSetCursor`; the error code identifies which step
  failed.

### Phase 8 (cursor persists during idle)

- "cursor disappears during stationary state over an active
  semadraw-term": sub-item 10's upper-z damage propagation isn't
  firing. Check the daemon log for `upper-z damage propagation
  failed for surface N` warnings; if absent, the propagation may
  be silently skipping due to empty bounds (cursor surface's
  logical_width / logical_height defaulted to 0). Inspect cursor
  surface state.
- "cursor flickers during stationary state": propagation is
  inconsistent. Likely a damage-clearing race — `clearAll()` may
  be wiping propagated damage before the render loop reads it.
  Confirm the propagation pass runs after `beginFrame()` /
  region-damage clearing and before the surface render loop.
- "cursor disappears even with no underlying surface activity":
  not a sub-item-10 issue. Check that the daemon isn't doing
  forced full-repaints from another path that doesn't include
  the cursor (e.g. an output-config-change handler that calls
  `markFullRepaint()` periodically).
