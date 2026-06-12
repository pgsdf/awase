const std = @import("std");
const semadraw = @import("semadraw");

/// Test generator for BLIT_IMAGE.
/// Creates small procedural images and blits them at various positions.
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

    // Create a small 16x16 checkerboard image
    const img_w: u32 = 16;
    const img_h: u32 = 16;
    var checker_pixels: [img_w * img_h * 4]u8 = undefined;
    for (0..img_h) |y| {
        for (0..img_w) |x| {
            const idx = (y * img_w + x) * 4;
            const is_white = ((x / 4) + (y / 4)) % 2 == 0;
            if (is_white) {
                checker_pixels[idx + 0] = 255; // R
                checker_pixels[idx + 1] = 255; // G
                checker_pixels[idx + 2] = 255; // B
                checker_pixels[idx + 3] = 255; // A
            } else {
                checker_pixels[idx + 0] = 80; // R
                checker_pixels[idx + 1] = 80; // G
                checker_pixels[idx + 2] = 80; // B
                checker_pixels[idx + 3] = 255; // A
            }
        }
    }

    // Blit checkerboard at different positions
    try enc.blitImage(32.0, 32.0, img_w, img_h, &checker_pixels);
    try enc.blitImage(64.0, 32.0, img_w, img_h, &checker_pixels);
    try enc.blitImage(32.0, 64.0, img_w, img_h, &checker_pixels);

    // Create a gradient 24x24 image with alpha
    const grad_w: u32 = 24;
    const grad_h: u32 = 24;
    var gradient_pixels: [grad_w * grad_h * 4]u8 = undefined;
    for (0..grad_h) |y| {
        for (0..grad_w) |x| {
            const idx = (y * grad_w + x) * 4;
            gradient_pixels[idx + 0] = @intCast((x * 255) / (grad_w - 1)); // R gradient
            gradient_pixels[idx + 1] = @intCast((y * 255) / (grad_h - 1)); // G gradient
            gradient_pixels[idx + 2] = 128; // B constant
            gradient_pixels[idx + 3] = 200; // A semi-transparent
        }
    }

    // Blit gradient image
    try enc.blitImage(120.0, 100.0, grad_w, grad_h, &gradient_pixels);

    // Create a small icon-like image (8x8) with transparency
    const icon_w: u32 = 8;
    const icon_h: u32 = 8;
    var icon_pixels: [icon_w * icon_h * 4]u8 = undefined;
    for (0..icon_h) |y| {
        for (0..icon_w) |x| {
            const idx = (y * icon_w + x) * 4;
            // Create a simple circle-ish shape
            const cx: i32 = @as(i32, @intCast(x)) - 3;
            const cy: i32 = @as(i32, @intCast(y)) - 3;
            const dist_sq = cx * cx + cy * cy;
            if (dist_sq <= 9) {
                icon_pixels[idx + 0] = 255; // R
                icon_pixels[idx + 1] = 100; // G
                icon_pixels[idx + 2] = 50; // B
                icon_pixels[idx + 3] = 255; // A
            } else {
                icon_pixels[idx + 0] = 0;
                icon_pixels[idx + 1] = 0;
                icon_pixels[idx + 2] = 0;
                icon_pixels[idx + 3] = 0; // Transparent
            }
        }
    }

    // Blit icons
    try enc.blitImage(180.0, 50.0, icon_w, icon_h, &icon_pixels);
    try enc.blitImage(195.0, 50.0, icon_w, icon_h, &icon_pixels);
    try enc.blitImage(210.0, 50.0, icon_w, icon_h, &icon_pixels);

    // Test with clipping
    var clips = [_]semadraw.Encoder.Rect{
        .{ .x = 150.0, .y = 150.0, .w = 80.0, .h = 80.0 },
    };
    try enc.setClipRects(&clips);
    try enc.blitImage(140.0, 140.0, grad_w, grad_h, &gradient_pixels);
    try enc.clearClip();

    // Test with transform (translate)
    try enc.setTransform2D(1.0, 0.0, 0.0, 1.0, 50.0, 150.0);
    try enc.blitImage(0.0, 0.0, img_w, img_h, &checker_pixels);
    try enc.resetTransform();

    try enc.end();
    try enc.writeToFile(file);
}
