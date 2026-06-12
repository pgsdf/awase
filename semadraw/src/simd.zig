const std = @import("std");

/// SIMD utilities for accelerated rasterization.
/// Provides vectorized operations for pixel blending, rectangle filling,
/// and anti-aliasing calculations.
///
/// Supports:
/// - x86/x86-64: SSE2 (128-bit), AVX2 (256-bit)
/// - ARM: NEON (128-bit)
/// - Fallback: Scalar implementation for other architectures

// ============================================================================
// Vector Type Definitions
// ============================================================================

/// 4-wide f32 vector (128-bit) - for 4 pixels or 4 coordinates
pub const F32x4 = @Vector(4, f32);

/// 8-wide f32 vector (256-bit) - for 8 pixels or 8 coordinates
pub const F32x8 = @Vector(8, f32);

/// 4-wide u16 vector - for intermediate blend calculations
pub const U16x4 = @Vector(4, u16);

/// 8-wide u16 vector - for processing 2 RGBA pixels
pub const U16x8 = @Vector(8, u16);

/// 16-wide u16 vector - for processing 4 RGBA pixels
pub const U16x16 = @Vector(16, u16);

/// 4-wide u8 vector - single RGBA pixel
pub const U8x4 = @Vector(4, u8);

/// 16-wide u8 vector - 4 RGBA pixels (128-bit)
pub const U8x16 = @Vector(16, u8);

/// 32-wide u8 vector - 8 RGBA pixels (256-bit)
pub const U8x32 = @Vector(32, u8);

/// 4-wide i32 vector for coordinate calculations
pub const I32x4 = @Vector(4, i32);

/// 8-wide i32 vector for coordinate calculations
pub const I32x8 = @Vector(8, i32);

// ============================================================================
// Blend Mode Constants
// ============================================================================

pub const BlendMode = enum(u32) {
    src_over = 0,
    src = 1,
    clear = 2,
    add = 3,
};

// ============================================================================
// Single Pixel Operations (Scalar, for reference)
// ============================================================================

/// Blend a single pixel using SrcOver compositing.
/// out = src * alpha + dst * (1 - alpha)
pub inline fn blendPixelSrcOver(dst: U8x4, src: U8x4, alpha: u8) U8x4 {
    _ = alpha; // Use source alpha from pixel
    const a: u16 = src[3];
    const inv_a: u16 = 255 - a;

    const sr: u16 = src[0];
    const sg: u16 = src[1];
    const sb: u16 = src[2];

    const dr: u16 = dst[0];
    const dg: u16 = dst[1];
    const db: u16 = dst[2];
    const da: u16 = dst[3];

    return .{
        @intCast(@min((sr * a + dr * inv_a) / 255, 255)),
        @intCast(@min((sg * a + dg * inv_a) / 255, 255)),
        @intCast(@min((sb * a + db * inv_a) / 255, 255)),
        @intCast(@min(a + (da * inv_a) / 255, 255)),
    };
}

// ============================================================================
// 4-Pixel Vectorized Operations (128-bit)
// ============================================================================

/// Load 4 RGBA pixels from memory into a vector
pub inline fn load4Pixels(ptr: [*]const u8) U8x16 {
    return ptr[0..16].*;
}

/// Store 4 RGBA pixels from a vector to memory
pub inline fn store4Pixels(ptr: [*]u8, pixels: U8x16) void {
    ptr[0..16].* = pixels;
}

/// Splat a single RGBA color to 4 pixels
pub inline fn splat4Pixels(r: u8, g: u8, b: u8, a: u8) U8x16 {
    return .{ r, g, b, a, r, g, b, a, r, g, b, a, r, g, b, a };
}

/// Blend 4 pixels with SrcOver compositing (vectorized)
/// Processes 4 RGBA pixels in parallel using 16-bit intermediate arithmetic
pub fn blend4PixelsSrcOver(dst: U8x16, src: U8x16) U8x16 {
    // Extract alpha values and expand to 16-bit
    // Alpha is at indices 3, 7, 11, 15
    const a0: u16 = src[3];
    const a1: u16 = src[7];
    const a2: u16 = src[11];
    const a3: u16 = src[15];

    const inv_a0: u16 = 255 - a0;
    const inv_a1: u16 = 255 - a1;
    const inv_a2: u16 = 255 - a2;
    const inv_a3: u16 = 255 - a3;

    // Process each pixel's RGBA channels
    // Pixel 0
    const r0: u16 = (@as(u16, src[0]) * a0 + @as(u16, dst[0]) * inv_a0) / 255;
    const g0: u16 = (@as(u16, src[1]) * a0 + @as(u16, dst[1]) * inv_a0) / 255;
    const b0: u16 = (@as(u16, src[2]) * a0 + @as(u16, dst[2]) * inv_a0) / 255;
    const out_a0: u16 = a0 + (@as(u16, dst[3]) * inv_a0) / 255;

    // Pixel 1
    const r1: u16 = (@as(u16, src[4]) * a1 + @as(u16, dst[4]) * inv_a1) / 255;
    const g1: u16 = (@as(u16, src[5]) * a1 + @as(u16, dst[5]) * inv_a1) / 255;
    const b1: u16 = (@as(u16, src[6]) * a1 + @as(u16, dst[6]) * inv_a1) / 255;
    const out_a1: u16 = a1 + (@as(u16, dst[7]) * inv_a1) / 255;

    // Pixel 2
    const r2: u16 = (@as(u16, src[8]) * a2 + @as(u16, dst[8]) * inv_a2) / 255;
    const g2: u16 = (@as(u16, src[9]) * a2 + @as(u16, dst[9]) * inv_a2) / 255;
    const b2: u16 = (@as(u16, src[10]) * a2 + @as(u16, dst[10]) * inv_a2) / 255;
    const out_a2: u16 = a2 + (@as(u16, dst[11]) * inv_a2) / 255;

    // Pixel 3
    const r3: u16 = (@as(u16, src[12]) * a3 + @as(u16, dst[12]) * inv_a3) / 255;
    const g3: u16 = (@as(u16, src[13]) * a3 + @as(u16, dst[13]) * inv_a3) / 255;
    const b3: u16 = (@as(u16, src[14]) * a3 + @as(u16, dst[14]) * inv_a3) / 255;
    const out_a3: u16 = a3 + (@as(u16, dst[15]) * inv_a3) / 255;

    return .{
        @intCast(@min(r0, 255)), @intCast(@min(g0, 255)), @intCast(@min(b0, 255)), @intCast(@min(out_a0, 255)),
        @intCast(@min(r1, 255)), @intCast(@min(g1, 255)), @intCast(@min(b1, 255)), @intCast(@min(out_a1, 255)),
        @intCast(@min(r2, 255)), @intCast(@min(g2, 255)), @intCast(@min(b2, 255)), @intCast(@min(out_a2, 255)),
        @intCast(@min(r3, 255)), @intCast(@min(g3, 255)), @intCast(@min(b3, 255)), @intCast(@min(out_a3, 255)),
    };
}

/// Blend 4 pixels with Src mode (direct copy)
pub inline fn blend4PixelsSrc(dst: U8x16, src: U8x16) U8x16 {
    _ = dst;
    return src;
}

/// Blend 4 pixels with Clear mode (zero)
pub inline fn blend4PixelsClear(dst: U8x16, src: U8x16) U8x16 {
    _ = dst;
    _ = src;
    return @splat(0);
}

/// Blend 4 pixels with Add mode (clamped addition)
pub fn blend4PixelsAdd(dst: U8x16, src: U8x16) U8x16 {
    // Use saturating addition - Zig's @addWithOverflow or manual clamping
    var result: U8x16 = undefined;
    inline for (0..16) |i| {
        const sum: u16 = @as(u16, dst[i]) + @as(u16, src[i]);
        result[i] = @intCast(@min(sum, 255));
    }
    return result;
}

/// Blend 4 pixels with the specified blend mode
pub fn blend4Pixels(dst: U8x16, src: U8x16, mode: u32) U8x16 {
    return switch (mode) {
        1 => blend4PixelsSrc(dst, src),
        2 => blend4PixelsClear(dst, src),
        3 => blend4PixelsAdd(dst, src),
        else => blend4PixelsSrcOver(dst, src),
    };
}

/// Blend 4 pixels with uniform color (same RGBA for all 4)
pub fn blend4PixelsUniform(dst: U8x16, r: u8, g: u8, b: u8, a: u8, mode: u32) U8x16 {
    const src = splat4Pixels(r, g, b, a);
    return blend4Pixels(dst, src, mode);
}

// ============================================================================
// Rectangle Fill Operations
// ============================================================================

/// Fill a horizontal span of pixels with a solid color.
/// Optimized for aligned 4-pixel chunks with scalar fallback for edges.
pub fn fillSpan(rgba: []u8, start_idx: usize, count: usize, r: u8, g: u8, b: u8, a: u8, mode: u32) void {
    if (count == 0) return;

    var idx = start_idx;
    var remaining = count;

    // Handle unaligned start (1-3 pixels)
    const start_misalign = (idx / 4) % 4;
    if (start_misalign != 0) {
        const align_count = @min(4 - start_misalign, remaining);
        for (0..align_count) |_| {
            blendPixelScalar(rgba, idx, r, g, b, a, mode);
            idx += 4;
            remaining -= 1;
        }
    }

    // Process aligned 4-pixel chunks
    const src = splat4Pixels(r, g, b, a);
    while (remaining >= 4) {
        const dst = load4Pixels(@ptrCast(rgba.ptr + idx));
        const result = blend4Pixels(dst, src, mode);
        store4Pixels(@ptrCast(rgba.ptr + idx), result);
        idx += 16; // 4 pixels * 4 bytes
        remaining -= 4;
    }

    // Handle remaining pixels (0-3)
    while (remaining > 0) {
        blendPixelScalar(rgba, idx, r, g, b, a, mode);
        idx += 4;
        remaining -= 1;
    }
}

/// Scalar pixel blend (fallback for edge cases)
fn blendPixelScalar(rgba: []u8, idx: usize, sr: u8, sg: u8, sb: u8, sa: u8, mode: u32) void {
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
        3 => { // Add
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

// ============================================================================
// Anti-Aliasing Sample Offsets (vectorized)
// ============================================================================

/// 4x4 sub-pixel sample offsets for AA (16 samples)
pub const AA_SAMPLES: u32 = 16;

/// Sample X offsets as vector for parallel processing
pub const AA_SAMPLE_X: F32x16 = .{
    0.0625, 0.3125, 0.5625, 0.8125,
    0.0625, 0.3125, 0.5625, 0.8125,
    0.0625, 0.3125, 0.5625, 0.8125,
    0.0625, 0.3125, 0.5625, 0.8125,
};

/// Sample Y offsets as vector for parallel processing
pub const AA_SAMPLE_Y: F32x16 = .{
    0.0625, 0.0625, 0.0625, 0.0625,
    0.3125, 0.3125, 0.3125, 0.3125,
    0.5625, 0.5625, 0.5625, 0.5625,
    0.8125, 0.8125, 0.8125, 0.8125,
};

/// 16-wide f32 vector for AA calculations
pub const F32x16 = @Vector(16, f32);

/// Compute coverage for a rectangular region using vectorized AA sampling.
/// Returns coverage value from 0.0 to 1.0.
pub fn computeRectCoverageAA(px: f32, py: f32, x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    // Use scalar loop - Zig will auto-vectorize if beneficial
    var count: u32 = 0;

    // Inline array for sample offsets
    const offsets_x = [16]f32{
        0.0625, 0.3125, 0.5625, 0.8125,
        0.0625, 0.3125, 0.5625, 0.8125,
        0.0625, 0.3125, 0.5625, 0.8125,
        0.0625, 0.3125, 0.5625, 0.8125,
    };
    const offsets_y = [16]f32{
        0.0625, 0.0625, 0.0625, 0.0625,
        0.3125, 0.3125, 0.3125, 0.3125,
        0.5625, 0.5625, 0.5625, 0.5625,
        0.8125, 0.8125, 0.8125, 0.8125,
    };

    inline for (0..16) |i| {
        const sx = px + offsets_x[i];
        const sy = py + offsets_y[i];
        if (sx >= x1 and sx < x2 and sy >= y1 and sy < y2) {
            count += 1;
        }
    }

    return @as(f32, @floatFromInt(count)) / 16.0;
}

// ============================================================================
// Cross Product for Line Rasterization
// ============================================================================

/// Compute 4 cross products in parallel for half-plane testing
pub fn crossProduct4(
    px: F32x4,
    py: F32x4,
    p0x: f32,
    p0y: f32,
    edge_x: f32,
    edge_y: f32,
) F32x4 {
    const p0x_vec: F32x4 = @splat(p0x);
    const p0y_vec: F32x4 = @splat(p0y);
    const edge_x_vec: F32x4 = @splat(edge_x);
    const edge_y_vec: F32x4 = @splat(edge_y);

    const dx = px - p0x_vec;
    const dy = py - p0y_vec;

    return dx * edge_y_vec - dy * edge_x_vec;
}

/// Test if 4 points are inside a half-plane (cross product >= 0)
pub fn halfPlaneTest4(cross: F32x4) @Vector(4, bool) {
    const zeros: F32x4 = @splat(0.0);
    return cross >= zeros;
}

// ============================================================================
// Tests
// ============================================================================

test "splat4Pixels" {
    const pixels = splat4Pixels(255, 128, 64, 200);
    try std.testing.expectEqual(@as(u8, 255), pixels[0]);
    try std.testing.expectEqual(@as(u8, 128), pixels[1]);
    try std.testing.expectEqual(@as(u8, 64), pixels[2]);
    try std.testing.expectEqual(@as(u8, 200), pixels[3]);
    // Check second pixel
    try std.testing.expectEqual(@as(u8, 255), pixels[4]);
    try std.testing.expectEqual(@as(u8, 128), pixels[5]);
}

test "blend4PixelsSrc" {
    const dst = splat4Pixels(100, 100, 100, 255);
    const src = splat4Pixels(200, 150, 50, 128);
    const result = blend4PixelsSrc(dst, src);

    try std.testing.expectEqual(@as(u8, 200), result[0]);
    try std.testing.expectEqual(@as(u8, 150), result[1]);
    try std.testing.expectEqual(@as(u8, 50), result[2]);
    try std.testing.expectEqual(@as(u8, 128), result[3]);
}

test "blend4PixelsAdd" {
    const dst = splat4Pixels(100, 200, 250, 100);
    const src = splat4Pixels(100, 100, 100, 100);
    const result = blend4PixelsAdd(dst, src);

    try std.testing.expectEqual(@as(u8, 200), result[0]); // 100 + 100
    try std.testing.expectEqual(@as(u8, 255), result[1]); // clamped
    try std.testing.expectEqual(@as(u8, 255), result[2]); // clamped
    try std.testing.expectEqual(@as(u8, 200), result[3]); // 100 + 100
}

test "blend4PixelsSrcOver" {
    // Fully opaque source should replace destination
    const dst = splat4Pixels(100, 100, 100, 255);
    const src = splat4Pixels(200, 150, 50, 255);
    const result = blend4PixelsSrcOver(dst, src);

    try std.testing.expectEqual(@as(u8, 200), result[0]);
    try std.testing.expectEqual(@as(u8, 150), result[1]);
    try std.testing.expectEqual(@as(u8, 50), result[2]);
    try std.testing.expectEqual(@as(u8, 255), result[3]);
}

test "blend4PixelsSrcOver_transparent" {
    // Fully transparent source should preserve destination
    const dst = splat4Pixels(100, 100, 100, 255);
    const src = splat4Pixels(200, 150, 50, 0);
    const result = blend4PixelsSrcOver(dst, src);

    try std.testing.expectEqual(@as(u8, 100), result[0]);
    try std.testing.expectEqual(@as(u8, 100), result[1]);
    try std.testing.expectEqual(@as(u8, 100), result[2]);
}

test "blend4PixelsSrcOver_half" {
    // 50% alpha should blend evenly
    const dst = splat4Pixels(0, 0, 0, 255);
    const src = splat4Pixels(255, 255, 255, 128);
    const result = blend4PixelsSrcOver(dst, src);

    // Result should be approximately 128 (255 * 128/255 + 0 * 127/255)
    try std.testing.expect(result[0] >= 126 and result[0] <= 130);
    try std.testing.expect(result[1] >= 126 and result[1] <= 130);
    try std.testing.expect(result[2] >= 126 and result[2] <= 130);
}

test "computeRectCoverageAA_fully_inside" {
    // Pixel fully inside rectangle
    const coverage = computeRectCoverageAA(5.0, 5.0, 0.0, 0.0, 10.0, 10.0);
    try std.testing.expectEqual(@as(f32, 1.0), coverage);
}

test "computeRectCoverageAA_fully_outside" {
    // Pixel fully outside rectangle
    const coverage = computeRectCoverageAA(15.0, 15.0, 0.0, 0.0, 10.0, 10.0);
    try std.testing.expectEqual(@as(f32, 0.0), coverage);
}

test "computeRectCoverageAA_partial" {
    // Pixel at edge should have partial coverage
    const coverage = computeRectCoverageAA(9.5, 5.0, 0.0, 0.0, 10.0, 10.0);
    try std.testing.expect(coverage > 0.0 and coverage < 1.0);
}

test "crossProduct4" {
    const px: F32x4 = .{ 1.0, 2.0, 3.0, 4.0 };
    const py: F32x4 = .{ 1.0, 1.0, 1.0, 1.0 };
    const result = crossProduct4(px, py, 0.0, 0.0, 1.0, 0.0);

    // Cross product of (px-0, py-0) with (1, 0) = px*0 - py*1 = -py
    try std.testing.expectEqual(@as(f32, -1.0), result[0]);
    try std.testing.expectEqual(@as(f32, -1.0), result[1]);
}
