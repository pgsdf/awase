const std = @import("std");
const posix = std.posix;
const backend = @import("backend");
const input = @import("input");
const inputfs_input = @import("inputfs_input.zig");

const log = std.log.scoped(.drawfs_backend);

// ioctl via libc (works on both Linux and FreeBSD)
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

fn doIoctl(fd: posix.fd_t, request: u32, arg: usize) c_int {
    return ioctl(@intCast(fd), @intCast(request), arg);
}

// ============================================================================
// drawfs protocol constants and structures
// ============================================================================

const DRAWFS_MAGIC: u32 = 0x31575244; // 'DRW1' little-endian
const DRAWFS_VERSION: u16 = 0x0100; // v1.0
const DRAWFS_FRAME_HDR_SIZE: usize = 16;
const DRAWFS_MSG_HDR_SIZE: usize = 16;

// Message types
const REQ_HELLO: u16 = 0x0001;
const REQ_DISPLAY_LIST: u16 = 0x0010;
const REQ_DISPLAY_OPEN: u16 = 0x0011;
const REQ_SURFACE_CREATE: u16 = 0x0020;
const REQ_SURFACE_DESTROY: u16 = 0x0021;
const REQ_SURFACE_PRESENT: u16 = 0x0022;

const RPL_HELLO: u16 = 0x8001;
const RPL_DISPLAY_LIST: u16 = 0x8010;
const RPL_DISPLAY_OPEN: u16 = 0x8011;
const RPL_SURFACE_CREATE: u16 = 0x8020;
const RPL_SURFACE_DESTROY: u16 = 0x8021;
const RPL_SURFACE_PRESENT: u16 = 0x8022;
const EVT_SURFACE_PRESENTED: u16 = 0x9002;

// Pixel formats
const FMT_XRGB8888: u32 = 1;

// ============================================================================
// ioctl encoding helpers
// ============================================================================
//
// BSD/Linux ioctl command encoding (from sys/ioccom.h):
//   Bits 31-30: Direction (0=none, 1=write, 2=read, 3=read+write)
//   Bits 29-16: Size of the data structure (14 bits, max 16383 bytes)
//   Bits 15-8:  Type (magic character identifying the driver)
//   Bits 7-0:   Command number
//
// _IOWR('D', 0x02, struct) means: read+write, type='D', cmd=0x02, size=sizeof(struct)

const IOC_VOID: u32 = 0x20000000; // no parameters
const IOC_OUT: u32 = 0x40000000; // copy out (read)
const IOC_IN: u32 = 0x80000000; // copy in (write)
const IOC_INOUT: u32 = IOC_IN | IOC_OUT; // read+write (0xC0000000)

/// Computes ioctl command number at comptime, matching _IOC/_IOWR macros.
/// This ensures the encoding stays correct if struct size changes.
fn ioc(dir: u32, typ: u8, nr: u8, comptime T: type) u32 {
    const size: u32 = @sizeOf(T);
    return dir | (size << 16) | (@as(u32, typ) << 8) | nr;
}

/// _IOWR equivalent: read+write ioctl
fn iowr(typ: u8, nr: u8, comptime T: type) u32 {
    return ioc(IOC_INOUT, typ, nr, T);
}

const MapSurfaceReq = extern struct {
    status: i32,
    surface_id: u32,
    stride_bytes: u32,
    bytes_total: u32,
};

// Computed at comptime: _IOWR('D', 0x02, struct drawfs_map_surface)
// If MapSurfaceReq size changes, this will automatically update.
const DRAWFSGIOC_MAP_SURFACE: u32 = iowr('D', 0x02, MapSurfaceReq);

// Compile-time verification that our encoding matches the expected value
comptime {
    // Expected: 0xC0104402 = direction(0xC0) | size(0x10=16) | type('D'=0x44) | cmd(0x02)
    if (DRAWFSGIOC_MAP_SURFACE != 0xC0104402) {
        @compileError("DRAWFSGIOC_MAP_SURFACE encoding mismatch - struct size may have changed");
    }
    if (@sizeOf(MapSurfaceReq) != 16) {
        @compileError("MapSurfaceReq size mismatch - expected 16 bytes");
    }
}

// DRAWFSGIOC_BLIT_TO_EFIFB: copy surface pixels to the EFI framebuffer.
// _IOW('D', 0x04, struct drawfs_blit_to_efifb)
const BlitToEfifb = extern struct {
    src:        u64,    // userspace pointer (const uint8_t *)
    src_stride: u32,
    width:      u32,
    height:     u32,
    dst_x:      u32,
    dst_y:      u32,
    _pad:       u32 = 0,
};
const DRAWFSGIOC_BLIT_TO_EFIFB: u32 = ioc(IOC_IN, 'D', 0x04, BlitToEfifb);

// DRAWFSGIOC_GET_EFIFB_INFO: query EFI framebuffer geometry.
// _IOR('D', 0x05, struct drawfs_efifb_info)
const EfifbInfo = extern struct {
    fb_size:   u64,
    fb_width:  u32,
    fb_height: u32,
    fb_stride: u32,
    fb_bpp:    u32,
    _pad:      u32 = 0,
};
const DRAWFSGIOC_GET_EFIFB_INFO: u32 = ioc(IOC_OUT, 'D', 0x05, EfifbInfo);

// ============================================================================
// Protocol helpers
// ============================================================================

fn align4(n: u32) u32 {
    return (n + 3) & ~@as(u32, 3);
}

// ADR 0010 (audit-refined): fill a caller-owned buffer rather than
// allocating per call. The escape audit found this the sole
// per-frame heap consumer in the hot path (events emit to stack
// buffers; the composite and loop bodies allocate nothing per
// pass), and its lifetime is strictly frame-local, so a persistent
// inline buffer mirroring read_buf removes the per-frame
// mmap/munmap churn (GPA page-run cycling) that paced Round U2.
// Frames are bounded by the same protocol limit as replies; the
// caller passes a buffer and we error rather than overrun.
fn fillFrame(buf: []u8, frame_id: u32, msg_type: u16, msg_id: u32, payload: []const u8) ![]u8 {
    const msg_bytes = align4(@as(u32, @intCast(DRAWFS_MSG_HDR_SIZE + payload.len)));
    const frame_bytes = align4(@as(u32, @intCast(DRAWFS_FRAME_HDR_SIZE)) + msg_bytes);

    if (frame_bytes > buf.len) return error.FrameTooLarge;
    const out = buf[0..frame_bytes];
    @memset(out, 0);

    // Frame header
    std.mem.writeInt(u32, out[0..4], DRAWFS_MAGIC, .little);
    std.mem.writeInt(u16, out[4..6], DRAWFS_VERSION, .little);
    std.mem.writeInt(u16, out[6..8], DRAWFS_FRAME_HDR_SIZE, .little);
    std.mem.writeInt(u32, out[8..12], frame_bytes, .little);
    std.mem.writeInt(u32, out[12..16], frame_id, .little);

    // Message header
    std.mem.writeInt(u16, out[16..18], msg_type, .little);
    std.mem.writeInt(u16, out[18..20], 0, .little); // flags
    std.mem.writeInt(u32, out[20..24], msg_bytes, .little);
    std.mem.writeInt(u32, out[24..28], msg_id, .little);
    std.mem.writeInt(u32, out[28..32], 0, .little); // reserved

    // Payload
    if (payload.len > 0) {
        @memcpy(out[32..][0..payload.len], payload);
    }

    return out;
}

/// A read that does not panic on unknown errnos. std.posix.read carries a
/// fixed list of "known" errnos for read(2) and routes anything else
/// through unexpectedErrno, which dumps a stack trace and propagates a
/// panic-style error. Some legitimate errno values fall outside that
/// list (notably ENXIO, errno 6, returned by the drawfs kernel module
/// when the session is in its closing state) and would therefore
/// crash the daemon during ordinary shutdown sequences.
///
/// This wrapper treats every errno uniformly: any failure returns
/// error.ReadFailed with no panic, no stack trace, no log spam. Callers
/// that want the byte count check it themselves; callers that just
/// want "did the read succeed" use try / catch break.
fn safeRead(fd: posix.fd_t, buf: []u8) !usize {
    const rc = posix.system.read(fd, buf.ptr, buf.len);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.ReadFailed;
    return @intCast(signed);
}

fn readFrame(fd: posix.fd_t, buf: []u8) !usize {
    // Poll for data first (kernel requires poll before read)
    var poll_fds = [_]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
    };
    const poll_result = posix.poll(&poll_fds, 5000) catch |err| {
        log.err("poll failed: {}", .{err});
        return err;
    };
    if (poll_result == 0) {
        log.err("poll timeout waiting for frame", .{});
        return error.Timeout;
    }
    if ((poll_fds[0].revents & posix.POLL.IN) == 0) {
        log.err("poll returned but no POLLIN: revents=0x{x}", .{poll_fds[0].revents});
        return error.PollError;
    }

    // Read entire frame in one syscall (kernel expects atomic read).
    // Use safeRead so unknown errnos (e.g. ENXIO from drawfs session
    // closing) don't crash the daemon during shutdown.
    const n = safeRead(fd, buf) catch |err| {
        log.err("read failed: {}", .{err});
        return err;
    };
    if (n == 0) {
        return error.EndOfFile;
    }

    // Validate header
    if (n < DRAWFS_FRAME_HDR_SIZE) {
        log.err("short read: {} bytes", .{n});
        return error.ShortRead;
    }

    const magic = std.mem.readInt(u32, buf[0..4], .little);
    if (magic != DRAWFS_MAGIC) {
        log.err("invalid magic: 0x{x:08}", .{magic});
        return error.InvalidMagic;
    }

    const frame_bytes = std.mem.readInt(u32, buf[8..12], .little);
    if (n < frame_bytes) {
        log.err("incomplete frame: got {}, expected {}", .{ n, frame_bytes });
        return error.IncompleteFrame;
    }

    return n;
}

fn parseReply(buf: []const u8) struct { msg_type: u16, msg_id: u32, payload: []const u8 } {
    const msg_type = std.mem.readInt(u16, buf[16..18], .little);
    const msg_bytes = std.mem.readInt(u32, buf[20..24], .little);
    const msg_id = std.mem.readInt(u32, buf[24..28], .little);
    const payload_len = msg_bytes - DRAWFS_MSG_HDR_SIZE;
    const payload = buf[32..][0..payload_len];
    return .{ .msg_type = msg_type, .msg_id = msg_id, .payload = payload };
}

// ============================================================================
// Render state
// ============================================================================

/// Per-session render state. Resets to defaults on RESET opcode or new session.
/// Does not leak between client sessions since each client gets its own backend.
pub const RenderState = struct {
    /// Blend mode. 0=SrcOver, 1=Src, 2=Clear, 3=Add.
    blend_mode: u32 = 0,
    /// Antialiasing enabled. When true, filled edges use alpha blending
    /// for sub-pixel coverage on the outer pixel ring.
    antialias: bool = false,
    /// Stroke join style. 0=Miter, 1=Bevel, 2=Round.
    stroke_join: u32 = 0,
    /// Stroke cap style. 0=Butt, 1=Square, 2=Round.
    stroke_cap: u32 = 0,
    /// Miter limit for miter joins (default 4.0).
    miter_limit: f32 = 4.0,

    pub fn reset(self: *RenderState) void {
        self.* = .{};
    }
};

// ============================================================================
// DrawfsBackend
// ============================================================================

pub const DrawfsBackend = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    frame_id: u32,
    msg_id: u32,

    // Display info
    display_id: u32,
    display_handle: u32,
    display_width: u32,
    display_height: u32,

    // Surface info
    surface_id: u32,
    surface_stride: u32,
    surface_bytes: u32,
    surface_map: ?[]align(4096) u8,

    // Render state
    width: u32,
    height: u32,
    frame_count: u64,
    render_state: RenderState,

    // AD-43.3b: pending-blit damage region, surface coordinates,
    // exclusive x1/y1. Accumulated by every buffer writer; consumed
    // and reset by a successful blitToEfifb. Persistent across calls
    // so clearRegion writes (outside renderImpl) reach the screen.
    dmg_any: bool = false,
    dmg_x0: i32 = 0,
    dmg_y0: i32 = 0,
    dmg_x1: i32 = 0,
    dmg_y1: i32 = 0,

    // AD-43 fix path 2: active clip rect, surface coordinates,
    // exclusive x1/y1. Installed by renderImpl from request.clip for
    // the duration of one render and reset on exit, so clearRegion
    // calls (which run outside renderImpl) and the next render start
    // unclipped. Primitives clamp against it exactly as they clamp
    // against the framebuffer; noteDamage intersects with it, so
    // nothing outside the clip is either drawn or blitted.
    clip_active: bool = false,
    clip_x0: i32 = 0,
    clip_y0: i32 = 0,
    clip_x1: i32 = 0,
    clip_y1: i32 = 0,

    // EFI framebuffer info (zeroed if not available)
    efifb_width:  u32,
    efifb_height: u32,
    efifb_stride: u32,
    efifb_bpp:    u32,
    efifb_avail:  bool,

    // Read buffer for protocol
    read_buf: [4096]u8,
    // ADR 0010: persistent frame-framing buffer, reused per send so
    // the hot path performs no per-frame allocation. Bounded like
    // read_buf by the 4096-byte protocol limit.
    frame_buf: [4096]u8,

    /// Key events translated from inputfs ring frames into the
    /// backend.KeyEvent shape. Populated by inputfs.drain() in
    /// pollEventsImpl; consumed and reset by getKeyEventsImpl.
    /// Pre-AD-2a-Phase-3 this buffer also held events parsed from
    /// the legacy DRAWFSGIOC_INJECT_INPUT path (EVT_KEY frames
    /// arriving on /dev/draw alongside protocol replies); that
    /// path was retired with semainputd in Phase 3 step 2. The
    /// "injected_" prefix is kept for source-stability; every
    /// existing caller writes by reference into these arrays via
    /// inputfs.drain, but the events are no longer literally
    /// "injected" via an ioctl.
    injected_keys: [32]backend.KeyEvent = undefined,
    injected_keys_len: usize = 0,

    /// Mouse events translated from inputfs ring frames. Same
    /// lifecycle as injected_keys: populated by inputfs.drain(),
    /// consumed and reset by getMouseEventsImpl. See the
    /// injected_keys comment for the historical context behind
    /// the field name.
    injected_mice: [backend.MAX_MOUSE_EVENTS]backend.MouseEvent = undefined,
    injected_mice_len: usize = 0,

    /// AD-2a Phase 2.4.2: side-channel buffer for raw inputfs events.
    /// Every event drained from the inputfs ring is appended here
    /// BEFORE the typed-event dispatch path (which drops touch and
    /// pen events). semadrawd's main loop reads this buffer in
    /// Phase 2.4.4 to feed the gesture recogniser, which needs the
    /// device_slot field that translated MouseEvents don't carry.
    /// Sized to match inputfs_input.DRAIN_BATCH so no events drop on
    /// the per-call boundary; consumed and reset by
    /// getInputfsEventsImpl.
    injected_inputfs_events: [inputfs_input.DRAIN_BATCH]input.Event = undefined,
    injected_inputfs_events_len: usize = 0,

    /// inputfs ring reader. Populated by init() if /var/run/sema/input/events
    /// is present and valid; null otherwise (compositor still starts but
    /// receives no input from inputfs). Drained once per pollEventsImpl.
    ///
    /// AD-2a follow-up (inputfs-ring startup race): inputfs publishes
    /// this ring asynchronously during its staged HID attach. At boot,
    /// semadrawd's first probe in init() can lose the race and find
    /// the ring absent, which previously left this null forever and
    /// every downstream client (e.g. pgsd-sessiond's login screen)
    /// permanently keyboard-dead. pollEventsImpl now retries (throttled
    /// via inputfs_retry_ticks) until it latches. Once non-null it is
    /// never re-probed; the retry path is a single counter compare
    /// per frame in the already-existing else branch.
    ///
    /// Replaces the previous `input: ?*bsdinput.BsdInput` field that was
    /// retained as vestigial through Phase 1's first commit; that field
    /// was always null under -b drawfs (input always arrived via the
    /// drawfs-injection path before Phase 1, and via the inputfs ring
    /// after) and is no longer carried.
    inputfs: ?inputfs_input.InputfsInput,

    /// Frame counter for throttling the inputfs re-probe while
    /// `inputfs == null`. pollEventsImpl re-attempts InputfsInput.init
    /// only every INPUTFS_RETRY_INTERVAL polls so the open()+mmap()
    /// probe is not run every frame while inputfs is still publishing.
    /// Unused (and irrelevant) once inputfs has latched.
    inputfs_retry_ticks: u32 = 0,


    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device_path: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .fd = -1,
            .frame_id = 1,
            .msg_id = 1,
            .display_id = 0,
            .display_handle = 0,
            .display_width = 0,
            .display_height = 0,
            .surface_id = 0,
            .surface_stride = 0,
            .surface_bytes = 0,
            .surface_map = null,
            .width = 0,
            .height = 0,
            .frame_count = 0,
            .render_state = .{},
            .read_buf = undefined,
            .frame_buf = undefined,
            .inputfs = null,
            .efifb_width  = 0,
            .efifb_height = 0,
            .efifb_stride = 0,
            .efifb_bpp    = 0,
            .efifb_avail  = false,
        };

        // Open device
        log.info("opening {s}...", .{device_path});
        self.fd = posix.open(device_path, .{ .ACCMODE = .RDWR }, 0) catch {
            log.err("failed to open {s}", .{device_path});
            return error.OpenFailed;
        };
        errdefer posix.close(self.fd);
        log.info("opened {s}, fd={}", .{ device_path, self.fd });

        // Protocol handshake
        log.info("sending HELLO...", .{});
        try self.doHello();
        log.info("HELLO complete, sending DISPLAY_LIST...", .{});
        try self.doDisplayList();
        log.info("DISPLAY_LIST complete, sending DISPLAY_OPEN...", .{});
        try self.doDisplayOpen();

        log.info("connected to drawfs: display {}x{}", .{ self.display_width, self.display_height });

        // Probe EFI framebuffer availability
        self.probeEfifb();

        // Input is delivered from the inputfs event ring at
        // /var/run/sema/input/events. inputfs.ko owns HID at the kernel
        // level (Stages A-D of AD-1) and publishes a shared-memory ring
        // that this backend drains once per frame. The drawfs backend
        // does not open evdev devices directly: doing so would
        // interfere with inputfs's hidbus attachment (ADR 0007) which
        // claims devices exclusively under UTF Mode.
        //
        // If inputfs is not loaded or the ring is not yet valid, the
        // compositor still starts; input simply does not arrive from
        // this source on THIS probe. quiet=false: the first probe
        // reports a genuinely absent inputfs once, loudly. If the
        // ring is merely not published yet (the boot race), this
        // returns null here and pollEventsImpl retries quietly until
        // inputfs finishes publishing.
        self.inputfs = inputfs_input.InputfsInput.init(false);

        return self;
    }

    pub fn initDefault(allocator: std.mem.Allocator) !*Self {
        return init(allocator, "/dev/draw");
    }

    fn nextFrameId(self: *Self) u32 {
        const id = self.frame_id;
        self.frame_id +%= 1;
        return id;
    }

    fn nextMsgId(self: *Self) u32 {
        const id = self.msg_id;
        self.msg_id +%= 1;
        return id;
    }

    fn sendAndRecv(self: *Self, msg_type: u16, payload: []const u8, expected_reply: u16) ![]const u8 {
        const frame_id = self.nextFrameId();
        const msg_id = self.nextMsgId();

        // ADR 0010: build into the persistent frame_buf; no per-frame
        // allocation, no defer free, no GPA page-run churn.
        const frame = try fillFrame(&self.frame_buf, frame_id, msg_type, msg_id, payload);

        // Send frame
        var sent: usize = 0;
        while (sent < frame.len) {
            sent += posix.write(self.fd, frame[sent..]) catch |err| {
                return err;
            };
        }

        // Read reply. The fd is multiplexed with EVT_SURFACE_PRESENTED
        // events emitted by our own SURFACE_PRESENT requests; loop
        // until the expected protocol reply arrives.
        while (true) {
            const n = try readFrame(self.fd, &self.read_buf);
            const reply = parseReply(self.read_buf[0..n]);

            // Skip compositor-acknowledgement events.
            if (reply.msg_type == EVT_SURFACE_PRESENTED) {
                continue;
            }

            if (reply.msg_type != expected_reply) {
                log.err("expected reply 0x{x:04}, got 0x{x:04}", .{ expected_reply, reply.msg_type });
                return error.UnexpectedReply;
            }

            return reply.payload;
        }
    }

    fn doHello(self: *Self) !void {
        var payload: [12]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], 1, .little); // client_major
        std.mem.writeInt(u16, payload[2..4], 0, .little); // client_minor
        std.mem.writeInt(u32, payload[4..8], 0, .little); // client_flags
        std.mem.writeInt(u32, payload[8..12], 4096, .little); // max_reply_bytes

        const reply = try self.sendAndRecv(REQ_HELLO, &payload, RPL_HELLO);

        if (reply.len < 16) return error.InvalidReply;

        const status = std.mem.readInt(i32, reply[0..4], .little);
        if (status != 0) {
            log.err("HELLO failed: status={}", .{status});
            return error.HelloFailed;
        }

        const server_major = std.mem.readInt(u16, reply[4..6], .little);
        const server_minor = std.mem.readInt(u16, reply[6..8], .little);
        log.info("drawfs protocol v{}.{}", .{ server_major, server_minor });
    }

    fn doDisplayList(self: *Self) !void {
        const reply = try self.sendAndRecv(REQ_DISPLAY_LIST, &[_]u8{}, RPL_DISPLAY_LIST);

        if (reply.len < 8) return error.InvalidReply;

        const status = std.mem.readInt(i32, reply[0..4], .little);
        if (status != 0) {
            log.err("DISPLAY_LIST failed: status={}", .{status});
            return error.DisplayListFailed;
        }

        const count = std.mem.readInt(u32, reply[4..8], .little);
        if (count == 0) return error.NoDisplays;

        // Parse first display descriptor (20 bytes each: display_id, width, height, refresh_mhz, flags)
        if (reply.len < 8 + 20) return error.InvalidReply;

        self.display_id = std.mem.readInt(u32, reply[8..12], .little);
        self.display_width = std.mem.readInt(u32, reply[12..16], .little);
        self.display_height = std.mem.readInt(u32, reply[16..20], .little);
        const refresh_mhz = std.mem.readInt(u32, reply[20..24], .little);

        log.info("display {}: {}x{}@{}mHz", .{
            self.display_id,
            self.display_width,
            self.display_height,
            refresh_mhz,
        });
    }

    fn doDisplayOpen(self: *Self) !void {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], self.display_id, .little);

        const reply = try self.sendAndRecv(REQ_DISPLAY_OPEN, &payload, RPL_DISPLAY_OPEN);

        if (reply.len < 12) return error.InvalidReply;

        const status = std.mem.readInt(i32, reply[0..4], .little);
        if (status != 0) {
            log.err("DISPLAY_OPEN failed: status={}", .{status});
            return error.DisplayOpenFailed;
        }

        self.display_handle = std.mem.readInt(u32, reply[4..8], .little);
        log.info("display opened: handle={}", .{self.display_handle});
    }

    fn createSurface(self: *Self, width: u32, height: u32) !void {
        var payload: [16]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], width, .little);
        std.mem.writeInt(u32, payload[4..8], height, .little);
        std.mem.writeInt(u32, payload[8..12], FMT_XRGB8888, .little);
        std.mem.writeInt(u32, payload[12..16], 0, .little); // flags

        const reply = try self.sendAndRecv(REQ_SURFACE_CREATE, &payload, RPL_SURFACE_CREATE);

        if (reply.len < 16) return error.InvalidReply;

        const status = std.mem.readInt(i32, reply[0..4], .little);
        if (status != 0) {
            log.err("SURFACE_CREATE failed: status={}", .{status});
            return error.SurfaceCreateFailed;
        }

        self.surface_id = std.mem.readInt(u32, reply[4..8], .little);
        self.surface_stride = std.mem.readInt(u32, reply[8..12], .little);
        self.surface_bytes = std.mem.readInt(u32, reply[12..16], .little);
        self.width = width;
        self.height = height;

        log.info("surface created: id={} stride={} bytes={}", .{
            self.surface_id,
            self.surface_stride,
            self.surface_bytes,
        });

        // Map the surface
        try self.mapSurface();
    }

    fn mapSurface(self: *Self) !void {
        var req = MapSurfaceReq{
            .status = 0,
            .surface_id = self.surface_id,
            .stride_bytes = 0,
            .bytes_total = 0,
        };

        // Call ioctl
        const result = doIoctl(self.fd, DRAWFSGIOC_MAP_SURFACE, @intFromPtr(&req));
        if (result < 0) {
            log.err("MAP_SURFACE ioctl failed: {}", .{result});
            return error.MapSurfaceFailed;
        }

        if (req.status != 0) {
            log.err("MAP_SURFACE status={}", .{req.status});
            return error.MapSurfaceFailed;
        }

        // mmap the surface
        const map = posix.mmap(
            null,
            self.surface_bytes,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            self.fd,
            0,
        ) catch |err| {
            log.err("mmap failed: {}", .{err});
            return error.MmapFailed;
        };

        self.surface_map = @as([*]align(4096) u8, @ptrCast(@alignCast(map)))[0..self.surface_bytes];
        log.info("surface mapped: {} bytes at {*}", .{ self.surface_bytes, self.surface_map.?.ptr });
    }

    fn destroySurface(self: *Self) void {
        if (self.surface_map) |m| {
            posix.munmap(m);
            self.surface_map = null;
        }

        if (self.surface_id != 0) {
            var payload: [4]u8 = undefined;
            std.mem.writeInt(u32, payload[0..4], self.surface_id, .little);

            _ = self.sendAndRecv(REQ_SURFACE_DESTROY, &payload, RPL_SURFACE_DESTROY) catch {};
            self.surface_id = 0;
        }
    }

    /// Query the kernel for EFI framebuffer availability and geometry.
    /// Non-fatal: if the ioctl fails (ENODEV) we stay in swap-only mode.
    fn probeEfifb(self: *Self) void {
        var info = std.mem.zeroes(EfifbInfo);
        const result = doIoctl(self.fd, DRAWFSGIOC_GET_EFIFB_INFO, @intFromPtr(&info));
        if (result != 0) {
            log.info("efifb not available (ioctl returned {})", .{result});
            return;
        }
        self.efifb_width  = info.fb_width;
        self.efifb_height = info.fb_height;
        self.efifb_stride = info.fb_stride;
        self.efifb_bpp    = info.fb_bpp;
        self.efifb_avail  = true;
        // AD-43.3b: the first blit after availability must cover the
        // whole screen regardless of what has been drawn since.
        self.noteDamageAll();
        log.info("efifb available: {}x{} stride={} bpp={}", .{
            info.fb_width, info.fb_height, info.fb_stride, info.fb_bpp,
        });
    }

    /// AD-43.3b damage accumulator: union a just-written rect
    /// (surface coordinates, exclusive x1/y1) into the pending blit
    /// region. Clamps to surface bounds; empty rects are ignored.
    /// Every code path that writes surface pixels must pass through
    /// here (or noteDamageAll), or its pixels never reach the EFI
    /// framebuffer.
    fn noteDamage(self: *Self, x0: i32, y0: i32, x1: i32, y1: i32) void {
        const w: i32 = @intCast(self.width);
        const h: i32 = @intCast(self.height);
        // AD-43 fix path 2: damage also intersects the active clip.
        // Nothing outside the clip is drawn, so nothing outside it
        // may be blitted; one point of truth covers both.
        const lx0: i32 = if (self.clip_active) @max(x0, self.clip_x0) else x0;
        const ly0: i32 = if (self.clip_active) @max(y0, self.clip_y0) else y0;
        const lx1: i32 = if (self.clip_active) @min(x1, self.clip_x1) else x1;
        const ly1: i32 = if (self.clip_active) @min(y1, self.clip_y1) else y1;
        const cx0 = @max(0, lx0);
        const cy0 = @max(0, ly0);
        const cx1 = @min(w, lx1);
        const cy1 = @min(h, ly1);
        if (cx0 >= cx1 or cy0 >= cy1) return;
        if (self.dmg_any) {
            self.dmg_x0 = @min(self.dmg_x0, cx0);
            self.dmg_y0 = @min(self.dmg_y0, cy0);
            self.dmg_x1 = @max(self.dmg_x1, cx1);
            self.dmg_y1 = @max(self.dmg_y1, cy1);
        } else {
            self.dmg_x0 = cx0;
            self.dmg_y0 = cy0;
            self.dmg_x1 = cx1;
            self.dmg_y1 = cy1;
            self.dmg_any = true;
        }
    }

    fn noteDamageAll(self: *Self) void {
        self.noteDamage(0, 0, @intCast(self.width), @intCast(self.height));
    }

    /// Blit the damaged region of the mmap'd surface buffer to the EFI
    /// framebuffer via kernel ioctl (AD-43.3b: subrect blit). The
    /// kernel handler reads `width` bytes-per-row starting at `src`,
    /// so the source pointer is offset to the rect origin and the
    /// stride is unchanged; no ABI change. Damage is consumed by a
    /// successful blit and kept on failure for the next attempt. No
    /// damage, no ioctl.
    fn blitToEfifb(self: *Self) void {
        if (!self.efifb_avail) return;
        const map = self.surface_map orelse return;
        if (!self.dmg_any) return;

        // Clamp against both surface and efifb geometry. The kernel
        // handler does not bounds-check dst_x + width against the
        // efifb row, so this clamp is load-bearing, not cosmetic.
        const lim_w: i32 = @intCast(@min(self.width, self.efifb_width));
        const lim_h: i32 = @intCast(@min(self.height, self.efifb_height));
        const x0: i32 = @max(0, self.dmg_x0);
        const y0: i32 = @max(0, self.dmg_y0);
        const x1: i32 = @min(lim_w, self.dmg_x1);
        const y1: i32 = @min(lim_h, self.dmg_y1);
        if (x0 >= x1 or y0 >= y1) {
            self.dmg_any = false;
            return;
        }

        const src_off: u64 = @as(u64, @intCast(y0)) * self.surface_stride +
            @as(u64, @intCast(x0)) * 4;
        const req = BlitToEfifb{
            .src        = @intFromPtr(map.ptr) + src_off,
            .src_stride = self.surface_stride,
            .width      = @intCast(x1 - x0),
            .height     = @intCast(y1 - y0),
            .dst_x      = @intCast(x0),
            .dst_y      = @intCast(y0),
        };

        const result = doIoctl(self.fd, DRAWFSGIOC_BLIT_TO_EFIFB, @intFromPtr(&req));
        if (result != 0) {
            log.warn("BLIT_TO_EFIFB failed: {}", .{result});
            return;
        }
        self.dmg_any = false;
    }

    fn present(self: *Self) !void {
        if (self.surface_id == 0) return error.NoSurface;

        var payload: [16]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], self.surface_id, .little);
        std.mem.writeInt(u32, payload[4..8], 0, .little); // flags
        std.mem.writeInt(u64, payload[8..16], self.frame_count, .little); // cookie

        const reply = try self.sendAndRecv(REQ_SURFACE_PRESENT, &payload, RPL_SURFACE_PRESENT);

        if (reply.len < 4) return error.InvalidReply;

        const status = std.mem.readInt(i32, reply[0..4], .little);
        if (status != 0) {
            log.warn("SURFACE_PRESENT status={}", .{status});
        }
    }

    pub fn deinit(self: *Self) void {
        // Cleanup inputfs ring reader
        if (self.inputfs) |*ifs| {
            ifs.deinit();
        }

        self.destroySurface();

        if (self.fd >= 0) {
            posix.close(self.fd);
            self.fd = -1;
        }

        self.allocator.destroy(self);
    }

    // ========================================================================
    // Backend interface implementation
    // ========================================================================

    fn getCapabilitiesImpl(ctx: *anyopaque) backend.Capabilities {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return .{
            .name = "drawfs",
            .max_width = if (self.display_width > 0) self.display_width else 8192,
            .max_height = if (self.display_height > 0) self.display_height else 8192,
            .supports_aa = true,
            .hardware_accelerated = false,
            .can_present = true,
        };
    }

    fn initFramebufferImpl(ctx: *anyopaque, config: backend.FramebufferConfig) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Destroy existing surface if different size
        if (self.surface_id != 0 and (self.width != config.width or self.height != config.height)) {
            self.destroySurface();
        }

        // Create surface if needed
        if (self.surface_id == 0) {
            try self.createSurface(config.width, config.height);
        }
    }

    /// AD-21 sub-item 9 / region damage: clear a framebuffer rect to a
    /// background color. Unlike fillRect (which honors the SDCS blend
    /// mode and antialias), clearRegion writes opaque pixels directly
    /// to overwrite whatever was there. Used by the compositor at the
    /// start of each composite cycle to wipe pixels that no surface
    /// will repaint (e.g. the cursor's old position when no underlying
    /// client surface covers the area).
    fn clearRegionImpl(ctx: *anyopaque, request: backend.ClearRegionRequest) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const buffer = self.surface_map orelse return error.NoSurfaceMapped;

        // BGRX byte order matches the EFI framebuffer that drawfs is
        // mapped over and the renderImpl clear path above.
        const r: u8 = @intFromFloat(@min(1.0, @max(0.0, request.color[0])) * 255.0);
        const g: u8 = @intFromFloat(@min(1.0, @max(0.0, request.color[1])) * 255.0);
        const b: u8 = @intFromFloat(@min(1.0, @max(0.0, request.color[2])) * 255.0);

        // Clamp the rect to framebuffer bounds. Surface stride is in
        // bytes, four bytes per pixel.
        const fb_w_i: i32 = @intCast(self.width);
        const fb_h_i: i32 = @intCast(self.height);
        const x0: i32 = @max(0, request.x);
        const y0: i32 = @max(0, request.y);
        const x1: i32 = @min(fb_w_i, request.x + @as(i32, @intCast(request.width)));
        const y1: i32 = @min(fb_h_i, request.y + @as(i32, @intCast(request.height)));
        if (x0 >= x1 or y0 >= y1) return;
        self.noteDamage(x0, y0, x1, y1); // AD-43.3b

        const stride = self.surface_stride;
        var py: i32 = y0;
        while (py < y1) : (py += 1) {
            var px: i32 = x0;
            while (px < x1) : (px += 1) {
                const idx = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(px)) * 4;
                if (idx + 3 < buffer.len) {
                    buffer[idx] = b;
                    buffer[idx + 1] = g;
                    buffer[idx + 2] = r;
                    buffer[idx + 3] = 0xFF;
                }
            }
        }
    }

    fn renderImpl(ctx: *anyopaque, request: backend.RenderRequest) anyerror!backend.RenderResult {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const start = monotonicNowNs();

        const buffer = self.surface_map orelse {
            return backend.RenderResult.failure(request.surface_id, "no surface mapped");
        };

        // AD-43 fix path 2: install the request's clip for this
        // render. A clip that clamps to empty (damage entirely off
        // the framebuffer) stays active as a zero rect: everything
        // is clipped out, which is the correct meaning. null clip
        // means unclipped, the pre-existing behaviour bit for bit.
        if (request.clip) |c| {
            const cw: i32 = @intCast(self.width);
            const ch: i32 = @intCast(self.height);
            self.clip_x0 = @max(0, c.x);
            self.clip_y0 = @max(0, c.y);
            self.clip_x1 = @min(cw, c.x + @as(i32, @intCast(c.width)));
            self.clip_y1 = @min(ch, c.y + @as(i32, @intCast(c.height)));
            if (self.clip_x0 >= self.clip_x1 or self.clip_y0 >= self.clip_y1) {
                self.clip_x0 = 0;
                self.clip_y0 = 0;
                self.clip_x1 = 0;
                self.clip_y1 = 0;
            }
            self.clip_active = true;
        }
        defer self.clip_active = false;

        // Clear if requested (XRGB8888 format: B, G, R, X)
        if (request.clear_color) |color| {
            const r: u8 = @intFromFloat(@min(1.0, @max(0.0, color[0])) * 255.0);
            const g: u8 = @intFromFloat(@min(1.0, @max(0.0, color[1])) * 255.0);
            const b: u8 = @intFromFloat(@min(1.0, @max(0.0, color[2])) * 255.0);

            // AD-43 fix path 2: clear only the active clip (this
            // surface's damage for the frame); full surface when
            // unclipped. Uses the AD-43.1 fast row fill in place of
            // the previous per-byte full-buffer loop; the per-byte
            // loop survives only as the fallback for a stride that
            // is not a multiple of 4 (never seen on real hardware).
            const cw: i32 = @intCast(self.width);
            const ch: i32 = @intCast(self.height);
            const cx0: i32 = if (self.clip_active) self.clip_x0 else 0;
            const cy0: i32 = if (self.clip_active) self.clip_y0 else 0;
            const cx1: i32 = if (self.clip_active) self.clip_x1 else cw;
            const cy1: i32 = if (self.clip_active) self.clip_y1 else ch;
            if (self.surface_stride % 4 == 0) {
                if (cx0 < cx1 and cy0 < cy1) {
                    const pixel: u32 = (@as(u32, 0xFF) << 24) |
                        (@as(u32, r) << 16) |
                        (@as(u32, g) << 8) |
                        @as(u32, b);
                    fillRectFast(buffer, self.surface_stride, cx0, cy0, cx1, cy1, pixel);
                    self.noteDamage(cx0, cy0, cx1, cy1);
                }
            } else {
                var i: usize = 0;
                while (i + 3 < buffer.len) : (i += 4) {
                    buffer[i] = b;
                    buffer[i + 1] = g;
                    buffer[i + 2] = r;
                    buffer[i + 3] = 0xFF; // X = opaque
                }
                self.noteDamageAll();
            }
        }

        // Execute SDCS commands. The offset_x / offset_y from the
        // RenderRequest carries the surface's screen position; SDCS
        // commands inside this surface use surface-local coordinates,
        // so we translate them by (offset_x, offset_y) when writing
        // pixels into the framebuffer (per ADR 0005 section 3a).
        const offset_xf: f32 = @floatFromInt(request.offset_x);
        const offset_yf: f32 = @floatFromInt(request.offset_y);
        self.executeSdcs(buffer, request.sdcs_data, offset_xf, offset_yf) catch |err| {
            return backend.RenderResult.failure(request.surface_id, @errorName(err));
        };

        // Present to drawfs
        self.present() catch |err| {
            log.warn("present failed: {}", .{err});
        };

        // Blit to EFI framebuffer for bare console display
        self.blitToEfifb();

        self.frame_count += 1;
        const end = monotonicNowNs();

        return backend.RenderResult.success(
            request.surface_id,
            self.frame_count,
            @intCast(end - start),
        );
    }

    fn executeSdcs(self: *Self, fb: []u8, data: []const u8, offset_x: f32, offset_y: f32) !void {
        if (data.len < 64) return; // Header too small

        // Skip SDCS header (64 bytes)
        var offset: usize = 64;

        // Process chunks
        while (offset + 32 <= data.len) {
            // ChunkHeader is 32 bytes
            const chunk_payload_bytes = std.mem.readInt(u64, data[offset + 24 ..][0..8], .little);
            offset += 32;

            if (offset + chunk_payload_bytes > data.len) break;

            // Process commands in chunk
            const chunk_end = offset + @as(usize, @intCast(chunk_payload_bytes));
            try self.executeChunkCommands(fb, data[offset..chunk_end], offset_x, offset_y);

            // Align to 8 bytes for next chunk
            offset = chunk_end;
            offset = std.mem.alignForward(usize, offset, 8);
        }
    }

    fn executeChunkCommands(self: *Self, fb: []u8, commands: []const u8, offset_x: f32, offset_y: f32) !void {
        var offset: usize = 0;

        while (offset + 8 <= commands.len) {
            const opcode = std.mem.readInt(u16, commands[offset..][0..2], .little);
            const payload_len = std.mem.readInt(u32, commands[offset + 4 ..][0..4], .little);
            offset += 8;

            if (offset + payload_len > commands.len) break;

            const payload = commands[offset..][0..payload_len];

            // Execute command
            switch (opcode) {
                0x0001 => { // RESET: reset render state and clear any clip
                    self.render_state.reset();
                },
                0x0004 => { // SET_BLEND (4 bytes: u32 blend_mode)
                    if (payload.len >= 4) {
                        self.render_state.blend_mode = std.mem.readInt(u32, payload[0..4], .little);
                    }
                },
                0x0007 => { // SET_ANTIALIAS (4 bytes: u32 enabled)
                    if (payload.len >= 4) {
                        self.render_state.antialias = std.mem.readInt(u32, payload[0..4], .little) != 0;
                    }
                },
                0x0013 => { // SET_STROKE_JOIN (4 bytes: u32 join)
                    if (payload.len >= 4) {
                        self.render_state.stroke_join = std.mem.readInt(u32, payload[0..4], .little);
                    }
                },
                0x0014 => { // SET_STROKE_CAP (4 bytes: u32 cap)
                    if (payload.len >= 4) {
                        self.render_state.stroke_cap = std.mem.readInt(u32, payload[0..4], .little);
                    }
                },
                0x0015 => { // SET_MITER_LIMIT (4 bytes: f32 limit)
                    if (payload.len >= 4) {
                        self.render_state.miter_limit = readF32(payload[0..4]);
                    }
                },
                0x0010 => { // FILL_RECT (32 bytes: x, y, w, h, r, g, b, a)
                    if (payload.len >= 32) {
                        const x = readF32(payload[0..4]);
                        const y = readF32(payload[4..8]);
                        const w = readF32(payload[8..12]);
                        const h = readF32(payload[12..16]);
                        const r = readF32(payload[16..20]);
                        const g = readF32(payload[20..24]);
                        const b_val = readF32(payload[24..28]);
                        const a = readF32(payload[28..32]);

                        // Translate surface-local coords to framebuffer
                        // coords by applying the surface's offset.
                        self.fillRect(fb, x + offset_x, y + offset_y, w, h, r, g, b_val, a);
                    }
                },
                0x0011 => { // STROKE_RECT (36 bytes: x, y, w, h, r, g, b, a, stroke_width)
                    if (payload.len >= 36) {
                        const x = readF32(payload[0..4]);
                        const y = readF32(payload[4..8]);
                        const w = readF32(payload[8..12]);
                        const h = readF32(payload[12..16]);
                        const r = readF32(payload[16..20]);
                        const g = readF32(payload[20..24]);
                        const b_val = readF32(payload[24..28]);
                        const a = readF32(payload[28..32]);
                        const stroke_width = readF32(payload[32..36]);

                        // Translate surface-local coords to framebuffer.
                        self.strokeRect(fb, x + offset_x, y + offset_y, w, h, r, g, b_val, a, stroke_width);
                    }
                },
                0x0012 => { // STROKE_LINE (36 bytes: x1, y1, x2, y2, r, g, b, a, stroke_width)
                    if (payload.len >= 36) {
                        const x1 = readF32(payload[0..4]);
                        const y1 = readF32(payload[4..8]);
                        const x2 = readF32(payload[8..12]);
                        const y2 = readF32(payload[12..16]);
                        const r = readF32(payload[16..20]);
                        const g = readF32(payload[20..24]);
                        const b_val = readF32(payload[24..28]);
                        const a = readF32(payload[28..32]);
                        const stroke_width = readF32(payload[32..36]);

                        // Translate surface-local coords to framebuffer.
                        self.strokeLine(fb, x1 + offset_x, y1 + offset_y, x2 + offset_x, y2 + offset_y, r, g, b_val, a, stroke_width);
                    }
                },
                0x00F0 => return, // END
                0x0030 => { // DRAW_GLYPH_RUN
                    // Payload layout (all little-endian):
                    //   [0..4)   base_x      f32
                    //   [4..8)   base_y      f32
                    //   [8..12)  r           f32
                    //   [12..16) g           f32
                    //   [16..20) b           f32
                    //   [20..24) a           f32
                    //   [24..28) cell_width  u32
                    //   [28..32) cell_height u32
                    //   [32..36) atlas_cols  u32
                    //   [36..40) atlas_width  u32
                    //   [40..44) atlas_height u32
                    //   [44..48) glyph_count u32
                    //   [48..48+glyph_count*12) glyphs: (index u32, x_off f32, y_off f32)
                    //   [48+glyph_count*12..)   atlas: atlas_width*atlas_height bytes (alpha)
                    if (payload.len < 48) break;

                    const base_x_local = readF32(payload[0..4]);
                    const base_y_local = readF32(payload[4..8]);
                    // Translate surface-local glyph base into framebuffer
                    // coords once; per-glyph (x_off, y_off) inherit the
                    // shift through `base_x + x_off` below.
                    const base_x = base_x_local + offset_x;
                    const base_y = base_y_local + offset_y;
                    const gr         = readF32(payload[8..12]);
                    const gg         = readF32(payload[12..16]);
                    const gb         = readF32(payload[16..20]);
                    const ga         = readF32(payload[20..24]);
                    const cell_w     = std.mem.readInt(u32, payload[24..28], .little);
                    const cell_h     = std.mem.readInt(u32, payload[28..32], .little);
                    const atlas_cols = std.mem.readInt(u32, payload[32..36], .little);
                    const atlas_w    = std.mem.readInt(u32, payload[36..40], .little);
                    const atlas_h    = std.mem.readInt(u32, payload[40..44], .little);
                    const glyph_count = std.mem.readInt(u32, payload[44..48], .little);

                    if (cell_w == 0 or cell_h == 0 or atlas_cols == 0) break;
                    if (atlas_w == 0 or atlas_h == 0 or glyph_count == 0) break;

                    const glyphs_bytes: usize = @as(usize, glyph_count) * 12;
                    const atlas_bytes:  usize = @as(usize, atlas_w) * @as(usize, atlas_h);
                    if (payload.len < 48 + glyphs_bytes + atlas_bytes) break;

                    const glyphs_slice = payload[48 .. 48 + glyphs_bytes];
                    const atlas_data   = payload[48 + glyphs_bytes .. 48 + glyphs_bytes + atlas_bytes];

                    const cr8 = clampU8(gr);
                    const cg8 = clampU8(gg);
                    const cb8 = clampU8(gb);
                    const stride = self.surface_stride;
                    const fb_w = self.width;
                    const fb_h = self.height;

                    // Render each glyph.
                    var gi: usize = 0;
                    while (gi < glyph_count) : (gi += 1) {
                        const goff = gi * 12;
                        const glyph_index = std.mem.readInt(u32, glyphs_slice[goff..][0..4], .little);
                        const x_off = readF32(glyphs_slice[goff + 4 ..][0..4]);
                        const y_off = readF32(glyphs_slice[goff + 8 ..][0..4]);

                        // Atlas cell origin for this glyph.
                        const glyph_row = glyph_index / atlas_cols;
                        const glyph_col = glyph_index % atlas_cols;
                        // Unscaled glyph dimensions derived from atlas and cell dimensions.
                        // glyph_w = atlas_w / atlas_cols
                        // glyph_h = cell_h * glyph_w / cell_w  (preserves aspect via scale)
                        const glyph_w_u: usize = @as(usize, atlas_w) / @as(usize, atlas_cols);
                        const glyph_h_u: usize = if (cell_w > 0)
                            @as(usize, cell_h) * glyph_w_u / @as(usize, cell_w)
                            else glyph_w_u * 2;
                        const atlas_x: usize = @as(usize, glyph_col) * glyph_w_u;
                        const atlas_y: usize = @as(usize, glyph_row) * glyph_h_u;

                        // Destination top-left pixel (no transform matrix in drawfs backend).
                        const dst_x_f = base_x + x_off;
                        const dst_y_f = base_y + y_off;

                        // Derive pixel scale from glyph dimensions already computed above.
                        const glyph_scale: usize = if (glyph_w_u > 0)
                            @as(usize, cell_w) / glyph_w_u
                            else 1;

                        // AD-43.3b: this glyph's destination extents.
                        const g_x0: i32 = @intFromFloat(dst_x_f);
                        const g_y0: i32 = @intFromFloat(dst_y_f);
                        const g_x1: i32 = g_x0 + @as(i32, @intCast(glyph_w_u * glyph_scale));
                        const g_y1: i32 = g_y0 + @as(i32, @intCast(glyph_h_u * glyph_scale));

                        // AD-43 fix path 2: skip glyphs whose cell
                        // rect misses the active clip entirely. For
                        // a text-heavy surface under cursor-move
                        // damage this skips nearly every glyph, and
                        // it is the largest single win of the clip.
                        if (self.clip_active and
                            (g_x1 <= self.clip_x0 or g_x0 >= self.clip_x1 or
                                g_y1 <= self.clip_y0 or g_y0 >= self.clip_y1)) continue;

                        self.noteDamage(g_x0, g_y0, g_x1, g_y1);

                        var py: usize = 0;
                        while (py < glyph_h_u) : (py += 1) {
                            var px: usize = 0;
                            while (px < glyph_w_u) : (px += 1) {
                                const src_x = atlas_x + px;
                                const src_y = atlas_y + py;
                                if (src_x >= atlas_w or src_y >= atlas_h) continue;

                                const glyph_alpha = atlas_data[src_y * @as(usize, atlas_w) + src_x];
                                if (glyph_alpha == 0) continue;

                                // Combine glyph alpha mask with color alpha.
                                const final_alpha: f32 =
                                    (@as(f32, @floatFromInt(glyph_alpha)) / 255.0) * ga;
                                const ca8 = clampU8(final_alpha);
                                if (ca8 == 0) continue;

                                // Expand each atlas pixel to glyph_scale x glyph_scale output pixels.
                                var sy: usize = 0;
                                while (sy < glyph_scale) : (sy += 1) {
                                    var sx: usize = 0;
                                    while (sx < glyph_scale) : (sx += 1) {
                                        const dx: isize = @as(isize, @intFromFloat(dst_x_f)) +
                                                          @as(isize, @intCast(px * glyph_scale + sx));
                                        const dy: isize = @as(isize, @intFromFloat(dst_y_f)) +
                                                          @as(isize, @intCast(py * glyph_scale + sy));

                                        if (dx < 0 or dy < 0) continue;
                                        if (dx >= @as(isize, @intCast(fb_w)) or
                                            dy >= @as(isize, @intCast(fb_h))) continue;
                                        // AD-43 fix path 2: clip test
                                        // for the partially-inside
                                        // glyphs that survive the
                                        // cell-rect skip above.
                                        if (self.clip_active and
                                            (dx < @as(isize, self.clip_x0) or
                                                dx >= @as(isize, self.clip_x1) or
                                                dy < @as(isize, self.clip_y0) or
                                                dy >= @as(isize, self.clip_y1))) continue;

                                        const idx = @as(usize, @intCast(dy)) * stride +
                                                    @as(usize, @intCast(dx)) * 4;
                                        writePixel(fb, idx, cr8, cg8, cb8, ca8,
                                                   self.render_state.blend_mode);
                                    }
                                }
                            }
                        }
                    }
                },
                else => {}, // Ignore unknown opcodes
            }

            // Align to 8 bytes
            offset += payload_len;
            const record_bytes = 8 + payload_len;
            const pad = (8 - (record_bytes % 8)) % 8;
            offset += pad;
        }
    }

    fn fillRect(self: *Self, fb: []u8, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b_col: f32, a: f32) void {
        const fb_w = self.width;
        const fb_h = self.height;

        // Clamp to framebuffer bounds
        var x0: i32 = @intFromFloat(@max(0, x));
        var y0: i32 = @intFromFloat(@max(0, y));
        var x1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(fb_w)), x + w));
        var y1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(fb_h)), y + h));

        // AD-43 fix path 2: clamp against the active clip exactly as
        // against the framebuffer. A rect fully outside the clip
        // costs these comparisons and nothing else. (The antialias
        // edge ring sits one pixel outside the clamped rect and was
        // already outside the noted damage in AD-43.3b; unchanged.)
        if (self.clip_active) {
            x0 = @max(x0, self.clip_x0);
            y0 = @max(y0, self.clip_y0);
            x1 = @min(x1, self.clip_x1);
            y1 = @min(y1, self.clip_y1);
        }

        if (x0 >= x1 or y0 >= y1) return;
        self.noteDamage(x0, y0, x1, y1); // AD-43.3b

        const stride = self.surface_stride;
        const blend_mode = self.render_state.blend_mode;

        const cr = clampU8(r);
        const cg = clampU8(g);
        const cb = clampU8(b_col);
        const ca = clampU8(a);

        // AD-43.1: fast path for the common case where every pixel
        // in the rect resolves to the same u32 value. Three blend
        // modes qualify:
        //
        //   Clear (mode 2):           every pixel becomes 0x00000000.
        //                             The original code (pre-AD-43.1)
        //                             always early-returned in Clear
        //                             mode before reaching the
        //                             antialias edge block, so Clear
        //                             is always fast-path eligible.
        //   Src (mode 1):             every pixel becomes the source.
        //                             Only eligible when antialias is
        //                             off; otherwise the slow path's
        //                             antialias edge block must run
        //                             (preserves pre-AD-43.1 behaviour).
        //   SrcOver (mode 0), a==255: degenerates to Src (writePixel
        //                             line 1537 has the same effect).
        //                             Same antialias guard as Src.
        //
        // The remaining cases (SrcOver with alpha < 255, Add) need
        // per-pixel work and fall through to the slow path below.
        //
        // The per-pixel slow path costs ~5 seconds for a full-screen
        // fill at 3840 x 2160 on a single-core software path (AD-43
        // bench evidence, 2026-05-27). The fast path replaces that
        // with one @memset per row over a [*]u32 slice; on amd64
        // this compiles to `rep stosd` or a vectorised equivalent
        // and finishes in tens of milliseconds.
        //
        // Aligned-write safety: stride is in bytes and is required
        // to be a multiple of 4 for the cast-to-[*]u32 to be safe.
        // Every real efifb stride on hardware so far has been a
        // multiple of 4 (it's pixels_per_row * 4 for 32 bpp
        // framebuffers). The runtime check below covers any future
        // surface with a stride that violates the assumption.
        const fast_path_eligible = (stride % 4 == 0) and switch (blend_mode) {
            2 => true,                                              // Clear
            1 => !self.render_state.antialias,                      // Src
            0 => ca == 255 and !self.render_state.antialias,        // SrcOver, opaque
            else => false,                                          // Add: per-pixel
        };

        if (fast_path_eligible) {
            // Compose the destination pixel. Memory layout is BGRA
            // (writePixel line 1496: fb[+0]=b, +1=g, +2=r, +3=a);
            // on little-endian amd64 this packs into a u32 as
            // 0xAARRGGBB.
            const pixel: u32 = if (blend_mode == 2) 0 else
                (@as(u32, ca) << 24) |
                (@as(u32, cr) << 16) |
                (@as(u32, cg) << 8) |
                @as(u32, cb);

            fillRectFast(fb, stride, x0, y0, x1, y1, pixel);

            // Skip the slow path; the rect is fully written and
            // the antialias edge block at the end of this function
            // is also skipped. Cases where the antialias edge is
            // needed have already been excluded from eligibility
            // above (Src and SrcOver branches require !antialias).
            // Clear mode never had antialias edge processing
            // pre-AD-43.1, so its early-return here matches.
            return;
        }

        // Slow path: per-pixel writePixel for the remaining cases
        // (SrcOver with alpha < 255, Add, plus the misaligned-stride
        // fallback which should never fire in practice).
        var py: i32 = y0;
        while (py < y1) : (py += 1) {
            var px: i32 = x0;
            while (px < x1) : (px += 1) {
                const idx = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(px)) * 4;
                if (idx + 3 < fb.len) {
                    writePixel(fb, idx, cr, cg, cb, ca, blend_mode);
                }
            }
        }

        // Antialias: blend outer edge pixels at half coverage.
        if (self.render_state.antialias and ca > 0) {
            const half_ca = ca / 2;
            // Top edge (row above y0)
            if (y0 > 0) {
                var px: i32 = x0;
                while (px < x1) : (px += 1) {
                    const idx = @as(usize, @intCast(y0 - 1)) * stride + @as(usize, @intCast(px)) * 4;
                    if (idx + 3 < fb.len)
                        writePixel(fb, idx, cr, cg, cb, half_ca, self.render_state.blend_mode);
                }
            }
            // Bottom edge
            if (y1 < @as(i32, @intCast(fb_h))) {
                var px: i32 = x0;
                while (px < x1) : (px += 1) {
                    const idx = @as(usize, @intCast(y1)) * stride + @as(usize, @intCast(px)) * 4;
                    if (idx + 3 < fb.len)
                        writePixel(fb, idx, cr, cg, cb, half_ca, self.render_state.blend_mode);
                }
            }
            // Left edge
            if (x0 > 0) {
                var ipy: i32 = y0;
                while (ipy < y1) : (ipy += 1) {
                    const idx = @as(usize, @intCast(ipy)) * stride + @as(usize, @intCast(x0 - 1)) * 4;
                    if (idx + 3 < fb.len)
                        writePixel(fb, idx, cr, cg, cb, half_ca, self.render_state.blend_mode);
                }
            }
            // Right edge
            if (x1 < @as(i32, @intCast(fb_w))) {
                var ipy: i32 = y0;
                while (ipy < y1) : (ipy += 1) {
                    const idx = @as(usize, @intCast(ipy)) * stride + @as(usize, @intCast(x1)) * 4;
                    if (idx + 3 < fb.len)
                        writePixel(fb, idx, cr, cg, cb, half_ca, self.render_state.blend_mode);
                }
            }
        }
    }

    fn strokeRect(self: *Self, fb: []u8, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b_col: f32, a: f32, stroke_width: f32) void {
        // Draw rectangle outline using four filled rectangles for the edges
        const sw = @max(1.0, stroke_width);
        const half_sw = sw / 2.0;

        // Top edge
        self.fillRect(fb, x - half_sw, y - half_sw, w + sw, sw, r, g, b_col, a);
        // Bottom edge
        self.fillRect(fb, x - half_sw, y + h - half_sw, w + sw, sw, r, g, b_col, a);
        // Left edge (between top and bottom)
        self.fillRect(fb, x - half_sw, y + half_sw, sw, h - sw, r, g, b_col, a);
        // Right edge (between top and bottom)
        self.fillRect(fb, x + w - half_sw, y + half_sw, sw, h - sw, r, g, b_col, a);
    }

    fn strokeLine(self: *Self, fb: []u8, x1: f32, y1: f32, x2: f32, y2: f32, r: f32, g: f32, b_col: f32, a: f32, stroke_width: f32) void {
        // Bresenham-style line drawing with stroke width
        const fb_w = self.width;
        const fb_h = self.height;
        const stride = self.surface_stride;

        const cr = clampU8(r);
        const cg = clampU8(g);
        const cb = clampU8(b_col);
        const ca = clampU8(a);

        const sw = @max(1.0, stroke_width);
        const half_sw = @as(i32, @intFromFloat(sw / 2.0));

        // Calculate line parameters
        const dx_f = x2 - x1;
        const dy_f = y2 - y1;
        const length = @sqrt(dx_f * dx_f + dy_f * dy_f);

        if (length < 0.5) {
            // Point - just draw a filled circle/square at the location
            self.fillRect(fb, x1 - sw / 2.0, y1 - sw / 2.0, sw, sw, r, g, b_col, a);
            return;
        }

        // Use integer Bresenham algorithm
        var ix1: i32 = @intFromFloat(x1);
        var iy1: i32 = @intFromFloat(y1);
        const ix2: i32 = @intFromFloat(x2);
        const iy2: i32 = @intFromFloat(y2);

        const dx: i32 = @intCast(@abs(ix2 - ix1));
        const dy: i32 = @intCast(@abs(iy2 - iy1));
        const sx: i32 = if (ix1 < ix2) @as(i32, 1) else @as(i32, -1);
        const sy: i32 = if (iy1 < iy2) @as(i32, 1) else @as(i32, -1);
        var err: i32 = dx - dy;

        // AD-43.3b: conservative bbox of the whole stroke (endpoints
        // expanded by the half-width square plotted at each step).
        self.noteDamage(
            @min(ix1, ix2) - half_sw,
            @min(iy1, iy2) - half_sw,
            @max(ix1, ix2) + half_sw + 1,
            @max(iy1, iy2) + half_sw + 1,
        );

        while (true) {
            // Draw a square at current position for stroke width
            var py: i32 = -half_sw;
            while (py <= half_sw) : (py += 1) {
                var px: i32 = -half_sw;
                while (px <= half_sw) : (px += 1) {
                    const plot_x = ix1 + px;
                    const plot_y = iy1 + py;

                    if (plot_x >= 0 and plot_x < @as(i32, @intCast(fb_w)) and
                        plot_y >= 0 and plot_y < @as(i32, @intCast(fb_h)) and
                        // AD-43 fix path 2: clip test per plotted pixel.
                        (!self.clip_active or
                            (plot_x >= self.clip_x0 and plot_x < self.clip_x1 and
                                plot_y >= self.clip_y0 and plot_y < self.clip_y1)))
                    {
                        const idx = @as(usize, @intCast(plot_y)) * stride + @as(usize, @intCast(plot_x)) * 4;
                        if (idx + 3 < fb.len) {
                            writePixel(fb, idx, cr, cg, cb, ca, self.render_state.blend_mode);
                        }
                    }
                }
            }

            if (ix1 == ix2 and iy1 == iy2) break;

            const e2 = 2 * err;
            if (e2 > -dy) {
                err -= dy;
                ix1 += sx;
            }
            if (e2 < dx) {
                err += dx;
                iy1 += sy;
            }
        }
    }

    fn getPixelsImpl(ctx: *anyopaque) ?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.surface_map;
    }

    fn resizeImpl(ctx: *anyopaque, width: u32, height: u32) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (self.width == width and self.height == height) return;

        // Destroy old surface and create new one
        self.destroySurface();
        try self.createSurface(width, height);
    }

    /// How many pollEventsImpl calls between inputfs re-probe
    /// attempts while inputfs has not yet latched. pollEventsImpl
    /// is called once per compositor frame; at typical frame rates
    /// this is on the order of one probe every 1-2 seconds, which
    /// is the intended cadence. The exact wall-clock period is
    /// deliberately approximate: the only requirements are "much
    /// less often than every frame" (so the open()+mmap() probe is
    /// not a per-frame cost) and "often enough that a user does not
    /// perceive a long dead-keyboard window at the login screen
    /// while inputfs finishes its staged HID attach". 120 satisfies
    /// both with margin.
    const INPUTFS_RETRY_INTERVAL: u32 = 120;

    fn pollEventsImpl(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // Input arrives from the inputfs event ring (AD-2a Phase 1).
        if (self.inputfs) |*ifs| {
            _ = ifs.drain(
                &self.injected_keys,
                &self.injected_keys_len,
                &self.injected_mice,
                &self.injected_mice_len,
                &self.injected_inputfs_events,
                &self.injected_inputfs_events_len,
            );
        } else {
            // inputfs was not available at the init() probe. inputfs
            // publishes its event ring asynchronously during its
            // staged HID attach, so at boot semadrawd can win the
            // race against inputfs and find the ring absent even
            // though inputfs is loaded and will publish momentarily.
            // Re-probe on a throttle until it latches. Once it
            // latches this branch is never taken again (the if-arm
            // above handles it), so this costs one counter compare
            // per frame in steady state.
            //
            // quiet=true: do not flood the warn log once per retry
            // interval while the ring is merely not-yet-published.
            // The loud "unavailable" warning was already emitted
            // once by the init()-time probe. InputfsInput.init's
            // success path logs (info) when it latches, so a late
            // attach is still visible on the bench.
            self.inputfs_retry_ticks +%= 1;
            if (self.inputfs_retry_ticks >= INPUTFS_RETRY_INTERVAL) {
                self.inputfs_retry_ticks = 0;
                if (inputfs_input.InputfsInput.init(true)) |latched| {
                    self.inputfs = latched;
                }
            }
        }
        return true;
    }

    fn getKeyEventsImpl(ctx: *anyopaque) []const backend.KeyEvent {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.injected_keys_len > 0) {
            // Snapshot the current contents and reset the buffer so the next
            // drain or sendAndRecv stash starts fresh. The returned slice is
            // safe to hold: injected_keys is a stack-allocated fixed array,
            // so resetting injected_keys_len does not invalidate the memory.
            // The caller (forwardKeyEvents) consumes the slice synchronously
            // before any further backend work can write to injected_keys.
            const events = self.injected_keys[0..self.injected_keys_len];
            self.injected_keys_len = 0;
            return events;
        }
        return &[_]backend.KeyEvent{};
    }

    fn getMouseEventsImpl(ctx: *anyopaque) []const backend.MouseEvent {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.injected_mice_len > 0) {
            // Snapshot and reset, exactly as getKeyEventsImpl does.
            // The fixed-array storage means the returned slice remains
            // valid for the caller's synchronous consumption.
            const events = self.injected_mice[0..self.injected_mice_len];
            self.injected_mice_len = 0;
            return events;
        }
        return &[_]backend.MouseEvent{};
    }

    /// AD-2a Phase 2.4.2: snapshot the side-channel buffer of raw
    /// inputfs events drained since the last call. Same lifecycle as
    /// getKeyEventsImpl/getMouseEventsImpl: snapshot the contents,
    /// reset the length to 0, return the slice. The caller
    /// (semadrawd's main loop in Phase 2.4.4) consumes the slice
    /// synchronously before any further backend work writes to the
    /// buffer; the fixed-array storage means the slice remains valid
    /// for that synchronous consumption.
    ///
    /// Until Phase 2.4.4 lands, no caller invokes this; the buffer
    /// fills in pollEventsImpl and drains here whenever someone
    /// happens to call it (i.e. never, in the current tree). That
    /// is the point of structural additivity: this commit can land
    /// without touching semadrawd.
    fn getInputfsEventsImpl(ctx: *anyopaque) []const input.Event {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.injected_inputfs_events_len > 0) {
            const events = self.injected_inputfs_events[0..self.injected_inputfs_events_len];
            self.injected_inputfs_events_len = 0;
            return events;
        }
        return &[_]input.Event{};
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    /// Return the /dev/draw file descriptor so semadrawd's main event
    /// loop can include it in its poll() set.
    ///
    /// Historical note: pre-AD-2a (semainputd retirement, 2026-05-08)
    /// this fd was the input wake source because semainputd injected
    /// EVT_KEY/POINTER/SCROLL/TOUCH frames into /dev/draw and the daemon
    /// woke on the resulting readability. After AD-2a, input flows
    /// through the inputfs event ring, not /dev/draw. The kernel-side
    /// notify cdev added in AD-41.3 is the new input wake source; see
    /// getInputfsPollFdImpl below. /dev/draw remains in the poll set
    /// for backend-side events (none currently emitted; reserved for
    /// future display hotplug / output config / surface lifecycle
    /// signals from the drawfs kernel module).
    fn getPollFdImpl(ctx: *anyopaque) ?posix.fd_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.fd < 0) return null;
        return self.fd;
    }

    /// AD-41.3: return the /dev/inputfs_notify file descriptor so
    /// semadrawd's main event loop can include it in its poll() set.
    /// Wakes the loop immediately on inputfs event publication
    /// instead of waiting out the 100 ms fallback timeout. See
    /// inputfs/docs/adr/0021 and BACKLOG AD-41 for the architecture.
    ///
    /// Returns null in three cases:
    ///   - inputfs is not currently attached (self.inputfs == null);
    ///     pollEventsImpl periodically retries the attach.
    ///   - inputfs is attached but the notify cdev was unavailable
    ///     at init time (older inputfs build, perms failure).
    ///   - The cdev was opened then closed via deinit somehow,
    ///     leaving notify_fd null.
    ///
    /// In all three cases the caller falls back to the 100 ms
    /// poll timeout for the harvest cadence. AD-41.5 tracks the
    /// observation that the timeout fires below its documented
    /// rate; until that is resolved the fallback path is degraded
    /// but functional.
    fn getInputfsPollFdImpl(ctx: *anyopaque) ?posix.fd_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.inputfs) |*ifs| {
            // ADR 0009: the pollable wake descriptor is the kqueue
            // bridge fd, not the raw notify fd. The notify cdev's
            // d_poll is edge-only and never returns POLLIN through
            // poll(2); only its kqueue path reports readiness, so the
            // bridge's kqueue fd is what the main loop polls. Null
            // when the bridge is absent (poll-timeout cadence).
            return ifs.getWakeFd();
        }
        return null;
    }

    /// ADR 0009: dispatch-path drain for the input wake fd.
    fn drainInputWakeImpl(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.inputfs) |*ifs| {
            ifs.drainWake();
        }
    }

    /// AD-17.2: report the EFI framebuffer geometry so the compositor
    /// can size its output to the actual display rather than to the
    /// hardcoded 1920x1080 default in semadrawd's Config.
    ///
    /// `efifb_avail`, `efifb_width`, and `efifb_height` are populated
    /// during `init` via `probeEfifb`, which calls
    /// `DRAWFSGIOC_GET_EFIFB_INFO` once. By the time this method is
    /// invoked from the compositor's `initOutput`, the values are
    /// already known; there's no detection cost on the query path.
    fn getDetectedDisplaySizeImpl(ctx: *anyopaque) ?backend.DisplaySize {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.efifb_avail) return null;
        if (self.efifb_width == 0 or self.efifb_height == 0) return null;
        return .{
            .width = self.efifb_width,
            .height = self.efifb_height,
        };
    }

    pub const vtable = backend.Backend.VTable{
        .getCapabilities = getCapabilitiesImpl,
        .initFramebuffer = initFramebufferImpl,
        .render = renderImpl,
        .clearRegion = clearRegionImpl,
        .getPixels = getPixelsImpl,
        .resize = resizeImpl,
        .pollEvents = pollEventsImpl,
        .getKeyEvents = getKeyEventsImpl,
        .getMouseEvents = getMouseEventsImpl,
        .getInputfsEvents = getInputfsEventsImpl,
        .getPollFd = getPollFdImpl,
        .getInputfsPollFd = getInputfsPollFdImpl,
        .drainInputWake = drainInputWakeImpl,
        .getDetectedDisplaySize = getDetectedDisplaySizeImpl,
        .deinit = deinitImpl,
    };

    pub fn toBackend(self: *Self) backend.Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

// ============================================================================
// Helper functions
// ============================================================================

/// Write one XRGB8888 pixel applying the given blend mode.
/// blend_mode: 0=SrcOver, 1=Src, 2=Clear, 3=Add
fn writePixel(fb: []u8, idx: usize, r: u8, g: u8, b: u8, a: u8, blend_mode: u32) void {
    if (idx + 3 >= fb.len) return;
    switch (blend_mode) {
        2 => { // Clear
            fb[idx] = 0; fb[idx+1] = 0; fb[idx+2] = 0; fb[idx+3] = 0;
        },
        1 => { // Src: write directly, no blending
            fb[idx+0] = b; fb[idx+1] = g; fb[idx+2] = r; fb[idx+3] = a;
        },
        3 => { // Add: saturating add
            fb[idx+0] = @intCast(@min(255, @as(u32, fb[idx+0]) + b));
            fb[idx+1] = @intCast(@min(255, @as(u32, fb[idx+1]) + g));
            fb[idx+2] = @intCast(@min(255, @as(u32, fb[idx+2]) + r));
            fb[idx+3] = 0xFF;
        },
        else => { // SrcOver (default)
            if (a == 255) {
                fb[idx+0] = b; fb[idx+1] = g; fb[idx+2] = r; fb[idx+3] = 0xFF;
            } else if (a > 0) {
                const sa: f32 = @as(f32, @floatFromInt(a)) / 255.0;
                const inv_sa = 1.0 - sa;
                fb[idx+0] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(b)) * sa + @as(f32, @floatFromInt(fb[idx+0])) * inv_sa));
                fb[idx+1] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(g)) * sa + @as(f32, @floatFromInt(fb[idx+1])) * inv_sa));
                fb[idx+2] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(r)) * sa + @as(f32, @floatFromInt(fb[idx+2])) * inv_sa));
                fb[idx+3] = 0xFF;
            }
        },
    }
}

fn clampU8(v: f32) u8 {
    var x = v;
    if (x < 0.0) x = 0.0;
    if (x > 1.0) x = 1.0;
    return @intFromFloat(@round(x * 255.0));
}

/// AD-43.1: row-major u32 memset replacement for the per-pixel
/// writePixel loop in fillRect. Used only when every pixel in the
/// rect resolves to the same destination value (Clear, Src, or
/// SrcOver-with-alpha-255). The slow per-pixel path in fillRect
/// handles the remaining cases (SrcOver with alpha < 255, Add).
///
/// Preconditions (asserted; caller is responsible):
///   - 0 <= x0 < x1, 0 <= y0 < y1
///   - stride is a multiple of 4
///   - py * stride + (x1-1) * 4 + 3 < fb.len for all py in [y0, y1)
///     (i.e., the rect fits in the framebuffer). The runtime check
///     below is defensive insurance; with correct upstream clamping
///     it never trips.
///
/// `pixel` is the destination u32 in the framebuffer's native byte
/// order. On the bench platform (amd64, little-endian) with a BGRA
/// memory layout (writePixel line 1537), this is
/// `(a << 24) | (r << 16) | (g << 8) | b`. Callers in this file
/// already compose the pixel correctly; see fillRect's fast-path
/// block.
fn fillRectFast(fb: []u8, stride: usize, x0: i32, y0: i32, x1: i32, y1: i32, pixel: u32) void {
    std.debug.assert(x0 >= 0);
    std.debug.assert(y0 >= 0);
    std.debug.assert(x0 < x1);
    std.debug.assert(y0 < y1);
    std.debug.assert(stride % 4 == 0);

    const ux0: usize = @intCast(x0);
    const ux1: usize = @intCast(x1);
    const uy0: usize = @intCast(y0);
    const uy1: usize = @intCast(y1);

    const row_pixel_count = ux1 - ux0;

    var py = uy0;
    while (py < uy1) : (py += 1) {
        const row_start_byte = py * stride + ux0 * 4;
        const row_end_byte = row_start_byte + row_pixel_count * 4;

        // Defensive: a row that would overflow fb is skipped, not
        // partially written. Matches the slow path's per-pixel
        // skip-on-overflow with coarser granularity. Upstream
        // clamping should prevent this from ever firing.
        if (row_end_byte > fb.len) continue;

        // Reinterpret the row's byte span as []u32. Alignment is
        // safe by construction: stride is a multiple of 4
        // (assert above), ux0 * 4 is a multiple of 4, and fb is
        // mmap-backed at a page-aligned base. @memset on a []u32
        // slice compiles to `rep stosd` (or a vectorised
        // equivalent) on amd64, which moves through the cache
        // hierarchy at far higher throughput than the per-byte
        // store loop the slow path generates.
        const row_ptr: [*]u32 = @ptrCast(@alignCast(fb[row_start_byte..].ptr));
        @memset(row_ptr[0..row_pixel_count], pixel);
    }
}

fn readF32(bytes: *const [4]u8) f32 {
    const u = std.mem.readInt(u32, bytes, .little);
    return @bitCast(u);
}

// ============================================================================
// Public API
// ============================================================================

/// Create drawfs backend with default device path (/dev/draw)
pub fn create(allocator: std.mem.Allocator) !backend.Backend {
    const drawfs_backend = try DrawfsBackend.initDefault(allocator);
    return drawfs_backend.toBackend();
}

/// Create drawfs backend with specific device path
pub fn createWithDevice(allocator: std.mem.Allocator, device_path: []const u8) !backend.Backend {
    const drawfs_backend = try DrawfsBackend.init(allocator, device_path);
    return drawfs_backend.toBackend();
}

// ============================================================================
// Tests
// ============================================================================

test "DrawfsBackend struct size" {
    try std.testing.expect(@sizeOf(DrawfsBackend) > 0);
}

test "align4" {
    try std.testing.expectEqual(@as(u32, 0), align4(0));
    try std.testing.expectEqual(@as(u32, 4), align4(1));
    try std.testing.expectEqual(@as(u32, 4), align4(4));
    try std.testing.expectEqual(@as(u32, 8), align4(5));
}

test "clampU8" {
    try std.testing.expectEqual(@as(u8, 0), clampU8(-1.0));
    try std.testing.expectEqual(@as(u8, 0), clampU8(0.0));
    try std.testing.expectEqual(@as(u8, 128), clampU8(0.5));
    try std.testing.expectEqual(@as(u8, 255), clampU8(1.0));
    try std.testing.expectEqual(@as(u8, 255), clampU8(2.0));
}

test "side-channel buffer sized to drain capacity" {
    // AD-2a Phase 2.4.2: the side-channel buffer must hold an entire
    // drain batch so no raw input.Events drop on the per-call boundary.
    // If DRAIN_BATCH grows but the buffer doesn't, the recogniser
    // silently misses events; this guard catches that drift at
    // compile time.
    const Self = DrawfsBackend;
    const field_info = @typeInfo(@FieldType(Self, "injected_inputfs_events"));
    try std.testing.expectEqual(inputfs_input.DRAIN_BATCH, field_info.array.len);
    try std.testing.expectEqual(input.Event, field_info.array.child);
}

test "fillRectFast: writes only the rect, leaves surroundings untouched" {
    // 8x4 pixel framebuffer at stride 32 bytes (8 pixels * 4 bytes).
    // Fill the inner 4x2 rect at (2,1)..(6,3) with 0xDEADBEEF.
    // Verify the rect pixels match the target and the surrounding
    // pixels are unchanged.
    const fb_w: usize = 8;
    const fb_h: usize = 4;
    const stride: usize = fb_w * 4;
    var fb: [fb_w * fb_h * 4]u8 = undefined;
    @memset(&fb, 0x42);

    fillRectFast(&fb, stride, 2, 1, 6, 3, 0xDEADBEEF);

    // Check rect pixels: rows 1..3, cols 2..6, every byte should
    // reflect the little-endian decomposition of 0xDEADBEEF
    // (i.e., bytes EF BE AD DE).
    for (1..3) |py| {
        for (2..6) |px| {
            const idx = py * stride + px * 4;
            try std.testing.expectEqual(@as(u8, 0xEF), fb[idx + 0]);
            try std.testing.expectEqual(@as(u8, 0xBE), fb[idx + 1]);
            try std.testing.expectEqual(@as(u8, 0xAD), fb[idx + 2]);
            try std.testing.expectEqual(@as(u8, 0xDE), fb[idx + 3]);
        }
    }

    // Check that pixels outside the rect remain at 0x42. Sample a
    // few representative positions rather than the full grid.
    const untouched_positions = [_][2]usize{
        .{ 0, 0 }, .{ 7, 0 }, // top row, outside rect
        .{ 0, 1 }, .{ 1, 1 }, .{ 6, 1 }, .{ 7, 1 }, // row 1, outside x range
        .{ 0, 3 }, .{ 7, 3 }, // row 3, outside y range (rect is y=1..3 exclusive)
    };
    for (untouched_positions) |pos| {
        const px = pos[0];
        const py = pos[1];
        const idx = py * stride + px * 4;
        try std.testing.expectEqual(@as(u8, 0x42), fb[idx + 0]);
        try std.testing.expectEqual(@as(u8, 0x42), fb[idx + 1]);
        try std.testing.expectEqual(@as(u8, 0x42), fb[idx + 2]);
        try std.testing.expectEqual(@as(u8, 0x42), fb[idx + 3]);
    }
}

test "fillRectFast: pixel layout matches writePixel for Src mode" {
    // The fast path's pixel composition formula must produce the
    // same byte sequence in memory as writePixel(blend_mode=Src)
    // would, otherwise switching to the fast path changes colours.
    //
    // For each colour in a representative palette, fill an 8-pixel
    // row two ways:
    //   (a) one writePixel(blend_mode=1) call per pixel
    //   (b) one fillRectFast call with the composed u32
    // Then byte-compare the two framebuffers. Any mismatch indicates
    // an endianness, channel-order, or alpha-handling bug.

    const stride: usize = 32; // 8 pixels per row
    const row_count: usize = 1;

    const palette = [_][4]u8{
        .{ 0x00, 0x00, 0x00, 0xFF }, // opaque black
        .{ 0xFF, 0xFF, 0xFF, 0xFF }, // opaque white
        .{ 0xFF, 0x00, 0x00, 0xFF }, // pure red
        .{ 0x00, 0xFF, 0x00, 0xFF }, // pure green
        .{ 0x00, 0x00, 0xFF, 0xFF }, // pure blue
        .{ 0x40, 0x80, 0xC0, 0xFF }, // arbitrary gradient sample
        .{ 0x12, 0x34, 0x56, 0x78 }, // alpha != 0xFF: tests that fast
        //                              path composes the alpha byte
        //                              into the u32 even when it
        //                              would not satisfy the
        //                              "a == 255" fast-path
        //                              eligibility predicate
        //                              (fillRectFast itself is
        //                              orthogonal to mode dispatch;
        //                              the caller is responsible
        //                              for not invoking it on
        //                              non-eligible cases)
    };

    for (palette) |rgba| {
        const r = rgba[0];
        const g = rgba[1];
        const b = rgba[2];
        const a = rgba[3];

        var fb_a: [stride * row_count]u8 = undefined;
        var fb_b: [stride * row_count]u8 = undefined;
        @memset(&fb_a, 0);
        @memset(&fb_b, 0);

        // (a) per-pixel writePixel
        var px: usize = 0;
        while (px < 8) : (px += 1) {
            writePixel(&fb_a, px * 4, r, g, b, a, 1);
        }

        // (b) fillRectFast with the composed u32
        const pixel: u32 = (@as(u32, a) << 24) |
            (@as(u32, r) << 16) |
            (@as(u32, g) << 8) |
            @as(u32, b);
        fillRectFast(&fb_b, stride, 0, 0, 8, 1, pixel);

        try std.testing.expectEqualSlices(u8, &fb_a, &fb_b);
    }
}

test "fillRectFast: Clear mode equivalence" {
    // Clear (blend_mode=2) sets every byte of every pixel to 0.
    // Verify fillRectFast with pixel=0 produces the same result.
    const stride: usize = 32;
    var fb_a: [stride * 2]u8 = undefined;
    var fb_b: [stride * 2]u8 = undefined;
    @memset(&fb_a, 0xAA); // start with non-zero so the clear is visible
    @memset(&fb_b, 0xAA);

    var py: usize = 0;
    while (py < 2) : (py += 1) {
        var px: usize = 0;
        while (px < 8) : (px += 1) {
            writePixel(&fb_a, py * stride + px * 4, 0, 0, 0, 0, 2);
        }
    }

    fillRectFast(&fb_b, stride, 0, 0, 8, 2, 0);

    try std.testing.expectEqualSlices(u8, &fb_a, &fb_b);
}

// ============================================================================
// Migration time idiom (P2 Tranche 3): file-local monotonic clock helper.
// Replaces std.time.nanoTimestamp(), removed in Zig 0.16. Monotonic is the
// correct clock for the interval/pacing maths here. Duplicated per file by
// design during migration; consolidation deferred.
// ============================================================================

fn monotonicNowNs() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
