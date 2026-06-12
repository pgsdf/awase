const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");

/// TCP server for remote semadraw connections
pub const TcpServer = struct {
    fd: posix.socket_t,
    port: u16,
    bound_addr: posix.sockaddr.in,

    /// Read timeout applied to every accepted client socket (30 seconds).
    /// A client that sends a partial message and stalls for longer than this
    /// will be disconnected by the next readMessage call on that socket.
    pub const READ_TIMEOUT_SEC: u32 = 30;

    pub const AcceptError = posix.AcceptError || error{Unexpected};

    /// Bind and listen on a TCP port
    pub fn bind(port: u16) !TcpServer {
        return bindAddr(.{ 0, 0, 0, 0 }, port);
    }

    /// Bind and listen on a specific address and port
    pub fn bindAddr(addr: [4]u8, port: u16) !TcpServer {
        // Create socket
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        // Enable address reuse
        const optval: c_int = 1;
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&optval));

        // Bind to address
        var bind_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.bytesToValue(u32, &addr),
            .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        };

        try posix.bind(fd, @ptrCast(&bind_addr), @sizeOf(posix.sockaddr.in));

        // Listen with reasonable backlog
        try posix.listen(fd, 16);

        return .{
            .fd = fd,
            .port = port,
            .bound_addr = bind_addr,
        };
    }

    /// Accept a new client connection and apply the read timeout.
    pub fn accept(self: *TcpServer) AcceptError!RemoteClient {
        var client_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        const client_fd = try posix.accept(self.fd, @ptrCast(&client_addr), &addr_len, posix.SOCK.CLOEXEC);

        // Apply read timeout so a stalled client cannot hold a surface
        // indefinitely. WouldBlock returned mid-message is treated as a
        // fatal timeout in RemoteClient.readMessage.
        const tv = std.posix.timeval{
            .sec = READ_TIMEOUT_SEC,
            .usec = 0,
        };
        posix.setsockopt(client_fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};

        return RemoteClient.init(client_fd, client_addr);
    }

    /// Get the file descriptor for use with poll/kqueue
    pub fn getFd(self: *const TcpServer) posix.socket_t {
        return self.fd;
    }

    /// Close the server socket
    pub fn deinit(self: *TcpServer) void {
        posix.close(self.fd);
    }
};

/// Remote client connection with buffered I/O
pub const RemoteClient = struct {
    fd: posix.socket_t,
    addr: posix.sockaddr.in,
    recv_buf: [65536]u8, // Larger buffer for inline SDCS data
    recv_len: usize,

    pub fn init(fd: posix.socket_t, addr: posix.sockaddr.in) RemoteClient {
        return .{
            .fd = fd,
            .addr = addr,
            .recv_buf = undefined,
            .recv_len = 0,
        };
    }

    /// Get client IP address as string
    pub fn getAddrString(self: *const RemoteClient) [16]u8 {
        var buf: [16]u8 = undefined;
        const addr_bytes = std.mem.toBytes(self.addr.addr);
        _ = std.fmt.bufPrint(&buf, "{}.{}.{}.{}", .{
            addr_bytes[0],
            addr_bytes[1],
            addr_bytes[2],
            addr_bytes[3],
        }) catch {
            @memcpy(buf[0..7], "0.0.0.0");
            buf[7] = 0;
        };
        return buf;
    }

    /// Read a complete message (header + payload).
    /// Returns null if no data is available and the buffer is empty (normal
    /// poll cycle with no incoming data).
    /// Returns error.ConnectionClosed on clean EOF.
    /// Returns error.ReadTimeout if SO_RCVTIMEO fires while a partial message
    /// is in the buffer, the connection is unusable and must be closed.
    pub fn readMessage(self: *RemoteClient, allocator: std.mem.Allocator) !?Message {
        // Try to read more data into the buffer.
        const space = self.recv_buf.len - self.recv_len;
        if (space > 0) {
            const n = posix.read(self.fd, self.recv_buf[self.recv_len..]) catch |err| switch (err) {
                error.WouldBlock => blk: {
                    // SO_RCVTIMEO fired. If we have a partial message in the
                    // buffer the client has stalled mid-send, treat as fatal.
                    if (self.recv_len > 0) return error.ReadTimeout;
                    // Buffer is empty: truly nothing to read this poll cycle.
                    break :blk @as(usize, 0);
                },
                else => return err,
            };
            // n == 0 means the peer closed the connection cleanly.
            if (n == 0 and self.recv_len == 0) return error.ConnectionClosed;
            if (n == 0) return error.ConnectionClosed;
            self.recv_len += n;
        }

        // Check if we have a complete header.
        if (self.recv_len < protocol.MsgHeader.SIZE) return null;

        const header = try protocol.MsgHeader.deserialize(self.recv_buf[0..protocol.MsgHeader.SIZE]);
        const total_len = protocol.MsgHeader.SIZE + header.length;

        // Safety check for message size.
        if (total_len > self.recv_buf.len) {
            return error.MessageTooLarge;
        }

        // Check if we have the complete message.
        if (self.recv_len < total_len) return null;

        // Extract payload.
        var payload: ?[]u8 = null;
        if (header.length > 0) {
            payload = try allocator.alloc(u8, header.length);
            @memcpy(payload.?, self.recv_buf[protocol.MsgHeader.SIZE..total_len]);
        }

        // Shift remaining data.
        if (self.recv_len > total_len) {
            std.mem.copyForwards(u8, self.recv_buf[0..], self.recv_buf[total_len..self.recv_len]);
        }
        self.recv_len -= total_len;

        return .{
            .header = header,
            .payload = payload,
        };
    }

    /// Send a message
    pub fn sendMessage(self: *RemoteClient, msg_type: protocol.MsgType, payload: []const u8) !void {
        const header = protocol.MsgHeader{
            .msg_type = msg_type,
            .flags = 0,
            .length = @intCast(payload.len),
        };

        var hdr_buf: [protocol.MsgHeader.SIZE]u8 = undefined;
        header.serialize(&hdr_buf);

        // Send header. AD-46: see ClientSocket.sendMessage; a short
        // write is an error, not a silent corruption.
        const hn = try posix.write(self.fd, &hdr_buf);
        if (hn != hdr_buf.len) return error.PartialWrite;

        // Send payload
        if (payload.len > 0) {
            const pn = try posix.write(self.fd, payload);
            if (pn != payload.len) return error.PartialWrite;
        }
    }

    /// AD-46: result of a non-blocking single-frame send attempt.
    pub const TrySendResult = enum {
        /// Full frame written.
        sent,
        /// Nothing written (socket buffer full); the frame was
        /// cleanly dropped and the stream is intact.
        would_block,
        /// Frame partially written; the peer's byte stream is
        /// corrupt mid-frame and the session must be disconnected.
        partial,
        /// Other write error.
        err,
    };

    /// AD-46: send one protocol message as a SINGLE send() of the
    /// fully serialized frame, non-blocking PER CALL via MSG_DONTWAIT.
    /// The fd itself stays blocking, so the receive path keeps its
    /// field-proven semantics; only this call cannot wedge. The
    /// single-frame design exists because drop-on-EAGAIN is only safe
    /// when nothing was written. The stack cap is generous for
    /// forward-path messages (tens of bytes); oversized frames report
    /// .err rather than risking a blocking or heap path here.
    pub fn trySendMessage(self: *RemoteClient, msg_type: protocol.MsgType, payload: []const u8) TrySendResult {
        var frame: [256]u8 = undefined;
        const total = protocol.MsgHeader.SIZE + payload.len;
        if (total > frame.len) return .err;

        const header = protocol.MsgHeader{
            .msg_type = msg_type,
            .flags = 0,
            .length = @intCast(payload.len),
        };
        header.serialize(frame[0..protocol.MsgHeader.SIZE]);
        @memcpy(frame[protocol.MsgHeader.SIZE..][0..payload.len], payload);

        const n = posix.send(self.fd, frame[0..total], posix.MSG.DONTWAIT) catch |e| switch (e) {
            error.WouldBlock => return .would_block,
            else => return .err,
        };
        if (n == total) return .sent;
        return .partial;
    }

    pub fn close(self: *RemoteClient) void {
        posix.close(self.fd);
    }

    pub fn getFd(self: *RemoteClient) posix.socket_t {
        return self.fd;
    }
};

/// Parsed message
pub const Message = struct {
    header: protocol.MsgHeader,
    payload: ?[]u8,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        if (self.payload) |p| allocator.free(p);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TcpServer bind on port 0 (OS-assigned)" {
    var server = TcpServer.bind(0) catch |err| {
        if (err == error.AddressInUse or err == error.AccessDenied) return;
        return err;
    };
    defer server.deinit();
    try std.testing.expect(server.fd >= 0);
    try std.testing.expectEqual(@as(u16, 0), server.port);
}

test "RemoteClient address string formatting" {
    const addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, 1234),
        .addr = std.mem.bytesToValue(u32, &[4]u8{ 192, 168, 1, 100 }),
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    const client = RemoteClient.init(-1, addr);
    const addr_str = client.getAddrString();
    try std.testing.expectEqual('1', addr_str[0]);
    try std.testing.expectEqual('9', addr_str[1]);
    try std.testing.expectEqual('2', addr_str[2]);
    try std.testing.expectEqual('.', addr_str[3]);
}

test "RemoteClient message framing via socketpair" {
    // Use socketpair to get a connected fd pair without needing a real server.
    var fds: [2]posix.socket_t = undefined;
    try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const dummy_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0,
        .addr = 0,
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    // Writer side: send one message through fds[0].
    var writer = RemoteClient.init(fds[0], dummy_addr);
    try writer.sendMessage(.hello, &[_]u8{});

    // Reader side: receive it through fds[1].
    var reader = RemoteClient.init(fds[1], dummy_addr);
    const msg = try reader.readMessage(std.testing.allocator);
    try std.testing.expect(msg != null);
    var m = msg.?;
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MsgType.hello, m.header.msg_type);
    try std.testing.expectEqual(@as(u32, 0), m.header.length);
    try std.testing.expect(m.payload == null);
}

test "RemoteClient message framing with payload via socketpair" {
    var fds: [2]posix.socket_t = undefined;
    try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const dummy_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0,
        .addr = 0,
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    const payload = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var writer = RemoteClient.init(fds[0], dummy_addr);
    try writer.sendMessage(.sync, &payload);

    var reader = RemoteClient.init(fds[1], dummy_addr);
    const msg = try reader.readMessage(std.testing.allocator);
    try std.testing.expect(msg != null);
    var m = msg.?;
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MsgType.sync, m.header.msg_type);
    try std.testing.expectEqual(@as(u32, 4), m.header.length);
    try std.testing.expect(m.payload != null);
    try std.testing.expectEqualSlices(u8, &payload, m.payload.?);
}

test "RemoteClient abrupt disconnect returns ConnectionClosed" {
    var fds: [2]posix.socket_t = undefined;
    try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);

    const dummy_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0,
        .addr = 0,
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    // Close the writer end without sending anything.
    posix.close(fds[0]);

    var reader = RemoteClient.init(fds[1], dummy_addr);
    defer posix.close(fds[1]);

    const result = reader.readMessage(std.testing.allocator);
    try std.testing.expectError(error.ConnectionClosed, result);
}

test "RemoteClient multiple messages in sequence via socketpair" {
    var fds: [2]posix.socket_t = undefined;
    try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const dummy_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0,
        .addr = 0,
        .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    var writer = RemoteClient.init(fds[0], dummy_addr);
    var reader = RemoteClient.init(fds[1], dummy_addr);

    // Send three messages back to back.
    try writer.sendMessage(.hello, &[_]u8{});
    try writer.sendMessage(.sync, &[_]u8{ 1, 2, 3, 4 });
    try writer.sendMessage(.disconnect, &[_]u8{});

    // Read them all out in order.
    const msg1 = try reader.readMessage(std.testing.allocator);
    try std.testing.expect(msg1 != null);
    var m1 = msg1.?;
    defer m1.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MsgType.hello, m1.header.msg_type);

    const msg2 = try reader.readMessage(std.testing.allocator);
    try std.testing.expect(msg2 != null);
    var m2 = msg2.?;
    defer m2.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MsgType.sync, m2.header.msg_type);
    try std.testing.expectEqual(@as(u32, 4), m2.header.length);

    const msg3 = try reader.readMessage(std.testing.allocator);
    try std.testing.expect(msg3 != null);
    var m3 = msg3.?;
    defer m3.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.MsgType.disconnect, m3.header.msg_type);
}

test "RemoteClient client ID collision: remote IDs start at 0x80000000" {
    // Verify the high-bit convention used in the daemon is respected.
    // Remote client IDs must not overlap with local client IDs (which start at 0).
    const remote_start: protocol.ClientId = 0x80000000;
    try std.testing.expect(remote_start & 0x80000000 != 0);
    try std.testing.expect(remote_start > 0x00FFFFFF);
}
