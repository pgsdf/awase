const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");
const Connection = @import("connection").Connection;

/// Surface state
pub const SurfaceState = enum {
    /// Surface is valid and ready for use
    ready,
    /// Surface has pending content awaiting commit
    pending,
    /// Surface is being presented
    presenting,
    /// Surface was destroyed
    destroyed,
};

/// Frame callback for animation
pub const FrameCallback = *const fn (surface: *Surface, frame_number: u64, timestamp_ns: u64) void;

/// Surface wrapper for easier client usage
pub const Surface = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    id: protocol.SurfaceId,
    width: f32,
    height: f32,
    scale: f32,
    state: SurfaceState,
    visible: bool,
    z_order: i32,
    frame_count: u64,
    frame_callback: ?FrameCallback,
    user_data: ?*anyopaque,

    const Self = @This();

    /// Create a new surface
    pub fn create(connection: *Connection, width: f32, height: f32) !*Self {
        return createWithScale(connection, width, height, 1.0);
    }

    /// Create a new surface with explicit scale
    pub fn createWithScale(connection: *Connection, width: f32, height: f32, scale: f32) !*Self {
        const allocator = connection.allocator;

        const surface_id = try connection.createSurfaceWithScale(width, height, scale);

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .connection = connection,
            .id = surface_id,
            .width = width,
            .height = height,
            .scale = scale,
            .state = .ready,
            .visible = false,
            .z_order = 0,
            .frame_count = 0,
            .frame_callback = null,
            .user_data = null,
        };

        return self;
    }

    /// Destroy the surface
    pub fn destroy(self: *Self) void {
        if (self.state != .destroyed) {
            self.connection.destroySurface(self.id) catch {};
            self.state = .destroyed;
        }
        self.allocator.destroy(self);
    }

    /// Commit surface contents
    pub fn commit(self: *Self) !void {
        if (self.state == .destroyed) return error.SurfaceDestroyed;

        try self.connection.commit(self.id);
        self.state = .presenting;
        self.frame_count += 1;
    }

    /// Attach SDCS buffer data and commit in one operation
    pub fn attachAndCommit(self: *Self, sdcs_data: []const u8) !void {
        if (self.state == .destroyed) return error.SurfaceDestroyed;

        try self.connection.attachBufferInline(self.id, sdcs_data);
        try self.connection.commit(self.id);
        self.state = .presenting;
        self.frame_count += 1;
    }

    /// Set visibility
    pub fn setVisible(self: *Self, visible: bool) !void {
        if (self.state == .destroyed) return error.SurfaceDestroyed;

        try self.connection.setVisible(self.id, visible);
        self.visible = visible;
    }

    /// Show the surface (shorthand for setVisible(true))
    pub fn show(self: *Self) !void {
        try self.setVisible(true);
    }

    /// Hide the surface (shorthand for setVisible(false))
    pub fn hide(self: *Self) !void {
        try self.setVisible(false);
    }

    /// Set z-order (stacking order)
    pub fn setZOrder(self: *Self, z_order: i32) !void {
        if (self.state == .destroyed) return error.SurfaceDestroyed;

        try self.connection.setZOrder(self.id, z_order);
        self.z_order = z_order;
    }

    /// Set position (in pixels)
    pub fn setPosition(self: *Self, x: f32, y: f32) !void {
        if (self.state == .destroyed) return error.SurfaceDestroyed;

        try self.connection.setPosition(self.id, x, y);
    }

    /// Set frame callback for animation
    pub fn setFrameCallback(self: *Self, callback: ?FrameCallback) void {
        self.frame_callback = callback;
    }

    /// Set user data pointer
    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        self.user_data = data;
    }

    /// Get user data pointer
    pub fn getUserData(self: *Self) ?*anyopaque {
        return self.user_data;
    }

    /// Get typed user data
    pub fn getUserDataAs(self: *Self, comptime T: type) ?*T {
        if (self.user_data) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }

    /// Handle frame complete event
    pub fn onFrameComplete(self: *Self, frame_number: u64, timestamp_ns: u64) void {
        self.state = .ready;
        if (self.frame_callback) |cb| {
            cb(self, frame_number, timestamp_ns);
        }
    }

    /// Get surface ID
    pub fn getId(self: *const Self) protocol.SurfaceId {
        return self.id;
    }

    /// Get surface dimensions
    pub fn getSize(self: *const Self) struct { width: f32, height: f32 } {
        return .{ .width = self.width, .height = self.height };
    }

    /// Get pixel dimensions (accounting for scale)
    pub fn getPixelSize(self: *const Self) struct { width: u32, height: u32 } {
        return .{
            .width = @intFromFloat(self.width * self.scale),
            .height = @intFromFloat(self.height * self.scale),
        };
    }

    /// Check if surface is visible
    pub fn isVisible(self: *const Self) bool {
        return self.visible;
    }

    /// Check if surface is ready for new content
    pub fn isReady(self: *const Self) bool {
        return self.state == .ready;
    }

    /// Get frame count
    pub fn getFrameCount(self: *const Self) u64 {
        return self.frame_count;
    }
};

/// Surface manager for tracking multiple surfaces
pub const SurfaceManager = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    surfaces: std.AutoHashMap(protocol.SurfaceId, *Surface),

    const Self = @This();

    pub fn init(connection: *Connection) Self {
        return .{
            .allocator = connection.allocator,
            .connection = connection,
            .surfaces = std.AutoHashMap(protocol.SurfaceId, *Surface).init(connection.allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Destroy all surfaces
        var it = self.surfaces.valueIterator();
        while (it.next()) |surface| {
            surface.*.destroy();
        }
        self.surfaces.deinit();
    }

    /// Create and track a new surface
    pub fn createSurface(self: *Self, width: f32, height: f32) !*Surface {
        const surface = try Surface.create(self.connection, width, height);
        try self.surfaces.put(surface.id, surface);
        return surface;
    }

    /// Destroy and untrack a surface
    pub fn destroySurface(self: *Self, surface: *Surface) void {
        _ = self.surfaces.remove(surface.id);
        surface.destroy();
    }

    /// Get surface by ID
    pub fn getSurface(self: *Self, id: protocol.SurfaceId) ?*Surface {
        return self.surfaces.get(id);
    }

    /// Process events and dispatch to surfaces
    pub fn processEvents(self: *Self) !void {
        while (try self.connection.poll()) |event| {
            switch (event) {
                .frame_complete => |fc| {
                    if (self.surfaces.get(fc.surface_id)) |surface| {
                        surface.onFrameComplete(fc.frame_number, fc.timestamp_ns);
                    }
                },
                .disconnected => return error.Disconnected,
                else => {},
            }
        }
    }

    /// Get number of tracked surfaces
    pub fn count(self: *const Self) usize {
        return self.surfaces.count();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Surface struct size" {
    try std.testing.expect(@sizeOf(Surface) > 0);
}

test "SurfaceManager struct size" {
    try std.testing.expect(@sizeOf(SurfaceManager) > 0);
}
