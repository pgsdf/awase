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

    // Background solid blue
    try enc.setBlend(semadraw.Encoder.BlendMode.Src);
    try enc.fillRect(0.0, 0.0, 256.0, 256.0, 0.0, 0.0, 1.0, 1.0);

    // Foreground semi-transparent yellow in SrcOver
    try enc.setBlend(semadraw.Encoder.BlendMode.SrcOver);
    try enc.fillRect(64.0, 64.0, 128.0, 128.0, 1.0, 1.0, 0.0, 0.5);

    try enc.end();
    try enc.writeToFile(file);
}
