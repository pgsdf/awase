# 0019 F.3.e: audiofs format negotiation

## Status

Accepted, 2026-06-01 (ratified same day as proposed; design
choices reviewed and confirmed by the bench operator before
implementation began).

Per ADR 0011, F.3.e is the format-negotiation sub-stage of
AD-3 Stage F. It depends on F.3.b (the user-control surface
to negotiate through, ADR 0015) and on the codec format
enumeration already performed at attach. ADR 0011 fixes the
policy: "Format query at attach time per DAC; format
negotiation through the user-control surface (F.3.b);
native-format-only in the kernel per ADR 0007."

This ADR does not reverse, reopen, or amend ADRs 0001-0018.
It implements the ioctl surface ADR 0015 section 8 reserved
(`AUDIOFS_IOC_GET_FORMAT` / `AUDIOFS_IOC_SET_FORMAT`,
numbers left for this ADR to allocate) and uses the
`format_change` F.2 event (type 4) already defined in
`shared/AUDIO_EVENTS.md` and `audiofs_events.h`.
Implementation follows in a separate commit after
ratification, kernel change plus bench, with bench-safety
review before it reaches the iMac (ADR 0014 discipline).

## Context

As of F.3.b the output stream comes up at a single hardcoded
wire format: 48 kHz, 16-bit, stereo, the format word
`0x0011`. `audiofs_stream_begin` takes `format`, `channels`,
and `rate_hz` arguments but rejects anything other than
`0x0011` / 2 / 48000 with `EINVAL` (audiofs.c:4999). The
cdev ioctl handler is a stub returning `ENOTTY`
(audiofs.c:5602). The codec's capabilities are already
enumerated and stored: `fg_supp_pcm_size_rate` and
`fg_supp_stream_formats`, with per-DAC accessors
`audiofs_widget_supp_pcm_size_rate` /
`audiofs_widget_supp_stream_formats`.

ADR 0007 forbids format conversion in the kernel: audiofs
publishes and consumes only formats the codec supports
natively, and any resampling or bit-depth/channel
conversion is userland's job (semasound, F.5). F.3.e is
therefore negotiation, not conversion: validate a requested
format against the DAC's advertised capabilities, accept it
if native, reject it otherwise.

On the confirmed target (pgsd-bare-metal, CS4206) the DAC
advertises `psr=0x20070`, which is 16-bit only at 32 kHz,
44.1 kHz, and 48 kHz. No other bit depth is advertised, so
only sample rate genuinely varies on this hardware.

## Decision

### 1. Scope: rate negotiation only, 16-bit stereo fixed

F.3.e v1 negotiates sample rate only. Bit depth stays 16
and channel count stays 2. The negotiable rates are those
the chosen output DAC advertises in its
`SUPP_PCM_SIZE_RATE` param, intersected with the set
audiofs supports in v1: 32000, 44100, 48000.

A `SET_FORMAT` request is accepted only if all of:
  - bits == 16 and channels == 2 (else `EINVAL`);
  - the requested rate is one of {32000, 44100, 48000} and
    the DAC's PSR advertises it (else `EINVAL`).

This keeps the frame size at 4 bytes (16-bit stereo)
invariant. The ithread LPIB delta math (`delta / 4`), the
fragment accounting, the F.3.c position counter, and the
F.4 clock accumulator are all expressed in or convert
through that constant and are untouched by F.3.e. Bit-depth
and channel negotiation would change bytes-per-frame and
ripple through all of those; they are out of scope here
(see Rejected alternatives B).

Native-only per ADR 0007: audiofs does not resample or
convert. A rate the DAC does not advertise is rejected, not
emulated.

### 2. Format-word construction

The HDA stream format word (`SDnFMT`, and the codec
`SET_CONV_FMT` payload) encodes base rate (bit 14), rate
multiplier (bits 13:11), divisor (bits 10:8), bits per
sample (bits 6:4), and channels minus one (bits 3:0), per
`hda_reg.h`. For 16-bit stereo the three supported rates
are:

  - 48000: base 48 kHz, x1, /1  -> `0x0011`
  - 44100: base 44.1 kHz, x1, /1 -> `0x4011`
  - 32000: base 48 kHz, x2, /3   -> `0x0A11`

audiofs derives the word from the requested rate (a small
switch keyed on the validated rate), using the `hda_reg.h`
`HDA_SDFMT_*` field defines rather than bare hex where they
exist. `audiofs_configure_output_stream` (audiofs.c:4406)
and the DAC `SET_CONV_FMT` path stop writing the
`AUDIOFS_FMT_48KHZ_16BIT_STEREO` constant and write the
current stream's negotiated word instead. The constant is
retained as the default (see Decision 5).

### 3. ioctl surface

Two ioctls on `/dev/audiofs0`, filling the existing
`audiofs_cdev_ioctl` stub. The exchange struct:

```c
struct audiofs_format {
    uint32_t rate_hz;        /* 32000 | 44100 | 48000      */
    uint16_t format_word;    /* HDA SDnFMT word (GET only) */
    uint8_t  bits;           /* 16 in v1                   */
    uint8_t  channels;       /* 2 in v1                    */
    uint32_t supported_rates;/* bitmask, GET only          */
};

#define AUDIOFS_RATE_32000  0x1
#define AUDIOFS_RATE_44100  0x2
#define AUDIOFS_RATE_48000  0x4

#define AUDIOFS_IOC_GET_FORMAT  _IOR('A', 1, struct audiofs_format)
#define AUDIOFS_IOC_SET_FORMAT  _IOW('A', 2, struct audiofs_format)
```

  - `GET_FORMAT` returns the active stream's `rate_hz`,
    `format_word`, `bits`, `channels`, and
    `supported_rates` (the DAC's advertised set among the
    three, derived from its PSR). This lets userland pick a
    rate without trial-and-error. Valid whenever the device
    is open.
  - `SET_FORMAT` reads `rate_hz` (and validates `bits` ==
    16, `channels` == 2). On success the active stream is
    reconfigured to the requested rate (Decision 4).

The numbers `'A'`,1 and `'A'`,2 are allocated here and
recorded; they are audiofs-native, not OSS-compatible
(OSS compatibility is out of scope; semasound speaks the
audiofs ioctls directly).

### 4. SET_FORMAT semantics: reconfigure the running stream

Because `cdev_open` starts the stream immediately
(audiofs.c cdev_open calls `audiofs_stream_begin` itself),
there is no open-but-idle window. `SET_FORMAT` therefore
reconfigures the live stream. Run from ioctl context, which
is sleepable:

  1. Validate per Decision 1. Unsupported -> `EINVAL`, no
     state change.
  2. If the requested rate equals the current rate, return
     0 (no-op).
  3. Otherwise, under `output_stream_user_ring_mtx`: mark a
     format change pending and flush the user ring (discard
     buffered bytes, they are at the old rate and would play
     at the wrong pitch across the boundary). Wake any
     writer blocked in `msleep` on a full ring so it
     re-evaluates.
  4. `audiofs_stream_end(sc)` then `audiofs_stream_begin(sc,
     0, word, 2, rate)` with the negotiated word and rate.
     This reuses the existing lifecycle (hw_lock for the
     hardware reprogram, `audiofs_state_sx` for the F.2
     events), so the reconfigure is a stop/start, not a new
     code path for hardware setup.
  5. `audiofs_stream_begin` already calls
     `audiofs_clock_stream_begin(sc, rate)` (F.4), which
     republishes the new `sample_rate` to
     `/var/run/sema/clock`. The clock's `samples_written`
     accumulator is monotonic across the stop/start (F.4
     Decision 4), so the published clock does not regress.
  6. Emit one `format_change` F.2 event
     (`AUDIOFS_EVSTREAM_FORMAT_CHANGE`, type 4) with
     `old_format`, `new_format`, and `new_rate_hz`, using
     the existing `audiofs_evp_format_change` payload.

The write path after `SET_FORMAT` returns is interpreted at
the new rate. Bytes accepted before `SET_FORMAT` are gone
(flushed); the caller is responsible for not racing its own
writer thread against its own `SET_FORMAT` if it cares about
exactly which samples were dropped. audiofs guarantees only
that the stream is internally consistent: no old-rate bytes
are played at the new rate.

Concurrency: `SET_FORMAT` holds `output_stream_user_ring_mtx`
across the flush and takes the same locks `stream_end` /
`stream_begin` already take. The ithread entry guard
(`output_stream_active`, ADR 0016) already tolerates a
stream_end racing a scheduled ithread; the reconfigure adds
no new race because it goes through the same end/begin
sequence the cdev close/open path is already verified
against.

### 5. Default and lifecycle

  - The default format remains 48 kHz / 16-bit / stereo.
    `cdev_open`'s `audiofs_stream_begin` call keeps using
    the default word, so F.3.b's open-starts-at-48k
    behavior is unchanged. A client that wants another rate
    opens, then issues `SET_FORMAT`.
  - The softc gains a `output_stream_format_word` and
    `output_stream_rate_hz` pair recording the active
    format (default 48000 / `0x0011` at attach). `GET_FORMAT`
    reads them; `configure_output_stream` writes the word
    from them.
  - On `stream_end` / cdev close the recorded format is left
    as-is; the next `cdev_open` starts at the default again
    (open does not inherit the previous session's
    negotiated rate in v1). This matches the "open is a
    fresh session" model and avoids surprising a new opener
    with a prior client's rate.
  - The F.1 state region's per-endpoint `current_format`
    (audiofs.c:1002) is updated to the negotiated word on
    reconfigure so the state file reflects reality.

### 6. What F.3.e does NOT do

  - No bit-depth or channel-count negotiation (Rejected B).
  - No kernel resampling or format conversion (ADR 0007).
  - No change to `cdev_open`'s open-starts-stream behavior
    (Rejected A).
  - No new wire-format or region-layout changes: the
    `format_change` event and its payload already exist in
    the F.2 schema.
  - No OSS-compatible ioctl encoding.
  - No mid-buffer (glitch-free) format switching: a format
    change flushes and restarts the stream.

## Rejected alternatives

**A. Decouple open from stream start.** Make `cdev_open`
passive (no `stream_begin`); start the stream on first
`write` or an explicit start ioctl, giving a natural idle
window in which `SET_FORMAT` configures the format before
any audio flows. Cleaner long-term and avoids the
flush-and-restart. Rejected for F.3.e because it changes
F.3.b's bench-verified open semantics (open currently brings
the stream up), which is a behavior change to an accepted
stage and widens the blast radius. The reconfigure model
reaches the same end state without disturbing F.3.b. If a
later stage revisits the cdev lifecycle, decoupling can be
reconsidered then.

**B. Negotiate bit depth and channels in v1.** Carry full
format negotiation now. Rejected because the target codec
advertises only 16-bit stereo, so the paths could not be
exercised on the bench, and because non-16-bit or non-stereo
formats change bytes-per-frame, which is assumed constant
(4) across the refill, position, and clock code. The ioctl
struct already carries `bits` and `channels`, so adding them
later is an opt-in extension, not a wire change.

**C. SET_FORMAT only when not streaming (EBUSY otherwise).**
Reject `SET_FORMAT` while the stream is active and require
the client to set format on an idle device. Rejected because
`cdev_open` auto-starts the stream, so no fd-accessible idle
state exists; this option is unusable without also adopting
A.

## Consequences

**Positive:**
  - Clients can select 32 kHz, 44.1 kHz, or 48 kHz playback,
    the real capability of the hardware, through a documented
    ioctl. semasound (F.5) gets the surface it negotiates
    through.
  - Zero blast radius on the hot paths: frame size stays 4
    bytes, so refill, position, and the F.4 clock are
    untouched. The clock republishes the negotiated rate for
    free.
  - Reuses the existing stream_end / stream_begin lifecycle
    and the existing `format_change` event; no new hardware
    or schema code.

**Negative:**
  - A format change is a stop/start with a ring flush, so
    in-flight buffered audio is dropped and there is a brief
    gap. This is acceptable for a deliberate format change
    and is documented; glitch-free switching is not a goal.
  - `SET_FORMAT` from ioctl context performs a hardware
    reprogram while a writer may be active. The locking
    reuses the verified close/open interlock, but the
    reconfigure path is new and must be bench-checked for
    writer races (see bench plan).

**Reversible:**
  - Fully. The default stays 48 kHz; a client that never
    calls `SET_FORMAT` sees exactly F.3.b behavior. Reverting
    F.3.e restores the `ENOTTY` ioctl stub and the hardcoded
    format with no wire-format impact.

## Closure criteria

F.3.e closes when:

  1. `AUDIOFS_IOC_GET_FORMAT` on an open `/dev/audiofs0`
     returns rate 48000, bits 16, channels 2, the `0x0011`
     word, and a `supported_rates` mask matching the DAC's
     advertised set (32000|44100|48000 on the bench).
  2. `AUDIOFS_IOC_SET_FORMAT` to 44100 reconfigures: a
     `clock_dump` shows `sample_rate=44100`, `samples_written`
     continues to advance monotonically with no regression
     across the change (F.4 interaction), and audible pitch
     is correct.
  3. `SET_FORMAT` to 32000 likewise reconfigures and plays at
     correct pitch.
  4. `SET_FORMAT` back to 48000 reconfigures cleanly.
  5. `SET_FORMAT` to the current rate returns 0 and does not
     restart the stream (no spurious `format_change` event,
     no audible gap).
  6. `SET_FORMAT` to an unadvertised rate (e.g. 96000) or to
     bits != 16 / channels != 2 returns `EINVAL` and leaves
     the stream running unchanged at the prior rate.
  7. Each reconfigure emits exactly one `format_change`
     event, observed via `audiofs_events_dump`, with correct
     `old_format` / `new_format` / `new_rate_hz`.
  8. The F.1 state file's `current_format` reflects the
     negotiated word after a change.
  9. `dmesg` shows no panic, no WITNESS, no trap across a
     sequence of reconfigures interleaved with active writes.
 10. Operator marks F.3.e `[x]` on `pgsd-bare-metal`.

## Bench test plan

Dev-side first: rebuild audiofs.ko; confirm `clock.zig` and
the other zig suites still pass (unaffected); build a small
`setfmt` helper or extend `playtone` to issue
`SET_FORMAT` before/while writing.

On the bench, in order:

  1. `git pull`; `cd audiofs && sudo ./build.sh all`.
  2. `sudo kldload audiofs`; open the device and
     `GET_FORMAT`: expect 48000 / 16 / 2 and
     supported_rates = 32000|44100|48000.
  3. Play a tone, `SET_FORMAT` 44100 mid-stream, continue
     playing. Verify audible pitch correct, `clock_dump`
     shows 44100 and monotonic `samples_written`, and one
     `format_change` event in `audiofs_events_dump`.
  4. Repeat for 32000, then back to 48000.
  5. `SET_FORMAT` to current rate: expect no event, no gap.
  6. `SET_FORMAT` 96000 and a 24-bit request: expect
     `EINVAL`, stream unchanged.
  7. Interleave `SET_FORMAT` with continuous writes from a
     second thread; verify no panic, no WITNESS, no torn
     stream, `dmesg` clean.
  8. `kldunload`; confirm clean detach (no regression of the
     F.4 criterion-9 result).

## References

  - ADR 0007: physics-only / native-format-only kernel
    constraint.
  - ADR 0011 (F-stage reconciliation): F.3.e placement and
    the "negotiate through F.3.b, native-only" policy.
  - ADR 0015 (F.3.b): reserved the GET_FORMAT / SET_FORMAT
    ioctls and the v1 hardcoded-format / 4-bytes-per-frame
    wire contract this stage extends.
  - ADR 0016 (F.3.c): the position counter and ithread
    active-guard the reconfigure relies on.
  - ADR 0018 (F.4): the clock writer, which republishes the
    negotiated rate at each stream_begin.
  - `shared/AUDIO_EVENTS.md` and `audiofs_events.h`: the
    `format_change` event (type 4) and its payload.
  - `audiofs.c`: the hardcoded format constant
    (`AUDIOFS_FMT_48KHZ_16BIT_STEREO`, line 233), the
    stream_begin validation (4999), the configure write
    (4406), the cdev ioctl stub (5602), and the DAC
    capability accessors (3883, 3901).

## Revision history

  - 2026-06-01: first draft. Scope set by design review:
    rate-only negotiation (32k/44.1k/48k, 16-bit stereo
    fixed) with SET_FORMAT reconfiguring the running stream
    (flush + stream_end + stream_begin), per the two scope
    decisions taken before drafting. Native-only per ADR
    0007; ioctl numbers ('A',1 GET / 'A',2 SET) allocated
    here; reuses the existing format_change event and the
    F.4 rate republication.
  - 2026-06-01: bench-verified on pgsd-bare-metal. The
    f3e_format_test.sh harness passed all automatable
    criteria (24/24): GET and the DAC supported-rate mask
    (criterion 1); mid-stream reconfigure to 44100 and to
    32000 with the clock flipping rate, samples_written
    monotonic across the change, and one decoded
    format_change each (criteria 2, 3, 7); the in-open
    cycle 44100 -> 48000 -> 32000 including the reconfigure
    back to the 48 kHz default, three events (criterion 4);
    the same-rate no-op with no event (criterion 5); the
    unadvertised-rate, non-16-bit, and non-stereo requests
    all rejected with EINVAL and the stream left unchanged,
    no event (criterion 6); and dmesg clean (criterion 9).
    Pitch drop at each switch confirmed aurally (criteria
    2, 3). Clean detach from a post-reconfigure state
    verified by kldunload plus a clock_integrity.sh re-run,
    which also reconfirmed F.4 (criterion 8). Implementation
    needed no bench fixes: the hda_reg.h 32 kHz/44.1 kHz
    rate masks were named as assumed and the build was clean
    on first compile. New tooling: setfmt (GET/SET/--seq
    ioctl exerciser), a format_change decode added to
    audiofs_events_dump, and the f3e_format_test.sh harness.
