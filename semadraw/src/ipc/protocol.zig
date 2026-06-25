const std = @import("std");

/// SemaDraw IPC Protocol
///
/// Wire format for communication between clients and semadrawd.
/// All multi-byte values are little-endian.

pub const PROTOCOL_VERSION_MAJOR: u16 = 0;
pub const PROTOCOL_VERSION_MINOR: u16 = 1;

/// Default socket path
pub const DEFAULT_SOCKET_PATH = "/var/run/semadraw.sock";

/// Default TCP port for remote connections
pub const DEFAULT_TCP_PORT: u16 = 7234;

/// Surface identifier (opaque handle)
pub const SurfaceId = u32;

/// Client identifier (assigned by daemon)
pub const ClientId = u32;

/// Sentinel ClientId value reserved for the daemon itself, used as
/// the owner of internal compositor-managed surfaces (currently the
/// cursor surface, per ADR 0005). Distinct from:
///   - 0          : "unconnected" placeholder used by client libraries
///                  before the hello handshake completes.
///   - 1..0x7FFFFFFF : local client ID range, assigned by the
///                     daemon's local socket accept path.
///   - 0x80000000..0xFFFFFFFE : remote client ID range.
/// 0xFFFFFFFF is therefore unambiguously the daemon and cannot
/// collide with any client-assigned ID.
pub const CLIENT_ID_DAEMON: ClientId = 0xFFFFFFFF;

/// Z-order constants (per ADR 0005 section 2). Client-set z-order
/// values are clamped server-side to [Z_ORDER_MIN, Z_ORDER_CLIENT_MAX]
/// in the daemon's set_z_order handlers. The cursor surface, owned
/// by the daemon, sits at Z_ORDER_CURSOR above the entire client
/// range; clients cannot reach or exceed it even by setting i32 max.
///
/// The daemon writes z-order directly to the surface registry
/// (registry.setZOrder) without going through the handlers, so the
/// clamp does not apply to internal daemon use.
pub const Z_ORDER_MIN: i32 = -1_000_000;
pub const Z_ORDER_CLIENT_MAX: i32 = 999_999;
pub const Z_ORDER_CURSOR: i32 = 1_000_000;

/// Message types
// BEGIN GENERATED CONSTANTS: msg_type
// Do not edit. Generated from shared/protocol_constants.json
// by shared/tools/gen_constants.py

pub const MsgType = enum(u16) {
    // Client -> Daemon requests (0x0xxx)
    hello = 0x0001, // Client handshake
    create_surface = 0x0010, // Create surface
    destroy_surface = 0x0011, // Destroy surface
    attach_buffer = 0x0020, // Attach shm buffer
    commit = 0x0021, // Commit surface
    attach_buffer_inline = 0x0022, // Attach inline buffer (remote)
    set_visible = 0x0030, // Set visibility
    set_z_order = 0x0031, // Set stacking order
    set_position = 0x0032, // Set position
    set_cursor = 0x0033, // Set cursor sprite + hotspot (focus-validated; AD-21 sub-item 7, ADR 0005 section 5)
    set_focus = 0x0034, // Assign keyboard focus to the given surface (D-7, ADR 0011); privileged client only; surface 0 clears to NO_FOCUS; fire-and-forget, observable via FOCUS_CHANGED; reply on failure is ERROR_REPLY
    session_lock = 0x0035, // Enter compositor session-lock mode with the given surface as the lock surface (D-10, ADR 0012); root-only; reply event is SESSION_LOCKED
    session_unlock = 0x0036, // Leave session-lock mode; lock owner only (D-10, ADR 0012); reply event is SESSION_UNLOCKED
    idle_query = 0x0037, // Query last input timestamp for idle detection; reply is IDLE_REPLY (ADR 0013; 0x0034 reserved for set_focus)
    sync = 0x0040, // Sync barrier
    clipboard_set = 0x0050, // Set clipboard
    clipboard_request = 0x0051, // Request clipboard
    output_info_request = 0x0060, // Query output info (framebuffer size); reply is OUTPUT_INFO_REPLY
    disconnect = 0x00F0, // Client disconnect

    // Daemon -> Client responses (0x8xxx)
    hello_reply = 0x8001, // Handshake response
    surface_created = 0x8010, // Surface created
    surface_destroyed = 0x8011, // Surface destroyed
    buffer_released = 0x8020, // Buffer released
    frame_complete = 0x8021, // Frame rendered
    cursor_set = 0x8033, // Cursor sprite + hotspot accepted (AD-21 sub-item 7, ADR 0005 section 5)
    idle_reply = 0x8037, // Idle reply: last_input_ts_ns as u64 in chronofs ns (ADR 0013)
    sync_done = 0x8040, // Sync complete
    output_info_reply = 0x8060, // Output info reply with output_id, width, height
    error_reply = 0x80F0, // Error response

    // Daemon -> Client events (0x9xxx)
    key_press = 0x9001, // Keyboard event
    mouse_event = 0x9002, // Mouse event
    focus_changed = 0x9003, // Keyboard focus changed (D-7, ADR 0011 D5); sent to the gaining client (surface_id = focused surface) and the losing/cleared client (surface_id = 0)
    session_locked = 0x9004, // Compositor entered session-lock mode (D-10, ADR 0012); sent to all clients, WM treats as a suspension signal
    session_unlocked = 0x9005, // Compositor left session-lock mode (D-10, ADR 0012); sent to all clients
    gesture_event = 0x9030, // Gesture event (interval-shaped, see ADR 0017-rev2)
    clipboard_data = 0x9050, // Clipboard data
};
// END GENERATED CONSTANTS: msg_type

/// Message header (8 bytes, always present)
pub const MsgHeader = extern struct {
    msg_type: MsgType,
    flags: u16,
    length: u32, // Payload length (excluding this header)

    pub const SIZE: usize = 8;

    pub fn serialize(self: MsgHeader, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u16, buf[0..2], @intFromEnum(self.msg_type), .little);
        std.mem.writeInt(u16, buf[2..4], self.flags, .little);
        std.mem.writeInt(u32, buf[4..8], self.length, .little);
    }

    pub fn deserialize(buf: []const u8) !MsgHeader {
        if (buf.len < SIZE) return error.BufferTooSmall;
        const type_val = std.mem.readInt(u16, buf[0..2], .little);
        return .{
            .msg_type = std.enums.fromInt(MsgType, type_val) orelse return error.InvalidMsgType,
            .flags = std.mem.readInt(u16, buf[2..4], .little),
            .length = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

// ============================================================================
// Client -> Daemon Messages
// ============================================================================

/// Hello request - protocol version negotiation
pub const HelloMsg = extern struct {
    version_major: u16,
    version_minor: u16,
    client_flags: u32, // Reserved

    pub const SIZE: usize = 8;

    pub fn init() HelloMsg {
        return .{
            .version_major = PROTOCOL_VERSION_MAJOR,
            .version_minor = PROTOCOL_VERSION_MINOR,
            .client_flags = 0,
        };
    }

    pub fn serialize(self: HelloMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u16, buf[0..2], self.version_major, .little);
        std.mem.writeInt(u16, buf[2..4], self.version_minor, .little);
        std.mem.writeInt(u32, buf[4..8], self.client_flags, .little);
    }

    pub fn deserialize(buf: []const u8) !HelloMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .version_major = std.mem.readInt(u16, buf[0..2], .little),
            .version_minor = std.mem.readInt(u16, buf[2..4], .little),
            .client_flags = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

/// Create surface request
pub const CreateSurfaceMsg = extern struct {
    logical_width: f32,
    logical_height: f32,
    scale: f32,
    flags: u32, // Reserved

    pub const SIZE: usize = 16;

    pub fn serialize(self: CreateSurfaceMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        @memcpy(buf[0..4], std.mem.asBytes(&self.logical_width));
        @memcpy(buf[4..8], std.mem.asBytes(&self.logical_height));
        @memcpy(buf[8..12], std.mem.asBytes(&self.scale));
        std.mem.writeInt(u32, buf[12..16], self.flags, .little);
    }

    pub fn deserialize(buf: []const u8) !CreateSurfaceMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .logical_width = @bitCast(std.mem.readInt(u32, buf[0..4], .little)),
            .logical_height = @bitCast(std.mem.readInt(u32, buf[4..8], .little)),
            .scale = @bitCast(std.mem.readInt(u32, buf[8..12], .little)),
            .flags = std.mem.readInt(u32, buf[12..16], .little),
        };
    }
};

/// Destroy surface request
pub const DestroySurfaceMsg = extern struct {
    surface_id: SurfaceId,

    pub const SIZE: usize = 4;

    pub fn serialize(self: DestroySurfaceMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
    }

    pub fn deserialize(buf: []const u8) !DestroySurfaceMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

/// Attach buffer request (file descriptor passed via SCM_RIGHTS)
pub const AttachBufferMsg = extern struct {
    surface_id: SurfaceId,
    shm_size: u64,
    sdcs_offset: u64,
    sdcs_length: u64,

    pub const SIZE: usize = 28;

    pub fn serialize(self: AttachBufferMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u64, buf[4..12], self.shm_size, .little);
        std.mem.writeInt(u64, buf[12..20], self.sdcs_offset, .little);
        std.mem.writeInt(u64, buf[20..28], self.sdcs_length, .little);
    }

    pub fn deserialize(buf: []const u8) !AttachBufferMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .shm_size = std.mem.readInt(u64, buf[4..12], .little),
            .sdcs_offset = std.mem.readInt(u64, buf[12..20], .little),
            .sdcs_length = std.mem.readInt(u64, buf[20..28], .little),
        };
    }
};

/// Attach buffer inline request (for remote connections without FD passing)
/// The SDCS data follows immediately after the header in the payload
pub const AttachBufferInlineMsg = extern struct {
    surface_id: SurfaceId,
    sdcs_length: u64, // Length of SDCS data that follows this header
    flags: u32, // Reserved

    pub const HEADER_SIZE: usize = 16;

    pub fn serialize(self: AttachBufferInlineMsg, buf: []u8) void {
        std.debug.assert(buf.len >= HEADER_SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u64, buf[4..12], self.sdcs_length, .little);
        std.mem.writeInt(u32, buf[12..16], self.flags, .little);
    }

    pub fn deserialize(buf: []const u8) !AttachBufferInlineMsg {
        if (buf.len < HEADER_SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .sdcs_length = std.mem.readInt(u64, buf[4..12], .little),
            .flags = std.mem.readInt(u32, buf[12..16], .little),
        };
    }
};

/// Commit request - present the attached buffer
pub const CommitMsg = extern struct {
    surface_id: SurfaceId,
    flags: u32, // Reserved

    pub const SIZE: usize = 8;

    pub fn serialize(self: CommitMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u32, buf[4..8], self.flags, .little);
    }

    pub fn deserialize(buf: []const u8) !CommitMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .flags = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

/// Set visibility request
pub const SetVisibleMsg = extern struct {
    surface_id: SurfaceId,
    visible: u32, // 0 = hidden, 1 = visible

    pub const SIZE: usize = 8;

    pub fn serialize(self: SetVisibleMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u32, buf[4..8], self.visible, .little);
    }

    pub fn deserialize(buf: []const u8) !SetVisibleMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .visible = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

/// Set Z-order request
pub const SetZOrderMsg = extern struct {
    surface_id: SurfaceId,
    z_order: i32,

    pub const SIZE: usize = 8;

    pub fn serialize(self: SetZOrderMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(i32, buf[4..8], self.z_order, .little);
    }

    pub fn deserialize(buf: []const u8) !SetZOrderMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .z_order = std.mem.readInt(i32, buf[4..8], .little),
        };
    }
};

/// Set-focus request (D-7, ADR 0011). Carries the target surface id;
/// surface_id 0 clears keyboard focus to NO_FOCUS. Privileged client
/// only; fire-and-forget (no success reply). Mirrors the single-u32
/// shape of DestroySurfaceMsg.
pub const SetFocusMsg = extern struct {
    surface_id: SurfaceId,

    pub const SIZE: usize = 4;

    pub fn serialize(self: SetFocusMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
    }

    pub fn deserialize(buf: []const u8) !SetFocusMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

/// Focus-changed event (D-7, ADR 0011 D5). Sent to the gaining client
/// (surface_id = the focused surface) and to the losing or cleared
/// client (surface_id = 0). surface_id 0 uniformly means "you no longer
/// hold focus," symmetric with SetFocusMsg surface 0 and NO_FOCUS.
pub const FocusChangedMsg = extern struct {
    surface_id: SurfaceId,

    pub const SIZE: usize = 4;

    pub fn serialize(self: FocusChangedMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
    }

    pub fn deserialize(buf: []const u8) !FocusChangedMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

/// Set position request
pub const SetPositionMsg = extern struct {
    surface_id: SurfaceId,
    x: f32,
    y: f32,

    pub const SIZE: usize = 12;

    pub fn serialize(self: SetPositionMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u32, buf[4..8], @bitCast(self.x), .little);
        std.mem.writeInt(u32, buf[8..12], @bitCast(self.y), .little);
    }

    pub fn deserialize(buf: []const u8) !SetPositionMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .x = @bitCast(std.mem.readInt(u32, buf[4..8], .little)),
            .y = @bitCast(std.mem.readInt(u32, buf[8..12], .little)),
        };
    }
};

/// AD-21 sub-item 7: cursor sprite formats.
///
/// `sprite_format` field on SetCursorMsg selects how the sprite_data
/// bytes that follow the header should be interpreted. Currently only
/// SDCS is supported; other formats are reserved for future use (e.g.
/// raw RGBA8 for sprites that don't benefit from SDCS encoding).
pub const SPRITE_FORMAT_SDCS: u32 = 1;

/// AD-21 sub-item 7: maximum cursor sprite dimensions per ADR 0005 §3.
///
/// Generous limits; typical cursors are 24x24 to 48x48. The cap
/// prevents a malicious or buggy client from making the cursor fill
/// the screen.
pub const SPRITE_MAX_DIM: u32 = 256;

/// Set cursor request: replace the cursor surface's sprite and
/// hotspot. Variable-length payload (header + sprite_data).
///
/// Per ADR 0005 section 5 (amended 2026-05-06: opcode reassigned to
/// 0x0033 from 0x0030, which collided with set_visible). The
/// requesting client must own the currently focused (top visible)
/// client surface; the daemon validates and replies with cursor_set
/// on success or error_reply on failure.
pub const SetCursorMsg = extern struct {
    /// Requester's client id. Filled in by the client; the daemon
    /// also has session.id available, so this is informational and
    /// not load-bearing for security; focus validation walks
    /// session.id, not this field.
    client_id: ClientId,
    /// Hotspot offset in sprite pixels. (0, 0) is the top-left of
    /// the sprite; SET_CURSOR for a centred-tip cursor would pass
    /// (sprite_width/2, sprite_height/2).
    hotspot_x: i32,
    hotspot_y: i32,
    /// Sprite logical dimensions. Both must be ≤ SPRITE_MAX_DIM
    /// (256). The daemon uses these as the surface's
    /// logical_width/height for damage/composition.
    sprite_width: u32,
    sprite_height: u32,
    /// Sprite encoding format (SPRITE_FORMAT_SDCS = 1). Other
    /// values are rejected with EINVAL.
    sprite_format: u32,
    /// Length of sprite data in bytes (follows this header).
    sprite_length: u32,

    /// Bytes of the fixed header. Total payload size on the wire
    /// is HEADER_SIZE + sprite_length.
    pub const HEADER_SIZE: usize = 28;

    pub fn serialize(self: SetCursorMsg, buf: []u8) void {
        std.debug.assert(buf.len >= HEADER_SIZE);
        std.mem.writeInt(u32, buf[0..4], self.client_id, .little);
        std.mem.writeInt(i32, buf[4..8], self.hotspot_x, .little);
        std.mem.writeInt(i32, buf[8..12], self.hotspot_y, .little);
        std.mem.writeInt(u32, buf[12..16], self.sprite_width, .little);
        std.mem.writeInt(u32, buf[16..20], self.sprite_height, .little);
        std.mem.writeInt(u32, buf[20..24], self.sprite_format, .little);
        std.mem.writeInt(u32, buf[24..28], self.sprite_length, .little);
    }

    pub fn deserialize(buf: []const u8) !SetCursorMsg {
        if (buf.len < HEADER_SIZE) return error.BufferTooSmall;
        return .{
            .client_id = std.mem.readInt(u32, buf[0..4], .little),
            .hotspot_x = std.mem.readInt(i32, buf[4..8], .little),
            .hotspot_y = std.mem.readInt(i32, buf[8..12], .little),
            .sprite_width = std.mem.readInt(u32, buf[12..16], .little),
            .sprite_height = std.mem.readInt(u32, buf[16..20], .little),
            .sprite_format = std.mem.readInt(u32, buf[20..24], .little),
            .sprite_length = std.mem.readInt(u32, buf[24..28], .little),
        };
    }
};

/// Cursor set reply: daemon → client acknowledgement that a
/// SET_CURSOR request was accepted and the new sprite is in effect.
/// On rejection the daemon sends error_reply instead.
pub const CursorSetMsg = extern struct {
    /// Status code; 0 = success. Failures are delivered via
    /// error_reply (with the appropriate ErrorCode), not via this
    /// reply, so this field is reserved and currently always 0.
    /// Kept for forward compatibility with reply codes that don't
    /// map to ErrorCode (e.g. partial-success diagnostics).
    status: i32,

    pub const SIZE: usize = 4;

    pub fn serialize(self: CursorSetMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(i32, buf[0..4], self.status, .little);
    }

    pub fn deserialize(buf: []const u8) !CursorSetMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .status = std.mem.readInt(i32, buf[0..4], .little),
        };
    }
};

/// Sync request (barrier)
pub const SyncMsg = extern struct {
    sync_id: u32,

    pub const SIZE: usize = 4;

    pub fn serialize(self: SyncMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.sync_id, .little);
    }

    pub fn deserialize(buf: []const u8) !SyncMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .sync_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

// ============================================================================
// Daemon -> Client Messages
// ============================================================================

/// Hello reply - confirms connection and capabilities
pub const HelloReplyMsg = extern struct {
    version_major: u16,
    version_minor: u16,
    client_id: ClientId,
    server_flags: u32, // Capability flags

    pub const SIZE: usize = 12;

    pub fn serialize(self: HelloReplyMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u16, buf[0..2], self.version_major, .little);
        std.mem.writeInt(u16, buf[2..4], self.version_minor, .little);
        std.mem.writeInt(u32, buf[4..8], self.client_id, .little);
        std.mem.writeInt(u32, buf[8..12], self.server_flags, .little);
    }

    pub fn deserialize(buf: []const u8) !HelloReplyMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .version_major = std.mem.readInt(u16, buf[0..2], .little),
            .version_minor = std.mem.readInt(u16, buf[2..4], .little),
            .client_id = std.mem.readInt(u32, buf[4..8], .little),
            .server_flags = std.mem.readInt(u32, buf[8..12], .little),
        };
    }
};

/// Surface created reply
pub const SurfaceCreatedMsg = extern struct {
    surface_id: SurfaceId,

    pub const SIZE: usize = 4;

    pub fn serialize(self: SurfaceCreatedMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
    }

    pub fn deserialize(buf: []const u8) !SurfaceCreatedMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

/// Buffer released - client can reuse the buffer
pub const BufferReleasedMsg = extern struct {
    surface_id: SurfaceId,

    pub const SIZE: usize = 4;

    pub fn serialize(self: BufferReleasedMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
    }

    pub fn deserialize(buf: []const u8) !BufferReleasedMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

/// Frame complete - frame was presented
pub const FrameCompleteMsg = extern struct {
    surface_id: SurfaceId,
    frame_number: u64,
    timestamp_ns: u64, // Presentation timestamp (nanoseconds since epoch)

    pub const SIZE: usize = 20;

    pub fn serialize(self: FrameCompleteMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u64, buf[4..12], self.frame_number, .little);
        std.mem.writeInt(u64, buf[12..20], self.timestamp_ns, .little);
    }

    pub fn deserialize(buf: []const u8) !FrameCompleteMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .frame_number = std.mem.readInt(u64, buf[4..12], .little),
            .timestamp_ns = std.mem.readInt(u64, buf[12..20], .little),
        };
    }
};

/// Sync done reply
pub const SyncDoneMsg = extern struct {
    sync_id: u32,

    pub const SIZE: usize = 4;

    pub fn serialize(self: SyncDoneMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.sync_id, .little);
    }

    pub fn deserialize(buf: []const u8) !SyncDoneMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .sync_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

/// Error codes
// BEGIN GENERATED CONSTANTS: error_code
// Do not edit. Generated from shared/protocol_constants.json
// by shared/tools/gen_constants.py

pub const ErrorCode = enum(u32) {
    none = 0, // Success
    invalid_message = 1, // Invalid message format
    invalid_surface = 2, // Invalid surface ID
    invalid_buffer = 3, // Invalid buffer
    permission_denied = 4, // Permission denied
    resource_limit = 5, // Resource limit reached
    protocol_error = 6, // Protocol violation
    internal_error = 7, // Internal error
    validation_failed = 8, // Validation failed
};
// END GENERATED CONSTANTS: error_code

/// Error reply
pub const ErrorReplyMsg = extern struct {
    code: ErrorCode,
    context: u32, // Context-specific value (e.g., surface_id)

    pub const SIZE: usize = 8;

    pub fn serialize(self: ErrorReplyMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], @intFromEnum(self.code), .little);
        std.mem.writeInt(u32, buf[4..8], self.context, .little);
    }

    pub fn deserialize(buf: []const u8) !ErrorReplyMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        const code_val = std.mem.readInt(u32, buf[0..4], .little);
        return .{
            .code = std.enums.fromInt(ErrorCode, code_val) orelse .internal_error,
            .context = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

// ============================================================================
// Input Events
// ============================================================================

/// Key press/release event
pub const KeyPressMsg = extern struct {
    surface_id: SurfaceId, // Target surface (focused surface)
    key_code: u32, // Platform key code (evdev on Linux)
    modifiers: u8, // Modifier state: bit 0=shift, bit 1=alt, bit 2=ctrl, bit 3=meta
    pressed: u8, // 1 = pressed, 0 = released
    _reserved: u16 = 0,

    pub const SIZE: usize = 12;

    // Modifier bit masks
    pub const MOD_SHIFT: u8 = 0x01;
    pub const MOD_ALT: u8 = 0x02;
    pub const MOD_CTRL: u8 = 0x04;
    pub const MOD_META: u8 = 0x08;

    pub fn serialize(self: KeyPressMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u32, buf[4..8], self.key_code, .little);
        buf[8] = self.modifiers;
        buf[9] = self.pressed;
        std.mem.writeInt(u16, buf[10..12], self._reserved, .little);
    }

    pub fn deserialize(buf: []const u8) !KeyPressMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .key_code = std.mem.readInt(u32, buf[4..8], .little),
            .modifiers = buf[8],
            .pressed = buf[9],
            ._reserved = std.mem.readInt(u16, buf[10..12], .little),
        };
    }
};

/// Mouse event types
pub const MouseEventType = enum(u8) {
    press = 0,
    release = 1,
    motion = 2,
};

/// Mouse button identifiers
pub const MouseButtonId = enum(u8) {
    left = 0,
    middle = 1,
    right = 2,
    scroll_up = 3,
    scroll_down = 4,
    scroll_left = 5,
    scroll_right = 6,
    button4 = 7,
    button5 = 8,
};

/// Mouse event message
pub const MouseEventMsg = extern struct {
    surface_id: SurfaceId, // Target surface (focused surface)
    x: i32, // X coordinate in pixels
    y: i32, // Y coordinate in pixels
    button: MouseButtonId, // Button involved
    event_type: MouseEventType, // Press, release, or motion
    modifiers: u8, // Modifier state: bit 0=shift, bit 1=alt, bit 2=ctrl, bit 3=meta
    _reserved: u8 = 0,

    pub const SIZE: usize = 16;

    pub fn serialize(self: MouseEventMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(i32, buf[4..8], self.x, .little);
        std.mem.writeInt(i32, buf[8..12], self.y, .little);
        buf[12] = @intFromEnum(self.button);
        buf[13] = @intFromEnum(self.event_type);
        buf[14] = self.modifiers;
        buf[15] = self._reserved;
    }

    pub fn deserialize(buf: []const u8) !MouseEventMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .x = std.mem.readInt(i32, buf[4..8], .little),
            .y = std.mem.readInt(i32, buf[8..12], .little),
            .button = @enumFromInt(buf[12]),
            .event_type = @enumFromInt(buf[13]),
            .modifiers = buf[14],
            ._reserved = buf[15],
        };
    }
};

// ============================================================================
// Gesture Event Messages
// ============================================================================
// See ADR 0017-rev2 (and the 2026-05-04 addendum) for the design contract.
//
// A gesture event consists of a 24-byte flat header followed by a
// per-gesture-type payload (0..20 bytes). Total wire size is 24..44 bytes,
// communicated to the receiver via MsgHeader.length.
//
// The header carries routing information (surface_id, gesture_type, phase,
// finger_count, flags) and one chronofs nanosecond timestamp:
//   - t_current: chronofs ns of the input event that triggered THIS phase
//
// For inactivity-driven transitions (long-press fires, timeout cancels)
// with no triggering input event, t_current is the recogniser's detection
// time.
//
// Clients that want the gesture-begin timestamp observe the
// `phase = begin` event and remember its `t_current` locally; the wire
// does not redundantly carry t_begin on subsequent updates. See the
// rev2 addendum for rationale.
//
// Payload layout per gesture_type is defined by the per-variant payload
// structs below. payloadSize(gesture_type) returns the wire size of the
// payload for a given gesture type.

/// Gesture type tag. Values match libsemainput's LibsemainputOutput enum.
pub const GestureType = enum(u32) {
    n_click = 1,
    drag_start = 2,
    drag_move = 3,
    drag_end = 4,
    tap = 5,
    scroll_begin = 6,
    two_finger_scroll = 7,
    scroll_end = 8,
    pinch_begin = 9,
    pinch = 10,
    pinch_end = 11,
    three_finger_swipe_begin = 12,
    three_finger_swipe = 13,
    three_finger_swipe_end = 14,
    intent_hint = 15,
    _,
};

/// Gesture lifecycle phase.
pub const GesturePhase = enum(u8) {
    begin = 0,
    update = 1,
    end = 2,
    cancel = 3,
    _,
};

/// Gesture modifier flags. Layout matches MouseEventMsg.modifiers but widens
/// to u32 for headroom.
pub const GestureFlags = packed struct(u32) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    meta: bool = false,
    _padding: u28 = 0,
};

/// Gesture event header (24 bytes). The wire payload follows immediately;
/// use payloadSize(gesture_type) to determine its size.
///
/// Per the ADR 0017-rev2 addendum (2026-05-04), only one chronofs
/// nanosecond timestamp is carried on the wire: `t_current`, the
/// timestamp of the input event that triggered THIS phase
/// transition. Clients that want gesture-begin time observe the
/// `phase = begin` event and remember its `t_current` locally.
pub const GestureEventMsg = extern struct {
    surface_id: SurfaceId, // Target surface (focused at emit time)
    gesture_type: GestureType, // u32 enum
    phase: GesturePhase, // u8 enum
    finger_count: u8, // 1..N; 0 reserved for future use
    _reserved: [2]u8 = .{ 0, 0 }, // Must be zero on emit; ignored on decode
    flags: GestureFlags, // Modifier state at the triggering input event
    t_current: u64, // chronofs ns; phase-transition trigger time

    pub const SIZE: usize = 24;

    pub fn serialize(self: GestureEventMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.surface_id, .little);
        std.mem.writeInt(u32, buf[4..8], @intFromEnum(self.gesture_type), .little);
        buf[8] = @intFromEnum(self.phase);
        buf[9] = self.finger_count;
        buf[10] = self._reserved[0];
        buf[11] = self._reserved[1];
        std.mem.writeInt(u32, buf[12..16], @as(u32, @bitCast(self.flags)), .little);
        std.mem.writeInt(u64, buf[16..24], self.t_current, .little);
    }

    pub fn deserialize(buf: []const u8) !GestureEventMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .surface_id = std.mem.readInt(u32, buf[0..4], .little),
            .gesture_type = @enumFromInt(std.mem.readInt(u32, buf[4..8], .little)),
            .phase = @enumFromInt(buf[8]),
            .finger_count = buf[9],
            ._reserved = .{ buf[10], buf[11] },
            .flags = @bitCast(std.mem.readInt(u32, buf[12..16], .little)),
            .t_current = std.mem.readInt(u64, buf[16..24], .little),
        };
    }
};

/// Payload for n_click gestures (16 bytes).
pub const NClickPayload = extern struct {
    button: u32, // MouseButtonId widened to u32
    count: u32, // Click count (2 = double, 3 = triple, ...)
    x: i32,
    y: i32,

    pub const SIZE: usize = 16;

    pub fn serialize(self: NClickPayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.button, .little);
        std.mem.writeInt(u32, buf[4..8], self.count, .little);
        std.mem.writeInt(i32, buf[8..12], self.x, .little);
        std.mem.writeInt(i32, buf[12..16], self.y, .little);
    }

    pub fn deserialize(buf: []const u8) !NClickPayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .button = std.mem.readInt(u32, buf[0..4], .little),
            .count = std.mem.readInt(u32, buf[4..8], .little),
            .x = std.mem.readInt(i32, buf[8..12], .little),
            .y = std.mem.readInt(i32, buf[12..16], .little),
        };
    }
};

/// Payload for drag_start, drag_move, drag_end, tap (12 bytes).
pub const DragPayload = extern struct {
    contact_id: u32,
    x: i32,
    y: i32,

    pub const SIZE: usize = 12;

    pub fn serialize(self: DragPayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.contact_id, .little);
        std.mem.writeInt(i32, buf[4..8], self.x, .little);
        std.mem.writeInt(i32, buf[8..12], self.y, .little);
    }

    pub fn deserialize(buf: []const u8) !DragPayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .contact_id = std.mem.readInt(u32, buf[0..4], .little),
            .x = std.mem.readInt(i32, buf[4..8], .little),
            .y = std.mem.readInt(i32, buf[8..12], .little),
        };
    }
};

/// Payload for two_finger_scroll (8 bytes).
pub const TwoFingerScrollPayload = extern struct {
    dx: i32,
    dy: i32,

    pub const SIZE: usize = 8;

    pub fn serialize(self: TwoFingerScrollPayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(i32, buf[0..4], self.dx, .little);
        std.mem.writeInt(i32, buf[4..8], self.dy, .little);
    }

    pub fn deserialize(buf: []const u8) !TwoFingerScrollPayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .dx = std.mem.readInt(i32, buf[0..4], .little),
            .dy = std.mem.readInt(i32, buf[4..8], .little),
        };
    }
};

/// Payload for pinch_begin (8 bytes).
pub const PinchBeginPayload = extern struct {
    delta: i32,
    scale_factor: f32,

    pub const SIZE: usize = 8;

    pub fn serialize(self: PinchBeginPayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(i32, buf[0..4], self.delta, .little);
        std.mem.writeInt(u32, buf[4..8], @as(u32, @bitCast(self.scale_factor)), .little);
    }

    pub fn deserialize(buf: []const u8) !PinchBeginPayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .delta = std.mem.readInt(i32, buf[0..4], .little),
            .scale_factor = @bitCast(std.mem.readInt(u32, buf[4..8], .little)),
        };
    }
};

/// Pinch direction tag.
pub const PinchDirection = enum(u8) {
    in = 0,
    out = 1,
    _,
};

/// Payload for pinch (12 bytes).
pub const PinchPayload = extern struct {
    delta: i32,
    scale_factor: f32,
    direction: PinchDirection,
    _pad: [3]u8 = .{ 0, 0, 0 },

    pub const SIZE: usize = 12;

    pub fn serialize(self: PinchPayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(i32, buf[0..4], self.delta, .little);
        std.mem.writeInt(u32, buf[4..8], @as(u32, @bitCast(self.scale_factor)), .little);
        buf[8] = @intFromEnum(self.direction);
        buf[9] = self._pad[0];
        buf[10] = self._pad[1];
        buf[11] = self._pad[2];
    }

    pub fn deserialize(buf: []const u8) !PinchPayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .delta = std.mem.readInt(i32, buf[0..4], .little),
            .scale_factor = @bitCast(std.mem.readInt(u32, buf[4..8], .little)),
            .direction = @enumFromInt(buf[8]),
            ._pad = .{ buf[9], buf[10], buf[11] },
        };
    }
};

/// Axis-lock tag for swipe gestures.
pub const SwipeAxis = enum(u8) {
    none = 0,
    horizontal = 1,
    vertical = 2,
    _,
};

/// Payload for three_finger_swipe_begin and three_finger_swipe (20 bytes).
pub const ThreeFingerSwipePayload = extern struct {
    dx: i32,
    dy: i32,
    total_dx: i32,
    total_dy: i32,
    axis_locked: SwipeAxis,
    confidence: u8, // 0..255
    _pad: [2]u8 = .{ 0, 0 },

    pub const SIZE: usize = 20;

    pub fn serialize(self: ThreeFingerSwipePayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(i32, buf[0..4], self.dx, .little);
        std.mem.writeInt(i32, buf[4..8], self.dy, .little);
        std.mem.writeInt(i32, buf[8..12], self.total_dx, .little);
        std.mem.writeInt(i32, buf[12..16], self.total_dy, .little);
        buf[16] = @intFromEnum(self.axis_locked);
        buf[17] = self.confidence;
        buf[18] = self._pad[0];
        buf[19] = self._pad[1];
    }

    pub fn deserialize(buf: []const u8) !ThreeFingerSwipePayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .dx = std.mem.readInt(i32, buf[0..4], .little),
            .dy = std.mem.readInt(i32, buf[4..8], .little),
            .total_dx = std.mem.readInt(i32, buf[8..12], .little),
            .total_dy = std.mem.readInt(i32, buf[12..16], .little),
            .axis_locked = @enumFromInt(buf[16]),
            .confidence = buf[17],
            ._pad = .{ buf[18], buf[19] },
        };
    }
};

/// Intent-hint subject tag.
pub const IntentGesture = enum(u8) {
    two_finger_scroll = 0,
    pinch = 1,
    three_finger_swipe = 2,
    _,
};

/// Intent-hint axis/direction tag.
pub const IntentAxis = enum(u8) {
    none = 0,
    horizontal = 1,
    vertical = 2,
    in = 3,
    out = 4,
    _,
};

/// Payload for intent_hint (4 bytes).
pub const IntentHintPayload = extern struct {
    gesture: IntentGesture,
    axis: IntentAxis,
    confidence: u8,
    _pad: [1]u8 = .{0},

    pub const SIZE: usize = 4;

    pub fn serialize(self: IntentHintPayload, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        buf[0] = @intFromEnum(self.gesture);
        buf[1] = @intFromEnum(self.axis);
        buf[2] = self.confidence;
        buf[3] = self._pad[0];
    }

    pub fn deserialize(buf: []const u8) !IntentHintPayload {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .gesture = @enumFromInt(buf[0]),
            .axis = @enumFromInt(buf[1]),
            .confidence = buf[2],
            ._pad = .{ buf[3] },
        };
    }
};

/// Returns the wire size in bytes of the payload for a given gesture type.
/// Total gesture event wire size is GestureEventMsg.SIZE + payloadSize(t).
pub fn payloadSize(t: GestureType) usize {
    return switch (t) {
        .n_click => NClickPayload.SIZE,
        .drag_start, .drag_move, .drag_end, .tap => DragPayload.SIZE,
        .scroll_begin, .scroll_end, .pinch_end, .three_finger_swipe_end => 0,
        .two_finger_scroll => TwoFingerScrollPayload.SIZE,
        .pinch_begin => PinchBeginPayload.SIZE,
        .pinch => PinchPayload.SIZE,
        .three_finger_swipe_begin, .three_finger_swipe => ThreeFingerSwipePayload.SIZE,
        .intent_hint => IntentHintPayload.SIZE,
        _ => 0, // Unknown gesture type: treat as zero-payload for forward compat
    };
}

// ============================================================================
// Clipboard Messages
// ============================================================================

/// Clipboard selection type
pub const ClipboardSelection = enum(u8) {
    clipboard = 0, // CLIPBOARD (Ctrl+C/V)
    primary = 1, // PRIMARY (mouse selection)
};

/// Clipboard set message - client sets clipboard content
/// Variable length: header followed by text data
pub const ClipboardSetMsg = extern struct {
    selection: ClipboardSelection,
    _reserved: [3]u8 = .{ 0, 0, 0 },
    length: u32, // Length of text data that follows

    pub const HEADER_SIZE: usize = 8;

    pub fn serialize(self: ClipboardSetMsg, buf: []u8) void {
        std.debug.assert(buf.len >= HEADER_SIZE);
        buf[0] = @intFromEnum(self.selection);
        buf[1] = 0;
        buf[2] = 0;
        buf[3] = 0;
        std.mem.writeInt(u32, buf[4..8], self.length, .little);
    }

    pub fn deserialize(buf: []const u8) !ClipboardSetMsg {
        if (buf.len < HEADER_SIZE) return error.BufferTooSmall;
        return .{
            .selection = @enumFromInt(buf[0]),
            ._reserved = .{ buf[1], buf[2], buf[3] },
            .length = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

/// Clipboard request message - client requests clipboard content
pub const ClipboardRequestMsg = extern struct {
    selection: ClipboardSelection,
    _reserved: [3]u8 = .{ 0, 0, 0 },

    pub const SIZE: usize = 4;

    pub fn serialize(self: ClipboardRequestMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        buf[0] = @intFromEnum(self.selection);
        buf[1] = 0;
        buf[2] = 0;
        buf[3] = 0;
    }

    pub fn deserialize(buf: []const u8) !ClipboardRequestMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .selection = @enumFromInt(buf[0]),
            ._reserved = .{ buf[1], buf[2], buf[3] },
        };
    }
};

/// Output info request - client asks the daemon for the size of an
/// output (typically the framebuffer that surfaces will composite to).
///
/// Per ADR 0006 §5, /dev/draw is gated to the _semadraw user; clients
/// cannot open it directly to call DRAWFSGIOC_GET_EFIFB_INFO. The
/// daemon already holds this information from its own backend init
/// path and exposes it via this protocol message.
///
/// output_id is reserved for a future multi-output world; for now the
/// only valid value is 0 (the primary/default output).
pub const OutputInfoRequestMsg = extern struct {
    output_id: u32,

    pub const SIZE: usize = 4;

    pub fn serialize(self: OutputInfoRequestMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.output_id, .little);
    }

    pub fn deserialize(buf: []const u8) !OutputInfoRequestMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .output_id = std.mem.readInt(u32, buf[0..4], .little),
        };
    }
};

/// Output info reply - daemon's response to OutputInfoRequestMsg.
///
/// width and height are in pixels. If the daemon has no output
/// available (e.g. the requested output_id does not exist, or the
/// backend has not initialised an output), it returns ERROR_REPLY
/// with code .invalid_argument rather than this message.
pub const OutputInfoReplyMsg = extern struct {
    output_id: u32,
    width: u32,
    height: u32,

    pub const SIZE: usize = 12;

    pub fn serialize(self: OutputInfoReplyMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u32, buf[0..4], self.output_id, .little);
        std.mem.writeInt(u32, buf[4..8], self.width, .little);
        std.mem.writeInt(u32, buf[8..12], self.height, .little);
    }

    pub fn deserialize(buf: []const u8) !OutputInfoReplyMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .output_id = std.mem.readInt(u32, buf[0..4], .little),
            .width = std.mem.readInt(u32, buf[4..8], .little),
            .height = std.mem.readInt(u32, buf[8..12], .little),
        };
    }
};

/// Idle reply payload (ADR 0013, D-11): the chronofs ns timestamp of
/// the most recent input event semadrawd has observed. The consumer
/// computes idle as chronofs_now minus last_input_ts_ns; a value of 0
/// means no input has been observed since semadrawd startup. The
/// payload is solely this u64.
pub const IdleReplyMsg = extern struct {
    last_input_ts_ns: u64,

    pub const SIZE: usize = 8;

    pub fn serialize(self: IdleReplyMsg, buf: []u8) void {
        std.debug.assert(buf.len >= SIZE);
        std.mem.writeInt(u64, buf[0..8], self.last_input_ts_ns, .little);
    }

    pub fn deserialize(buf: []const u8) !IdleReplyMsg {
        if (buf.len < SIZE) return error.BufferTooSmall;
        return .{
            .last_input_ts_ns = std.mem.readInt(u64, buf[0..8], .little),
        };
    }
};

/// Clipboard data message - daemon sends clipboard content to client
/// Variable length: header followed by text data
pub const ClipboardDataMsg = extern struct {
    selection: ClipboardSelection,
    _reserved: [3]u8 = .{ 0, 0, 0 },
    length: u32, // Length of text data that follows

    pub const HEADER_SIZE: usize = 8;

    pub fn serialize(self: ClipboardDataMsg, buf: []u8) void {
        std.debug.assert(buf.len >= HEADER_SIZE);
        buf[0] = @intFromEnum(self.selection);
        buf[1] = 0;
        buf[2] = 0;
        buf[3] = 0;
        std.mem.writeInt(u32, buf[4..8], self.length, .little);
    }

    pub fn deserialize(buf: []const u8) !ClipboardDataMsg {
        if (buf.len < HEADER_SIZE) return error.BufferTooSmall;
        return .{
            .selection = @enumFromInt(buf[0]),
            ._reserved = .{ buf[1], buf[2], buf[3] },
            .length = std.mem.readInt(u32, buf[4..8], .little),
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MsgHeader serialize/deserialize roundtrip" {
    const hdr = MsgHeader{
        .msg_type = .create_surface,
        .flags = 0x1234,
        .length = 16,
    };
    var buf: [MsgHeader.SIZE]u8 = undefined;
    hdr.serialize(&buf);
    const decoded = try MsgHeader.deserialize(&buf);
    try std.testing.expectEqual(hdr.msg_type, decoded.msg_type);
    try std.testing.expectEqual(hdr.flags, decoded.flags);
    try std.testing.expectEqual(hdr.length, decoded.length);
}

test "CreateSurfaceMsg serialize/deserialize roundtrip" {
    const msg = CreateSurfaceMsg{
        .logical_width = 1280.0,
        .logical_height = 720.0,
        .scale = 2.0,
        .flags = 0,
    };
    var buf: [CreateSurfaceMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try CreateSurfaceMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.logical_width, decoded.logical_width);
    try std.testing.expectEqual(msg.logical_height, decoded.logical_height);
    try std.testing.expectEqual(msg.scale, decoded.scale);
}

test "SetFocusMsg serialize/deserialize roundtrip" {
    const msg = SetFocusMsg{ .surface_id = 42 };
    var buf: [SetFocusMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try SetFocusMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.surface_id, decoded.surface_id);
}

test "SetFocusMsg surface 0 clears focus" {
    // surface_id 0 is the clear-to-NO_FOCUS sentinel (D-7, ADR 0011 D1).
    const msg = SetFocusMsg{ .surface_id = 0 };
    var buf: [SetFocusMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try SetFocusMsg.deserialize(&buf);
    try std.testing.expectEqual(@as(u32, 0), decoded.surface_id);
}

test "SetFocusMsg deserialize rejects short buffer" {
    var buf: [SetFocusMsg.SIZE - 1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, SetFocusMsg.deserialize(&buf));
}

test "FocusChangedMsg serialize/deserialize roundtrip" {
    const msg = FocusChangedMsg{ .surface_id = 7 };
    var buf: [FocusChangedMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try FocusChangedMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.surface_id, decoded.surface_id);
}

test "FocusChangedMsg surface 0 means focus lost" {
    // surface_id 0 to the losing/cleared client (D-7, ADR 0011 D5).
    const msg = FocusChangedMsg{ .surface_id = 0 };
    var buf: [FocusChangedMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try FocusChangedMsg.deserialize(&buf);
    try std.testing.expectEqual(@as(u32, 0), decoded.surface_id);
}

test "HelloMsg version check" {
    const msg = HelloMsg.init();
    try std.testing.expectEqual(PROTOCOL_VERSION_MAJOR, msg.version_major);
    try std.testing.expectEqual(PROTOCOL_VERSION_MINOR, msg.version_minor);
}

// ============================================================================
// Extended Protocol Validation Tests (P3.3)
// ============================================================================

test "AttachBufferMsg serialize/deserialize roundtrip" {
    const msg = AttachBufferMsg{
        .surface_id = 42,
        .shm_size = 1024 * 1024,
        .sdcs_offset = 0,
        .sdcs_length = 4096,
    };
    var buf: [AttachBufferMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try AttachBufferMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.surface_id, decoded.surface_id);
    try std.testing.expectEqual(msg.shm_size, decoded.shm_size);
    try std.testing.expectEqual(msg.sdcs_offset, decoded.sdcs_offset);
    try std.testing.expectEqual(msg.sdcs_length, decoded.sdcs_length);
}

test "HelloReplyMsg serialize/deserialize roundtrip" {
    const msg = HelloReplyMsg{
        .version_major = 0,
        .version_minor = 1,
        .client_id = 12345,
        .server_flags = 0xFF,
    };
    var buf: [HelloReplyMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try HelloReplyMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.version_major, decoded.version_major);
    try std.testing.expectEqual(msg.version_minor, decoded.version_minor);
    try std.testing.expectEqual(msg.client_id, decoded.client_id);
    try std.testing.expectEqual(msg.server_flags, decoded.server_flags);
}

test "KeyPressMsg serialize/deserialize roundtrip" {
    const msg = KeyPressMsg{
        .surface_id = 1,
        .key_code = 0x1E, // KEY_A
        .modifiers = KeyPressMsg.MOD_SHIFT | KeyPressMsg.MOD_CTRL,
        .pressed = 1,
    };
    var buf: [KeyPressMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try KeyPressMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.surface_id, decoded.surface_id);
    try std.testing.expectEqual(msg.key_code, decoded.key_code);
    try std.testing.expectEqual(msg.modifiers, decoded.modifiers);
    try std.testing.expectEqual(msg.pressed, decoded.pressed);
}

test "MouseEventMsg serialize/deserialize roundtrip" {
    const msg = MouseEventMsg{
        .surface_id = 2,
        .x = -100,
        .y = 200,
        .button = .left,
        .event_type = .press,
        .modifiers = 0,
    };
    var buf: [MouseEventMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try MouseEventMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.surface_id, decoded.surface_id);
    try std.testing.expectEqual(msg.x, decoded.x);
    try std.testing.expectEqual(msg.y, decoded.y);
    try std.testing.expectEqual(msg.button, decoded.button);
    try std.testing.expectEqual(msg.event_type, decoded.event_type);
}

test "ErrorReplyMsg serialize/deserialize roundtrip" {
    const msg = ErrorReplyMsg{
        .code = .invalid_surface,
        .context = 999,
    };
    var buf: [ErrorReplyMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try ErrorReplyMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.code, decoded.code);
    try std.testing.expectEqual(msg.context, decoded.context);
}

test "ClipboardSetMsg serialize/deserialize roundtrip" {
    const msg = ClipboardSetMsg{
        .selection = .primary,
        .length = 1024,
    };
    var buf: [ClipboardSetMsg.HEADER_SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try ClipboardSetMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.selection, decoded.selection);
    try std.testing.expectEqual(msg.length, decoded.length);
}

test "reply message type convention" {
    // Replies use 0x8xxx (high bit set)
    try std.testing.expect(@intFromEnum(MsgType.hello_reply) & 0x8000 != 0);
    try std.testing.expect(@intFromEnum(MsgType.surface_created) & 0x8000 != 0);
    try std.testing.expect(@intFromEnum(MsgType.error_reply) & 0x8000 != 0);
    try std.testing.expect(@intFromEnum(MsgType.sync_done) & 0x8000 != 0);

    // Requests use 0x0xxx (high bit clear)
    try std.testing.expect(@intFromEnum(MsgType.hello) & 0x8000 == 0);
    try std.testing.expect(@intFromEnum(MsgType.create_surface) & 0x8000 == 0);
    try std.testing.expect(@intFromEnum(MsgType.disconnect) & 0x8000 == 0);

    // Events use 0x9xxx
    try std.testing.expect(@intFromEnum(MsgType.key_press) >= 0x9000);
    try std.testing.expect(@intFromEnum(MsgType.mouse_event) >= 0x9000);
}

test "message type values match protocol spec" {
    // Verify against shared/protocol_constants.json values
    try std.testing.expectEqual(@as(u16, 0x0001), @intFromEnum(MsgType.hello));
    try std.testing.expectEqual(@as(u16, 0x0010), @intFromEnum(MsgType.create_surface));
    try std.testing.expectEqual(@as(u16, 0x0011), @intFromEnum(MsgType.destroy_surface));
    try std.testing.expectEqual(@as(u16, 0x0020), @intFromEnum(MsgType.attach_buffer));
    try std.testing.expectEqual(@as(u16, 0x0021), @intFromEnum(MsgType.commit));
    try std.testing.expectEqual(@as(u16, 0x0040), @intFromEnum(MsgType.sync));
    try std.testing.expectEqual(@as(u16, 0x00F0), @intFromEnum(MsgType.disconnect));

    try std.testing.expectEqual(@as(u16, 0x8001), @intFromEnum(MsgType.hello_reply));
    try std.testing.expectEqual(@as(u16, 0x8010), @intFromEnum(MsgType.surface_created));
    try std.testing.expectEqual(@as(u16, 0x80F0), @intFromEnum(MsgType.error_reply));

    try std.testing.expectEqual(@as(u16, 0x9001), @intFromEnum(MsgType.key_press));
    try std.testing.expectEqual(@as(u16, 0x9002), @intFromEnum(MsgType.mouse_event));
    try std.testing.expectEqual(@as(u16, 0x9030), @intFromEnum(MsgType.gesture_event));
}

test "MsgHeader size is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), MsgHeader.SIZE);
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(MsgHeader));
}

test "error code values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(ErrorCode.none));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(ErrorCode.invalid_message));
    try std.testing.expectEqual(@as(u32, 8), @intFromEnum(ErrorCode.validation_failed));
}

// ----------------------------------------------------------------------------
// Gesture event tests
// ----------------------------------------------------------------------------

test "GestureEventMsg header size is 24 bytes" {
    try std.testing.expectEqual(@as(usize, 24), GestureEventMsg.SIZE);
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(GestureEventMsg));
}

test "GestureEventMsg header serialize/deserialize roundtrip" {
    const msg = GestureEventMsg{
        .surface_id = 42,
        .gesture_type = .pinch,
        .phase = .update,
        .finger_count = 2,
        .flags = .{ .ctrl = true, .shift = true },
        .t_current = 1_500_000_000,
    };
    var buf: [GestureEventMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try GestureEventMsg.deserialize(&buf);
    try std.testing.expectEqual(msg.surface_id, decoded.surface_id);
    try std.testing.expectEqual(msg.gesture_type, decoded.gesture_type);
    try std.testing.expectEqual(msg.phase, decoded.phase);
    try std.testing.expectEqual(msg.finger_count, decoded.finger_count);
    try std.testing.expectEqual(@as(u32, @bitCast(msg.flags)), @as(u32, @bitCast(decoded.flags)));
    try std.testing.expectEqual(msg.t_current, decoded.t_current);
}

test "GestureEventMsg header rejects short buffer" {
    var buf: [16]u8 = .{0} ** 16;
    try std.testing.expectError(error.BufferTooSmall, GestureEventMsg.deserialize(&buf));
}

test "GestureEventMsg single-timestamp wire (rev2 addendum 2026-05-04)" {
    // The wire format carries one chronofs ns timestamp, t_current,
    // not two. Clients that want gesture-begin time observe the
    // phase=begin event and remember its t_current locally. This
    // test pins the single-timestamp shape so a regression that
    // re-introduces t_begin would have to also revise this test.
    const msg = GestureEventMsg{
        .surface_id = 1,
        .gesture_type = .drag_start,
        .phase = .begin,
        .finger_count = 1,
        .flags = .{},
        .t_current = 12345,
    };
    var buf: [GestureEventMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try GestureEventMsg.deserialize(&buf);
    try std.testing.expectEqual(@as(u64, 12345), decoded.t_current);
    // Header size is exactly 24; if the struct grew a second
    // timestamp the size would jump and this assertion would
    // fail. Belt-and-braces with the dedicated size test above.
    try std.testing.expectEqual(@as(usize, 24), GestureEventMsg.SIZE);
}

test "NClickPayload roundtrip" {
    const p = NClickPayload{ .button = 0, .count = 2, .x = 100, .y = 200 };
    var buf: [NClickPayload.SIZE]u8 = undefined;
    p.serialize(&buf);
    const decoded = try NClickPayload.deserialize(&buf);
    try std.testing.expectEqual(p.button, decoded.button);
    try std.testing.expectEqual(p.count, decoded.count);
    try std.testing.expectEqual(p.x, decoded.x);
    try std.testing.expectEqual(p.y, decoded.y);
}

test "DragPayload roundtrip with negative coords" {
    const p = DragPayload{ .contact_id = 7, .x = -50, .y = -100 };
    var buf: [DragPayload.SIZE]u8 = undefined;
    p.serialize(&buf);
    const decoded = try DragPayload.deserialize(&buf);
    try std.testing.expectEqual(p.contact_id, decoded.contact_id);
    try std.testing.expectEqual(p.x, decoded.x);
    try std.testing.expectEqual(p.y, decoded.y);
}

test "TwoFingerScrollPayload roundtrip" {
    const p = TwoFingerScrollPayload{ .dx = 10, .dy = -20 };
    var buf: [TwoFingerScrollPayload.SIZE]u8 = undefined;
    p.serialize(&buf);
    const decoded = try TwoFingerScrollPayload.deserialize(&buf);
    try std.testing.expectEqual(p.dx, decoded.dx);
    try std.testing.expectEqual(p.dy, decoded.dy);
}

test "PinchBeginPayload roundtrip preserves f32 bit pattern" {
    const p = PinchBeginPayload{ .delta = 5, .scale_factor = 1.25 };
    var buf: [PinchBeginPayload.SIZE]u8 = undefined;
    p.serialize(&buf);
    const decoded = try PinchBeginPayload.deserialize(&buf);
    try std.testing.expectEqual(p.delta, decoded.delta);
    try std.testing.expectEqual(p.scale_factor, decoded.scale_factor);
}

test "PinchPayload roundtrip with direction" {
    const p = PinchPayload{ .delta = -3, .scale_factor = 0.75, .direction = .out };
    var buf: [PinchPayload.SIZE]u8 = undefined;
    p.serialize(&buf);
    const decoded = try PinchPayload.deserialize(&buf);
    try std.testing.expectEqual(p.delta, decoded.delta);
    try std.testing.expectEqual(p.scale_factor, decoded.scale_factor);
    try std.testing.expectEqual(p.direction, decoded.direction);
}

test "ThreeFingerSwipePayload roundtrip" {
    const p = ThreeFingerSwipePayload{
        .dx = 15,
        .dy = 5,
        .total_dx = 120,
        .total_dy = 40,
        .axis_locked = .horizontal,
        .confidence = 200,
    };
    var buf: [ThreeFingerSwipePayload.SIZE]u8 = undefined;
    p.serialize(&buf);
    const decoded = try ThreeFingerSwipePayload.deserialize(&buf);
    try std.testing.expectEqual(p.dx, decoded.dx);
    try std.testing.expectEqual(p.dy, decoded.dy);
    try std.testing.expectEqual(p.total_dx, decoded.total_dx);
    try std.testing.expectEqual(p.total_dy, decoded.total_dy);
    try std.testing.expectEqual(p.axis_locked, decoded.axis_locked);
    try std.testing.expectEqual(p.confidence, decoded.confidence);
}

test "IntentHintPayload roundtrip" {
    const p = IntentHintPayload{
        .gesture = .pinch,
        .axis = .out,
        .confidence = 128,
    };
    var buf: [IntentHintPayload.SIZE]u8 = undefined;
    p.serialize(&buf);
    const decoded = try IntentHintPayload.deserialize(&buf);
    try std.testing.expectEqual(p.gesture, decoded.gesture);
    try std.testing.expectEqual(p.axis, decoded.axis);
    try std.testing.expectEqual(p.confidence, decoded.confidence);
}

test "payloadSize matches per-variant SIZE constants" {
    try std.testing.expectEqual(NClickPayload.SIZE, payloadSize(.n_click));
    try std.testing.expectEqual(DragPayload.SIZE, payloadSize(.drag_start));
    try std.testing.expectEqual(DragPayload.SIZE, payloadSize(.drag_move));
    try std.testing.expectEqual(DragPayload.SIZE, payloadSize(.drag_end));
    try std.testing.expectEqual(DragPayload.SIZE, payloadSize(.tap));
    try std.testing.expectEqual(@as(usize, 0), payloadSize(.scroll_begin));
    try std.testing.expectEqual(@as(usize, 0), payloadSize(.scroll_end));
    try std.testing.expectEqual(@as(usize, 0), payloadSize(.pinch_end));
    try std.testing.expectEqual(@as(usize, 0), payloadSize(.three_finger_swipe_end));
    try std.testing.expectEqual(TwoFingerScrollPayload.SIZE, payloadSize(.two_finger_scroll));
    try std.testing.expectEqual(PinchBeginPayload.SIZE, payloadSize(.pinch_begin));
    try std.testing.expectEqual(PinchPayload.SIZE, payloadSize(.pinch));
    try std.testing.expectEqual(ThreeFingerSwipePayload.SIZE, payloadSize(.three_finger_swipe_begin));
    try std.testing.expectEqual(ThreeFingerSwipePayload.SIZE, payloadSize(.three_finger_swipe));
    try std.testing.expectEqual(IntentHintPayload.SIZE, payloadSize(.intent_hint));
}

test "payloadSize: max wire size is 44 bytes" {
    // Largest payload is ThreeFingerSwipe at 20 bytes; total wire size
    // is GestureEventMsg.SIZE (24, per the rev2 addendum) + 20 = 44
    // bytes. ADR 0017-rev2 makes this number load-bearing for buffer
    // sizing in semadrawd; verify it here so a future payload growth
    // (or a regression that grows the header back to 32) is caught
    // at test time.
    var max_payload: usize = 0;
    inline for (.{
        GestureType.n_click, .drag_start, .drag_move, .drag_end, .tap,
        .scroll_begin, .two_finger_scroll, .scroll_end,
        .pinch_begin, .pinch, .pinch_end,
        .three_finger_swipe_begin, .three_finger_swipe, .three_finger_swipe_end,
        .intent_hint,
    }) |t| {
        const sz = payloadSize(t);
        if (sz > max_payload) max_payload = sz;
    }
    try std.testing.expectEqual(@as(usize, 20), max_payload);
    try std.testing.expectEqual(@as(usize, 44), GestureEventMsg.SIZE + max_payload);
}

test "GestureEventMsg with full event including payload roundtrip" {
    // End-to-end: serialize header + payload to one buffer (as the wire
    // would carry them), deserialize both.
    const header = GestureEventMsg{
        .surface_id = 99,
        .gesture_type = .three_finger_swipe,
        .phase = .update,
        .finger_count = 3,
        .flags = .{ .meta = true },
        .t_current = 200,
    };
    const payload = ThreeFingerSwipePayload{
        .dx = 5,
        .dy = -2,
        .total_dx = 50,
        .total_dy = -20,
        .axis_locked = .horizontal,
        .confidence = 250,
    };
    const total = GestureEventMsg.SIZE + ThreeFingerSwipePayload.SIZE;
    var buf: [total]u8 = undefined;
    header.serialize(buf[0..GestureEventMsg.SIZE]);
    payload.serialize(buf[GestureEventMsg.SIZE..]);
    const decoded_header = try GestureEventMsg.deserialize(buf[0..GestureEventMsg.SIZE]);
    const decoded_payload = try ThreeFingerSwipePayload.deserialize(buf[GestureEventMsg.SIZE..]);
    try std.testing.expectEqual(header.surface_id, decoded_header.surface_id);
    try std.testing.expectEqual(header.gesture_type, decoded_header.gesture_type);
    try std.testing.expectEqual(payload.dx, decoded_payload.dx);
    try std.testing.expectEqual(payload.confidence, decoded_payload.confidence);
}

test "OutputInfoRequestMsg roundtrip" {
    const msg = OutputInfoRequestMsg{ .output_id = 7 };
    var buf: [OutputInfoRequestMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try OutputInfoRequestMsg.deserialize(&buf);
    try std.testing.expectEqual(@as(u32, 7), decoded.output_id);
}

test "OutputInfoReplyMsg roundtrip" {
    const msg = OutputInfoReplyMsg{
        .output_id = 0,
        .width = 3840,
        .height = 2160,
    };
    var buf: [OutputInfoReplyMsg.SIZE]u8 = undefined;
    msg.serialize(&buf);
    const decoded = try OutputInfoReplyMsg.deserialize(&buf);
    try std.testing.expectEqual(@as(u32, 0), decoded.output_id);
    try std.testing.expectEqual(@as(u32, 3840), decoded.width);
    try std.testing.expectEqual(@as(u32, 2160), decoded.height);
}
