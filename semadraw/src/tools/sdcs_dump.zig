const std = @import("std");
const compat = @import("compat");
const sdcs = @import("sdcs");
const posix = std.posix;


// Owned raw-posix read/seek idioms (Zig 0.16 removed std.fs.File). This tool's
// fs surface is read-only SDCS inspection.
fn openReadOnly(path: []const u8) !posix.fd_t {
    var path_buf = try posix.toPosixPath(path);
    const fd = posix.system.open(&path_buf, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    return fd;
}
fn seekByFd(fd: posix.fd_t, delta: i64) !void {
    if (posix.system.lseek(fd, delta, posix.SEEK.CUR) < 0) return error.SeekFailed;
}
fn readExact(fd: posix.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.read(fd, buf[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}

fn opcodeName(op: u16) []const u8 {
    return switch (op) {
        sdcs.Op.FILL_RECT => "FILL_RECT",
        sdcs.Op.END => "END",
        sdcs.Op.RESET => "RESET",
        sdcs.Op.SET_CLIP_RECTS => "SET_CLIP_RECTS",
        sdcs.Op.CLEAR_CLIP => "CLEAR_CLIP",
        sdcs.Op.SET_BLEND => "SET_BLEND",
        sdcs.Op.SET_TRANSFORM_2D => "SET_TRANSFORM_2D",
        sdcs.Op.RESET_TRANSFORM => "RESET_TRANSFORM",
        sdcs.Op.STROKE_RECT => "STROKE_RECT",
        sdcs.Op.BLIT_IMAGE => "BLIT_IMAGE",
        sdcs.Op.DRAW_GLYPH_RUN => "DRAW_GLYPH_RUN",
        else => "UNKNOWN",
    };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args_owned = try compat.args.alloc(alloc, init.args);
    defer args_owned.deinit(alloc);
    const args = args_owned.argv;

    if (args.len < 2) {
        std.log.err("usage: {s} file.sdcs", .{args[0]});
        return error.InvalidArgument;
    }

    const fd = try openReadOnly(args[1]);
    defer _ = posix.system.close(fd);

    var h: sdcs.Header = undefined;
    try readExact(fd, std.mem.asBytes(&h));
    if (!std.mem.eql(u8, h.magic[0..], sdcs.Magic)) return error.Protocol;

    std.debug.print("SDCS {d}.{d}\n", .{ h.version_major, h.version_minor });

    while (true) {
        var ch: sdcs.ChunkHeader = undefined;
        const got = posix.read(fd, std.mem.asBytes(&ch)) catch return;
        if (got == 0) break;
        if (got != @sizeOf(sdcs.ChunkHeader)) break;

        const t = ch.type;
        var four: [4]u8 = .{
            @intCast(t & 0xFF),
            @intCast((t >> 8) & 0xFF),
            @intCast((t >> 16) & 0xFF),
            @intCast((t >> 24) & 0xFF),
        };
        std.debug.print("chunk {s} payload {d}\n", .{ four[0..], ch.payload_bytes });

        if (ch.type == sdcs.ChunkType.CMDS) {
            var remaining: usize = @intCast(ch.payload_bytes);
            while (remaining >= @sizeOf(sdcs.CmdHdr)) {
                var cmd: sdcs.CmdHdr = undefined;
                try readExact(fd, std.mem.asBytes(&cmd));
                remaining -= @sizeOf(sdcs.CmdHdr);

                const pb: usize = @intCast(cmd.payload_bytes);
                std.debug.print("  op 0x{X:0>4} {s} payload {d}\n", .{ cmd.opcode, opcodeName(cmd.opcode), pb });
                if (pb > remaining) return error.Protocol;
                try seekByFd(fd, @intCast(pb));
                remaining -= pb;

                const pad = sdcs.pad8Len(@sizeOf(sdcs.CmdHdr) + pb);
                if (pad > remaining) return error.Protocol;
                if (pad != 0) try seekByFd(fd, @intCast(pad));
                remaining -= pad;

                if (cmd.opcode == sdcs.Op.END) break;
            }
            break;
        } else {
            try seekByFd(fd, @intCast(ch.payload_bytes));
        }
    }
}
