// F.5.b rate-correcting predictor (ADR 0024 Decision 5; ADR 0007 clock/mix
// seam). PURE CONTROL LAW: no I/O, no clock reads, no ring access. It is a
// function from observed (clock slope, ring fill) to a resampling ratio
// trim. Keeping it pure is deliberate, the same standalone-first discipline
// the resampler kernel used: the controller is verified in isolation against
// a simulated clock before any broker, socket, or scheduling noise enters.
//
// ADR 0007's requirement is normative and shapes the design:
//   - The F.4 kernel clock is the long-term authority on SLOPE. The
//     primary error term is clock-slope error: how fast the hardware
//     actually played versus how many frames semasound's local model
//     believes it produced, differenced over a window long enough that a
//     single jittery clock read cannot move the correction.
//   - Correction is expressed SOLELY as a resampling ratio trim. This
//     module's only output is a trim value; it has no actuator that could
//     drop, insert, duplicate, or skip samples. "Rate correction, not
//     position correction" is therefore structural here, not merely
//     asserted: there is no position-correcting code path to misuse.
//   - Ring fill is a SECONDARY guardrail, not the authoritative error.
//     Driving the loop primarily from ring occupancy would be a
//     queue-following design and would relocate scheduling jitter into the
//     correction. Ring fill only nudges the trim gently when it drifts
//     toward a boundary despite the slope correction, and is otherwise just
//     a health signal.

const std = @import("std");
const compat = @import("compat");

pub const Predictor = struct {
    // Three coupled coefficients, tuned as a stability envelope (not three
    // independent knobs), per the structural identification in ADR 0024's
    // criterion-8 investigation:
    //   kp  responsiveness: large enough to acquire a constant offset before
    //       the ring walls, bounded by noise amplification through the EMA.
    //   ki  integral: removes steady-state rate bias.
    //   eps STABILITY: the weak continuous level term. Pure rate correction
    //       lets fill diffuse (variance ~ t, proven); a small restoring pull
    //       toward mid-fill makes occupancy mean-reverting (Ornstein-Uhlenbeck
    //       instead of Brownian). Small relative to the P path so frequency
    //       correction stays primary and this is a guardrail, NOT level
    //       targeting / queue-following: near center it contributes almost
    //       nothing. (EMA tau lives in the estimator thread; it is the third
    //       envelope term, noise shaping.)
    kp: f64,
    ki: f64,
    eps: f64,

    integ: f64, // integral accumulator (in trim units)
    trim: f64, // current trim, multiplicative around 1.0
    clamp: f64, // total-trim clamp, +/-0.5%

    // Last component contributions, exposed for instrumentation: proving which
    // term drives trim variance (the proportional path vs the level term)
    // before changing structure. Each is the term's additive contribution to
    // the pre-clamp trim, in trim-fraction units.
    last_p: f64,
    last_i: f64,
    last_level: f64,

    pub fn init() Predictor {
        // Defaults are the bench-validated F.5.b envelope (criterion 8): the
        // smallest configuration that keeps fill bounded during acquisition
        // and corrected in steady state under measured chunk-boundary noise.
        // KP low (the proportional path is a minor variance source); KI modest;
        // EPS=0.005 is the weak level term -- necessary to prevent occupancy
        // diffusion, and the dominant residual trim-variance source, so kept
        // as small as the restoring-authority requirement allows. All remain
        // env-overridable for further system-ID.
        return .{
            .kp = envF64("SEMASOUND_KP", 0.2),
            .ki = envF64("SEMASOUND_KI", 0.05),
            .eps = envF64("SEMASOUND_EPS", 0.005),
            .integ = 0.0,
            .trim = 1.0,
            .clamp = 0.005,
            .last_p = 0.0,
            .last_i = 0.0,
            .last_level = 0.0,
        };
    }

    /// One control step.
    ///   rate_error: per-client ring-trend (frames_pushed - frames_popped) /
    ///               frames_popped over the window. Positive = client fast.
    ///   fill_dev:   fill fraction minus center (e.g. fill_frac - 0.5), the
    ///               input to the weak level term. NOT a setpoint the loop
    ///               drives to; only a gentle restoring pull that bounds the
    ///               otherwise-diffusive occupancy.
    /// Returns the new multiplicative trim.
    ///
    /// Sign: positive rate_error (client fast, ring filling) -> trim up to
    /// consume faster. Positive fill_dev (ring above center) -> also trim up
    /// to drain it. Same direction, so the level term reinforces the rate
    /// term when the ring is genuinely too full and gently opposes it
    /// otherwise; near center fill_dev ~ 0 and the term vanishes.
    pub fn step(self: *Predictor, rate_error: f64, fill_dev: f64) f64 {
        self.integ += self.ki * rate_error;
        self.integ = std.math.clamp(self.integ, -self.clamp, self.clamp);
        const p = self.kp * rate_error;
        const level = self.eps * fill_dev;
        self.last_p = p;
        self.last_i = self.integ;
        self.last_level = level;
        const t = p + self.integ + level;
        self.trim = 1.0 + std.math.clamp(t, -self.clamp, self.clamp);
        return self.trim;
    }

    pub fn currentTrim(self: *const Predictor) f64 {
        return self.trim;
    }
};

fn envF64(name: []const u8, dflt: f64) f64 {
    const v = compat.args.getenv(name) orelse return dflt;
    return std.fmt.parseFloat(f64, v) catch dflt;
}

// ---- synthetic controller tests (ADR 0024 criterion 8, layer 1) ----
//
// These feed the pure control law a simulated per-client rate error with an
// injected ppm offset and verify convergence, boundedness, no oscillation,
// and step recovery, with no broker or ring. The simulation models a client
// whose production rate is offset from our consumption by `ppm`: each window,
// if the trim does not match the offset, production and consumption diverge,
// producing a rate error; when the trim matches, the rate error goes to zero.

const SimSource = struct {
    ppm: f64, // client production rate offset, parts per million
    // The residual rate error the predictor sees given its current trim. If
    // the client runs +ppm fast and the trim already speeds consumption by
    // +ppm, they cancel and the observed rate error is ~0.
    fn rateError(self: SimSource, trim: f64) f64 {
        const source_factor = 1.0 + self.ppm * 1e-6;
        return source_factor / trim - 1.0;
    }
};

// Test helper: a Predictor with explicit gains, independent of the env-tuned
// defaults, so the control-law tests are stable regardless of bench tuning.
fn testPredictor(kp: f64, ki: f64, eps: f64) Predictor {
    return .{ .kp = kp, .ki = ki, .eps = eps, .integ = 0.0, .trim = 1.0, .clamp = 0.005, .last_p = 0.0, .last_i = 0.0, .last_level = 0.0 };
}

fn converge(ppm: f64, steps: usize) Predictor {
    var p = testPredictor(0.10, 0.02, 0.0); // slow stable gains, no level term
    const src = SimSource{ .ppm = ppm };
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        _ = p.step(src.rateError(p.currentTrim()), 0.0); // fill at center
    }
    return p;
}

test "converges to cancel a +100 ppm client" {
    var p = converge(100.0, 2000);
    try std.testing.expect(@abs(p.currentTrim() - (1.0 + 100e-6)) < 5e-6);
}

test "converges to cancel a -100 ppm client" {
    var p = converge(-100.0, 2000);
    try std.testing.expect(@abs(p.currentTrim() - (1.0 - 100e-6)) < 5e-6);
}

test "residual rate error driven to near zero at convergence" {
    var p = converge(250.0, 3000);
    const src = SimSource{ .ppm = 250.0 };
    try std.testing.expect(@abs(src.rateError(p.currentTrim())) < 1e-6);
}

test "trim stays within clamp for an absurd offset" {
    var p = converge(5000.0, 3000);
    try std.testing.expect(p.currentTrim() <= 1.0 + p.clamp + 1e-9);
    try std.testing.expect(p.currentTrim() >= 1.0 - p.clamp - 1e-9);
}

test "no oscillation: trim does not overshoot the target" {
    var p = testPredictor(0.10, 0.02, 0.0);
    const src = SimSource{ .ppm = 200.0 };
    const target = 1.0 + 200.0 * 1e-6;
    var i: usize = 0;
    var max_trim: f64 = 1.0;
    while (i < 2000) : (i += 1) {
        const tr = p.step(src.rateError(p.currentTrim()), 0.0);
        if (tr > max_trim) max_trim = tr;
    }
    try std.testing.expect(max_trim <= target + 1e-6);
}

test "recovers after a step change in client rate" {
    var p = testPredictor(0.10, 0.02, 0.0);
    var src = SimSource{ .ppm = 100.0 };
    var i: usize = 0;
    while (i < 2000) : (i += 1) _ = p.step(src.rateError(p.currentTrim()), 0.0);
    try std.testing.expect(@abs(p.currentTrim() - (1.0 + 100e-6)) < 5e-6);
    src = SimSource{ .ppm = -150.0 };
    i = 0;
    while (i < 3000) : (i += 1) _ = p.step(src.rateError(p.currentTrim()), 0.0);
    try std.testing.expect(@abs(p.currentTrim() - (1.0 - 150e-6)) < 5e-6);
}

test "level term is inert at center, restoring off-center" {
    // At fill_dev = 0 (center) with zero rate error, the trim holds: the
    // level term contributes nothing near center, preserving rate-correction
    // primacy. Off-center, it produces a restoring pull (the term that
    // converts diffusive occupancy to mean-reverting).
    var p = testPredictor(0.10, 0.02, 0.02);
    // converge to a nonzero trim with fill centered
    const src = SimSource{ .ppm = 300.0 };
    var i: usize = 0;
    while (i < 3000) : (i += 1) _ = p.step(src.rateError(p.currentTrim()), 0.0);
    const at_center = p.currentTrim();
    // one step at center holds (level inert)
    const held = p.step(0.0, 0.0);
    try std.testing.expectApproxEqAbs(at_center, held, 1e-9);
    // a positive fill deviation (ring too full) pushes trim up to drain
    const up = p.step(0.0, 0.3);
    try std.testing.expect(up > held);
    // a negative deviation (ring too empty) pushes trim down
    const down = p.step(0.0, -0.3);
    try std.testing.expect(down < up);
}
