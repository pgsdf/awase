// semasound-tone: F.5.a test client (ADR 0021 bench plan).
//
// Connects to the semasound socket, sends the canonical Hello, and streams a
// generated sine. The analogue of audiofs's playtone, but writing PCM to
// semasound's socket. Drives the F.5.a closure criteria.
//
// Usage: semasound-tone [seconds [freq_hz [amp]]] [--rate N] [--mono] [--drift-ppm N]
//        [--target NAME] [--label NAME] [--class TOKEN]
//        [--format N] [--channels N] [--version N] [--badrate] [--gap ms]
// Exit codes: 0 clean, 2 rejected at hello, 3 preempted mid-stream by policy.
//   positional:  seconds (3.0), freq_hz (750), amp (3000)
//   --rate N     declare AND generate at N Hz (drives F.5.b resampling);
//                a supported non-48k rate is accepted and resampled
//   --mono       declare 1 channel, emit 16-bit mono (tests mono->stereo)
//   --drift-ppm N  generate at an effective rate offset by N ppm from the
//                declared rate, and self-pace to wall clock, so the offset is
//                a sustained free-running drift (layer-2 criterion 8 source)
//   --badrate    send a non-canonical rate in the Hello (criterion 4:
//                expect rejection)
//   --gap N      stop writing for N ms partway through, keeping the socket
//                open, to drain semasound's ring and induce an audiofs xrun
//                (criterion 7). Default gap point is mid-stream.

const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try posix.write(fd, bytes[off..]);
        off += n;
    }
}

pub fn main() !void {
    var seconds: f64 = 3.0;
    var freq: f64 = 750.0;
    var amp: f64 = 3000.0; // peak per channel; raise to match a multi-client sum
    var badrate: bool = false;
    var gap_ms: u64 = 0; // 0 = no gap
    var rate: u32 = protocol.CANON_RATE; // --rate N: declare AND generate at N
    var mono: bool = false; // --mono: declare 1 channel, emit 16-bit mono
    var drift_ppm: f64 = 0.0; // --drift-ppm N: generate at an effective rate
    // offset from the declared rate by N ppm (a physical clock deviation, not
    // a declared-rate lie), to exercise the F.5.b rate-correcting predictor.
    // F.5.b criterion 7 rejection overrides: declare an unsupported format
    // code or channel count in the Hello and expect STATUS_REJECTED. The
    // broker must reject cleanly and survive. (e.g. --format 2 stands in for
    // a 24-bit client, --format 3 for float, --channels 4 for multichannel.)
    var format_override: ?u16 = null; // --format N: raw format code
    var channels_override: ?u16 = null; // --channels N: raw channel count
    // F.5.c routing (ADR 0025): --target NAME routes to a named target
    // (empty -> "default" broker-side). --version N overrides the declared
    // hello version (criterion 5: v1 must be rejected).
    var target_name: []const u8 = "";
    var version_override: ?u16 = null;
    // F.5.d identity (ADR 0026): --label NAME and --class TOKEN.
    var label_name: []const u8 = "";
    var class_name: []const u8 = "";

    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    var pos: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--badrate")) {
            badrate = true;
        } else if (std.mem.eql(u8, a, "--gap")) {
            i += 1;
            if (i < args.len) gap_ms = std.fmt.parseInt(u64, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "--rate")) {
            i += 1;
            if (i < args.len) rate = std.fmt.parseInt(u32, args[i], 10) catch rate;
        } else if (std.mem.eql(u8, a, "--mono")) {
            mono = true;
        } else if (std.mem.eql(u8, a, "--drift-ppm")) {
            i += 1;
            if (i < args.len) drift_ppm = std.fmt.parseFloat(f64, args[i]) catch 0.0;
        } else if (std.mem.eql(u8, a, "--format")) {
            i += 1;
            if (i < args.len) format_override = std.fmt.parseInt(u16, args[i], 10) catch null;
        } else if (std.mem.eql(u8, a, "--channels")) {
            i += 1;
            if (i < args.len) channels_override = std.fmt.parseInt(u16, args[i], 10) catch null;
        } else if (std.mem.eql(u8, a, "--target")) {
            i += 1;
            if (i < args.len) target_name = args[i];
        } else if (std.mem.eql(u8, a, "--version")) {
            i += 1;
            if (i < args.len) version_override = std.fmt.parseInt(u16, args[i], 10) catch null;
        } else if (std.mem.eql(u8, a, "--label")) {
            i += 1;
            if (i < args.len) label_name = args[i];
        } else if (std.mem.eql(u8, a, "--class")) {
            i += 1;
            if (i < args.len) class_name = args[i];
        } else {
            switch (pos) {
                0 => seconds = std.fmt.parseFloat(f64, a) catch seconds,
                1 => freq = std.fmt.parseFloat(f64, a) catch freq,
                2 => amp = std.fmt.parseFloat(f64, a) catch amp,
                else => {},
            }
            pos += 1;
        }
    }

    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fd);
    var addr: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = [_]u8{0} ** 104,
    };
    @memcpy(addr.path[0..protocol.SOCKET_PATH.len], protocol.SOCKET_PATH);
    try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    var target_buf = [_]u8{0} ** 16;
    const tn = if (target_name.len > 16) target_name[0..16] else target_name;
    @memcpy(target_buf[0..tn.len], tn);
    var label_buf = [_]u8{0} ** 16;
    const ln = if (label_name.len > 16) label_name[0..16] else label_name;
    @memcpy(label_buf[0..ln.len], ln);
    var class_buf = [_]u8{0} ** 16;
    const cn = if (class_name.len > 16) class_name[0..16] else class_name;
    @memcpy(class_buf[0..cn.len], cn);
    const hello = protocol.Hello{
        .magic = protocol.HELLO_MAGIC,
        .version = version_override orelse protocol.HELLO_VERSION,
        // --format N overrides the format code (criterion 7: a non-16-bit
        // code such as 2 (24-bit) or 3 (float) must be rejected).
        .format = format_override orelse protocol.CANON_FORMAT,
        // --badrate declares 96000, a rate outside rateSupported, to test
        // rejection. (Its original F.5.a value 44100 is ACCEPTED under
        // F.5.b, so the flag was repurposed to keep its documented intent:
        // a rate that must be rejected.) Otherwise declare the --rate value,
        // which F.5.b accepts and resamples.
        .rate_hz = if (badrate) 96000 else rate,
        // --channels N overrides the channel count (criterion 7: >2 must be
        // rejected); otherwise mono/stereo per --mono.
        .channels = channels_override orelse (if (mono) @as(u16, 1) else protocol.CANON_CHANNELS),
        ._pad = 0,
        .target = target_buf,
        .label = label_buf,
        .class = class_buf,
    };
    try writeAll(fd, std.mem.asBytes(&hello));

    var status: [1]u8 = undefined;
    const sn = try posix.read(fd, &status);
    if (sn == 0 or status[0] != protocol.STATUS_ACCEPTED) {
        std.debug.print("semasound-tone: rejected (status {d})\n", .{if (sn == 0) @as(u8, 255) else status[0]});
        // Exit nonzero so rejection tests (criterion 7) can assert on the
        // exit code: rejection is the EXPECTED outcome for a bad Hello.
        std.process.exit(2);
    }
    if (!protocol.helloIsAcceptable(hello)) {
        // We sent a Hello we can locally compute is unacceptable, and the
        // broker accepted it anyway: that is a criterion-7 failure.
        std.debug.print("semasound-tone: WARNING broker accepted an unacceptable Hello (criterion 7 fail)\n", .{});
    }

    // Generate at the declared rate so the resampler receives a true N-Hz
    // tone. --badrate is the exception: it declares 96000 but generates at
    // 48k; it is rejected before generation matters anyway.
    const gen_rate: u32 = if (badrate) protocol.CANON_RATE else rate;
    // --drift-ppm offsets the EFFECTIVE generation rate from the declared
    // rate by a physical fraction. The Hello still declared gen_rate honestly;
    // here we emit frames as if the client's clock ran fast/slow by drift_ppm,
    // producing more/fewer frames over the same wall-clock seconds. This is
    // the genuine drift the F.5.b predictor must cancel via ratio trim.
    const eff_rate: f64 = @as(f64, @floatFromInt(gen_rate)) * (1.0 + drift_ppm * 1e-6);
    const total_frames: usize = @intFromFloat(seconds * eff_rate);
    const dphi: f64 = 2.0 * std.math.pi * freq / eff_rate;
    var phase: f64 = 0.0;

    // criterion 7: take the gap at the stream midpoint, once.
    const gap_at: usize = if (gap_ms > 0) total_frames / 2 else 0;
    var gapped: bool = false;

    var chunk: [4096]u8 = undefined;
    const bpf: usize = if (mono) 2 else 4;
    var frames_done: usize = 0;
    // Self-pace to wall clock when testing drift: emit frames at the effective
    // rate regardless of how fast the broker drains, so a drift offset becomes
    // a sustained producer/consumer mismatch (the real layer-2 stress). When
    // not drift-testing, stay purely blocking-paced (fast drain) as before.
    const paced = (drift_ppm != 0.0);
    const start_ns: i128 = std.time.nanoTimestamp();
    while (frames_done < total_frames) {
        if (gap_ms > 0 and !gapped and frames_done >= gap_at) {
            std.debug.print("semasound-tone: stalling {d} ms mid-stream (socket stays open)\n", .{gap_ms});
            std.Thread.sleep(gap_ms * std.time.ns_per_ms);
            gapped = true;
        }
        var n: usize = 0;
        while (n + bpf <= chunk.len and frames_done < total_frames) {
            const v: i16 = @intFromFloat(amp * @sin(phase));
            const u: u16 = @bitCast(v);
            chunk[n] = @truncate(u);
            chunk[n + 1] = @truncate(u >> 8);
            if (!mono) {
                chunk[n + 2] = @truncate(u);
                chunk[n + 3] = @truncate(u >> 8);
            }
            n += bpf;
            phase += dphi;
            if (phase >= 2.0 * std.math.pi) phase -= 2.0 * std.math.pi;
            frames_done += 1;
        }
        writeAll(fd, chunk[0..n]) catch |e| {
            // F.5.d (ADR 0026 Decision 6): a mid-stream write failure may be
            // a group preemption; the broker queues STATUS_PREEMPTED before
            // shutting the socket down. Drain one status byte to find out.
            var st: [1]u8 = undefined;
            const rn = posix.read(fd, &st) catch 0;
            if (rn == 1 and st[0] == protocol.STATUS_PREEMPTED) {
                std.debug.print("semasound-tone: preempted by policy (group exclusivity)\n", .{});
                std.process.exit(3);
            }
            return e;
        };
        if (paced) {
            // Sleep until the wall-clock instant these frames should have been
            // produced at the effective rate: target_ns = frames_done /
            // eff_rate. If we are ahead, sleep the difference; if behind (the
            // broker is slower), do not sleep.
            const target_ns: i128 = start_ns +
                @as(i128, @intFromFloat(@as(f64, @floatFromInt(frames_done)) /
                    eff_rate * 1e9));
            const now_ns: i128 = std.time.nanoTimestamp();
            if (target_ns > now_ns) {
                std.Thread.sleep(@intCast(target_ns - now_ns));
            }
        }
    }
    std.debug.print("semasound-tone: wrote {d} frames ({d:.2}s at {d:.0} Hz, rate {d}, {s}, amp {d:.0})\n", .{ total_frames, seconds, freq, gen_rate, if (mono) "mono" else "stereo", amp });
}
