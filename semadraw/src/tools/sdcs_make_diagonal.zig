const std = @import("std");
const semadraw = @import("semadraw");

/// Test generator for non-axis-aligned (diagonal) lines.
/// Demonstrates STROKE_LINE v2 with arbitrary angles.
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

    // Dark background
    try enc.setBlend(semadraw.Encoder.BlendMode.Src);
    try enc.fillRect(0.0, 0.0, 256.0, 256.0, 0.05, 0.05, 0.1, 1.0);

    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);

    // Diagonal line: 45 degrees (bottom-left to top-right)
    try enc.strokeLine(32.0, 224.0, 224.0, 32.0, 12.0, 0.9, 0.3, 0.2, 0.9);

    // Diagonal line: 135 degrees (bottom-right to top-left)
    try enc.strokeLine(224.0, 224.0, 32.0, 32.0, 8.0, 0.2, 0.8, 0.4, 0.85);

    // Shallow angle line
    try enc.strokeLine(16.0, 128.0, 240.0, 96.0, 10.0, 0.3, 0.5, 0.95, 0.8);

    // Steep angle line
    try enc.strokeLine(128.0, 16.0, 160.0, 240.0, 6.0, 0.95, 0.8, 0.2, 0.75);

    // Short diagonal
    try enc.strokeLine(180.0, 180.0, 220.0, 220.0, 14.0, 0.7, 0.2, 0.9, 0.7);

    // Test with clipping
    var clips = [_]semadraw.Encoder.Rect{
        .{ .x = 48.0, .y = 48.0, .w = 160.0, .h = 160.0 },
    };
    try enc.setClipRects(&clips);

    // Clipped diagonal line
    try enc.strokeLine(24.0, 180.0, 232.0, 76.0, 16.0, 1.0, 0.6, 0.1, 0.65);

    try enc.clearClip();

    try enc.end();
    try enc.writeToFile(file);
}
