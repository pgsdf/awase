const std = @import("std");
const input = @import("input");

/// Backend capabilities reported during initialization
pub const Capabilities = struct {
    /// Backend name for logging/debugging
    name: []const u8,
    /// Maximum supported framebuffer width
    max_width: u32,
    /// Maximum supported framebuffer height
    max_height: u32,
    /// Supports anti-aliasing
    supports_aa: bool,
    /// Supports GPU acceleration
    hardware_accelerated: bool,
    /// Can output to display directly
    can_present: bool,
};

/// Framebuffer pixel format
pub const PixelFormat = enum(u8) {
    /// 8-bit RGBA (4 bytes per pixel)
    rgba8 = 0,
    /// 8-bit BGRA (4 bytes per pixel)
    bgra8 = 1,
    /// 8-bit RGB (3 bytes per pixel, no alpha)
    rgb8 = 2,
};

/// Framebuffer configuration
pub const FramebufferConfig = struct {
    width: u32,
    height: u32,
    format: PixelFormat = .rgba8,
    /// Scale factor for HiDPI (1.0 = no scaling)
    scale: f32 = 1.0,
};

/// Native display size detected by a backend, returned from
/// `getDetectedDisplaySize`. Carries pixel dimensions only, format
/// and scale are compositor-side choices, not backend-detected.
///
/// AD-17 entry point: backends that have a native size to report
/// (drawfs: efifb_width × efifb_height; X11/Wayland: window
/// geometry; Vulkan: surface extent) populate this. Backends that
/// don't (software, headless) leave the optional vtable method
/// `null` and the compositor falls back to its configured default.
pub const DisplaySize = struct {
    width: u32,
    height: u32,
};

/// CAPTURE-DESIGN.md commit 2: one coherent view of the composited
/// frame, produced by the optional `frameSnapshot` vtable operation.
///
/// Deliberately ONE aggregate rather than getPixels() plus geometry
/// getters. Separate getters invite a tear: read width, the display
/// resizes, read stride, and the two now describe different frames,
/// which produces a sheared or out-of-bounds capture. One struct
/// makes the pairing true by construction, and the abstraction being
/// exposed IS a snapshot.
///
/// Atomicity contract: the snapshot represents the same "current"
/// surface state the compositor would read if it composited at that
/// point in the event loop. Today that is guaranteed by two things
/// together: the daemon's single-threaded event-loop topology (the
/// snapshot is taken from a handler that runs in the same loop as
/// compositing, so no composite is concurrently mutating the buffer)
/// and the ADR 0022 pending/current surface state model (a commit
/// promotes state atomically, so "current" is never half-applied).
/// If the compositor architecture ever changes, multi-threaded or
/// asynchronous composition, the frameSnapshot implementation must
/// either preserve this invariant or explicitly weaken this contract;
/// it must not be left to drift into falsehood silently.
///
/// Lifetime contract: `pixels` is a BORROWED view of backend-owned
/// memory, not a copy. It remains valid until the backend processes
/// the next mutating operation (render, clearRegion, resize) or is
/// destroyed. Callers must not retain it beyond the current
/// event-loop turn; a caller that needs the frame afterwards copies
/// it out while the borrow holds. This is what makes the capture
/// path's copy-into-shared-memory step mandatory rather than an
/// implementation choice.
///
/// `stride` is carried explicitly because it may exceed width * 4:
/// a padded surface captured as if it were tight produces a sheared
/// image, the classic screenshot bug. The backend knows its stride;
/// nothing else can infer it.
///
/// `format` names the byte order of `pixels`. Backends whose fourth
/// byte is padding rather than coverage (drawfs: XRGB8888, laid out
/// B,G,R,X in memory) report `.bgra8` with the alpha byte carrying
/// no meaning; consumers converting to RGB drop the fourth byte
/// either way. A distinct bgrx member would ripple through every
/// exhaustive PixelFormat switch for no consumer benefit today; if
/// a consumer ever needs the distinction, that is its own change.
pub const FrameSnapshot = struct {
    width: u32,
    height: u32,
    stride: u32,
    format: PixelFormat,
    pixels: []const u8,
};

/// Render request sent to backend
pub const RenderRequest = struct {
    /// Surface ID being rendered
    surface_id: u32,
    /// SDCS command data
    sdcs_data: []const u8,
    /// Destination framebuffer config
    framebuffer: FramebufferConfig,
    /// Clear color before rendering (null = don't clear)
    clear_color: ?[4]f32 = null,
    /// Surface position offset in pixels (where to render in framebuffer)
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    /// AD-43 fix path 2: optional clip rect in FRAMEBUFFER coordinates.
    /// When set, the backend executes the surface's SDCS clipped to
    /// this rect: primitives clamp against it exactly as they clamp
    /// against the framebuffer, fully-outside commands cost a compare,
    /// and the clear_color clear covers only this rect. null means no
    /// clip (full re-execution), the pre-existing behaviour.
    clip: ?ClipRect = null,
};

/// AD-43 fix path 2: framebuffer-coordinate clip rect.
pub const ClipRect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

/// AD-21 sub-item 9 / region damage: request to clear a rectangular
/// region of the framebuffer to a background color, before any
/// surface renders this composite cycle.
///
/// Region clearing is the architectural complement to surface damage:
/// surface damage tells the compositor "this surface needs to re-render";
/// region damage tells the compositor "the framebuffer pixels in this
/// rect are stale, paint them with background color." Surfaces that
/// intersect a damaged region are also marked for full damage by the
/// pump (or whatever produced the region damage), so the cleared
/// background is correctly painted over by the surfaces' own pixels.
///
/// Backends that don't implement clearRegion fall back to the
/// existing "clear_color on first surface render" path, which clears
/// the entire framebuffer. The compositor handles that fallback.
pub const ClearRegionRequest = struct {
    /// Destination framebuffer config (same as RenderRequest).
    framebuffer: FramebufferConfig,
    /// Rect to clear, in framebuffer coordinates.
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    /// Background color in [r, g, b, a] floats 0.0..1.0.
    color: [4]f32,
};

/// Render result returned from backend
pub const RenderResult = struct {
    /// Surface ID that was rendered
    surface_id: u32,
    /// Frame number
    frame_number: u64,
    /// Render time in nanoseconds
    render_time_ns: u64,
    /// Error message if failed (null = success)
    error_msg: ?[]const u8 = null,

    pub fn success(surface_id: u32, frame: u64, time_ns: u64) RenderResult {
        return .{
            .surface_id = surface_id,
            .frame_number = frame,
            .render_time_ns = time_ns,
        };
    }

    pub fn failure(surface_id: u32, msg: []const u8) RenderResult {
        return .{
            .surface_id = surface_id,
            .frame_number = 0,
            .render_time_ns = 0,
            .error_msg = msg,
        };
    }
};

/// Key event from backend (keyboard input)
pub const KeyEvent = struct {
    /// Key code. Historically this carried an evdev code (the
    /// semainputd era; semainputd read evdev directly and forwarded
    /// the code unchanged). After AD-2a Phase 1 (inputfs cutover),
    /// the value is post-translation: inputfs publishes HID Usage
    /// Page 0x07 IDs, and semadraw/src/backend/inputfs_translate.zig
    /// translates those to the same evdev codes the field used to
    /// carry, so client code that interprets it as an evdev code
    /// continues to work. Renaming this field to `keysym` is a
    /// follow-up cleanup; AD-2a Phase 1 keeps the wire-compatible
    /// name to avoid client-side ripple.
    key_code: u32,
    /// Modifier state: bit 0=shift, bit 1=alt, bit 2=ctrl, bit 3=meta
    modifiers: u8,
    /// True if key pressed, false if released
    pressed: bool,
};

/// Maximum number of key events that can be queued
pub const MAX_KEY_EVENTS = 32;

/// Mouse button identifiers
pub const MouseButton = enum(u8) {
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

/// Mouse event type
pub const MouseEventType = enum(u8) {
    press = 0,
    release = 1,
    motion = 2,
};

/// Mouse event from backend
pub const MouseEvent = struct {
    /// X coordinate in pixels
    x: i32,
    /// Y coordinate in pixels
    y: i32,
    /// Button involved (for press/release)
    button: MouseButton,
    /// Event type
    event_type: MouseEventType,
    /// Modifier state: bit 0=shift, bit 1=alt, bit 2=ctrl, bit 3=meta
    modifiers: u8,
};

/// Maximum number of mouse events that can be queued
pub const MAX_MOUSE_EVENTS = 64;

/// Backend interface - all backends must implement this
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Get backend capabilities
        getCapabilities: *const fn (ctx: *anyopaque) Capabilities,
        /// Initialize framebuffer with given config
        initFramebuffer: *const fn (ctx: *anyopaque, config: FramebufferConfig) anyerror!void,
        /// Render SDCS commands to framebuffer
        render: *const fn (ctx: *anyopaque, request: RenderRequest) anyerror!RenderResult,
        /// AD-21 sub-item 9 / region damage: clear a rectangular region
        /// of the framebuffer to a background color. Optional; backends
        /// that don't implement it (null) trigger the compositor's
        /// fallback path (full-frame clear via clear_color on the first
        /// surface render of the cycle).
        clearRegion: ?*const fn (ctx: *anyopaque, request: ClearRegionRequest) anyerror!void = null,
        /// ADR 0021 Section 7: push buffered pixel writes to the
        /// panel without rendering a surface. Exists because
        /// clearRegion writes are carried to the screen by the next
        /// render's blit in some backends (drawfs: blitToEfifb runs
        /// only in renderImpl); the blank root clears and then
        /// suspends, so it must flush explicitly. Optional; backends
        /// whose clearRegion writes the visible framebuffer directly
        /// leave it null.
        flush: ?*const fn (ctx: *anyopaque) void = null,
        /// Get pointer to framebuffer pixels (for composition/output)
        getPixels: *const fn (ctx: *anyopaque) ?[]u8,

        /// CAPTURE-DESIGN.md commit 2: produce one coherent
        /// FrameSnapshot of the composited frame, or null if the
        /// backend cannot produce one right now (no surface mapped,
        /// zero-sized framebuffer). Optional, following the pattern
        /// of clearRegion/flush/getKeyEvents: a backend that cannot
        /// produce a coherent snapshot does not implement this, and
        /// saying so is a truthful answer rather than a guessed one.
        /// See FrameSnapshot for the atomicity and lifetime contract.
        frameSnapshot: ?*const fn (ctx: *anyopaque) ?FrameSnapshot = null,
        /// Resize framebuffer
        resize: *const fn (ctx: *anyopaque, width: u32, height: u32) anyerror!void,
        /// Process pending events (keyboard, window, etc.)
        /// Returns false if backend should stop (e.g., window closed)
        pollEvents: *const fn (ctx: *anyopaque) bool,
        /// Get pending key events (empties the queue)
        /// Returns slice of events, caller should not free
        getKeyEvents: ?*const fn (ctx: *anyopaque) []const KeyEvent = null,
        /// Get pending mouse events (empties the queue)
        /// Returns slice of events, caller should not free
        getMouseEvents: ?*const fn (ctx: *anyopaque) []const MouseEvent = null,
        /// Get pending raw inputfs events captured by the side-channel
        /// (AD-2a Phase 2.4.2). Returns the slice of `input.Event`s
        /// drained since the last call; backend snapshot-and-resets
        /// the buffer. Used by semadrawd to feed the gesture
        /// recogniser, which needs the device_slot field that the
        /// translated MouseEvent type doesn't carry. Backends without
        /// inputfs integration leave this null.
        getInputfsEvents: ?*const fn (ctx: *anyopaque) []const input.Event = null,
        /// Return a file descriptor the daemon should include in its main
        /// poll() set, or null if the backend has no pollable event source.
        /// Waking on this fd lets semadrawd drain injected input events
        /// immediately instead of after the next poll timeout.
        getPollFd: ?*const fn (ctx: *anyopaque) ?std.posix.fd_t = null,
        /// AD-41.3: return a separate file descriptor for the inputfs
        /// notification cdev (/dev/inputfs_notify), if the backend
        /// integrates with inputfs and the cdev is currently open. The
        /// daemon adds this to its poll() set alongside getPollFd's
        /// return so the main loop wakes on inputfs event publication
        /// without waiting on the 100 ms fallback timeout. See
        /// inputfs/docs/adr/0021 for the architecture; the separation
        /// between getPollFd (backend wake source) and
        /// getInputfsPollFd (input wake source) is deliberate. Backends
        /// without inputfs integration leave this null.
        getInputfsPollFd: ?*const fn (ctx: *anyopaque) ?std.posix.fd_t = null,
        /// ADR 0009: consume pending kevents on the input wake fd so
        /// its readiness clears (the wake fd is a kqueue descriptor;
        /// EV_CLEAR re-arms on the kevent read). Required dispatch
        /// handler for getInputfsPollFd's descriptor per the AD-32
        /// rule: a polled fd never enters the set without one. Null
        /// when getInputfsPollFd is null.
        drainInputWake: ?*const fn (ctx: *anyopaque) void = null,
        /// AD-17: report the backend's native display size, if any.
        ///
        /// Outer null: backend has no detection mechanism (software,
        /// headless, stubs).
        ///
        /// Inner null: backend supports detection but the size is not
        /// currently available (drawfs without efifb, vulkan before
        /// surface creation).
        ///
        /// Returned size: backend's native pixel dimensions. The
        /// compositor treats this as authoritative when present and
        /// uses its configured default otherwise. See `initOutput`
        /// in compositor.zig.
        getDetectedDisplaySize: ?*const fn (ctx: *anyopaque) ?DisplaySize = null,
        /// Set clipboard content (selection: 0=CLIPBOARD, 1=PRIMARY)
        setClipboard: ?*const fn (ctx: *anyopaque, selection: u8, text: []const u8) anyerror!void = null,
        /// Request clipboard content (async - data available after pollEvents)
        requestClipboard: ?*const fn (ctx: *anyopaque, selection: u8) void = null,
        /// Get clipboard data (returns null if not available or not supported)
        getClipboardData: ?*const fn (ctx: *anyopaque, selection: u8) ?[]const u8 = null,
        /// Check if clipboard request is pending
        isClipboardPending: ?*const fn (ctx: *anyopaque) bool = null,
        /// Cleanup and free resources
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn getCapabilities(self: Backend) Capabilities {
        return self.vtable.getCapabilities(self.ptr);
    }

    pub fn initFramebuffer(self: Backend, config: FramebufferConfig) !void {
        return self.vtable.initFramebuffer(self.ptr, config);
    }

    pub fn render(self: Backend, request: RenderRequest) !RenderResult {
        return self.vtable.render(self.ptr, request);
    }

    /// AD-21 sub-item 9 / region damage: clear a rectangular region of
    /// the framebuffer. Returns error.NotSupported if the backend
    /// does not implement clearRegion; the caller (compositor) should
    /// fall back to full-frame clear in that case.
    pub fn clearRegion(self: Backend, request: ClearRegionRequest) !void {
        if (self.vtable.clearRegion) |func| {
            return func(self.ptr, request);
        }
        return error.NotSupported;
    }

    /// Returns true if the backend implements clearRegion. Lets the
    /// compositor make the fall-back decision once per composite cycle
    /// rather than per-rect.
    pub fn supportsClearRegion(self: Backend) bool {
        return self.vtable.clearRegion != null;
    }

    /// ADR 0021: flush buffered writes to the panel. No-op when the
    /// backend needs none.
    pub fn flush(self: Backend) void {
        if (self.vtable.flush) |func| {
            func(self.ptr);
        }
    }

    pub fn getPixels(self: Backend) ?[]u8 {
        return self.vtable.getPixels(self.ptr);
    }

    /// One coherent view of the composited frame, or null when the
    /// backend does not implement snapshots or cannot produce one
    /// right now. See FrameSnapshot for the atomicity and lifetime
    /// contract; in particular the returned pixels are borrowed and
    /// must not be retained beyond the current event-loop turn.
    pub fn frameSnapshot(self: Backend) ?FrameSnapshot {
        if (self.vtable.frameSnapshot) |func| {
            return func(self.ptr);
        }
        return null;
    }

    pub fn resize(self: Backend, width: u32, height: u32) !void {
        return self.vtable.resize(self.ptr, width, height);
    }

    /// Process pending events (keyboard, window, etc.)
    /// Returns false if backend should stop (e.g., window closed)
    pub fn pollEvents(self: Backend) bool {
        return self.vtable.pollEvents(self.ptr);
    }

    /// Get pending key events (empties the queue)
    /// Returns empty slice if backend doesn't support keyboard input
    pub fn getKeyEvents(self: Backend) []const KeyEvent {
        if (self.vtable.getKeyEvents) |func| {
            return func(self.ptr);
        }
        return &[_]KeyEvent{};
    }

    /// Get pending mouse events (empties the queue)
    /// Returns empty slice if backend doesn't support mouse input
    pub fn getMouseEvents(self: Backend) []const MouseEvent {
        if (self.vtable.getMouseEvents) |func| {
            return func(self.ptr);
        }
        return &[_]MouseEvent{};
    }

    /// Get pending raw inputfs events from the side-channel buffer
    /// (AD-2a Phase 2.4.2). Returns empty slice if the backend has no
    /// inputfs integration. The drawfs backend is the only one that
    /// populates this today; semadrawd uses the slice to feed the
    /// gesture recogniser in Phase 2.4.4.
    pub fn getInputfsEvents(self: Backend) []const input.Event {
        if (self.vtable.getInputfsEvents) |func| {
            return func(self.ptr);
        }
        return &[_]input.Event{};
    }

    /// Return a file descriptor the daemon should include in its main
    /// poll() set, or null if the backend has no pollable event source.
    /// Backends that push events via pollEvents() alone (X11, Wayland,
    /// Vulkan with polling) return null. Backends where an external
    /// process enqueues events on a file descriptor (drawfs, via kernel
    /// DRAWFSGIOC_INJECT_INPUT) return that fd so the daemon wakes
    /// immediately on input.
    pub fn getPollFd(self: Backend) ?std.posix.fd_t {
        if (self.vtable.getPollFd) |func| {
            return func(self.ptr);
        }
        return null;
    }

    /// AD-41.3: return the inputfs notify fd if the backend has one.
    /// See VTable.getInputfsPollFd for the rationale; null if the
    /// backend does not integrate with inputfs or the cdev was
    /// unavailable at init.
    pub fn getInputfsPollFd(self: Backend) ?std.posix.fd_t {
        if (self.vtable.getInputfsPollFd) |func| {
            return func(self.ptr);
        }
        return null;
    }

    /// ADR 0009: drain the input wake descriptor's pending kevents.
    pub fn drainInputWake(self: Backend) void {
        if (self.vtable.drainInputWake) |func| {
            func(self.ptr);
        }
    }

    /// AD-17: ask the backend for its native display size.
    ///
    /// Returns null if the backend has no detection mechanism (e.g.
    /// software, headless) or if detection is supported but not
    /// available right now (e.g. drawfs without efifb).
    ///
    /// The compositor uses this to size the framebuffer to the
    /// physical display rather than to a hardcoded default. The
    /// configured `OutputConfig.{width,height}` becomes the fallback
    /// rather than the actual.
    pub fn getDetectedDisplaySize(self: Backend) ?DisplaySize {
        if (self.vtable.getDetectedDisplaySize) |func| {
            return func(self.ptr);
        }
        return null;
    }

    /// Set clipboard content (selection: 0=CLIPBOARD, 1=PRIMARY)
    pub fn setClipboard(self: Backend, selection: u8, text: []const u8) !void {
        if (self.vtable.setClipboard) |func| {
            return func(self.ptr, selection, text);
        }
        return error.ClipboardNotSupported;
    }

    /// Request clipboard content (async - data available after pollEvents)
    pub fn requestClipboard(self: Backend, selection: u8) void {
        if (self.vtable.requestClipboard) |func| {
            func(self.ptr, selection);
        }
    }

    /// Get clipboard data (returns null if not available or not supported)
    pub fn getClipboardData(self: Backend, selection: u8) ?[]const u8 {
        if (self.vtable.getClipboardData) |func| {
            return func(self.ptr, selection);
        }
        return null;
    }

    /// Check if clipboard request is pending
    pub fn isClipboardPending(self: Backend) bool {
        if (self.vtable.isClipboardPending) |func| {
            return func(self.ptr);
        }
        return false;
    }

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Backend type enumeration
pub const BackendType = enum(u8) {
    /// Software renderer (CPU-based)
    software = 0,
    /// Headless (no output, for testing)
    headless = 1,
    /// Vulkan GPU renderer (X11 presentation)
    vulkan = 2,
    /// KMS/DRM direct output
    kms = 3,
    /// X11 windowed output
    x11 = 4,
    /// Wayland windowed output
    wayland = 5,
    /// Vulkan console backend (VK_KHR_display, no X11/Wayland)
    vulkan_console = 6,
    /// FreeBSD drawfs kernel module backend
    drawfs = 7,
};

/// Create a backend of the specified type
pub fn createBackend(allocator: std.mem.Allocator, backend_type: BackendType) !Backend {
    switch (backend_type) {
        .software => {
            const software = @import("software");
            return software.create(allocator);
        },
        .headless => {
            // Headless is just software without display
            const software = @import("software");
            return software.create(allocator);
        },
        .kms => {
            const drm = @import("drm");
            return drm.create(allocator);
        },
        .x11 => {
            const x11 = @import("x11");
            return x11.create(allocator);
        },
        .vulkan => {
            const vulkan = @import("vulkan");
            return vulkan.create(allocator);
        },
        .wayland => {
            const wayland = @import("wayland");
            return wayland.create(allocator);
        },
        .vulkan_console => {
            const vulkan_console = @import("vulkan_console");
            return vulkan_console.create(allocator);
        },
        .drawfs => {
            const drawfs = @import("drawfs");
            return drawfs.create(allocator);
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "RenderResult success" {
    const result = RenderResult.success(1, 100, 1000000);
    try std.testing.expectEqual(@as(u32, 1), result.surface_id);
    try std.testing.expectEqual(@as(u64, 100), result.frame_number);
    try std.testing.expectEqual(@as(?[]const u8, null), result.error_msg);
}

test "RenderResult failure" {
    const result = RenderResult.failure(2, "test error");
    try std.testing.expectEqual(@as(u32, 2), result.surface_id);
    try std.testing.expect(result.error_msg != null);
}

// CAPTURE-DESIGN.md commit 2: the frameSnapshot wrapper contract.
// A backend that does not implement the optional op answers null (a
// truthful "cannot be captured" rather than a guessed one), and an
// implementing backend's snapshot passes through with metadata and
// pixels paired in one aggregate.
const snapshot_test = struct {
    var probe: u8 = 0;
    const pixels = [_]u8{ 1, 2, 3, 4 } ** 4; // 2x2 at stride 8

    fn caps(_: *anyopaque) Capabilities {
        return .{
            .name = "stub",
            .max_width = 16,
            .max_height = 16,
            .supports_aa = false,
            .hardware_accelerated = false,
            .can_present = false,
        };
    }
    fn initFb(_: *anyopaque, _: FramebufferConfig) anyerror!void {}
    fn render(_: *anyopaque, request: RenderRequest) anyerror!RenderResult {
        return RenderResult.success(request.surface_id, 0, 0);
    }
    fn getPx(_: *anyopaque) ?[]u8 {
        return null;
    }
    fn resize(_: *anyopaque, _: u32, _: u32) anyerror!void {}
    fn poll(_: *anyopaque) bool {
        return true;
    }
    fn deinit(_: *anyopaque) void {}
    fn snap(_: *anyopaque) ?FrameSnapshot {
        return .{
            .width = 2,
            .height = 2,
            .stride = 8,
            .format = .bgra8,
            .pixels = &pixels,
        };
    }

    const without = Backend.VTable{
        .getCapabilities = caps,
        .initFramebuffer = initFb,
        .render = render,
        .getPixels = getPx,
        .resize = resize,
        .pollEvents = poll,
        .deinit = deinit,
    };
    const with = Backend.VTable{
        .getCapabilities = caps,
        .initFramebuffer = initFb,
        .render = render,
        .getPixels = getPx,
        .frameSnapshot = snap,
        .resize = resize,
        .pollEvents = poll,
        .deinit = deinit,
    };
};

test "frameSnapshot: backend without the optional op answers null" {
    const b = Backend{ .ptr = &snapshot_test.probe, .vtable = &snapshot_test.without };
    try std.testing.expect(b.frameSnapshot() == null);
}

test "frameSnapshot: implementing backend's snapshot passes through paired" {
    const b = Backend{ .ptr = &snapshot_test.probe, .vtable = &snapshot_test.with };
    const s = b.frameSnapshot() orelse return error.TestExpectedSnapshot;
    try std.testing.expectEqual(@as(u32, 2), s.width);
    try std.testing.expectEqual(@as(u32, 2), s.height);
    try std.testing.expectEqual(@as(u32, 8), s.stride);
    try std.testing.expectEqual(PixelFormat.bgra8, s.format);
    try std.testing.expectEqualSlices(u8, &snapshot_test.pixels, s.pixels);
}
