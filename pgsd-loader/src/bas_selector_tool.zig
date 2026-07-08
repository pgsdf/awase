// bas-selector: host-side selector tool implementing sections 7.1
// through 7.3 of BOOT-ARTIFACT-STORE 0.3. Subcommands:
//   init <file>                    preallocate 1024 zero bytes
//                                  (destroyed state: reader falls
//                                  back, section 10)
//   show <file>                    print both records and the winner
//   commit <file> <slot> <sha256>  overwrite the losing record with
//                                  generation max+1 (7.3), fsync
// The commit is a single 512-byte pwrite into existing allocation:
// no directory entry and no FAT chain in the commit path.

const std = @import("std");
const bas = @import("bas.zig");
const posix = std.posix;

fn die(msg: []const u8) noreturn {
    std.debug.print("bas-selector: {s}\n", .{msg});
    std.process.exit(1);
}

/// Machine-readable output goes to STDOUT (raw fd 1): callers parse
/// it, and std.debug.print writes stderr, which a $() capture never
/// sees. That mismatch armed nothing in the publish script's active
/// slot guard and let a live slot be rewritten; hence this helper.
fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.posix.system.write(1, s.ptr, s.len);
}

fn readImage(fd: posix.fd_t) [bas.selector_size]u8 {
    var img: [bas.selector_size]u8 = undefined;
    const n = posix.system.pread(fd, &img, bas.selector_size, 0);
    if (n != bas.selector_size) die("selector is not exactly 1024 bytes");
    return img;
}

fn hex(b: []const u8, dst: []u8) []const u8 {
    const digits = "0123456789abcdef";
    for (b, 0..) |c, i| {
        dst[i * 2] = digits[c >> 4];
        dst[i * 2 + 1] = digits[c & 0xf];
    }
    return dst[0 .. b.len * 2];
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args_buf: [8][]const u8 = undefined;
    var n_args: usize = 0;
    var it = std.process.Args.Iterator.init(init.args);
    while (it.next()) |a| {
        if (n_args == args_buf.len) die("too many arguments");
        args_buf[n_args] = a;
        n_args += 1;
    }
    const args = args_buf[0..n_args];
    if (args.len < 3) die("usage: init|show|commit <file> [slot sha256hex]");
    const cmd = args[1];
    const path = args[2];

    if (std.mem.eql(u8, cmd, "init")) {
        const fd = posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644) catch
            die("cannot create (exists already?)");
        defer _ = posix.system.close(fd);
        const zeros = [_]u8{0} ** bas.selector_size;
        const n = posix.system.write(fd, &zeros, bas.selector_size);
        if (n != bas.selector_size) die("short write");
        if (posix.system.fsync(fd) != 0) die("fsync failed");
        out("initialized {s}: 1024 bytes, both records invalid (destroyed state)\n", .{path});
        return;
    }

    const fd = posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDWR }, 0) catch die("cannot open selector");
    defer _ = posix.system.close(fd);
    var img = readImage(fd);
    const rr = bas.read(&img);

    if (std.mem.eql(u8, cmd, "show")) {
        for (0..2) |i| {
            const rec = bas.Record.decode(img[i * bas.record_size ..][0..bas.record_size]);
            if (rec) |r| {
                var hb: [64]u8 = undefined;
                out("record {d}: valid gen={d} slot={d} manifest={s}\n", .{ i, r.generation, r.active_slot, hex(&r.manifest_sha256, &hb) });
            } else {
                out("record {d}: invalid\n", .{i});
            }
        }
        if (rr.winner) |w| {
            out("winner: gen={d} slot={d}\n", .{ w.generation, w.active_slot });
        } else {
            out("winner: none (destroyed selector, reader falls back)\n", .{});
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "commit")) {
        if (args.len != 5) die("usage: commit <file> <slot> <sha256hex>");
        const slot = std.fmt.parseInt(u32, args[3], 10) catch die("bad slot number");
        if (args[4].len != 64) die("manifest sha256 must be 64 hex chars");
        var mh: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&mh, args[4]) catch die("bad sha256 hex");
        const gen: u64 = if (rr.winner) |w| w.generation + 1 else 1;
        const rec = bas.Record{ .generation = gen, .active_slot = slot, .manifest_sha256 = mh };
        const enc = rec.encode();
        const off: i64 = @as(i64, rr.loser_index) * bas.record_size;
        const n = posix.system.pwrite(fd, &enc, bas.record_size, off);
        if (n != bas.record_size) die("short pwrite");
        if (posix.system.fsync(fd) != 0) die("fsync failed");
        // Read back and confirm the winner is what we just wrote
        // (verification precedes success report, I4/I5 spirit).
        img = readImage(fd);
        const after = bas.read(&img);
        if (after.winner == null or after.winner.?.generation != gen or after.winner.?.active_slot != slot)
            die("post-commit verification failed");
        out("committed: record {d}, gen={d}, slot={d}\n", .{ rr.loser_index, gen, slot });
        return;
    }
    die("unknown subcommand");
}
