const std = @import("std");
const sdcs = @import("sdcs");
const simd = @import("simd");

fn readExact(r: anytype, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try r.read(buf[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}


/// Minimal limited-reader for Zig 0.15.2.
///
/// Zig 0.15.2 does not expose `std.io.limitedReader`, but we only need a
/// wrapper that prevents reading past a fixed byte count.
const LimitedFileReader = struct {
    file: *std.fs.File,
    remaining: usize,

    fn read(self: *LimitedFileReader, buf: []u8) !usize {
        if (self.remaining == 0) return 0;
        const want = @min(buf.len, self.remaining);
        const n = try self.file.read(buf[0..want]);
        self.remaining -= n;
        return n;
    }

    /// Compatibility shim: many helpers accept an `anytype` with a `read` method.
    /// Returning `self` keeps call sites ergonomic (`lr.reader()`), similar to the
    /// old `std.io.limitedReader(...).reader()` pattern.
    pub fn reader(self: *LimitedFileReader) *LimitedFileReader {
        return self;
    }
};

const StrokeJoin = enum(u32) {
    Miter = 0,
    Bevel = 1,
    Round = 2,
};

const StrokeCap = enum(u32) {
    Butt = 0,
    Square = 1,
    Round = 2,
};


fn clampU8(v: f32) u8 {
    var x = v;
    if (x < 0.0) x = 0.0;
    if (x > 1.0) x = 1.0;
    return @intFromFloat(@round(x * 255.0));
}

// 4x4 sub-pixel sample offsets for deterministic anti-aliasing.
// Positions are evenly distributed within [0,1) x [0,1).
const AA_SAMPLES: u32 = 16;
const AA_SAMPLE_OFFSETS: [16][2]f32 = .{
    .{ 0.0625, 0.0625 }, .{ 0.3125, 0.0625 }, .{ 0.5625, 0.0625 }, .{ 0.8125, 0.0625 },
    .{ 0.0625, 0.3125 }, .{ 0.3125, 0.3125 }, .{ 0.5625, 0.3125 }, .{ 0.8125, 0.3125 },
    .{ 0.0625, 0.5625 }, .{ 0.3125, 0.5625 }, .{ 0.5625, 0.5625 }, .{ 0.8125, 0.5625 },
    .{ 0.0625, 0.8125 }, .{ 0.3125, 0.8125 }, .{ 0.5625, 0.8125 }, .{ 0.8125, 0.8125 },
};

/// Blend a pixel with coverage-based anti-aliasing.
/// Coverage is a value from 0.0 to 1.0 representing partial pixel coverage.
fn fbBlendPixelAA(rgba: []u8, idx: usize, sr: u8, sg: u8, sb: u8, sa: u8, mode: u32, coverage: f32) void {
    if (coverage <= 0.0) return;

    // Modulate source alpha by coverage
    const sa_f: f32 = @as(f32, @floatFromInt(sa)) * coverage;
    const sa_cov: u8 = @intFromFloat(@min(@max(sa_f, 0.0), 255.0));

    if (sa_cov == 0) return;

    fbBlendPixel(rgba, idx, sr, sg, sb, sa_cov, mode);
}
fn emitSquareCap(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip_enabled: bool,
    clip_rects: []const ClipRect,
    blend_mode: u32,
    x: f32,
    y: f32,
    axis: u8,
    sign: i8,
    sw: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
) void {
    const half: f32 = sw * 0.5;
    var rx: f32 = 0;
    var ry: f32 = 0;
    var rw: f32 = 0;
    var rh: f32 = 0;

    if (axis == 0) { // horizontal
        rx = x + (if (sign > 0) 0 else -half);
        ry = y - half;
        rw = half;
        rh = sw;
    } else { // vertical
        rx = x - half;
        ry = y + (if (sign > 0) 0 else -half);
        rw = sw;
        rh = half;
    }

    const rr = rectApplyTBounds(t, rx, ry, rw, rh);
    fbFillRectClipped(
        rgba,
        w,
        h,
        rr.x,
        rr.y,
        rr.w,
        rr.h,
        clampU8(cr),
        clampU8(cg),
        clampU8(cb),
        clampU8(ca),
        blend_mode,
        if (clip_enabled) clip_rects else null,
    );
}

fn pointInClips(px: f32, py: f32, clips: ?[]const ClipRect) bool {
    if (clips) |cs| {
        for (cs) |c| {
            if (px >= c.x and py >= c.y and px < c.x + c.w and py < c.y + c.h) return true;
        }
        return false;
    }
    return true;
}

/// Rasterize an arbitrary-angle stroked line as an oriented rectangle.
/// The line from (x1,y1) to (x2,y2) is stroked with width sw.
fn emitStrokedLineArbitrary(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip_enabled: bool,
    clip_rects: []const ClipRect,
    blend_mode: u32,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    sw: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
) void {
    // Direction vector
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.0001) return; // Degenerate line

    // Normalize direction
    const ux = dx / len;
    const uy = dy / len;

    // Perpendicular (90° CCW)
    const px = -uy;
    const py = ux;

    // Half stroke width
    const half = sw * 0.5;

    // Four corners of the stroke rectangle in user space
    // p0 = (x1, y1) + half * perp
    // p1 = (x1, y1) - half * perp
    // p2 = (x2, y2) - half * perp
    // p3 = (x2, y2) + half * perp
    const c0x = x1 + px * half;
    const c0y = y1 + py * half;
    const c1x = x1 - px * half;
    const c1y = y1 - py * half;
    const c2x = x2 - px * half;
    const c2y = y2 - py * half;
    const c3x = x2 + px * half;
    const c3y = y2 + py * half;

    // Transform corners to screen space
    const p0 = applyT(t, c0x, c0y);
    const p1 = applyT(t, c1x, c1y);
    const p2 = applyT(t, c2x, c2y);
    const p3 = applyT(t, c3x, c3y);

    // Compute axis-aligned bounding box
    var minx: f32 = @min(@min(p0.x, p1.x), @min(p2.x, p3.x));
    var maxx: f32 = @max(@max(p0.x, p1.x), @max(p2.x, p3.x));
    var miny: f32 = @min(@min(p0.y, p1.y), @min(p2.y, p3.y));
    var maxy: f32 = @max(@max(p0.y, p1.y), @max(p2.y, p3.y));

    // Clamp to framebuffer
    if (minx < 0) minx = 0;
    if (miny < 0) miny = 0;
    if (maxx > @as(f32, @floatFromInt(w))) maxx = @as(f32, @floatFromInt(w));
    if (maxy > @as(f32, @floatFromInt(h))) maxy = @as(f32, @floatFromInt(h));

    const ix0: isize = @intFromFloat(@floor(minx));
    const iy0: isize = @intFromFloat(@floor(miny));
    const ix1: isize = @intFromFloat(@ceil(maxx));
    const iy1: isize = @intFromFloat(@ceil(maxy));

    // Edge vectors for half-plane tests (CCW winding: p0 -> p3 -> p2 -> p1)
    // Each edge: point is inside if cross product with edge normal is >= 0
    const e0x = p3.x - p0.x;
    const e0y = p3.y - p0.y;
    const e1x = p2.x - p3.x;
    const e1y = p2.y - p3.y;
    const e2x = p1.x - p2.x;
    const e2y = p1.y - p2.y;
    const e3x = p0.x - p1.x;
    const e3y = p0.y - p1.y;

    var iy: isize = iy0;
    while (iy < iy1) : (iy += 1) {
        var ix: isize = ix0;
        while (ix < ix1) : (ix += 1) {
            const px_f: f32 = @as(f32, @floatFromInt(ix)) + 0.5;
            const py_f: f32 = @as(f32, @floatFromInt(iy)) + 0.5;

            // Clip test
            if (clip_enabled and !pointInClips(px_f, py_f, clip_rects)) continue;

            // Half-plane tests: check if point is on the inside of all 4 edges
            // Cross product sign determines which side of the edge the point is on
            const d0 = (px_f - p0.x) * e0y - (py_f - p0.y) * e0x;
            const d1 = (px_f - p3.x) * e1y - (py_f - p3.y) * e1x;
            const d2 = (px_f - p2.x) * e2y - (py_f - p2.y) * e2x;
            const d3 = (px_f - p1.x) * e3y - (py_f - p1.y) * e3x;

            // Point is inside if all cross products have the same sign (>= 0 for CCW)
            if (d0 >= 0 and d1 >= 0 and d2 >= 0 and d3 >= 0) {
                const idx: usize = (@as(usize, @intCast(iy)) * w + @as(usize, @intCast(ix))) * 4;
                fbBlendPixel(rgba, idx, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode);
            }
        }
    }
}

/// Rasterize an arbitrary-angle stroked line with anti-aliasing.
/// Uses 4x4 sub-pixel sampling for smooth edge coverage.
fn emitStrokedLineArbitraryAA(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip_enabled: bool,
    clip_rects: []const ClipRect,
    blend_mode: u32,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    sw: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
) void {
    // Direction vector
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.0001) return; // Degenerate line

    // Normalize direction
    const ux = dx / len;
    const uy = dy / len;

    // Perpendicular (90° CCW)
    const px = -uy;
    const py = ux;

    // Half stroke width
    const half = sw * 0.5;

    // Four corners of the stroke rectangle in user space
    const c0x = x1 + px * half;
    const c0y = y1 + py * half;
    const c1x = x1 - px * half;
    const c1y = y1 - py * half;
    const c2x = x2 - px * half;
    const c2y = y2 - py * half;
    const c3x = x2 + px * half;
    const c3y = y2 + py * half;

    // Transform corners to screen space
    const p0 = applyT(t, c0x, c0y);
    const p1 = applyT(t, c1x, c1y);
    const p2 = applyT(t, c2x, c2y);
    const p3 = applyT(t, c3x, c3y);

    // Compute axis-aligned bounding box
    var minx: f32 = @min(@min(p0.x, p1.x), @min(p2.x, p3.x));
    var maxx: f32 = @max(@max(p0.x, p1.x), @max(p2.x, p3.x));
    var miny: f32 = @min(@min(p0.y, p1.y), @min(p2.y, p3.y));
    var maxy: f32 = @max(@max(p0.y, p1.y), @max(p2.y, p3.y));

    // Clamp to framebuffer
    if (minx < 0) minx = 0;
    if (miny < 0) miny = 0;
    if (maxx > @as(f32, @floatFromInt(w))) maxx = @as(f32, @floatFromInt(w));
    if (maxy > @as(f32, @floatFromInt(h))) maxy = @as(f32, @floatFromInt(h));

    const ix0: isize = @intFromFloat(@floor(minx));
    const iy0: isize = @intFromFloat(@floor(miny));
    const ix1: isize = @intFromFloat(@ceil(maxx));
    const iy1: isize = @intFromFloat(@ceil(maxy));

    // Edge vectors for half-plane tests (CCW winding: p0 -> p3 -> p2 -> p1)
    const e0x = p3.x - p0.x;
    const e0y = p3.y - p0.y;
    const e1x = p2.x - p3.x;
    const e1y = p2.y - p3.y;
    const e2x = p1.x - p2.x;
    const e2y = p1.y - p2.y;
    const e3x = p0.x - p1.x;
    const e3y = p0.y - p1.y;

    const r8 = clampU8(cr);
    const g8 = clampU8(cg);
    const b8 = clampU8(cb);
    const a8 = clampU8(ca);

    var iy: isize = iy0;
    while (iy < iy1) : (iy += 1) {
        var ix: isize = ix0;
        while (ix < ix1) : (ix += 1) {
            const base_px: f32 = @floatFromInt(ix);
            const base_py: f32 = @floatFromInt(iy);

            // Sub-pixel sampling for AA
            var samples_inside: u32 = 0;
            for (AA_SAMPLE_OFFSETS) |offset| {
                const spx = base_px + offset[0];
                const spy = base_py + offset[1];

                // Clip test at sub-pixel level
                if (clip_enabled and !pointInClips(spx, spy, clip_rects)) continue;

                // Half-plane tests
                const d0 = (spx - p0.x) * e0y - (spy - p0.y) * e0x;
                const d1 = (spx - p3.x) * e1y - (spy - p3.y) * e1x;
                const d2 = (spx - p2.x) * e2y - (spy - p2.y) * e2x;
                const d3 = (spx - p1.x) * e3y - (spy - p1.y) * e3x;

                if (d0 >= 0 and d1 >= 0 and d2 >= 0 and d3 >= 0) {
                    samples_inside += 1;
                }
            }

            if (samples_inside > 0) {
                const coverage: f32 = @as(f32, @floatFromInt(samples_inside)) / @as(f32, @floatFromInt(AA_SAMPLES));
                const idx: usize = (@as(usize, @intCast(iy)) * w + @as(usize, @intCast(ix))) * 4;
                fbBlendPixelAA(rgba, idx, r8, g8, b8, a8, blend_mode, coverage);
            }
        }
    }
}

/// Evaluate a quadratic Bezier at parameter t (0..1)
fn evalQuadBezier(x0: f32, y0: f32, cx: f32, cy: f32, x1: f32, y1: f32, t_param: f32) struct { x: f32, y: f32 } {
    const mt = 1.0 - t_param;
    const mt2 = mt * mt;
    const t2 = t_param * t_param;
    return .{
        .x = mt2 * x0 + 2.0 * mt * t_param * cx + t2 * x1,
        .y = mt2 * y0 + 2.0 * mt * t_param * cy + t2 * y1,
    };
}

/// Evaluate a cubic Bezier at parameter t (0..1)
fn evalCubicBezier(x0: f32, y0: f32, cx1: f32, cy1: f32, cx2: f32, cy2: f32, x1: f32, y1: f32, t_param: f32) struct { x: f32, y: f32 } {
    const mt = 1.0 - t_param;
    const mt2 = mt * mt;
    const mt3 = mt2 * mt;
    const t2 = t_param * t_param;
    const t3 = t2 * t_param;
    return .{
        .x = mt3 * x0 + 3.0 * mt2 * t_param * cx1 + 3.0 * mt * t2 * cx2 + t3 * x1,
        .y = mt3 * y0 + 3.0 * mt2 * t_param * cy1 + 3.0 * mt * t2 * cy2 + t3 * y1,
    };
}

/// Stroke a quadratic Bezier by subdividing into line segments
fn emitStrokedQuadBezier(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip_enabled: bool,
    clip_rects: []const ClipRect,
    blend_mode: u32,
    x0: f32,
    y0: f32,
    cx: f32,
    cy: f32,
    x1: f32,
    y1: f32,
    sw: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
) void {
    // Adaptive subdivision based on curve flatness
    // Use fixed number of segments for simplicity in v1
    const segments: u32 = 16;
    var prev_x = x0;
    var prev_y = y0;

    var i: u32 = 1;
    while (i <= segments) : (i += 1) {
        const t_param: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const pt = evalQuadBezier(x0, y0, cx, cy, x1, y1, t_param);

        emitStrokedLineArbitrary(
            rgba,
            w,
            h,
            t,
            clip_enabled,
            clip_rects,
            blend_mode,
            prev_x,
            prev_y,
            pt.x,
            pt.y,
            sw,
            cr,
            cg,
            cb,
            ca,
        );

        prev_x = pt.x;
        prev_y = pt.y;
    }
}

/// Stroke a cubic Bezier by subdividing into line segments
fn emitStrokedCubicBezier(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip_enabled: bool,
    clip_rects: []const ClipRect,
    blend_mode: u32,
    x0: f32,
    y0: f32,
    cx1: f32,
    cy1: f32,
    cx2: f32,
    cy2: f32,
    x1: f32,
    y1: f32,
    sw: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
) void {
    // Adaptive subdivision based on curve flatness
    // Use fixed number of segments for simplicity in v1
    const segments: u32 = 24;
    var prev_x = x0;
    var prev_y = y0;

    var i: u32 = 1;
    while (i <= segments) : (i += 1) {
        const t_param: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const pt = evalCubicBezier(x0, y0, cx1, cy1, cx2, cy2, x1, y1, t_param);

        emitStrokedLineArbitrary(
            rgba,
            w,
            h,
            t,
            clip_enabled,
            clip_rects,
            blend_mode,
            prev_x,
            prev_y,
            pt.x,
            pt.y,
            sw,
            cr,
            cg,
            cb,
            ca,
        );

        prev_x = pt.x;
        prev_y = pt.y;
    }
}

/// Stroke a quadratic Bezier with anti-aliasing by subdividing into line segments
fn emitStrokedQuadBezierAA(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip_enabled: bool,
    clip_rects: []const ClipRect,
    blend_mode: u32,
    x0: f32,
    y0: f32,
    cx: f32,
    cy: f32,
    x1: f32,
    y1: f32,
    sw: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
) void {
    const segments: u32 = 16;
    var prev_x = x0;
    var prev_y = y0;

    var i: u32 = 1;
    while (i <= segments) : (i += 1) {
        const t_param: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const pt = evalQuadBezier(x0, y0, cx, cy, x1, y1, t_param);

        emitStrokedLineArbitraryAA(rgba, w, h, t, clip_enabled, clip_rects, blend_mode, prev_x, prev_y, pt.x, pt.y, sw, cr, cg, cb, ca);

        prev_x = pt.x;
        prev_y = pt.y;
    }
}

/// Stroke a cubic Bezier with anti-aliasing by subdividing into line segments
fn emitStrokedCubicBezierAA(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip_enabled: bool,
    clip_rects: []const ClipRect,
    blend_mode: u32,
    x0: f32,
    y0: f32,
    cx1: f32,
    cy1: f32,
    cx2: f32,
    cy2: f32,
    x1: f32,
    y1: f32,
    sw: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
) void {
    const segments: u32 = 24;
    var prev_x = x0;
    var prev_y = y0;

    var i: u32 = 1;
    while (i <= segments) : (i += 1) {
        const t_param: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const pt = evalCubicBezier(x0, y0, cx1, cy1, cx2, cy2, x1, y1, t_param);

        emitStrokedLineArbitraryAA(rgba, w, h, t, clip_enabled, clip_rects, blend_mode, prev_x, prev_y, pt.x, pt.y, sw, cr, cg, cb, ca);

        prev_x = pt.x;
        prev_y = pt.y;
    }
}

fn emitRoundCap(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip_enabled: bool,
    clip_rects: []const ClipRect,
    blend_mode: u32,
    x: f32,
    y: f32,
    sw: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
) void {
    const r: f32 = sw * 0.5;

    const c = applyT(t, x, y);
    const vx = struct { x: f32, y: f32 }{ .x = t.a * r, .y = t.b * r };
    const vy = struct { x: f32, y: f32 }{ .x = t.c * r, .y = t.d * r };

    const ex = @abs(vx.x) + @abs(vy.x);
    const ey = @abs(vx.y) + @abs(vy.y);

    var minx: isize = @intFromFloat(@floor(c.x - ex));
    var maxx: isize = @intFromFloat(@ceil(c.x + ex));
    var miny: isize = @intFromFloat(@floor(c.y - ey));
    var maxy: isize = @intFromFloat(@ceil(c.y + ey));

    if (minx < 0) minx = 0;
    if (miny < 0) miny = 0;
    if (maxx > @as(isize, @intCast(w))) maxx = @as(isize, @intCast(w));
    if (maxy > @as(isize, @intCast(h))) maxy = @as(isize, @intCast(h));

    const det: f32 = vx.x * vy.y - vx.y * vy.x;
    const use_affine = @abs(det) > 1e-6;

    var iy: isize = miny;
    while (iy < maxy) : (iy += 1) {
        var ix: isize = minx;
        while (ix < maxx) : (ix += 1) {
            const px: f32 = @as(f32, @floatFromInt(ix)) + 0.5;
            const py: f32 = @as(f32, @floatFromInt(iy)) + 0.5;

            if (clip_enabled and !pointInClips(px, py, clip_rects)) continue;

            const dx = px - c.x;
            const dy = py - c.y;

            var inside: bool = false;
            if (use_affine) {
                const u = (dx * vy.y - dy * vy.x) / det;
                const v = (-dx * vx.y + dy * vx.x) / det;
                inside = (u * u + v * v) <= 1.0;
            } else {
                inside = (dx * dx + dy * dy) <= (r * r);
            }

            if (!inside) continue;

            const idx: usize = (@as(usize, @intCast(iy)) * w + @as(usize, @intCast(ix))) * 4;
            fbBlendPixel(rgba, idx, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode);
        }
    }
}

/// Emit a round cap/join with anti-aliasing.
/// Uses 4x4 sub-pixel sampling for smooth circle edges.
fn emitRoundCapAA(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip_enabled: bool,
    clip_rects: []const ClipRect,
    blend_mode: u32,
    x: f32,
    y: f32,
    sw: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
) void {
    const r: f32 = sw * 0.5;

    const c = applyT(t, x, y);
    const vx = struct { x: f32, y: f32 }{ .x = t.a * r, .y = t.b * r };
    const vy = struct { x: f32, y: f32 }{ .x = t.c * r, .y = t.d * r };

    const ex = @abs(vx.x) + @abs(vy.x);
    const ey = @abs(vx.y) + @abs(vy.y);

    var minx: isize = @intFromFloat(@floor(c.x - ex));
    var maxx: isize = @intFromFloat(@ceil(c.x + ex));
    var miny: isize = @intFromFloat(@floor(c.y - ey));
    var maxy: isize = @intFromFloat(@ceil(c.y + ey));

    if (minx < 0) minx = 0;
    if (miny < 0) miny = 0;
    if (maxx > @as(isize, @intCast(w))) maxx = @as(isize, @intCast(w));
    if (maxy > @as(isize, @intCast(h))) maxy = @as(isize, @intCast(h));

    const det: f32 = vx.x * vy.y - vx.y * vy.x;
    const use_affine = @abs(det) > 1e-6;

    const r8 = clampU8(cr);
    const g8 = clampU8(cg);
    const b8 = clampU8(cb);
    const a8 = clampU8(ca);

    var iy: isize = miny;
    while (iy < maxy) : (iy += 1) {
        var ix: isize = minx;
        while (ix < maxx) : (ix += 1) {
            const base_px: f32 = @floatFromInt(ix);
            const base_py: f32 = @floatFromInt(iy);

            // Sub-pixel sampling for AA
            var samples_inside: u32 = 0;
            for (AA_SAMPLE_OFFSETS) |offset| {
                const spx = base_px + offset[0];
                const spy = base_py + offset[1];

                if (clip_enabled and !pointInClips(spx, spy, clip_rects)) continue;

                const dx = spx - c.x;
                const dy = spy - c.y;

                var inside: bool = false;
                if (use_affine) {
                    const u = (dx * vy.y - dy * vy.x) / det;
                    const v = (-dx * vx.y + dy * vx.x) / det;
                    inside = (u * u + v * v) <= 1.0;
                } else {
                    inside = (dx * dx + dy * dy) <= (r * r);
                }

                if (inside) {
                    samples_inside += 1;
                }
            }

            if (samples_inside > 0) {
                const coverage: f32 = @as(f32, @floatFromInt(samples_inside)) / @as(f32, @floatFromInt(AA_SAMPLES));
                const idx: usize = (@as(usize, @intCast(iy)) * w + @as(usize, @intCast(ix))) * 4;
                fbBlendPixelAA(rgba, idx, r8, g8, b8, a8, blend_mode, coverage);
            }
        }
    }
}


fn fbBlendPixel(rgba: []u8, idx: usize, sr: u8, sg: u8, sb: u8, sa: u8, mode: u32) void {
    const dr = rgba[idx + 0];
    const dg = rgba[idx + 1];
    const db = rgba[idx + 2];
    const da = rgba[idx + 3];

    switch (mode) {
        1 => { // Src
            rgba[idx + 0] = sr;
            rgba[idx + 1] = sg;
            rgba[idx + 2] = sb;
            rgba[idx + 3] = sa;
        },
        2 => { // Clear
            rgba[idx + 0] = 0;
            rgba[idx + 1] = 0;
            rgba[idx + 2] = 0;
            rgba[idx + 3] = 0;
        },
        3 => { // Add (clamped)
            const rsum: u16 = @as(u16, dr) + @as(u16, sr);
            const gsum: u16 = @as(u16, dg) + @as(u16, sg);
            const bsum: u16 = @as(u16, db) + @as(u16, sb);
            const asum: u16 = @as(u16, da) + @as(u16, sa);
            rgba[idx + 0] = @intCast(@min(rsum, 255));
            rgba[idx + 1] = @intCast(@min(gsum, 255));
            rgba[idx + 2] = @intCast(@min(bsum, 255));
            rgba[idx + 3] = @intCast(@min(asum, 255));
        },
        else => { // SrcOver
            const a: u16 = sa;
            const inva: u16 = 255 - sa;
            const or_: u16 = (@as(u16, sr) * a + @as(u16, dr) * inva) / 255;
            const og_: u16 = (@as(u16, sg) * a + @as(u16, dg) * inva) / 255;
            const ob_: u16 = (@as(u16, sb) * a + @as(u16, db) * inva) / 255;
            const oa_: u16 = a + (@as(u16, da) * inva) / 255;
            rgba[idx + 0] = @intCast(@min(or_, 255));
            rgba[idx + 1] = @intCast(@min(og_, 255));
            rgba[idx + 2] = @intCast(@min(ob_, 255));
            rgba[idx + 3] = @intCast(@min(oa_, 255));
        },
    }
}

fn fbFillRect(rgba: []u8, w: usize, h: usize, x: f32, y: f32, rw: f32, rh: f32, r: u8, g: u8, b: u8, a: u8, mode: u32) void {
    const ix0: isize = @intFromFloat(@floor(x));
    const iy0: isize = @intFromFloat(@floor(y));
    const ix1: isize = @intFromFloat(@ceil(x + rw));
    const iy1: isize = @intFromFloat(@ceil(y + rh));

    // Clamp to framebuffer bounds
    const x0: usize = @intCast(@max(ix0, 0));
    const y0: usize = @intCast(@max(iy0, 0));
    const x1: usize = @intCast(@min(ix1, @as(isize, @intCast(w))));
    const y1: usize = @intCast(@min(iy1, @as(isize, @intCast(h))));

    if (x0 >= x1 or y0 >= y1) return;

    const span_width = x1 - x0;

    // Use SIMD-optimized span fill for each row
    var iy: usize = y0;
    while (iy < y1) : (iy += 1) {
        const row_start = (iy * w + x0) * 4;
        simd.fillSpan(rgba, row_start, span_width, r, g, b, a, mode);
    }
}

/// Fill an axis-aligned rectangle with anti-aliasing at edges.
/// Uses SIMD-accelerated 4x4 sub-pixel sampling for smooth edge coverage.
fn fbFillRectAA(rgba: []u8, w: usize, h: usize, x: f32, y: f32, rw: f32, rh: f32, r: u8, g: u8, b: u8, a: u8, mode: u32) void {
    if (rw <= 0.0 or rh <= 0.0) return;

    const x1 = x;
    const y1 = y;
    const x2 = x + rw;
    const y2 = y + rh;

    // Expand bounds by 1 pixel to include edge pixels that might have partial coverage
    const ix0: isize = @intFromFloat(@floor(x1));
    const iy0: isize = @intFromFloat(@floor(y1));
    const ix1: isize = @intFromFloat(@ceil(x2));
    const iy1: isize = @intFromFloat(@ceil(y2));

    // Clamp to framebuffer bounds
    const px0: usize = @intCast(@max(ix0, 0));
    const py0: usize = @intCast(@max(iy0, 0));
    const px1: usize = @intCast(@min(ix1, @as(isize, @intCast(w))));
    const py1: usize = @intCast(@min(iy1, @as(isize, @intCast(h))));

    if (px0 >= px1 or py0 >= py1) return;

    // Identify interior region (fully covered pixels)
    const interior_x0: usize = @intCast(@max(@as(isize, @intFromFloat(@ceil(x1))), @as(isize, @intCast(px0))));
    const interior_y0: usize = @intCast(@max(@as(isize, @intFromFloat(@ceil(y1))), @as(isize, @intCast(py0))));
    const interior_x1: usize = @intCast(@min(@as(isize, @intFromFloat(@floor(x2))), @as(isize, @intCast(px1))));
    const interior_y1: usize = @intCast(@min(@as(isize, @intFromFloat(@floor(y2))), @as(isize, @intCast(py1))));

    // Fill interior rows with SIMD (no AA needed)
    if (interior_x0 < interior_x1 and interior_y0 < interior_y1) {
        const span_width = interior_x1 - interior_x0;
        var iy: usize = interior_y0;
        while (iy < interior_y1) : (iy += 1) {
            const row_start = (iy * w + interior_x0) * 4;
            simd.fillSpan(rgba, row_start, span_width, r, g, b, a, mode);
        }
    }

    // Process edge pixels with vectorized AA coverage calculation
    var iy: usize = py0;
    while (iy < py1) : (iy += 1) {
        var ix: usize = px0;
        while (ix < px1) : (ix += 1) {
            // Skip interior pixels (already filled above)
            if (ix >= interior_x0 and ix < interior_x1 and
                iy >= interior_y0 and iy < interior_y1)
            {
                continue;
            }

            const px: f32 = @floatFromInt(ix);
            const py: f32 = @floatFromInt(iy);

            // Use SIMD-accelerated coverage calculation
            const coverage = simd.computeRectCoverageAA(px, py, x1, y1, x2, y2);

            if (coverage > 0.0) {
                const idx: usize = (iy * w + ix) * 4;
                if (coverage >= 1.0) {
                    fbBlendPixel(rgba, idx, r, g, b, a, mode);
                } else {
                    fbBlendPixelAA(rgba, idx, r, g, b, a, mode, coverage);
                }
            }
        }
    }
}


fn readF32LE(r: anytype) !f32 {

    var b: [4]u8 = undefined;
    try readExact(r, b[0..]);

    const u: u32 =
        (@as(u32, b[0])) |
        (@as(u32, b[1]) << 8) |
        (@as(u32, b[2]) << 16) |
        (@as(u32, b[3]) << 24);

    return @bitCast(u);
}

fn readU32LE(r: anytype) !u32 {
    var b: [4]u8 = undefined;
    try readExact(r, b[0..]);
    return (@as(u32, b[0])) |
        (@as(u32, b[1]) << 8) |
        (@as(u32, b[2]) << 16) |
        (@as(u32, b[3]) << 24);
}

const ClipRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

fn fbFillRectClipped(rgba: []u8, w: usize, h: usize, rx: f32, ry: f32, rw: f32, rh: f32, r: u8, g: u8, b: u8, a: u8, mode: u32, clips: ?[]const ClipRect) void {
    if (clips) |cs| {
        // Apply union of clip rects by filling each intersection.
        for (cs) |c| {
            const ix = @max(rx, c.x);
            const iy = @max(ry, c.y);
            const ix2 = @min(rx + rw, c.x + c.w);
            const iy2 = @min(ry + rh, c.y + c.h);
            const iw = ix2 - ix;
            const ih = iy2 - iy;
            if (iw <= 0.0 or ih <= 0.0) continue;
            fbFillRect(rgba, w, h, ix, iy, iw, ih, r, g, b, a, mode);
        }
    } else {
        fbFillRect(rgba, w, h, rx, ry, rw, rh, r, g, b, a, mode);
    }
}

fn fbFillRectClippedAA(rgba: []u8, w: usize, h: usize, rx: f32, ry: f32, rw: f32, rh: f32, r: u8, g: u8, b: u8, a: u8, mode: u32, clips: ?[]const ClipRect) void {
    if (clips) |cs| {
        // Apply union of clip rects by filling each intersection.
        for (cs) |c| {
            const ix = @max(rx, c.x);
            const iy = @max(ry, c.y);
            const ix2 = @min(rx + rw, c.x + c.w);
            const iy2 = @min(ry + rh, c.y + c.h);
            const iw = ix2 - ix;
            const ih = iy2 - iy;
            if (iw <= 0.0 or ih <= 0.0) continue;
            fbFillRectAA(rgba, w, h, ix, iy, iw, ih, r, g, b, a, mode);
        }
    } else {
        fbFillRectAA(rgba, w, h, rx, ry, rw, rh, r, g, b, a, mode);
    }
}

const Transform2D = struct {
    a: f32 = 1.0,
    b: f32 = 0.0,
    c: f32 = 0.0,
    d: f32 = 1.0,
    e: f32 = 0.0,
    f: f32 = 0.0,
};



fn applyT(t: Transform2D, x: f32, y: f32) struct { x: f32, y: f32 } {
    return .{
        .x = t.a * x + t.c * y + t.e,
        .y = t.b * x + t.d * y + t.f,
    };
}

fn rectApplyTBounds(t: Transform2D, x: f32, y: f32, w: f32, h: f32) struct { x: f32, y: f32, w: f32, h: f32 } {
    // Transform 4 corners and return axis aligned bounds
    const p0 = applyT(t, x, y);
    const p1 = applyT(t, x + w, y);
    const p2 = applyT(t, x, y + h);
    const p3 = applyT(t, x + w, y + h);

    var minx = p0.x;
    var miny = p0.y;
    var maxx = p0.x;
    var maxy = p0.y;

    inline for ([_]@TypeOf(p0){ p1, p2, p3 }) |p| {
        if (p.x < minx) minx = p.x;
        if (p.y < miny) miny = p.y;
        if (p.x > maxx) maxx = p.x;
        if (p.y > maxy) maxy = p.y;
    }

    return .{ .x = minx, .y = miny, .w = (maxx - minx), .h = (maxy - miny) };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 5) {
        std.log.err("usage: {s} file.sdcs out.ppm width height", .{args[0]});
        return error.InvalidArgument;
    }

    const in_path = args[1];
    const out_path = args[2];
    const w = try std.fmt.parseInt(usize, args[3], 10);
    const h = try std.fmt.parseInt(usize, args[4], 10);

    var rgba = try alloc.alloc(u8, w * h * 4);
    defer alloc.free(rgba);

    var clip_rects = std.ArrayList(ClipRect){};
    defer clip_rects.deinit(alloc);
    var clip_enabled: bool = false;
    var t = Transform2D{};
    var blend_mode: u32 = 0;
    var aa_enabled: bool = false;
var stroke_join: StrokeJoin = .Miter;
var stroke_cap: StrokeCap = .Butt;
var miter_limit: f32 = 4.0; // SVG default

var last_line_valid: bool = false;

var pending_cap_valid: bool = false;
var pending_end_x: f32 = 0;
var pending_end_y: f32 = 0;
var pending_dir_axis: u8 = 0; // 0=h,1=v
var pending_dir_sign: i8 = 0; // +1 or -1
var pending_sw: f32 = 0;
var pending_cr: f32 = 0;
var pending_cg: f32 = 0;
var pending_cb: f32 = 0;
var pending_ca: f32 = 0;
var pending_t: Transform2D = .{ .a=1, .b=0, .c=0, .d=1, .e=0, .f=0 };
var last_x1: f32 = 0;
var last_y1: f32 = 0;
var last_x2: f32 = 0;
var last_y2: f32 = 0;
var last_sw: f32 = 0;
var last_cr: f32 = 0;
var last_cg: f32 = 0;
var last_cb: f32 = 0;
var last_ca: f32 = 0;

    // background 0x102030
    for (0..h) |yy| {
        for (0..w) |xx| {
            const i = (yy * w + xx) * 4;
            rgba[i + 0] = 16;
            rgba[i + 1] = 32;
            rgba[i + 2] = 48;
            rgba[i + 3] = 255;
        }
    }

    var file = try std.fs.cwd().openFile(in_path, .{});
    defer file.close();

    // Validate before executing
    try sdcs.validateFile(file);
    try file.seekTo(0);

    // Zig 0.15.x: use `fs.File` directly (fs.File.Reader does not expose `.read()`).
    var file_r = file;

    var header: sdcs.Header = undefined;
    try readExact(file_r, std.mem.asBytes(&header));
    if (!std.mem.eql(u8, header.magic[0..], sdcs.Magic)) return error.Protocol;

    while (true) {
        var ch: sdcs.ChunkHeader = undefined;
        const got = file_r.read(std.mem.asBytes(&ch)) catch return;
        if (got == 0) break;
        if (got != @sizeOf(sdcs.ChunkHeader)) break;

        if (ch.type != sdcs.ChunkType.CMDS) {
            try file.seekBy(@intCast(ch.payload_bytes));
            continue;
        }

        var remaining: usize = @intCast(ch.payload_bytes);
        while (remaining >= @sizeOf(sdcs.CmdHdr)) {
            var cmd: sdcs.CmdHdr = undefined;
            try readExact(file_r, std.mem.asBytes(&cmd));
            remaining -= @sizeOf(sdcs.CmdHdr);

            // Padding marker: allow trailing zeroed records
            // flush pending end cap if the next command cannot connect to the previous segment
if (pending_cap_valid and cmd.opcode != sdcs.Op.STROKE_LINE) {
    if (stroke_cap == .Square) {
        emitSquareCap(
            rgba,
            w,
            h,
            pending_t,
            clip_enabled,
            clip_rects.items,
            blend_mode,
            pending_end_x,
            pending_end_y,
            pending_dir_axis,
            pending_dir_sign,
            pending_sw,
            pending_cr,
            pending_cg,
            pending_cb,
            pending_ca,
        );
    }
else if (stroke_cap == .Round) {
    if (aa_enabled) {
        emitRoundCapAA(rgba, w, h, pending_t, clip_enabled, clip_rects.items, blend_mode, pending_end_x, pending_end_y, pending_sw, pending_cr, pending_cg, pending_cb, pending_ca);
    } else {
        emitRoundCap(rgba, w, h, pending_t, clip_enabled, clip_rects.items, blend_mode, pending_end_x, pending_end_y, pending_sw, pending_cr, pending_cg, pending_cb, pending_ca);
    }
}

    pending_cap_valid = false;
}

if (cmd.opcode == 0 and cmd.flags == 0 and cmd.payload_bytes == 0) {
                break;
            }


            const pb: usize = @intCast(cmd.payload_bytes);
            if (pb > remaining) break;

            var lr = LimitedFileReader{ .file = &file, .remaining = pb };
            const r = lr.reader();

            if (cmd.opcode == sdcs.Op.SET_BLEND) {
                blend_mode = try readU32LE(r);
            } else if (cmd.opcode == sdcs.Op.SET_ANTIALIAS) {
                const aa_val = try readU32LE(r);
                aa_enabled = (aa_val != 0);
            } else if (cmd.opcode == sdcs.Op.SET_TRANSFORM_2D) {
                t.a = try readF32LE(r);
                t.b = try readF32LE(r);
                t.c = try readF32LE(r);
                t.d = try readF32LE(r);
                t.e = try readF32LE(r);
                t.f = try readF32LE(r);
            } else if (cmd.opcode == sdcs.Op.RESET_TRANSFORM) {
                t = Transform2D{};
            } else if (cmd.opcode == sdcs.Op.SET_CLIP_RECTS) {
                // payload: u32 count + rects
                const count = try readU32LE(r);
                clip_rects.clearRetainingCapacity();
                clip_enabled = (count != 0);
                // consume bytes: count + rects
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const cx = try readF32LE(r);
                    const cy = try readF32LE(r);
                    const cw = try readF32LE(r);
                    const ch2 = try readF32LE(r);
                    try clip_rects.append(alloc, .{ .x = cx, .y = cy, .w = cw, .h = ch2 });
                }

            } else if (cmd.opcode == sdcs.Op.CLEAR_CLIP) {
                clip_rects.clearRetainingCapacity();
                clip_enabled = false;
            } else if (cmd.opcode == sdcs.Op.SET_STROKE_JOIN) {
                const join_u = try readU32LE(r);
                if (join_u == 0) {
                    stroke_join = .Miter;
                } else if (join_u == 1) {
                    stroke_join = .Bevel;
                } else {
                    stroke_join = .Miter;
                }
                last_line_valid = false;
            } else if (cmd.opcode == sdcs.Op.SET_STROKE_CAP) {
                const cap_u = try readU32LE(r);
                if (cap_u == 0) {
                    stroke_cap = .Butt;
                } else if (cap_u == 1) {
                    stroke_cap = .Square;
                } else if (cap_u == 2) {
                    stroke_cap = .Round;
                } else {
                    stroke_cap = .Butt;
                }
                last_line_valid = false;
                pending_cap_valid = false;
            } else if (cmd.opcode == sdcs.Op.SET_MITER_LIMIT) {
                const limit = try readF32LE(r);
                // Clamp to minimum of 1.0 (values below 1.0 don't make geometric sense)
                miter_limit = if (limit < 1.0) 1.0 else limit;
            } else if (cmd.opcode == sdcs.Op.STROKE_LINE) {
    // x1,y1,x2,y2,stroke_width,r,g,b,a (9 x f32 = 36 bytes)
    const x1 = try readF32LE(r);
    const y1 = try readF32LE(r);
    const x2 = try readF32LE(r);
    const y2 = try readF32LE(r);
    const sw = try readF32LE(r);
    const cr = try readF32LE(r);
    const cg = try readF32LE(r);
    const cb = try readF32LE(r);
    const ca = try readF32LE(r);
            // caps v1: manage pending end caps and emit start caps when not connected
            const eps: f32 = 0.0001;

            const cur_h = (@abs(y1 - y2) < eps);
            const cur_v = (@abs(x1 - x2) < eps);

            // If the new segment starts at the previous end, suppress the previous end cap.
            if (pending_cap_valid) {
                const connects_prev =
                    (@abs(pending_end_x - x1) < eps and @abs(pending_end_y - y1) < eps) or
                    (@abs(pending_end_x - x2) < eps and @abs(pending_end_y - y2) < eps);

                if (!connects_prev) {
                    if (stroke_cap == .Square) {
                        emitSquareCap(
                            rgba,
                            w,
                            h,
                            pending_t,
                            clip_enabled,
                            clip_rects.items,
                            blend_mode,
                            pending_end_x,
                            pending_end_y,
                            pending_dir_axis,
                            pending_dir_sign,
                            pending_sw,
                            pending_cr,
                            pending_cg,
                            pending_cb,
                            pending_ca,
                        );
                    }
else if (stroke_cap == .Round) {
    if (aa_enabled) {
        emitRoundCapAA(rgba, w, h, pending_t, clip_enabled, clip_rects.items, blend_mode, pending_end_x, pending_end_y, pending_sw, pending_cr, pending_cg, pending_cb, pending_ca);
    } else {
        emitRoundCap(rgba, w, h, pending_t, clip_enabled, clip_rects.items, blend_mode, pending_end_x, pending_end_y, pending_sw, pending_cr, pending_cg, pending_cb, pending_ca);
    }
}

                }
                pending_cap_valid = false;
            }

            // Start cap at (x1,y1) if not connected to last segment.
            if (stroke_cap == .Square) {
                var start_connected: bool = false;
                if (last_line_valid) {
                    start_connected =
                        (@abs(last_x2 - x1) < eps and @abs(last_y2 - y1) < eps) or
                        (@abs(last_x1 - x1) < eps and @abs(last_y1 - y1) < eps);
                }
                if (!start_connected) {
                    var axis: u8 = 0;
                    var sign: i8 = 0;
                    if (cur_h) {
                        axis = 0;
                        sign = if (x2 >= x1) 1 else -1;
                    } else if (cur_v) {
                        axis = 1;
                        sign = if (y2 >= y1) 1 else -1;
                    }
                    if (sign != 0) {
                        emitSquareCap(
                            rgba,
                            w,
                            h,
                            t,
                            clip_enabled,
                            clip_rects.items,
                            blend_mode,
                            x1,
                            y1,
                            axis,
                            -sign,
                            sw,
                            cr,
                            cg,
                            cb,
                            ca,
                        );
                    }
                }
            }

            // Defer end cap for this segment to the next command
            if (stroke_cap == .Square) {
                pending_cap_valid = true;
                pending_end_x = x2;
                pending_end_y = y2;
                pending_sw = sw;
                pending_cr = cr;
                pending_cg = cg;
                pending_cb = cb;
                pending_ca = ca;
                pending_t = t;

                if (cur_h) {
                    pending_dir_axis = 0;
                    pending_dir_sign = if (x2 >= x1) 1 else -1;
                } else if (cur_v) {
                    pending_dir_axis = 1;
                    pending_dir_sign = if (y2 >= y1) 1 else -1;
                } else {
                    pending_dir_axis = 0;
                    pending_dir_sign = 0;
                    pending_cap_valid = false;
                }
            }

            // Joins: for now we only emit additional geometry when we can reliably
            // detect an axis aligned right angle between consecutive STROKE_LINE
            // segments that share an endpoint and share style parameters.
            if (last_line_valid and sw == last_sw and cr == last_cr and cg == last_cg and cb == last_cb and ca == last_ca) {
                const last_h = (@abs(last_y1 - last_y2) < eps);
                const last_v = (@abs(last_x1 - last_x2) < eps);

                // Only right angle joins between axis aligned segments.
                if ((last_h and cur_v) or (last_v and cur_h)) {
                    const jx: f32 = x1;
                    const jy: f32 = y1;
                    const connects =
                        (@abs(last_x2 - jx) < eps and @abs(last_y2 - jy) < eps) or
                        (@abs(last_x1 - jx) < eps and @abs(last_y1 - jy) < eps);

                    if (connects) {
                        if (stroke_join == .Round) {
                            // Round join is approximated by a filled disk at the join point.
                            if (aa_enabled) {
                                emitRoundCapAA(rgba, w, h, t, clip_enabled, clip_rects.items, blend_mode, jx, jy, sw, cr, cg, cb, ca);
                            } else {
                                emitRoundCap(rgba, w, h, t, clip_enabled, clip_rects.items, blend_mode, jx, jy, sw, cr, cg, cb, ca);
                            }
                        } else if (stroke_join == .Miter) {
                            // Miter join v1: emit an extra sw x sw corner block on the outer corner.
                            // For 90-degree (right angle) joins, the miter ratio is sqrt(2) ≈ 1.414.
                            // If miter_limit < sqrt(2), fall back to bevel (no extra geometry).
                            const sqrt2: f32 = 1.41421356237;
                            if (miter_limit >= sqrt2) {
                                var sx: f32 = 0;
                                var sy: f32 = 0;

                                if (last_h) {
                                    if (@abs(last_x2 - jx) < eps) sx = if (last_x2 > last_x1) 1 else -1 else sx = if (last_x1 > last_x2) 1 else -1;
                                } else if (cur_h) {
                                    if (@abs(x2 - jx) < eps) sx = if (x2 > x1) 1 else -1 else sx = if (x1 > x2) 1 else -1;
                                }

                                if (last_v) {
                                    if (@abs(last_y2 - jy) < eps) sy = if (last_y2 > last_y1) 1 else -1 else sy = if (last_y1 > last_y2) 1 else -1;
                                } else if (cur_v) {
                                    if (@abs(y2 - jy) < eps) sy = if (y2 > y1) 1 else -1 else sy = if (y1 > y2) 1 else -1;
                                }

                                if (sx != 0 and sy != 0) {
                                    const px = jx + (if (sx > 0) 0 else -sw);
                                    const py = jy + (if (sy > 0) 0 else -sw);
                                    const patch = rectApplyTBounds(t, px, py, sw, sw);
                                    const join_clips = if (clip_enabled) clip_rects.items else null;
                                    if (aa_enabled) {
                                        fbFillRectClippedAA(rgba, w, h, patch.x, patch.y, patch.w, patch.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, join_clips);
                                    } else {
                                        fbFillRectClipped(rgba, w, h, patch.x, patch.y, patch.w, patch.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, join_clips);
                                    }
                                }
                            }
                            // else: miter_limit < sqrt(2), fall back to bevel (no extra geometry)
                        }
                    }
                }
            }


    // Payload length already accounted for by outer loop.

    if (sw <= 0.0) continue;

    // v1 semantics: only axis aligned lines in user space
    const s2: f32 = sw / 2.0;
    const clips = if (clip_enabled) clip_rects.items else null;

    if (x1 == x2) {
        const yy0 = @min(y1, y2);
        const yy1 = @max(y1, y2);
        const rect = rectApplyTBounds(t, x1 - s2, yy0, sw, yy1 - yy0);
        if (aa_enabled) {
            fbFillRectClippedAA(rgba, w, h, rect.x, rect.y, rect.w, rect.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clips);
        } else {
            fbFillRectClipped(rgba, w, h, rect.x, rect.y, rect.w, rect.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clips);
        }
    } else if (y1 == y2) {
        const xx0 = @min(x1, x2);
        const xx1 = @max(x1, x2);
        const rect = rectApplyTBounds(t, xx0, y1 - s2, xx1 - xx0, sw);
        if (aa_enabled) {
            fbFillRectClippedAA(rgba, w, h, rect.x, rect.y, rect.w, rect.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clips);
        } else {
            fbFillRectClipped(rgba, w, h, rect.x, rect.y, rect.w, rect.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clips);
        }
    } else {
        // v2: arbitrary-angle lines with proper oriented quad rasterization
        if (aa_enabled) {
            emitStrokedLineArbitraryAA(rgba, w, h, t, clip_enabled, clip_rects.items, blend_mode, x1, y1, x2, y2, sw, cr, cg, cb, ca);
        } else {
            emitStrokedLineArbitrary(rgba, w, h, t, clip_enabled, clip_rects.items, blend_mode, x1, y1, x2, y2, sw, cr, cg, cb, ca);
        }
    }
            // update last segment info for join detection
            last_line_valid = true;
            last_x1 = x1;
            last_y1 = y1;
            last_x2 = x2;
            last_y2 = y2;
            last_sw = sw;
            last_cr = cr;
            last_cg = cg;
            last_cb = cb;
            last_ca = ca;

}

else if (cmd.opcode == sdcs.Op.STROKE_RECT) {
    // x,y,w,h,stroke_width,r,g,b,a (9 x f32 = 36 bytes)
    const rx = try readF32LE(r);
    const ry = try readF32LE(r);
    const rw2 = try readF32LE(r);
    const rh2 = try readF32LE(r);
    const sw = try readF32LE(r);
    const cr = try readF32LE(r);
    const cg = try readF32LE(r);
    const cb = try readF32LE(r);
    const ca = try readF32LE(r);

    // Payload length already accounted for by outer loop.

    if (sw <= 0.0) continue;

    const s2: f32 = sw / 2.0;

    // Build four edge rectangles in user space
    const top = rectApplyTBounds(t, rx - s2, ry - s2, rw2 + sw, sw);
    const bottom = rectApplyTBounds(t, rx - s2, ry + rh2 - s2, rw2 + sw, sw);
    const left = rectApplyTBounds(t, rx - s2, ry + s2, sw, @max(0.0, rh2 - sw));
    const right = rectApplyTBounds(t, rx + rw2 - s2, ry + s2, sw, @max(0.0, rh2 - sw));

    const clips = if (clip_enabled) clip_rects.items else null;
    if (aa_enabled) {
        fbFillRectClippedAA(rgba, w, h, top.x, top.y, top.w, top.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clips);
        fbFillRectClippedAA(rgba, w, h, bottom.x, bottom.y, bottom.w, bottom.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clips);
        fbFillRectClippedAA(rgba, w, h, left.x, left.y, left.w, left.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clips);
        fbFillRectClippedAA(rgba, w, h, right.x, right.y, right.w, right.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clips);
    } else {
        fbFillRectClipped(rgba, w, h, top.x, top.y, top.w, top.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clips);
        fbFillRectClipped(rgba, w, h, bottom.x, bottom.y, bottom.w, bottom.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clips);
        fbFillRectClipped(rgba, w, h, left.x, left.y, left.w, left.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clips);
        fbFillRectClipped(rgba, w, h, right.x, right.y, right.w, right.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clips);
    }
}

else if (cmd.opcode == sdcs.Op.FILL_RECT) {
                if (pb != 32) return error.Protocol;
                const rx = try readF32LE(r);
                const ry = try readF32LE(r);
                const rw2 = try readF32LE(r);
                const rh2 = try readF32LE(r);
                const cr = try readF32LE(r);
                const cg = try readF32LE(r);
                const cb = try readF32LE(r);
                const ca = try readF32LE(r);
                const tb = rectApplyTBounds(t, rx, ry, rw2, rh2);
                if (aa_enabled) {
                    fbFillRectClippedAA(rgba, w, h, tb.x, tb.y, tb.w, tb.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, if (clip_enabled) clip_rects.items else null);
                } else {
                    fbFillRectClipped(rgba, w, h, tb.x, tb.y, tb.w, tb.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, if (clip_enabled) clip_rects.items else null);
                }

            } else if (cmd.opcode == sdcs.Op.BLIT_IMAGE) {
                // Payload: dst_x(f32), dst_y(f32), img_w(u32), img_h(u32), pixels(RGBA)
                if (pb < 16) return error.Protocol;
                const dst_x = try readF32LE(r);
                const dst_y = try readF32LE(r);
                const img_w = try readU32LE(r);
                const img_h = try readU32LE(r);

                const pixel_bytes: usize = @as(usize, img_w) * @as(usize, img_h) * 4;
                if (pb != 16 + pixel_bytes) return error.Protocol;
                if (img_w == 0 or img_h == 0) continue;

                // Read pixel data into temporary buffer
                const pixels = try alloc.alloc(u8, pixel_bytes);
                defer alloc.free(pixels);
                try readExact(r, pixels);

                // Blit each pixel with transform, clip, and blend
                var iy: u32 = 0;
                while (iy < img_h) : (iy += 1) {
                    var ix: u32 = 0;
                    while (ix < img_w) : (ix += 1) {
                        const src_idx: usize = (@as(usize, iy) * @as(usize, img_w) + @as(usize, ix)) * 4;
                        const sr = pixels[src_idx + 0];
                        const sg = pixels[src_idx + 1];
                        const sb = pixels[src_idx + 2];
                        const sa = pixels[src_idx + 3];

                        // Skip fully transparent pixels
                        if (sa == 0) continue;

                        // Transform source pixel position to screen space
                        const px = dst_x + @as(f32, @floatFromInt(ix)) + 0.5;
                        const py = dst_y + @as(f32, @floatFromInt(iy)) + 0.5;
                        const tp = applyT(t, px, py);

                        // Clip test
                        if (clip_enabled and !pointInClips(tp.x, tp.y, clip_rects.items)) continue;

                        // Bounds check
                        const dx: isize = @intFromFloat(@floor(tp.x));
                        const dy: isize = @intFromFloat(@floor(tp.y));
                        if (dx < 0 or dy < 0) continue;
                        if (dx >= @as(isize, @intCast(w)) or dy >= @as(isize, @intCast(h))) continue;

                        const dst_idx: usize = (@as(usize, @intCast(dy)) * w + @as(usize, @intCast(dx))) * 4;
                        fbBlendPixel(rgba, dst_idx, sr, sg, sb, sa, blend_mode);
                    }
                }

            } else if (cmd.opcode == sdcs.Op.STROKE_QUAD_BEZIER) {
                // Payload: x0, y0, cx, cy, x1, y1, stroke_width, r, g, b, a (11 x f32 = 44 bytes)
                if (pb != 44) return error.Protocol;
                const bx0 = try readF32LE(r);
                const by0 = try readF32LE(r);
                const bcx = try readF32LE(r);
                const bcy = try readF32LE(r);
                const bx1 = try readF32LE(r);
                const by1 = try readF32LE(r);
                const bsw = try readF32LE(r);
                const bcr = try readF32LE(r);
                const bcg = try readF32LE(r);
                const bcb = try readF32LE(r);
                const bca = try readF32LE(r);

                if (bsw <= 0.0) continue;

                if (aa_enabled) {
                    emitStrokedQuadBezierAA(rgba, w, h, t, clip_enabled, clip_rects.items, blend_mode, bx0, by0, bcx, bcy, bx1, by1, bsw, bcr, bcg, bcb, bca);
                } else {
                    emitStrokedQuadBezier(rgba, w, h, t, clip_enabled, clip_rects.items, blend_mode, bx0, by0, bcx, bcy, bx1, by1, bsw, bcr, bcg, bcb, bca);
                }

                // Reset line tracking state since curves don't participate in joins
                last_line_valid = false;

            } else if (cmd.opcode == sdcs.Op.STROKE_CUBIC_BEZIER) {
                // Payload: x0, y0, cx1, cy1, cx2, cy2, x1, y1, stroke_width, r, g, b, a (13 x f32 = 52 bytes)
                if (pb != 52) return error.Protocol;
                const bx0 = try readF32LE(r);
                const by0 = try readF32LE(r);
                const bcx1 = try readF32LE(r);
                const bcy1 = try readF32LE(r);
                const bcx2 = try readF32LE(r);
                const bcy2 = try readF32LE(r);
                const bx1 = try readF32LE(r);
                const by1 = try readF32LE(r);
                const bsw = try readF32LE(r);
                const bcr = try readF32LE(r);
                const bcg = try readF32LE(r);
                const bcb = try readF32LE(r);
                const bca = try readF32LE(r);

                if (bsw <= 0.0) continue;

                if (aa_enabled) {
                    emitStrokedCubicBezierAA(rgba, w, h, t, clip_enabled, clip_rects.items, blend_mode, bx0, by0, bcx1, bcy1, bcx2, bcy2, bx1, by1, bsw, bcr, bcg, bcb, bca);
                } else {
                    emitStrokedCubicBezier(rgba, w, h, t, clip_enabled, clip_rects.items, blend_mode, bx0, by0, bcx1, bcy1, bcx2, bcy2, bx1, by1, bsw, bcr, bcg, bcb, bca);
                }

                // Reset line tracking state since curves don't participate in joins
                last_line_valid = false;

            } else if (cmd.opcode == sdcs.Op.STROKE_PATH) {
                // Payload: stroke_width, r, g, b, a (5 f32), point_count (u32), points (N x 2 x f32)
                if (pb < 24) return error.Protocol;
                const psw = try readF32LE(r);
                const pcr = try readF32LE(r);
                const pcg = try readF32LE(r);
                const pcb = try readF32LE(r);
                const pca = try readF32LE(r);
                const point_count = try readU32LE(r);

                // Validate payload size: 24 bytes header + point_count * 8 bytes
                const expected_size: usize = 24 + @as(usize, point_count) * 8;
                if (pb != expected_size) return error.Protocol;
                if (point_count < 2) continue;
                if (psw <= 0.0) continue;

                // Read all points
                const PathPoint = struct { x: f32, y: f32 };
                const path_points = try alloc.alloc(PathPoint, point_count);
                defer alloc.free(path_points);

                for (path_points) |*pt| {
                    pt.x = try readF32LE(r);
                    pt.y = try readF32LE(r);
                }

                // Draw each line segment with proper joins
                const eps: f32 = 0.0001;
                var prev_seg_x1: f32 = 0;
                var prev_seg_y1: f32 = 0;
                var prev_seg_x2: f32 = 0;
                var prev_seg_y2: f32 = 0;
                var prev_seg_valid: bool = false;

                var seg_i: usize = 0;
                while (seg_i < point_count - 1) : (seg_i += 1) {
                    const sx1 = path_points[seg_i].x;
                    const sy1 = path_points[seg_i].y;
                    const sx2 = path_points[seg_i + 1].x;
                    const sy2 = path_points[seg_i + 1].y;

                    // Check if current segment is axis-aligned
                    const cur_h = (@abs(sy1 - sy2) < eps);
                    const cur_v = (@abs(sx1 - sx2) < eps);

                    // Emit join at start of segment if connected to previous
                    const path_clips = if (clip_enabled) clip_rects.items else null;
                    if (prev_seg_valid) {
                        const prev_h = (@abs(prev_seg_y1 - prev_seg_y2) < eps);
                        const prev_v = (@abs(prev_seg_x1 - prev_seg_x2) < eps);

                        // Only right-angle joins between axis-aligned segments
                        if ((prev_h and cur_v) or (prev_v and cur_h)) {
                            const jx = sx1;
                            const jy = sy1;
                            const connects = (@abs(prev_seg_x2 - jx) < eps and @abs(prev_seg_y2 - jy) < eps);

                            if (connects) {
                                if (stroke_join == .Round) {
                                    if (aa_enabled) {
                                        emitRoundCapAA(rgba, w, h, t, clip_enabled, clip_rects.items, blend_mode, jx, jy, psw, pcr, pcg, pcb, pca);
                                    } else {
                                        emitRoundCap(rgba, w, h, t, clip_enabled, clip_rects.items, blend_mode, jx, jy, psw, pcr, pcg, pcb, pca);
                                    }
                                } else if (stroke_join == .Miter) {
                                    const sqrt2: f32 = 1.41421356237;
                                    if (miter_limit >= sqrt2) {
                                        var sx: f32 = 0;
                                        var sy: f32 = 0;
                                        if (prev_h) {
                                            sx = if (prev_seg_x2 > prev_seg_x1) 1 else -1;
                                        } else if (cur_h) {
                                            sx = if (sx2 > sx1) 1 else -1;
                                        }
                                        if (prev_v) {
                                            sy = if (prev_seg_y2 > prev_seg_y1) 1 else -1;
                                        } else if (cur_v) {
                                            sy = if (sy2 > sy1) 1 else -1;
                                        }
                                        if (sx != 0 and sy != 0) {
                                            const px = jx + (if (sx > 0) 0 else -psw);
                                            const py = jy + (if (sy > 0) 0 else -psw);
                                            const patch = rectApplyTBounds(t, px, py, psw, psw);
                                            if (aa_enabled) {
                                                fbFillRectClippedAA(rgba, w, h, patch.x, patch.y, patch.w, patch.h, clampU8(pcr), clampU8(pcg), clampU8(pcb), clampU8(pca), blend_mode, path_clips);
                                            } else {
                                                fbFillRectClipped(rgba, w, h, patch.x, patch.y, patch.w, patch.h, clampU8(pcr), clampU8(pcg), clampU8(pcb), clampU8(pca), blend_mode, path_clips);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Draw the line segment
                    const s2: f32 = psw / 2.0;
                    if (sx1 == sx2) {
                        const yy0 = @min(sy1, sy2);
                        const yy1 = @max(sy1, sy2);
                        const rect = rectApplyTBounds(t, sx1 - s2, yy0, psw, yy1 - yy0);
                        if (aa_enabled) {
                            fbFillRectClippedAA(rgba, w, h, rect.x, rect.y, rect.w, rect.h, clampU8(pcr), clampU8(pcg), clampU8(pcb), clampU8(pca), blend_mode, path_clips);
                        } else {
                            fbFillRectClipped(rgba, w, h, rect.x, rect.y, rect.w, rect.h, clampU8(pcr), clampU8(pcg), clampU8(pcb), clampU8(pca), blend_mode, path_clips);
                        }
                    } else if (sy1 == sy2) {
                        const xx0 = @min(sx1, sx2);
                        const xx1 = @max(sx1, sx2);
                        const rect = rectApplyTBounds(t, xx0, sy1 - s2, xx1 - xx0, psw);
                        if (aa_enabled) {
                            fbFillRectClippedAA(rgba, w, h, rect.x, rect.y, rect.w, rect.h, clampU8(pcr), clampU8(pcg), clampU8(pcb), clampU8(pca), blend_mode, path_clips);
                        } else {
                            fbFillRectClipped(rgba, w, h, rect.x, rect.y, rect.w, rect.h, clampU8(pcr), clampU8(pcg), clampU8(pcb), clampU8(pca), blend_mode, path_clips);
                        }
                    } else {
                        // Arbitrary angle
                        if (aa_enabled) {
                            emitStrokedLineArbitraryAA(rgba, w, h, t, clip_enabled, clip_rects.items, blend_mode, sx1, sy1, sx2, sy2, psw, pcr, pcg, pcb, pca);
                        } else {
                            emitStrokedLineArbitrary(rgba, w, h, t, clip_enabled, clip_rects.items, blend_mode, sx1, sy1, sx2, sy2, psw, pcr, pcg, pcb, pca);
                        }
                    }

                    prev_seg_x1 = sx1;
                    prev_seg_y1 = sy1;
                    prev_seg_x2 = sx2;
                    prev_seg_y2 = sy2;
                    prev_seg_valid = true;
                }

                // Reset line tracking state
                last_line_valid = false;

            } else if (cmd.opcode == sdcs.Op.DRAW_GLYPH_RUN) {
                // Payload: base_x, base_y, r, g, b, a, cell_w, cell_h, atlas_cols,
                //          atlas_w, atlas_h, glyph_count, [glyphs...], [atlas...]
                if (pb < 48) return error.Protocol;
                const gbase_x = try readF32LE(r);
                const gbase_y = try readF32LE(r);
                const gr = try readF32LE(r);
                const gg = try readF32LE(r);
                const gb = try readF32LE(r);
                const ga = try readF32LE(r);
                const cell_w = try readU32LE(r);
                const cell_h = try readU32LE(r);
                const atlas_cols = try readU32LE(r);
                const atlas_w = try readU32LE(r);
                const atlas_h = try readU32LE(r);
                const glyph_count = try readU32LE(r);

                // Validate payload size
                const glyphs_size: usize = @as(usize, glyph_count) * 12;
                const atlas_size: usize = @as(usize, atlas_w) * @as(usize, atlas_h);
                const expected_size: usize = 48 + glyphs_size + atlas_size;
                if (pb != expected_size) return error.Protocol;
                if (glyph_count == 0) continue;
                if (cell_w == 0 or cell_h == 0) continue;
                if (atlas_cols == 0) continue;

                // Read glyph data
                const GlyphEntry = struct { index: u32, x_off: f32, y_off: f32 };
                const glyph_entries = try alloc.alloc(GlyphEntry, glyph_count);
                defer alloc.free(glyph_entries);

                for (glyph_entries) |*ge| {
                    ge.index = try readU32LE(r);
                    ge.x_off = try readF32LE(r);
                    ge.y_off = try readF32LE(r);
                }

                // Read atlas data
                const atlas_data = try alloc.alloc(u8, atlas_size);
                defer alloc.free(atlas_data);
                const bytes_read = try r.read(atlas_data);
                if (bytes_read != atlas_size) return error.Protocol;

                // Render each glyph
                const cr8 = clampU8(gr);
                const cg8 = clampU8(gg);
                const cb8 = clampU8(gb);

                for (glyph_entries) |ge| {
                    // Calculate glyph position in atlas
                    const glyph_row = ge.index / atlas_cols;
                    const glyph_col = ge.index % atlas_cols;
                    const atlas_x: usize = @as(usize, glyph_col) * @as(usize, cell_w);
                    const atlas_y: usize = @as(usize, glyph_row) * @as(usize, cell_h);

                    // Calculate destination position
                    const dst_x = gbase_x + ge.x_off;
                    const dst_y = gbase_y + ge.y_off;

                    // Apply transform to destination
                    const tx = dst_x * t.a + dst_y * t.c + t.e;
                    const ty = dst_x * t.b + dst_y * t.d + t.f;

                    // Render glyph pixels
                    var py: usize = 0;
                    while (py < cell_h) : (py += 1) {
                        var px: usize = 0;
                        while (px < cell_w) : (px += 1) {
                            const src_x = atlas_x + px;
                            const src_y = atlas_y + py;
                            if (src_x >= atlas_w or src_y >= atlas_h) continue;

                            const alpha_idx = src_y * @as(usize, atlas_w) + src_x;
                            const glyph_alpha = atlas_data[alpha_idx];
                            if (glyph_alpha == 0) continue;

                            // Calculate final alpha (glyph alpha * color alpha)
                            const final_alpha: f32 = (@as(f32, @floatFromInt(glyph_alpha)) / 255.0) * ga;
                            const ca8 = clampU8(final_alpha);
                            if (ca8 == 0) continue;

                            // Destination pixel
                            const dx: isize = @as(isize, @intFromFloat(tx)) + @as(isize, @intCast(px));
                            const dy: isize = @as(isize, @intFromFloat(ty)) + @as(isize, @intCast(py));

                            if (dx < 0 or dy < 0) continue;
                            if (dx >= @as(isize, @intCast(w)) or dy >= @as(isize, @intCast(h))) continue;

                            // Check clipping
                            if (clip_enabled) {
                                const dx_f: f32 = @floatFromInt(dx);
                                const dy_f: f32 = @floatFromInt(dy);
                                var in_clip = false;
                                for (clip_rects.items) |cr| {
                                    if (dx_f >= cr.x and dx_f < cr.x + cr.w and
                                        dy_f >= cr.y and dy_f < cr.y + cr.h)
                                    {
                                        in_clip = true;
                                        break;
                                    }
                                }
                                if (!in_clip) continue;
                            }

                            const dst_idx: usize = (@as(usize, @intCast(dy)) * w + @as(usize, @intCast(dx))) * 4;
                            fbBlendPixel(rgba, dst_idx, cr8, cg8, cb8, ca8, blend_mode);
                        }
                    }
                }

                // Reset line tracking state
                last_line_valid = false;

            } else {
                try file.seekBy(@intCast(pb));

            }
            const left = lr.remaining;
            if (left != 0) try file.seekBy(@intCast(left));
            remaining -= pb;

            const pad = sdcs.pad8Len(@sizeOf(sdcs.CmdHdr) + pb);
            if (pad > remaining) return error.Protocol;
            if (pad != 0) try file.seekBy(@intCast(pad));
            remaining -= pad;
            file_r = file;

            if (cmd.opcode == sdcs.Op.END) break;
        }
        break;
    }

    var out = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer out.close();
    
// flush final pending cap
if (pending_cap_valid) {
    if (stroke_cap == .Square) {
        emitSquareCap(
            rgba,
            w,
            h,
            pending_t,
            clip_enabled,
            clip_rects.items,
            blend_mode,
            pending_end_x,
            pending_end_y,
            pending_dir_axis,
            pending_dir_sign,
            pending_sw,
            pending_cr,
            pending_cg,
            pending_cb,
            pending_ca,
        );
    }
else if (stroke_cap == .Round) {
    if (aa_enabled) {
        emitRoundCapAA(rgba, w, h, pending_t, clip_enabled, clip_rects.items, blend_mode, pending_end_x, pending_end_y, pending_sw, pending_cr, pending_cg, pending_cb, pending_ca);
    } else {
        emitRoundCap(rgba, w, h, pending_t, clip_enabled, clip_rects.items, blend_mode, pending_end_x, pending_end_y, pending_sw, pending_cr, pending_cg, pending_cb, pending_ca);
    }
}

    pending_cap_valid = false;
}

// PPM header (P6)
// Zig 0.15+ uses the new std.Io Writer API and std.fmt.format expects a
// compatible writer adapter. std.fs.File.Writer does not provide that adapter,
// so format into a small buffer and write the bytes.
var ppm_hdr_buf: [64]u8 = undefined;
const ppm_hdr = try std.fmt.bufPrint(&ppm_hdr_buf, "P6\n{d} {d}\n255\n", .{ w, h });
try out.writeAll(ppm_hdr);

    // Convert RGBA framebuffer to RGB for PPM output.
    // PPM P6 is 3 bytes per pixel (RGB)
    var rgb_out = try alloc.alloc(u8, w * h * 3);
    defer alloc.free(rgb_out);
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        rgb_out[i * 3 + 0] = rgba[i * 4 + 0];
        rgb_out[i * 3 + 1] = rgba[i * 4 + 1];
        rgb_out[i * 3 + 2] = rgba[i * 4 + 2];
    }
    try out.writeAll(rgb_out);
}
