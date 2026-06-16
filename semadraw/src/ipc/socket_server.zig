const std = @import("std");
const posix = std.posix;
const compat = @import("compat");

// Owned raw-posix idioms for the descriptor verbs std.posix dropped in 0.16.
// The socket family routes through compat.posix; write/close are local.
fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

fn writeOnce(fd: posix.fd_t, bytes: []const u8) !usize {
    const rc = posix.system.write(fd, bytes.ptr, bytes.len);
    if (rc < 0) {
        if (posix.errno(rc) == .AGAIN) return error.WouldBlock;
        return error.WriteFailed;
    }
    return @intCast(rc);
}
const protocol = @import("protocol");

/// Unix domain socket server for semadrawd
pub const SocketServer = struct {
    fd: posix.socket_t,
    path: []const u8,

    pub const AcceptError = posix.AcceptError || error{Unexpected};

    /// Bind and listen on a Unix domain socket.
    ///
    /// If `path` already exists, this function distinguishes between two
    /// cases by attempting a connect() to the path:
    ///   - Connect succeeds: another daemon is already alive and listening.
    ///     Returns error.AlreadyRunning. The new instance MUST exit; if it
    ///     proceeded by deleting the existing file and rebinding, the old
    ///     instance's listening fd would survive in the kernel but its
    ///     socket name would now resolve to the new instance, leaving the
    ///     old daemon a zombie listener (clients connect to the new one
    ///     but the old one still consumes resources and produces logs).
    ///     This was a real bug observed in pre-fix testing where multiple
    ///     semadrawds accumulated across debug sessions.
    ///   - Connect fails (ECONNREFUSED / no such file): the file is stale
    ///     from a previous instance that exited without unlinking. Safe
    ///     to delete and rebind.
    pub fn bind(path: []const u8) !SocketServer {
        // Build the sockaddr once; both the probe connect and the real
        // bind use it.
        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        if (path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;
        const addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un);

        // Probe: is anything currently listening at this path?
        const probe = compat.posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
            return err;
        };
        const connect_result = compat.posix.connect(probe, @ptrCast(&addr), addr_len);
        closeFd(probe);

        // Treat ANY connect failure as "no live listener, safe to proceed."
        // The most common reasons for a probe connect to fail are:
        //   - ENOENT: no such path (the file was unlinked or never existed)
        //   - ECONNREFUSED: file exists but no one is listen()ing
        //   - EACCES: file exists with wrong permissions (still no listener)
        // None of these warrant refusing to start. Only a *successful*
        // connect indicates another daemon is alive.
        //
        // The choice to broaden rather than narrow is deliberate: a false
        // negative (treating an unusual failure as "no listener" when one
        // exists) is recoverable, bind() will then fail with EADDRINUSE,
        // which propagates cleanly. A false positive (failing to start
        // because the probe encountered an unfamiliar error) would be a
        // nuisance bug. Better to err toward "let bind() decide."
        if (connect_result) |_| {
            return error.AlreadyRunning;
        } else |_| {
            // No listener. Fall through to delete-and-rebind.
        }

        // Create the listening socket.
        const fd = try compat.posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer closeFd(fd);

        // Remove the stale file if it exists (after the probe confirmed
        // no live listener). FileNotFound is fine; other errors propagate.
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        try compat.posix.bind(fd, @ptrCast(&addr), addr_len);

        // Set socket permissions (owner+group read/write)
        // Mode 0660 = rw-rw----
        if (posix.toPosixPath(path)) |pathz| {
            _ = posix.system.fchmodat(posix.AT.FDCWD, &pathz, 0o660, 0);
        } else |_| {}

        // Listen with reasonable backlog
        try compat.posix.listen(fd, 16);

        return .{
            .fd = fd,
            .path = path,
        };
    }

    /// Accept a new client connection
    pub fn accept(self: *SocketServer) AcceptError!posix.socket_t {
        const client_fd = try compat.posix.accept(self.fd, null, null, posix.SOCK.CLOEXEC);
        return client_fd;
    }

    /// Get the file descriptor for use with kqueue/poll
    pub fn getFd(self: *SocketServer) posix.socket_t {
        return self.fd;
    }

    /// Close the server socket and remove the socket file
    pub fn deinit(self: *SocketServer) void {
        closeFd(self.fd);
        std.fs.cwd().deleteFile(self.path) catch {};
    }
};

/// Client connection wrapper with buffered I/O
pub const ClientSocket = struct {
    fd: posix.socket_t,
    recv_buf: [8192]u8,
    recv_len: usize,
    large_buf: ?[]u8, // Dynamically allocated buffer for large messages
    large_buf_len: usize,
    allocator: ?std.mem.Allocator,

    pub fn init(fd: posix.socket_t) ClientSocket {
        return .{
            .fd = fd,
            .recv_buf = undefined,
            .recv_len = 0,
            .large_buf = null,
            .large_buf_len = 0,
            .allocator = null,
        };
    }

    /// Read a complete message (header + payload)
    /// Returns null if not enough data available yet
    pub fn readMessage(self: *ClientSocket, allocator: std.mem.Allocator) !?Message {
        self.allocator = allocator;

        // If we're in the middle of reading a large message, continue reading into large_buf
        if (self.large_buf) |buf| {
            return self.readLargeMessage(buf);
        }

        // Try to read more data into small buffer
        const space = self.recv_buf.len - self.recv_len;
        if (space > 0) {
            const n = posix.read(self.fd, self.recv_buf[self.recv_len..]) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            if (n == 0 and self.recv_len == 0) return error.ConnectionClosed;
            self.recv_len += n;
        }

        // Check if we have a complete header
        if (self.recv_len < protocol.MsgHeader.SIZE) return null;

        const header = try protocol.MsgHeader.deserialize(self.recv_buf[0..protocol.MsgHeader.SIZE]);
        const total_len = protocol.MsgHeader.SIZE + header.length;

        // Check if message fits in small buffer
        if (total_len <= self.recv_buf.len) {
            // Check if we have the complete message
            if (self.recv_len < total_len) return null;

            // Extract payload
            var payload: ?[]u8 = null;
            if (header.length > 0) {
                payload = try allocator.alloc(u8, header.length);
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

        // Large message - allocate buffer and copy what we have
        const large_buf = try allocator.alloc(u8, total_len);
        @memcpy(large_buf[0..self.recv_len], self.recv_buf[0..self.recv_len]);
        self.large_buf = large_buf;
        self.large_buf_len = self.recv_len;
        self.recv_len = 0;

        return self.readLargeMessage(large_buf);
    }

    /// Continue reading a large message
    fn readLargeMessage(self: *ClientSocket, buf: []u8) !?Message {
        const allocator = self.allocator orelse return error.Unexpected;

        // Read more data
        if (self.large_buf_len < buf.len) {
            const n = posix.read(self.fd, buf[self.large_buf_len..]) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => {
                    allocator.free(buf);
                    self.large_buf = null;
                    self.large_buf_len = 0;
                    return err;
                },
            };
            if (n == 0) {
                allocator.free(buf);
                self.large_buf = null;
                self.large_buf_len = 0;
                return error.ConnectionClosed;
            }
            self.large_buf_len += n;
        }

        // Check if complete
        if (self.large_buf_len < buf.len) return null;

        // Parse header
        const header = try protocol.MsgHeader.deserialize(buf[0..protocol.MsgHeader.SIZE]);

        // Extract payload
        var payload: ?[]u8 = null;
        if (header.length > 0) {
            payload = try allocator.alloc(u8, header.length);
            @memcpy(payload.?, buf[protocol.MsgHeader.SIZE..]);
        }

        // Free large buffer
        allocator.free(buf);
        self.large_buf = null;
        self.large_buf_len = 0;

        return .{
            .header = header,
            .payload = payload,
        };
    }

    /// Send a message
    pub fn sendMessage(self: *ClientSocket, msg_type: protocol.MsgType, payload: []const u8) !void {
        const header = protocol.MsgHeader{
            .msg_type = msg_type,
            .flags = 0,
            .length = @intCast(payload.len),
        };

        var hdr_buf: [protocol.MsgHeader.SIZE]u8 = undefined;
        header.serialize(&hdr_buf);

        // Send header. AD-46 hardening: a short write (possible under
        // signal interruption) leaves the stream corrupt mid-frame, so
        // it is surfaced as an error and the caller's existing error
        // path disconnects the client instead of corrupting silently.
        const hn = try writeOnce(self.fd, &hdr_buf);
        if (hn != hdr_buf.len) return error.PartialWrite;

        // Send payload
        if (payload.len > 0) {
            const pn = try writeOnce(self.fd, payload);
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
    pub fn trySendMessage(self: *ClientSocket, msg_type: protocol.MsgType, payload: []const u8) TrySendResult {
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

        const n = compat.posix.send(self.fd, frame[0..total], posix.MSG.DONTWAIT) catch |e| switch (e) {
            error.WouldBlock => return .would_block,
            else => return .err,
        };
        if (n == total) return .sent;
        return .partial;
    }

    /// Send a message with a file descriptor (SCM_RIGHTS)
    pub fn sendMessageWithFd(self: *ClientSocket, msg_type: protocol.MsgType, payload: []const u8, fd_to_send: posix.fd_t) !void {
        const header = protocol.MsgHeader{
            .msg_type = msg_type,
            .flags = 0,
            .length = @intCast(payload.len),
        };

        var hdr_buf: [protocol.MsgHeader.SIZE]u8 = undefined;
        header.serialize(&hdr_buf);

        // Combine header and payload for sendmsg
        var iov = [_]posix.iovec_const{
            .{ .base = &hdr_buf, .len = hdr_buf.len },
            .{ .base = payload.ptr, .len = payload.len },
        };

        // Set up control message for SCM_RIGHTS
        var cmsg_buf: [posix.CMSG_SPACE(@sizeOf(posix.fd_t))]u8 align(@alignOf(posix.cmsghdr)) = undefined;
        const cmsg: *posix.cmsghdr = @ptrCast(&cmsg_buf);
        cmsg.level = posix.SOL.SOCKET;
        cmsg.type = posix.SCM.RIGHTS;
        cmsg.len = posix.CMSG_LEN(@sizeOf(posix.fd_t));

        const fd_ptr: *posix.fd_t = @ptrCast(@alignCast(posix.CMSG_DATA(cmsg)));
        fd_ptr.* = fd_to_send;

        var msg = posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &cmsg_buf,
            .controllen = cmsg_buf.len,
            .flags = 0,
        };

        _ = try posix.sendmsg(self.fd, &msg, 0);
    }

    /// Receive a message that may include a file descriptor
    pub fn recvMessageWithFd(self: *ClientSocket, allocator: std.mem.Allocator) !?MessageWithFd {
        // For simplicity, we'll handle this when we have a complete message
        const maybe_msg = try self.readMessage(allocator);
        if (maybe_msg) |msg| {
            // TODO: Implement fd receiving via recvmsg when needed
            return .{
                .message = msg,
                .fd = null,
            };
        }
        return null;
    }

    pub fn close(self: *ClientSocket) void {
        // Free any pending large buffer
        if (self.large_buf) |buf| {
            if (self.allocator) |alloc| {
                alloc.free(buf);
            }
        }
        self.large_buf = null;
        self.large_buf_len = 0;
        closeFd(self.fd);
    }

    pub fn getFd(self: *ClientSocket) posix.socket_t {
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

/// Message with optional file descriptor
pub const MessageWithFd = struct {
    message: Message,
    fd: ?posix.fd_t,

    pub fn deinit(self: *MessageWithFd, allocator: std.mem.Allocator) void {
        self.message.deinit(allocator);
        if (self.fd) |f| closeFd(f);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SocketServer can be created with temp path" {
    const path = "/tmp/semadraw_test.sock";
    var server = try SocketServer.bind(path);
    defer server.deinit();

    try std.testing.expect(server.fd >= 0);
}

test "ClientSocket message serialization" {
    // This is a unit test for the message format, not actual socket I/O
    var buf: [protocol.MsgHeader.SIZE + protocol.HelloMsg.SIZE]u8 = undefined;

    const header = protocol.MsgHeader{
        .msg_type = .hello,
        .flags = 0,
        .length = protocol.HelloMsg.SIZE,
    };
    header.serialize(buf[0..protocol.MsgHeader.SIZE]);

    const hello = protocol.HelloMsg.init();
    hello.serialize(buf[protocol.MsgHeader.SIZE..]);

    // Verify header
    const decoded_hdr = try protocol.MsgHeader.deserialize(&buf);
    try std.testing.expectEqual(protocol.MsgType.hello, decoded_hdr.msg_type);
    try std.testing.expectEqual(@as(u32, protocol.HelloMsg.SIZE), decoded_hdr.length);
}
