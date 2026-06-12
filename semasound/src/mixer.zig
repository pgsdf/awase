// F.5.a mixer core (ADR 0021 Decision 3).
//
// Sum each source's 16-bit LE stereo samples into a 32-bit accumulator,
// then saturate to the int16 range (hard clip) and pack the output. A
// source shorter than `out` contributes silence for the shortfall
// (zero-fill), so a slow or stalled client mixes as silence without
// stalling the mix. Clipping is semantic and owned here, not in audiofs
// (ADR 0007).

const std = @import("std");

/// Mix `sources` into `out`. Both are canonical 16-bit LE PCM byte buffers.
/// `out.len` must be even (one i16 sample is two bytes). Sources may be
/// shorter than `out`; the shortfall is treated as silence.
pub fn mix(out: []u8, sources: []const []const u8) void {
    std.debug.assert(out.len % 2 == 0);
    const nsamples = out.len / 2;

    var i: usize = 0;
    while (i < nsamples) : (i += 1) {
        const off = i * 2;
        var acc: i32 = 0;
        for (sources) |src| {
            if (off + 2 <= src.len) {
                const s: i16 = @bitCast(@as(u16, src[off]) |
                    (@as(u16, src[off + 1]) << 8));
                acc += s;
            }
        }
        const clipped: i16 = if (acc > std.math.maxInt(i16))
            std.math.maxInt(i16)
        else if (acc < std.math.minInt(i16))
            std.math.minInt(i16)
        else
            @intCast(acc);
        const u: u16 = @bitCast(clipped);
        out[off] = @truncate(u);
        out[off + 1] = @truncate(u >> 8);
    }
}

/// F.5.d (ADR 0026 Decision 5): mix with per-source milli-gains (1000 =
/// unity). Unity sources take the EXACT same accumulation path as mix(), so
/// a lone passthrough client with no override active remains bit-exact
/// (criterion 6); ducked sources are scaled in i32 before accumulation
/// (round toward zero), then the sum saturates as in mix().
pub fn mixGains(out: []u8, sources: []const []const u8, gains_milli: []const u32) void {
    std.debug.assert(out.len % 2 == 0);
    std.debug.assert(sources.len == gains_milli.len);
    const nsamples = out.len / 2;

    var i: usize = 0;
    while (i < nsamples) : (i += 1) {
        const off = i * 2;
        var acc: i32 = 0;
        for (sources, gains_milli) |src, g| {
            if (off + 2 <= src.len) {
                const s: i16 = @bitCast(@as(u16, src[off]) |
                    (@as(u16, src[off + 1]) << 8));
                if (g == 1000) {
                    acc += s;
                } else {
                    acc += @divTrunc(@as(i32, s) * @as(i32, @intCast(g)), 1000);
                }
            }
        }
        const clipped: i16 = if (acc > std.math.maxInt(i16))
            std.math.maxInt(i16)
        else if (acc < std.math.minInt(i16))
            std.math.minInt(i16)
        else
            @intCast(acc);
        const u: u16 = @bitCast(clipped);
        out[off] = @truncate(u);
        out[off + 1] = @truncate(u >> 8);
    }
}

test "mixGains at unity is byte-identical to mix" {
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    const s1 = [_]u8{ 0x01, 0x02, 0xFF, 0x7F, 0x00, 0x80, 0x34, 0x12 };
    const s2 = [_]u8{ 0x10, 0x00, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x00 };
    const srcs = [_][]const u8{ &s1, &s2 };
    mix(&a, &srcs);
    mixGains(&b, &srcs, &[_]u32{ 1000, 1000 });
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "mixGains ducks a source by the milli factor" {
    var out: [4]u8 = undefined;
    // one source: samples 1000 and -1000; duck to 250/1000.
    const s1 = [_]u8{ 0xE8, 0x03, 0x18, 0xFC };
    const srcs = [_][]const u8{&s1};
    mixGains(&out, &srcs, &[_]u32{250});
    const v0: i16 = @bitCast(@as(u16, out[0]) | (@as(u16, out[1]) << 8));
    const v1: i16 = @bitCast(@as(u16, out[2]) | (@as(u16, out[3]) << 8));
    try std.testing.expectEqual(@as(i16, 250), v0);
    try std.testing.expectEqual(@as(i16, -250), v1);
}

fn sampleLE(buf: []const u8, idx: usize) i16 {
    return @bitCast(@as(u16, buf[idx * 2]) | (@as(u16, buf[idx * 2 + 1]) << 8));
}

test "two sources sum" {
    var a = [_]u8{ 0x10, 0x27 }; // 10000
    var b = [_]u8{ 0xE8, 0x03 }; // 1000
    var out = [_]u8{ 0, 0 };
    mix(&out, &[_][]const u8{ &a, &b });
    try std.testing.expectEqual(@as(i16, 11000), sampleLE(&out, 0));
}

test "positive clip saturates" {
    var a = [_]u8{ 0x20, 0x4E }; // 20000
    var b = [_]u8{ 0x20, 0x4E }; // 20000 -> 40000 clips
    var out = [_]u8{ 0, 0 };
    mix(&out, &[_][]const u8{ &a, &b });
    try std.testing.expectEqual(@as(i16, 32767), sampleLE(&out, 0));
}

test "negative clip saturates" {
    var a = [_]u8{ 0xE0, 0xB1 }; // -20000
    var b = [_]u8{ 0xE0, 0xB1 }; // -20000 -> -40000 clips
    var out = [_]u8{ 0, 0 };
    mix(&out, &[_][]const u8{ &a, &b });
    try std.testing.expectEqual(@as(i16, -32768), sampleLE(&out, 0));
}

test "short source zero-fills the tail" {
    var a = [_]u8{ 0x10, 0x27 }; // one sample 10000
    var out = [_]u8{ 0, 0, 0, 0 }; // two samples
    mix(&out, &[_][]const u8{&a});
    try std.testing.expectEqual(@as(i16, 10000), sampleLE(&out, 0));
    try std.testing.expectEqual(@as(i16, 0), sampleLE(&out, 1));
}

test "no sources yields silence" {
    var out = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    mix(&out, &[_][]const u8{});
    try std.testing.expectEqual(@as(i16, 0), sampleLE(&out, 0));
    try std.testing.expectEqual(@as(i16, 0), sampleLE(&out, 1));
}
