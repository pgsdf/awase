const std = @import("std");
const posix = std.posix;
const compat = @import("compat");
const semadraw = @import("semadraw");

// Minimal generator for a round join.
//
// Produces a small SDCS stream containing two connected STROKE_LINE commands that
// meet at a right angle with StrokeJoin.Round enabled.

// Owned raw-posix create idiom (Zig 0.16 removed std.fs.File). The fd feeds
// Encoder.writeToFile, which writes through the surviving posix.system surface.
fn openCreateRdwr(path: []const u8, mode: posix.mode_t) !posix.fd_t {
    var path_buf = try posix.toPosixPath(path);
    const fd = posix.system.open(&path_buf, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, mode);
    if (fd < 0) return error.OpenFailed;
    return fd;
}
pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args_owned = try compat.args.alloc(alloc, init.args);
    defer args_owned.deinit(alloc);
    const args = args_owned.argv;

    if (args.len != 2) {
        std.log.err("usage: {s} <out.sdcs>", .{args[0]});
        return error.InvalidArgs;
    }

    const out_path = args[1];

    const fd = try openCreateRdwr(out_path, 0o644);
    defer _ = posix.system.close(fd);

    var enc = semadraw.Encoder.init(alloc);
    defer enc.deinit();

    try enc.reset();

    // Stroke style.
    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);
    const stroke_w: f32 = 18.0;
    const cr: f32 = 0.1;
    const cg: f32 = 0.6;
    const cb: f32 = 0.9;
    const ca: f32 = 1.0;
    try enc.setStrokeJoin(.Round);

    // An L shape.
    try enc.strokeLine(64.0, 64.0, 192.0, 64.0, stroke_w, cr, cg, cb, ca);
    try enc.strokeLine(192.0, 64.0, 192.0, 192.0, stroke_w, cr, cg, cb, ca);

    try enc.end();
    try enc.writeToFile(fd);
}
