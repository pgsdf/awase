# 0032: boot initialization chime

## Status

Proposed, 2026-07-07 (revision 2). Revision 1 was operator-ratified
the same day with an rc.d oneshot anchored REQUIRE-after-audiofs.
Source survey during implementation showed that anchor unsound (see
Context, "why not audiofs"); this revision changes the readiness
anchor and returns for ratification before the implementation lands.

Not part of the F-series milestone chain. Depends on F.5.e state
publication (ADR 0027, closed) as its readiness observable and on
semasound-cat (F.5 client set) as its playback mechanism.

## Context

The operator needs audible confirmation that the audio substrate
reached readiness at boot. The chime doubles as a per-boot probe of
the CS4206 D0 power-up and GPIO ordering paths on bare metal: a
silent boot on known-good hardware is an audible regression signal
for exactly the two bugs diagnosed and fixed on
bare-metal-test-bench.

Why not audiofs. Revision 1 anchored the chime on audiofs rc
completion, reasoning that module load is the earliest point
playback is possible. Two facts from the source contradict this.
First, semasound-cat is a broker client: it connects to the
semasound socket and streams there, so nothing is playable until
the broker is up, regardless of module state. Second, and
load-bearing, AD-47 makes the broker start on the null sink when
the device is absent and reconnect when it appears (fd ownership
fixed under AD-50). A chime played into the null sink is consumed
at nominal rate and exits 0: best-effort "success" with no sound,
which silently defeats the probe purpose. Exit status alone cannot
distinguish an audible chime from a swallowed one.

The correct readiness observable already exists. F.5.e (ADR 0027)
publishes per-target static surfaces under
/var/run/sema/audio/<target>/, including `device`, which reads
`/dev/audiofs0` when hardware is bound and `none` on the null sink.
Polling that surface is exactly the "hardware sink live" signal the
chime needs, consumed through the observability layer built for
this purpose rather than inferred from rc ordering.

Why not session establishment. Considered and rejected in revision
1, unchanged here: the chime signals substrate readiness, not
session establishment, and pgsd-sessiond should stay free of audio
dependencies (its scope is ADR 0009/0010 territory: idle, power,
lock).

## Decisions

### 1. Mechanism: rc.d oneshot pgsd-bootchime, REQUIRE: semasound

A oneshot, not a daemon: it has no s6 service directory and does
not follow the AD-20 shim shape, because there is nothing to
supervise. rcorder places it after the semasound shim (which itself
REQUIREs awase_supervisor and audiofs_loaded), so by the time it
runs, the supervision tree exists and the broker is starting.

Rationale. The tree's existing pattern is rc.d for one-time boot
actions (module load) and s6 for daemons; a chime is a one-time
boot action.

### 2. Readiness: poll the F.5.e device surface, then play

The oneshot backgrounds a subshell immediately (rcorder is never
delayed) which polls /var/run/sema/audio/default/device until it
reads a device path rather than `none`, then plays
$PREFIX/share/pgsd/sounds/boot.pcm through semasound-cat with
`--label bootchime`. Defaults, all rc.conf-tunable: 50 polls at
100 ms (5 s window), 5 s hard timeout on playback.

Rationale. The device surface is the only observable that
distinguishes the hardware sink from the null sink (the AD-47
swallow). Bounded polling absorbs both broker startup and device
reconnect latency without ever holding boot.

### 3. Failure semantics: strictly best-effort, one log line

Missing asset, poll window exhausted, or nonzero semasound-cat
exit each produce exactly one syslog line via logger(1) and
nothing else. Boot proceeds identically with or without audio
hardware. No retry of playback itself: by Decision 2 the stream
is only attempted against a bound device, so semasound-cat's
distinct failures (2 rejected at hello, 3 preempted by policy,
ADR 0026 Decision 6) are policy outcomes to report, not races to
retry.

### 4. Asset: build product from a committed generator

boot.pcm is never committed. tools/gen-boot-tone.py (python3,
stdlib only; the inputfs fuzz harness precedent makes python3 an
acceptable tool dependency) is the source of truth. install.sh
generates and installs the asset at install time when python3 is
present and skips with a notice otherwise; the rc script tolerates
the missing asset per Decision 3. Output is pinned at 48000 Hz
stereo s16le, the CANON_RATE bit-exact passthrough path, 2.000 s,
sample-exact zero first and last frames so the stream cuts with no
click.

### 5. Sounds directory anticipates per-environment cues

The asset installs to $PREFIX/share/pgsd/sounds/ (following the
existing share/pgsd convention from the ADR 0004 session files).
A distinct RE-entry cue under the AD-59 three-environment model is
deferred to a follow-up ADR; the layout (boot.pcm, later
recovery.pcm) anticipates it.

## Closure criteria

1. Boot with audio present: chime plays the full 2.000 s sequence,
   audibly complete, no click at cutoff, within the poll window of
   semasound reaching the hardware sink.
2. Boot with audio hardware detached: boot proceeds identically
   minus the sound; exactly one log line (poll window exhausted).
3. Asset removed: one log line, boot unaffected.
4. Repeated cold boots: chime correct every time; silent or
   garbled boot flags D0 or GPIO ordering regression.
5. Poll-latency measurement recorded: boots-to-first-bind delay
   between semasound start and device surface leaving `none`, to
   confirm the 5 s window is generous on bench hardware.
6. Uninstall reaps the rc script, the rc.conf knob, and the
   sounds directory asset.

## References

- ADR 0027 (F.5.e): device surface, the readiness observable.
- ADR 0026 (F.5.d): label/class in Hello v3; exit codes 2 and 3.
- ADR 0025 (F.5.c): default and null targets; null sink pacing.
- AD-47, AD-50 (BACKLOG): null-sink fallback and reconnect; why
  exit status cannot signal audibility.
- ADR 0028 (F.5.f): rc.d shim shapes and REQUIRE chain.
- shared ADR 0004: share/pgsd layout precedent (session files).

## Revision history

- Revision 1, 2026-07-07: ratified in design discussion with an
  rc.d oneshot REQUIRE-after-audiofs anchor and a bounded
  open-retry loop.
- Revision 2, 2026-07-07: readiness anchor corrected to the F.5.e
  device surface after source survey found the audiofs anchor
  unsound (broker-client architecture; AD-47 null-sink swallow).
  Open-retry replaced by device-surface polling; playback itself
  is attempted once. Returned for ratification.
