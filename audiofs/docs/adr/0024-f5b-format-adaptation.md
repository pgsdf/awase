# 0024 F.5.b: format adaptation, resampling, and the rate-correcting predictor

## Status

Accepted, 2026-06-02 (ratified same day as proposed). Closed,
2026-06-04: all ten closure criteria verified on pgsd-bare-
metal and the operator marked F.5.b complete. Decision 1
amended to session-opener semantics under the Stage 2 ruling
(see Decision 1 and the revision history). First
implementation increment was the windowed-sinc resampler as a
standalone, signal-tested component (closure criterion 4),
before it was wired into the mixer, since ADR notes the kernel
is best verified independently of integration.

Second sub-milestone of F.5 (semasound), scoped under ADR
0020. Builds on F.5.a (ADR 0021, the mixer core, closed and
bench-verified). Inherits ADR 0020's six binding constraints
and does not re-argue them. Takes ADR 0019 (F.3.e format
negotiation) and ADR 0007 (the physics/semantics boundary,
specifically the clock/mix seam) as normative inputs.

## Context

F.5.a delivered the mixer core under one deliberate
simplification: clients present the canonical format
(48000 Hz, 16-bit, stereo) and anything else is rejected. At
the canonical rate with no resampler in the path, two
properties held for free. Each client's sample stream maps
1:1 to output samples, so no conversion is needed; and
audiofs blocking-write backpressure paces the single output
stream, so semasound is structurally locked to the hardware
rate and the ADR 0007 rate-correction requirement is
satisfied by construction (no explicit drift handling needed,
because there is no resampling ratio to drift).

F.5.b removes that simplification. It is the milestone that
introduces resampling, non-native-rate clients, per-client
adaptive ratios, and hardware-rate election. That is exactly
where ADR 0007's clock/mix seam stops being free and becomes
something that must be engineered: the moment a resampling
ratio enters the path, a fixed nominal ratio (e.g.
48000/44100) drifts against real crystal differences between
the client's source clock and the hardware clock, and a fixed-
ratio converter would walk its client ring from steady-state
to underflow over time. ADR 0007's "rate correction, not
position correction" is the normative fix and the normative
constraint, and F.5.b is where it is first implemented and
exercised rather than merely stated.

Binding inputs, restated as constraints this ADR operates
under and does not relitigate:

  - audiofs is native-only (ADR 0007). All resampling and
    format conversion is semasound's, in userland. The kernel
    never converts.
  - Hardware formats are exactly {32000, 44100, 48000} Hz,
    16-bit, stereo, selected through the F.3.e SET_FORMAT
    ioctl (ADR 0019). There is no other output format.
  - Resampling quality is semantic policy and lives in
    semasound (ADR 0007). The clock/mix seam (ADR 0007: rate
    correction, not position correction) is normative.

## Decisions

### 1. Hardware-rate election: single-client native passthrough, otherwise 48 kHz

When exactly one client is active and its rate is one of the
three hardware rates, elect that rate so the client plays
bit-exact with no resampling. In all other cases, two or more
active clients, or a lone client at a non-hardware rate, elect
48000 Hz and resample every client to it.

Rationale. Election only avoids resampling for a client whose
rate matches the elected hardware rate; with mixed rates the
hardware runs one rate and the rest resample regardless, so
election buys nothing in the mixed case and is not worth
contorting for it. It buys the most in the single-client case,
which is also the most common real case (a lone music player
at 44.1k), so optimizing exactly that case is the right
target. 48 kHz is the mixed-case default because it is the
canonical rate, the highest-quality common denominator, and
the rate F.5.a already drove.

Tradeoff. This introduces hardware-rate changes at the
1-to-2-client boundary, governed by Decision 2. The rejected
alternative, pin 48 kHz always, removes all switching but
forces resampling on the lone-44.1k-player case, the one case
where avoiding it matters most. The chosen policy makes the
common case perfect and the mixed case merely correct.

Amended (2026-06-04, operator ruling): session-opener
semantics. Under the Stage 2 realization (election only on
the 0-to-1 transition), the electing set is always exactly
one client, so the "two or more active clients" branch above
is structurally unreachable and the policy is restated as:
the session rate is elected for the session-OPENING client
(its rate if it is a hardware rate, else 48000); every later
joiner is resampled to the session rate for the duration of
the overlap; no live client ever observes a hardware-rate
change. 48 kHz multi-client operation therefore arises when
the opener is at 48 kHz or at a non-hardware rate. A
44.1k-opened multi-client session mixes at 44100, which is
audio-correct and consistent with Decision 2's overlap
semantics. The rejected alternative, a pending-election
mechanism to preserve the literal multi-client-48k wording,
would add state and testing surface solely to satisfy a
sentence superseded by the ratified architecture.

### 2. SET_FORMAT only across silence

semasound issues a SET_FORMAT hardware-rate change only at an
output idle boundary: when the output transitions idle to
active (elect for the incoming client) or active to idle. It
never changes the hardware rate while audio is actively
mixing. A re-election that would change the rate while a
stream is playing is deferred until the output next goes idle.

Rationale. Every hardware reconfiguration then happens when
nothing is playing, so it is inaudible and never disturbs in-
flight mixer buffers. This pairs with Decision 1: election is
evaluated only at idle boundaries, not continuously.

Tradeoff. A 44.1k client that joins a running 48k stream is
resampled to 48k for the duration of the overlap and only
obtains its native rate once it is alone again and the output
has cycled through idle. The rejected alternative, chase the
client's rate mid-mix, is audible (a hardware rate switch
under live audio) and complex (reconfiguring the mixer mid-
flight) for no real benefit. Deferring to the idle boundary is
the correct tradeoff.

Stage 2 realization (ratified 2026-06-04). Hardware-rate
election occurs only on transitions from zero active clients
to one active client. Once admitted, a client's resampler
configuration is immutable for the lifetime of that client
connection. The idle boundary of this decision is therefore
the next idle-to-active SESSION transition after the system
has become idle: a client never spans an election, so no
reader-side rebuild protocol, rate-generation tracking, or
mid-life ring flush exists, and the single-writer resampler
ownership of Stage 1 is preserved intact. When the active set
drops to zero the hardware is left at its current rate (lazy
rest state); election runs on the next 0-to-1 admission, so a
repeated lone native-rate client incurs zero switches after
its first session and the device never flaps. The externally
visible guarantees are unchanged: exactly one supported-rate
client receives native passthrough at its rate; multi-client
operation runs at 48 kHz; re-election is deferred to a safe
boundary; each election issues at most one SET_FORMAT.

### 3. Input scope: arbitrary 16-bit rate, mono or stereo

v1 accepts clients at an arbitrary input rate (validated
against a sane bounded set; at minimum the common rates
8000/11025/16000/22050/32000/44100/48000), 16-bit PCM only,
mono or stereo. Mono is converted to stereo by channel
duplication. 24-bit, float, and multichannel (>2) inputs are
rejected in v1 with a clear status byte and deferred.

Rationale. Mono-to-stereo is near-free (duplication) and
covers a large real class (system sounds, voice, many games),
so it earns inclusion. 24-bit and float pull in dithering on
the way down to 16-bit, a separate quality-policy concern;
multichannel pulls in downmix matrices and LFE handling, a
project of its own. audiofs is 16-bit-stereo-native, so
rejecting these rare inputs with an honest status is cheap and
correct for v1.

Tradeoff. A 24-bit or 5.1 client is refused rather than
converted in v1. Given the native format and the rarity of
such clients, clear rejection is preferable to a half-built
conversion path. These remain candidates for a later
sub-milestone.

### 4. Resampler: windowed-sinc (polyphase) from the start

The resampler is a windowed-sinc polyphase converter,
implemented as the intended production design in this
milestone. No interim linear-interpolation implementation.

Rationale. ADR 0007 identifies resampling quality as semantic
policy placed in semasound; F.5.b is the format-adaptation
milestone, so the resampler ratified here is the one intended
to be kept. A temporary linear implementation would require a
second design and a second full verification cycle for no
lasting benefit. Latency is not the obstacle that might
otherwise argue for a cheaper first pass: a 32-to-64-tap
polyphase kernel adds well under a millisecond, negligible
against the audiofs output ring (~85 ms at the ADR 0023 depth
of 4 fragments), so CPU is the only cost and it is modest for
the handful of streams a desktop mixes. Implementing the
production kernel directly is the honest path.

Tradeoff. The resampler's plumbing (ratio tracking, polyphase
phase accumulation, the buffering that feeds the mixer, and
the rate-correction loop of Decision 5) is more demanding to
validate against a sinc kernel than against a trivially-
checkable linear one. This is accepted: the kernel is verified
by signal tests (a swept sine resampled across the hard
44.1-to-48 ratio, checked for spectral image rejection and
SNR) independently of the integration tests, so the difficulty
is contained to one well-bounded component.

### 5. The rate-correcting predictor (the ADR 0007 clock/mix seam)

This is the core of the milestone, not a deferred hook.
semasound maintains a free-running local playback model from
its own buffer accounting and uses kernel-clock observations
only to estimate and correct the long-term drift *rate*, never
to apply per-observation *position* corrections. The
correction acts on the resampling ratio: each client's
effective ratio is the nominal rate ratio trimmed by a slow,
bounded, clamped controller driven by a drift estimate, so the
hardware clock constrains the mixer's long-term slope without
scheduling it. (ADR 0007's hard requirement, verbatim in
intent: "rate correction, not position correction.")

Design shape (the control form is fixed here; tuning constants
are an implementation/bench matter):

  - Per-client nominal ratio = client_rate / elected_hw_rate.
  - A drift estimator observes the client ring's long-term
    fill trend (and, for the elected/output stream, the F.4
    kernel clock's slope against semasound's local sample
    count) over a window long enough to average out individual
    read jitter, satisfying ADR 0007's requirement that
    instantaneous observation latency must not affect
    correctness.
  - A proportional (optionally PI) controller trims the
    effective ratio by a small, hard-clamped fraction of the
    nominal (clamp on the order of a fraction of a percent, far
    inside audible-pitch territory), so corrections are smooth
    and inaudible and the loop cannot run away.
  - The controller adjusts *rate*; it never drops, inserts,
    duplicates, or skips samples to resynchronize. Position
    correction is forbidden by ADR 0007 and excluded by
    construction here.

Scope of what must be exercised for closure. The predictor
must be real and demonstrated to correct genuine drift, not a
fixed-ratio converter wearing a controller that never acts.
v1 is not required to support arbitrary free-running network
sources; closure may be demonstrated with a controlled drift
source (a test client whose effective sample rate is
deliberately offset from nominal by a known ppm, or a clock
whose slope is perturbed), showing the predictor estimates the
imposed drift and trims the ratio to hold the client ring
stable over a duration long enough that a fixed-ratio
converter would have underflowed or overflowed. Well-behaved
blocking clients (paced by socket backpressure) drift little
and are the normal case; the controlled drift source proves
the predictor works where it matters.

Rationale. F.5.b is the first milestone where resampling and
non-native rates make the ADR 0007 seam real. Reducing it to a
future hook would ship a fixed-ratio converter that drifts to
xrun on long streams and would leave the normative requirement
unimplemented in the exact milestone that introduces the need.
The predictor is therefore part of the architecture,
implementation, and bench verification of F.5.b.

## Rejected alternatives

  - Pin the hardware at 48 kHz permanently (reject Decision
    1's election). Simpler, no switching, but forces resampling
    on the most common single-client case. Rejected for the
    quality cost in exactly the case that matters most.
  - Chase the client rate with SET_FORMAT mid-mix (reject
    Decision 2). Audible and complex for no benefit. Rejected.
  - Linear interpolation first, sinc later (reject Decision 4).
    Two designs and two verification cycles for a temporary
    result ADR 0007 says should be the kept production policy.
    Rejected per the operator's decision to ratify the intended
    resampler.
  - Fixed-ratio resampler with the predictor deferred to a
    later sub-milestone (reject Decision 5). Ships a converter
    that drifts to xrun and leaves the normative ADR 0007 seam
    unimplemented in the milestone that creates the need.
    Rejected.
  - Position correction (read the clock, jump to the reported
    sample). Explicitly forbidden by ADR 0007: it relocates
    scheduling jitter to the sampling boundary rather than
    removing it. Excluded by construction.
  - 24-bit/float/multichannel input in v1. Pulls in dithering
    and downmix matrices, each its own concern. Deferred, not
    rejected in principle.

## Consequences

  - semasound gains a per-client resampling stage between the
    client ring and the mixer, a drift estimator and ratio
    controller per client, and a hardware-rate election step
    evaluated at output idle boundaries that drives F.3.e
    SET_FORMAT.
  - The ADR 0007 clock/mix seam is implemented and bench-
    exercised for the first time. After F.5.b, "rate
    correction, not position correction" is a verified
    property, not just a stated requirement.
  - semasound can serve arbitrary-rate 16-bit mono/stereo
    clients, the capability gap that has kept it from standing
    in for semaaud. It still cannot (by scope) serve 24-bit,
    float, or multichannel clients; those and full target
    routing (F.5.c) remain before parity.
  - The single-client passthrough path must be bit-exact:
    when elected to a client's native rate, the resampler is
    bypassed entirely (ratio 1:1 is not "resample by 1.0", it
    is no resampling), so a lone native-rate client is
    unchanged from F.5.a behavior.
  - audiofs is untouched. F.5.b is entirely within semasound
    plus use of the existing F.3.e SET_FORMAT and F.4 clock
    interfaces.

## Closure criteria

  1. A single client at each hardware rate (32k/44.1k/48k)
     plays cleanly with the hardware elected to that rate and
     the resampler bypassed (bit-exact passthrough verified).
  2. A single client at a non-hardware rate (e.g. 22050) plays
     cleanly, resampled to 48 kHz.
  3. Two clients at different rates (e.g. 44100 + 48000) mix
     cleanly with the hardware at 48 kHz and both resampled as
     needed; no hum, underflow counters flat (the F.5.a/ADR
     0023 audible-mix bar, now with resampling in the path).
  4. Resampler signal quality: a swept sine resampled across
     44.1-to-48 shows image rejection and SNR meeting a stated
     bar (the sinc kernel verified independently of mixing).
     VERIFIED 2026-06-02 (resampler_quality harness, bar SNR
     >= 60 dB / image >= 60 dB down, TAPS=32): all seven rate
     pairs pass. SNR by case: 48->48 86.7 dB; 48->44.1 120.0 dB
     (1k and 6k); 44.1->48 75.8 dB (1k), 60.6 dB (6k); 32->48
     73.6 dB; 22050->48 69.9 dB. The 44.1->48 at 6 kHz result
     (60.6 dB) is the floor and a legitimate pass; 32 taps is
     adequate for 16-bit playback and was kept rather than
     widened purely for margin.
  5. Hardware-rate election (as amended under Decision 1,
     session-opener semantics): a lone hardware-rate opener is
     elected natively with bit-exact passthrough; a mid-session
     joiner triggers NO SET_FORMAT and is resampled to the
     session rate; a non-hardware-rate opener elects 48000;
     every SET_FORMAT occurs at a session boundary across
     silence, never mid-mix, at most one per election.
     VERIFIED 2026-06-04 (f5b_election harness): lone 44.1k
     opener elected with one SET_FORMAT, accepted at hw=44100
     [passthrough]; 48k joiner mid-session caused zero
     SET_FORMATs and resampled to 44100; 22050 opener elected
     48000 with one SET_FORMAT and a 44.1k joiner resampling
     to 48000; at-rate session was a no-op (zero SET_FORMATs);
     switch-back issued exactly one. Original wording's
     "second client triggers SET_FORMAT to 48 kHz" was ruled
     structurally unreachable under the ratified 0-to-1
     election and amended rather than preserved via added
     machinery (see Decision 1 amendment).
  6. Mono client is duplicated to stereo correctly.
  7. Non-canonical-but-unsupported formats (24-bit, float,
     >2 channels) are rejected with a clear status; broker
     survives.
     VERIFIED 2026-06-04 (f5b_reject harness): format codes 2
     and 3 (24-bit/float stand-ins; any non-16-bit code hits
     the same check), channels 4 and 0, and rate 96000 all
     rejected with STATUS_REJECTED + error line (client exit
     2); a good client played clean immediately after, broker
     survived. Note: the F.5.a-era --badrate (44100) became an
     ACCEPTED rate under F.5.b; the flag was repurposed to
     declare 96000 to preserve its intent.
  8. **Rate correction (the ADR 0007 seam).** Against a
     controlled drift source (a client offset from nominal by
     a known ppm, or a perturbed clock slope), the predictor
     estimates the imposed drift and trims the resampling ratio
     to hold the client ring stable over a duration long enough
     that a fixed-ratio converter would have under/overflowed.
     Verified to be rate correction, not position correction:
     no sample drops/inserts occur; the correction appears as a
     smooth ratio trim.
     VERIFIED 2026-06-04 (two-hour soak, default envelope,
     +1000 ppm drifting 44100 client): steady-state mean trim
     1002-1006 ppm, trim std flat at 154-158 ppm across all
     buckets, fill bounded 35-50% for the full run; a fixed
     ratio would have walled in ~3 minutes. Rate-only by
     construction (no drop/insert path exists). Full evidence
     in the revision history.
  9. No fd/memory leak across client connect/disconnect and
     rate-election cycles.
     VERIFIED 2026-06-04 (f5b_election harness, case F): fd
     count identical (11) before and after 24 election cycles
     (44100/48000 alternating, each a connect, SET_FORMAT, and
     disconnect), RSS delta 0 KiB, broker alive throughout.
 10. Operator marks F.5.b `[x]`.
     VERIFIED 2026-06-04: operator confirmed criterion 10 and
     marked F.5.b complete after reviewing the final state
     (criteria 1-9 verified; ADR, implementation, and bench
     evidence aligned).

## References

  - ADR 0007 (physics/semantics boundary): the clock/mix seam,
    "rate correction, not position correction" (normative);
    resampling quality as semantic policy in semasound.
  - ADR 0019 (F.3.e): SET_FORMAT, the three hardware rates,
    16-bit stereo fixed.
  - ADR 0020 (F.5 decomposition): F.5.b's scope and the
    binding constraints.
  - ADR 0021 (F.5.a): the mixer core this builds on; the
    canonical-only simplification F.5.b removes.
  - ADR 0018 (F.4): the kernel clock the predictor observes
    for slope.

## Revision history

  - 2026-06-02: first draft. Five decisions: single-client
    native passthrough with 48k mixed-case fallback;
    SET_FORMAT only across silence; arbitrary 16-bit mono/
    stereo input with 24-bit/float/multichannel deferred;
    windowed-sinc resampler from the start (no interim linear);
    and the rate-correcting predictor implemented and bench-
    exercised as part of the milestone (not a deferred hook),
    closure demonstrable against a controlled drift source.
  - 2026-06-02: first implementation increment landed. The
    windowed-sinc resampler (resampler.zig, TAPS=32, PHASES=
    256, Hann, per-phase unity-DC normalization, streaming
    position carry, runtime ratio trim as the predictor hook)
    and a standalone signal-quality harness (resampler_quality
    .zig) committed. Criterion 4 VERIFIED on bench (see above):
    all seven rate pairs clear the 60 dB SNR bar at TAPS=32.
    The harness measures SNR via least-squares tone fit at the
    exact frequency over whole cycles (an earlier Goertzel-
    based and bin-snapping measurement gave false failures that
    were measurement bugs, not resampler defects; the fix was
    validated in a standalone C cross-check before bench).
    TAPS kept at 32 per the operator: criterion is met and the
    architectural risk is the predictor, not FIR length.
  - 2026-06-03: per-client resampling (Stage 1) landed and
    criteria 1/2/3/6 verified live (passthrough, 44100, 22050,
    mono->stereo, mixed-rate mix all clean). Then the drift
    controller (criterion 8) underwent a structural
    identification on the bench that corrected the design shape
    sketched in decision 5 above. Findings, each from a clean
    test:
      - The output-vs-clock slope is structurally blind to
        client drift: the mixer's output is hardware-paced by
        audiofs blocking-write backpressure, so semasound's
        output frame rate equals the kernel clock rate by
        construction and their ratio carries no drift signal.
        The drift is observable only in each client's ring-fill
        trend (frames pushed by the reader vs popped by the
        mixer). The estimator and trim are therefore PER-CLIENT
        and do not use the kernel clock at all; the F.4 clock
        reference in decision 5 does not apply to the realized
        design.
      - The control law is rate matching, not level targeting
        (ADR 0007): it drives the ring-fill TREND (rate of
        change of occupancy) toward zero, never toward a fill
        level.
      - Measurement noise is bounded chunk-boundary
        quantization: a fixed ~1-chunk (1024-frame) per-window
        uncertainty, ~5000 ppm at a 5s window, falling inversely
        with window length (measured directly via a window-
        length sweep). An EMA on the rate error (tau term)
        suppresses it.
      - Pure rate correction does NOT bound buffer occupancy:
        with rate correction alone, fill executes an unbounded
        random walk (variance grows ~linearly with time, std
        ~sqrt(t), confirmed over a 96x time range). A weak
        continuous level term (eps * (fill - center)) is
        therefore architecturally necessary, converting the
        diffusive (Brownian) occupancy into mean-reverting
        (Ornstein-Uhlenbeck). It is a guardrail, not a setpoint:
        near center it contributes nothing.
      - Acquisition is controller-limited: a perfect-measurement
        test showed the original low proportional gain took
        ~795s to acquire a 1000 ppm offset vs a ~186s ring time-
        to-wall, so a real proportional path is required.
      - Component logging proved the residual steady-state trim
        variance is dominated by the level term (it injects the
        per-window fill quantization noise), not the
        proportional path. Reducing eps trades restoring
        authority for variance. A future refinement (documented,
        not implemented) is to feed the level term a low-pass-
        filtered fill, decoupling restoring authority from
        variance; not needed to meet criterion 8 today.
    Realized control law: trim = clamp(kp*ema(rate_err) + integral
    + eps*(fill-0.5)). Bench-validated default envelope (the
    smallest config that keeps fill bounded during acquisition
    and corrected in steady state under the measured noise):
    KP=0.2, KI=0.05, EPS=0.005, EMA_TAU_S=120, WINDOW_MS=5000;
    all env-overridable. At this config: trim mean ~1100 ppm
    against a +1000 ppm injected drift (convergence within
    ~100 ppm), trim std ~150 ppm (inaudible, ~0.015% pitch),
    fill bounded ~8-57% with no wall. Constants found by bench
    system-ID, not by the C model (which did the structural
    identification but proved untrustworthy for quantitative
    tuning due to clamp-saturation and metric artifacts).
  - 2026-06-04: criterion 8 VERIFIED. Two-hour soak at the
    compiled-in default envelope against a +1000 ppm drifting
    44100 client (1439 five-second windows, analyzed in eight
    time buckets). Bucket 1 contains the expected acquisition
    transient. Buckets 2-8 (steady state, ~1.75 h): mean trim
    1002-1006 ppm against the injected 1000 (convergence within
    ~5 ppm), trim std flat at 154-158 ppm across every bucket
    (no variance growth: the diffusion is gone), fill bounded
    35-50% throughout. One noted observation: a slight monotone
    fill creep (~3% over the steady-state span), mechanism
    understood -- mean trim sits ~4 ppm above the injected
    drift, draining fill at the rate observed; the level term's
    restoring pull grows as fill falls, so the creep is the
    self-limiting tail of convergence toward the loop's
    equilibrium (Ornstein-Uhlenbeck mean reversion), not
    diffusion. Trim std flat across buckets confirms no slow
    destabilization. Rate correction held a ring stable for two
    hours that a fixed-ratio converter would have walled in
    ~3 minutes; correction is rate-only by construction (no
    sample drop/insert path exists).
  - 2026-06-04: criterion 7 VERIFIED (see inline annotation).
    Rejection surface exercised end to end: unsupported format
    codes, channel counts, and rates each rejected with a clear
    status; broker survived and served a good client cleanly
    afterward. Remaining for closure: criterion 5 (hardware-
    rate election, Stage 2), criterion 9 (no leak across
    connect/disconnect and election cycles, to be verified
    during Stage 2 testing), criterion 10 (operator mark).
  - 2026-06-04: Stage 2 design ratified (see Decision 2's
    "Stage 2 realization" and criterion 5's realization note):
    election only on the 0-to-1 active-client transition;
    per-client resampler configuration immutable for the
    connection lifetime; lazy idle rest state. Chosen over a
    data-silence-boundary design specifically because a client
    can then never span an election, preserving the Stage 1
    single-writer resampler ownership with no rebuild protocol,
    generation tracking, or mid-life ring flush. Kernel side
    already complete: ADR 0019's SET_FORMAT reconfigures the
    live stream (ring flush, monotonic clock) and was bench-
    verified under F.3.e.
  - 2026-06-04: Stage 2 election bench-verified (f5b_election
    harness, all cases): lone 44.1k opener elected natively
    with bit-exact passthrough at hw=44100; a 48k mid-session
    joiner caused NO SET_FORMAT and resampled to 44100
    (Decision 2 overlap); a 22050 opener elected 48000 with a
    44.1k joiner resampling to it; the at-rate no-op issued
    nothing; the switch-back issued exactly one SET_FORMAT.
    Criterion 9 VERIFIED in the same run (see inline). Two
    harness-side lessons recorded: sessions need a settling
    interval (~1.5 s) before the active set is genuinely empty
    (ring drain + reap), and three earlier all-negative runs
    were stale-binary artifacts, after which the harness gained
    a preflight that refuses to measure a binary or broker that
    predates Stage 2. Criterion 5's verification is HELD
    pending the operator's ruling on the Decision 1 wording:
    under 0-to-1-only election the "two or more clients ->
    48000" branch is unreachable (the session rate is the
    OPENER's election; joiners resample to it), so either
    Decision 1 and criterion 5 are amended to session-opener
    semantics, or a pending-election mechanism is added to
    preserve the literal multi-client-48k guarantee.
  - 2026-06-04: criterion 5 VERIFIED under the operator's
    ruling for session-opener semantics. Decision 1 amended
    (see "Amended" paragraph there) and criterion 5 reworded to
    match the ratified architecture rather than preserved via a
    pending-election mechanism, which would have added state
    and testing surface solely to satisfy wording superseded by
    the 0-to-1 election invariant. Verification rests on the
    f5b_election evidence already recorded. No further Stage 2
    implementation work. Remaining for F.5.b closure: criterion
    10 (operator marks F.5.b done).
  - 2026-06-04 (operator ruling, recorded during F.5.e
    verification): native-passthrough clients are
    INTENTIONALLY UNCORRECTED. Bit-exactness and rate
    correction are mutually exclusive properties; Stage 2's
    native election (ADR 0025) exposed that fact but did not
    create it. In passthrough mode, fast-clock drift is
    bounded by ring backpressure, manifesting as additional
    latency up to the established bound (~370 ms, one ring),
    while slow-clock drift follows the existing F.5.a
    shortfall path. Those behaviors are explicit, observable,
    and consistent with the current invariants. Automatic
    resampler insertion to restore correction is REJECTED:
    it would violate the per-connection resampler-immutability
    invariant and silently break the bit-exact guarantee that
    passthrough mode exists to provide; if a client has
    selected native passthrough, the system does not alter
    the stream behind its back. Telemetry-only fill-trend
    reporting for passthrough clients is recorded as a
    potential future observability enhancement (it improves
    operator visibility without changing stream semantics),
    not a requirement. The drift soak harness accordingly
    uses a 48k anchor opener so its drift client exercises
    the corrected (resampled) path.
