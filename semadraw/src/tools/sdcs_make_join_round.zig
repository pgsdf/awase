const std = @import("std");
const semadraw = @import("semadraw");

// Minimal generator for a round join.
//
// Produces a small SDCS stream containing two connected STROKE_LINE commands that
// meet at a right angle with StrokeJoin.Round enabled.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len != 2) {
        std.log.err("usage: {s} <out.sdcs>", .{args[0]});
        return error.InvalidArgs;
    }

    const out_path = args[1];

    var out = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer out.close();

    var enc = semadraw.Encoder.init(alloc);
    defer enc.deinit();

    try enc.reset();

    // Stroke style.
    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);
    const stroke_w: f32 = 18.0;
    const cr: f32 = 0.1;
    const cg: f32 = 0.6;
    const cb: f32 = 0.9;
    const ca: f32 = 1.0;
    try enc.setStrokeJoin(.Round);

    // An L shape.
    try enc.strokeLine(64.0, 64.0, 192.0, 64.0, stroke_w, cr, cg, cb, ca);
    try enc.strokeLine(192.0, 64.0, 192.0, 192.0, stroke_w, cr, cg, cb, ca);

    try enc.end();
    try enc.writeToFile(out);
}