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

const RUN_BASE = "/var/run/sema/audio";
const FILES = [_][]const u8{
    "identity",     "version",       "backend",       "device",
    "capabilities", "policy-valid",  "policy-errors", "policy-state",
    "state",        "clients",       "last-event",
};
const MAX_TARGETS = 8;
const NAME_LEN = 32;

fn printFile(dir: std.fs.Dir, name: []const u8) void {
    var buf: [32 * 1024]u8 = undefined;
    const f = dir.openFile(name, .{}) catch {
        std.debug.print("  {s}: <absent>\n", .{name});
        return;
    };
    defer f.close();
    const n = f.readAll(&buf) catch 0;
    const content = std.mem.trimRight(u8, buf[0..n], "\n");
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

pub fn main() !void {
    var follow = false;
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "-f")) follow = true;
    }

    var names: [MAX_TARGETS][NAME_LEN]u8 = undefined;
    var name_lens: [MAX_TARGETS]usize = undefined;
    var ntargets: usize = 0;

    var base = std.fs.cwd().openDir(RUN_BASE, .{ .iterate = true }) catch {
        std.debug.print("semasound-dump: {s} absent (broker never ran?)\n", .{RUN_BASE});
        return;
    };
    defer base.close();

    var it = base.iterate();
    while (try it.next()) |e| {
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
        var td = base.openDir(tname, .{}) catch continue;
        defer td.close();
        for (FILES) |fname| printFile(td, fname);
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
            var td = base.openDir(tname, .{}) catch continue;
            defer td.close();
            const f = td.openFile("events", .{}) catch continue;
            const n = f.readAll(&buf) catch 0;
            f.close();
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
        std.Thread.sleep(500_000_000);
    }
}
