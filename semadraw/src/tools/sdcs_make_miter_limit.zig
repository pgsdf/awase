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

    // Left: miter join with default limit (4.0) - should show miter corners (green)
    // For 90-degree corners, miter ratio = sqrt(2) ≈ 1.414, which is < 4.0
    try enc.setStrokeJoin(.Miter);
    // Default miter limit is 4.0
    try enc.strokeLine(40.0, 40.0, 100.0, 40.0, 16.0, 0.2, 0.8, 0.3, 0.8);
    try enc.strokeLine(40.0, 40.0, 40.0, 100.0, 16.0, 0.2, 0.8, 0.3, 0.8);

    // Middle: miter join with limit 1.0 - should fall back to bevel (orange)
    // For 90-degree corners, miter ratio = sqrt(2) ≈ 1.414 > 1.0, so bevel is used
    try enc.setMiterLimit(1.0);
    try enc.strokeLine(128.0, 40.0, 188.0, 40.0, 16.0, 0.9, 0.5, 0.2, 0.8);
    try enc.strokeLine(128.0, 40.0, 128.0, 100.0, 16.0, 0.9, 0.5, 0.2, 0.8);

    // Right: miter join with limit 2.0 - should still show miter (blue)
    // For 90-degree corners, miter ratio = sqrt(2) ≈ 1.414 < 2.0, so miter is used
    try enc.setMiterLimit(2.0);
    try enc.strokeLine(216.0, 40.0, 156.0, 40.0, 16.0, 0.3, 0.5, 0.9, 0.8);
    try enc.strokeLine(216.0, 40.0, 216.0, 100.0, 16.0, 0.3, 0.5, 0.9, 0.8);

    // Bottom row: demonstrate with larger stroke widths
    // Left: default limit, miter visible
    try enc.setMiterLimit(4.0);
    try enc.strokeLine(40.0, 140.0, 100.0, 140.0, 24.0, 0.8, 0.3, 0.8, 0.75);
    try enc.strokeLine(40.0, 140.0, 40.0, 200.0, 24.0, 0.8, 0.3, 0.8, 0.75);

    // Middle: limit 1.0, bevel (no corner fill)
    try enc.setMiterLimit(1.0);
    try enc.strokeLine(128.0, 140.0, 188.0, 140.0, 24.0, 0.8, 0.8, 0.3, 0.75);
    try enc.strokeLine(128.0, 140.0, 128.0, 200.0, 24.0, 0.8, 0.8, 0.3, 0.75);

    // Right: limit at threshold (sqrt(2) + epsilon), should show miter
    try enc.setMiterLimit(1.42);
    try enc.strokeLine(216.0, 140.0, 156.0, 140.0, 24.0, 0.3, 0.8, 0.8, 0.75);
    try enc.strokeLine(216.0, 140.0, 216.0, 200.0, 24.0, 0.3, 0.8, 0.8, 0.75);

    try enc.end();
    try enc.writeToFile(fd);
}
