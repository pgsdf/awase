const std = @import("std");
const posix = std.posix;
const compat = @import("compat");
const protocol = @import("protocol");

const log = std.log.scoped(.semadraw_client);

/// Connection state
pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

/// Clipboard data event
pub const ClipboardData = struct {
    selection: protocol.ClipboardSelection,
    data: []const u8,
};

/// Per-variant payload for a parsed gesture event. One arm per
/// GestureType value, decoded from wire bytes by the connection's
/// poll path. The void variants (scroll_begin, scroll_end,
/// pinch_end, three_finger_swipe_end) carry no payload bytes on
/// the wire per the protocol's payloadSize table; they exist as
/// union arms for tag completeness so client `switch` statements
/// stay exhaustive.
///
/// finger_count and modifier flags ride on the GestureEventMsg
/// header (see ParsedGesture below), not in the per-variant
/// payload. ADR 0017-rev2 addendum 2026-05-04 documents why.
pub const GesturePayload = union(protocol.GestureType) {
    n_click: protocol.NClickPayload,
    drag_start: protocol.DragPayload,
    drag_move: protocol.DragPayload,
    drag_end: protocol.DragPayload,
    tap: protocol.DragPayload,
    scroll_begin: void,
    two_finger_scroll: protocol.TwoFingerScrollPayload,
    scroll_end: void,
    pinch_begin: protocol.PinchBeginPayload,
    pinch: protocol.PinchPayload,
    pinch_end: void,
    three_finger_swipe_begin: protocol.ThreeFingerSwipePayload,
    three_finger_swipe: protocol.ThreeFingerSwipePayload,
    three_finger_swipe_end: void,
    intent_hint: protocol.IntentHintPayload,
};

/// A gesture event as delivered to clients. The header is the
/// 24-byte GestureEventMsg parsed from the wire; payload is the
/// per-variant tail decoded from the bytes following the header.
/// header.gesture_type and the active tag of payload always
/// agree by construction; client code can switch on either.
pub const ParsedGesture = struct {
    header: protocol.GestureEventMsg,
    payload: GesturePayload,
};

/// Event types received from the daemon
pub const Event = union(enum) {
    surface_created: protocol.SurfaceCreatedMsg,
    buffer_released: protocol.BufferReleasedMsg,
    frame_complete: protocol.FrameCompleteMsg,
    sync_done: protocol.SyncDoneMsg,
    error_reply: protocol.ErrorReplyMsg,
    key_press: protocol.KeyPressMsg,
    mouse_event: protocol.MouseEventMsg,
    gesture_event: ParsedGesture,
    clipboard_data: ClipboardData,
    disconnected: void,
};

/// Connection to semadrawd
pub const Connection = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    fd: posix.fd_t,
    state: ConnectionState,
    client_id: protocol.ClientId,
    server_version_major: u16,
    server_version_minor: u16,
    next_sync_id: u32,
    recv_buf: [4096]u8,
    recv_len: usize,

    const Self = @This();

    /// Connect to the daemon at the default socket path
    pub fn connect(allocator: std.mem.Allocator) !*Self {
        return connectTo(allocator, protocol.DEFAULT_SOCKET_PATH);
    }

    /// Connect to the daemon at a specific socket path
    pub fn connectTo(allocator: std.mem.Allocator, socket_path: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .socket_path = socket_path,
            .fd = -1,
            .state = .disconnected,
            .client_id = 0,
            .server_version_major = 0,
            .server_version_minor = 0,
            .next_sync_id = 1,
            .recv_buf = undefined,
            .recv_len = 0,
        };

        try self.doConnect();
        return self;
    }

    fn doConnect(self: *Self) !void {
        self.state = .connecting;

        // Create socket. CLOEXEC is required so a client that
        // fork+execs a child process doesn't leak its semadrawd
        // connection fd into the child. Every other socket call
        // in semadraw (remote_connection, socket_server) already
        // uses SOCK.CLOEXEC; this local Unix-domain client
        // connection was the lone holdout. pgsd-sessiond Stage 6
        // is the first consumer that fork+execs a session leader
        // while connected, and would have leaked a fd to every
        // child without this. Other clients (term, hello) don't
        // currently fork+exec, but adding CLOEXEC here is the
        // right hygiene regardless.
        self.fd = compat.posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
            self.state = .error_state;
            return err;
        };
        errdefer {
            _ = posix.system.close(self.fd);
            self.fd = -1;
        }

        // Connect to daemon
        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        const path_bytes = self.socket_path;
        if (path_bytes.len >= addr.path.len) {
            self.state = .error_state;
            return error.PathTooLong;
        }
        @memcpy(addr.path[0..path_bytes.len], path_bytes);

        compat.posix.connect(self.fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
            self.state = .error_state;
            return err;
        };

        // Send hello
        try self.sendHello();

        // Wait for hello reply
        try self.waitForHelloReply();

        self.state = .connected;
        log.info("connected to semadrawd, client_id={}", .{self.client_id});
    }

    fn sendHello(self: *Self) !void {
        const hello = protocol.HelloMsg.init();
        var payload: [protocol.HelloMsg.SIZE]u8 = undefined;
        hello.serialize(&payload);
        try self.sendMessage(.hello, &payload);
    }

    fn waitForHelloReply(self: *Self) !void {
        const msg = try self.recvMessage();
        if (msg.header.msg_type != .hello_reply) {
            return error.UnexpectedMessage;
        }
        if (msg.payload) |p| {
            const reply = try protocol.HelloReplyMsg.deserialize(p);
            self.client_id = reply.client_id;
            self.server_version_major = reply.version_major;
            self.server_version_minor = reply.version_minor;
        } else {
            return error.InvalidPayload;
        }
    }

    /// Disconnect from the daemon
    pub fn disconnect(self: *Self) void {
        if (self.fd >= 0) {
            // Send disconnect message (best effort)
            self.sendMessage(.disconnect, &.{}) catch {};
            _ = posix.system.close(self.fd);
            self.fd = -1;
        }
        self.state = .disconnected;
        self.allocator.destroy(self);
    }

    /// Create a new surface
    pub fn createSurface(self: *Self, width: f32, height: f32) !protocol.SurfaceId {
        return self.createSurfaceWithScale(width, height, 1.0);
    }

    /// Create a new surface with explicit scale
    pub fn createSurfaceWithScale(self: *Self, width: f32, height: f32, scale: f32) !protocol.SurfaceId {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.CreateSurfaceMsg{
            .logical_width = width,
            .logical_height = height,
            .scale = scale,
            .flags = 0,
        };
        var payload: [protocol.CreateSurfaceMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.create_surface, &payload);

        // Wait for response
        const response = try self.recvMessage();
        switch (response.header.msg_type) {
            .surface_created => {
                if (response.payload) |p| {
                    const created = try protocol.SurfaceCreatedMsg.deserialize(p);
                    return created.surface_id;
                }
                return error.InvalidPayload;
            },
            .error_reply => {
                if (response.payload) |p| {
                    const err = try protocol.ErrorReplyMsg.deserialize(p);
                    log.err("create_surface failed: {}", .{err.code});
                }
                return error.ServerError;
            },
            else => return error.UnexpectedMessage,
        }
    }

    /// Destroy a surface
    pub fn destroySurface(self: *Self, surface_id: protocol.SurfaceId) !void {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.DestroySurfaceMsg{ .surface_id = surface_id };
        var payload: [protocol.DestroySurfaceMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.destroy_surface, &payload);
    }

    /// Commit a surface (present its contents)
    pub fn commit(self: *Self, surface_id: protocol.SurfaceId) !void {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.CommitMsg{
            .surface_id = surface_id,
            .flags = 0,
        };
        var payload: [protocol.CommitMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.commit, &payload);
    }

    /// Attach buffer data inline (SDCS data sent in message payload)
    pub fn attachBufferInline(self: *Self, surface_id: protocol.SurfaceId, sdcs_data: []const u8) !void {
        if (self.state != .connected) return error.NotConnected;

        // Create message with AttachBufferInlineMsg header + SDCS data
        const msg_buf = try self.allocator.alloc(u8, protocol.AttachBufferInlineMsg.HEADER_SIZE + sdcs_data.len);
        defer self.allocator.free(msg_buf);

        // Serialize header
        const msg = protocol.AttachBufferInlineMsg{
            .surface_id = surface_id,
            .sdcs_length = sdcs_data.len,
            .flags = 0,
        };
        msg.serialize(msg_buf[0..protocol.AttachBufferInlineMsg.HEADER_SIZE]);

        // Copy SDCS data
        @memcpy(msg_buf[protocol.AttachBufferInlineMsg.HEADER_SIZE..], sdcs_data);

        try self.sendMessage(.attach_buffer_inline, msg_buf);
    }

    /// Set surface visibility
    pub fn setVisible(self: *Self, surface_id: protocol.SurfaceId, visible: bool) !void {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.SetVisibleMsg{
            .surface_id = surface_id,
            .visible = if (visible) 1 else 0,
        };
        var payload: [protocol.SetVisibleMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.set_visible, &payload);
    }

    /// Set surface z-order
    pub fn setZOrder(self: *Self, surface_id: protocol.SurfaceId, z_order: i32) !void {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.SetZOrderMsg{
            .surface_id = surface_id,
            .z_order = z_order,
        };
        var payload: [protocol.SetZOrderMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.set_z_order, &payload);
    }

    /// Set surface position (in pixels)
    pub fn setPosition(self: *Self, surface_id: protocol.SurfaceId, x: f32, y: f32) !void {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.SetPositionMsg{
            .surface_id = surface_id,
            .x = x,
            .y = y,
        };
        var payload: [protocol.SetPositionMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.set_position, &payload);
    }

    /// Set clipboard content
    pub fn setClipboard(self: *Self, selection: protocol.ClipboardSelection, text: []const u8) !void {
        if (self.state != .connected) return error.NotConnected;

        const header_size = protocol.ClipboardSetMsg.HEADER_SIZE;
        const msg_buf = try self.allocator.alloc(u8, header_size + text.len);
        defer self.allocator.free(msg_buf);

        const msg = protocol.ClipboardSetMsg{
            .selection = selection,
            .length = @intCast(text.len),
        };
        msg.serialize(msg_buf[0..header_size]);
        @memcpy(msg_buf[header_size..], text);

        try self.sendMessage(.clipboard_set, msg_buf);
    }

    /// Request clipboard content (response will come as clipboard_data event)
    pub fn requestClipboard(self: *Self, selection: protocol.ClipboardSelection) !void {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.ClipboardRequestMsg{
            .selection = selection,
        };
        var payload: [protocol.ClipboardRequestMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.clipboard_request, &payload);
    }

    /// Synchronization barrier - wait for all pending operations
    pub fn sync(self: *Self) !void {
        if (self.state != .connected) return error.NotConnected;

        const sync_id = self.next_sync_id;
        self.next_sync_id +%= 1;

        const msg = protocol.SyncMsg{ .sync_id = sync_id };
        var payload: [protocol.SyncMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.sync, &payload);

        // Wait for sync_done
        while (true) {
            const response = try self.recvMessage();
            if (response.header.msg_type == .sync_done) {
                if (response.payload) |p| {
                    const done = try protocol.SyncDoneMsg.deserialize(p);
                    if (done.sync_id == sync_id) return;
                }
            }
            // Handle other messages that might arrive before sync_done
        }
    }

    /// Output info (framebuffer dimensions for a given output).
    pub const OutputInfo = struct {
        output_id: u32,
        width: u32,
        height: u32,
    };

    /// AD-26 follow-up: query the daemon for an output's dimensions.
    /// Replaces the previous practice of clients opening /dev/draw and
    /// calling DRAWFSGIOC_GET_EFIFB_INFO themselves; per ADR 0006 §5,
    /// /dev/draw is restricted to the _semadraw user and clients must
    /// go through the daemon's IPC.
    ///
    /// output_id is reserved for a future multi-output world; for now
    /// the only valid value is 0 (the primary/default output). Returns
    /// error.NoOutput if the daemon replies with ERROR_REPLY (either
    /// the requested output does not exist, or the daemon has no
    /// output initialised yet).
    pub fn queryOutputInfo(self: *Self, output_id: u32) !OutputInfo {
        if (self.state != .connected) return error.NotConnected;

        const msg = protocol.OutputInfoRequestMsg{ .output_id = output_id };
        var payload: [protocol.OutputInfoRequestMsg.SIZE]u8 = undefined;
        msg.serialize(&payload);
        try self.sendMessage(.output_info_request, &payload);

        // Wait for output_info_reply or error_reply. Pass through any
        // other unrelated messages that may arrive interleaved (e.g.
        // mouse_event while the user moves the cursor over a partly-
        // configured surface).
        while (true) {
            const response = try self.recvMessage();
            switch (response.header.msg_type) {
                .output_info_reply => {
                    if (response.payload) |p| {
                        const reply = try protocol.OutputInfoReplyMsg.deserialize(p);
                        if (reply.output_id == output_id) {
                            return .{
                                .output_id = reply.output_id,
                                .width = reply.width,
                                .height = reply.height,
                            };
                        }
                    }
                    return error.ProtocolError;
                },
                .error_reply => {
                    if (response.payload) |p| {
                        const err = try protocol.ErrorReplyMsg.deserialize(p);
                        if (err.context == output_id) return error.NoOutput;
                    }
                    return error.ProtocolError;
                },
                else => {
                    // Unrelated message; drop and keep waiting.
                },
            }
        }
    }

    /// D-11 (ADR 0013): query the daemon for the chronofs ns timestamp
    /// of the most recent input event it has observed. The caller
    /// computes idle as chronofs_now minus the returned value; a value
    /// of 0 means no input has been observed since the daemon started.
    /// idle_query is argument-free and the reply carries solely the u64;
    /// the value is read at query time with no caching (ADR 0013 D1/D2).
    pub fn queryIdle(self: *Self) !u64 {
        if (self.state != .connected) return error.NotConnected;

        try self.sendMessage(.idle_query, &.{});

        // Wait for idle_reply or error_reply, passing through any
        // unrelated messages that may arrive interleaved.
        while (true) {
            const response = try self.recvMessage();
            switch (response.header.msg_type) {
                .idle_reply => {
                    if (response.payload) |p| {
                        const reply = try protocol.IdleReplyMsg.deserialize(p);
                        return reply.last_input_ts_ns;
                    }
                    return error.ProtocolError;
                },
                .error_reply => {
                    return error.ProtocolError;
                },
                else => {
                    // Unrelated message; drop and keep waiting.
                },
            }
        }
    }

    /// Poll for events (non-blocking)
    pub fn poll(self: *Self) !?Event {
        if (self.state != .connected) return null;

        // Check if data is available
        var pfd = [_]posix.pollfd{.{
            .fd = self.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        const n = posix.poll(&pfd, 0) catch return null;
        if (n == 0) return null;

        if (pfd[0].revents & posix.POLL.IN != 0) {
            const msg = self.recvMessage() catch |err| {
                if (err == error.EndOfStream) {
                    self.state = .disconnected;
                    return .disconnected;
                }
                return err;
            };
            return self.msgToEvent(msg);
        }

        if (pfd[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
            self.state = .disconnected;
            return .disconnected;
        }

        return null;
    }

    /// Wait for an event (blocking)
    pub fn waitEvent(self: *Self) !Event {
        if (self.state != .connected) return .disconnected;

        const msg = try self.recvMessage();
        return self.msgToEvent(msg) orelse error.UnexpectedMessage;
    }

    fn msgToEvent(self: *Self, msg: RecvMessage) ?Event {
        _ = self;
        switch (msg.header.msg_type) {
            .surface_created => {
                if (msg.payload) |p| {
                    if (protocol.SurfaceCreatedMsg.deserialize(p)) |m| {
                        return .{ .surface_created = m };
                    } else |_| {}
                }
            },
            .buffer_released => {
                if (msg.payload) |p| {
                    if (protocol.BufferReleasedMsg.deserialize(p)) |m| {
                        return .{ .buffer_released = m };
                    } else |_| {}
                }
            },
            .frame_complete => {
                if (msg.payload) |p| {
                    if (protocol.FrameCompleteMsg.deserialize(p)) |m| {
                        return .{ .frame_complete = m };
                    } else |_| {}
                }
            },
            .sync_done => {
                if (msg.payload) |p| {
                    if (protocol.SyncDoneMsg.deserialize(p)) |m| {
                        return .{ .sync_done = m };
                    } else |_| {}
                }
            },
            .error_reply => {
                if (msg.payload) |p| {
                    if (protocol.ErrorReplyMsg.deserialize(p)) |m| {
                        return .{ .error_reply = m };
                    } else |_| {}
                }
            },
            .key_press => {
                if (msg.payload) |p| {
                    if (protocol.KeyPressMsg.deserialize(p)) |m| {
                        return .{ .key_press = m };
                    } else |_| {}
                }
            },
            .mouse_event => {
                if (msg.payload) |p| {
                    if (protocol.MouseEventMsg.deserialize(p)) |m| {
                        return .{ .mouse_event = m };
                    } else |_| {}
                }
            },
            .gesture_event => {
                if (msg.payload) |p| {
                    if (parseGestureEvent(p)) |g| {
                        return .{ .gesture_event = g };
                    } else |err| {
                        log.warn("gesture_event decode failed: {}", .{err});
                    }
                }
            },
            .clipboard_data => {
                if (msg.payload) |p| {
                    if (p.len >= protocol.ClipboardDataMsg.HEADER_SIZE) {
                        if (protocol.ClipboardDataMsg.deserialize(p)) |m| {
                            const data_start = protocol.ClipboardDataMsg.HEADER_SIZE;
                            const data_end = data_start + m.length;
                            if (p.len >= data_end) {
                                return .{ .clipboard_data = .{
                                    .selection = m.selection,
                                    .data = p[data_start..data_end],
                                } };
                            }
                        } else |_| {}
                    }
                }
            },
            else => {},
        }
        return null;
    }

    /// Get file descriptor for external polling
    pub fn getFd(self: *const Self) posix.fd_t {
        return self.fd;
    }

    /// Get current connection state
    pub fn getState(self: *const Self) ConnectionState {
        return self.state;
    }

    /// Get client ID assigned by daemon
    pub fn getClientId(self: *const Self) protocol.ClientId {
        return self.client_id;
    }

    // ========================================================================
    // Internal message I/O
    // ========================================================================

    const RecvMessage = struct {
        header: protocol.MsgHeader,
        payload: ?[]const u8,
    };

    fn sendMessage(self: *Self, msg_type: protocol.MsgType, payload: []const u8) !void {
        var header_buf: [protocol.MsgHeader.SIZE]u8 = undefined;
        const header = protocol.MsgHeader{
            .msg_type = msg_type,
            .flags = 0,
            .length = @intCast(payload.len),
        };
        header.serialize(&header_buf);

        // Send header (small, should complete in one write)
        try self.sendAll(&header_buf);

        // Send payload if any
        if (payload.len > 0) {
            try self.sendAll(payload);
        }
    }

    /// Write all bytes, handling partial writes
    fn sendAll(self: *Self, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len) {
            const chunk = data[sent..];
            const rc = posix.system.write(self.fd, chunk.ptr, chunk.len);
            if (rc < 0) {
                if (posix.errno(rc) == .AGAIN) continue;
                return error.WriteFailed;
            }
            const n: usize = @intCast(rc);
            if (n == 0) return error.BrokenPipe;
            sent += n;
        }
    }

    fn recvMessage(self: *Self) !RecvMessage {
        // Read header
        var header_buf: [protocol.MsgHeader.SIZE]u8 = undefined;
        try self.recvExact(&header_buf);

        const header = try protocol.MsgHeader.deserialize(&header_buf);

        // Read payload if any
        var payload: ?[]const u8 = null;
        if (header.length > 0) {
            if (header.length > self.recv_buf.len) {
                return error.PayloadTooLarge;
            }
            try self.recvExact(self.recv_buf[0..header.length]);
            payload = self.recv_buf[0..header.length];
        }

        return .{ .header = header, .payload = payload };
    }

    fn recvExact(self: *Self, buf: []u8) !void {
        var received: usize = 0;
        while (received < buf.len) {
            const n = posix.read(self.fd, buf[received..]) catch |err| {
                if (err == error.WouldBlock) continue;
                return err;
            };
            if (n == 0) return error.EndOfStream;
            received += n;
        }
    }
};

// ============================================================================
// Gesture event decoding
// ============================================================================

/// Decode a wire `gesture_event` payload (24-byte GestureEventMsg
/// header + per-variant payload bytes) into a ParsedGesture. The
/// caller passes the message body verbatim; this function consumes
/// the header, looks up the per-gesture-type payload size via
/// protocol.payloadSize, and decodes that variant's struct from
/// the tail. Errors propagate from the underlying deserialize
/// methods (mostly BufferTooSmall, plus InvalidEnum from an
/// unrecognised gesture_type via @enumFromInt in
/// GestureEventMsg.deserialize).
fn parseGestureEvent(buf: []const u8) !ParsedGesture {
    if (buf.len < protocol.GestureEventMsg.SIZE) return error.BufferTooSmall;
    const header = try protocol.GestureEventMsg.deserialize(buf);
    const payload_buf = buf[protocol.GestureEventMsg.SIZE..];
    const expected_payload_size = protocol.payloadSize(header.gesture_type);
    if (payload_buf.len < expected_payload_size) return error.BufferTooSmall;

    const payload: GesturePayload = switch (header.gesture_type) {
        .n_click => .{ .n_click = try protocol.NClickPayload.deserialize(payload_buf) },
        .drag_start => .{ .drag_start = try protocol.DragPayload.deserialize(payload_buf) },
        .drag_move => .{ .drag_move = try protocol.DragPayload.deserialize(payload_buf) },
        .drag_end => .{ .drag_end = try protocol.DragPayload.deserialize(payload_buf) },
        .tap => .{ .tap = try protocol.DragPayload.deserialize(payload_buf) },
        .scroll_begin => .{ .scroll_begin = {} },
        .two_finger_scroll => .{ .two_finger_scroll = try protocol.TwoFingerScrollPayload.deserialize(payload_buf) },
        .scroll_end => .{ .scroll_end = {} },
        .pinch_begin => .{ .pinch_begin = try protocol.PinchBeginPayload.deserialize(payload_buf) },
        .pinch => .{ .pinch = try protocol.PinchPayload.deserialize(payload_buf) },
        .pinch_end => .{ .pinch_end = {} },
        .three_finger_swipe_begin => .{ .three_finger_swipe_begin = try protocol.ThreeFingerSwipePayload.deserialize(payload_buf) },
        .three_finger_swipe => .{ .three_finger_swipe = try protocol.ThreeFingerSwipePayload.deserialize(payload_buf) },
        .three_finger_swipe_end => .{ .three_finger_swipe_end = {} },
        .intent_hint => .{ .intent_hint = try protocol.IntentHintPayload.deserialize(payload_buf) },
        // GestureType is non-exhaustive (`_,` in protocol.zig) so a
        // future daemon could send a gesture_type the client doesn't
        // recognise. We can't decode the payload without knowing the
        // type, so error out and let the caller log/skip.
        _ => return error.UnknownGestureType,
    };

    return .{ .header = header, .payload = payload };
}

// ============================================================================
// Tests
// ============================================================================

test "Connection struct size" {
    // Ensure Connection can be created
    try std.testing.expect(@sizeOf(Connection) > 0);
}

test "parseGestureEvent round-trips n_click" {
    // Build a wire buffer the way semadrawd does: header + payload
    // concatenated. Feed through parseGestureEvent and verify the
    // decoded form. Catches regressions in the dispatch path or
    // payload-size lookup.
    const header = protocol.GestureEventMsg{
        .surface_id = 7,
        .gesture_type = .n_click,
        .phase = .update,
        .finger_count = 1,
        .flags = .{ .ctrl = true },
        .t_current = 1_234_567_890,
    };
    const pl = protocol.NClickPayload{
        .button = 1,
        .count = 2,
        .x = 100,
        .y = 200,
    };
    var buf: [protocol.GestureEventMsg.SIZE + protocol.NClickPayload.SIZE]u8 = undefined;
    header.serialize(buf[0..protocol.GestureEventMsg.SIZE]);
    pl.serialize(buf[protocol.GestureEventMsg.SIZE..]);

    const parsed = try parseGestureEvent(&buf);
    try std.testing.expectEqual(@as(protocol.SurfaceId, 7), parsed.header.surface_id);
    try std.testing.expectEqual(protocol.GestureType.n_click, parsed.header.gesture_type);
    try std.testing.expectEqual(protocol.GesturePhase.update, parsed.header.phase);
    try std.testing.expectEqual(@as(u8, 1), parsed.header.finger_count);
    try std.testing.expect(parsed.header.flags.ctrl);
    try std.testing.expectEqual(@as(u64, 1_234_567_890), parsed.header.t_current);
    switch (parsed.payload) {
        .n_click => |p| {
            try std.testing.expectEqual(@as(u32, 1), p.button);
            try std.testing.expectEqual(@as(u32, 2), p.count);
            try std.testing.expectEqual(@as(i32, 100), p.x);
            try std.testing.expectEqual(@as(i32, 200), p.y);
        },
        else => return error.WrongPayloadVariant,
    }
}

test "parseGestureEvent handles void-payload variants" {
    // pinch_end carries zero payload bytes per the rev2 ADR. A
    // header-only buffer must decode cleanly.
    const header = protocol.GestureEventMsg{
        .surface_id = 1,
        .gesture_type = .pinch_end,
        .phase = .end,
        .finger_count = 2,
        .flags = .{},
        .t_current = 42,
    };
    var buf: [protocol.GestureEventMsg.SIZE]u8 = undefined;
    header.serialize(&buf);

    const parsed = try parseGestureEvent(&buf);
    try std.testing.expectEqual(protocol.GestureType.pinch_end, parsed.header.gesture_type);
    try std.testing.expectEqual(protocol.GesturePhase.end, parsed.header.phase);
    try std.testing.expectEqual(@as(u8, 2), parsed.header.finger_count);
    switch (parsed.payload) {
        .pinch_end => {},
        else => return error.WrongPayloadVariant,
    }
}

test "parseGestureEvent rejects truncated buffer" {
    // Header alone is 24 bytes; passing fewer must error rather
    // than read out of bounds.
    var buf: [16]u8 = .{0} ** 16;
    try std.testing.expectError(error.BufferTooSmall, parseGestureEvent(&buf));
}

test "parseGestureEvent rejects truncated payload" {
    // Header says n_click (16-byte payload), but we only provide
    // header + 4 bytes of payload. Decode must fail BufferTooSmall.
    const header = protocol.GestureEventMsg{
        .surface_id = 1,
        .gesture_type = .n_click,
        .phase = .update,
        .finger_count = 1,
        .flags = .{},
        .t_current = 0,
    };
    var buf: [protocol.GestureEventMsg.SIZE + 4]u8 = undefined;
    header.serialize(buf[0..protocol.GestureEventMsg.SIZE]);
    @memset(buf[protocol.GestureEventMsg.SIZE..], 0);
    try std.testing.expectError(error.BufferTooSmall, parseGestureEvent(&buf));
}
