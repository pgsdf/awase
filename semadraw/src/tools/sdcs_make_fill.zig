const std = @import("std");
const semadraw = @import("semadraw");

const Point = semadraw.Encoder.Point;

// Pentagram: five outer vertices visited with a 144-degree step, which
// makes a single self-intersecting contour. Under nonzero the inner
// pentagon fills; under even-odd it is a hole. This is the winding-rule
// divergence case (ADR 0015 section 8).
fn pentagram(cx: f32, cy: f32, r: f32) [5]Point {
    var pts: [5]Point = undefined;
    var k: usize = 0;
    while (k < 5) : (k += 1) {
        const deg: f32 = -90.0 + @as(f32, @floatFromInt(k)) * 144.0;
        const rad: f32 = deg * std.math.pi / 180.0;
        pts[k] = .{ .x = cx + r * std.math.cos(rad), .y = cy + r * std.math.sin(rad) };
    }
    return pts;
}

fn emitScene(enc: *semadraw.Encoder) !void {
    // Convex: a hexagon.
    const hex = [_]Point{
        .{ .x = 40, .y = 20 }, .{ .x = 72, .y = 20 }, .{ .x = 88, .y = 48 },
        .{ .x = 72, .y = 76 }, .{ .x = 40, .y = 76 }, .{ .x = 24, .y = 48 },
    };
    try enc.fillPath(&.{hex[0..]}, .nonzero, 0.85, 0.30, 0.20, 1.0);

    // Concave: a right-pointing block arrow, concave at the two joins
    // where the shaft meets the head. A single, simple (non-self-
    // intersecting) contour.
    const chevron = [_]Point{
        .{ .x = 120, .y = 32 }, .{ .x = 152, .y = 32 }, .{ .x = 152, .y = 20 },
        .{ .x = 180, .y = 48 }, .{ .x = 152, .y = 76 }, .{ .x = 152, .y = 64 },
        .{ .x = 120, .y = 64 },
    };
    try enc.fillPath(&.{chevron[0..]}, .nonzero, 0.20, 0.55, 0.85, 1.0);

    // Ring with a hole (even-odd): outer square, inner square.
    const outer = [_]Point{ .{ .x = 30, .y = 110 }, .{ .x = 100, .y = 110 }, .{ .x = 100, .y = 180 }, .{ .x = 30, .y = 180 } };
    const inner = [_]Point{ .{ .x = 50, .y = 130 }, .{ .x = 80, .y = 130 }, .{ .x = 80, .y = 160 }, .{ .x = 50, .y = 160 } };
    try enc.fillPath(&.{ outer[0..], inner[0..] }, .even_odd, 0.30, 0.70, 0.35, 1.0);

    // Self-intersecting star (nonzero).
    const star = pentagram(165, 145, 45);
    try enc.fillPath(&.{star[0..]}, .nonzero, 0.80, 0.65, 0.20, 1.0);

    // Vertex-on-sample: a triangle with integer-aligned vertices so its
    // edges and corners land on the 4x4 sub-sample lattice.
    const tri = [_]Point{ .{ .x = 40, .y = 210 }, .{ .x = 120, .y = 210 }, .{ .x = 80, .y = 250 } };
    try enc.fillPath(&.{tri[0..]}, .nonzero, 0.55, 0.40, 0.80, 1.0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.log.err("usage: {s} output.sdcs [variant]", .{args[0]});
        return error.InvalidArgument;
    }
    const out_path = args[1];
    const variant: []const u8 = if (args.len >= 3) args[2] else "scene";

    var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer file.close();

    var enc = semadraw.Encoder.init(alloc);
    defer enc.deinit();

    try enc.reset();
    try enc.setAntialias(true);

    const col = .{ 0.20, 0.60, 0.90, 1.0 };
    if (std.mem.eql(u8, variant, "scene")) {
        try emitScene(&enc);
    } else if (std.mem.eql(u8, variant, "equiv-rect")) {
        try enc.fillRect(0, 0, 256, 256, col[0], col[1], col[2], col[3]);
    } else if (std.mem.eql(u8, variant, "equiv-path")) {
        const sq = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 256, .y = 0 }, .{ .x = 256, .y = 256 }, .{ .x = 0, .y = 256 } };
        try enc.fillPath(&.{sq[0..]}, .nonzero, col[0], col[1], col[2], col[3]);
    } else if (std.mem.eql(u8, variant, "star-nz")) {
        const star = pentagram(128, 128, 90);
        try enc.fillPath(&.{star[0..]}, .nonzero, col[0], col[1], col[2], col[3]);
    } else if (std.mem.eql(u8, variant, "star-eo")) {
        const star = pentagram(128, 128, 90);
        try enc.fillPath(&.{star[0..]}, .even_odd, col[0], col[1], col[2], col[3]);
    } else {
        std.log.err("unknown variant: {s}", .{variant});
        return error.InvalidArgument;
    }

    try enc.end();
    try enc.writeToFile(file);
}
