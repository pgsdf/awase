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

    // Translate by (40, 30) and scale by 1.0 (identity scale)
    // Matrix:
    // x' = 1*x + 0*y + 40
    // y' = 0*x + 1*y + 30
    try enc.setTransform2D(1.0, 0.0, 0.0, 1.0, 40.0, 30.0);

    try enc.fillRect(10.0, 10.0, 80.0, 40.0, 1.0, 0.0, 1.0, 1.0);

    try enc.end();
    try enc.writeToFile(file);
}
