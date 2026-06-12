/// sdcs_make_cursor — generate the default cursor sprite as SDCS bytes.
///
/// Per ADR 0005 section 6, the default cursor is a 24×24 stepped-triangle
/// arrow with a black 1-pixel outline and white interior. The hotspot is
/// at pixel (0, 0) — the arrow tip at the top-left.
///
/// Output is a complete SDCS file (header + CMDS chunk + commands) ready
/// to be attached as a surface buffer via `attachInlineBuffer`. The file
/// is committed at `semadraw/src/daemon/cursor_arrow.sdcs` and embedded
/// into semadrawd via `@embedFile`. The asset lives in the daemon's
/// source tree (rather than a separate `assets/` directory) so that
/// Zig's `@embedFile` package-path constraint is satisfied without
/// extra build wiring.
///
/// This program is the documentation of how the bytes were produced; it
/// is NOT part of the daemon's build chain. Re-run this program if the
/// cursor design changes:
///
///     zig build sdcs_make_cursor
///     ./zig-out/bin/sdcs_make_cursor semadraw/src/daemon/cursor_arrow.sdcs
///
/// then commit the regenerated .sdcs file.

const std = @import("std");
const semadraw = @import("semadraw");

/// Sprite dimensions. The surface is logically this size; the cursor's
/// hotspot is at (0, 0).
const SPRITE_W: f32 = 24;
const SPRITE_H: f32 = 24;

/// Arrow row layout. Each row N contains:
///   - background:           transparent (no fill)
///   - black border at x=0:  1px wide
///   - white interior:       (row_width[N] - 2) px wide, starting at x=1
///   - black border at right: 1px at x=row_width[N]-1
///
/// row_width[N] is the pixel-count of the visible arrow shape on row N.
/// The shape narrows from row 0 (1px) downward to form a triangle, then
/// trails off into a smaller rectangular "tail" at the bottom.
///
/// 16 rows total, gives a recognisable arrow without needing fancy art.
const ROWS: usize = 16;
const row_width = [ROWS]u32{
    1,  // row  0: just the tip pixel
    2,  // row  1
    3,  // row  2
    4,  // row  3
    5,  // row  4
    6,  // row  5
    7,  // row  6
    8,  // row  7
    9,  // row  8
    10, // row  9
    11, // row 10
    12, // row 11
    13, // row 12
    6,  // row 13: tail starts; 6px wide at x=0..5
    5,  // row 14: tail
    4,  // row 15: tail end
};

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

    // SrcOver blend so transparent regions outside the arrow don't
    // overwrite underlying surface pixels — only the arrow itself
    // composites onto the framebuffer.
    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);

    // Render each row as two FILL_RECT calls: the full-width black
    // outline first, then a 2px-narrower white interior overlaid on
    // top. Single-pixel-wide rows (only row 0) are pure black; the
    // white inset would be zero-width and is skipped.
    var y: f32 = 0;
    for (row_width) |w| {
        const wf: f32 = @floatFromInt(w);

        // Black outline: full width at this row.
        try enc.fillRect(0, y, wf, 1, 0, 0, 0, 1);

        // White interior: inset by 1px on left and right. Only emit if
        // there's room (rows narrower than 3px have no interior).
        if (w >= 3) {
            try enc.fillRect(1, y, wf - 2, 1, 1, 1, 1, 1);
        }

        y += 1;
    }

    try enc.end();
    try enc.writeToFile(file);

    std.log.info("wrote {s} ({d} rows, sprite {d}x{d}, hotspot (0, 0))", .{
        args[1], ROWS, @as(u32, @intFromFloat(SPRITE_W)), @as(u32, @intFromFloat(SPRITE_H)),
    });
}
