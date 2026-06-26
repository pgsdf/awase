const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");

const log = std.log.scoped(.remote_connection);

/// Remote connection to semadrawd over TCP
pub const RemoteConnection = struct {
    allocator: std.mem.Allocator,
    fd: posix.socket_t,
    client_id: protocol.ClientId,
    recv_buf: [65536]u8,
    recv_len: usize,

    const Self = @This();

    /// Connect to a remote semadrawd instance
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Create socket
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        // Parse host address
        var addr_bytes: [4]u8 = undefined;
        var part_idx: usize = 0;
        var iter = std.mem.splitScalar(u8, host, '.');
        while (iter.next()) |part| {
            if (part_idx >= 4) return error.InvalidAddress;
            addr_bytes[part_idx] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
            part_idx += 1;
        }
        if (part_idx != 4) return error.InvalidAddress;

        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.bytesToValue(u32, &addr_bytes),
            .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        };

        try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

        self.* = .{
            .allocator = allocator,
            .fd = fd,
            .client_id = 0,
            .recv_buf = undefined,
            .recv_len = 0,
        };

        // Perform handshake
        try self.handshake();

        log.info("connected to {s}:{} as client {}", .{ host, port, self.client_id });

        return self;
    }

    /// Connect using default port
    pub fn connectDefault(allocator: std.mem.Allocator, host: []const u8) !*Self {
        return connect(allocator, host, protocol.DEFAULT_TCP_PORT);
    }

    pub fn disconnect(self: *Self) void {
        // Send disconnect message
        self.sendMessage(.disconnect, &.{}) catch {};
        posix.close(self.fd);
        self.allocator.destroy(self);
    }

    fn handshake(self: *Self) !void {
        // Send hello
        var hello_buf: [protocol.HelloMsg.SIZE]u8 = undefined;
        const hello = protocol.HelloMsg.init();
        hello.serialize(&hello_buf);
        try self.sendMessage(.hello, &hello_buf);

        // Wait for reply
        const reply = try self.recvMessage();
        defer if (reply.payload) |p| self.allocator.free(p);

        if (reply.header.msg_type != .hello_reply) {
            return error.ProtocolError;
        }

        if (reply.payload == null or reply.payload.?.len < protocol.HelloReplyMsg.SIZE) {
            return error.InvalidPayload;
        }

        const hello_reply = try protocol.HelloReplyMsg.deserialize(reply.payload.?);

        if (hello_reply.version_major != protocol.PROTOCOL_VERSION_MAJOR) {
            return error.VersionMismatch;
        }

        self.client_id = hello_reply.client_id;
    }

    fn sendMessage(self: *Self, msg_type: protocol.MsgType, payload: []const u8) !void {
        const header = protocol.MsgHeader{
            .msg_type = msg_type,
            .flags = 0,
            .length = @intCast(payload.len),
        };

        var hdr_buf: [protocol.MsgHeader.SIZE]u8 = undefined;
        header.serialize(&hdr_buf);

        _ = try posix.write(self.fd, &hdr_buf);
        if (payload.len > 0) {
            _ = try posix.write(self.fd, payload);
        }
    }

    fn recvMessage(self: *Self) !Message {
        // Read until we have a complete message
        while (true) {
            // Check if we have a complete header
            if (self.recv_len >= protocol.MsgHeader.SIZE) {
                const header = try protocol.MsgHeader.deserialize(self.recv_buf[0..protocol.MsgHeader.SIZE]);
                const total_len = protocol.MsgHeader.SIZE + header.length;

                if (self.recv_len >= total_len) {
                    // Extract payload
                    var payload: ?[]u8 = null;
                    if (header.length > 0) {
                        payload = try self.allocator.alloc(u8, header.length);
                        @memcpy(payload.?, self.recv_buf[protocol.MsgHeader.SIZE..total_len]);
                    }

                    // Shift remaining data
                    if (self.recv_len > total_len) {
                        std.mem.copyForwards(u8, self.recv_buf[0..], self.recv_buf[total_len..self.recv_len]);
                    }
                    self.recv_len -= total_len;

                    return .{
                        .header = header,
                        .payload = payload,
                    };
                }
            }

            // Need more data
            const space = self.recv_buf.len - self.recv_len;
            if (space == 0) return error.MessageTooLarge;

            const n = try posix.read(self.fd, self.recv_buf[self.recv_len..]);
            if (n == 0) return error.ConnectionClosed;
            self.recv_len += n;
        }
    }

    /// Create a new surface
    pub fn createSurface(self: *Self, width: f32, height: f32) !protocol.SurfaceId {
        var msg_buf: [protocol.CreateSurfaceMsg.SIZE]u8 = undefined;
        const msg = protocol.CreateSurfaceMsg{
            .logical_width = width,
            .logical_height = height,
            .scale = 1.0,
            .flags = 0,
        };
        msg.serialize(&msg_buf);
        try self.sendMessage(.create_surface, &msg_buf);

        const reply = try self.recvMessage();
        defer if (reply.payload) |p| self.allocator.free(p);

        if (reply.header.msg_type == .error_reply) {
            return error.ServerError;
        }

        if (reply.header.msg_type != .surface_created) {
            return error.UnexpectedResponse;
        }

        if (reply.payload == null or reply.payload.?.len < protocol.SurfaceCreatedMsg.SIZE) {
            return error.InvalidPayload;
        }

        const created = try protocol.SurfaceCreatedMsg.deserialize(reply.payload.?);
        return created.surface_id;
    }

    /// Destroy a surface
    pub fn destroySurface(self: *Self, surface_id: protocol.SurfaceId) !void {
        var msg_buf: [protocol.DestroySurfaceMsg.SIZE]u8 = undefined;
        const msg = protocol.DestroySurfaceMsg{ .surface_id = surface_id };
        msg.serialize(&msg_buf);
        try self.sendMessage(.destroy_surface, &msg_buf);
    }

    /// Attach SDCS data to a surface (inline, for remote connections)
    pub fn attachBufferInline(self: *Self, surface_id: protocol.SurfaceId, sdcs_data: []const u8) !void {
        // Build message with header + SDCS data
        const msg_len = protocol.AttachBufferInlineMsg.HEADER_SIZE + sdcs_data.len;
        const msg_buf = try self.allocator.alloc(u8, msg_len);
        defer self.allocator.free(msg_buf);

        const msg = protocol.AttachBufferInlineMsg{
            .surface_id = surface_id,
            .sdcs_length = @intCast(sdcs_data.len),
            .flags = 0,
        };
        msg.serialize(msg_buf[0..protocol.AttachBufferInlineMsg.HEADER_SIZE]);
        @memcpy(msg_buf[protocol.AttachBufferInlineMsg.HEADER_SIZE..], sdcs_data);

        try self.sendMessage(.attach_buffer_inline, msg_buf);
    }

    /// Commit a surface and wait for frame complete
    pub fn commit(self: *Self, surface_id: protocol.SurfaceId) !u64 {
        var msg_buf: [protocol.CommitMsg.SIZE]u8 = undefined;
        const msg = protocol.CommitMsg{ .surface_id = surface_id, .flags = 0 };
        msg.serialize(&msg_buf);
        try self.sendMessage(.commit, &msg_buf);

        const reply = try self.recvMessage();
        defer if (reply.payload) |p| self.allocator.free(p);

        if (reply.header.msg_type == .error_reply) {
            return error.ServerError;
        }

        if (reply.header.msg_type != .frame_complete) {
            return error.UnexpectedResponse;
        }

        if (reply.payload == null or reply.payload.?.len < protocol.FrameCompleteMsg.SIZE) {
            return error.InvalidPayload;
        }

        const frame = try protocol.FrameCompleteMsg.deserialize(reply.payload.?);
        return frame.frame_number;
    }

    /// Set surface visibility
    pub fn setVisible(self: *Self, surface_id: protocol.SurfaceId, visible: bool) !void {
        var msg_buf: [protocol.SetVisibleMsg.SIZE]u8 = undefined;
        const msg = protocol.SetVisibleMsg{
            .surface_id = surface_id,
            .visible = if (visible) 1 else 0,
        };
        msg.serialize(&msg_buf);
        try self.sendMessage(.set_visible, &msg_buf);
    }

    /// Set surface z-order
    pub fn setZOrder(self: *Self, surface_id: protocol.SurfaceId, z_order: i32) !void {
        var msg_buf: [protocol.SetZOrderMsg.SIZE]u8 = undefined;
        const msg = protocol.SetZOrderMsg{
            .surface_id = surface_id,
            .z_order = z_order,
        };
        msg.serialize(&msg_buf);
        try self.sendMessage(.set_z_order, &msg_buf);
    }

    /// Assign keyboard focus to a surface (D-7, ADR 0011). Privileged
    /// clients only; surface_id 0 clears focus. Fire-and-forget; observe
    /// focus_changed events for the resulting transition.
    pub fn setFocus(self: *Self, surface_id: protocol.SurfaceId) !void {
        var msg_buf: [protocol.SetFocusMsg.SIZE]u8 = undefined;
        const msg = protocol.SetFocusMsg{ .surface_id = surface_id };
        msg.serialize(&msg_buf);
        try self.sendMessage(.set_focus, &msg_buf);
    }

    /// Synchronization barrier
    pub fn sync(self: *Self) !void {
        var msg_buf: [protocol.SyncMsg.SIZE]u8 = undefined;
        const msg = protocol.SyncMsg{ .sync_id = 0 };
        msg.serialize(&msg_buf);
        try self.sendMessage(.sync, &msg_buf);

        const reply = try self.recvMessage();
        defer if (reply.payload) |p| self.allocator.free(p);

        if (reply.header.msg_type != .sync_done) {
            return error.UnexpectedResponse;
        }
    }

    /// Output info (framebuffer dimensions for a given output).
    pub const OutputInfo = struct {
        output_id: u32,
        width: u32,
        height: u32,
    };

    /// AD-26 follow-up: query the daemon for an output's dimensions.
    /// TCP counterpart to Connection.queryOutputInfo (see that
    /// function's comment for the rationale). Returns error.NoOutput
    /// if the daemon replies with ERROR_REPLY (either the requested
    /// output_id does not exist, or the daemon has no output
    /// initialised yet).
    pub fn queryOutputInfo(self: *Self, output_id: u32) !OutputInfo {
        var msg_buf: [protocol.OutputInfoRequestMsg.SIZE]u8 = undefined;
        const msg = protocol.OutputInfoRequestMsg{ .output_id = output_id };
        msg.serialize(&msg_buf);
        try self.sendMessage(.output_info_request, &msg_buf);

        const reply = try self.recvMessage();
        defer if (reply.payload) |p| self.allocator.free(p);

        switch (reply.header.msg_type) {
            .output_info_reply => {
                const p = reply.payload orelse return error.ProtocolError;
                const r = try protocol.OutputInfoReplyMsg.deserialize(p);
                if (r.output_id != output_id) return error.ProtocolError;
                return .{
                    .output_id = r.output_id,
                    .width = r.width,
                    .height = r.height,
                };
            },
            .error_reply => {
                return error.NoOutput;
            },
            else => return error.UnexpectedResponse,
        }
    }
};

const Message = struct {
    header: protocol.MsgHeader,
    payload: ?[]u8,
};

// ============================================================================
// Tests
// ============================================================================

test "RemoteConnection address parsing" {
    // Test invalid addresses (we can't test actual connection without a server)
    const allocator = std.testing.allocator;

    // Invalid address format
    const result = RemoteConnection.connect(allocator, "invalid", 1234);
    try std.testing.expectError(error.InvalidAddress, result);

    // Too few octets
    const result2 = RemoteConnection.connect(allocator, "192.168.1", 1234);
    try std.testing.expectError(error.InvalidAddress, result2);
}
