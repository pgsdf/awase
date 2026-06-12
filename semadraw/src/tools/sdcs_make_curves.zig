const std = @import("std");
const semadraw = @import("semadraw");

/// Test generator for Bezier curves (quadratic and cubic).
/// Creates various curve shapes to test the curve rendering implementation.
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

    // === Quadratic Bezier curves ===

    // Simple S-curve (quadratic)
    try enc.strokeQuadBezier(
        20.0, 40.0, // start
        60.0, 20.0, // control
        100.0, 40.0, // end
        3.0, // stroke width
        1.0, 0.4, 0.2, 1.0, // orange
    );

    // Inverted curve below
    try enc.strokeQuadBezier(
        20.0, 60.0, // start
        60.0, 80.0, // control
        100.0, 60.0, // end
        3.0, // stroke width
        0.2, 0.8, 0.4, 1.0, // green
    );

    // Sharp curve
    try enc.strokeQuadBezier(
        120.0, 30.0, // start
        150.0, 70.0, // control (far from line)
        180.0, 30.0, // end
        2.0, // stroke width
        0.3, 0.5, 1.0, 1.0, // blue
    );

    // === Cubic Bezier curves ===

    // Classic S-curve (cubic)
    try enc.strokeCubicBezier(
        20.0, 120.0, // start
        50.0, 90.0, // control 1
        70.0, 150.0, // control 2
        100.0, 120.0, // end
        3.0, // stroke width
        1.0, 0.8, 0.2, 1.0, // yellow
    );

    // Tight loop-like curve
    try enc.strokeCubicBezier(
        120.0, 100.0, // start
        180.0, 80.0, // control 1
        120.0, 140.0, // control 2
        180.0, 120.0, // end
        2.5, // stroke width
        0.8, 0.3, 0.8, 1.0, // purple
    );

    // Wide gentle curve
    try enc.strokeCubicBezier(
        20.0, 180.0, // start
        80.0, 160.0, // control 1
        160.0, 200.0, // control 2
        220.0, 180.0, // end
        4.0, // stroke width
        0.2, 0.7, 0.9, 1.0, // cyan
    );

    // Near-straight cubic (control points close to line)
    try enc.strokeCubicBezier(
        20.0, 220.0, // start
        80.0, 222.0, // control 1 (almost on line)
        160.0, 218.0, // control 2 (almost on line)
        220.0, 220.0, // end
        2.0, // stroke width
        0.9, 0.9, 0.9, 1.0, // white
    );

    // === Test with clipping ===
    var clips = [_]semadraw.Encoder.Rect{
        .{ .x = 180.0, .y = 20.0, .w = 60.0, .h = 60.0 },
    };
    try enc.setClipRects(&clips);

    // Curve that extends outside clip region
    try enc.strokeCubicBezier(
        160.0, 20.0, // start
        200.0, 0.0, // control 1
        220.0, 80.0, // control 2
        250.0, 50.0, // end
        3.0, // stroke width
        1.0, 0.5, 0.5, 1.0, // pink
    );
    try enc.clearClip();

    // === Test with transform ===
    // Rotate 30 degrees around point (210, 160)
    const angle: f32 = 0.523599; // 30 degrees in radians
    const cos_a = @cos(angle);
    const sin_a = @sin(angle);
    const cx: f32 = 210.0;
    const cy: f32 = 160.0;
    // Rotation matrix: translate to origin, rotate, translate back
    // a=cos, b=sin, c=-sin, d=cos, e=cx-cx*cos+cy*sin, f=cy-cx*sin-cy*cos
    try enc.setTransform2D(
        cos_a,
        sin_a,
        -sin_a,
        cos_a,
        cx - cx * cos_a + cy * sin_a,
        cy - cx * sin_a - cy * cos_a,
    );

    try enc.strokeQuadBezier(
        190.0, 140.0, // start
        210.0, 120.0, // control
        230.0, 140.0, // end
        2.5, // stroke width
        1.0, 1.0, 0.5, 1.0, // light yellow
    );

    try enc.strokeQuadBezier(
        190.0, 160.0, // start
        210.0, 180.0, // control
        230.0, 160.0, // end
        2.5, // stroke width
        0.5, 1.0, 1.0, 1.0, // light cyan
    );

    try enc.resetTransform();

    try enc.end();
    try enc.writeToFile(file);
}
