const std = @import("std");
const semadraw = @import("semadraw");

const Point = semadraw.Encoder.Point;

// Canvas is 256x256; the covering rect for every clipped fill is the whole
// canvas, so the active clip alone decides coverage. This is what makes the
// C-1 variants exact: a covering FILL_RECT under a path clip must match a
// direct FILL_PATH of that same path.
const COVER = [4]f32{ 0, 0, 256, 256 };

// Fill color shared by the clipped fills and their unclipped references, so a
// clip-to-P-plus-covering-rect and a direct FILL_PATH of P cannot drift on
// color (invariant C-1).
const FC = [4]f32{ 0.20, 0.60, 0.85, 1.0 };

// An axis-aligned square as a 4-point contour. `cw` selects winding: the two
// orders are mirror images. Pairing a same-wound or opposite-wound inner
// square against an outer square is what drives the winding-rule cases (a hole
// under both rules when wound opposite; a hole only under even_odd when wound
// the same).
fn square(cx: f32, cy: f32, half: f32, cw: bool) [4]Point {
    const x0 = cx - half;
    const y0 = cy - half;
    const x1 = cx + half;
    const y1 = cy + half;
    if (cw) {
        return .{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 } };
    } else {
        return .{ .{ .x = x0, .y = y0 }, .{ .x = x0, .y = y1 }, .{ .x = x1, .y = y1 }, .{ .x = x1, .y = y0 } };
    }
}

// A regular pentagon as a 5-point contour, the basic single-contour clip in
// the scene and the C-1 single-contour case. The first vertex points up.
fn pentagon(cx: f32, cy: f32, r: f32) [5]Point {
    var p: [5]Point = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const a = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / 5.0);
        p[i] = .{ .x = cx + r * std.math.cos(a), .y = cy + r * std.math.sin(a) };
    }
    return p;
}

// Two disjoint triangles, the multi-contour clip for the C-1 multi-contour
// case. Disjoint and same-wound, so nonzero fills each independently.
fn triA() [3]Point {
    return .{ .{ .x = 40, .y = 40 }, .{ .x = 110, .y = 40 }, .{ .x = 40, .y = 120 } };
}
fn triB() [3]Point {
    return .{ .{ .x = 140, .y = 140 }, .{ .x = 220, .y = 150 }, .{ .x = 170, .y = 220 } };
}

// The composite golden scene. One hash pins three independent features: a
// basic single-contour clip (pentagon), a carved hole (opposite-wound squares
// under even_odd), and a clip baked under a CTM then left fixed in device
// space while the fill runs under the identity transform (CTM at set time).
fn emitScene(enc: *semadraw.Encoder) !void {
    // Region 1: basic single-contour clip. Clip to a pentagon under the
    // identity CTM, fill the whole canvas; only the pentagon shows.
    {
        const pent = pentagon(64, 64, 46);
        try enc.setClipPath(&.{pent[0..]}, .nonzero);
        try enc.fillRect(COVER[0], COVER[1], COVER[2], COVER[3], 0.85, 0.30, 0.25, 1.0);
        try enc.clearClip();
    }

    // Region 2: a hole. Outer and inner squares wound opposite under even_odd,
    // so the inner square is carved out: the fill shows as an annulus.
    {
        const outer = square(192, 64, 46, true);
        const inner = square(192, 64, 22, false);
        try enc.setClipPath(&.{ outer[0..], inner[0..] }, .even_odd);
        try enc.fillRect(COVER[0], COVER[1], COVER[2], COVER[3], 0.20, 0.55, 0.30, 1.0);
        try enc.clearClip();
    }

    // Region 3: CTM at set time. Under a rotate+scale+translate, clip to an
    // axis-aligned square; the square bakes to a rotated quad in device space.
    // Reset the transform before filling, so only the baked clip carries the
    // rotation. The clip is fixed in device space, independent of the
    // transform in effect when the fill runs.
    {
        const deg: f32 = 20.0;
        const ang: f32 = deg * std.math.pi / 180.0;
        const cs = std.math.cos(ang);
        const sn = std.math.sin(ang);
        const sc: f32 = 1.3;
        try enc.setTransform2D(sc * cs, sc * sn, -sc * sn, sc * cs, 128, 190);
        const sq = square(0, 0, 34, true);
        try enc.setClipPath(&.{sq[0..]}, .nonzero);
        try enc.resetTransform();
        try enc.fillRect(COVER[0], COVER[1], COVER[2], COVER[3], 0.25, 0.45, 0.85, 1.0);
        try enc.clearClip();
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
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

    if (std.mem.eql(u8, variant, "scene")) {
        try emitScene(&enc);
    } else if (std.mem.eql(u8, variant, "hole-nonzero") or std.mem.eql(u8, variant, "hole-even-odd")) {
        // Outer and inner squares wound opposite. Both winding rules carve the
        // same hole, so the two renders must be byte-identical.
        const rule: semadraw.Encoder.FillRule = if (std.mem.eql(u8, variant, "hole-even-odd")) .even_odd else .nonzero;
        const outer = square(128, 128, 80, true);
        const inner = square(128, 128, 38, false);
        try enc.setClipPath(&.{ outer[0..], inner[0..] }, rule);
        try enc.fillRect(COVER[0], COVER[1], COVER[2], COVER[3], FC[0], FC[1], FC[2], FC[3]);
    } else if (std.mem.eql(u8, variant, "winding-nonzero") or std.mem.eql(u8, variant, "winding-even-odd")) {
        // Outer and inner squares wound the SAME way. nonzero fills through the
        // inner square (winding 2, no hole); even_odd carves a hole. The two
        // renders must differ.
        const rule: semadraw.Encoder.FillRule = if (std.mem.eql(u8, variant, "winding-even-odd")) .even_odd else .nonzero;
        const outer = square(128, 128, 80, true);
        const inner = square(128, 128, 38, true);
        try enc.setClipPath(&.{ outer[0..], inner[0..] }, rule);
        try enc.fillRect(COVER[0], COVER[1], COVER[2], COVER[3], FC[0], FC[1], FC[2], FC[3]);
    } else if (std.mem.eql(u8, variant, "c1-rect-clip")) {
        // C-1, single contour: clip to P (identity CTM, so the baked device
        // contour equals P), fill the covering canvas rect.
        const pent = pentagon(128, 128, 90);
        try enc.setClipPath(&.{pent[0..]}, .nonzero);
        try enc.fillRect(COVER[0], COVER[1], COVER[2], COVER[3], FC[0], FC[1], FC[2], FC[3]);
    } else if (std.mem.eql(u8, variant, "c1-rect-fill")) {
        // C-1 reference: fill P directly with the same color, no clip.
        const pent = pentagon(128, 128, 90);
        try enc.fillPath(&.{pent[0..]}, .nonzero, FC[0], FC[1], FC[2], FC[3]);
    } else if (std.mem.eql(u8, variant, "c1-multi-clip")) {
        // C-1, multi-contour: clip to two disjoint triangles, fill the cover.
        const a = triA();
        const b = triB();
        try enc.setClipPath(&.{ a[0..], b[0..] }, .nonzero);
        try enc.fillRect(COVER[0], COVER[1], COVER[2], COVER[3], FC[0], FC[1], FC[2], FC[3]);
    } else if (std.mem.eql(u8, variant, "c1-multi-fill")) {
        // C-1 multi-contour reference: fill the same two triangles directly.
        const a = triA();
        const b = triB();
        try enc.fillPath(&.{ a[0..], b[0..] }, .nonzero, FC[0], FC[1], FC[2], FC[3]);
    } else if (std.mem.eql(u8, variant, "immut-a") or std.mem.eql(u8, variant, "immut-b")) {
        // Transform immutability. Both variants bake the clip under transform A
        // and fill under the identity transform. immut-b additionally applies a
        // different transform B after the clip is set. Because the clip is
        // fixed in device space at set time, B must not move it, so the two
        // renders must be byte-identical.
        const adeg: f32 = 30.0;
        const aang: f32 = adeg * std.math.pi / 180.0;
        const acs = std.math.cos(aang);
        const asn = std.math.sin(aang);
        const asc: f32 = 1.2;
        try enc.setTransform2D(asc * acs, asc * asn, -asc * asn, asc * acs, 128, 128);
        const sq = square(0, 0, 70, true);
        try enc.setClipPath(&.{sq[0..]}, .nonzero);
        if (std.mem.eql(u8, variant, "immut-b")) {
            const bdeg: f32 = -15.0;
            const bang: f32 = bdeg * std.math.pi / 180.0;
            const bcs = std.math.cos(bang);
            const bsn = std.math.sin(bang);
            const bsc: f32 = 2.0;
            try enc.setTransform2D(bsc * bcs, bsc * bsn, -bsc * bsn, bsc * bcs, 50, 50);
        }
        try enc.resetTransform();
        try enc.fillRect(COVER[0], COVER[1], COVER[2], COVER[3], FC[0], FC[1], FC[2], FC[3]);
    } else if (std.mem.eql(u8, variant, "clear")) {
        // Clear restores. Set a clip, clear it, then fill: the fill is
        // unclipped, matching a fill that never set a clip.
        const pent = pentagon(128, 128, 90);
        try enc.setClipPath(&.{pent[0..]}, .nonzero);
        try enc.clearClip();
        try enc.fillRect(COVER[0], COVER[1], COVER[2], COVER[3], FC[0], FC[1], FC[2], FC[3]);
    } else if (std.mem.eql(u8, variant, "clear-ref")) {
        try enc.fillRect(COVER[0], COVER[1], COVER[2], COVER[3], FC[0], FC[1], FC[2], FC[3]);
    } else if (std.mem.eql(u8, variant, "replace")) {
        // Replace, not intersect. Set clip P1, then clip P2; the fill must be
        // clipped to P2 alone. P2 is not a subset of P1, so an intersection
        // would differ from P2.
        const p1 = square(96, 128, 56, true);
        const p2 = square(168, 128, 56, true);
        try enc.setClipPath(&.{p1[0..]}, .nonzero);
        try enc.setClipPath(&.{p2[0..]}, .nonzero);
        try enc.fillRect(COVER[0], COVER[1], COVER[2], COVER[3], FC[0], FC[1], FC[2], FC[3]);
    } else if (std.mem.eql(u8, variant, "replace-ref")) {
        // Reference: clip to P2 alone.
        const p2 = square(168, 128, 56, true);
        try enc.setClipPath(&.{p2[0..]}, .nonzero);
        try enc.fillRect(COVER[0], COVER[1], COVER[2], COVER[3], FC[0], FC[1], FC[2], FC[3]);
    } else {
        std.log.err("unknown variant: {s}", .{variant});
        return error.InvalidArgument;
    }

    try enc.end();
    try enc.writeToFile(file);
}
