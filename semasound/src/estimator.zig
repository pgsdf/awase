// F.5.b output-domain drift estimator (ADR 0024 Decision 5; ADR 0007 seam).
//
// This is the OUTPUT-DOMAIN controller's sensor, not a per-client drift
// tracker. It measures one scalar for the whole system: how fast semasound
// produced output frames versus how fast the F.4 hardware clock actually
// advanced, over an estimation window. That scalar is the output-domain
// slope error fed to predictor.step. The resulting shared trim is applied to
// every active client's resampler as base_ratio * (1 + drift_correction);
// the drift correction is a property of system clock alignment, uniform
// across clients, NOT estimated per client. True per-stream drift estimation
// is deferred to F.5.c, when routing introduces independent stream domains
// (ADR 0020 sequences routing after format adaptation). Until then clients
// are folded into the single elected hardware-rate domain by resampling, so
// a per-client clock-anchored drift is not well defined and is not attempted.
//
// Cadence: the estimator runs on its OWN low-frequency loop, never driven by
// the mix loop (ADR 0007: the clock must not schedule the mixer). A window of
// order a second, stepped a few times per second, is far slower than the mix
// loop and ample for drift that moves over minutes. Sampling latency and
// jitter on any single clock read are irrelevant because the slope is
// differenced over the whole window.
//
// The slope error definition:
//   kernel_delta = clock.read() - clock_at_window_start   (hardware advanced)
//   local_delta  = frames_written - frames_at_window_start (system produced)
//   slope_error  = kernel_delta / local_delta - 1
// Positive slope_error means hardware outpaced local production (the system
// ran slow); the predictor responds by trimming the resampling ratio so the
// next window's production tracks hardware. The clock is the long-term slope
// authority (ADR 0007); local production is what we steer.

const std = @import("std");
const compat = @import("compat");
const predictor_mod = @import("predictor.zig");

fn envF64(name: []const u8, dflt: f64) f64 {
    const v = compat.args.getenv(name) orelse return dflt;
    return std.fmt.parseFloat(f64, v) catch dflt;
}

pub const Estimator = struct {
    pred: predictor_mod.Predictor,

    // Window anchors: cumulative bytes pushed by the client and popped by the
    // mixer, captured at window start.
    pushed_at_start: u64,
    popped_at_start: u64,
    have_anchor: bool,

    // Last computed values, for observability/health logging.
    last_rate_error: f64,
    last_trim: f64,
    // Raw measurement path, exposed for instrumentation (step 1 of the
    // criterion-8 noise characterization): the actual byte deltas the rate
    // error was derived from, so the chunk-boundary-noise hypothesis can be
    // verified against real numbers rather than inferred.
    last_pushed_delta: u64,
    last_popped_delta: u64,

    // EMA on the rate error (the tau / noise-shaping term of the control
    // envelope). The per-window rate measurement is dominated by bounded
    // chunk-boundary quantization noise (measured: ~1 chunk, ~5000 ppm at a
    // 5s window). The EMA averages the zero-mean boundary noise toward zero
    // while passing the persistent drift signal. alpha is derived from
    // SEMASOUND_EMA_TAU_S (seconds) and the actual window duration each step:
    // alpha = win_s / (tau_s + win_s).
    ema: f64,
    tau_s: f64,
    last_filtered_error: f64, // exposed for instrumentation

    pub fn init() Estimator {
        return .{
            .pred = predictor_mod.Predictor.init(),
            .pushed_at_start = 0,
            .popped_at_start = 0,
            .have_anchor = false,
            .last_rate_error = 0.0,
            .last_trim = 1.0,
            .last_pushed_delta = 0,
            .last_popped_delta = 0,
            .ema = 0.0,
            .tau_s = envF64("SEMASOUND_EMA_TAU_S", 120.0),
            .last_filtered_error = 0.0,
        };
    }

    /// Advance this per-client estimator by one window. Inputs are the client
    /// ring's cumulative flow counters sampled now: `total_pushed` (bytes the
    /// client's reader has put into the ring) and `total_popped` (bytes the
    /// mixer has taken). The difference of their deltas over the window is the
    /// production/consumption mismatch, i.e. the ring-fill TREND, which is the
    /// signal that actually reflects this client's drift. (The output-vs-
    /// hardware-clock slope is structurally blind to client drift, because the
    /// mixer's output is hardware-paced by backpressure; the meaningful signal
    /// lives in each client's producer/consumer imbalance.) Returns this
    /// client's multiplicative trim.
    ///
    /// This is rate matching, not level targeting (ADR 0007): we drive the
    /// rate error (the normalized trend) to zero, never toward a fill level.
    ///
    /// First call only anchors. Guard: if nothing was popped in the window
    /// (client idle or stalled), hold the trim; a zero consumption denominator
    /// carries no rate information.
    pub fn window(
        self: *Estimator,
        total_pushed: u64,
        total_popped: u64,
        fill_frac: f64,
        win_s: f64,
    ) f64 {
        if (!self.have_anchor) {
            self.pushed_at_start = total_pushed;
            self.popped_at_start = total_popped;
            self.have_anchor = true;
            return self.pred.currentTrim();
        }

        const pushed_delta = total_pushed -| self.pushed_at_start;
        const popped_delta = total_popped -| self.popped_at_start;

        self.pushed_at_start = total_pushed;
        self.popped_at_start = total_popped;
        self.last_pushed_delta = pushed_delta;
        self.last_popped_delta = popped_delta;

        // No consumption this window: nothing to match against, hold.
        if (popped_delta == 0) {
            return self.pred.currentTrim();
        }

        // Normalized rate error: how much more the client produced than we
        // consumed, relative to consumption. Positive => client running fast
        // (ring trending full) => trim up to consume faster.
        const rate_error =
            (@as(f64, @floatFromInt(pushed_delta)) -
            @as(f64, @floatFromInt(popped_delta))) /
            @as(f64, @floatFromInt(popped_delta));
        self.last_rate_error = rate_error;

        // EMA filter (tau term): suppress the bounded chunk-boundary noise
        // while passing the persistent drift. alpha from the actual window.
        // The EMA initializes to zero (no assumed drift) and builds up toward
        // the true rate, rather than seizing the first raw sample as its
        // starting value. Seizing the first sample lets a single noisy window
        // (the per-window noise is ~5000 ppm) poison the estimate for many
        // windows afterward; starting at zero is unbiased and acquires the
        // signal from below instead of decaying from a bad high sample.
        const alpha = win_s / (self.tau_s + win_s);
        self.ema = alpha * rate_error + (1.0 - alpha) * self.ema;
        self.last_filtered_error = self.ema;

        // Controller fed from the FILTERED error; level term from fill.
        self.last_trim = self.pred.step(self.ema, fill_frac - 0.5);
        return self.last_trim;
    }

    pub fn currentTrim(self: *const Estimator) f64 {
        return self.pred.currentTrim();
    }
};

// ---- synthetic estimator tests (ADR 0024 criterion 8, layer 1 bridge) ----
//
// These drive the estimator with a simulated client ring: the client pushes
// bytes at a rate offset by `ppm`, the mixer pops at the (hardware-paced)
// consumption rate scaled by the applied trim. When the trim matches the
// client offset, pushed and popped deltas align and the rate error goes to
// zero. No broker, mmap, or ring; pure loop closure.

const Sim = struct {
    ppm: f64,
    pushed: u64 = 0,
    popped: u64 = 0,
    // Bytes consumed per window at nominal. Large so per-window integer
    // truncation does not quantize the rate error in the test; the live
    // estimator handles low-drift resolution with its long window.
    block: u64 = 48_000_000,

    fn advance(self: *Sim, trim: f64) void {
        // Client pushes at its offset rate; mixer pops at the trimmed rate.
        // When trim == 1 + ppm/1e6, push and pop rates match.
        const pushed = @as(f64, @floatFromInt(self.block)) * (1.0 + self.ppm * 1e-6);
        const popped = @as(f64, @floatFromInt(self.block)) * trim;
        self.pushed += @intFromFloat(pushed);
        self.popped += @intFromFloat(popped);
    }
};

fn runSim(ppm: f64, windows: usize) Estimator {
    var est = Estimator.init();
    var sim = Sim{ .ppm = ppm };
    sim.advance(est.currentTrim());
    _ = est.window(sim.pushed, sim.popped, 0.5, 5.0); // anchor
    var i: usize = 0;
    while (i < windows) : (i += 1) {
        sim.advance(est.currentTrim());
        _ = est.window(sim.pushed, sim.popped, 0.5, 5.0);
    }
    return est;
}

test "estimator converges to cancel a +100 ppm client" {
    var est = runSim(100.0, 3000);
    try std.testing.expect(@abs(est.currentTrim() - (1.0 + 100e-6)) < 5e-6);
}

test "estimator converges to cancel a -200 ppm client" {
    var est = runSim(-200.0, 3000);
    try std.testing.expect(@abs(est.currentTrim() - (1.0 - 200e-6)) < 5e-6);
}

test "first window only anchors, returns neutral trim" {
    var est = Estimator.init();
    const t = est.window(1_000_000, 1_000_000, 0.5, 5.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), t, 1e-9);
}

test "no consumption in the window holds trim (client idle/stalled)" {
    var est = Estimator.init();
    _ = est.window(0, 0, 0.5, 5.0); // anchor
    // Client pushed but the mixer popped nothing this window: hold.
    const t = est.window(48000, 0, 0.5, 5.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), t, 1e-9);
}
