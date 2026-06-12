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

    try enc.setStrokeCap(.Round);

    // Horizontal and vertical lines, endpoints should be round
    try enc.strokeLine(32.0, 64.0, 224.0, 64.0, 18.0, 0.25, 0.75, 0.95, 0.85);
    try enc.strokeLine(128.0, 96.0, 128.0, 224.0, 18.0, 0.95, 0.55, 0.25, 0.80);

    // Clip interaction
    var clips = [_]semadraw.Encoder.Rect{ .{ .x = 16.0, .y = 16.0, .w = 224.0, .h = 224.0 } };
    try enc.setClipRects(&clips);
    try enc.strokeLine(16.0, 16.0, 240.0, 240.0, 10.0, 0.35, 0.95, 0.45, 0.70);
    try enc.clearClip();

    try enc.end();
    try enc.writeToFile(file);
}
