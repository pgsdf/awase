const std = @import("std");
const posix = std.posix;
const compat = @import("compat");
const semadraw = @import("semadraw");


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

    if (args.len < 2) {
        std.log.err("usage: {s} out.sdcs", .{args[0]});
        return error.InvalidArgument;
    }

    const fd = try openCreateRdwr(args[1], 0o644);
    defer _ = posix.system.close(fd);

    var enc = semadraw.Encoder.init(alloc);
    defer enc.deinit();

    try enc.reset();
    try enc.setBlend(semadraw.Encoder.BlendMode.Src);
    try enc.fillRect(0.0, 0.0, 256.0, 256.0, 0.07, 0.07, 0.07, 1.0);
    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);

    // Top: Butt caps (green)
    try enc.setStrokeCap(.Butt);
    try enc.strokeLine(32.0, 48.0, 224.0, 48.0, 18.0, 0.2, 0.85, 0.35, 0.85);
    try enc.strokeLine(64.0, 80.0, 64.0, 176.0, 18.0, 0.2, 0.85, 0.35, 0.85);

    // Bottom: Square caps (orange)
    try enc.setStrokeCap(.Square);
    try enc.strokeLine(32.0, 208.0, 224.0, 208.0, 18.0, 0.92, 0.45, 0.2, 0.80);
    try enc.strokeLine(192.0, 176.0, 192.0, 80.0, 18.0, 0.92, 0.45, 0.2, 0.80);

    // Clip interaction (blue square caps)
    var clips = [_]semadraw.Encoder.Rect{ .{ .x = 16.0, .y = 16.0, .w = 224.0, .h = 224.0 } };
    try enc.setClipRects(&clips);
    try enc.setStrokeCap(.Square);
    try enc.strokeLine(128.0, 128.0, 200.0, 128.0, 10.0, 0.3, 0.6, 1.0, 0.60);
    try enc.strokeLine(128.0, 128.0, 128.0, 200.0, 10.0, 0.3, 0.6, 1.0, 0.60);
    try enc.clearClip();

    try enc.end();
    try enc.writeToFile(fd);
}
