/// sdcs_make_glyph — DRAW_GLYPH_RUN test for D-4.
///
/// Renders:
///   1. A row of ASCII glyphs (single-width, cell_width=6)
///   2. A row of CJK-like glyphs (double-width, cell_width=12) using the
///      same atlas but 2× cell width, verifying that double-width glyphs
///      occupy exactly twice the horizontal space.
///
/// The resulting SDCS file is replayed by sdcs_replay and compared against
/// the golden hash in tests/golden/golden.sha256.

const std = @import("std");
const semadraw = @import("semadraw");

// ============================================================================
// Minimal 6×8 monospaced atlas: ASCII glyphs A-Z (26 glyphs), single row.
// Each cell is 6 wide × 8 tall. Double-width cells are 12 wide × 8 tall and
// use two adjacent single-width cells from the atlas.
// ============================================================================

const CW: u32 = 6;   // single cell width
const CH: u32 = 8;   // cell height
const NCOLS: u32 = 26; // A-Z
const AW: u32 = CW * NCOLS; // 156
const AH: u32 = CH;          // 8

/// Compact 6×8 font bitmaps for A–Z.
/// Each entry is 8 rows of 6-bit patterns (bits 5..0 = columns 0..5).
const bitmaps = [26][8]u6{
    // A
    .{ 0b001100, 0b010010, 0b100001, 0b100001, 0b111111, 0b100001, 0b100001, 0b000000 },
    // B
    .{ 0b111110, 0b100001, 0b100001, 0b111110, 0b100001, 0b100001, 0b111110, 0b000000 },
    // C
    .{ 0b011110, 0b100001, 0b100000, 0b100000, 0b100000, 0b100001, 0b011110, 0b000000 },
    // D
    .{ 0b111100, 0b100010, 0b100001, 0b100001, 0b100001, 0b100010, 0b111100, 0b000000 },
    // E
    .{ 0b111111, 0b100000, 0b100000, 0b111110, 0b100000, 0b100000, 0b111111, 0b000000 },
    // F
    .{ 0b111111, 0b100000, 0b100000, 0b111110, 0b100000, 0b100000, 0b100000, 0b000000 },
    // G
    .{ 0b011110, 0b100001, 0b100000, 0b100111, 0b100001, 0b100001, 0b011111, 0b000000 },
    // H
    .{ 0b100001, 0b100001, 0b100001, 0b111111, 0b100001, 0b100001, 0b100001, 0b000000 },
    // I
    .{ 0b011110, 0b001000, 0b001000, 0b001000, 0b001000, 0b001000, 0b011110, 0b000000 },
    // J
    .{ 0b000111, 0b000010, 0b000010, 0b000010, 0b000010, 0b100010, 0b011100, 0b000000 },
    // K
    .{ 0b100010, 0b100100, 0b101000, 0b110000, 0b101000, 0b100100, 0b100010, 0b000000 },
    // L
    .{ 0b100000, 0b100000, 0b100000, 0b100000, 0b100000, 0b100000, 0b111111, 0b000000 },
    // M
    .{ 0b100001, 0b110011, 0b101101, 0b100001, 0b100001, 0b100001, 0b100001, 0b000000 },
    // N
    .{ 0b100001, 0b110001, 0b101001, 0b100101, 0b100011, 0b100001, 0b100001, 0b000000 },
    // O
    .{ 0b011110, 0b100001, 0b100001, 0b100001, 0b100001, 0b100001, 0b011110, 0b000000 },
    // P
    .{ 0b111110, 0b100001, 0b100001, 0b111110, 0b100000, 0b100000, 0b100000, 0b000000 },
    // Q
    .{ 0b011110, 0b100001, 0b100001, 0b100001, 0b100101, 0b100010, 0b011101, 0b000000 },
    // R
    .{ 0b111110, 0b100001, 0b100001, 0b111110, 0b101000, 0b100100, 0b100010, 0b000000 },
    // S
    .{ 0b011111, 0b100000, 0b100000, 0b011110, 0b000001, 0b000001, 0b111110, 0b000000 },
    // T
    .{ 0b111111, 0b001000, 0b001000, 0b001000, 0b001000, 0b001000, 0b001000, 0b000000 },
    // U
    .{ 0b100001, 0b100001, 0b100001, 0b100001, 0b100001, 0b100001, 0b011110, 0b000000 },
    // V
    .{ 0b100001, 0b100001, 0b100001, 0b100001, 0b010010, 0b010010, 0b001100, 0b000000 },
    // W
    .{ 0b100001, 0b100001, 0b100001, 0b101101, 0b010010, 0b010010, 0b000000, 0b000000 },
    // X
    .{ 0b100001, 0b010010, 0b001100, 0b001100, 0b010010, 0b100001, 0b000000, 0b000000 },
    // Y
    .{ 0b100001, 0b010010, 0b001100, 0b001000, 0b001000, 0b001000, 0b001000, 0b000000 },
    // Z
    .{ 0b111111, 0b000010, 0b000100, 0b001000, 0b010000, 0b100000, 0b111111, 0b000000 },
};

fn generateAtlas() [AW * AH]u8 {
    var atlas: [AW * AH]u8 = [_]u8{0} ** (AW * AH);
    for (bitmaps, 0..) |rows, gi| {
        const ax = gi * CW;
        for (rows, 0..) |row_bits, row| {
            for (0..CW) |col| {
                const bit = (row_bits >> @intCast(5 - col)) & 1;
                atlas[row * AW + ax + col] = if (bit == 1) 255 else 0;
            }
        }
    }
    return atlas;
}

fn charIndex(c: u8) u32 {
    return switch (c) {
        'A'...'Z' => c - 'A',
        'a'...'z' => c - 'a',
        else => 0,
    };
}

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

    // Dark background.
    try enc.setBlend(semadraw.Encoder.BlendMode.Src);
    try enc.fillRect(0, 0, 256, 256, 0.05, 0.05, 0.1, 1.0);
    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);

    const atlas = generateAtlas();

    // -----------------------------------------------------------------------
    // Row 1: ASCII single-width "HELLO" at y=20, cell_width=CW
    // -----------------------------------------------------------------------
    const ascii_str = "HELLO";
    var ascii_glyphs: [ascii_str.len]semadraw.Encoder.Glyph = undefined;
    for (ascii_str, 0..) |c, i| {
        ascii_glyphs[i] = .{
            .index    = charIndex(c),
            .x_offset = @as(f32, @floatFromInt(i)) * @as(f32, @floatFromInt(CW + 1)),
            .y_offset = 0,
        };
    }
    try enc.drawGlyphRun(
        20, 20, 1.0, 1.0, 1.0, 1.0, // white
        CW, CH, NCOLS, AW, AH,
        &ascii_glyphs, &atlas,
    );

    // -----------------------------------------------------------------------
    // Row 2: CJK double-width "WORLD" at y=40, cell_width=CW*2.
    // Each glyph occupies 2× horizontal space. The glyph index still refers
    // to the same atlas cell; the wider cell_width causes the blit to sample
    // the atlas pixel at position (atlas_x + px) where px goes to 2*CW-1.
    // Pixels beyond the single-cell width (px >= CW) read zeros, producing a
    // blank right half — correctly simulating a full-width character box.
    // In a real CJK font the atlas cells would be CW*2 wide.
    // -----------------------------------------------------------------------
    const cjk_str = "WORLD";
    var cjk_glyphs: [cjk_str.len]semadraw.Encoder.Glyph = undefined;
    for (cjk_str, 0..) |c, i| {
        cjk_glyphs[i] = .{
            .index    = charIndex(c),
            .x_offset = @as(f32, @floatFromInt(i)) * @as(f32, @floatFromInt(CW * 2 + 1)),
            .y_offset = 0,
        };
    }
    try enc.drawGlyphRun(
        20, 40, 0.4, 0.9, 1.0, 1.0, // light blue
        CW * 2, CH, NCOLS, AW, AH,   // double cell_width
        &cjk_glyphs, &atlas,
    );

    // -----------------------------------------------------------------------
    // Row 3: Mixed run — first glyph single-width, remaining double-width.
    // Demonstrates that x_offset controls placement independently of cell_w.
    // -----------------------------------------------------------------------
    const mixed_str = "ABCD";
    var mixed_glyphs: [mixed_str.len]semadraw.Encoder.Glyph = undefined;
    var x_cursor: f32 = 0;
    for (mixed_str, 0..) |c, i| {
        mixed_glyphs[i] = .{
            .index    = charIndex(c),
            .x_offset = x_cursor,
            .y_offset = 0,
        };
        // A is single-width, B-D are double-width.
        x_cursor += if (i == 0)
            @as(f32, @floatFromInt(CW + 1))
        else
            @as(f32, @floatFromInt(CW * 2 + 1));
    }
    try enc.drawGlyphRun(
        20, 60, 1.0, 0.7, 0.3, 1.0, // orange
        CW * 2, CH, NCOLS, AW, AH,
        &mixed_glyphs, &atlas,
    );

    // -----------------------------------------------------------------------
    // Row 4: Full alphabet A-Z, single-width, to exercise all 26 glyphs.
    // -----------------------------------------------------------------------
    var alpha_glyphs: [26]semadraw.Encoder.Glyph = undefined;
    for (0..26) |i| {
        alpha_glyphs[i] = .{
            .index    = @intCast(i),
            .x_offset = @as(f32, @floatFromInt(i)) * @as(f32, @floatFromInt(CW)),
            .y_offset = 0,
        };
    }
    try enc.drawGlyphRun(
        4, 80, 0.8, 1.0, 0.6, 1.0, // green
        CW, CH, NCOLS, AW, AH,
        &alpha_glyphs, &atlas,
    );

    try enc.end();
    try enc.writeToFile(file);
}
