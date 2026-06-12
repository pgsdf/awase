const std = @import("std");
const semadraw = @import("semadraw");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.log.err("usage: {s} output.sdcs", .{args[0]});
        return error.InvalidArgument;
    }

    const out_path = args[1];

    var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer file.close();

    var enc = semadraw.Encoder.init(alloc);
    defer enc.deinit();

    try enc.reset();

    // Enable anti-aliasing for all subsequent operations
    try enc.setAntialias(true);

    // Test 1: Axis-aligned rectangles with fractional positions (edges should be smooth)
    try enc.fillRect(10.3, 10.7, 30.0, 20.0, 1.0, 0.0, 0.0, 1.0);
    try enc.fillRect(50.5, 10.5, 30.0, 20.0, 0.0, 1.0, 0.0, 1.0);
    try enc.fillRect(90.25, 10.25, 30.0, 20.0, 0.0, 0.0, 1.0, 1.0);

    // Test 2: Stroked rectangles with fractional positions
    try enc.strokeRect(10.3, 40.7, 30.0, 20.0, 2.0, 1.0, 1.0, 0.0, 1.0);
    try enc.strokeRect(50.5, 40.5, 30.0, 20.0, 3.0, 1.0, 0.0, 1.0, 1.0);
    try enc.strokeRect(90.25, 40.25, 30.0, 20.0, 4.0, 0.0, 1.0, 1.0, 1.0);

    // Test 3: Diagonal lines (should have smooth edges)
    try enc.strokeLine(10.0, 80.0, 50.0, 120.0, 2.0, 1.0, 0.5, 0.0, 1.0);
    try enc.strokeLine(60.0, 80.0, 100.0, 120.0, 3.0, 0.5, 1.0, 0.0, 1.0);
    try enc.strokeLine(110.0, 80.0, 150.0, 120.0, 4.0, 0.0, 0.5, 1.0, 1.0);

    // Test 4: Bezier curves (should have smooth edges)
    try enc.strokeQuadBezier(10.0, 140.0, 40.0, 180.0, 70.0, 140.0, 2.0, 0.8, 0.2, 0.8, 1.0);
    try enc.strokeCubicBezier(90.0, 140.0, 100.0, 180.0, 140.0, 100.0, 150.0, 140.0, 2.5, 0.2, 0.8, 0.2, 1.0);

    // Test 5: Path with round joins (should have smooth circular joins)
    try enc.setStrokeJoin(.Round);
    const path_points = [_]semadraw.Encoder.Point{
        .{ .x = 10.0, .y = 180.0 },
        .{ .x = 30.0, .y = 200.0 },
        .{ .x = 50.0, .y = 180.0 },
        .{ .x = 70.0, .y = 200.0 },
        .{ .x = 90.0, .y = 180.0 },
    };
    try enc.strokePath(&path_points, 3.0, 0.9, 0.6, 0.1, 1.0);

    // Test 6: Semi-transparent AA (coverage * alpha)
    try enc.fillRect(130.0, 140.0, 40.0, 40.0, 1.0, 0.0, 0.0, 0.5);
    try enc.strokeRect(140.0, 150.0, 40.0, 40.0, 3.0, 0.0, 1.0, 0.0, 0.5);

    // Test 7: Disable AA and draw non-AA comparison
    try enc.setAntialias(false);
    try enc.fillRect(10.3, 220.7, 30.0, 20.0, 1.0, 0.0, 0.0, 1.0);
    try enc.strokeLine(60.0, 220.0, 100.0, 250.0, 2.0, 0.0, 1.0, 0.0, 1.0);

    // Re-enable AA for final test
    try enc.setAntialias(true);
    try enc.fillRect(130.3, 220.7, 30.0, 20.0, 1.0, 0.0, 0.0, 1.0);
    try enc.strokeLine(170.0, 220.0, 210.0, 250.0, 2.0, 0.0, 1.0, 0.0, 1.0);

    try enc.end();
    try enc.writeToFile(file);
}
