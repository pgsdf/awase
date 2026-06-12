const std = @import("std");
const semadraw = @import("semadraw");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.log.err("usage: {s} out.sdcs", .{args[0]});
        return error.InvalidArgument;
    }

    var file = try std.fs.cwd().createFile(args[1], .{ .truncate = true });
    defer file.close();

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
    try enc.writeToFile(file);
}
