//! Awase compatibility boundary over churning std APIs.
//!
//! Awase code depends on the interfaces here; these interfaces depend on the
//! external std surfaces. When a std surface Awase relies on is volatile, in
//! behaviour or in shape, the volatility is absorbed once behind an Awase-owned
//! interface and callers depend on that interface, not on the std surface. This
//! is the standing rule established by ADR shared 0001 (the compatibility
//! boundary); see also shared/src/posix_safe.zig (AD-6), the first concrete
//! instance, for read/write over posix.system.*.
//!
//! Modules:
//!   args  process arguments, over std.process.Args (0.16 removed argsAlloc).
//!   io    a local blocking I/O context, lifetime only (0.16 routes I/O through
//!         a std.Io handle); construction lives here, filesystem semantics in fs.
//!   fs    the filesystem surface (0.16 relocated std.fs under std.Io and moved
//!         byte transfer onto the Reader/Writer interface).
//!
//! The socket shim (Class D) joins these here once Class E clears and the pure
//! socket surface is fully visible.

pub const args = @import("compat/args.zig");
pub const io = @import("compat/io.zig");
pub const fs = @import("compat/fs.zig");
pub const sync = @import("compat/sync.zig");
pub const time = @import("compat/time.zig");
pub const posix = @import("compat/posix.zig");
