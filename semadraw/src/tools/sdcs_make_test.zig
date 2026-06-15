const std = @import("std");
const compat = @import("compat");
const semadraw = @import("semadraw");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args_owned = try compat.args.alloc(alloc, init.args);
    defer args_owned.deinit(alloc);
    const args = args_owned.argv;

    if (args.len < 2) {
        std.log.err("usage: {s} out.sdcs", .{args[0]});
        return error.InvalidArgument;
    }

    var file = try std.fs.cwd().createFile(args[1], .{ .truncate = true });
    defer file.close();

    var enc = semadraw.Encoder.init(alloc);
    defer enc.deinit();

    try enc.reset();
    try enc.fillRect(10.0, 10.0, 100.0, 50.0, 1.0, 1.0, 1.0, 1.0);
    try enc.end();

    try enc.writeToFile(file);
}
