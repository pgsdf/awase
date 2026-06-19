# audiofs unfed-stream investigation findings (2026-06-19)

## Status

Storm resolved on the bench; fault characterized but not
root-caused. The unfed-stream condition that drove the
`path_dead_end` storm ended when the holding semasound process
exited (closing the device, which cleanly stopped the stream). A
fresh supervised semasound came up and is feeding correctly. The
specific failure shape is now observed and confirmed, one earlier
hypothesis is refuted, and the trigger is open and requires
controlled reproduction rather than further observation. No fix is
drafted here, because the mechanism is not closed.

This is a dated session record. It is not an ADR. Placement:
`audiofs/docs/sessions/2026-06-19-unfed-stream-findings.md`.

## Relationship to ADR 0031

Unchanged and confirmed by this session. ADR 0031 removes the
amplifier: the F.3.d xrun-to-event-to-republish-to-topology-walk
path that turns a stalled stream into a 47-per-second
`path_dead_end` flood. This note concerns the trigger: why a
stream was running unfed. The two are independent; together they
were the storm. semasound stopped feeding (this note), and every
resulting underrun was multiplied into a topology-walk flood
(0031). 0031 makes the system robust to the flood regardless of
cause; closing this trigger removes the cause.

## Method note

This investigation repeatedly produced plausible mechanisms that
later evidence falsified, including one raised and refuted within
this session (see Refuted). The findings below separate what the
bench proved from what remains inferred or open. The discipline
that held throughout: a mechanism is not a finding until the bench
confirms it, and a mechanism the bench contradicts is dead no
matter how clean it looked.

## The intended architecture (from semasound source)

`semasound/src/output.zig` is explicit: the output loop is "the
sole writer to /dev/audiofs0," and "with no clients the mix is
silence and the loop still paces on the write, keeping the stream
alive." So at idle the stream is designed to be continuously fed
with silence: `clock_valid` stays 1, the kernel clock keeps
advancing, and the compositor can pace off it. The intended idle
state is therefore device-open, stream-running, fed-with-silence,
not a stopped stream.

This relocates the bug. An unfed, underrunning stream is a failure
of this silence-feed loop, in semasound's output layer. It is not
an audiofs lifecycle gap and not intended behavior.

The output loop has an AD-47 device layer (2026-06-06 finding):
device write errors transition a `real` state to a `null_sink`
state that discards the mix, paces on a monotonic timer, and is
meant to retry the device open at about one per second, returning
to `real` on success. AD-47 prevented a device error from killing
the engine outright; this session found a gap in what it left
behind.

## What was observed on the bench

  - The stream was genuinely live and unfed before resolution:
    state region `runtime_active=1`, `current_format=0x0011`;
    clock `clock_valid=1`, samples advancing; `underflow_count`
    climbing about 47 per second for roughly 2 hours.
  - semasound (PID 286) held `/dev/audiofs0` fd 4 (write) with no
    connected client, threads parked in `accept`, `nanslp`,
    `uwait`, `pipewr`: alive, idle, not hung.
  - `truss -p 286` showed the output loop timer-pacing on
    `nanosleep(0.0212...)` (the 1024-frame-at-48kHz period), no
    `write()` to the device, and it wrote target state files
    reporting `status=idle, clients=0`. So it was in the
    `null_sink`-style discard-and-pace mode, not feeding.
  - Critically, the trace showed NO `openat("/dev/audiofs0")`
    attempts at all over several seconds. The reconnect was not
    being blocked; it was not being attempted.
  - PID 286 then exited (possibly disturbed by the truss
    attach/detach). The kernel closed its fd, which fired
    `cdev_close`, which called `stream_end`. dmesg captured the
    chain directly:

        path_dead_end ...                                  (storm)
        stream_end: stream_id=1 frames_total=1366929251 (clean stop)
        cdev_close arg=0x0

    The `path_dead_end` flood ended at that `stream_end`.
  - `underflow_count` froze at 1293991 (zero increment over 2 s,
    then over a further 3 s). s6 respawned a fresh semasound (PID
    72318); the new process feeds correctly and the underflow
    count stays flat. The system is back in its proper idle state.

## The fault, characterized

semasound reached a state in which its output loop timer-paced in
the device-less `null_sink` mode, did not feed the live kernel
stream, did not attempt to reconnect to the device, and reported
clean `status=idle`. The kernel stream starved underneath a daemon
that believed it was healthily idle. That gap, presenting
healthy-idle while not feeding a live stream, is the fault shape.
It is observed and confirmed. What put the loop there, and whether
the device-owning loop wedged or had exited, is not yet
determined.

## Refuted hypotheses

Recorded so they are not re-proposed.

  - **"The stream started about 2 hours ago."** Refuted earlier in
    the session by the clock: the stream had run since near boot;
    the 2 hours was the unfed duration, not the stream age.
  - **"No owner; a kernel close-path escape left an ownerless
    stream running."** Refuted: semasound owned the device (the
    first empty `fstat` was an unprivileged-view artifact).
  - **"A boot-time test_tone tunable started a perpetual SINE
    stream."** Refuted: `test_tone` is not in loader.conf and reads
    0.
  - **"Clock-versus-state inconsistency."** Refuted: the Speaker
    endpoint read `runtime_active=1`; clock and state agreed.
  - **"The null_sink reconnect deadlocks on EBUSY against
    semasound's own held fd."** Refuted in this session by truss:
    there were no device-open attempts at all in the trace, so the
    reconnect was not being blocked, it was not running. The
    reconnect-deadlock mechanism is dead.

## How it resolved

PID 286's exit closed the device, `cdev_close` called
`stream_end`, the stream stopped cleanly (`frames_total` recorded),
and the storm ended in the same instant (the three-line dmesg
chain above). A fresh semasound respawned and feeds correctly. A
clean restart therefore lands in the healthy state and stays
there, which means the wedge is not spontaneously reproducible: the
trigger was an event, not a condition the daemon drifts into on its
own.

## Durable findings

  - **F1. The clean-idle-while-not-feeding state is reachable.**
    semasound can present `status=idle` while its output loop is
    not feeding a live kernel stream that then starves. Any future
    kernel-side abandonment net cannot key on "no owner": here the
    owner was present, alive, and reporting idle. (Observed before
    resolution; the state is real even though this instance is
    cleared.)
  - **F2. audiofs has no stop-while-open path.** A stream stops
    only via `stream_end`, reachable only from `cdev_close`. While
    the device is held open the stream runs. The idle model
    "device held, stream stopped" is not achievable without new
    mechanism; only "release the device to stop" exists today.
    Relevant to any lifecycle fix, including a semasound-side one
    that wants to stop the stream without dropping the device.
  - **F3 (resolved). The clock predating semasound is a counter
    artifact, not a tension.** The target state files show
    `frames_written` counters that do not reset per process
    (default about 41.9 million, null about 1.367 billion, both far
    exceeding the roughly 6 hour uptime). These are long-lived
    monotonic counters, so cross-counter time arithmetic was never
    going to align with a single process's elapsed time. The
    earlier "clock began 5 minutes before semasound" puzzle
    dissolves once the counters are understood as not process-local.
  - **F4. The storm structure is dmesg-confirmed.** The
    `stream_end (clean stop)` immediately after `cdev_close`, with
    the `path_dead_end` flood ending there, proves the storm was a
    single live stream (id=1) tied to the device-open, stopped by
    closing the fd. Every piece of the reconstructed structure is
    confirmed in the kernel log.
  - **F5. A clean restart restores the healthy idle state.** The
    fresh semasound feeds silence correctly with zero underflow
    increment. Remediation of an active wedge is a service bounce;
    it is not a fix for the trigger.

## Open questions

  - What event triggers the `null_sink` transition and leaves the
    loop not feeding and not reconnecting? Candidates, all
    unconfirmed: a device write error from a `SET_FORMAT` waking the
    blocked writer (ADR 0019), or a device disappearance of the
    AD-47 `kldunload` class.
  - Did the device-owning output loop wedge in `null_sink` without
    reconnecting, or had that loop exited entirely, leaving only the
    null-target loop (`runNull`, which never touches the device)
    running? The truss could not distinguish before PID 286 exited.
  - Why was no reconnect `openat` observed at all? If the loop were
    in `null_sink` and healthy, it should retry once per second.
    Its absence is the strongest open clue and points at either a
    not-reached reconnect branch or a dead device loop.

## Surfaced defects (independent of the wedge)

  - **D1. utf-to-awase log-path migration straggler.** The s6-log
    services are still pointed at `/var/log/utf/<svc>`, which does
    not exist, so they crash-loop (`s6-log: fatal: unable to mkdir
    /var/log/utf/semasound`). Per-service logs under
    `/var/log/awase/<svc>/` are empty as a result. This is an R3
    operational-path straggler from the UTF-to-Awase rename. Fix is
    a path-token change only in the s6-log run scripts and the
    `install.sh` lines that write them; it must not be a blind
    `s/utf/awase/`, because `utf` is a substring of `inputfs` and
    the subsystem names.
  - **D2. The fault was invisible because of D1.** semasound's
    1-Hz heartbeat prints `degraded[...] device absent,
    reconnecting` in `null_sink` and `playing[...]` in `real`. With
    per-service logging dead, that heartbeat went nowhere, so a
    production fault ran for about 2 hours undiagnosed. Had the
    heartbeat landed in `/var/log/awase/semasound/current`, this
    would have been a seconds-long diagnosis. D1 is therefore not
    only cleanup; it is an observability gap that hid a live fault.

## Why no fix yet

The fault shape is confirmed but the trigger is not, and the live
evidence left with PID 286. A clean restart does not reproduce it.
Root-causing it requires controlled reproduction: fix D1 so the
heartbeat is captured, attach truss from the start, then induce the
`null_sink` transition deliberately (the `SET_FORMAT`-write-error
path or an AD-47-class device disappearance) and observe whether
the device loop reconnects or wedges, and whether it is the device
loop or only `runNull` that survives. Only then is the lifecycle
fix specifiable. D1 is independently fixable now and should be,
both on its own merit and because it is the reason this fault hid.
