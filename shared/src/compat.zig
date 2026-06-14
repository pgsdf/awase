//! Awase compatibility boundary over churning std APIs.
//!
//! Zig's standard library periodically removes or reshapes medium-level
//! interfaces that Awase depends on broadly (process arguments in 0.16, the
//! std.posix socket layer in 0.16). Rather than couple dozens of call sites
//! directly to those moving targets, Awase owns thin replacements here, built
//! over the surviving primitives (std.process.Args.Iterator, posix.system.*).
//! If a future Zig release moves the ground again, the migration stays inside
//! this boundary instead of spreading across the tree.
//!
//! shared/src/posix_safe.zig (AD-6) already follows this pattern for read/write
//! over posix.system.*; the forthcoming socket shim (Class D) joins it here.

pub const args = @import("compat/args.zig");
