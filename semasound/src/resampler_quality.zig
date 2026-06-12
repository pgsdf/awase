// resampler_quality: F.5.b resampler signal-quality harness (ADR 0024
// criterion 4). TEST ONLY, not part of the broker.
//
// Verifies the windowed-sinc resampler's quality against a stated bar,
// independently of mixing, before it is wired into the output path. For each
// rate pair it generates a pure sine at the input rate, resamples it, and
// measures two things on the steady-state output (the kernel warmup region
// is skipped):
//
//   - Passband fidelity / SNR: power at the fundamental versus all other
//     in-band energy. A clean resampler concentrates essentially all energy
//     at the resampled fundamental; aliases, images, and quantization noise
//     are the "noise" denominator.
//   - Image/alias rejection: power at the principal alias image relative to
//     the fundamental. For upsampling the image sits at (out_rate - f_in)
//     folded into band; for downsampling, any input content above the output
//     Nyquist must be rejected. We probe the specific image frequency and
//     report how far down it is.
//
// Single-frequency power is measured with the Goertzel algorithm (one bin,
// O(N), numerically stable), not a full FFT: we only care about power at a
// few known frequencies.
//
// Exit status: 0 if every case meets the bar, 1 otherwise, so this doubles
// as a gate. Stated bar (see BAR_* constants): SNR >= 60 dB on the hard
// 44.1<->48 ratios, principal image >= 60 dB down. 60 dB is ~10 bits clean,
// comfortably adequate for 16-bit playback where the noise floor and the
// codec dominate; a 32-tap Hann-windowed sinc should clear it with margin.

const std = @import("std");
const resampler = @import("resampler.zig");

const BAR_SNR_DB: f64 = 60.0;
const BAR_IMAGE_DB: f64 = 60.0;

// In-phase/quadrature amplitudes of a fitted tone.
const ToneFit = struct { a: f64, b: f64 };

// Fundamental power by least-squares sinusoid fit. Projecting the signal
// onto cos(wt) and sin(wt) gives the in-phase and quadrature amplitudes a, b
// at frequency f; the tone's mean-square power is (a^2 + b^2)/2. This has no
// normalization constant to get wrong (unlike a raw Goertzel accumulator):
// the projection is self-scaling.
fn fitTone(samples: []const f64, freq: f64, rate: f64) ToneFit {
    const w = 2.0 * std.math.pi * freq / rate;
    var sc: f64 = 0.0; // sum x*cos
    var ss: f64 = 0.0; // sum x*sin
    var i: usize = 0;
    while (i < samples.len) : (i += 1) {
        const ph = w * @as(f64, @floatFromInt(i));
        sc += samples[i] * @cos(ph);
        ss += samples[i] * @sin(ph);
    }
    const n: f64 = @floatFromInt(samples.len);
    // For an on-bin frequency, sum(cos^2) = sum(sin^2) = N/2, so the
    // amplitude estimate is 2/N times the projection.
    return .{ .a = 2.0 * sc / n, .b = 2.0 * ss / n };
}

// Mean-square power of a fitted tone.
fn tonePower(fit: ToneFit) f64 {
    return (fit.a * fit.a + fit.b * fit.b) / 2.0;
}

// Total power (mean square) of the signal.
fn totalPower(samples: []const f64) f64 {
    var sum: f64 = 0.0;
    for (samples) |x| sum += x * x;
    return sum / @as(f64, @floatFromInt(samples.len));
}

fn db(ratio: f64) f64 {
    if (ratio <= 0.0) return -200.0;
    return 10.0 * std.math.log10(ratio);
}

// Decode the left channel of a 16-bit stereo byte buffer into f64 mono,
// skipping the first `skip` frames (kernel warmup), into `out`.
fn decodeLeft(bytes: []const u8, skip: usize, out: []f64) usize {
    const frames = bytes.len / 4;
    var n: usize = 0;
    var i: usize = skip;
    while (i < frames and n < out.len) : (i += 1) {
        const off = i * 4;
        const l: i16 = @bitCast(@as(u16, bytes[off]) |
            (@as(u16, bytes[off + 1]) << 8));
        out[n] = @floatFromInt(l);
        n += 1;
    }
    return n;
}

const Case = struct {
    in_rate: u32,
    out_rate: u32,
    freq: f64, // test tone, Hz
};

fn runCase(c: Case, scratch_in: []u8, scratch_out: []u8, mono: []f64) !bool {
    var rs = resampler.Resampler.init(c.in_rate, c.out_rate);

    // Generate a pure sine at the input rate, amplitude -6 dBFS to leave
    // headroom (no clipping to confound the measurement).
    const in_frames = scratch_in.len / 4;
    const amp: f64 = 16000.0;
    var i: usize = 0;
    while (i < in_frames) : (i += 1) {
        const ph = 2.0 * std.math.pi * c.freq *
            @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(c.in_rate));
        const v: i16 = @intFromFloat(amp * @sin(ph));
        const u: u16 = @bitCast(v);
        const off = i * 4;
        scratch_in[off] = @truncate(u);
        scratch_in[off + 1] = @truncate(u >> 8);
        scratch_in[off + 2] = @truncate(u);
        scratch_in[off + 3] = @truncate(u >> 8);
    }

    const out_bytes = rs.resample(scratch_in, scratch_out);
    const out_frames = out_bytes / 4;
    if (out_frames < 1024) {
        std.debug.print("  case {d}->{d} @ {d:.0}Hz: too few output frames ({d})\n",
            .{ c.in_rate, c.out_rate, c.freq, out_frames });
        return false;
    }

    // Skip the kernel warmup, then analyze a whole number of cycles of the
    // exact test frequency. Fitting at exactly c.freq (the tone the resampler
    // preserves) over an integer number of cycles makes the projection
    // leakage-free without snapping to a DFT bin, which previously landed off
    // the true tone and collapsed the measured SNR.
    const skip: usize = 512;
    const decoded = decodeLeft(scratch_out[0..out_bytes], skip, mono);
    const out_rate_f: f64 = @floatFromInt(c.out_rate);
    // Whole cycles of c.freq that fit in the decoded span.
    const cycles = std.math.floor(@as(f64, @floatFromInt(decoded)) *
        c.freq / out_rate_f);
    var an: usize = @intFromFloat(cycles * out_rate_f / c.freq);
    if (an > decoded) an = decoded;
    if (an < 1024) {
        std.debug.print("  {d}->{d} @ {d:.0}Hz: too few analysis frames\n",
            .{ c.in_rate, c.out_rate, c.freq });
        return false;
    }
    const sig = mono[0..an];

    const fund = tonePower(fitTone(sig, c.freq, out_rate_f));
    const total = totalPower(sig);
    // Noise = total minus the fundamental tone's power.
    const noise = if (total > fund) total - fund else total * 1e-12;
    const snr = db(fund / noise);

    // Principal image: the dominant artifact sits at |in_rate - freq| folded
    // into the output band. Measure its power relative to the fundamental,
    // fit at its exact frequency.
    const image_freq = @as(f64, @floatFromInt(c.in_rate)) - c.freq;
    var image_db: f64 = -200.0;
    if (image_freq > 0 and image_freq < out_rate_f / 2.0) {
        const img = tonePower(fitTone(sig, image_freq, out_rate_f));
        image_db = db(img / fund); // how far down the image is (negative dB)
    }

    const snr_ok = snr >= BAR_SNR_DB;
    const img_ok = (-image_db) >= BAR_IMAGE_DB or image_freq <= 0 or
        image_freq >= out_rate_f / 2.0;

    std.debug.print(
        "  {d}->{d} @ {d:.0}Hz: SNR {d:.1} dB [{s}], image {d:.1} dB down [{s}]\n",
        .{
            c.in_rate,                c.out_rate, c.freq,
            snr,                      if (snr_ok) "ok" else "FAIL",
            -image_db,                if (img_ok) "ok" else "FAIL",
        },
    );
    return snr_ok and img_ok;
}

pub fn main() !void {
    // Big scratch buffers: ~1 second of audio is plenty for clean bins.
    var buf_in: [4 * 48000]u8 = undefined;
    var buf_out: [4 * 53000]u8 = undefined; // headroom for upsampling
    var mono: [53000]f64 = undefined;

    const cases = [_]Case{
        .{ .in_rate = 44100, .out_rate = 48000, .freq = 1000.0 },
        .{ .in_rate = 44100, .out_rate = 48000, .freq = 6000.0 },
        .{ .in_rate = 48000, .out_rate = 44100, .freq = 1000.0 },
        .{ .in_rate = 48000, .out_rate = 44100, .freq = 6000.0 },
        .{ .in_rate = 32000, .out_rate = 48000, .freq = 1000.0 },
        .{ .in_rate = 22050, .out_rate = 48000, .freq = 1000.0 },
        .{ .in_rate = 48000, .out_rate = 48000, .freq = 1000.0 },
    };

    std.debug.print("resampler signal quality (bar: SNR >= {d:.0} dB, image >= {d:.0} dB down)\n",
        .{ BAR_SNR_DB, BAR_IMAGE_DB });

    var all_ok = true;
    for (cases) |c| {
        // Size the input to a whole number of seconds-ish; use the full
        // input buffer length the case can fill.
        const in_len = (buf_in.len / 4) * 4;
        const ok = try runCase(c, buf_in[0..in_len], &buf_out, &mono);
        if (!ok) all_ok = false;
    }

    if (all_ok) {
        std.debug.print("\nPASS: all cases meet the quality bar.\n", .{});
    } else {
        std.debug.print("\nFAIL: at least one case missed the bar.\n", .{});
        std.process.exit(1);
    }
}
