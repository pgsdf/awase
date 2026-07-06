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

    // Replies and notifications (compositor -> session authority).
    ctl_ack = 0x8001, // request accepted and applied
    ctl_error = 0x8002, // payload: CtlErrorPayload
    display_state = 0x8003, // payload: DisplayStatePayload; sent as
    // the status_query reply and as an unsolicited notification on
    // every display-axis transition, including input-driven wake
    // (ADR 0021 §8), so the policy agent can restart its idle
    // timeline without polling races.
};

pub const CtlError = enum(u16) {
    not_implemented = 1, // verb assigned but its machinery not landed
    protocol_error = 2, // malformed frame, oversize, unknown type
    invalid_state = 3, // request legal but not from this state
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

test "payload roundtrips" {
    var b1: [1]u8 = undefined;
    (DisplayStatePayload{ .axis = @intFromEnum(DisplayAxis.blanked) }).serialize(&b1);
    try std.testing.expectEqual(@as(u8, 1), (try DisplayStatePayload.deserialize(&b1)).axis);
    var b2: [2]u8 = undefined;
    (CtlErrorPayload{ .code = @intFromEnum(CtlError.not_implemented) }).serialize(&b2);
    try std.testing.expectEqual(@as(u16, 1), (try CtlErrorPayload.deserialize(&b2)).code);
}
