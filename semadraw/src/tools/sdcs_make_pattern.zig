const std = @import("std");
const semadraw = @import("semadraw");

const Point = semadraw.Encoder.Point;
const Extend = semadraw.Encoder.ExtendMode;
const Filter = semadraw.Encoder.PatternFilter;

// Equivalence color, shared by the solid and uniform-tile variants (invariant
// B2-1). A single source of truth so the solid reference and the pattern
// cannot drift apart.
const C = [4]f32{ 0.30, 0.55, 0.80, 1.0 };

// Quantize a straight-alpha channel to a byte the same way the replay does
// (round of c*255 in f32), so a uniform tile of quant(C) reproduces the solid
// fill of C exactly.
fn quant(c: f32) u8 {
    return @as(u8, @intFromFloat(@round(std.math.clamp(c, 0, 1) * 255.0)));
}

// An 8x8 two-color checker tile (4-texel squares), straight RGBA8, row-major,
// top-left origin. Distinct enough that tiling, rotation, and extend behavior
// are all visible.
fn checker8() [8 * 8 * 4]u8 {
    const ca = [4]u8{ 230, 130, 30, 255 }; // orange
    const cb = [4]u8{ 30, 150, 160, 255 }; // teal
    var t: [8 * 8 * 4]u8 = undefined;
    var y: usize = 0;
    while (y < 8) : (y += 1) {
        var x: usize = 0;
        while (x < 8) : (x += 1) {
            const on = ((x / 4) + (y / 4)) % 2 == 0;
            const c = if (on) ca else cb;
            const idx = (y * 8 + x) * 4;
            t[idx + 0] = c[0];
            t[idx + 1] = c[1];
            t[idx + 2] = c[2];
            t[idx + 3] = c[3];
        }
    }
    return t;
}

// The composite golden scene. It pins, in one hash, the identity pattern on a
// FILL_RECT and a FILL_PATH, the CTM-transformed pattern (section 5
// coordinate-space case for the CTM inverse), the rotated pattern affine (the
// pattern inverse, independent of the CTM), and all three extend modes.
fn emitScene(enc: *semadraw.Encoder) !void {
    const tile = checker8();

    // Row 1, identity pattern on a FILL_RECT (left) and a FILL_PATH (right),
    // repeat both axes, 2 user px per texel (the 8-texel tile spans 16 px).
    try enc.setSourcePattern(2, 0, 0, 2, 15, 15, .repeat, .repeat, .nearest, 8, 8, tile[0..]);
    try enc.fillRect(15, 15, 105, 40, 0, 0, 0, 1);

    try enc.setSourcePattern(2, 0, 0, 2, 138, 15, .repeat, .repeat, .nearest, 8, 8, tile[0..]);
    const pathpts = [_]Point{
        .{ .x = 138, .y = 15 }, .{ .x = 240, .y = 15 },
        .{ .x = 240, .y = 55 }, .{ .x = 138, .y = 55 },
    };
    try enc.fillPath(&.{pathpts[0..]}, .nonzero, 0, 0, 0, 1);

    // Row 2 left, pattern under a non-uniform scale (sx=1.8, sy=0.7) with a 25
    // degree rotation. A correct draw-time CTM inverse makes the checker
    // stretch and rotate with the geometry (ADR 0017 section 5). The rect is
    // centered on the CTM origin so the parallelogram stays in its region.
    const deg: f32 = 25.0;
    const ang: f32 = deg * std.math.pi / 180.0;
    const cs = std.math.cos(ang);
    const sn = std.math.sin(ang);
    const sx: f32 = 1.8;
    const sy: f32 = 0.7;
    try enc.setTransform2D(sx * cs, sx * sn, -sy * sn, sy * cs, 65, 105);
    try enc.setSourcePattern(2, 0, 0, 2, 0, 0, .repeat, .repeat, .nearest, 8, 8, tile[0..]);
    try enc.fillRect(-32, -22, 64, 44, 0, 0, 0, 1);
    try enc.resetTransform();

    // Row 2 right, non-identity pattern affine: the tile itself rotated 30
    // degrees and scaled, under the identity CTM. This exercises the pattern
    // inverse independently of the CTM inverse.
    const pdeg: f32 = 30.0;
    const pang: f32 = pdeg * std.math.pi / 180.0;
    const pcs = std.math.cos(pang);
    const psn = std.math.sin(pang);
    const psc: f32 = 2.5;
    try enc.setSourcePattern(psc * pcs, psc * psn, -psc * psn, psc * pcs, 140, 78, .repeat, .repeat, .nearest, 8, 8, tile[0..]);
    try enc.fillRect(140, 78, 100, 56, 0, 0, 0, 1);

    // Row 3, extend modes: the tile placed at the left of each strip (about 24
    // px), rendered pad, repeat, and reflect. Beyond the tile the three modes
    // diverge, and the hash pins each.
    const modes = [_]Extend{ .pad, .repeat, .reflect };
    var i: usize = 0;
    while (i < modes.len) : (i += 1) {
        const ys: f32 = 155 + @as(f32, @floatFromInt(i)) * 26;
        try enc.setSourcePattern(3, 0, 0, 3, 20, ys, modes[i], modes[i], .nearest, 8, 8, tile[0..]);
        try enc.fillRect(20, ys, 220, 20, 0, 0, 0, 1);
    }

    try enc.setSourceNone();
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

    // Equivalence shapes (invariant B2-1). The rect pair exercises the sourced
    // FILL_RECT path against the solid FILL_RECT path; the path pair exercises
    // the pattern sampler on FILL_PATH against the solid FILL_PATH path. A 1x1
    // uniform tile of quant(C) samples to the same color at every pixel.
    const eq_rx: f32 = 40;
    const eq_ry: f32 = 40;
    const eq_rw: f32 = 120;
    const eq_rh: f32 = 90;
    const eq_path = [_]Point{
        .{ .x = 40, .y = 40 }, .{ .x = 160, .y = 40 },
        .{ .x = 160, .y = 130 }, .{ .x = 40, .y = 130 },
    };
    const uniform = [_]u8{ quant(C[0]), quant(C[1]), quant(C[2]), quant(C[3]) };

    if (std.mem.eql(u8, variant, "scene")) {
        try emitScene(&enc);
    } else if (std.mem.eql(u8, variant, "equiv-solid-rect")) {
        try enc.fillRect(eq_rx, eq_ry, eq_rw, eq_rh, C[0], C[1], C[2], C[3]);
    } else if (std.mem.eql(u8, variant, "equiv-pattern-rect")) {
        try enc.setSourcePattern(1, 0, 0, 1, 0, 0, .repeat, .repeat, .nearest, 1, 1, uniform[0..]);
        try enc.fillRect(eq_rx, eq_ry, eq_rw, eq_rh, 0, 0, 0, 1);
    } else if (std.mem.eql(u8, variant, "equiv-solid-path")) {
        try enc.fillPath(&.{eq_path[0..]}, .nonzero, C[0], C[1], C[2], C[3]);
    } else if (std.mem.eql(u8, variant, "equiv-pattern-path")) {
        try enc.setSourcePattern(1, 0, 0, 1, 0, 0, .repeat, .repeat, .nearest, 1, 1, uniform[0..]);
        try enc.fillPath(&.{eq_path[0..]}, .nonzero, 0, 0, 0, 1);
    } else if (std.mem.eql(u8, variant, "extend-pad-full") or std.mem.eql(u8, variant, "extend-repeat-full")) {
        const mode: Extend = if (std.mem.eql(u8, variant, "extend-repeat-full")) .repeat else .pad;
        const tile = checker8();
        // The tile spans user [100,160] on each axis (7.5 px per texel); the
        // regions outside that lie beyond the tile, where pad clamps to the
        // edge texels but repeat tiles, so the two modes must differ.
        try enc.setSourcePattern(7.5, 0, 0, 7.5, 100, 100, mode, mode, .nearest, 8, 8, tile[0..]);
        try enc.fillRect(0, 0, 256, 256, 0, 0, 0, 1);
    } else if (std.mem.eql(u8, variant, "reset")) {
        // Set a pattern, clear it, then fill: the fill must use the inline color.
        const tile = checker8();
        try enc.setSourcePattern(2, 0, 0, 2, 0, 0, .repeat, .repeat, .nearest, 8, 8, tile[0..]);
        try enc.setSourceNone();
        try enc.fillRect(0, 0, 256, 256, C[0], C[1], C[2], C[3]);
    } else if (std.mem.eql(u8, variant, "reset-ref")) {
        try enc.fillRect(0, 0, 256, 256, C[0], C[1], C[2], C[3]);
    } else {
        std.log.err("unknown variant: {s}", .{variant});
        return error.InvalidArgument;
    }

    try enc.end();
    try enc.writeToFile(file);
}
