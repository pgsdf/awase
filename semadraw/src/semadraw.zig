const std = @import("std");

pub const ApiVersion = struct {
    pub const major: u16 = 0;
    pub const minor: u16 = 1;
    pub const patch: u16 = 0;
};

pub const Result = error{
    InvalidArgument,
    OutOfMemory,
    NotSupported,
    Io,
    Protocol,
    Backend,
    Internal,
};

pub const Scalar = f32;

pub const Point = struct { x: Scalar, y: Scalar };
pub const Size = struct { w: Scalar, h: Scalar };
pub const Rect = struct { x: Scalar, y: Scalar, w: Scalar, h: Scalar };
pub const Rgba = struct { r: f32, g: f32, b: f32, a: f32 };

pub const BlendMode = enum(u32) { src_over = 0, src = 1, dst_over = 2, multiply = 3, screen = 4 };
pub const PresentMode = enum(u32) { immediate = 0, vsync = 1 };
pub const Backend = enum(u32) { auto = 0, software = 1, vulkan = 2, host_x11 = 3, host_wayland = 4, kms = 5, headless = 6 };

pub const ContextDesc = struct {
    backend: Backend = .auto,
    endpoint: ?[]const u8 = null,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    backend: Backend,

    pub fn init(allocator: std.mem.Allocator, desc: ContextDesc) !Context {
        _ = desc.endpoint;
        return .{ .allocator = allocator, .backend = desc.backend };
    }

    pub fn deinit(self: *Context) void {
        _ = self;
    }
};

pub const SurfaceDesc = struct {
    logical_size: Size,
    scale: f32 = 1.0,
};

pub const Surface = struct {
    logical: Size,
    scale: f32,

    pub fn init(desc: SurfaceDesc) !Surface {
        if (!(desc.scale > 0.0)) return Result.InvalidArgument;
        return .{ .logical = desc.logical_size, .scale = desc.scale };
    }
};

pub const Encoder = @import("encoder.zig").Encoder;

/// Low-level client API: Connection, Surface, Event. Use these
/// directly when the App framework's fixed-size up-front surface
/// doesn't fit (e.g. when sizing the surface to the framebuffer
/// queried via queryOutputInfo). For most apps, prefer App.
pub const client = @import("semadraw_client");

/// ADR 0021 Section 8: the control-interface wire contract, exported
/// for the session authority (pgsd-sessiond) which is the only
/// legitimate client of the control socket. A file import within the
/// module, deliberately not a named build module here: the contract
/// travels with the semadraw dependency sessiond already has.
pub const control = @import("ipc/control.zig");

/// High-level application framework. Wraps connection, surface, encoder,
/// and event loop. See src/app.zig for usage.
pub const App     = @import("app.zig").App;
pub const AppDesc = @import("app.zig").AppDesc;
pub const AppEvent = @import("app.zig").Event;
