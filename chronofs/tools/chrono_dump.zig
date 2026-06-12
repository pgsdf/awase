/// chrono_dump: chronofs diagnostic tool (chronofs ADR 0001)
///
/// Default mode reports the shared audio clock: it reads
/// /var/run/sema/clock through the chronofs clock reader (the same
/// library every consumer uses), prints the decoded state, measures
/// advance across a short interval, and exits. It never blocks.
/// The audiofs tool clock_dump is the raw-region sibling; this tool
/// answers "what do clock consumers see".
///
/// Usage:
///   chrono_dump                  one clock report, then exit
///   chrono_dump -f               follow: one line per second until ^C
///   chrono_dump --replay <file>  resolve recorded EVENT_SCHEMA lines
///
/// The stdin pipeline modes (live, --drift) were removed by chronofs
/// ADR 0001 Decision 2: their producer set is empty since the semaaud
/// and semainputd retirements. --replay is retained for recorded
/// material; semaaud/semainput lines in old recordings are skipped
/// (Decision 3), leaving the visual domain.
const std = @import("std");
const resolver_mod = @import("resolver");
const stream_mod   = @import("stream");
const clock_mod    = @import("clock");

const DomainStreams = stream_mod.DomainStreams;
const Resolver      = resolver_mod.Resolver;
const Clock         = clock_mod.Clock;

const CLOCK_PATH = "/var/run/sema/clock";

// ============================================================================
// stdout/stderr helpers following codebase conventions
// ============================================================================

fn writeStdout(line: []const u8) void {
    var file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);
    w.interface.writeAll(line) catch {};
    w.interface.flush() catch {};
}

fn writeStderr(line: []const u8) void {
    var file = std.fs.File.stderr();
    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);
    w.interface.writeAll(line) catch {};
    w.interface.flush() catch {};
}

fn printFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStdout(s);
}

// ============================================================================
// CLI argument parsing
// ============================================================================

const Mode = enum { report, follow, replay };

const Args = struct {
    mode:        Mode           = .report,
    replay_path: ?[]const u8    = null,
    /// Sample rate for time display in replay mode (default 48000).
    sample_rate: u32            = 48_000,
};

fn parseArgs(argv: []const []const u8) !Args {
    var a = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-f")) {
            a.mode = .follow;
        } else if (std.mem.eql(u8, arg, "--replay")) {
            a.mode = .replay;
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            a.replay_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--rate")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            a.sample_rate = try std.fmt.parseInt(u32, argv[i], 10);
        } else {
            var ebuf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&ebuf, "chrono_dump: unknown argument: {s}\n", .{arg})
                catch "chrono_dump: unknown argument\n";
            writeStderr(msg);
            return error.UnknownArg;
        }
    }
    return a;
}

// ============================================================================
// JSON field extractors (replay support)
// ============================================================================

fn extractSubsystem(line: []const u8) ?[]const u8 {
    const key = "\"subsystem\":\"";
    const idx = std.mem.indexOf(u8, line, key) orelse return null;
    const start = idx + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    return line[start..end];
}

fn extractAudioSamples(line: []const u8) ?u64 {
    const key = "\"ts_audio_samples\":";
    const idx = std.mem.indexOf(u8, line, key) orelse return null;
    var i = idx + key.len;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    if (std.mem.startsWith(u8, line[i..], "null")) return null;
    var end = i;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseInt(u64, line[i..end], 10) catch null;
}

// ============================================================================
// Ingestion dispatcher (replay; semadraw is the only retained format,
// chronofs ADR 0001 Decision 3. Other subsystem lines are skipped.)
// ============================================================================

fn ingestLine(streams: *DomainStreams, line: []const u8) void {
    const subsystem = extractSubsystem(line) orelse return;
    if (std.mem.eql(u8, subsystem, "semadraw")) {
        resolver_mod.ingestSemadrawLine(streams, line) catch {};
    }
}

// ============================================================================
// Clock report (the default mode, chronofs ADR 0001 Decision 1)
// ============================================================================

/// Interval between the two samples of a single report, and between
/// follow-mode lines. Short enough to feel immediate, long enough that
/// a live 48 kHz clock advances by thousands of samples.
const REPORT_INTERVAL_MS: u64 = 200;
const FOLLOW_INTERVAL_MS: u64 = 1000;

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn runReport() void {
    const present = fileExists(CLOCK_PATH);
    printFmt("clock: {s}\n", .{CLOCK_PATH});

    if (!present) {
        writeStdout("  state:   absent (no publication; is the audiofs module loaded?)\n");
        return;
    }

    const clk = Clock.init(CLOCK_PATH);
    defer clk.deinit();

    if (!clk.isValid()) {
        writeStdout("  state:   invalid (region present, clock_valid=0; no stream has started)\n");
        return;
    }

    const rate = clk.sampleRate();
    const t1 = clk.now();
    std.Thread.sleep(REPORT_INTERVAL_MS * std.time.ns_per_ms);
    const t2 = clk.now();

    const frate: f64 = if (rate > 0) @as(f64, @floatFromInt(rate)) else 48_000.0;
    const secs = @as(f64, @floatFromInt(t2)) / frate;
    printFmt("  state:   valid\n", .{});
    printFmt("  rate:    {d} Hz\n", .{rate});
    printFmt("  now:     {d} samples ({d:.3} s)\n", .{ t2, secs });

    if (t2 > t1) {
        const delta = t2 - t1;
        const effective = @as(f64, @floatFromInt(delta)) /
            (@as(f64, @floatFromInt(REPORT_INTERVAL_MS)) / 1000.0);
        printFmt("  advance: +{d} samples over {d} ms -> live ({d:.1} Hz effective)\n",
            .{ delta, REPORT_INTERVAL_MS, effective });
    } else {
        printFmt("  advance: 0 samples over {d} ms -> paused (no active stream)\n",
            .{REPORT_INTERVAL_MS});
    }
}

fn runFollow() void {
    var last: ?u64 = null;
    while (true) {
        if (!fileExists(CLOCK_PATH)) {
            writeStdout("clock absent\n");
            last = null;
        } else {
            const clk = Clock.init(CLOCK_PATH);
            defer clk.deinit();
            if (!clk.isValid()) {
                writeStdout("clock invalid (clock_valid=0)\n");
                last = null;
            } else {
                const t = clk.now();
                const rate = clk.sampleRate();
                const frate: f64 = if (rate > 0) @as(f64, @floatFromInt(rate)) else 48_000.0;
                const secs = @as(f64, @floatFromInt(t)) / frate;
                if (last) |prev| {
                    const delta: i64 = @as(i64, @intCast(t)) - @as(i64, @intCast(prev));
                    const state: []const u8 = if (delta > 0) "live" else "paused";
                    printFmt("t={d:<14} ({d:.3} s)  delta={d:<8} rate={d} Hz  {s}\n",
                        .{ t, secs, delta, rate, state });
                } else {
                    printFmt("t={d:<14} ({d:.3} s)  rate={d} Hz\n", .{ t, secs, rate });
                }
                last = t;
            }
        }
        std.Thread.sleep(FOLLOW_INTERVAL_MS * std.time.ns_per_ms);
    }
}

// ============================================================================
// Replay mode (retained unchanged in behaviour; chronofs ADR 0001
// Decision 2. Audio/input domains of old recordings resolve to (none)
// since their ingestion arms are removed, Decision 3.)
// ============================================================================

fn runReplay(args: Args, allocator: std.mem.Allocator) !void {
    const path = args.replay_path orelse return error.MissingReplayPath;

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(content);

    var streams = DomainStreams.init();
    var max_t: u64 = 0;

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        ingestLine(&streams, line);
        if (extractAudioSamples(line)) |t| {
            if (t > max_t) max_t = t;
        }
    }

    if (max_t == 0) {
        writeStdout("chrono_dump: no audio-timestamped events in replay file\n");
        return;
    }

    const clk = Clock.init("/var/run/sema/clock_c5_replay_absent");
    defer clk.deinit();
    const r = Resolver.init(&streams, clk);

    const interval: u64 = 1000;
    const rate: f64 = if (args.sample_rate > 0)
        @as(f64, @floatFromInt(args.sample_rate)) else 48_000.0;

    var t: u64 = 0;
    while (t <= max_t + interval) : (t += interval) {
        const secs = @as(f64, @floatFromInt(t)) / rate;
        printFmt("t={d:<12} ({d:.3}s)\n", .{ t, secs });

        const state = r.resolveAll(t);

        if (state.audio) |a| {
            printFmt("  audio:  stream_id={d} samples_written={d} active={}\n",
                .{ a.stream_id, a.samples_written, a.active });
        } else {
            writeStdout("  audio:  (none)\n");
        }

        if (state.visual) |v| {
            printFmt("  visual: surface_id={d} frame={d}\n",
                .{ v.surface_id, v.frame_number });
        } else {
            writeStdout("  visual: (none)\n");
        }

        if (state.input) |inp| {
            printFmt("  input:  {s} device={s}\n",
                .{ inp.typeName(), inp.deviceName() });
        } else {
            writeStdout("  input:  (none)\n");
        }
    }
}

// ============================================================================
// Entry point
// ============================================================================

const USAGE =
    \\Usage: chrono_dump [-f] [--replay <file>] [--rate <hz>]
    \\
    \\  (no flags)      Report the shared audio clock at /var/run/sema/clock
    \\                  (state, rate, position, advance) and exit. Never blocks.
    \\  -f              Follow: print one clock line per second until ^C.
    \\  --replay <file> Read a recorded EVENT_SCHEMA log file, print resolved
    \\                  state at every 1000-sample interval.
    \\  --rate <hz>     Sample rate for replay time display (default: 48000).
    \\
    \\Examples:
    \\  chrono_dump
    \\  chrono_dump -f
    \\  chrono_dump --replay fabric.log --rate 48000
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const args = parseArgs(argv) catch {
        writeStderr(USAGE);
        return;
    };

    switch (args.mode) {
        .report => runReport(),
        .follow => runFollow(),
        .replay => try runReplay(args, allocator),
    }
}
