const std = @import("std");
const semadraw = @import("semadraw");

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

    try enc.setBlend(semadraw.Encoder.BlendMode.Src);
    try enc.fillRect(0.0, 0.0, 256.0, 256.0, 0.1, 0.1, 0.1, 1.0);

    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);

    var clips = [_]semadraw.Encoder.Rect{
        .{ .x = 24.0, .y = 24.0, .w = 208.0, .h = 208.0 },
    };
    try enc.setClipRects(&clips);

    try enc.strokeRect(32.0, 32.0, 192.0, 192.0, 16.0, 0.2, 0.7, 1.0, 0.9);
    try enc.strokeRect(72.0, 72.0, 112.0, 112.0, 10.0, 1.0, 0.6, 0.2, 0.5);

    try enc.clearClip();
    try enc.end();
    try enc.writeToFile(file);
}
