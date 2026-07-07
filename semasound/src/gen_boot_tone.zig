// gen-boot-tone: build-time generator for the boot chime asset (ADR 0032).
//
// Emits the 2.000 s boot initialization sequence as raw interleaved
// signed 16-bit LE PCM. The committed source of truth for boot.pcm,
// which is a build product and is never committed; install.sh runs
// this at install time from zig-out/bin and ships the result to
// $PREFIX/share/pgsd/sounds/boot.pcm. Not a deployed binary.
//
// Default rate is protocol.CANON_RATE (the bit-exact passthrough
// path). First and last frames are sample-exact zero so the stream
// can be cut hard with no click; peak is normalized to --gain of
// full scale (default 0.15, operator-tuned: full-scale playback of
// the sequence was vastly too loud on the bench hardware).
//
// Structure of the sequence:
//   0.00 - 0.60 s : low root swell, A2 gliding up one octave to A3
//   0.35 - 1.60 s : bell tones A4 -> E5 -> A5, staggered, panned
//                   lightly left -> right -> center
//   1.20 - 2.00 s : shimmer tail (detuned A5 pair, split L/R)
//   final 5 ms    : linear fade forcing exact-zero endpoints
//
// Usage: gen-boot-tone [--rate N] [--mono] [--wav] [--gain G]
//        [--out BASENAME]
// --gain G sets the normalized peak as a fraction of full scale,
// clamped to [0.0, 1.0].
// Writes BASENAME.pcm (and BASENAME.wav with --wav). BASENAME may
// include a path; default "boot". Exit codes: 0 written, 1 error.

const std = @import("std");
const compat = @import("compat");
const protocol = @import("protocol.zig");

const tau: f64 = 2.0 * std.math.pi;
const total_seconds: f64 = 2.0;

const BellNote = struct {
    t0: f64, // start time (s)
    freq: f64, // fundamental (Hz)
    dur: f64, // note length (s)
    amp: f64, // peak amplitude, pre-normalization
    pan: f64, // 0 = left, 1 = right
};

const notes = [_]BellNote{
    .{ .t0 = 0.35, .freq = 440.00, .dur = 1.10, .amp = 0.34, .pan = 0.35 },
    .{ .t0 = 0.70, .freq = 659.25, .dur = 1.05, .amp = 0.30, .pan = 0.65 },
    .{ .t0 = 1.05, .freq = 880.00, .dur = 0.95, .amp = 0.26, .pan = 0.50 },
};

/// Bell voice at time `local` since note start: fast attack,
/// exponential decay, decaying 2nd and 3rd harmonics.
fn bellSample(local: f64, freq: f64, amp: f64) f64 {
    const attack = @min(local / 0.012, 1.0);
    const env = attack * @exp(-local * 4.5);
    const tone =
        1.00 * @sin(tau * freq * local) +
        0.35 * @sin(tau * freq * 2.0 * local) * @exp(-local * 7.0) +
        0.12 * @sin(tau * freq * 3.0 * local) * @exp(-local * 10.0);
    return amp * env * tone;
}

fn quantize(v: f64, scale: f64) i16 {
    const clamped = std.math.clamp(v * scale, -32767.0, 32767.0);
    return @intFromFloat(@trunc(clamped));
}

/// 44-byte RIFF/WAVE header for 16-bit PCM.
fn wavHeader(rate: u32, channels: u16, data_len: u32) [44]u8 {
    var h: [44]u8 = undefined;
    const byte_rate: u32 = rate * channels * 2;
    const block_align: u16 = channels * 2;
    @memcpy(h[0..4], "RIFF");
    std.mem.writeInt(u32, h[4..8], 36 + data_len, .little);
    @memcpy(h[8..12], "WAVE");
    @memcpy(h[12..16], "fmt ");
    std.mem.writeInt(u32, h[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, h[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, h[22..24], channels, .little);
    std.mem.writeInt(u32, h[24..28], rate, .little);
    std.mem.writeInt(u32, h[28..32], byte_rate, .little);
    std.mem.writeInt(u16, h[32..34], block_align, .little);
    std.mem.writeInt(u16, h[34..36], 16, .little); // bits per sample
    @memcpy(h[36..40], "data");
    std.mem.writeInt(u32, h[40..44], data_len, .little);
    return h;
}

fn createOut(io: std.Io, path: []const u8) !compat.fs.File {
    if (path.len > 0 and path[0] == '/')
        return compat.fs.createFileAbsolute(io, path, .{});
    return compat.fs.cwd(io).createFile(path, .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var rate: u32 = protocol.CANON_RATE;
    var mono = false;
    var wav = false;
    var gain: f64 = 0.15;
    var out_base: []const u8 = "boot";

    const args_owned = try compat.args.alloc(gpa, init.args);
    defer args_owned.deinit(gpa);
    const args = args_owned.argv;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--rate")) {
            i += 1;
            if (i < args.len) rate = std.fmt.parseInt(u32, args[i], 10) catch rate;
        } else if (std.mem.eql(u8, a, "--mono")) {
            mono = true;
        } else if (std.mem.eql(u8, a, "--wav")) {
            wav = true;
        } else if (std.mem.eql(u8, a, "--gain")) {
            i += 1;
            if (i < args.len) {
                const g = std.fmt.parseFloat(f64, args[i]) catch gain;
                gain = std.math.clamp(g, 0.0, 1.0);
            }
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i < args.len) out_base = args[i];
        } else {
            std.debug.print(
                "usage: gen-boot-tone [--rate N] [--mono] [--wav] [--gain G] [--out BASENAME]\n",
                .{},
            );
            std.process.exit(1);
        }
    }

    const sr: f64 = @floatFromInt(rate);
    const n: usize = @intFromFloat(sr * total_seconds);

    const left = try gpa.alloc(f64, n);
    defer gpa.free(left);
    const right = try gpa.alloc(f64, n);
    defer gpa.free(right);

    const swell_dur: f64 = 0.60;
    const tail_t0: f64 = 1.20;
    const tail_dur: f64 = 0.80;
    const fade_n: usize = @intFromFloat(sr * 0.005);

    var phase: f64 = 0.0;
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const t = @as(f64, @floatFromInt(idx)) / sr;
        var l: f64 = 0.0;
        var r: f64 = 0.0;

        // 1. Root swell: A2 (110 Hz) glides one octave up; the phase
        // accumulator keeps the glide continuous.
        if (t < swell_dur) {
            const frac = t / swell_dur;
            const freq = 110.0 * @exp2(frac);
            phase += tau * freq / sr;
            const env = std.math.pow(f64, @sin(std.math.pi * frac), 1.5);
            const s = 0.30 * env * @sin(phase);
            l += s;
            r += s;
        }

        // 2. Bell arpeggio with light constant-power panning.
        for (notes) |note| {
            const local = t - note.t0;
            if (local >= 0.0 and local < note.dur) {
                const s = bellSample(local, note.freq, note.amp);
                l += s * @cos(note.pan * std.math.pi / 2.0);
                r += s * @sin(note.pan * std.math.pi / 2.0);
            }
        }

        // 3. Shimmer tail: detuned pair split across channels.
        if (t >= tail_t0 and t < tail_t0 + tail_dur) {
            const local = t - tail_t0;
            const env_s = @sin(std.math.pi * local / tail_dur);
            const env = env_s * env_s;
            l += 0.10 * env * @sin(tau * 878.0 * local);
            r += 0.10 * env * @sin(tau * 882.0 * local);
        }

        // 4. Terminal fade to sample-exact zero.
        if (idx >= n - fade_n) {
            const ramp = @as(f64, @floatFromInt(n - 1 - idx)) /
                @as(f64, @floatFromInt(fade_n));
            l *= ramp;
            r *= ramp;
        }

        left[idx] = l;
        right[idx] = r;
    }

    // Normalize the peak to `gain` of full scale and quantize.
    var peak: f64 = 0.0;
    for (left) |v| peak = @max(peak, @abs(v));
    for (right) |v| peak = @max(peak, @abs(v));
    const scale: f64 = if (peak > 0.0) (gain / peak) * 32767.0 else 0.0;

    const channels: u16 = if (mono) 1 else 2;
    const pcm = try gpa.alloc(i16, n * channels);
    defer gpa.free(pcm);
    if (mono) {
        for (0..n) |j| pcm[j] = quantize((left[j] + right[j]) * 0.5, scale);
    } else {
        for (0..n) |j| {
            pcm[2 * j] = quantize(left[j], scale);
            pcm[2 * j + 1] = quantize(right[j], scale);
        }
    }
    const bytes = std.mem.sliceAsBytes(pcm);

    var io_ctx = compat.io.open(gpa) catch {
        std.debug.print("gen-boot-tone: cannot initialize I/O\n", .{});
        std.process.exit(1);
    };
    defer io_ctx.deinit();
    const io = io_ctx.io();

    var path_buf: [1024]u8 = undefined;

    const raw_path = std.fmt.bufPrint(&path_buf, "{s}.pcm", .{out_base}) catch {
        std.debug.print("gen-boot-tone: output basename too long\n", .{});
        std.process.exit(1);
    };
    var raw = createOut(io, raw_path) catch |e| {
        std.debug.print("gen-boot-tone: cannot create {s}: {s}\n", .{ raw_path, @errorName(e) });
        std.process.exit(1);
    };
    raw.writeAll(bytes) catch |e| {
        std.debug.print("gen-boot-tone: write {s}: {s}\n", .{ raw_path, @errorName(e) });
        std.process.exit(1);
    };
    raw.close();
    std.debug.print(
        "wrote {s} ({d} bytes, {d} Hz, {d} ch, s16le)\n",
        .{ raw_path, bytes.len, rate, channels },
    );

    if (wav) {
        const wav_path = std.fmt.bufPrint(&path_buf, "{s}.wav", .{out_base}) catch unreachable;
        var wf = createOut(io, wav_path) catch |e| {
            std.debug.print("gen-boot-tone: cannot create {s}: {s}\n", .{ wav_path, @errorName(e) });
            std.process.exit(1);
        };
        const header = wavHeader(rate, channels, @intCast(bytes.len));
        wf.writeAll(&header) catch |e| {
            std.debug.print("gen-boot-tone: write {s}: {s}\n", .{ wav_path, @errorName(e) });
            std.process.exit(1);
        };
        wf.writeAll(bytes) catch |e| {
            std.debug.print("gen-boot-tone: write {s}: {s}\n", .{ wav_path, @errorName(e) });
            std.process.exit(1);
        };
        wf.close();
        std.debug.print("wrote {s} (preview)\n", .{wav_path});
    }
}
