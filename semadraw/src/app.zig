//! SemaDraw Application Framework
//!
//! Provides a high-level `App` abstraction that manages the connection,
//! surface, encoder, and event loop so application code only needs to
//! implement drawing and input handling.
//!
//! ## Minimal example
//!
//! ```zig
//! const app = @import("semadraw").App;
//! const Encoder = @import("semadraw").Encoder;
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!
//!     var myapp = try App.init(gpa.allocator(), .{
//!         .title  = "Hello",
//!         .width  = 800,
//!         .height = 600,
//!     });
//!     defer myapp.deinit();
//!
//!     try myapp.run(&myapp, onDraw, onEvent);
//! }
//!
//! fn onDraw(ctx: *anyopaque, enc: *Encoder, _: u64) !void {
//!     _ = ctx;
//!     try enc.fillRect(0, 0, 800, 600, 0.1, 0.1, 0.2, 1.0);
//! }
//!
//! fn onEvent(ctx: *anyopaque, event: App.Event) !bool {
//!     _ = ctx;
//!     return event != .quit;
//! }
//! ```

const std = @import("std");
const client = @import("semadraw_client");
const Encoder = @import("encoder.zig").Encoder;

const log = std.log.scoped(.semadraw_app);

// ============================================================================
// Public event type
// ============================================================================

pub const KeyEvent = struct {
    key_code: u32,
    pressed: bool,
    modifiers: u8,
};

pub const MouseEvent = struct {
    x: f32,
    y: f32,
    button: u8,
    pressed: bool,
    modifiers: u8,
};

/// Events delivered to the application's onEvent callback.
pub const Event = union(enum) {
    /// User or system requested quit
    quit,
    /// A frame was completed by the compositor
    frame: struct { frame_number: u64, timestamp_ns: u64 },
    /// Keyboard event
    key: KeyEvent,
    /// Mouse/pointer event
    mouse: MouseEvent,
};

// ============================================================================
// App descriptor
// ============================================================================

pub const AppDesc = struct {
    /// Window/surface title (informational)
    title: []const u8 = "SemaDraw App",
    /// Surface width in logical pixels
    width: f32 = 1280,
    /// Surface height in logical pixels
    height: f32 = 720,
    /// Pixel scale factor
    scale: f32 = 1.0,
    /// Z-order for surface stacking
    z_order: i32 = 0,
    /// Initial position
    x: f32 = 0,
    y: f32 = 0,
    /// Socket path override (null = default)
    socket_path: ?[]const u8 = null,
    /// Target frames per second (0 = as fast as possible)
    target_fps: u32 = 60,
};

// ============================================================================
// Callback types
// ============================================================================

/// Called each frame to produce drawing commands.
/// `ctx`   — user context pointer passed to run()
/// `enc`   — encoder to write SDCS commands into
/// `frame` — monotonic frame counter
pub const DrawFn  = *const fn (ctx: *anyopaque, enc: *Encoder, frame: u64) anyerror!void;

/// Called for each input/lifecycle event.
/// Return `true` to continue running, `false` to quit.
pub const EventFn = *const fn (ctx: *anyopaque, event: Event) anyerror!bool;

// ============================================================================
// App
// ============================================================================

pub const App = struct {
    allocator: std.mem.Allocator,
    desc: AppDesc,
    conn: *client.Connection,
    surface: *client.Surface,
    encoder: Encoder,
    frame: u64,
    running: bool,

    const Self = @This();

    /// Create and connect the application. Connects to semadrawd, creates
    /// a surface, and prepares the encoder. Call `run()` to start the loop.
    pub fn init(allocator: std.mem.Allocator, desc: AppDesc) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Connect to semadrawd
        log.info("connecting to semadrawd...", .{});
        const conn = if (desc.socket_path) |path|
            try client.Connection.connectTo(allocator, path)
        else
            try client.Connection.connect(allocator);
        errdefer conn.disconnect();

        log.info("connected, creating surface {}x{}...", .{ desc.width, desc.height });

        // Create surface
        const surface = try client.Surface.createWithScale(
            conn, desc.width, desc.height, desc.scale);
        errdefer surface.destroy();

        try surface.setZOrder(desc.z_order);
        try surface.setPosition(desc.x, desc.y);
        try surface.show();

        self.* = .{
            .allocator = allocator,
            .desc      = desc,
            .conn      = conn,
            .surface   = surface,
            .encoder   = Encoder.init(allocator),
            .frame     = 0,
            .running   = true,
        };

        log.info("surface ready ({s})", .{desc.title});
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.encoder.deinit();
        self.surface.destroy();
        self.conn.disconnect();
        self.allocator.destroy(self);
    }

    /// Run the application event loop.
    ///
    /// `ctx`     — arbitrary user context pointer forwarded to callbacks
    /// `onDraw`  — called each frame; write SDCS commands into the encoder
    /// `onEvent` — called for each event; return false to quit
    pub fn run(
        self: *Self,
        ctx: *anyopaque,
        onDraw: DrawFn,
        onEvent: EventFn,
    ) !void {
        const frame_ns: u64 = if (self.desc.target_fps > 0)
            @divTrunc(std.time.ns_per_s, self.desc.target_fps)
        else
            0;

        while (self.running) {
            const frame_start = std.time.nanoTimestamp();

            // Draw
            try self.encoder.reset();
            try onDraw(ctx, &self.encoder, self.frame);
            const sdcs_data = try self.encoder.finishBytesWithHeader();
            defer self.allocator.free(sdcs_data);
            try self.surface.attachAndCommit(sdcs_data);
            self.frame += 1;

            // Drain events (non-blocking)
            self.running = try self.drainEvents(ctx, onEvent);

            // Frame pacing
            if (frame_ns > 0) {
                const elapsed: u64 = @intCast(std.time.nanoTimestamp() - frame_start);
                if (elapsed < frame_ns) {
                    std.Thread.sleep(frame_ns - elapsed);
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    fn drainEvents(
        self: *Self,
        ctx: *anyopaque,
        onEvent: EventFn,
    ) !bool {
        // Use a short poll to avoid blocking the render loop
        const fd = self.conn.getFd();
        var pfd = [1]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        while (true) {
            const ready = std.posix.poll(&pfd, 0) catch break;
            if (ready == 0) break;
            if ((pfd[0].revents & std.posix.POLL.IN) == 0) break;

            const ev = self.conn.waitEvent() catch |err| {
                if (err == error.EndOfStream or err == error.BrokenPipe) {
                    return false;
                }
                break;
            };

            const app_ev: ?Event = switch (ev) {
                .frame_complete => |fc| Event{ .frame = .{
                    .frame_number = fc.frame_number,
                    .timestamp_ns = fc.timestamp_ns,
                }},
                .disconnected => Event{ .quit = {} },
                .key_press => |kp| Event{ .key = .{
                    .key_code  = kp.key_code,
                    .pressed   = kp.pressed != 0,
                    .modifiers = kp.modifiers,
                }},
                .mouse_event => |me| Event{ .mouse = .{
                    .x         = @as(f32, @floatFromInt(me.x)),
                    .y         = @as(f32, @floatFromInt(me.y)),
                    .button    = @intFromEnum(me.button),
                    .pressed   = me.event_type == .press,
                    .modifiers = me.modifiers,
                }},
                else => null,
            };

            if (app_ev) |e| {
                const keep_running = try onEvent(ctx, e);
                if (!keep_running) return false;
            }
        }

        return true;
    }
};
