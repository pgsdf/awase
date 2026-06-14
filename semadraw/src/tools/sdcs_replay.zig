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
    clip: Clip,
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
        clip,
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

// The active clip (ADR 0018). One of three kinds: none (everything passes),
// a union of rectangles (the SET_CLIP_RECTS path, device space), or an
// arbitrary path under a winding rule (SET_CLIP_PATH, baked to device space
// at set time). Path points and lengths are owned by the decode loop; the
// Clip only borrows them.
const ClipKind = enum { none, rects, path };

const Clip = struct {
    kind: ClipKind = .none,
    rects: []const ClipRect = &.{},
    path_pts: []const FillPoint = &.{},
    path_lens: []const u32 = &.{},
    path_even_odd: bool = false,
};

// The per-sample clip predicate: does (px, py) pass the active clip? This is
// the single point of dispatch that every draw routine routes through. The
// path case reuses the Stage A winding predicate, so a path clip admits
// exactly the samples the same contour would fill (ADR 0018 invariant C-1).
fn clipContains(clip: Clip, px: f32, py: f32) bool {
    return switch (clip.kind) {
        .none => true,
        .rects => pointInClips(px, py, clip.rects),
        .path => pointInFilledPath(px, py, clip.path_pts, clip.path_lens, clip.path_even_odd),
    };
}

// Fill an axis-aligned rect region under a path clip by per-sample testing.
// The rect-rect intersection fast path is valid only for a rectangle clip; a
// path clip requires the same per-sample coverage computation emitFilledPath
// uses, so that a rect under a path clip and a coincident FILL_PATH
// antialias identically (ADR 0018 section 5, invariant C-1). A sample
// contributes when it lies inside the rect (half-open, matching the rect
// clip convention) and passes the clip. Solid color arrives pre-quantized in
// r8..a8; a non-null source overrides the color, sampled at the pixel center
// exactly as emitFilledPath samples it.
fn fbFillRectClipPath(
    rgba: []u8,
    w: usize,
    h: usize,
    rx: f32,
    ry: f32,
    rw: f32,
    rh: f32,
    r8: u8,
    g8: u8,
    b8: u8,
    a8: u8,
    mode: u32,
    aa: bool,
    clip: Clip,
    source: ?*const PaintSource,
    tinv: Transform2D,
) void {
    if (rw <= 0.0 or rh <= 0.0) return;

    var minx = rx;
    var miny = ry;
    var maxx = rx + rw;
    var maxy = ry + rh;
    if (minx < 0.0) minx = 0.0;
    if (miny < 0.0) miny = 0.0;
    if (maxx > @as(f32, @floatFromInt(w))) maxx = @as(f32, @floatFromInt(w));
    if (maxy > @as(f32, @floatFromInt(h))) maxy = @as(f32, @floatFromInt(h));
    if (maxx <= minx or maxy <= miny) return;

    const ix0: isize = @intFromFloat(@floor(minx));
    const iy0: isize = @intFromFloat(@floor(miny));
    const ix1: isize = @intFromFloat(@ceil(maxx));
    const iy1: isize = @intFromFloat(@ceil(maxy));

    var iy: isize = iy0;
    while (iy < iy1) : (iy += 1) {
        if (iy < 0 or iy >= @as(isize, @intCast(h))) continue;
        var ix: isize = ix0;
        while (ix < ix1) : (ix += 1) {
            if (ix < 0 or ix >= @as(isize, @intCast(w))) continue;
            const base_px: f32 = @floatFromInt(ix);
            const base_py: f32 = @floatFromInt(iy);
            const idx: usize = (@as(usize, @intCast(iy)) * w + @as(usize, @intCast(ix))) * 4;

            if (aa) {
                var samples_inside: u32 = 0;
                for (AA_SAMPLE_OFFSETS) |offset| {
                    const spx = base_px + offset[0];
                    const spy = base_py + offset[1];
                    if (spx >= rx and spx < rx + rw and spy >= ry and spy < ry + rh and clipContains(clip, spx, spy)) {
                        samples_inside += 1;
                    }
                }
                if (samples_inside > 0) {
                    const coverage: f32 = @as(f32, @floatFromInt(samples_inside)) / @as(f32, @floatFromInt(AA_SAMPLES));
                    if (source) |src| {
                        const col = sampleSourceColor(src, tinv, base_px + 0.5, base_py + 0.5);
                        fbBlendPixelAA(rgba, idx, col[0], col[1], col[2], col[3], mode, coverage);
                    } else {
                        fbBlendPixelAA(rgba, idx, r8, g8, b8, a8, mode, coverage);
                    }
                }
            } else {
                const spx = base_px + 0.5;
                const spy = base_py + 0.5;
                if (spx >= rx and spx < rx + rw and spy >= ry and spy < ry + rh and clipContains(clip, spx, spy)) {
                    if (source) |src| {
                        const col = sampleSourceColor(src, tinv, spx, spy);
                        fbBlendPixel(rgba, idx, col[0], col[1], col[2], col[3], mode);
                    } else {
                        fbBlendPixel(rgba, idx, r8, g8, b8, a8, mode);
                    }
                }
            }
        }
    }
}

/// Rasterize an arbitrary-angle stroked line as an oriented rectangle.
/// The line from (x1,y1) to (x2,y2) is stroked with width sw.
fn emitStrokedLineArbitrary(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip: Clip,
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
            if (!clipContains(clip, px_f, py_f)) continue;

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
    clip: Clip,
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
                if (!clipContains(clip, spx, spy)) continue;

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
    clip: Clip,
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
            clip,
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
    clip: Clip,
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
            clip,
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
    clip: Clip,
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

        emitStrokedLineArbitraryAA(rgba, w, h, t, clip, blend_mode, prev_x, prev_y, pt.x, pt.y, sw, cr, cg, cb, ca);

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
    clip: Clip,
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

        emitStrokedLineArbitraryAA(rgba, w, h, t, clip, blend_mode, prev_x, prev_y, pt.x, pt.y, sw, cr, cg, cb, ca);

        prev_x = pt.x;
        prev_y = pt.y;
    }
}

fn emitRoundCap(
    rgba: []u8,
    w: usize,
    h: usize,
    t: Transform2D,
    clip: Clip,
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

            if (!clipContains(clip, px, py)) continue;

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
    clip: Clip,
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

                if (!clipContains(clip, spx, spy)) continue;

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

fn fbFillRectClipped(rgba: []u8, w: usize, h: usize, rx: f32, ry: f32, rw: f32, rh: f32, r: u8, g: u8, b: u8, a: u8, mode: u32, clip: Clip) void {
    switch (clip.kind) {
        .none => fbFillRect(rgba, w, h, rx, ry, rw, rh, r, g, b, a, mode),
        .rects => {
            // Union of clip rects: fill each rect-rect intersection.
            for (clip.rects) |c| {
                const ix = @max(rx, c.x);
                const iy = @max(ry, c.y);
                const ix2 = @min(rx + rw, c.x + c.w);
                const iy2 = @min(ry + rh, c.y + c.h);
                const iw = ix2 - ix;
                const ih = iy2 - iy;
                if (iw <= 0.0 or ih <= 0.0) continue;
                fbFillRect(rgba, w, h, ix, iy, iw, ih, r, g, b, a, mode);
            }
        },
        .path => fbFillRectClipPath(rgba, w, h, rx, ry, rw, rh, r, g, b, a, mode, false, clip, null, .{}),
    }
}

fn fbFillRectClippedAA(rgba: []u8, w: usize, h: usize, rx: f32, ry: f32, rw: f32, rh: f32, r: u8, g: u8, b: u8, a: u8, mode: u32, clip: Clip) void {
    switch (clip.kind) {
        .none => fbFillRectAA(rgba, w, h, rx, ry, rw, rh, r, g, b, a, mode),
        .rects => {
            // Union of clip rects: fill each rect-rect intersection.
            for (clip.rects) |c| {
                const ix = @max(rx, c.x);
                const iy = @max(ry, c.y);
                const ix2 = @min(rx + rw, c.x + c.w);
                const iy2 = @min(ry + rh, c.y + c.h);
                const iw = ix2 - ix;
                const ih = iy2 - iy;
                if (iw <= 0.0 or ih <= 0.0) continue;
                fbFillRectAA(rgba, w, h, ix, iy, iw, ih, r, g, b, a, mode);
            }
        },
        .path => fbFillRectClipPath(rgba, w, h, rx, ry, rw, rh, r, g, b, a, mode, true, clip, null, .{}),
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

const FillPoint = struct { x: f32, y: f32 };

// Point-in-path test under a winding rule, over one or more closed
// contours (ADR 0015). Points are device-space; each contour is closed
// by connecting its last point to its first. A horizontal ray is cast
// in +x; the half-open crossing convention (a.y <= py) != (b.y <= py)
// counts each crossing once, which is what keeps vertices that land on
// a sample row from double-counting or cancelling.
fn pointInFilledPath(px: f32, py: f32, pts: []const FillPoint, contour_lens: []const u32, even_odd: bool) bool {
    var winding: i32 = 0;
    var parity: u1 = 0;
    var base: usize = 0;
    for (contour_lens) |clen| {
        const n: usize = @intCast(clen);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const a = pts[base + i];
            const b = pts[base + ((i + 1) % n)];
            if ((a.y <= py) != (b.y <= py)) {
                const t_cross = (py - a.y) / (b.y - a.y);
                const xint = a.x + t_cross * (b.x - a.x);
                if (xint > px) {
                    if (even_odd) {
                        parity ^= 1;
                    } else if (b.y > a.y) {
                        winding += 1;
                    } else {
                        winding -= 1;
                    }
                }
            }
        }
        base += n;
    }
    if (even_odd) return parity == 1;
    return winding != 0;
}

// ---- Paint sources (ADR 0016, Stage B1) ----
// A current-source register layered over the existing solid path. The
// source affects per-pixel color only; coverage, antialiasing, and blend
// are computed exactly as for a solid primitive (invariant B1-2). A
// single-color gradient therefore renders byte-identically to the solid
// fill of that color (invariant B1-3).

const GradStop = struct { offset: f32, r: f32, g: f32, b: f32, a: f32 };

const SourceKind = enum { none, linear, radial, pattern };

const PaintSource = struct {
    kind: SourceKind = .none,
    extend: u32 = 0, // 0 pad, 1 repeat, 2 reflect
    // linear axis (user space)
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,
    // radial (user space)
    cx: f32 = 0,
    cy: f32 = 0,
    radius: f32 = 1,
    stop_count: u32 = 0,
    stops: [256]GradStop = undefined,
    // pattern (ADR 0017). pinv maps user space to texel space (the inverse
    // of the pattern affine, precomputed at decode). ext_x and ext_y are the
    // per-axis extend modes. tile is the inline straight-RGBA8 surface,
    // row-major, top-left origin, tile_w * tile_h * 4 bytes, owned.
    pinv: Transform2D = .{},
    ext_x: u32 = 0,
    ext_y: u32 = 0,
    filter: u32 = 0,
    tile_w: u32 = 0,
    tile_h: u32 = 0,
    tile: ?[]u8 = null,
};

// Inverse of a 2D affine. applyT maps user->device as
//   x' = a*x + c*y + e ; y' = b*x + d*y + f
// so the device->user inverse is returned in the same field layout.
fn invertT(t: Transform2D) ?Transform2D {
    const det = t.a * t.d - t.c * t.b;
    if (det == 0.0) return null;
    const inv = 1.0 / det;
    return Transform2D{
        .a = t.d * inv,
        .b = -t.b * inv,
        .c = -t.c * inv,
        .d = t.a * inv,
        .e = (t.c * t.f - t.d * t.e) * inv,
        .f = (t.b * t.e - t.a * t.f) * inv,
    };
}

fn applyExtend(s: f32, mode: u32) f32 {
    return switch (mode) {
        1 => s - @floor(s), // repeat
        2 => blk: { // reflect
            const f = s - 2.0 * @floor(s / 2.0);
            break :blk if (f <= 1.0) f else 2.0 - f;
        },
        else => blk: { // pad
            if (s < 0.0) break :blk 0.0;
            if (s > 1.0) break :blk 1.0;
            break :blk s;
        },
    };
}

// Resolve the gradient color at normalized parameter t in [0,1], interpolating
// adjacent stops linearly in straight RGBA. Stops are monotonic by validation.
fn resolveStops(src: *const PaintSource, t: f32) [4]u8 {
    const n = src.stop_count;
    const first = src.stops[0];
    if (t <= first.offset) return .{ clampU8(first.r), clampU8(first.g), clampU8(first.b), clampU8(first.a) };
    const last = src.stops[n - 1];
    if (t >= last.offset) return .{ clampU8(last.r), clampU8(last.g), clampU8(last.b), clampU8(last.a) };
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        const s1 = src.stops[i];
        if (t <= s1.offset) {
            const s0 = src.stops[i - 1];
            const span = s1.offset - s0.offset;
            const u: f32 = if (span > 0.0) (t - s0.offset) / span else 0.0;
            return .{
                clampU8(s0.r + u * (s1.r - s0.r)),
                clampU8(s0.g + u * (s1.g - s0.g)),
                clampU8(s0.b + u * (s1.b - s0.b)),
                clampU8(s0.a + u * (s1.a - s0.a)),
            };
        }
    }
    return .{ clampU8(last.r), clampU8(last.g), clampU8(last.b), clampU8(last.a) };
}

// Sample the source at a device-space pixel center. tinv maps device->user.
// Fold a pattern-space coordinate to a texel index in [0, n) per the axis
// extend mode (ADR 0017 section 5). Takes the f32 coordinate and floors it
// internally, guarding the float-to-integer conversion against non-finite or
// out-of-range values so an extreme pattern affine cannot panic the convert.
fn foldTexelIndex(coord: f32, n: u32, mode: u32) u32 {
    const nn: i64 = @intCast(n);
    const fl = @floor(coord);
    var k: i64 = 0;
    if (!std.math.isFinite(fl)) {
        k = 0;
    } else if (fl <= -9.0e18) {
        k = -9000000000000000000;
    } else if (fl >= 9.0e18) {
        k = 9000000000000000000;
    } else {
        k = @intFromFloat(fl);
    }
    switch (mode) {
        1 => { // repeat: positive modulo, @mod with nn > 0 yields [0, nn)
            return @intCast(@mod(k, nn));
        },
        2 => { // reflect: period 2N, mirror, edge texel duplicated at folds
            const p2 = nn * 2;
            const m = @mod(k, p2);
            if (m < nn) return @intCast(m);
            return @intCast(p2 - 1 - m);
        },
        else => { // pad: clamp to [0, N-1]
            if (k < 0) return 0;
            if (k >= nn) return @intCast(nn - 1);
            return @intCast(k);
        },
    }
}

// Free a pattern source's owned tile, if any. Called before any source-setting
// op replaces the register, and once after the decode loop.
fn releaseSourceTile(src: *PaintSource, allocator: std.mem.Allocator) void {
    if (src.tile) |t| {
        allocator.free(t);
        src.tile = null;
    }
}

fn sampleSourceColor(src: *const PaintSource, tinv: Transform2D, px: f32, py: f32) [4]u8 {
    const u = applyT(tinv, px, py);
    if (src.kind == .pattern) {
        // user space -> texel space via the pattern inverse, then nearest
        // (floor-based) texel selection with per-axis extend.
        const p = applyT(src.pinv, u.x, u.y);
        const i = foldTexelIndex(p.x, src.tile_w, src.ext_x);
        const j = foldTexelIndex(p.y, src.tile_h, src.ext_y);
        const idx: usize = (@as(usize, j) * @as(usize, src.tile_w) + @as(usize, i)) * 4;
        const t = src.tile.?;
        return .{ t[idx], t[idx + 1], t[idx + 2], t[idx + 3] };
    }
    var s: f32 = 0;
    if (src.kind == .linear) {
        const dx = src.x1 - src.x0;
        const dy = src.y1 - src.y0;
        const denom = dx * dx + dy * dy; // > 0 by validation
        s = ((u.x - src.x0) * dx + (u.y - src.y0) * dy) / denom;
    } else {
        const ddx = u.x - src.cx;
        const ddy = u.y - src.cy;
        s = @sqrt(ddx * ddx + ddy * ddy) / src.radius;
    }
    return resolveStops(src, applyExtend(s, src.extend));
}

// Sourced rect fills mirror the solid fbFillRect* partition exactly (same
// pixel set, same coverage), substituting a per-pixel sampled color for the
// constant color. Since fbBlendPixel at full coverage is byte-identical to
// simd.fillSpan, a single-color gradient reproduces the solid fill exactly.

fn fbFillRectAASourced(rgba: []u8, w: usize, h: usize, x: f32, y: f32, rw: f32, rh: f32, src: *const PaintSource, tinv: Transform2D, mode: u32) void {
    if (rw <= 0.0 or rh <= 0.0) return;
    const x1 = x;
    const y1 = y;
    const x2 = x + rw;
    const y2 = y + rh;

    const ix0: isize = @intFromFloat(@floor(x1));
    const iy0: isize = @intFromFloat(@floor(y1));
    const ix1: isize = @intFromFloat(@ceil(x2));
    const iy1: isize = @intFromFloat(@ceil(y2));

    const px0: usize = @intCast(@max(ix0, 0));
    const py0: usize = @intCast(@max(iy0, 0));
    const px1: usize = @intCast(@min(ix1, @as(isize, @intCast(w))));
    const py1: usize = @intCast(@min(iy1, @as(isize, @intCast(h))));
    if (px0 >= px1 or py0 >= py1) return;

    const interior_x0: usize = @intCast(@max(@as(isize, @intFromFloat(@ceil(x1))), @as(isize, @intCast(px0))));
    const interior_y0: usize = @intCast(@max(@as(isize, @intFromFloat(@ceil(y1))), @as(isize, @intCast(py0))));
    const interior_x1: usize = @intCast(@min(@as(isize, @intFromFloat(@floor(x2))), @as(isize, @intCast(px1))));
    const interior_y1: usize = @intCast(@min(@as(isize, @intFromFloat(@floor(y2))), @as(isize, @intCast(py1))));

    if (interior_x0 < interior_x1 and interior_y0 < interior_y1) {
        var iy: usize = interior_y0;
        while (iy < interior_y1) : (iy += 1) {
            var ix: usize = interior_x0;
            while (ix < interior_x1) : (ix += 1) {
                const idx: usize = (iy * w + ix) * 4;
                const col = sampleSourceColor(src, tinv, @as(f32, @floatFromInt(ix)) + 0.5, @as(f32, @floatFromInt(iy)) + 0.5);
                fbBlendPixel(rgba, idx, col[0], col[1], col[2], col[3], mode);
            }
        }
    }

    var iy: usize = py0;
    while (iy < py1) : (iy += 1) {
        var ix: usize = px0;
        while (ix < px1) : (ix += 1) {
            if (ix >= interior_x0 and ix < interior_x1 and iy >= interior_y0 and iy < interior_y1) continue;
            const px: f32 = @floatFromInt(ix);
            const py: f32 = @floatFromInt(iy);
            const coverage = simd.computeRectCoverageAA(px, py, x1, y1, x2, y2);
            if (coverage > 0.0) {
                const idx: usize = (iy * w + ix) * 4;
                const col = sampleSourceColor(src, tinv, px + 0.5, py + 0.5);
                if (coverage >= 1.0) {
                    fbBlendPixel(rgba, idx, col[0], col[1], col[2], col[3], mode);
                } else {
                    fbBlendPixelAA(rgba, idx, col[0], col[1], col[2], col[3], mode, coverage);
                }
            }
        }
    }
}

fn fbFillRectSourced(rgba: []u8, w: usize, h: usize, x: f32, y: f32, rw: f32, rh: f32, src: *const PaintSource, tinv: Transform2D, mode: u32) void {
    const ix0: isize = @intFromFloat(@floor(x));
    const iy0: isize = @intFromFloat(@floor(y));
    const ix1: isize = @intFromFloat(@ceil(x + rw));
    const iy1: isize = @intFromFloat(@ceil(y + rh));

    const x0: usize = @intCast(@max(ix0, 0));
    const y0: usize = @intCast(@max(iy0, 0));
    const x1u: usize = @intCast(@min(ix1, @as(isize, @intCast(w))));
    const y1u: usize = @intCast(@min(iy1, @as(isize, @intCast(h))));
    if (x0 >= x1u or y0 >= y1u) return;

    var iy: usize = y0;
    while (iy < y1u) : (iy += 1) {
        var ix: usize = x0;
        while (ix < x1u) : (ix += 1) {
            const idx: usize = (iy * w + ix) * 4;
            const col = sampleSourceColor(src, tinv, @as(f32, @floatFromInt(ix)) + 0.5, @as(f32, @floatFromInt(iy)) + 0.5);
            fbBlendPixel(rgba, idx, col[0], col[1], col[2], col[3], mode);
        }
    }
}

fn fbFillRectClippedAASourced(rgba: []u8, w: usize, h: usize, rx: f32, ry: f32, rw: f32, rh: f32, src: *const PaintSource, tinv: Transform2D, mode: u32, clip: Clip) void {
    switch (clip.kind) {
        .none => fbFillRectAASourced(rgba, w, h, rx, ry, rw, rh, src, tinv, mode),
        .rects => {
            for (clip.rects) |c| {
                const ix = @max(rx, c.x);
                const iy = @max(ry, c.y);
                const ix2 = @min(rx + rw, c.x + c.w);
                const iy2 = @min(ry + rh, c.y + c.h);
                const iw = ix2 - ix;
                const ih = iy2 - iy;
                if (iw <= 0.0 or ih <= 0.0) continue;
                fbFillRectAASourced(rgba, w, h, ix, iy, iw, ih, src, tinv, mode);
            }
        },
        .path => fbFillRectClipPath(rgba, w, h, rx, ry, rw, rh, 0, 0, 0, 0, mode, true, clip, src, tinv),
    }
}

fn fbFillRectClippedSourced(rgba: []u8, w: usize, h: usize, rx: f32, ry: f32, rw: f32, rh: f32, src: *const PaintSource, tinv: Transform2D, mode: u32, clip: Clip) void {
    switch (clip.kind) {
        .none => fbFillRectSourced(rgba, w, h, rx, ry, rw, rh, src, tinv, mode),
        .rects => {
            for (clip.rects) |c| {
                const ix = @max(rx, c.x);
                const iy = @max(ry, c.y);
                const ix2 = @min(rx + rw, c.x + c.w);
                const iy2 = @min(ry + rh, c.y + c.h);
                const iw = ix2 - ix;
                const ih = iy2 - iy;
                if (iw <= 0.0 or ih <= 0.0) continue;
                fbFillRectSourced(rgba, w, h, ix, iy, iw, ih, src, tinv, mode);
            }
        },
        .path => fbFillRectClipPath(rgba, w, h, rx, ry, rw, rh, 0, 0, 0, 0, mode, false, clip, src, tinv),
    }
}

// Rasterize a filled path. Points are already transformed to device
// space. Boundary coverage uses the same 4x4 (16-sample) lattice and
// the same fbBlendPixelAA path as stroke rasterization, so a fill and a
// coincident stroke antialias identically; coverage is an integer
// sample count in [0,16] (ADR 0015 section 5). The non-AA path samples
// the pixel center.
fn emitFilledPath(
    rgba: []u8,
    w: usize,
    h: usize,
    clip: Clip,
    blend_mode: u32,
    pts: []const FillPoint,
    contour_lens: []const u32,
    even_odd: bool,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
    aa: bool,
    source: ?*const PaintSource,
    tinv: Transform2D,
) void {
    if (pts.len == 0) return;

    var minx = pts[0].x;
    var miny = pts[0].y;
    var maxx = pts[0].x;
    var maxy = pts[0].y;
    for (pts) |p| {
        if (p.x < minx) minx = p.x;
        if (p.y < miny) miny = p.y;
        if (p.x > maxx) maxx = p.x;
        if (p.y > maxy) maxy = p.y;
    }

    if (minx < 0.0) minx = 0.0;
    if (miny < 0.0) miny = 0.0;
    if (maxx > @as(f32, @floatFromInt(w))) maxx = @as(f32, @floatFromInt(w));
    if (maxy > @as(f32, @floatFromInt(h))) maxy = @as(f32, @floatFromInt(h));
    if (maxx <= minx or maxy <= miny) return;

    const ix0: isize = @intFromFloat(@floor(minx));
    const iy0: isize = @intFromFloat(@floor(miny));
    const ix1: isize = @intFromFloat(@ceil(maxx));
    const iy1: isize = @intFromFloat(@ceil(maxy));

    const r8 = clampU8(cr);
    const g8 = clampU8(cg);
    const b8 = clampU8(cb);
    const a8 = clampU8(ca);

    var iy: isize = iy0;
    while (iy < iy1) : (iy += 1) {
        if (iy < 0 or iy >= @as(isize, @intCast(h))) continue;
        var ix: isize = ix0;
        while (ix < ix1) : (ix += 1) {
            if (ix < 0 or ix >= @as(isize, @intCast(w))) continue;
            const base_px: f32 = @floatFromInt(ix);
            const base_py: f32 = @floatFromInt(iy);
            const idx: usize = (@as(usize, @intCast(iy)) * w + @as(usize, @intCast(ix))) * 4;

            if (aa) {
                var samples_inside: u32 = 0;
                for (AA_SAMPLE_OFFSETS) |offset| {
                    const spx = base_px + offset[0];
                    const spy = base_py + offset[1];
                    if (!clipContains(clip, spx, spy)) continue;
                    if (pointInFilledPath(spx, spy, pts, contour_lens, even_odd)) samples_inside += 1;
                }
                if (samples_inside > 0) {
                    const coverage: f32 = @as(f32, @floatFromInt(samples_inside)) / @as(f32, @floatFromInt(AA_SAMPLES));
                    if (source) |src| {
                        const col = sampleSourceColor(src, tinv, base_px + 0.5, base_py + 0.5);
                        fbBlendPixelAA(rgba, idx, col[0], col[1], col[2], col[3], blend_mode, coverage);
                    } else {
                        fbBlendPixelAA(rgba, idx, r8, g8, b8, a8, blend_mode, coverage);
                    }
                }
            } else {
                const spx = base_px + 0.5;
                const spy = base_py + 0.5;
                if (!clipContains(clip, spx, spy)) continue;
                if (pointInFilledPath(spx, spy, pts, contour_lens, even_odd)) {
                    if (source) |src| {
                        const col = sampleSourceColor(src, tinv, spx, spy);
                        fbBlendPixel(rgba, idx, col[0], col[1], col[2], col[3], blend_mode);
                    } else {
                        fbBlendPixel(rgba, idx, r8, g8, b8, a8, blend_mode);
                    }
                }
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var clip_path_pts = std.ArrayList(FillPoint){};
    defer clip_path_pts.deinit(alloc);
    var clip_path_lens = std.ArrayList(u32){};
    defer clip_path_lens.deinit(alloc);
    var clip: Clip = .{};
    var t = Transform2D{};
    var blend_mode: u32 = 0;
    var aa_enabled: bool = false;
    var current_source = PaintSource{};
    defer releaseSourceTile(&current_source, alloc);
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
            clip,
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
        emitRoundCapAA(rgba, w, h, pending_t, clip, blend_mode, pending_end_x, pending_end_y, pending_sw, pending_cr, pending_cg, pending_cb, pending_ca);
    } else {
        emitRoundCap(rgba, w, h, pending_t, clip, blend_mode, pending_end_x, pending_end_y, pending_sw, pending_cr, pending_cg, pending_cb, pending_ca);
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

            if (cmd.opcode == sdcs.Op.RESET) {
                releaseSourceTile(&current_source, alloc);
                current_source.kind = .none;
            } else if (cmd.opcode == sdcs.Op.SET_BLEND) {
                blend_mode = try readU32LE(r);
            } else if (cmd.opcode == sdcs.Op.SET_SOURCE_NONE) {
                releaseSourceTile(&current_source, alloc);
                current_source.kind = .none;
            } else if (cmd.opcode == sdcs.Op.SET_SOURCE_LINEAR_GRADIENT) {
                releaseSourceTile(&current_source, alloc);
                current_source.kind = .linear;
                current_source.x0 = try readF32LE(r);
                current_source.y0 = try readF32LE(r);
                current_source.x1 = try readF32LE(r);
                current_source.y1 = try readF32LE(r);
                current_source.extend = try readU32LE(r);
                const sc = try readU32LE(r);
                if (sc < 2 or sc > 256) return error.Protocol;
                current_source.stop_count = sc;
                var si: u32 = 0;
                while (si < sc) : (si += 1) {
                    current_source.stops[si] = .{
                        .offset = try readF32LE(r),
                        .r = try readF32LE(r),
                        .g = try readF32LE(r),
                        .b = try readF32LE(r),
                        .a = try readF32LE(r),
                    };
                }
            } else if (cmd.opcode == sdcs.Op.SET_SOURCE_RADIAL_GRADIENT) {
                releaseSourceTile(&current_source, alloc);
                current_source.kind = .radial;
                current_source.cx = try readF32LE(r);
                current_source.cy = try readF32LE(r);
                current_source.radius = try readF32LE(r);
                current_source.extend = try readU32LE(r);
                const sc = try readU32LE(r);
                if (sc < 2 or sc > 256) return error.Protocol;
                current_source.stop_count = sc;
                var si: u32 = 0;
                while (si < sc) : (si += 1) {
                    current_source.stops[si] = .{
                        .offset = try readF32LE(r),
                        .r = try readF32LE(r),
                        .g = try readF32LE(r),
                        .b = try readF32LE(r),
                        .a = try readF32LE(r),
                    };
                }
            } else if (cmd.opcode == sdcs.Op.SET_SOURCE_PATTERN) {
                releaseSourceTile(&current_source, alloc);
                if (pb < 44) return error.Protocol;
                const aff_a = try readF32LE(r);
                const aff_b = try readF32LE(r);
                const aff_c = try readF32LE(r);
                const aff_d = try readF32LE(r);
                const aff_e = try readF32LE(r);
                const aff_f = try readF32LE(r);
                const ext_x = try readU32LE(r);
                const ext_y = try readU32LE(r);
                const filt = try readU32LE(r);
                const tw = try readU32LE(r);
                const th = try readU32LE(r);
                // Defensive content checks; the encoder already enforces these.
                if (tw < 1 or tw > 4096 or th < 1 or th > 4096) return error.Protocol;
                if (ext_x > 2 or ext_y > 2) return error.Protocol;
                if (filt != 0) return error.Protocol;
                const tile_bytes: usize = @as(usize, tw) * @as(usize, th) * 4;
                if (pb != 44 + tile_bytes) return error.Protocol;
                // The affine must be invertible (encoder rejects det == 0).
                const pat_affine = Transform2D{ .a = aff_a, .b = aff_b, .c = aff_c, .d = aff_d, .e = aff_e, .f = aff_f };
                const pinv = invertT(pat_affine) orelse return error.Protocol;
                const tile_buf = try alloc.alloc(u8, tile_bytes);
                errdefer alloc.free(tile_buf);
                try readExact(r, tile_buf);
                current_source.kind = .pattern;
                current_source.pinv = pinv;
                current_source.ext_x = ext_x;
                current_source.ext_y = ext_y;
                current_source.filter = filt;
                current_source.tile_w = tw;
                current_source.tile_h = th;
                current_source.tile = tile_buf;
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
                // payload: u32 count + rects. Replaces any current clip
                // (rectangles or path) with this rectangle union (ADR 0018).
                const count = try readU32LE(r);
                clip_rects.clearRetainingCapacity();
                clip_path_pts.clearRetainingCapacity();
                clip_path_lens.clearRetainingCapacity();
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const cx = try readF32LE(r);
                    const cy = try readF32LE(r);
                    const cw = try readF32LE(r);
                    const ch2 = try readF32LE(r);
                    try clip_rects.append(alloc, .{ .x = cx, .y = cy, .w = cw, .h = ch2 });
                }
                clip = if (count != 0)
                    .{ .kind = .rects, .rects = clip_rects.items }
                else
                    .{};

            } else if (cmd.opcode == sdcs.Op.CLEAR_CLIP) {
                clip_rects.clearRetainingCapacity();
                clip_path_pts.clearRetainingCapacity();
                clip_path_lens.clearRetainingCapacity();
                clip = .{};
            } else if (cmd.opcode == sdcs.Op.SET_CLIP_PATH) {
                // Payload (ADR 0018 section 4): fill_rule (u32),
                // contour_count (u32), contour_lengths (cc x u32), points
                // (sum x 2 x f32), user space. Points are baked to device
                // space here with the transform in effect now, and the
                // result replaces any current clip. Field-level checks
                // (mirroring FILL_PATH) run as the body is read; lengths
                // accumulate in usize to avoid overflow.
                if (pb < 8) return error.Protocol;
                const fill_rule = try readU32LE(r);
                const contour_count = try readU32LE(r);
                if (fill_rule > 1) return error.Protocol;
                if (contour_count == 0 or contour_count > 65535) return error.Protocol;

                clip_rects.clearRetainingCapacity();
                clip_path_pts.clearRetainingCapacity();
                clip_path_lens.clearRetainingCapacity();

                var total_pts: usize = 0;
                var ci: u32 = 0;
                while (ci < contour_count) : (ci += 1) {
                    const clen = try readU32LE(r);
                    if (clen < 3) return error.Protocol;
                    total_pts += @as(usize, clen);
                    if (total_pts > 65535) return error.Protocol;
                    try clip_path_lens.append(alloc, clen);
                }

                const expected: usize = 8 + @as(usize, contour_count) * 4 + total_pts * 8;
                if (@as(usize, pb) != expected) return error.Protocol;

                var pi: usize = 0;
                while (pi < total_pts) : (pi += 1) {
                    const ux = try readF32LE(r);
                    const uy = try readF32LE(r);
                    const dp = applyT(t, ux, uy);
                    try clip_path_pts.append(alloc, .{ .x = dp.x, .y = dp.y });
                }

                clip = .{
                    .kind = .path,
                    .path_pts = clip_path_pts.items,
                    .path_lens = clip_path_lens.items,
                    .path_even_odd = (fill_rule == 1),
                };
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
                            clip,
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
        emitRoundCapAA(rgba, w, h, pending_t, clip, blend_mode, pending_end_x, pending_end_y, pending_sw, pending_cr, pending_cg, pending_cb, pending_ca);
    } else {
        emitRoundCap(rgba, w, h, pending_t, clip, blend_mode, pending_end_x, pending_end_y, pending_sw, pending_cr, pending_cg, pending_cb, pending_ca);
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
                            clip,
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
                                emitRoundCapAA(rgba, w, h, t, clip, blend_mode, jx, jy, sw, cr, cg, cb, ca);
                            } else {
                                emitRoundCap(rgba, w, h, t, clip, blend_mode, jx, jy, sw, cr, cg, cb, ca);
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
                                    const join_clips = clip;
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
    const clips = clip;

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
            emitStrokedLineArbitraryAA(rgba, w, h, t, clip, blend_mode, x1, y1, x2, y2, sw, cr, cg, cb, ca);
        } else {
            emitStrokedLineArbitrary(rgba, w, h, t, clip, blend_mode, x1, y1, x2, y2, sw, cr, cg, cb, ca);
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

    const clips = clip;
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
                if (current_source.kind != .none) {
                    const tinv = invertT(t) orelse Transform2D{};
                    if (aa_enabled) {
                        fbFillRectClippedAASourced(rgba, w, h, tb.x, tb.y, tb.w, tb.h, &current_source, tinv, blend_mode, clip);
                    } else {
                        fbFillRectClippedSourced(rgba, w, h, tb.x, tb.y, tb.w, tb.h, &current_source, tinv, blend_mode, clip);
                    }
                } else if (aa_enabled) {
                    fbFillRectClippedAA(rgba, w, h, tb.x, tb.y, tb.w, tb.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clip);
                } else {
                    fbFillRectClipped(rgba, w, h, tb.x, tb.y, tb.w, tb.h, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), blend_mode, clip);
                }

            } else if (cmd.opcode == sdcs.Op.FILL_PATH) {
                // Payload (ADR 0015): r,g,b,a (4 f32), fill_rule (u32),
                // contour_count (u32), contour_lengths (cc x u32),
                // points (sum x 2 x f32).
                if (pb < 24) return error.Protocol;
                const fcr = try readF32LE(r);
                const fcg = try readF32LE(r);
                const fcb = try readF32LE(r);
                const fca = try readF32LE(r);
                const fill_rule = try readU32LE(r);
                const contour_count = try readU32LE(r);
                if (fill_rule > 1) return error.Protocol;
                if (contour_count == 0) return error.Protocol;

                const lens = try alloc.alloc(u32, contour_count);
                defer alloc.free(lens);
                var total_pts: usize = 0;
                for (lens) |*l| {
                    l.* = try readU32LE(r);
                    if (l.* < 3) return error.Protocol;
                    total_pts += @as(usize, l.*);
                }

                const expected_size: usize = 24 + @as(usize, contour_count) * 4 + total_pts * 8;
                if (pb != expected_size) return error.Protocol;

                const fpts = try alloc.alloc(FillPoint, total_pts);
                defer alloc.free(fpts);
                for (fpts) |*p| {
                    const ux = try readF32LE(r);
                    const uy = try readF32LE(r);
                    const tp = applyT(t, ux, uy);
                    p.* = .{ .x = tp.x, .y = tp.y };
                }

                const fp_src: ?*const PaintSource = if (current_source.kind != .none) &current_source else null;
                const fp_tinv = if (fp_src != null) (invertT(t) orelse Transform2D{}) else Transform2D{};
                emitFilledPath(rgba, w, h, clip, blend_mode, fpts, lens, fill_rule == 1, fcr, fcg, fcb, fca, aa_enabled, fp_src, fp_tinv);

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
                        if (!clipContains(clip, tp.x, tp.y)) continue;

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
                    emitStrokedQuadBezierAA(rgba, w, h, t, clip, blend_mode, bx0, by0, bcx, bcy, bx1, by1, bsw, bcr, bcg, bcb, bca);
                } else {
                    emitStrokedQuadBezier(rgba, w, h, t, clip, blend_mode, bx0, by0, bcx, bcy, bx1, by1, bsw, bcr, bcg, bcb, bca);
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
                    emitStrokedCubicBezierAA(rgba, w, h, t, clip, blend_mode, bx0, by0, bcx1, bcy1, bcx2, bcy2, bx1, by1, bsw, bcr, bcg, bcb, bca);
                } else {
                    emitStrokedCubicBezier(rgba, w, h, t, clip, blend_mode, bx0, by0, bcx1, bcy1, bcx2, bcy2, bx1, by1, bsw, bcr, bcg, bcb, bca);
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
                    const path_clips = clip;
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
                                        emitRoundCapAA(rgba, w, h, t, clip, blend_mode, jx, jy, psw, pcr, pcg, pcb, pca);
                                    } else {
                                        emitRoundCap(rgba, w, h, t, clip, blend_mode, jx, jy, psw, pcr, pcg, pcb, pca);
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
                            emitStrokedLineArbitraryAA(rgba, w, h, t, clip, blend_mode, sx1, sy1, sx2, sy2, psw, pcr, pcg, pcb, pca);
                        } else {
                            emitStrokedLineArbitrary(rgba, w, h, t, clip, blend_mode, sx1, sy1, sx2, sy2, psw, pcr, pcg, pcb, pca);
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
                            {
                                const dx_f: f32 = @floatFromInt(dx);
                                const dy_f: f32 = @floatFromInt(dy);
                                if (!clipContains(clip, dx_f, dy_f)) continue;
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
            clip,
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
        emitRoundCapAA(rgba, w, h, pending_t, clip, blend_mode, pending_end_x, pending_end_y, pending_sw, pending_cr, pending_cg, pending_cb, pending_ca);
    } else {
        emitRoundCap(rgba, w, h, pending_t, clip, blend_mode, pending_end_x, pending_end_y, pending_sw, pending_cr, pending_cg, pending_cb, pending_ca);
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

test "pointInFilledPath convex square nonzero" {
    const sq = [_]FillPoint{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    const lens = [_]u32{4};
    try std.testing.expect(pointInFilledPath(5, 5, sq[0..], lens[0..], false));
    try std.testing.expect(!pointInFilledPath(15, 5, sq[0..], lens[0..], false));
    try std.testing.expect(!pointInFilledPath(-1, 5, sq[0..], lens[0..], false));
}

test "pointInFilledPath ring hole, opposite inner winding" {
    // Outer CCW, inner CW (opposite) -> hole under both rules.
    const pts = [_]FillPoint{
        .{ .x = 0, .y = 0 },  .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 },
        .{ .x = 3, .y = 3 },  .{ .x = 3, .y = 7 },  .{ .x = 7, .y = 7 },   .{ .x = 7, .y = 3 },
    };
    const lens = [_]u32{ 4, 4 };
    try std.testing.expect(!pointInFilledPath(5, 5, pts[0..], lens[0..], true)); // even-odd hole
    try std.testing.expect(pointInFilledPath(1, 5, pts[0..], lens[0..], true)); // between contours
    try std.testing.expect(!pointInFilledPath(5, 5, pts[0..], lens[0..], false)); // nonzero hole
    try std.testing.expect(pointInFilledPath(1, 5, pts[0..], lens[0..], false));
}

test "pointInFilledPath winding rule diverges on nested same-direction contours" {
    // Both CCW: nonzero keeps the center filled, even-odd carves a hole.
    const pts = [_]FillPoint{
        .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 },
        .{ .x = 3, .y = 3 }, .{ .x = 7, .y = 3 },  .{ .x = 7, .y = 7 },   .{ .x = 3, .y = 7 },
    };
    const lens = [_]u32{ 4, 4 };
    try std.testing.expect(pointInFilledPath(5, 5, pts[0..], lens[0..], false)); // nonzero: filled
    try std.testing.expect(!pointInFilledPath(5, 5, pts[0..], lens[0..], true)); // even-odd: hole
}

test "emitFilledPath interior opaque, exterior untouched" {
    const W: usize = 8;
    const H: usize = 8;
    var fb = [_]u8{0} ** (8 * 8 * 4);
    const sq = [_]FillPoint{ .{ .x = 2, .y = 2 }, .{ .x = 6, .y = 2 }, .{ .x = 6, .y = 6 }, .{ .x = 2, .y = 6 } };
    const lens = [_]u32{4};
    emitFilledPath(fb[0..], W, H, Clip{}, 0, sq[0..], lens[0..], false, 1.0, 0.0, 0.0, 1.0, true, null, Transform2D{});

    const i_in = (4 * W + 4) * 4;
    try std.testing.expectEqual(@as(u8, 255), fb[i_in + 0]); // R
    try std.testing.expectEqual(@as(u8, 255), fb[i_in + 3]); // A

    const i_out = (0 * W + 0) * 4;
    try std.testing.expectEqual(@as(u8, 0), fb[i_out + 3]); // untouched
}

test "emitFilledPath antialiases a fractional edge" {
    const W: usize = 8;
    const H: usize = 8;
    var fb = [_]u8{0} ** (8 * 8 * 4);
    const sq = [_]FillPoint{ .{ .x = 2.5, .y = 2.0 }, .{ .x = 5.5, .y = 2.0 }, .{ .x = 5.5, .y = 6.0 }, .{ .x = 2.5, .y = 6.0 } };
    const lens = [_]u32{4};
    emitFilledPath(fb[0..], W, H, Clip{}, 0, sq[0..], lens[0..], false, 1.0, 1.0, 1.0, 1.0, true, null, Transform2D{});

    const i_edge = (4 * W + 2) * 4; // column [2,3] straddles left edge x=2.5
    try std.testing.expect(fb[i_edge + 3] > 0 and fb[i_edge + 3] < 255);

    const i_full = (4 * W + 3) * 4; // column [3,4] fully inside
    try std.testing.expectEqual(@as(u8, 255), fb[i_full + 3]);
}

test "applyExtend pad repeat reflect" {
    const testing = std.testing;
    // pad (mode 0)
    try testing.expectApproxEqAbs(@as(f32, 1.0), applyExtend(1.5, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), applyExtend(-0.5, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), applyExtend(0.5, 0), 1e-6);
    // repeat (mode 1): integer maps to 0
    try testing.expectApproxEqAbs(@as(f32, 0.5), applyExtend(1.5, 1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), applyExtend(2.0, 1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), applyExtend(3.25, 1), 1e-6);
    // reflect (mode 2): triangle wave
    try testing.expectApproxEqAbs(@as(f32, 0.5), applyExtend(1.5, 2), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), applyExtend(1.0, 2), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), applyExtend(2.0, 2), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.7), applyExtend(2.7, 2), 1e-6);
}

test "sampleSourceColor linear endpoints and midpoint" {
    const testing = std.testing;
    var src = PaintSource{};
    src.kind = .linear;
    src.x0 = 0;
    src.y0 = 0;
    src.x1 = 100;
    src.y1 = 0;
    src.extend = 0;
    src.stop_count = 2;
    src.stops[0] = .{ .offset = 0, .r = 1, .g = 0, .b = 0, .a = 1 };
    src.stops[1] = .{ .offset = 1, .r = 0, .g = 0, .b = 1, .a = 1 };
    const id = Transform2D{};
    const c0 = sampleSourceColor(&src, id, 0.5, 0.5);
    try testing.expect(c0[0] > 250 and c0[2] < 5);
    const c1 = sampleSourceColor(&src, id, 99.5, 0.5);
    try testing.expect(c1[2] > 250 and c1[0] < 5);
    const cm = sampleSourceColor(&src, id, 50.5, 0.5);
    try testing.expect(cm[0] > 118 and cm[0] < 138);
    try testing.expect(cm[2] > 118 and cm[2] < 138);
}

test "sampleSourceColor radial center to edge" {
    const testing = std.testing;
    var src = PaintSource{};
    src.kind = .radial;
    src.cx = 50;
    src.cy = 50;
    src.radius = 50;
    src.extend = 0;
    src.stop_count = 2;
    src.stops[0] = .{ .offset = 0, .r = 1, .g = 1, .b = 1, .a = 1 };
    src.stops[1] = .{ .offset = 1, .r = 0, .g = 0, .b = 0, .a = 1 };
    const id = Transform2D{};
    const center = sampleSourceColor(&src, id, 50.5, 50.5);
    try testing.expect(center[0] > 245);
    const edge = sampleSourceColor(&src, id, 100.5, 50.5);
    try testing.expect(edge[0] < 10);
}

test "single-color gradient path equals solid path (B1-3)" {
    const testing = std.testing;
    const W = 16;
    const H = 16;
    var fb_solid: [W * H * 4]u8 = undefined;
    var fb_grad: [W * H * 4]u8 = undefined;
    for (0..W * H) |i| {
        fb_solid[i * 4 + 0] = 16;
        fb_solid[i * 4 + 1] = 32;
        fb_solid[i * 4 + 2] = 48;
        fb_solid[i * 4 + 3] = 255;
        fb_grad[i * 4 + 0] = 16;
        fb_grad[i * 4 + 1] = 32;
        fb_grad[i * 4 + 2] = 48;
        fb_grad[i * 4 + 3] = 255;
    }
    const sq = [_]FillPoint{
        .{ .x = 2.3, .y = 2.7 },
        .{ .x = 12.6, .y = 2.7 },
        .{ .x = 12.6, .y = 12.4 },
        .{ .x = 2.3, .y = 12.4 },
    };
    const lens = [_]u32{4};
    emitFilledPath(fb_solid[0..], W, H, Clip{}, 0, sq[0..], lens[0..], false, 0.25, 0.5, 0.75, 1.0, true, null, Transform2D{});
    var src = PaintSource{};
    src.kind = .linear;
    src.x0 = 0;
    src.y0 = 0;
    src.x1 = 10;
    src.y1 = 0;
    src.extend = 0;
    src.stop_count = 2;
    src.stops[0] = .{ .offset = 0, .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 };
    src.stops[1] = .{ .offset = 1, .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 };
    emitFilledPath(fb_grad[0..], W, H, Clip{}, 0, sq[0..], lens[0..], false, 0, 0, 0, 1, true, &src, Transform2D{});
    try testing.expectEqualSlices(u8, fb_solid[0..], fb_grad[0..]);
}

test "single-color gradient rect equals solid rect (B1-3, FILL_RECT)" {
    const testing = std.testing;
    const W = 16;
    const H = 16;
    var fb_solid: [W * H * 4]u8 = undefined;
    var fb_grad: [W * H * 4]u8 = undefined;
    for (0..W * H) |i| {
        fb_solid[i * 4 + 0] = 16;
        fb_solid[i * 4 + 1] = 32;
        fb_solid[i * 4 + 2] = 48;
        fb_solid[i * 4 + 3] = 255;
        fb_grad[i * 4 + 0] = 16;
        fb_grad[i * 4 + 1] = 32;
        fb_grad[i * 4 + 2] = 48;
        fb_grad[i * 4 + 3] = 255;
    }
    fbFillRectClippedAA(fb_solid[0..], W, H, 2.3, 2.7, 10.4, 9.6, clampU8(0.25), clampU8(0.5), clampU8(0.75), clampU8(1.0), 0, Clip{});
    var src = PaintSource{};
    src.kind = .linear;
    src.x0 = 0;
    src.y0 = 0;
    src.x1 = 10;
    src.y1 = 0;
    src.extend = 0;
    src.stop_count = 2;
    src.stops[0] = .{ .offset = 0, .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 };
    src.stops[1] = .{ .offset = 1, .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 };
    fbFillRectClippedAASourced(fb_grad[0..], W, H, 2.3, 2.7, 10.4, 9.6, &src, Transform2D{}, 0, Clip{});
    try testing.expectEqualSlices(u8, fb_solid[0..], fb_grad[0..]);
}

test "foldTexelIndex pad repeat reflect at boundaries and negatives" {
    const testing = std.testing;
    // N = 3.
    // pad: clamp to [0, 2].
    try testing.expectEqual(@as(u32, 0), foldTexelIndex(-1.0, 3, 0));
    try testing.expectEqual(@as(u32, 0), foldTexelIndex(0.5, 3, 0));
    try testing.expectEqual(@as(u32, 2), foldTexelIndex(2.9, 3, 0));
    try testing.expectEqual(@as(u32, 2), foldTexelIndex(3.0, 3, 0));
    try testing.expectEqual(@as(u32, 2), foldTexelIndex(7.0, 3, 0));
    // repeat: positive modulo, integer maps in range.
    try testing.expectEqual(@as(u32, 2), foldTexelIndex(-1.0, 3, 1));
    try testing.expectEqual(@as(u32, 0), foldTexelIndex(-3.0, 3, 1));
    try testing.expectEqual(@as(u32, 0), foldTexelIndex(3.0, 3, 1));
    try testing.expectEqual(@as(u32, 1), foldTexelIndex(4.5, 3, 1));
    // reflect: mirror with edge duplication at folds.
    try testing.expectEqual(@as(u32, 0), foldTexelIndex(-1.0, 3, 2));
    try testing.expectEqual(@as(u32, 2), foldTexelIndex(2.0, 3, 2));
    try testing.expectEqual(@as(u32, 2), foldTexelIndex(3.0, 3, 2));
    try testing.expectEqual(@as(u32, 1), foldTexelIndex(4.0, 3, 2));
    try testing.expectEqual(@as(u32, 0), foldTexelIndex(5.0, 3, 2));
    try testing.expectEqual(@as(u32, 0), foldTexelIndex(6.0, 3, 2));
}

test "sampleSourceColor pattern nearest and extend" {
    const testing = std.testing;
    // 2x2 tile, row-major top-left: (0,0) red, (1,0) green, (0,1) blue, (1,1) white.
    var tile = [_]u8{
        255, 0,   0,   255, // (0,0)
        0,   255, 0,   255, // (1,0)
        0,   0,   255, 255, // (0,1)
        255, 255, 255, 255, // (1,1)
    };
    var src = PaintSource{};
    src.kind = .pattern;
    src.pinv = Transform2D{}; // identity: user space == texel space
    src.ext_x = 1; // repeat
    src.ext_y = 1;
    src.tile_w = 2;
    src.tile_h = 2;
    src.tile = tile[0..];
    const id = Transform2D{};
    // Pixel centers land inside each texel cell.
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, sampleSourceColor(&src, id, 0.5, 0.5));
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, sampleSourceColor(&src, id, 1.5, 0.5));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, sampleSourceColor(&src, id, 0.5, 1.5));
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, sampleSourceColor(&src, id, 1.5, 1.5));
    // Beyond the tile: repeat wraps (x=2.5 -> texel col 0).
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, sampleSourceColor(&src, id, 2.5, 0.5));
    // Pad clamps instead (x=2.5 -> texel col 1).
    src.ext_x = 0;
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, sampleSourceColor(&src, id, 2.5, 0.5));
}

test "single-color pattern equals solid path (B2-1)" {
    const testing = std.testing;
    const W = 16;
    const H = 16;
    var fb_solid: [W * H * 4]u8 = undefined;
    var fb_pat: [W * H * 4]u8 = undefined;
    for (0..W * H) |i| {
        fb_solid[i * 4 + 0] = 16;
        fb_solid[i * 4 + 1] = 32;
        fb_solid[i * 4 + 2] = 48;
        fb_solid[i * 4 + 3] = 255;
        fb_pat[i * 4 + 0] = 16;
        fb_pat[i * 4 + 1] = 32;
        fb_pat[i * 4 + 2] = 48;
        fb_pat[i * 4 + 3] = 255;
    }
    const sq = [_]FillPoint{
        .{ .x = 2.3, .y = 2.7 },
        .{ .x = 12.6, .y = 2.7 },
        .{ .x = 12.6, .y = 12.4 },
        .{ .x = 2.3, .y = 12.4 },
    };
    const lens = [_]u32{4};
    const cr: f32 = 0.25;
    const cg: f32 = 0.5;
    const cb: f32 = 0.75;
    const ca: f32 = 1.0;
    emitFilledPath(fb_solid[0..], W, H, Clip{}, 0, sq[0..], lens[0..], false, cr, cg, cb, ca, true, null, Transform2D{});
    // 1x1 uniform tile of the quantized solid color.
    var tile = [_]u8{ clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca) };
    var src = PaintSource{};
    src.kind = .pattern;
    src.pinv = Transform2D{};
    src.ext_x = 1;
    src.ext_y = 1;
    src.tile_w = 1;
    src.tile_h = 1;
    src.tile = tile[0..];
    emitFilledPath(fb_pat[0..], W, H, Clip{}, 0, sq[0..], lens[0..], false, 0, 0, 0, 1, true, &src, Transform2D{});
    try testing.expectEqualSlices(u8, fb_solid[0..], fb_pat[0..]);
}

test "single-color pattern equals solid rect (B2-1, FILL_RECT)" {
    const testing = std.testing;
    const W = 16;
    const H = 16;
    var fb_solid: [W * H * 4]u8 = undefined;
    var fb_pat: [W * H * 4]u8 = undefined;
    for (0..W * H) |i| {
        fb_solid[i * 4 + 0] = 16;
        fb_solid[i * 4 + 1] = 32;
        fb_solid[i * 4 + 2] = 48;
        fb_solid[i * 4 + 3] = 255;
        fb_pat[i * 4 + 0] = 16;
        fb_pat[i * 4 + 1] = 32;
        fb_pat[i * 4 + 2] = 48;
        fb_pat[i * 4 + 3] = 255;
    }
    const cr: f32 = 0.30;
    const cg: f32 = 0.55;
    const cb: f32 = 0.80;
    const ca: f32 = 1.0;
    fbFillRectClippedAA(fb_solid[0..], W, H, 2.3, 2.7, 10.4, 9.6, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), 0, Clip{});
    var tile = [_]u8{ clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca) };
    var src = PaintSource{};
    src.kind = .pattern;
    src.pinv = Transform2D{};
    src.ext_x = 1;
    src.ext_y = 1;
    src.tile_w = 1;
    src.tile_h = 1;
    src.tile = tile[0..];
    fbFillRectClippedAASourced(fb_pat[0..], W, H, 2.3, 2.7, 10.4, 9.6, &src, Transform2D{}, 0, Clip{});
    try testing.expectEqualSlices(u8, fb_solid[0..], fb_pat[0..]);
}

test "clipContains dispatches over none, rects, and path (ADR 0018)" {
    const testing = std.testing;

    // none admits everything.
    try testing.expect(clipContains(Clip{}, 100, -50));

    // rects: inside the union passes, outside fails (half-open).
    const rects = [_]ClipRect{.{ .x = 0, .y = 0, .w = 4, .h = 4 }};
    const rclip = Clip{ .kind = .rects, .rects = rects[0..] };
    try testing.expect(clipContains(rclip, 2, 2));
    try testing.expect(!clipContains(rclip, 4, 2)); // x == x+w is outside
    try testing.expect(!clipContains(rclip, 5, 5));

    // path: a triangle with vertices (0,0),(10,0),(0,10) under nonzero.
    const tri = [_]FillPoint{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 0, .y = 10 } };
    const lens = [_]u32{3};
    const pclip = Clip{ .kind = .path, .path_pts = tri[0..], .path_lens = lens[0..], .path_even_odd = false };
    try testing.expect(clipContains(pclip, 2, 2)); // inside
    try testing.expect(!clipContains(pclip, 8, 8)); // beyond the hypotenuse
    try testing.expect(!clipContains(pclip, -1, 5)); // left of the triangle
}

// A device-space polygon used by both C-1 equivalence tests. Fractional
// vertices exercise antialiased clip edges.
fn c1TestPolygon() [5]FillPoint {
    return .{
        .{ .x = 12.0, .y = 2.5 },
        .{ .x = 21.5, .y = 9.3 },
        .{ .x = 17.6, .y = 20.4 },
        .{ .x = 6.4, .y = 20.4 },
        .{ .x = 2.5, .y = 9.3 },
    };
}

test "rect under path clip equals fill of that path, AA (ADR 0018 C-1)" {
    const testing = std.testing;
    const W = 24;
    const H = 24;
    var fb_fill: [W * H * 4]u8 = undefined;
    var fb_clip: [W * H * 4]u8 = undefined;
    for (0..W * H) |i| {
        inline for (.{ 0, 1, 2 }) |k| {
            fb_fill[i * 4 + k] = 16;
            fb_clip[i * 4 + k] = 16;
        }
        fb_fill[i * 4 + 3] = 255;
        fb_clip[i * 4 + 3] = 255;
    }
    const P = c1TestPolygon();
    const lens = [_]u32{5};
    const cr: f32 = 0.85;
    const cg: f32 = 0.20;
    const cb: f32 = 0.45;
    const ca: f32 = 1.0;

    // Fill the path directly (no clip).
    emitFilledPath(fb_fill[0..], W, H, Clip{}, 0, P[0..], lens[0..], false, cr, cg, cb, ca, true, null, Transform2D{});

    // Clip to the path, fill a covering full-canvas rect with the same color.
    const clip = Clip{ .kind = .path, .path_pts = P[0..], .path_lens = lens[0..], .path_even_odd = false };
    fbFillRectClippedAA(fb_clip[0..], W, H, 0, 0, W, H, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), 0, clip);

    try testing.expectEqualSlices(u8, fb_fill[0..], fb_clip[0..]);
}

test "rect under path clip equals fill of that path, non-AA (ADR 0018 C-1)" {
    const testing = std.testing;
    const W = 24;
    const H = 24;
    var fb_fill: [W * H * 4]u8 = undefined;
    var fb_clip: [W * H * 4]u8 = undefined;
    for (0..W * H) |i| {
        inline for (.{ 0, 1, 2 }) |k| {
            fb_fill[i * 4 + k] = 16;
            fb_clip[i * 4 + k] = 16;
        }
        fb_fill[i * 4 + 3] = 255;
        fb_clip[i * 4 + 3] = 255;
    }
    const P = c1TestPolygon();
    const lens = [_]u32{5};
    const cr: f32 = 0.10;
    const cg: f32 = 0.70;
    const cb: f32 = 0.55;
    const ca: f32 = 1.0;

    emitFilledPath(fb_fill[0..], W, H, Clip{}, 0, P[0..], lens[0..], false, cr, cg, cb, ca, false, null, Transform2D{});

    const clip = Clip{ .kind = .path, .path_pts = P[0..], .path_lens = lens[0..], .path_even_odd = false };
    fbFillRectClipped(fb_clip[0..], W, H, 0, 0, W, H, clampU8(cr), clampU8(cg), clampU8(cb), clampU8(ca), 0, clip);

    try testing.expectEqualSlices(u8, fb_fill[0..], fb_clip[0..]);
}
