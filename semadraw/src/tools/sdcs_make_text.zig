const std = @import("std");
const semadraw = @import("semadraw");

/// Simple 5x7 bitmap font data for uppercase letters A-Z and digits 0-9.
/// Each glyph is 5 pixels wide, 7 pixels tall.
/// The atlas is arranged in a single row: A B C D E F G H I J K L M N O P Q R S T U V W X Y Z 0 1 2 3 4 5 6 7 8 9
const GLYPH_WIDTH: u32 = 5;
const GLYPH_HEIGHT: u32 = 7;
const ATLAS_COLS: u32 = 36; // 26 letters + 10 digits
const ATLAS_WIDTH: u32 = GLYPH_WIDTH * ATLAS_COLS; // 180
const ATLAS_HEIGHT: u32 = GLYPH_HEIGHT; // 7

/// Bitmap font data (5x7 per glyph, stored as rows)
/// Each glyph is represented as 7 rows of 5-bit patterns
const font_data = [36][7]u8{
    // A
    .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
    // B
    .{ 0b11110, 0b10001, 0b11110, 0b10001, 0b10001, 0b10001, 0b11110 },
    // C
    .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 },
    // D
    .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
    // E
    .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
    // F
    .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
    // G
    .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110 },
    // H
    .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
    // I
    .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
    // J
    .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 },
    // K
    .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
    // L
    .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
    // M
    .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
    // N
    .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
    // O
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
    // P
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
    // Q
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
    // R
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
    // S
    .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
    // T
    .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
    // U
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
    // V
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
    // W
    .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010 },
    // X
    .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
    // Y
    .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
    // Z
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
    // 0
    .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
    // 1
    .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
    // 2
    .{ 0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111 },
    // 3
    .{ 0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110 },
    // 4
    .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
    // 5
    .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 },
    // 6
    .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
    // 7
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
    // 8
    .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
    // 9
    .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 },
};

/// Generate atlas data from font bitmap
fn generateAtlas() [ATLAS_WIDTH * ATLAS_HEIGHT]u8 {
    var atlas: [ATLAS_WIDTH * ATLAS_HEIGHT]u8 = undefined;
    @memset(&atlas, 0);

    for (0..36) |glyph_idx| {
        const glyph = font_data[glyph_idx];
        const atlas_x = glyph_idx * GLYPH_WIDTH;

        for (0..GLYPH_HEIGHT) |row| {
            const row_bits = glyph[row];
            for (0..GLYPH_WIDTH) |col| {
                const bit = (row_bits >> @intCast(4 - col)) & 1;
                const idx = row * ATLAS_WIDTH + atlas_x + col;
                atlas[idx] = if (bit == 1) 255 else 0;
            }
        }
    }

    return atlas;
}

/// Map ASCII character to glyph index
fn charToGlyphIndex(c: u8) ?u32 {
    if (c >= 'A' and c <= 'Z') {
        return c - 'A';
    } else if (c >= 'a' and c <= 'z') {
        return c - 'a'; // Map lowercase to uppercase
    } else if (c >= '0' and c <= '9') {
        return 26 + (c - '0');
    }
    return null;
}

/// Test generator for DRAW_GLYPH_RUN (text rendering with glyph atlas).
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

    // Generate the font atlas
    const atlas = generateAtlas();

    // === Text 1: "HELLO" in white ===
    const text1 = "HELLO";
    var glyphs1: [5]semadraw.Encoder.Glyph = undefined;
    for (text1, 0..) |c, i| {
        glyphs1[i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0, // 5 width + 1 spacing
            .y_offset = 0.0,
        };
    }
    try enc.drawGlyphRun(
        20.0,
        20.0,
        1.0,
        1.0,
        1.0,
        1.0, // white
        GLYPH_WIDTH,
        GLYPH_HEIGHT,
        ATLAS_COLS,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
        &glyphs1,
        &atlas,
    );

    // === Text 2: "SDCS" in orange ===
    const text2 = "SDCS";
    var glyphs2: [4]semadraw.Encoder.Glyph = undefined;
    for (text2, 0..) |c, i| {
        glyphs2[i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0,
            .y_offset = 0.0,
        };
    }
    try enc.drawGlyphRun(
        60.0,
        20.0,
        1.0,
        0.6,
        0.2,
        1.0, // orange
        GLYPH_WIDTH,
        GLYPH_HEIGHT,
        ATLAS_COLS,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
        &glyphs2,
        &atlas,
    );

    // === Text 3: "WORLD" in cyan ===
    const text3 = "WORLD";
    var glyphs3: [5]semadraw.Encoder.Glyph = undefined;
    for (text3, 0..) |c, i| {
        glyphs3[i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0,
            .y_offset = 0.0,
        };
    }
    try enc.drawGlyphRun(
        20.0,
        40.0,
        0.2,
        0.8,
        1.0,
        1.0, // cyan
        GLYPH_WIDTH,
        GLYPH_HEIGHT,
        ATLAS_COLS,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
        &glyphs3,
        &atlas,
    );

    // === Text 4: "2024" in green ===
    const text4 = "2024";
    var glyphs4: [4]semadraw.Encoder.Glyph = undefined;
    for (text4, 0..) |c, i| {
        glyphs4[i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0,
            .y_offset = 0.0,
        };
    }
    try enc.drawGlyphRun(
        20.0,
        60.0,
        0.3,
        1.0,
        0.3,
        1.0, // green
        GLYPH_WIDTH,
        GLYPH_HEIGHT,
        ATLAS_COLS,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
        &glyphs4,
        &atlas,
    );

    // === Text 5: "ABCDEFGHIJ" in magenta (longer text) ===
    const text5 = "ABCDEFGHIJ";
    var glyphs5: [10]semadraw.Encoder.Glyph = undefined;
    for (text5, 0..) |c, i| {
        glyphs5[i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0,
            .y_offset = 0.0,
        };
    }
    try enc.drawGlyphRun(
        20.0,
        80.0,
        1.0,
        0.4,
        1.0,
        1.0, // magenta
        GLYPH_WIDTH,
        GLYPH_HEIGHT,
        ATLAS_COLS,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
        &glyphs5,
        &atlas,
    );

    // === Text 6: Semi-transparent yellow text ===
    const text6 = "ALPHA";
    var glyphs6: [5]semadraw.Encoder.Glyph = undefined;
    for (text6, 0..) |c, i| {
        glyphs6[i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0,
            .y_offset = 0.0,
        };
    }
    try enc.drawGlyphRun(
        20.0,
        100.0,
        1.0,
        1.0,
        0.3,
        0.5, // semi-transparent yellow
        GLYPH_WIDTH,
        GLYPH_HEIGHT,
        ATLAS_COLS,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
        &glyphs6,
        &atlas,
    );

    // === Text 7: With transform (scaled 2x) ===
    try enc.setTransform2D(2.0, 0.0, 0.0, 2.0, 0.0, 0.0);
    const text7 = "BIG";
    var glyphs7: [3]semadraw.Encoder.Glyph = undefined;
    for (text7, 0..) |c, i| {
        glyphs7[i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0,
            .y_offset = 0.0,
        };
    }
    try enc.drawGlyphRun(
        10.0,
        65.0, // Will be at 20, 130 after 2x scale
        1.0,
        0.5,
        0.5,
        1.0, // pink
        GLYPH_WIDTH,
        GLYPH_HEIGHT,
        ATLAS_COLS,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
        &glyphs7,
        &atlas,
    );
    try enc.resetTransform();

    // === Text 8: Clipped text ===
    var clips = [_]semadraw.Encoder.Rect{
        .{ .x = 20.0, .y = 160.0, .w = 30.0, .h = 10.0 },
    };
    try enc.setClipRects(&clips);
    const text8 = "CLIPPED";
    var glyphs8: [7]semadraw.Encoder.Glyph = undefined;
    for (text8, 0..) |c, i| {
        glyphs8[i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0,
            .y_offset = 0.0,
        };
    }
    try enc.drawGlyphRun(
        15.0,
        158.0,
        0.8,
        0.8,
        0.2,
        1.0, // yellow
        GLYPH_WIDTH,
        GLYPH_HEIGHT,
        ATLAS_COLS,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
        &glyphs8,
        &atlas,
    );
    try enc.clearClip();

    // === Text 9: All digits ===
    const text9 = "0123456789";
    var glyphs9: [10]semadraw.Encoder.Glyph = undefined;
    for (text9, 0..) |c, i| {
        glyphs9[i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0,
            .y_offset = 0.0,
        };
    }
    try enc.drawGlyphRun(
        20.0,
        180.0,
        0.5,
        0.8,
        1.0,
        1.0, // light blue
        GLYPH_WIDTH,
        GLYPH_HEIGHT,
        ATLAS_COLS,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
        &glyphs9,
        &atlas,
    );

    // === Text 10: Multi-line effect with y_offset ===
    const text10a = "LINE";
    const text10b = "TWO";
    var glyphs10: [7]semadraw.Encoder.Glyph = undefined;
    for (text10a, 0..) |c, i| {
        glyphs10[i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0,
            .y_offset = 0.0,
        };
    }
    for (text10b, 0..) |c, i| {
        glyphs10[4 + i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0,
            .y_offset = 10.0, // Second line
        };
    }
    try enc.drawGlyphRun(
        150.0,
        160.0,
        0.9,
        0.7,
        0.5,
        1.0, // tan
        GLYPH_WIDTH,
        GLYPH_HEIGHT,
        ATLAS_COLS,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
        &glyphs10,
        &atlas,
    );

    // === Text at bottom: "KLMNOPQRSTUVWXYZ" to show full alphabet ===
    const text11 = "KLMNOPQRSTUVWXYZ";
    var glyphs11: [16]semadraw.Encoder.Glyph = undefined;
    for (text11, 0..) |c, i| {
        glyphs11[i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0,
            .y_offset = 0.0,
        };
    }
    try enc.drawGlyphRun(
        20.0,
        200.0,
        0.7,
        0.9,
        0.7,
        1.0, // light green
        GLYPH_WIDTH,
        GLYPH_HEIGHT,
        ATLAS_COLS,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
        &glyphs11,
        &atlas,
    );

    // === Final row: "VECTOR" in red ===
    const text12 = "VECTOR";
    var glyphs12: [6]semadraw.Encoder.Glyph = undefined;
    for (text12, 0..) |c, i| {
        glyphs12[i] = .{
            .index = charToGlyphIndex(c) orelse 0,
            .x_offset = @as(f32, @floatFromInt(i)) * 6.0,
            .y_offset = 0.0,
        };
    }
    try enc.drawGlyphRun(
        20.0,
        220.0,
        1.0,
        0.3,
        0.3,
        1.0, // red
        GLYPH_WIDTH,
        GLYPH_HEIGHT,
        ATLAS_COLS,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
        &glyphs12,
        &atlas,
    );

    try enc.end();
    try enc.writeToFile(file);
}
