// ADR 0021 Section 8: the privileged control interface.
//
// This is the wire contract for the dedicated control socket, the
// channel between the session authority (sessiond ADR 0010) and the
// compositor. It is deliberately NOT part of the public client
// protocol (protocol.zig): blanking is session policy, not a
// compositor service offered to clients, and the ADR 0012 lock verbs
// relocate here for the same reason with more force (ADR 0012
// Section 10 amendment, 2026-07-06).
//
// The header shares the client protocol's 8-byte shape (type u16,
// flags u16, length u32, little-endian) so the framing idiom is the
// same across both sockets, but the opcode namespace is disjoint by
// construction: a control message can never be mistaken for a client
// message because it can never arrive on the client socket, and vice
// versa. The physical socket boundary is the contract boundary.
//
// Authorization is not part of the wire contract: the listener is
// root-owned and mode 0600 (filesystem pre-filter), and the daemon
// verifies the peer against the session authority at accept
// (ADR 0012 Section 4 bootstrap: peer uid 0). By the time a message
// is parsed, the peer is trusted.

const std = @import("std");

/// Default control socket path, beside the client socket. The ADR
/// names /var/run/sema/drawctl as an example; the implementation
/// places it next to /var/run/semadraw.sock instead so the two
/// listeners share directory lifecycle and the audio runtime dir's
/// creation timing is not a dependency.
pub const DEFAULT_CTL_SOCKET_PATH = "/var/run/semadraw.ctl";

/// Control messages are tiny; anything larger than this is a
/// protocol violation and the connection is closed.
pub const MAX_CTL_PAYLOAD: usize = 64;

/// Control opcode namespace. Requests are low, replies and
/// notifications have the high bit set, mirroring the client
/// protocol's convention without sharing its numeric space.
pub const CtlMsgType = enum(u16) {
    // Requests (session authority -> compositor).
    blank = 0x0001, // enter BLANKED (display axis; ADR 0021 §4)
    unblank = 0x0002, // leave BLANKED by policy (not the wake path)
    status_query = 0x0003, // reply is display_state

    // ADR 0012 verbs relocate here (Section 10 amendment,
    // 2026-07-06). Assigned now so the numeric space is settled;
    // implemented with the lock machinery, not before.
    session_lock = 0x0010,
    session_unlock = 0x0011,

    // CAPTURE-DESIGN.md commit 3 (ADR 0021 Section 8 amendment,
    // 2026-07-15). capture consumes the SCM_RIGHTS descriptor that
    // accompanied the request frame: the daemon copies the composited
    // frame into the caller's shared-memory object and replies with
    // metadata only; pixels never travel through this socket.
    // capture_info is the sizing probe: same capture_reply metadata,
    // no descriptor and no copy, so a client can size the object
    // before capturing (it has no other channel to learn stride and
    // height, and the capture-time buffer_too_small check still
    // protects against a display change between the two requests).
    capture = 0x0020,
    capture_info = 0x0021,

    // D-12 stage 2 (ADR 0022 section 5). The administrative front end
    // for compositor-assigned geometry: the operator tells the
    // compositor to assign the surface a configuration, the daemon
    // allocates the serial, records the pending configure, and emits
    // surface_configure to the owning client. Deliberately
    // administrative rather than protocol-shaped: it exposes exactly
    // what drives and verifies the configure state machine, no more.
    // NDE-1's surface manager later becomes the policy front end over
    // the same registry machinery; this verb remains as the operator
    // and bench facility. Payload: ConfigurePayload. Reply:
    // configure_reply carrying the allocated serial, so the bench can
    // name serials when driving supersession.
    configure = 0x0030,

    // D-12 stage 2 observability. Without enumeration the operator
    // guesses surface ids, which the first metal bench of the
    // configure verb proved untenable (the cursor owns id 1 and a
    // reconnecting client's id is whatever the churn left it at).
    // Reply is one surfaces_reply carrying the count, then one
    // surface_info frame per surface.
    list_surfaces = 0x0031,

    // Operator authority over existing compositor mechanisms, the
    // configure pattern continued (ratified 2026-07-16): no new
    // architecture, an administrative front end over the registry and
    // focus machinery that NDE-1's surface manager will later drive
    // through the same internal calls.
    //
    // move stages a new position through the transactional setter:
    // compositor-global pixels, any finite coordinate legal (rendering
    // clamps at framebuffer edges; a fully off-screen surface simply
    // contributes nothing), visible at the client's NEXT COMMIT, per
    // the ADR 0022 model. No timing guarantee beyond that.
    //
    // focus reassigns keyboard routing only: it does not raise, does
    // not change z-order, and visibility is orthogonal (a hidden
    // surface may hold focus; raise-on-focus and click-to-focus are
    // surface-manager policy, deliberately absent here). surface 0
    // clears to NO_FOCUS, the set_focus (0x0034) semantic.
    move = 0x0032,
    focus = 0x0033,

    // Replies and notifications (compositor -> session authority).
    ctl_ack = 0x8001, // request accepted and applied
    ctl_error = 0x8002, // payload: CtlErrorPayload
    display_state = 0x8003, // payload: DisplayStatePayload; sent as
    // the status_query reply and as an unsolicited notification on
    // every display-axis transition, including input-driven wake
    // (ADR 0021 §8), so the policy agent can restart its idle
    // timeline without polling races.
    capture_reply = 0x8004, // payload: CaptureHeader
    configure_reply = 0x8005, // payload: ConfigureReplyPayload
    surfaces_reply = 0x8006, // payload: SurfacesReplyPayload (count)
    surface_info = 0x8007, // payload: SurfaceInfoPayload, one per surface
};

pub const CtlError = enum(u16) {
    not_implemented = 1, // verb assigned but its machinery not landed
    protocol_error = 2, // malformed frame, oversize, unknown type
    invalid_state = 3, // request legal but not from this state

    // Capture failures (CAPTURE-DESIGN.md commit 3), classed so a
    // client can respond appropriately: fix the request, retry
    // later, or report a fault, rather than guessing from one code.
    //
    // Client/protocol errors: the request itself is wrong.
    capture_no_descriptor = 0x0010, // no SCM_RIGHTS fd accompanied capture
    capture_bad_descriptor = 0x0011, // descriptor rejected by fstat
    capture_buffer_too_small = 0x0012, // object smaller than stride * height;
    // retry with a larger object (capture_info gives the sizing)
    //
    // Operational: nothing wrong with the request; retry later.
    capture_unavailable = 0x0013, // backend has no coherent snapshot
    //
    // System/runtime: the daemon could not map the object.
    capture_map_failed = 0x0014,

    // Configure failures (D-12 stage 2), all client/protocol class:
    // the request itself is wrong.
    configure_unknown_surface = 0x0020, // no surface with that id
    configure_invalid_geometry = 0x0021, // non-positive or non-finite size
    configure_not_client_surface = 0x0022, // daemon-owned surface (the
    // cursor); cursor state does not inherit surface transaction
    // semantics (ADR 0022; audit SA-2), so it is not configurable

    // Move failures, client/protocol class.
    move_unknown_surface = 0x0030,
    move_invalid_position = 0x0031, // non-finite coordinate
    move_not_client_surface = 0x0032, // the cursor's position is the
    // pointer's, never the operator's (ADR 0005)

    // Focus failures, client/protocol class.
    focus_unknown_surface = 0x0040,
    focus_not_client_surface = 0x0041, // focusing a daemon-owned
    // surface routes keys to nobody; refused as a footgun
};

/// ADR 0021 Section 3: the display axis. OFF is reserved for Tier B
/// (sessiond ADR 0009 D3) and deliberately not assigned a value yet.
pub const DisplayAxis = enum(u8) {
    on = 0,
    blanked = 1,
};

/// 8-byte header, same shape and endianness as protocol.MsgHeader.
pub const CtlHeader = extern struct {
    msg_type: CtlMsgType,
    flags: u16,
    length: u32,

    pub const SIZE: usize = 8;

    pub fn serialize(self: CtlHeader, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u16, buf[0..2], @intFromEnum(self.msg_type), .little);
        std.mem.writeInt(u16, buf[2..4], self.flags, .little);
        std.mem.writeInt(u32, buf[4..8], self.length, .little);
    }

    pub fn deserialize(buf: []const u8) !CtlHeader {
        if (buf.len < SIZE) return error.BufferTooSmall;
        const type_val = std.mem.readInt(u16, buf[0..2], .little);
        return .{
            .msg_type = std.enums.fromInt(CtlMsgType, type_val) orelse return error.InvalidMsgType,
            .flags = std.mem.readInt(u16, buf[2..4], .little),
            .length = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

pub const DisplayStatePayload = extern struct {
    axis: u8,

    pub const SIZE: usize = 1;

    pub fn serialize(self: DisplayStatePayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        buf[0] = self.axis;
    }

    pub fn deserialize(buf: []const u8) !DisplayStatePayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{ .axis = buf[0] };
    }
};

pub const CtlErrorPayload = extern struct {
    code: u16,

    pub const SIZE: usize = 2;

    pub fn serialize(self: CtlErrorPayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u16, buf[0..2], self.code, .little);
    }

    pub fn deserialize(buf: []const u8) !CtlErrorPayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{ .code = std.mem.readInt(u16, buf[0..2], .little) };
    }
};

/// CAPTURE-DESIGN.md commit 3: the capture reply payload. Metadata
/// only; the pixels travel through the caller-provided shared-memory
/// object, never through this socket (a 4K frame is ~33 MB and the
/// ctl path is synchronous; the design commit carries the argument).
/// Sent as the reply to capture (after the copy, describing exactly
/// what was copied) and to capture_info (the sizing probe). stride
/// is carried explicitly because it may exceed width * 4; format is
/// the backend PixelFormat wire value.
pub const CaptureHeader = extern struct {
    width: u32,
    height: u32,
    stride: u32,
    format: u8,

    pub const SIZE: usize = 13;

    pub fn serialize(self: CaptureHeader, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.width, .little);
        std.mem.writeInt(u32, buf[4..8], self.height, .little);
        std.mem.writeInt(u32, buf[8..12], self.stride, .little);
        buf[12] = self.format;
    }

    pub fn deserialize(buf: []const u8) !CaptureHeader {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .width = std.mem.readInt(u32, buf[0..4], .little),
            .height = std.mem.readInt(u32, buf[4..8], .little),
            .stride = std.mem.readInt(u32, buf[8..12], .little),
            .format = buf[12],
        };
    }
};

test "CtlHeader is 8 bytes and roundtrips" {
    try std.testing.expectEqual(@as(usize, 8), CtlHeader.SIZE);
    var buf: [8]u8 = undefined;
    const h = CtlHeader{ .msg_type = .status_query, .flags = 0, .length = 0 };
    h.serialize(&buf);
    const back = try CtlHeader.deserialize(&buf);
    try std.testing.expectEqual(CtlMsgType.status_query, back.msg_type);
    try std.testing.expectEqual(@as(u32, 0), back.length);
}

test "unknown control opcode is rejected at deserialize" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 0x7777, .little);
    std.mem.writeInt(u16, buf[2..4], 0, .little);
    std.mem.writeInt(u32, buf[4..8], 0, .little);
    try std.testing.expectError(error.InvalidMsgType, CtlHeader.deserialize(&buf));
}

/// D-12 stage 2: the configure request payload. Logical size as f32,
/// matching SurfaceState and the client-protocol SurfaceConfigureMsg.
/// Scale is deliberately absent: the operator interface exposes only
/// what drives the state machine, and no per-surface scale exists yet.
pub const ConfigurePayload = extern struct {
    surface_id: u32,
    logical_width: f32,
    logical_height: f32,

    pub const SIZE: usize = 12;

    pub fn serialize(self: ConfigurePayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        @memcpy(buf[4..8], std.mem.asBytes(&self.logical_width));
        @memcpy(buf[8..12], std.mem.asBytes(&self.logical_height));
    }

    pub fn deserialize(buf: []const u8) !ConfigurePayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .logical_width = @bitCast(std.mem.readInt(u32, buf[4..8], .little)),
            .logical_height = @bitCast(std.mem.readInt(u32, buf[8..12], .little)),
        };
    }
};

/// D-12 stage 2: the configure reply, carrying the serial the daemon
/// allocated so the bench can name serials when driving supersession.
pub const ConfigureReplyPayload = extern struct {
    config_serial: u64,

    pub const SIZE: usize = 8;

    pub fn serialize(self: ConfigureReplyPayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u64, buf[0..8], self.config_serial, .little);
    }

    pub fn deserialize(buf: []const u8) !ConfigureReplyPayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{ .config_serial = std.mem.readInt(u64, buf[0..8], .little) };
    }
};

/// D-12 stage 2 observability: the list_surfaces reply header.
pub const SurfacesReplyPayload = extern struct {
    count: u32,

    pub const SIZE: usize = 4;

    pub fn serialize(self: SurfacesReplyPayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.count, .little);
    }

    pub fn deserialize(buf: []const u8) !SurfacesReplyPayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{ .count = std.mem.readInt(u32, buf[0..4], .little) };
    }
};

/// D-12 stage 2 observability: one surface's administrative view.
/// pending_serial is 0 when no configure is outstanding (0 is never
/// an allocated serial; it names the creation configuration).
pub const SurfaceInfoPayload = extern struct {
    surface_id: u32,
    owner: u32,
    owner_uid: u32,
    logical_width: f32,
    logical_height: f32,
    pending_serial: u64,
    acked_serial: u64,
    // Appended for the move verb's observability (2026-07-16): the
    // CURRENT position, same presented-state rule as the size fields.
    position_x: f32,
    position_y: f32,

    pub const SIZE: usize = 44;

    pub fn serialize(self: SurfaceInfoPayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u32, buf[4..8], self.owner, .little);
        std.mem.writeInt(u32, buf[8..12], self.owner_uid, .little);
        @memcpy(buf[12..16], std.mem.asBytes(&self.logical_width));
        @memcpy(buf[16..20], std.mem.asBytes(&self.logical_height));
        std.mem.writeInt(u64, buf[20..28], self.pending_serial, .little);
        std.mem.writeInt(u64, buf[28..36], self.acked_serial, .little);
        @memcpy(buf[36..40], std.mem.asBytes(&self.position_x));
        @memcpy(buf[40..44], std.mem.asBytes(&self.position_y));
    }

    pub fn deserialize(buf: []const u8) !SurfaceInfoPayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .owner = std.mem.readInt(u32, buf[4..8], .little),
            .owner_uid = std.mem.readInt(u32, buf[8..12], .little),
            .logical_width = @bitCast(std.mem.readInt(u32, buf[12..16], .little)),
            .logical_height = @bitCast(std.mem.readInt(u32, buf[16..20], .little)),
            .pending_serial = std.mem.readInt(u64, buf[20..28], .little),
            .acked_serial = std.mem.readInt(u64, buf[28..36], .little),
            .position_x = @bitCast(std.mem.readInt(u32, buf[36..40], .little)),
            .position_y = @bitCast(std.mem.readInt(u32, buf[40..44], .little)),
        };
    }
};

/// Operator move request: compositor-global pixels, staged through
/// the transactional setter, visible at the client's next commit.
pub const MovePayload = extern struct {
    surface_id: u32,
    x: f32,
    y: f32,

    pub const SIZE: usize = 12;

    pub fn serialize(self: MovePayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        @memcpy(buf[4..8], std.mem.asBytes(&self.x));
        @memcpy(buf[8..12], std.mem.asBytes(&self.y));
    }

    pub fn deserialize(buf: []const u8) !MovePayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .x = @bitCast(std.mem.readInt(u32, buf[4..8], .little)),
            .y = @bitCast(std.mem.readInt(u32, buf[8..12], .little)),
        };
    }
};

/// Operator focus request: keyboard routing only; surface 0 clears.
pub const FocusPayload = extern struct {
    surface_id: u32,

    pub const SIZE: usize = 4;

    pub fn serialize(self: FocusPayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
    }

    pub fn deserialize(buf: []const u8) !FocusPayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{ .surface_id = std.mem.readInt(u32, buf[0..4], .little) };
    }
};

test "payload roundtrips" {
    var b1: [1]u8 = undefined;
    (DisplayStatePayload{ .axis = @intFromEnum(DisplayAxis.blanked) }).serialize(&b1);
    try std.testing.expectEqual(@as(u8, 1), (try DisplayStatePayload.deserialize(&b1)).axis);
    var b2: [2]u8 = undefined;
    (CtlErrorPayload{ .code = @intFromEnum(CtlError.not_implemented) }).serialize(&b2);
    try std.testing.expectEqual(@as(u16, 1), (try CtlErrorPayload.deserialize(&b2)).code);
}

test "surface listing payloads roundtrip and fit the payload budget" {
    try std.testing.expect(SurfaceInfoPayload.SIZE <= MAX_CTL_PAYLOAD);
    var b: [SurfaceInfoPayload.SIZE]u8 = undefined;
    (SurfaceInfoPayload{
        .surface_id = 3,
        .owner = 2,
        .owner_uid = 1000,
        .logical_width = 800,
        .logical_height = 600,
        .pending_serial = 4,
        .acked_serial = 2,
        .position_x = 1920,
        .position_y = 0,
    }).serialize(&b);
    const back = try SurfaceInfoPayload.deserialize(&b);
    try std.testing.expectEqual(@as(u32, 3), back.surface_id);
    try std.testing.expectEqual(@as(u32, 1000), back.owner_uid);
    try std.testing.expectEqual(@as(f32, 800), back.logical_width);
    try std.testing.expectEqual(@as(u64, 4), back.pending_serial);
    try std.testing.expectEqual(@as(u64, 2), back.acked_serial);
    try std.testing.expectEqual(@as(f32, 1920), back.position_x);
    var c: [SurfacesReplyPayload.SIZE]u8 = undefined;
    (SurfacesReplyPayload{ .count = 2 }).serialize(&c);
    try std.testing.expectEqual(@as(u32, 2), (try SurfacesReplyPayload.deserialize(&c)).count);
}

test "move and focus payloads roundtrip and fit the payload budget" {
    try std.testing.expect(MovePayload.SIZE <= MAX_CTL_PAYLOAD);
    try std.testing.expect(FocusPayload.SIZE <= MAX_CTL_PAYLOAD);
    var b: [MovePayload.SIZE]u8 = undefined;
    (MovePayload{ .surface_id = 4, .x = 1920, .y = -8.5 }).serialize(&b);
    const back = try MovePayload.deserialize(&b);
    try std.testing.expectEqual(@as(u32, 4), back.surface_id);
    try std.testing.expectEqual(@as(f32, 1920), back.x);
    try std.testing.expectEqual(@as(f32, -8.5), back.y);
    var c: [FocusPayload.SIZE]u8 = undefined;
    (FocusPayload{ .surface_id = 7 }).serialize(&c);
    try std.testing.expectEqual(@as(u32, 7), (try FocusPayload.deserialize(&c)).surface_id);
    try std.testing.expectError(error.BufferTooSmall, MovePayload.deserialize(b[0 .. MovePayload.SIZE - 1]));
}

test "configure payloads roundtrip and fit the payload budget" {
    try std.testing.expect(ConfigurePayload.SIZE <= MAX_CTL_PAYLOAD);
    try std.testing.expect(ConfigureReplyPayload.SIZE <= MAX_CTL_PAYLOAD);
    var b1: [ConfigurePayload.SIZE]u8 = undefined;
    (ConfigurePayload{ .surface_id = 5, .logical_width = 132.5, .logical_height = 43.0 }).serialize(&b1);
    const back = try ConfigurePayload.deserialize(&b1);
    try std.testing.expectEqual(@as(u32, 5), back.surface_id);
    try std.testing.expectEqual(@as(f32, 132.5), back.logical_width);
    try std.testing.expectEqual(@as(f32, 43.0), back.logical_height);
    var b2: [ConfigureReplyPayload.SIZE]u8 = undefined;
    (ConfigureReplyPayload{ .config_serial = 7 }).serialize(&b2);
    try std.testing.expectEqual(@as(u64, 7), (try ConfigureReplyPayload.deserialize(&b2)).config_serial);
    try std.testing.expectError(error.BufferTooSmall, ConfigurePayload.deserialize(b1[0 .. ConfigurePayload.SIZE - 1]));
}

test "CaptureHeader roundtrips and fits the payload budget" {
    try std.testing.expect(CaptureHeader.SIZE <= MAX_CTL_PAYLOAD);
    var buf: [CaptureHeader.SIZE]u8 = undefined;
    const h = CaptureHeader{ .width = 3840, .height = 2160, .stride = 15360, .format = 1 };
    h.serialize(&buf);
    const back = try CaptureHeader.deserialize(&buf);
    try std.testing.expectEqual(@as(u32, 3840), back.width);
    try std.testing.expectEqual(@as(u32, 2160), back.height);
    try std.testing.expectEqual(@as(u32, 15360), back.stride);
    try std.testing.expectEqual(@as(u8, 1), back.format);
    try std.testing.expectError(error.BufferTooSmall, CaptureHeader.deserialize(buf[0 .. CaptureHeader.SIZE - 1]));
}
