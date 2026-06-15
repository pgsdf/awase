// F.5.e (ADR 0027 Decision 5): semasound-dump, the surface inspector in the
// clock_dump / audiofs_events_dump pattern. STRICTLY READ-ONLY, permanently
// (operator note): this tool must never modify any surface.
//
// Usage: semasound-dump        print every target's surfaces once
//        semasound-dump -f     additionally follow events (poll by seq)
//
// Reads /var/run/sema/audio/<target>/. No broker dependency: a dead
// broker's last-published state still prints (itself diagnostic; check
// publish_ts staleness in `state`).

const std = @import("std");
const compat = @import("compat");

const RUN_BASE = "/var/run/sema/audio";
const FILES = [_][]const u8{
    "identity",     "version",       "backend",       "device",
    "capabilities", "policy-valid",  "policy-errors", "policy-state",
    "state",        "clients",       "last-event",
};
const MAX_TARGETS = 8;
const NAME_LEN = 32;

// Read a whole surface file into `buf` via the std.Io route (compat.fs over a
// blocking Io). Returns bytes read, or null when the file is absent. This is a
// read-only diagnostic surface, so the boundary's std.Io layer is used rather
// than the owned raw-posix route reserved for persistence and mmap paths.
fn readFileInto(io: std.Io, path: []const u8, buf: []u8) ?usize {
    var f = compat.fs.cwd(io).openFile(path) catch return null;
    defer f.close();
    var n: usize = 0;
    while (n < buf.len) {
        const r = f.read(buf[n..]) catch break;
        if (r == 0) break;
        n += r;
    }
    return n;
}

fn printFile(io: std.Io, dirpath: []const u8, name: []const u8) void {
    var pathbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pathbuf, "{s}/{s}", .{ dirpath, name }) catch {
        std.debug.print("  {s}: <absent>\n", .{name});
        return;
    };
    var buf: [32 * 1024]u8 = undefined;
    const n = readFileInto(io, path, &buf) orelse {
        std.debug.print("  {s}: <absent>\n", .{name});
        return;
    };
    const content = std.mem.trimEnd(u8, buf[0..n], "\n");
    if (content.len == 0) {
        std.debug.print("  {s}: <empty>\n", .{name});
    } else if (std.mem.indexOfScalar(u8, content, '\n') == null) {
        std.debug.print("  {s}: {s}\n", .{ name, content });
    } else {
        std.debug.print("  {s}:\n", .{name});
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |l| std.debug.print("    {s}\n", .{l});
    }
}

fn eventSeq(line: []const u8) u64 {
    // lines start "seq=N ..."
    if (!std.mem.startsWith(u8, line, "seq=")) return 0;
    const rest = line[4..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return std.fmt.parseInt(u64, rest[0..sp], 10) catch 0;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var follow = false;
    const args_owned = try compat.args.alloc(std.heap.page_allocator, init.args);
    defer args_owned.deinit(std.heap.page_allocator);
    const args = args_owned.argv;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "-f")) follow = true;
    }

    var names: [MAX_TARGETS][NAME_LEN]u8 = undefined;
    var name_lens: [MAX_TARGETS]usize = undefined;
    var ntargets: usize = 0;

    var io_ctx = compat.io.open(std.heap.page_allocator) catch {
        std.debug.print("semasound-dump: cannot initialize I/O\n", .{});
        return;
    };
    defer io_ctx.deinit();
    const io = io_ctx.io();

    var base = std.Io.Dir.cwd().openDir(io, RUN_BASE, .{ .iterate = true }) catch {
        std.debug.print("semasound-dump: {s} absent (broker never ran?)\n", .{RUN_BASE});
        return;
    };
    defer base.close(io);

    var it = base.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        if (ntargets >= MAX_TARGETS) break;
        const n = @min(e.name.len, NAME_LEN);
        @memcpy(names[ntargets][0..n], e.name[0..n]);
        name_lens[ntargets] = n;
        ntargets += 1;
    }

    var ti: usize = 0;
    while (ti < ntargets) : (ti += 1) {
        const tname = names[ti][0..name_lens[ti]];
        std.debug.print("== target {s} ==\n", .{tname});
        var dirbuf: [512]u8 = undefined;
        const dirpath = std.fmt.bufPrint(&dirbuf, "{s}/{s}", .{ RUN_BASE, tname }) catch continue;
        for (FILES) |fname| printFile(io, dirpath, fname);
        std.debug.print("\n", .{});
    }

    if (!follow) return;

    std.debug.print("-- following events (interrupt to stop) --\n", .{});
    var last_seq: [MAX_TARGETS]u64 = [_]u64{0} ** MAX_TARGETS;
    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        ti = 0;
        while (ti < ntargets) : (ti += 1) {
            const tname = names[ti][0..name_lens[ti]];
            var ebuf: [512]u8 = undefined;
            const epath = std.fmt.bufPrint(&ebuf, "{s}/{s}/events", .{ RUN_BASE, tname }) catch continue;
            const n = readFileInto(io, epath, &buf) orelse continue;
            var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
            while (lines.next()) |l| {
                if (l.len == 0) continue;
                const sq = eventSeq(l);
                if (sq > last_seq[ti]) {
                    std.debug.print("[{s}] {s}\n", .{ tname, l });
                    last_seq[ti] = sq;
                }
            }
        }
        compat.time.sleep(compat.time.Duration.fromNanoseconds(500_000_000));
    }
}
