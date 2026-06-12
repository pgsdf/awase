# D-11 verification: published idle timestamp on bare metal

Acceptance test for D-11 (publish `last_input_ts_ns` for idle
detection, semadraw ADR 0013) on `pgsd-bare-metal`. The D-11 closeout
in `BACKLOG.md` and the ADR 0013 bench section flip only after this
runbook passes end-to-end.

D-11 exposes the idle signal that SM-2 (pgsd-sessiond ADR 0010) and
SM-3 (ADR 0009) consume. semadrawd publishes `last_input_ts_ns`
(chronofs ns) over the client socket via the `idle_query` /
`idle_reply` round-trip; the `idle_probe` tool issues that query. The
probe prints the raw published value and, in watch mode, the change
since the previous poll. It does not compute idle against a clock:
`idle = chronofs_now - last_input_ts_ns` is the consumer's job
(ADR 0013 D2). What this runbook checks is that the published value
behaves correctly: zero before any input, advancing on each input
class, and fresh for a non-root caller.

## Setup

Build on the bench; both binaries install under `zig-out/bin/`:

    zig build

Optionally confirm the generated constants match the spec first:

    python3 shared/tools/gen_constants.py --validate

Have `semadrawd` running, with the keyboard and the HAILUCK touchpad
attached. `idle_probe` is built but not installed on `PATH`; run it from
`semadraw/zig-out/bin/idle_probe`. It connects to the default socket
`/var/run/semadraw.sock` and creates no surface.

Run the probe over SSH and exercise the input devices physically on the
machine. SSH keystrokes travel over the network, not through inputfs, so
they do not update `last_input_ts_ns`; only the local keyboard, mouse,
and touchpad do. This is what isolates the per-class checks: typing the
command or reading output over SSH never registers as input, so each
`advanced=yes` is attributable to the one local device you touched.

Output format, one sample per line:

    idle last_input_ts_ns=<u64>                                   (one-shot)
    idle last_input_ts_ns=<u64> delta_ns=<i128> advanced=<yes|no> (watch)

`advanced=yes` means input arrived between this poll and the previous
one; `delta_ns` is the timestamp change in chronofs ns.

## Check 1: sentinel, zero before first input (ADR 0013 D3)

Start `semadrawd` fresh and, before touching any input device, run the
one-shot probe:

    zig-out/bin/idle_probe

Expected:

    idle last_input_ts_ns=0

Timing is the whole point: if any input has already reached the daemon
the value is nonzero. If you have already typed or touched, restart
`semadrawd` and re-query. This confirms the contract that a reply of 0
means no input has been observed since daemon startup.

## Check 2: per-class advance (ADR 0013 D4, coverage)

Start the watcher (polls once per second):

    zig-out/bin/idle_probe --watch

With a couple of idle polls between each action, exercise one input
class at a time and confirm the next sample reads `advanced=yes`
(`delta_ns` greater than 0):

  1. Press a key.
  2. Wait for an idle poll or two (`advanced=no`), then move the
     pointer.
  3. Wait again, then make a touch contact on the touchpad.

Each class must independently produce `advanced=yes`. Idle polls
between actions must read `advanced=no delta_ns=0`, confirming the
value moves only on real input. This demonstrates that the timestamp
is driven by the raw inputfs stream (every class), not by the gesture
path alone.

## Check 3: non-root freshness (ADR 0013 D1, the AD-34 reason)

Run the watcher as an ordinary user, not root:

    zig-out/bin/idle_probe --watch

Generate input and confirm the value still advances. This is the case
the old state-region mmap broke: that mmap is stale for non-root
readers (AD-34), which is why D-11 publishes over the socket instead.
Advancing values for a non-root caller confirm the socket path works.
If a non-root user cannot connect to `/var/run/semadraw.sock` at all,
that is a separate socket-permission finding to record.

## Check 4: idle hold (optional sanity)

Leave the system untouched and confirm `advanced=no` holds across
polls (the value is steady), then confirm any input flips the next
poll to `advanced=yes`. A negative `delta_ns` indicates the daemon
restarted and reset the value to 0.

## Caveats

  - AD-52 (clickpad button-release) is still open, so button events
    are unreliable. Use pointer motion and touch contact, not button
    clicks: motion and contact flow normally and are what bump
    `last_input_ts_ns`, whereas a click could conflate a button defect
    with an idle-signal defect.
  - On the HAILUCK clickpad a finger slide produces both a touch
    contact and synthesised pointer motion, so the two classes are
    coupled on that one device. To isolate the pointer class from
    touch, use a separate USB mouse for pointer motion and the
    touchpad for touch. The side-channel captures every raw event
    regardless; the aim is only to confirm each input path reaches the
    timestamp.

## Pass criteria and closeout

D-11 is verified when all of the following hold:

  - a fresh daemon returns `last_input_ts_ns=0` before any input;
  - `advanced=yes` follows each of keyboard, pointer, and touch input
    independently;
  - `advanced=no` holds while idle;
  - a non-root caller sees advancing values.

When they hold, mark the ADR 0013 bench section and the D-11
`BACKLOG.md` entry bench-complete and move D-11 to
`BACKLOG-history.md`.

## Result

Verified 2026-06-09 on pgsd-bare-metal (operator vic). All four checks
passed: the sentinel returned 0 on a fresh daemon; keyboard, pointer,
and touch each advanced the value independently; and a non-root caller
received fresh advancing values. D-11 closed to `BACKLOG-history.md`;
ADR 0013 marked bench-verified.
