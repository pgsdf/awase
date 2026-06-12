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

    var file = try std.fs.cwd().createFile(args[1], .{ .truncate = true });
    defer file.close();

    var enc = semadraw.Encoder.init(alloc);
    defer enc.deinit();

    try enc.reset();

    // Dark background
    try enc.setBlend(semadraw.Encoder.BlendMode.Src);
    try enc.fillRect(0, 0, 1280, 1080, 0.08, 0.08, 0.12, 1.0);
    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);

    // Enable anti-aliasing for smooth edges
    try enc.setAntialias(true);

    // Title area - gradient-like effect with overlapping rectangles
    var y: f32 = 0;
    while (y < 120) : (y += 2) {
        const t = y / 120.0;
        try enc.fillRect(0, y, 1280, 2, 0.15 + t * 0.1, 0.12 + t * 0.08, 0.25 + t * 0.1, 1.0);
    }

    // "SemaDraw" text simulation with rectangles (since we don't have full font rendering)
    // S
    try enc.fillRect(80, 40, 40, 10, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(80, 40, 10, 25, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(80, 55, 40, 10, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(110, 55, 10, 25, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(80, 70, 40, 10, 1.0, 1.0, 1.0, 0.9);

    // e
    try enc.fillRect(135, 50, 30, 8, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(135, 50, 8, 30, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(135, 60, 30, 8, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(135, 72, 30, 8, 1.0, 1.0, 1.0, 0.9);

    // m
    try enc.fillRect(175, 50, 8, 30, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(175, 50, 20, 8, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(187, 50, 8, 30, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(187, 50, 20, 8, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(199, 50, 8, 30, 1.0, 1.0, 1.0, 0.9);

    // a
    try enc.fillRect(220, 50, 30, 8, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(220, 50, 8, 30, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(242, 50, 8, 30, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(220, 62, 30, 8, 1.0, 1.0, 1.0, 0.9);

    // D
    try enc.fillRect(270, 40, 8, 40, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(270, 40, 25, 8, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(270, 72, 25, 8, 1.0, 1.0, 1.0, 0.9);
    try enc.fillRect(290, 45, 8, 30, 1.0, 1.0, 1.0, 0.9);

    // Section 1: Bezier curves showcase
    try enc.setStrokeJoin(.Round);
    try enc.setStrokeCap(.Round);

    // Flowing curves in blue/cyan
    try enc.strokeCubicBezier(100, 200, 300, 350, 500, 150, 700, 300, 4.0, 0.2, 0.6, 1.0, 0.9);
    try enc.strokeCubicBezier(100, 220, 350, 380, 550, 120, 700, 320, 3.0, 0.3, 0.7, 1.0, 0.7);
    try enc.strokeCubicBezier(100, 240, 400, 410, 600, 90, 700, 340, 2.0, 0.4, 0.8, 1.0, 0.5);

    // Quadratic curves in purple/magenta
    try enc.strokeQuadBezier(750, 200, 900, 350, 1050, 200, 4.0, 0.8, 0.3, 0.9, 0.9);
    try enc.strokeQuadBezier(770, 220, 920, 370, 1070, 220, 3.0, 0.7, 0.4, 0.85, 0.7);
    try enc.strokeQuadBezier(790, 240, 940, 390, 1090, 240, 2.0, 0.6, 0.5, 0.8, 0.5);

    // Section 2: Geometric shapes
    // Filled rectangles with transparency
    try enc.fillRect(100, 400, 150, 150, 1.0, 0.3, 0.3, 0.8);
    try enc.fillRect(170, 450, 150, 150, 0.3, 1.0, 0.3, 0.6);
    try enc.fillRect(240, 500, 150, 150, 0.3, 0.3, 1.0, 0.4);

    // Stroked rectangles
    try enc.strokeRect(450, 420, 120, 120, 3.0, 1.0, 0.8, 0.2, 1.0);
    try enc.strokeRect(480, 450, 120, 120, 3.0, 0.8, 1.0, 0.2, 0.8);
    try enc.strokeRect(510, 480, 120, 120, 3.0, 0.2, 1.0, 0.8, 0.6);

    // Section 3: Line patterns
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const x1: f32 = 700 + fi * 25;
        const y1: f32 = 400;
        const x2: f32 = 750 + fi * 20;
        const y2: f32 = 650;
        const hue = fi / 20.0;
        // Simple HSV-like color
        const r = @abs(@sin(hue * 6.28));
        const g = @abs(@sin((hue + 0.33) * 6.28));
        const b = @abs(@sin((hue + 0.66) * 6.28));
        try enc.strokeLine(x1, y1, x2, y2, 2.0 + fi * 0.15, r, g, b, 0.8);
    }

    // Section 4: Path with round joins (zigzag pattern)
    try enc.setStrokeJoin(.Round);
    const zigzag = [_]semadraw.Encoder.Point{
        .{ .x = 100, .y = 750 },
        .{ .x = 150, .y = 850 },
        .{ .x = 200, .y = 750 },
        .{ .x = 250, .y = 850 },
        .{ .x = 300, .y = 750 },
        .{ .x = 350, .y = 850 },
        .{ .x = 400, .y = 750 },
        .{ .x = 450, .y = 850 },
        .{ .x = 500, .y = 750 },
    };
    try enc.strokePath(&zigzag, 5.0, 1.0, 0.5, 0.0, 0.9);

    // Miter join comparison
    try enc.setStrokeJoin(.Miter);
    const miter_path = [_]semadraw.Encoder.Point{
        .{ .x = 100, .y = 900 },
        .{ .x = 200, .y = 1000 },
        .{ .x = 300, .y = 900 },
        .{ .x = 400, .y = 1000 },
        .{ .x = 500, .y = 900 },
    };
    try enc.strokePath(&miter_path, 4.0, 0.0, 0.8, 0.6, 0.9);

    // Section 5: Blend mode showcase (using available modes: Src, SrcOver, Clear, Add)
    // Additive blending for glow effect
    try enc.setBlend(semadraw.Encoder.BlendMode.Add);
    try enc.fillRect(600, 750, 200, 150, 0.5, 0.0, 0.0, 0.7);
    try enc.fillRect(700, 800, 200, 150, 0.0, 0.0, 0.5, 0.7);

    // SrcOver with transparency
    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);
    try enc.fillRect(950, 750, 200, 150, 0.0, 0.6, 0.0, 0.7);
    try enc.fillRect(1050, 800, 200, 150, 0.6, 0.0, 0.6, 0.5);

    // Section 6: Anti-aliasing comparison
    // AA enabled (already on)
    try enc.fillRect(100, 1000, 10, 40, 1.0, 1.0, 1.0, 0.7);
    try enc.strokeLine(120, 1000, 180, 1040, 2.0, 1.0, 1.0, 1.0, 0.9);

    // Disable AA for comparison
    try enc.setAntialias(false);
    try enc.fillRect(200, 1000, 10, 40, 1.0, 1.0, 1.0, 0.7);
    try enc.strokeLine(220, 1000, 280, 1040, 2.0, 1.0, 1.0, 1.0, 0.9);

    // Re-enable for final flourish
    try enc.setAntialias(true);

    // Decorative corner curves
    try enc.strokeCubicBezier(1150, 950, 1200, 980, 1230, 1020, 1250, 1060, 3.0, 0.9, 0.7, 0.2, 0.8);
    try enc.strokeCubicBezier(1140, 940, 1190, 970, 1220, 1010, 1240, 1050, 2.0, 0.95, 0.75, 0.3, 0.6);

    try enc.end();
    try enc.writeToFile(file);
}
