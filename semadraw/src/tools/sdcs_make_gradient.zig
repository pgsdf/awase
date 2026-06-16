const std = @import("std");
const posix = std.posix;
const compat = @import("compat");
const semadraw = @import("semadraw");

const Point = semadraw.Encoder.Point;
const Stop = semadraw.Encoder.GradientStop;
const Extend = semadraw.Encoder.ExtendMode;

// Equivalence color, shared by the solid and identical-stop gradient variants
// (invariant B1-3). A single source of truth so the solid reference and the
// gradient cannot drift apart.
const C = [4]f32{ 0.30, 0.55, 0.80, 1.0 };

// A square contour, given as a single nonzero path.
fn square(x: f32, y: f32, s: f32) [4]Point {
    return .{
        .{ .x = x, .y = y },
        .{ .x = x + s, .y = y },
        .{ .x = x + s, .y = y + s },
        .{ .x = x, .y = y + s },
    };
}

// The composite golden scene. It pins, in one hash, the identity linear
// (two-stop and multi-stop), the radial fill, the transformed linear (the
// section 5 coordinate-space case), and all three extend modes.
fn emitScene(enc: *semadraw.Encoder) !void {
    // Linear two-stop (identity), red to blue, pad.
    const lin2 = [_]Stop{
        .{ .offset = 0, .r = 0.90, .g = 0.15, .b = 0.15, .a = 1 },
        .{ .offset = 1, .r = 0.15, .g = 0.20, .b = 0.85, .a = 1 },
    };
    try enc.setSourceLinearGradient(15, 0, 115, 0, lin2[0..], .pad);
    try enc.fillRect(15, 15, 100, 40, 0, 0, 0, 1);

    // Linear multi-stop (four stops), pad.
    const lin4 = [_]Stop{
        .{ .offset = 0.0, .r = 0.90, .g = 0.20, .b = 0.20, .a = 1 },
        .{ .offset = 0.33, .r = 0.90, .g = 0.85, .b = 0.20, .a = 1 },
        .{ .offset = 0.66, .r = 0.20, .g = 0.75, .b = 0.35, .a = 1 },
        .{ .offset = 1.0, .r = 0.20, .g = 0.30, .b = 0.85, .a = 1 },
    };
    try enc.setSourceLinearGradient(140, 0, 240, 0, lin4[0..], .pad);
    try enc.fillRect(140, 15, 100, 40, 0, 0, 0, 1);

    // Radial two-stop on a FILL_PATH, white center to navy edge, pad.
    const rad = [_]Stop{
        .{ .offset = 0, .r = 0.95, .g = 0.95, .b = 0.95, .a = 1 },
        .{ .offset = 1, .r = 0.10, .g = 0.15, .b = 0.45, .a = 1 },
    };
    try enc.setSourceRadialGradient(62, 120, 42, rad[0..], .pad);
    const ring = square(20, 78, 84);
    try enc.fillPath(&.{ring[0..]}, .nonzero, 0, 0, 0, 1);

    // Transformed linear (non-uniform scale sx=1.8, sy=0.7 with a 25 degree
    // rotation). The gradient runs along the shape's local x axis, so a correct
    // draw-time inverse-CTM mapping makes the gradient stretch and rotate with
    // the geometry (ADR 0016 section 5).
    const deg: f32 = 25.0;
    const rad_ang: f32 = deg * std.math.pi / 180.0;
    const cs = std.math.cos(rad_ang);
    const sn = std.math.sin(rad_ang);
    const sx: f32 = 1.8;
    const sy: f32 = 0.7;
    try enc.setTransform2D(sx * cs, sx * sn, -sy * sn, sy * cs, 150, 120);
    const lint = [_]Stop{
        .{ .offset = 0, .r = 0.15, .g = 0.85, .b = 0.85, .a = 1 },
        .{ .offset = 1, .r = 0.85, .g = 0.15, .b = 0.65, .a = 1 },
    };
    try enc.setSourceLinearGradient(0, 0, 50, 0, lint[0..], .pad);
    const usq = square(0, 0, 50);
    try enc.fillPath(&.{usq[0..]}, .nonzero, 0, 0, 0, 1);
    try enc.resetTransform();

    // Extend modes: a short-axis gradient over a wide strip, rendered pad,
    // repeat, and reflect. The axis covers roughly a quarter of each strip, so
    // the beyond-axis behavior of each mode is visible and pinned by the hash.
    const ext = [_]Stop{
        .{ .offset = 0, .r = 0.95, .g = 0.95, .b = 0.95, .a = 1 },
        .{ .offset = 1, .r = 0.12, .g = 0.12, .b = 0.12, .a = 1 },
    };
    const modes = [_]Extend{ .pad, .repeat, .reflect };
    var i: usize = 0;
    while (i < modes.len) : (i += 1) {
        const sy0: f32 = 175 + @as(f32, @floatFromInt(i)) * 26;
        try enc.setSourceLinearGradient(20, 0, 75, 0, ext[0..], modes[i]);
        try enc.fillRect(20, sy0, 220, 20, 0, 0, 0, 1);
    }

    try enc.setSourceNone();
}


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
        std.log.err("usage: {s} output.sdcs [variant]", .{args[0]});
        return error.InvalidArgument;
    }
    const out_path = args[1];
    const variant: []const u8 = if (args.len >= 3) args[2] else "scene";

    const fd = try openCreateRdwr(out_path, 0o644);
    defer _ = posix.system.close(fd);

    var enc = semadraw.Encoder.init(alloc);
    defer enc.deinit();

    try enc.reset();
    try enc.setAntialias(true);

    // Equivalence shapes (invariant B1-3). The rect pair exercises the sourced
    // FILL_RECT path against the solid FILL_RECT path; the path pair exercises
    // the radial sampler on FILL_PATH against the solid FILL_PATH path.
    const eq_rx: f32 = 40;
    const eq_ry: f32 = 40;
    const eq_rw: f32 = 120;
    const eq_rh: f32 = 90;
    const eq_path = [_]Point{
        .{ .x = 40, .y = 40 }, .{ .x = 160, .y = 40 },
        .{ .x = 160, .y = 130 }, .{ .x = 40, .y = 130 },
    };

    if (std.mem.eql(u8, variant, "scene")) {
        try emitScene(&enc);
    } else if (std.mem.eql(u8, variant, "equiv-solid-rect")) {
        try enc.fillRect(eq_rx, eq_ry, eq_rw, eq_rh, C[0], C[1], C[2], C[3]);
    } else if (std.mem.eql(u8, variant, "equiv-linear-rect")) {
        const stops = [_]Stop{
            .{ .offset = 0, .r = C[0], .g = C[1], .b = C[2], .a = C[3] },
            .{ .offset = 1, .r = C[0], .g = C[1], .b = C[2], .a = C[3] },
        };
        try enc.setSourceLinearGradient(eq_rx, 0, eq_rx + eq_rw, 0, stops[0..], .pad);
        try enc.fillRect(eq_rx, eq_ry, eq_rw, eq_rh, 0, 0, 0, 1);
    } else if (std.mem.eql(u8, variant, "equiv-solid-path")) {
        try enc.fillPath(&.{eq_path[0..]}, .nonzero, C[0], C[1], C[2], C[3]);
    } else if (std.mem.eql(u8, variant, "equiv-radial-path")) {
        const stops = [_]Stop{
            .{ .offset = 0, .r = C[0], .g = C[1], .b = C[2], .a = C[3] },
            .{ .offset = 1, .r = C[0], .g = C[1], .b = C[2], .a = C[3] },
        };
        try enc.setSourceRadialGradient(100, 85, 70, stops[0..], .pad);
        try enc.fillPath(&.{eq_path[0..]}, .nonzero, 0, 0, 0, 1);
    } else if (std.mem.eql(u8, variant, "extend-pad-full") or std.mem.eql(u8, variant, "extend-repeat-full")) {
        const mode: Extend = if (std.mem.eql(u8, variant, "extend-repeat-full")) .repeat else .pad;
        const stops = [_]Stop{
            .{ .offset = 0, .r = 0.90, .g = 0.15, .b = 0.15, .a = 1 },
            .{ .offset = 1, .r = 0.15, .g = 0.20, .b = 0.85, .a = 1 },
        };
        // Axis covers x in [100,160]; the regions x<100 and x>160 lie beyond the
        // axis, where pad clamps but repeat tiles, so the two modes must differ.
        try enc.setSourceLinearGradient(100, 0, 160, 0, stops[0..], mode);
        try enc.fillRect(0, 0, 256, 256, 0, 0, 0, 1);
    } else if (std.mem.eql(u8, variant, "reset")) {
        // Set a gradient, clear it, then fill: the fill must use the inline color.
        const stops = [_]Stop{
            .{ .offset = 0, .r = 0.90, .g = 0.15, .b = 0.15, .a = 1 },
            .{ .offset = 1, .r = 0.15, .g = 0.20, .b = 0.85, .a = 1 },
        };
        try enc.setSourceLinearGradient(100, 0, 160, 0, stops[0..], .pad);
        try enc.setSourceNone();
        try enc.fillRect(0, 0, 256, 256, C[0], C[1], C[2], C[3]);
    } else if (std.mem.eql(u8, variant, "reset-ref")) {
        try enc.fillRect(0, 0, 256, 256, C[0], C[1], C[2], C[3]);
    } else {
        std.log.err("unknown variant: {s}", .{variant});
        return error.InvalidArgument;
    }

    try enc.end();
    try enc.writeToFile(fd);
}
