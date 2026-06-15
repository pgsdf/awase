//! Process-argument compatibility.
//!
//! Zig 0.16 removed std.process.argsAlloc/argsFree/args(); arguments now arrive
//! through main's std.process.Init parameter as a std.process.Args. Awase tools
//! were written around argv as a random-access slice (positional access plus
//! len), so this restores that shape over the new forward iterator.

const std = @import("std");

/// Owned argument vector. Holds the allocation backing the slice so callers
/// release it through the boundary rather than knowing how it was built. The
/// field type stays fixed even if a future platform needs extra state.
pub const Argv = struct {
    argv: []const [:0]const u8,

    pub fn deinit(self: Argv, gpa: std.mem.Allocator) void {
        gpa.free(self.argv);
    }
};

/// Collect the process arguments into an owned, randomly-accessible slice.
///
/// FreeBSD: std.process.Args.Iterator is allocator-free and its returned slices
/// point into the stable process argv, so only the pointer slice is allocated.
pub fn alloc(gpa: std.mem.Allocator, args: std.process.Args) !Argv {
    var counter = std.process.Args.Iterator.init(args);
    var n: usize = 0;
    while (counter.next()) |_| n += 1;

    const out = try gpa.alloc([:0]const u8, n);
    errdefer gpa.free(out);

    var it = std.process.Args.Iterator.init(args);
    var i: usize = 0;
    while (it.next()) |arg| : (i += 1) out[i] = arg;
    return .{ .argv = out };
}

/// Forward iterator over the process arguments, for tools that parse with
/// look-ahead rather than random access. Wrapping keeps callers off
/// std.process directly, so a future change to argument delivery stays inside
/// this boundary. FreeBSD: construction is allocator-free and needs no deinit;
/// argv[0] is included (skip it if undesired).
pub const Iterator = struct {
    inner: std.process.Args.Iterator,

    pub fn next(self: *Iterator) ?[:0]const u8 {
        return self.inner.next();
    }

    pub fn skip(self: *Iterator) bool {
        return self.inner.skip();
    }
};

pub fn iterator(args: std.process.Args) Iterator {
    return .{ .inner = std.process.Args.Iterator.init(args) };
}

// Not wired into any build test step yet; runs only under an explicit
// `zig test` of this file. Exercises the collection over a synthetic argv.
test "collect argv into a slice" {
    const raw = [_][*:0]const u8{ "prog", "alpha", "beta" };
    const args: std.process.Args = .{ .vector = &raw };
    const owned = try alloc(std.testing.allocator, args);
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), owned.argv.len);
    try std.testing.expectEqualStrings("prog", owned.argv[0]);
    try std.testing.expectEqualStrings("beta", owned.argv[2]);
}
