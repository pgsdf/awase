# audiofs unfed-stream investigation findings (open)

## Status

Open investigation. No decision. This note records evidence-backed
findings and the questions still open, so the thread is captured
precisely for when semasound's intended behavior is on the table.
It deliberately does not propose a fix; the central decision
depends on evidence this note shows we do not yet have.

It is not an ADR and not yet an ADR-bound artifact (no lifecycle
ADR number exists). Suggested placement: an audiofs investigation
or sessions note (for example `audiofs/docs/sessions/`), to be
promoted to an ADR-bound companion if and when a lifecycle ADR is
opened. Placement is the operator's call.

## Relationship to ADR 0031

Independent. ADR 0031 removes the amplifier: the F.3.d
xrun-to-event-to-republish-to-topology-walk path that turns a
stalled stream into a 47-per-second `path_dead_end` storm. This
note concerns the trigger: why a stream is running unfed in the
first place. 0031 makes the system robust to the storm regardless
of cause; this investigation is about removing the cause. Both are
needed; neither subsumes the other.

## Method note

This investigation repeatedly produced plausible mechanisms that
later evidence falsified. The findings below are split into
evidence-backed facts and explicitly-open questions for that
reason. Several attractive hypotheses were killed by direct
measurement (see Falsified). The discipline that held: a mechanism
is not a finding until the bench confirms it.

## Established facts (evidence-backed)

### The stream is genuinely live, on both surfaces

  - Clock region `/var/run/sema/clock`: `clock_valid = 1`,
    `clock_source = 1` (audio), `sample_rate = 48000`,
    `samples_written = 0x41574bd8 = 1096889816`. At 48 kHz that is
    about 6 hours 21 minutes of continuous clocking.
  - State region `/var/run/sema/audio/state`: `state_valid = 1`,
    2 controllers, 11 endpoints. On controller 0 (Intel
    `8086:a170`) the Speaker endpoint reads `electrically_ready =
    1`, `runtime_active = 1`, `current_format = 0x0011`
    (`AUDIOFS_FMT_48KHZ_16BIT_STEREO`). Every other endpoint reads
    `runtime_active = 0`.

The clock and the state region agree: a stream is bound and
running on the internal Speaker DAC at 48 kHz, 16-bit, stereo.
There is no clock-versus-state inconsistency.

### It has run since boot, fed then unfed

  - `samples_written` corresponds to about 6 hours 21 minutes of
    clocking. semasound (PID 286) has been up 6 hours 16 minutes
    (started 11:42:41). The clock therefore began roughly 5
    minutes before semasound started.
  - `dev.audiofs.0.underflow_count` is about 354000 and climbing
    at about 47 per second (94 observed in 2 seconds). Controller
    1's count is 0. That is roughly 2 hours of continuous
    underrun.

So the stream is about 6.3 hours old, was fed (no underrun) for
roughly its first 4 hours, and has been underrunning for the last
roughly 2 hours. The 2 hours is the unfed duration, not the
stream's age.

### A live write-owner is present and idle

  - `sudo fstat` and `fuser /dev/audiofs0` show semasound (PID
    286) holds `/dev/audiofs0` fd 4 (write) and `audiofs_notify`
    fd 5 (read).
  - `sockstat` shows semasound's listening socket
    `/var/run/sema/audio.s` with no connected client peer.
  - `procstat -t 286` shows threads parked in `accept`, `nanslp`,
    `uwait`, `pipewr`: idle, not blocked on the audio device, not
    spinning, not hung.

semasound is healthy and quiescent, holding the device open with
no client connected.

### Source-level lifecycle facts (from audiofs.c)

  - A stream stops only via `audiofs_stream_end`, which is called
    only from `audiofs_cdev_close`, and there only when
    `test_tone == 0`. While the device is held open, the stream
    runs. There is no path that stops the stream while keeping the
    device open.
  - `audiofs_cdev_open`: if no stream is active it calls
    `stream_begin`; if a stream is already running (SINE source
    from the tunable) it swaps source to USER without restarting.
  - The `test_tone = 1` warm path starts a SINE stream at attach
    and keeps it running across opens and closes (close swaps
    source back to SINE rather than ending it).
  - `runtime_active = 1` is published for exactly the one
    configured output DAC (`output_stream_configured &&
    output_dac_cad == cad && output_dac_nid == dac`).

## Falsified hypotheses

Recorded so they are not re-proposed.

  - **"The stream started about 2 hours ago."** Falsified: the
    clock shows about 6.3 hours of clocking since boot. The 2-hour
    figure is the underrun (unfed) duration, not the stream age.
  - **"No owner; a kernel close-path escape left an ownerless
    stream running."** Falsified: an unprivileged `fstat` returned
    empty (a privilege artifact), but `fuser` and `sudo fstat`
    show semasound owns the device. There is an owner.
  - **"A boot-time `test_tone = 1` tunable started a perpetual
    SINE stream."** Falsified: `test_tone` is not set in
    `/boot/loader.conf` or `loader.conf.local` and reads 0.
  - **"Clock-versus-state inconsistency: clocking with no endpoint
    marked active."** Falsified: the Speaker endpoint reads
    `runtime_active = 1` with a valid format; the two surfaces
    agree.

## Durable findings

  - **F1. Sustained underrun occurs with a valid owner present and
    idle.** A stream runs live on controller 0's Speaker DAC,
    unfed, while semasound holds the device open and sits idle with
    no client. Consequence for any future kernel-side abandonment
    logic: it cannot key on "no owner" as its sole criterion. The
    owner is present. The condition is "owner present, idle, stream
    running and starving," which an ownership check alone cannot
    distinguish from a slow-but-live producer between writes.

  - **F2. audiofs has no stop-while-open path.** A held-open device
    keeps its stream running by design, because `stream_end` is
    reachable only from `cdev_close`. The idle model "device held,
    stream stopped" is therefore not achievable in the current
    design without new mechanism; only "release the device to stop
    the stream" is supported today. Any lifecycle decision that
    wants device-held-stream-stopped must add that mechanism, not
    merely change a caller.

  - **F3. The clock began before semasound started.** The audio
    clock predates semasound's launch by about 5 minutes. The
    Speaker-stream binding does not explain how clocking began
    before the apparent owner existed. This tension is unresolved
    and is the strongest open thread.

## Open questions

  - Why did feeding stop about 2 hours ago while the stream kept
    running?
  - How did clocking begin before semasound launched (F3)? Did the
    stream start at attach by a path not yet read, with semasound
    later adopting it via the source-swap-on-open path?
  - Where does the fix belong: semasound closing the device when it
    has no client (supported by the current design), audiofs gaining
    a stop-while-open mechanism plus a present-owner-aware
    abandonment net (new design, F1 and F2), or both?
  - What is semasound's intended behavior on its `/dev/audiofs0` fd
    when it has no client: does it open at startup and hold across
    idle, close on last client, or feed silence? This is not
    answerable from the audiofs tree.

## Why no ADR yet

The central lifecycle decision (where the stop belongs, and whether
device-held-stream-stopped is even a target state) depends on
resolving F3 and on knowing semasound's intended open and idle
behavior, neither of which is established. Per ADR-before-code and
bench-as-authority discipline, this is recorded as findings and the
decision is deferred. The next evidence is on the semasound side,
not the audiofs side.
