// F.5.b resampler (ADR 0024 Decision 4): windowed-sinc polyphase rate
// converter, the production design from the start (no interim linear stage).
//
// Converts a client's 16-bit stereo PCM stream from its input rate to the
// elected hardware rate. The conversion ratio is RUNTIME-ADJUSTABLE: the
// effective step is set per call, so the ADR 0024 Decision 5 rate-correcting
// predictor can trim it continuously without rebuilding any state. This
// module owns ONLY the signal path (kernel + phase accumulation); the drift
// estimator and ratio controller live in the predictor (a later increment),
// which calls setRatio.
//
// Design:
//   - A windowed-sinc lowpass, sampled into a table, is the interpolation
//     kernel. TAPS taps (an even count) span the kernel; the cutoff is set
//     to the lower of input/output Nyquist so downsampling is anti-aliased
//     and upsampling rejects images.
//   - Output sample n draws input position pos = n * step, where
//     step = in_rate / out_rate (the nominal ratio, trimmed by the
//     predictor). The kernel is centered on pos and weights the TAPS input
//     frames around it. Fractional position selects the sub-sample phase.
//   - Stereo: left and right are independent convolutions sharing the same
//     kernel and phase. Mono-to-stereo duplication happens upstream (ADR
//     0024 Decision 3), so this module always sees stereo.
//
// Bit-exact bypass (ADR 0024 Decision 1 / Consequences): when the elected
// rate equals the input rate, the resampler is NOT used at all; callers take
// the passthrough path. A ratio of exactly 1.0 here is still a real
// convolution, so do not rely on this module for the 1:1 case.

const std = @import("std");

pub const TAPS: usize = 32; // even; kernel half-width = TAPS/2
pub const PHASES: usize = 256; // sub-sample phase resolution of the table
const HALF: usize = TAPS / 2;

// Windowed-sinc kernel table: PHASES rows, each TAPS wide. Row p holds the
// kernel sampled at fractional offset p/PHASES. Built once for a given
// cutoff; reused across all calls. Stored as f32 (quality is well within
// f32 precision for 16-bit audio).
const Kernel = struct {
    table: [PHASES][TAPS]f32,

    // Build a windowed-sinc kernel with the given normalized cutoff (in
    // cycles/sample, 0..0.5). A Hann window tapers the sinc to TAPS taps.
    fn init(cutoff: f64) Kernel {
        var k: Kernel = undefined;
        var p: usize = 0;
        while (p < PHASES) : (p += 1) {
            const frac: f64 = @as(f64, @floatFromInt(p)) /
                @as(f64, @floatFromInt(PHASES));
            var sum: f64 = 0.0;
            var t: usize = 0;
            while (t < TAPS) : (t += 1) {
                // Tap t corresponds to input offset (t - HALF + 1) - frac
                // from the interpolation point.
                const x: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(t)) -
                    @as(i64, @intCast(HALF)) + 1)) - frac;
                const s = sinc(2.0 * cutoff * x) * 2.0 * cutoff;
                // Hann window over the TAPS span, centered.
                const wpos: f64 = (@as(f64, @floatFromInt(t)) - frac + 0.5) /
                    @as(f64, @floatFromInt(TAPS));
                const w = 0.5 - 0.5 * @cos(2.0 * std.math.pi * wpos);
                const v = s * w;
                k.table[p][t] = @floatCast(v);
                sum += v;
            }
            // Normalize each phase row to unity DC gain so a constant input
            // resamples to the same constant (no level shift, no ripple at
            // DC).
            const inv: f64 = if (sum != 0.0) 1.0 / sum else 1.0;
            t = 0;
            while (t < TAPS) : (t += 1) {
                k.table[p][t] = @floatCast(@as(f64, k.table[p][t]) * inv);
            }
        }
        return k;
    }
};

fn sinc(x: f64) f64 {
    if (x == 0.0) return 1.0;
    const px = std.math.pi * x;
    return @sin(px) / px;
}

pub const Resampler = struct {
    kernel: Kernel,
    in_rate: u32,
    out_rate: u32,
    // step = in_rate / out_rate, trimmable by the predictor via setRatio.
    step: f64,
    // Fractional input position carried across calls so streaming chunks
    // join seamlessly. Integer part indexes the history ring.
    pos: f64,
    // History of the most recent TAPS input frames (stereo), so a kernel
    // centered near a chunk boundary can reach back into the previous chunk.
    hist_l: [TAPS]f32,
    hist_r: [TAPS]f32,
    hist_fill: usize,

    /// Create a resampler from in_rate to out_rate. Cutoff is the lower
    /// Nyquist (anti-image on upsample, anti-alias on downsample), with a
    /// small guard so the transition band sits below Nyquist.
    pub fn init(in_rate: u32, out_rate: u32) Resampler {
        const lo: f64 = @floatFromInt(@min(in_rate, out_rate));
        const hi: f64 = @floatFromInt(@max(in_rate, out_rate));
        // Normalized cutoff in cycles/input-sample, with 0.90 guard band.
        const cutoff: f64 = 0.5 * (lo / hi) * 0.90;
        return .{
            .kernel = Kernel.init(cutoff),
            .in_rate = in_rate,
            .out_rate = out_rate,
            .step = @as(f64, @floatFromInt(in_rate)) /
                @as(f64, @floatFromInt(out_rate)),
            .pos = 0.0,
            .hist_l = [_]f32{0.0} ** TAPS,
            .hist_r = [_]f32{0.0} ** TAPS,
            .hist_fill = 0,
        };
    }

    /// ADR 0024 Decision 5: trim the effective step by a small factor
    /// (e.g. 1.0 + ppm*1e-6). The predictor calls this; the clamp belongs
    /// to the predictor, not here, but guard against absurd values.
    pub fn setRatioTrim(self: *Resampler, trim: f64) void {
        const nominal = @as(f64, @floatFromInt(self.in_rate)) /
            @as(f64, @floatFromInt(self.out_rate));
        const clamped = std.math.clamp(trim, 0.97, 1.03);
        self.step = nominal * clamped;
    }

    // Push one input frame into the history ring (most-recent at the end).
    fn pushFrame(self: *Resampler, l: f32, r: f32) void {
        var i: usize = 0;
        while (i < TAPS - 1) : (i += 1) {
            self.hist_l[i] = self.hist_l[i + 1];
            self.hist_r[i] = self.hist_r[i + 1];
        }
        self.hist_l[TAPS - 1] = l;
        self.hist_r[TAPS - 1] = r;
        if (self.hist_fill < TAPS) self.hist_fill += 1;
    }

    /// Resample `in_bytes` (16-bit LE stereo) into `out_bytes`. Returns the
    /// number of output BYTES written. Streaming-safe: position and history
    /// carry across calls so chunk boundaries join seamlessly.
    ///
    /// Coordinate model (single, consistent): the history ring holds the most
    /// recent frames with the newest at index hist_fill-1. `pos` is the
    /// fractional read position measured from the OLDEST sample in the ring
    /// (index 0). To emit an output frame we need TAPS samples centered on
    /// pos, i.e. samples [floor(pos)-HALF+1 .. floor(pos)+HALF]; that requires
    /// pos to be at least HALF-1 from the start and at most hist_fill-HALF
    /// from the end. When pos advances past 1.0 we consume input frames: each
    /// consumed frame shifts the ring left by one, so pos decreases by 1.0 to
    /// stay aligned with the same physical sample. Consuming and decrementing
    /// happen together, exactly once per shift, which is the invariant the
    /// previous version violated.
    pub fn resample(self: *Resampler, in_bytes: []const u8, out_bytes: []u8) usize {
        const in_frames = in_bytes.len / 4; // 16-bit stereo = 4 bytes/frame
        const out_cap = out_bytes.len / 4;
        var out_n: usize = 0;
        var consumed: usize = 0;

        while (out_n < out_cap) {
            // Emit while the kernel window centered on pos is fully inside the
            // buffered history: need floor(pos)+HALF <= hist_fill-1.
            while (out_n < out_cap and
                self.pos + @as(f64, @floatFromInt(HALF)) <
                    @as(f64, @floatFromInt(self.hist_fill)))
            {
                const base: usize = @intFromFloat(self.pos);
                const frac: f64 = self.pos - @as(f64, @floatFromInt(base));
                const phase: usize = @intFromFloat(frac *
                    @as(f64, @floatFromInt(PHASES)));
                const row = &self.kernel.table[@min(phase, PHASES - 1)];

                var acc_l: f64 = 0.0;
                var acc_r: f64 = 0.0;
                var t: usize = 0;
                while (t < TAPS) : (t += 1) {
                    const idx_i: i64 = @as(i64, @intCast(base)) +
                        @as(i64, @intCast(t)) - @as(i64, @intCast(HALF)) + 1;
                    if (idx_i >= 0 and idx_i < @as(i64, @intCast(self.hist_fill))) {
                        const idx: usize = @intCast(idx_i);
                        acc_l += @as(f64, row[t]) * @as(f64, self.hist_l[idx]);
                        acc_r += @as(f64, row[t]) * @as(f64, self.hist_r[idx]);
                    }
                }
                writeFrame(out_bytes, out_n, acc_l, acc_r);
                out_n += 1;
                self.pos += self.step;
            }

            // Need more input to advance. Consume one frame: shift the ring
            // left (oldest drops), append the new frame, and move pos back by
            // one to track the same physical sample after the shift.
            if (consumed >= in_frames) break;
            const off = consumed * 4;
            const l: i16 = @bitCast(@as(u16, in_bytes[off]) |
                (@as(u16, in_bytes[off + 1]) << 8));
            const r: i16 = @bitCast(@as(u16, in_bytes[off + 2]) |
                (@as(u16, in_bytes[off + 3]) << 8));
            self.pushFrame(@floatFromInt(l), @floatFromInt(r));
            consumed += 1;
            // Only decrement once the ring is full and actually sliding (a
            // shift discarded one old sample); while still filling, the ring
            // grows and pos stays aligned to index 0.
            if (self.hist_fill >= TAPS and self.pos >= 1.0) self.pos -= 1.0;
        }
        return out_n * 4;
    }
};

fn writeFrame(out: []u8, frame: usize, l: f64, r: f64) void {
    const li = clampI16(l);
    const ri = clampI16(r);
    const lu: u16 = @bitCast(li);
    const ru: u16 = @bitCast(ri);
    const off = frame * 4;
    out[off] = @truncate(lu);
    out[off + 1] = @truncate(lu >> 8);
    out[off + 2] = @truncate(ru);
    out[off + 3] = @truncate(ru >> 8);
}

fn clampI16(v: f64) i16 {
    const r = std.math.round(v);
    if (r > 32767.0) return 32767;
    if (r < -32768.0) return -32768;
    return @intFromFloat(r);
}

// ---- signal tests (ADR 0024 closure criterion 4, run independently) ----

fn writeSine(buf: []u8, freq: f64, rate: u32, amp: f64) void {
    const frames = buf.len / 4;
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const ph = 2.0 * std.math.pi * freq *
            @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate));
        const v: i16 = @intFromFloat(amp * @sin(ph));
        const u: u16 = @bitCast(v);
        const off = i * 4;
        buf[off] = @truncate(u);
        buf[off + 1] = @truncate(u >> 8);
        buf[off + 2] = @truncate(u);
        buf[off + 3] = @truncate(u >> 8);
    }
}

fn frameL(buf: []const u8, frame: usize) i16 {
    const off = frame * 4;
    return @bitCast(@as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8));
}

test "unity DC gain: constant input stays constant" {
    var rs = Resampler.init(44100, 48000);
    var in_buf: [4 * 512]u8 = undefined;
    // constant 10000 in both channels
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        const u: u16 = @bitCast(@as(i16, 10000));
        in_buf[i * 4] = @truncate(u);
        in_buf[i * 4 + 1] = @truncate(u >> 8);
        in_buf[i * 4 + 2] = @truncate(u);
        in_buf[i * 4 + 3] = @truncate(u >> 8);
    }
    var out_buf: [4 * 600]u8 = undefined;
    const n = rs.resample(&in_buf, &out_buf);
    const frames = n / 4;
    try std.testing.expect(frames > 400); // ~512 * 48/44.1
    // Sample well past the startup transient; should be ~10000.
    const v = frameL(&out_buf, frames - 20);
    try std.testing.expect(v > 9800 and v < 10200);
}

test "output frame count tracks the ratio" {
    var rs = Resampler.init(24000, 48000); // 2x upsample
    var in_buf: [4 * 256]u8 = undefined;
    writeSine(&in_buf, 1000.0, 24000, 8000.0);
    var out_buf: [4 * 600]u8 = undefined;
    const n = rs.resample(&in_buf, &out_buf);
    const frames = n / 4;
    // 256 input frames at 2x -> ~512 output (minus kernel warmup).
    try std.testing.expect(frames > 480 and frames <= 512);
}

test "ratio trim shifts the effective step" {
    var rs = Resampler.init(48000, 48000);
    const before = rs.step;
    rs.setRatioTrim(1.0001); // +100 ppm
    try std.testing.expect(rs.step > before);
    rs.setRatioTrim(0.9999); // -100 ppm
    try std.testing.expect(rs.step < before);
}

test "ratio trim is clamped against runaway" {
    var rs = Resampler.init(48000, 48000);
    rs.setRatioTrim(100.0); // absurd
    try std.testing.expect(rs.step <= 1.03 + 0.0001);
    rs.setRatioTrim(0.0); // absurd
    try std.testing.expect(rs.step >= 0.97 - 0.0001);
}
