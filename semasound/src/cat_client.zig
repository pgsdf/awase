// semasound-cat: generic stdin-to-socket PCM client.
//
// Connects to the semasound socket, sends a v3 Hello, and copies raw
// interleaved 16-bit LE PCM from stdin to the socket until EOF. The
// decode-anything companion to semasound-tone: any external decoder that
// can emit s16le becomes a semasound source, e.g.
//
//   ffmpeg -i song.mp3 -f s16le -ar 48000 -ac 2 - | \
//       semasound-cat --label mp3 --class music
//
// 48 kHz stereo is the bit-exact passthrough; any rateSupported rate or
// mono is accepted and adapted broker-side (F.5.b). Pacing is purely
// blocking: the broker drains the socket at the hardware rate and
// backpressure holds the pipeline (and ffmpeg behind it) to real time.
//
// Usage: semasound-cat [--rate N] [--mono] [--gain G] [--target NAME]
//        [--label NAME] [--class TOKEN]
// --gain G scales samples client-side by G in [0.0, 1.0] (default 1.0),
// saturating-safe since attenuation cannot overflow i16.
// Exit codes: 0 clean EOF, 2 rejected at hello, 3 preempted mid-stream
// by policy (ADR 0026 Decision 6).

const std = @import("std");
const compat = @import("compat");
const posix = std.posix;
const protocol = @import("protocol.zig");

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const slice = bytes[off..];
        const n = posix.system.write(fd, slice.ptr, slice.len);
        if (n < 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var rate: u32 = protocol.CANON_RATE; // --rate N: declared stdin rate
    var mono: bool = false; // --mono: stdin is 16-bit mono
    var gain_milli: u32 = 1000; // --gain G: client-side attenuation, unity = 1000
    var target_name: []const u8 = "";
    var label_name: []const u8 = "";
    var class_name: []const u8 = "";

    const args_owned = try compat.args.alloc(std.heap.page_allocator, init.args);
    defer args_owned.deinit(std.heap.page_allocator);
    const args = args_owned.argv;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--rate")) {
            i += 1;
            if (i < args.len) rate = std.fmt.parseInt(u32, args[i], 10) catch rate;
        } else if (std.mem.eql(u8, a, "--mono")) {
            mono = true;
        } else if (std.mem.eql(u8, a, "--gain")) {
            i += 1;
            if (i < args.len) {
                const g = std.fmt.parseFloat(f64, args[i]) catch 1.0;
                if (g >= 0.0 and g <= 1.0) gain_milli = @intFromFloat(@round(g * 1000.0));
            }
        } else if (std.mem.eql(u8, a, "--target")) {
            i += 1;
            if (i < args.len) target_name = args[i];
        } else if (std.mem.eql(u8, a, "--label")) {
            i += 1;
            if (i < args.len) label_name = args[i];
        } else if (std.mem.eql(u8, a, "--class")) {
            i += 1;
            if (i < args.len) class_name = args[i];
        } else {
            std.debug.print("semasound-cat: unknown argument '{s}'\n", .{a});
            std.process.exit(1);
        }
    }

    const fd = try compat.posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer _ = posix.system.close(fd);
    var addr: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = [_]u8{0} ** 104,
    };
    @memcpy(addr.path[0..protocol.SOCKET_PATH.len], protocol.SOCKET_PATH);
    try compat.posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

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
        .version = protocol.HELLO_VERSION,
        .format = protocol.CANON_FORMAT,
        .rate_hz = rate,
        .channels = if (mono) @as(u16, 1) else protocol.CANON_CHANNELS,
        ._pad = 0,
        .target = target_buf,
        .label = label_buf,
        .class = class_buf,
    };
    try writeAll(fd, std.mem.asBytes(&hello));

    var status: [1]u8 = undefined;
    const sn = try posix.read(fd, &status);
    if (sn == 0 or status[0] != protocol.STATUS_ACCEPTED) {
        std.debug.print("semasound-cat: rejected (status {d})\n", .{if (sn == 0) @as(u8, 255) else status[0]});
        std.process.exit(2);
    }

    // Copy stdin to the socket until EOF. Chunk size matches the tone
    // client; blocking writes against the broker are the pacing.
    var chunk: [4096]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const rn = posix.read(0, &chunk) catch |e| {
            std.debug.print("semasound-cat: stdin read failed ({s})\n", .{@errorName(e)});
            std.process.exit(1);
        };
        if (rn == 0) break; // EOF: decoder finished
        if (gain_milli != 1000) {
            // Attenuate in place. Samples are interleaved s16le; scale
            // each in i32 (mirrors the broker's milli-gain convention,
            // mixer.mixGains). rn may be odd only at a truncated final
            // read; the trailing byte passes through unscaled.
            var off: usize = 0;
            while (off + 2 <= rn) : (off += 2) {
                const lo: u16 = chunk[off];
                const hi: u16 = @as(u16, chunk[off + 1]) << 8;
                const v: i16 = @bitCast(lo | hi);
                const scaled: i32 = @divTrunc(@as(i32, v) * @as(i32, @intCast(gain_milli)), 1000);
                const u: u16 = @bitCast(@as(i16, @intCast(scaled)));
                chunk[off] = @truncate(u);
                chunk[off + 1] = @truncate(u >> 8);
            }
        }
        writeAll(fd, chunk[0..rn]) catch |e| {
            // A mid-stream write failure may be a group preemption; the
            // broker queues STATUS_PREEMPTED before shutting the socket
            // down (ADR 0026 Decision 6). Drain one status byte to find out.
            var st: [1]u8 = undefined;
            const drn = posix.read(fd, &st) catch 0;
            if (drn == 1 and st[0] == protocol.STATUS_PREEMPTED) {
                std.debug.print("semasound-cat: preempted by policy (group exclusivity)\n", .{});
                std.process.exit(3);
            }
            return e;
        };
        total += rn;
    }

    const bpf: usize = if (mono) 2 else 4;
    const frames = total / bpf;
    const secs = @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(rate));
    std.debug.print("semasound-cat: wrote {d} frames ({d:.2}s at rate {d}, {s})\n", .{ frames, secs, rate, if (mono) "mono" else "stereo" });
}
