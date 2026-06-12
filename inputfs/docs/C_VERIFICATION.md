# Stage C verification

Acceptance test for Stage C of the inputfs roadmap (publication of
the state region and event ring to userspace via vnode-backed sync).
The Stage C closeout bullet in `BACKLOG.md` is flipped only after
this protocol passes end-to-end on bare-metal FreeBSD.

The protocol has two parts:

1. The automated checks in `inputfs/test/c/c-verify.sh`. These
   exercise everything that does not require generating live input:
   module load and unload cleanliness, file presence and sizes,
   header magics and versions, device-inventory consistency between
   the state region and the device count, lifecycle event emission,
   sequence monotonicity, and reload sanity.

2. The manual mouse-and-button checklist below. These exercise the
   parts that require a human driving real hardware: pointer.motion
   event flow, button transition pairing, state-and-event
   consistency under live input.

Both parts must pass for Stage C to be considered verified on a
given machine.

## Recipe

The short version, for someone who already knows the project:

```
cd ~/Development/UTF/inputfs
zig build                                 # produces zig-out/bin/inputdump
cd sys/modules/inputfs && sudo make       # produces inputfs.ko
cd ../../../

sudo sh test/c/c-verify.sh                # automated checks

# then, for the manual checklist:
sudo zig-out/bin/inputdump watch
# move the mouse, click left and right, observe events.
# Ctrl-C to stop.
```

If `c-verify.sh` reports `0 failed` and the manual checklist below
matches what you observe, Stage C is verified on this machine.

## Preconditions

The verification assumes the following are in place. If the
preconditions are not met, the automated script fails fast in
phase 0 with a precondition error rather than producing
misleading downstream failures.

1. The PGSD-flavored FreeBSD kernel is running. The stock FreeBSD
   GENERIC kernel includes drivers (`hms`, `hkbd`, `hidmap`, etc.)
   that bind to the same HID devices inputfs binds to, and on a
   GENERIC kernel inputfs will lose the binding race and produce
   no attached devices. See README "System Requirements".

2. `/var/run` is mounted as tmpfs. inputfs creates files there in
   `MOD_LOAD`; a non-tmpfs `/var/run` works mechanically but
   pollutes persistent storage. See README "System Requirements"
   and `/etc/fstab` line:
   `tmpfs /var/run tmpfs rw,mode=755 0 0`.

3. The inputfs kernel module has been built: from
   `inputfs/sys/modules/inputfs/`, `make` returns 0 with no
   warnings beyond those already accepted in the `Wno-*` flags.

4. The `inputdump` userspace tool has been built: from
   `inputfs/`, `zig build` returns 0 and produces
   `zig-out/bin/inputdump`.

5. At least one HID device is attached and visible to the kernel
   (any USB or Bluetooth pointer or keyboard).

6. The C.4 commit has been applied (the throwaway
   `inputstate-check.zig` has been deleted). The script catches
   regressions where someone reintroduces it.

## Automated phases

`c-verify.sh` runs seven phases in order. Each phase prints a
`[c5 STEP]` banner and a sequence of `[c5 PASS]` / `[c5 FAIL]`
lines.

### Phase 0: preconditions

Confirms that the verification can run at all: root privileges,
inputdump binary present, throwaway absent, kernel module built,
`/var/run` is tmpfs. Any failure here exits with code 2 before
loading anything.

### Phase 1: module load

Unloads any pre-existing inputfs.ko, captures the pre-load
`M_INPUTFS` allocation as a baseline, then `kldload inputfs`
should succeed. Sleeps one second after load to let the kthread
open both publication files and run the initial sync.

What it proves: the module loads on this kernel, the kthread
starts, and the malloc baseline is captured for later leak
checking.

### Phase 2: publication region files

Checks that both `/var/run/sema/input/state` and
`/var/run/sema/input/events` exist with their spec-mandated sizes
(11328 and 65600 bytes), that their first four bytes spell `INST`
and `INVE` respectively, and that the version byte at offset 4
equals 1.

What it proves: the kernel writer is doing the right structural
thing. If a future patch changes the byte layout without updating
the spec or vice versa, this phase catches the divergence.

### Phase 3: state region content

Reads the state region via `inputdump state --json` and checks
that `device_count` is at least 1 (any number of attached devices
is acceptable; the bare-metal bench has 6 but the script does
not bake that in). Confirms that the four end-user inputdump
subcommands (`state`, `devices`, `events`, `watch`) at least run
without error.

What it proves: the kernel-side device publication works at least
once (state slots get populated on attach), the C.1 reader on the
userspace side parses what the kernel wrote, and inputdump's own
plumbing is intact.

### Phase 4: event ring content

Drains the event ring via `inputdump events --json` and verifies
two invariants:

- One `lifecycle.attach` event has been emitted for each
  populated device slot. (At module load time, the kernel emits
  exactly one attach event per device that successfully claims a
  slot; the count must match the state region's `device_count`.)

- Sequence numbers across all events in the ring are strictly
  monotonic increasing.

What it proves: the C.3 event publication path fires correctly
during attach, the per-slot seq protocol assigns sequence numbers
in the right order, and no events are dropped or duplicated
within the populated portion of the ring.

### Phase 5: liveness

Takes two state snapshots one second apart and checks that
`last_sequence` does not regress across them. A flat
`last_sequence` is informational rather than a failure: if no
input is being driven during this phase, the sequence will not
advance, and that is a property of the bench rather than a bug.
A regression would mean something is wrong (the seqlock is being
misused, or a snapshot is reading from a stale view).

What it proves: the seqlock advances correctly under real input,
or, if no input is occurring, that nothing is silently
regressing.

### Phase 6: module unload

Unloads inputfs and checks that `M_INPUTFS` returns to the
pre-load baseline captured in phase 1. The publication files may
or may not persist after unload (the module does not currently
delete them in `MOD_UNLOAD`; tmpfs keeps them around until the
next mount); their presence is informational.

What it proves: the unload path is clean, the kthread exits, and
the module returns its allocations.

### Phase 7: reload sanity

Re-runs phases 1, 2, and 4 after reloading the module, to verify
that the lifecycle is repeatable. A reload should produce a fresh
state region with `device_count` matching the new attach round,
fresh lifecycle events with monotonic seqs starting at 1, and
files at the expected sizes.

What it proves: the module survives load → unload → reload
without state leakage, and the per-load seq counter starts fresh
each time.

## Manual checklist: live input verification

After `c-verify.sh` reports zero failures, run the following
manual checks. They cannot be automated without HID injection,
which is out of scope for Stage C.

Open a terminal and start:

```
sudo zig-out/bin/inputdump watch
```

Then perform each step below and confirm what you observe.

### M.1: pointer motion produces events

**Action.** Move the mouse slowly in any direction.

**Expect.** A continuous stream of `pointer.motion` events scrolls
past, one per HID report, with sequence numbers strictly increasing
by 1, timestamps strictly increasing, `dx` and `dy` values
matching the direction of motion (negative for left/up, positive
for right/down on a standard mouse).

**Acceptance.** Pointer motion produces events at roughly the
mouse's report rate (typically 100–125 Hz for a USB mouse, hence
seqs increment as fast as you can move).

### M.2: state pointer position tracks events

**Expect.** Interleaved with the event stream, occasional
`[state] dev_count=N last_seq=K pointer=(X,Y) buttons=0x0` lines
appear when state changes are observed. The `(X, Y)` values
should approximately track the cumulative `dx`/`dy` from the
event stream.

**Acceptance.** The state region's pointer position is consistent
with the integral of the event stream's deltas. Exact match is
not required (the watch loop polls state at intervals and may
miss intermediate values), but a state pointer of (0, 0) after
significant mouse motion would indicate a bug.

### M.3: left button transitions

**Action.** Press and release the left mouse button once.

**Expect.** Two new events:

- `pointer.button_down ... button=0x1 buttons=0x1` on press
- `pointer.button_up ... button=0x1 buttons=0x0` on release

The two events should have distinct sequence numbers and
monotonically increasing timestamps. Buttons mask `0x1` is the
left button bit.

**Acceptance.** Both events appear, with the correct event types
in the correct order. The intervening `buttons` bitmap value goes
0x0 → 0x1 → 0x0. A `pointer.motion` event with `dx=dy=0` and
`buttons=0x1` may also appear in the boot-protocol mouse layout
(buttons-only HID reports show as zero-delta motion events); this
is correct, not a bug.

### M.4: right button transitions

**Action.** Press and release the right mouse button once.

**Expect.** Same as M.3, but with `button=0x2` and the buttons
bitmap toggling between 0x0 and 0x2.

**Acceptance.** Same as M.3.

### M.5: middle button (if present)

**Action.** Press and release the middle mouse button (or scroll
wheel button) once, if your mouse has one.

**Expect.** Same as M.3, but with `button=0x4` and the buttons
bitmap toggling between 0x0 and 0x4.

**Acceptance.** Same as M.3. Skip this check if the mouse has no
middle button.

### M.6: simultaneous buttons (optional)

**Action.** Hold the left mouse button down. While holding it,
press and release the right button.

**Expect.** Four events:

- `pointer.button_down button=0x1 buttons=0x1` (left press)
- `pointer.button_down button=0x2 buttons=0x3` (right press, both held)
- `pointer.button_up   button=0x2 buttons=0x1` (right release, left still held)
- `pointer.button_up   button=0x1 buttons=0x0` (left release)

**Acceptance.** Each button transition emits exactly one event;
the buttons bitmap correctly reflects the union of currently
held buttons during each event.

## Troubleshooting matrix

If a check fails, the table below maps the failure to the most
likely cause.

### Phase 0 (preconditions)

- "/var/run is X, expected tmpfs": fix `/etc/fstab`, remount, retry.
- "inputdump binary not found": run `zig build` from `inputfs/`.
- "stale C.2/C.3 throwaway exists": delete
  `inputfs/tools/inputstate-check.zig` (it was removed in C.4).
- "inputfs.ko not built": `cd inputfs/sys/modules/inputfs && sudo make`.

### Phase 1 (module load)

- "kldload inputfs failed": check `dmesg | tail` for the underlying
  reason. Common causes: kernel ABI mismatch (rebuild against
  `/usr/src` for the running kernel), missing `hidbus` (this
  driver depends on it; should be in the PGSD kernel).

### Phase 2 (publication region files)

- "state is N bytes, expected 11328": the kernel `MOD_LOAD` is
  not writing the full buffer at file open. Check
  `inputfs_state_open_file`'s initial `vn_rdwr` size.
- "events is N bytes, expected 65600": same root cause for the
  events file. C.3 added an explicit full-buffer write at open
  for exactly this reason.
- "magic 'INST'/'INVE'" wrong: byte order or constant divergence
  between kernel and `shared/src/input.zig`. Compare
  `INPUTFS_STATE_MAGIC` / `INPUTFS_EVENTS_MAGIC` definitions.
- "version byte" wrong: same kind of divergence.

### Phase 3 (state region content)

- "device_count = 0, expected >= 1": no devices attached. Check
  `dmesg | grep inputfs` for attach lines. If devices appear in
  dmesg but not in the state region, the writer is not publishing;
  check `inputfs_state_put_device` and the state slot allocation.
- "inputdump state failed": probably an `input.zig` reader bug or
  a layout drift. Run `sudo zig-out/bin/inputdump state` directly
  to see the error.

### Phase 4 (event ring content)

- "lifecycle.attach events = N, device_count = M" mismatch:
  - N < M: some attaches are not emitting events. Check the
    `inputfs_events_publish` call in the attach path.
  - N > M: extra events from somewhere (a device that detached and
    re-attached, or a stale event in the ring from a previous
    load). Try unloading and reloading the module.
- "no events in ring": the kthread is not running, or
  `MOD_LOAD` did not initialise the events buffer. Check the
  kthread startup in `inputfs_modevent`.
- "seq N not greater than previous M": writer protocol violation.
  This is a serious bug; the `inputfs_events_publish` ordering
  may be wrong, or atomic stores are not actually atomic on this
  platform.

### Phase 5 (liveness)

A flat `last_sequence` is OK if no input is being driven. A
*regressing* last_sequence means a snapshot is reading a stale
view; check the seqlock retry loop in `StateReader.snapshot`.

### Phase 6 (module unload)

- "kldunload inputfs failed": something is holding a reference to
  the module. Check `kldstat -v inputfs` for refcount.
- "M_INPUTFS bytes did not return to baseline": memory leak. Check
  `MOD_UNLOAD` for missing `free()` calls. Common culprits: state
  buffer, events buffer, kthread state.

### Phase 7 (reload sanity)

Same diagnoses as phases 2, 4 in their respective failure modes.
A regression on reload but not on first load typically points to
state in module-global variables that is not reset by `MOD_LOAD`.

### Manual checklist

- M.1 produces no events: HID interrupt path is broken. Check
  `dmesg | grep inputfs` for raw report lines (B.4 logging).
- M.3 / M.4 produce only one event per press-release pair instead
  of two: button transition detection is wrong. Check the
  `prev_buttons ^ new_buttons` logic in the interrupt path.
- M.6 produces wrong `buttons` bitmaps: simultaneous-press
  handling broken. Should be straightforward (each event reports
  the buttons mask at the time of the event, not the delta).

## Recording

For commit messages and the BACKLOG closeout:

```
sudo sh test/c/c-verify.sh > c-verify.log 2>&1
```

The closeout entry should cite the bench used (`PGSD-bare-metal`)
and the device count exercised. If the manual checklist was run,
say so explicitly: "automated checks passed, manual checklist M.1
through M.5 passed" or similar. M.6 is optional and need not be
mentioned if not run.

## Notes

The verification deliberately does not exercise keyboard, touch,
or pen events; Stage C's emission is limited to pointer events
and lifecycle events per the C.3 scope decision (full
descriptor-driven parsing for the other roles is deferred). When
those event paths are added in a later sub-stage, this protocol
will gain corresponding manual checks (`M.K1`, `M.T1`, `M.P1`)
and automated phase additions for the new event types.

The chronofs `ts_sync` integration is also deferred: every event
has `ts_sync == 0`. Once chronofs is wired up, an automated phase
will be added that reads two snapshots from chronofs across an
event window and verifies that `ts_sync` values fall within the
expected drift band.
