//! compat.io: ownership of the local I/O context.
//!
//! Zig 0.16 routes filesystem and stream operations through a std.Io handle
//! rather than free functions on std.fs. Awase tools own their own allocator
//! and keep the std.process.Init.Minimal entrypoint, so they construct a local
//! blocking Io from that allocator through this boundary rather than taking the
//! full std.process.Init (ADR shared 0001, Decision 2, Option B).
//!
//! This module owns construction and lifetime only. It deliberately exposes no
//! filesystem helpers; those live in compat.fs, so this does not grow into a
//! second filesystem layer (ADR shared 0001, Decision 3 constraint).
//!
//! Usage:
//!     var io_ctx = try compat.io.open(gpa);
//!     defer io_ctx.deinit();
//!     const io = io_ctx.io();          // hand to compat.fs.cwd(io)

const std = @import("std");

/// A live I/O context. Holds the backing implementation and hands out the
/// opaque handle the rest of the boundary consumes. Must outlive every handle
/// it produces and every compat.fs value derived from those handles, so it is
/// held as a local `var` for the duration of the work and not copied.
pub const Context = struct {
    backing: std.Io.Threaded,

    /// The handle to pass into compat.fs and any other boundary that performs
    /// I/O. Stable for the lifetime of the Context.
    pub fn io(self: *Context) std.Io {
        return self.backing.io();
    }

    pub fn deinit(self: *Context) void {
        self.backing.deinit();
    }
};

/// Open a local blocking I/O context backed by `gpa`. The allocator must
/// outlive the returned Context.
///
/// Fallible by signature even though today's backing construction cannot fail,
/// so that a future Zig I/O implementation that needs a fallible setup does not
/// force a signature change on every call site.
pub fn open(gpa: std.mem.Allocator) !Context {
    return .{ .backing = std.Io.Threaded.init(gpa, .{}) };
}
