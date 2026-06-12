const std = @import("std");
const semadraw = @import("semadraw");

/// Test generator for STROKE_PATH (polyline paths).
/// Creates various path shapes to test the path rendering implementation.
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
    try enc.fillRect(0.0, 0.0, 256.0, 256.0, 0.1, 0.1, 0.15, 1.0);

    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);

    // === Simple polyline ===
    const simple_path = [_]semadraw.Encoder.Point{
        .{ .x = 20.0, .y = 30.0 },
        .{ .x = 60.0, .y = 30.0 },
        .{ .x = 60.0, .y = 70.0 },
        .{ .x = 100.0, .y = 70.0 },
    };
    try enc.strokePath(&simple_path, 3.0, 1.0, 0.4, 0.2, 1.0); // orange

    // === Zigzag path ===
    const zigzag_path = [_]semadraw.Encoder.Point{
        .{ .x = 120.0, .y = 30.0 },
        .{ .x = 140.0, .y = 60.0 },
        .{ .x = 160.0, .y = 30.0 },
        .{ .x = 180.0, .y = 60.0 },
        .{ .x = 200.0, .y = 30.0 },
    };
    try enc.strokePath(&zigzag_path, 2.5, 0.2, 0.8, 0.4, 1.0); // green

    // === Staircase path with miter joins ===
    try enc.setStrokeJoin(.Miter);
    const stair_path = [_]semadraw.Encoder.Point{
        .{ .x = 20.0, .y = 100.0 },
        .{ .x = 40.0, .y = 100.0 },
        .{ .x = 40.0, .y = 120.0 },
        .{ .x = 60.0, .y = 120.0 },
        .{ .x = 60.0, .y = 140.0 },
        .{ .x = 80.0, .y = 140.0 },
        .{ .x = 80.0, .y = 160.0 },
    };
    try enc.strokePath(&stair_path, 4.0, 0.3, 0.5, 1.0, 1.0); // blue

    // === Staircase path with round joins ===
    try enc.setStrokeJoin(.Round);
    const stair_path2 = [_]semadraw.Encoder.Point{
        .{ .x = 100.0, .y = 100.0 },
        .{ .x = 120.0, .y = 100.0 },
        .{ .x = 120.0, .y = 120.0 },
        .{ .x = 140.0, .y = 120.0 },
        .{ .x = 140.0, .y = 140.0 },
        .{ .x = 160.0, .y = 140.0 },
        .{ .x = 160.0, .y = 160.0 },
    };
    try enc.strokePath(&stair_path2, 4.0, 1.0, 0.8, 0.2, 1.0); // yellow

    // === Staircase path with bevel joins ===
    try enc.setStrokeJoin(.Bevel);
    const stair_path3 = [_]semadraw.Encoder.Point{
        .{ .x = 180.0, .y = 100.0 },
        .{ .x = 200.0, .y = 100.0 },
        .{ .x = 200.0, .y = 120.0 },
        .{ .x = 220.0, .y = 120.0 },
        .{ .x = 220.0, .y = 140.0 },
        .{ .x = 240.0, .y = 140.0 },
        .{ .x = 240.0, .y = 160.0 },
    };
    try enc.strokePath(&stair_path3, 4.0, 0.8, 0.3, 0.8, 1.0); // purple

    // === Complex diagonal path ===
    try enc.setStrokeJoin(.Miter);
    const diag_path = [_]semadraw.Encoder.Point{
        .{ .x = 20.0, .y = 180.0 },
        .{ .x = 50.0, .y = 200.0 },
        .{ .x = 80.0, .y = 180.0 },
        .{ .x = 110.0, .y = 220.0 },
        .{ .x = 140.0, .y = 190.0 },
    };
    try enc.strokePath(&diag_path, 3.0, 0.2, 0.7, 0.9, 1.0); // cyan

    // === Closed-looking square (but not actually closed) ===
    const square_path = [_]semadraw.Encoder.Point{
        .{ .x = 170.0, .y = 180.0 },
        .{ .x = 220.0, .y = 180.0 },
        .{ .x = 220.0, .y = 230.0 },
        .{ .x = 170.0, .y = 230.0 },
        .{ .x = 170.0, .y = 180.0 },
    };
    try enc.strokePath(&square_path, 2.5, 0.9, 0.9, 0.9, 1.0); // white

    // === Test with clipping ===
    var clips = [_]semadraw.Encoder.Rect{
        .{ .x = 20.0, .y = 240.0, .w = 60.0, .h = 15.0 },
    };
    try enc.setClipRects(&clips);
    const clipped_path = [_]semadraw.Encoder.Point{
        .{ .x = 10.0, .y = 235.0 },
        .{ .x = 40.0, .y = 250.0 },
        .{ .x = 70.0, .y = 235.0 },
        .{ .x = 100.0, .y = 250.0 },
    };
    try enc.strokePath(&clipped_path, 3.0, 1.0, 0.5, 0.5, 1.0); // pink
    try enc.clearClip();

    // === Test with transform ===
    try enc.setTransform2D(0.866, 0.5, -0.5, 0.866, 140.0, 180.0); // 30 degree rotation around (140, 180)
    const rotated_path = [_]semadraw.Encoder.Point{
        .{ .x = 100.0, .y = 230.0 },
        .{ .x = 120.0, .y = 230.0 },
        .{ .x = 120.0, .y = 250.0 },
    };
    try enc.strokePath(&rotated_path, 2.0, 1.0, 1.0, 0.5, 1.0); // light yellow
    try enc.resetTransform();

    try enc.end();
    try enc.writeToFile(file);
}
