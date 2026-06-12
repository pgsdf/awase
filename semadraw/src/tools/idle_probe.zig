// idle_probe: connect to semadrawd and query the published last-input
// timestamp (D-11, ADR 0013). Intended for bare-metal verification of
// the idle signal that SM-2 and SM-3 consume.
//
// The daemon publishes last_input_ts_ns (chronofs ns) via the
// idle_query / idle_reply round-trip. This tool issues that query. It
// does NOT compute idle against a clock: idle = chronofs_now minus the
// printed value is the consumer's job (ADR 0013 D2). The probe shows
// the raw published value and, in watch mode, whether it advanced,
// which is what the D-11 bench needs to confirm:
//   - a fresh daemon returns last_input_ts_ns=0 before any input
//     (ADR 0013 D3 sentinel);
//   - the value advances after keyboard, pointer, and touch input,
//     each independently (coverage, ADR 0013 D4);
//   - a non-root caller receives fresh, advancing values, the reason
//     for the socket mechanism over the AD-34-stale mmap (ADR 0013 D1).
//
// Usage:
//   idle_probe                One-shot: print last_input_ts_ns once.
//   idle_probe --watch        Poll every 1000 ms; print each sample
//                             with the delta since the previous one.
//   idle_probe --interval MS  Poll every MS ms (implies --watch).
//   idle_probe --help         Print this message.
//
// Output (grep-friendly, one sample per line):
//   idle last_input_ts_ns=<u64>                                  (one-shot)
//   idle last_input_ts_ns=<u64> delta_ns=<i128> advanced=<yes|no> (watch)
//
// Exit:
//   - one-shot: 0 on success.
//   - watch: 0 on daemon disconnect or clean exit.
//   - connect or query failure: error to stderr, exit 1; bad args exit 2.

const std = @import("std");
const posix = std.posix;
const semadraw_client = @import("semadraw_client");

const Connection = semadraw_client.Connection;

fn writeOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(1, s) catch {};
}

fn writeErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(2, s) catch {};
}

fn usage() void {
    const text =
        \\idle_probe: query semadrawd's published last-input timestamp (D-11).
        \\
        \\Usage:
        \\  idle_probe                One-shot: print last_input_ts_ns once.
        \\  idle_probe --watch        Poll every 1000 ms; print each sample
        \\                            with the delta. Ctrl-C to quit.
        \\  idle_probe --interval MS  Poll every MS ms (implies --watch).
        \\  idle_probe --help         Print this message.
        \\
    ;
    _ = posix.write(1, text) catch {};
}

const Args = struct {
    watch: bool = false,
    interval_ms: u64 = 1000,
    help: bool = false,
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var result = Args{};
    var iter = try std.process.argsWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "--watch")) {
            result.watch = true;
        } else if (std.mem.eql(u8, arg, "--interval")) {
            const v = iter.next() orelse return error.MissingIntervalValue;
            result.interval_ms = std.fmt.parseInt(u64, v, 10) catch return error.InvalidIntervalValue;
            result.watch = true; // --interval implies --watch
        } else {
            writeErr("unknown argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }
    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = parseArgs(allocator) catch |err| {
        writeErr("argument error: {}\nrun with --help for usage\n", .{err});
        std.process.exit(2);
    };

    if (args.help) {
        usage();
        return;
    }

    var conn = Connection.connect(allocator) catch |err| {
        writeErr("failed to connect to semadrawd: {}\n", .{err});
        writeErr("hint: is the daemon running? is the socket accessible?\n", .{});
        std.process.exit(1);
    };
    defer conn.disconnect();

    if (!args.watch) {
        const v = conn.queryIdle() catch |err| {
            writeErr("idle_query failed: {}\n", .{err});
            std.process.exit(1);
        };
        writeOut("idle last_input_ts_ns={d}\n", .{v});
        return;
    }

    // Watch mode: poll every interval_ms and report whether the value
    // advanced since the previous sample. A negative delta_ns signals
    // the daemon reset the value (restart), which returns it to 0.
    const interval_ns: u64 = args.interval_ms * std.time.ns_per_ms;
    var have_prev = false;
    var prev: u64 = 0;
    while (true) {
        const v = conn.queryIdle() catch |err| {
            writeErr("idle_query failed: {}\n", .{err});
            break;
        };
        const delta: i128 = if (have_prev)
            @as(i128, v) - @as(i128, prev)
        else
            0;
        const advanced = if (delta > 0) "yes" else "no";
        writeOut("idle last_input_ts_ns={d} delta_ns={d} advanced={s}\n", .{ v, delta, advanced });
        prev = v;
        have_prev = true;
        std.Thread.sleep(interval_ns);
    }
}
