const std = @import("std");
const posix = std.posix;
const backend = @import("backend");
const evdev = @import("evdev");

const log = std.log.scoped(.drm_backend);

/// DRM ioctl commands
const DRM_IOCTL_BASE: u32 = 'd';

fn DRM_IO(nr: u8) u32 {
    return @as(u32, nr) << 8 | DRM_IOCTL_BASE;
}

fn DRM_IOWR(nr: u8, comptime T: type) u32 {
    return 0xC0000000 | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, nr) << 8) | DRM_IOCTL_BASE;
}

/// Wrapper for DRM ioctl calls that handles the type conversion
fn drm_ioctl(fd: posix.fd_t, request: u32, arg: usize) c_int {
    // Use std.os.linux.ioctl which accepts u32 request directly
    const linux = std.os.linux;
    const rc = linux.ioctl(@intCast(fd), request, arg);
    // Convert result - negative errno comes back as large positive
    const signed_rc: isize = @bitCast(rc);
    return @intCast(signed_rc);
}

const DRM_IOCTL_SET_MASTER = DRM_IO(0x1e);
const DRM_IOCTL_DROP_MASTER = DRM_IO(0x1f);
const DRM_IOCTL_MODE_GETRESOURCES = DRM_IOWR(0xA0, drm_mode_card_res);
const DRM_IOCTL_MODE_GETCONNECTOR = DRM_IOWR(0xA7, drm_mode_get_connector);
const DRM_IOCTL_MODE_GETENCODER = DRM_IOWR(0xA6, drm_mode_get_encoder);
const DRM_IOCTL_MODE_GETCRTC = DRM_IOWR(0xA1, drm_mode_crtc);
const DRM_IOCTL_MODE_SETCRTC = DRM_IOWR(0xA2, drm_mode_crtc);
const DRM_IOCTL_MODE_CREATE_DUMB = DRM_IOWR(0xB2, drm_mode_create_dumb);
const DRM_IOCTL_MODE_MAP_DUMB = DRM_IOWR(0xB3, drm_mode_map_dumb);
const DRM_IOCTL_MODE_DESTROY_DUMB = DRM_IOWR(0xB4, drm_mode_destroy_dumb);
const DRM_IOCTL_MODE_ADDFB = DRM_IOWR(0xAE, drm_mode_fb_cmd);
const DRM_IOCTL_MODE_RMFB = DRM_IOWR(0xAF, u32);
const DRM_IOCTL_MODE_PAGE_FLIP = DRM_IOWR(0xB0, drm_mode_page_flip);

/// DRM mode info structure
const drm_mode_modeinfo = extern struct {
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    vrefresh: u32,
    flags: u32,
    type_: u32,
    name: [32]u8,
};

/// Card resources
const drm_mode_card_res = extern struct {
    fb_id_ptr: u64,
    crtc_id_ptr: u64,
    connector_id_ptr: u64,
    encoder_id_ptr: u64,
    count_fbs: u32,
    count_crtcs: u32,
    count_connectors: u32,
    count_encoders: u32,
    min_width: u32,
    max_width: u32,
    min_height: u32,
    max_height: u32,
};

/// Connector info
const drm_mode_get_connector = extern struct {
    encoders_ptr: u64,
    modes_ptr: u64,
    props_ptr: u64,
    prop_values_ptr: u64,
    count_modes: u32,
    count_props: u32,
    count_encoders: u32,
    encoder_id: u32,
    connector_id: u32,
    connector_type: u32,
    connector_type_id: u32,
    connection: u32,
    mm_width: u32,
    mm_height: u32,
    subpixel: u32,
    pad: u32,
};

/// Encoder info
const drm_mode_get_encoder = extern struct {
    encoder_id: u32,
    encoder_type: u32,
    crtc_id: u32,
    possible_crtcs: u32,
    possible_clones: u32,
};

/// CRTC info
const drm_mode_crtc = extern struct {
    set_connectors_ptr: u64,
    count_connectors: u32,
    crtc_id: u32,
    fb_id: u32,
    x: u32,
    y: u32,
    gamma_size: u32,
    mode_valid: u32,
    mode: drm_mode_modeinfo,
};

/// Create dumb buffer
const drm_mode_create_dumb = extern struct {
    height: u32,
    width: u32,
    bpp: u32,
    flags: u32,
    handle: u32,
    pitch: u32,
    size: u64,
};

/// Map dumb buffer
const drm_mode_map_dumb = extern struct {
    handle: u32,
    pad: u32,
    offset: u64,
};

/// Destroy dumb buffer
const drm_mode_destroy_dumb = extern struct {
    handle: u32,
};

/// Framebuffer command
const drm_mode_fb_cmd = extern struct {
    fb_id: u32,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
    depth: u32,
    handle: u32,
};

/// Page flip request
const drm_mode_page_flip = extern struct {
    crtc_id: u32,
    fb_id: u32,
    flags: u32,
    reserved: u32,
    user_data: u64,
};

const DRM_MODE_PAGE_FLIP_EVENT = 0x01;

/// Connection status
const DRM_MODE_CONNECTED = 1;
const DRM_MODE_DISCONNECTED = 2;
const DRM_MODE_UNKNOWNCONNECTION = 3;

/// Dumb buffer for double buffering
const DumbBuffer = struct {
    handle: u32,
    fb_id: u32,
    size: u64,
    pitch: u32,
    map: ?[]align(4096) u8,

    fn create(fd: posix.fd_t, width: u32, height: u32) !DumbBuffer {
        // Create dumb buffer
        var create_req = drm_mode_create_dumb{
            .width = width,
            .height = height,
            .bpp = 32,
            .flags = 0,
            .handle = 0,
            .pitch = 0,
            .size = 0,
        };

        const create_result = drm_ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, @intFromPtr(&create_req));
        if (create_result != 0) {
            return error.CreateDumbFailed;
        }

        // Add framebuffer
        var fb_cmd = drm_mode_fb_cmd{
            .fb_id = 0,
            .width = width,
            .height = height,
            .pitch = create_req.pitch,
            .bpp = 32,
            .depth = 24,
            .handle = create_req.handle,
        };

        const fb_result = drm_ioctl(fd, DRM_IOCTL_MODE_ADDFB, @intFromPtr(&fb_cmd));
        if (fb_result != 0) {
            // Clean up handle
            var destroy_dumb = drm_mode_destroy_dumb{ .handle = create_req.handle };
            _ = drm_ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, @intFromPtr(&destroy_dumb));
            return error.AddFbFailed;
        }

        // Map buffer
        var map_req = drm_mode_map_dumb{
            .handle = create_req.handle,
            .pad = 0,
            .offset = 0,
        };

        const map_result = drm_ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, @intFromPtr(&map_req));
        if (map_result != 0) {
            _ = drm_ioctl(fd, DRM_IOCTL_MODE_RMFB, @intFromPtr(&fb_cmd.fb_id));
            var destroy_dumb = drm_mode_destroy_dumb{ .handle = create_req.handle };
            _ = drm_ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, @intFromPtr(&destroy_dumb));
            return error.MapDumbFailed;
        }

        const map_ptr = posix.mmap(
            null,
            @intCast(create_req.size),
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            @intCast(map_req.offset),
        ) catch {
            _ = drm_ioctl(fd, DRM_IOCTL_MODE_RMFB, @intFromPtr(&fb_cmd.fb_id));
            var destroy_dumb = drm_mode_destroy_dumb{ .handle = create_req.handle };
            _ = drm_ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, @intFromPtr(&destroy_dumb));
            return error.MmapFailed;
        };

        return .{
            .handle = create_req.handle,
            .fb_id = fb_cmd.fb_id,
            .size = create_req.size,
            .pitch = create_req.pitch,
            .map = @as([*]align(4096) u8, @ptrCast(@alignCast(map_ptr)))[0..@intCast(create_req.size)],
        };
    }

    fn destroy(self: *DumbBuffer, fd: posix.fd_t) void {
        if (self.map) |m| {
            posix.munmap(m);
            self.map = null;
        }
        _ = drm_ioctl(fd, DRM_IOCTL_MODE_RMFB, @intFromPtr(&self.fb_id));
        var destroy_req = drm_mode_destroy_dumb{ .handle = self.handle };
        _ = drm_ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, @intFromPtr(&destroy_req));
    }
};

/// DRM/KMS Backend for direct display output
pub const DrmBackend = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    connector_id: u32,
    crtc_id: u32,
    mode: drm_mode_modeinfo,
    width: u32,
    height: u32,
    buffers: [2]?DumbBuffer,
    front_buffer: u8,
    frame_count: u64,
    saved_crtc: ?drm_mode_crtc,

    // Input handling via evdev module
    input: ?*evdev.EvdevInput,

    // Clipboard storage (file-based for console use)
    // Selection 0 = CLIPBOARD, Selection 1 = PRIMARY
    clipboard_data: [2]?[]u8,
    clipboard_pending: [2]bool,

    // File paths for clipboard persistence
    const CLIPBOARD_PATH = "/tmp/.semadraw-clipboard";
    const PRIMARY_PATH = "/tmp/.semadraw-primary";

    const Self = @This();

    /// Open DRM device and set up display
    pub fn init(allocator: std.mem.Allocator, device_path: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .fd = -1,
            .connector_id = 0,
            .crtc_id = 0,
            .mode = undefined,
            .width = 0,
            .height = 0,
            .buffers = .{ null, null },
            .front_buffer = 0,
            .frame_count = 0,
            .saved_crtc = null,
            // Input via evdev module
            .input = null,
            // Clipboard initialization
            .clipboard_data = .{ null, null },
            .clipboard_pending = .{ false, false },
        };

        // Open device
        self.fd = posix.open(device_path, .{ .ACCMODE = .RDWR }, 0) catch {
            return error.OpenFailed;
        };
        errdefer posix.close(self.fd);

        // Try to become master
        _ = drm_ioctl(self.fd, DRM_IOCTL_SET_MASTER, @as(usize, 0));

        // Get resources and find connector
        try self.findConnector();

        // Initialize input devices via evdev module
        self.input = evdev.EvdevInput.init(allocator, self.width, self.height) catch |err| blk: {
            log.warn("failed to initialize evdev input: {}", .{err});
            break :blk null;
        };

        return self;
    }

    /// Open default DRM device
    pub fn initDefault(allocator: std.mem.Allocator) !*Self {
        // Try common device paths
        const paths = [_][]const u8{
            "/dev/dri/card0",
            "/dev/dri/card1",
            "/dev/drm0", // FreeBSD
        };

        var last_err: ?anyerror = null;
        var had_resources_failed = false;
        for (paths) |path| {
            if (init(allocator, path)) |self| {
                return self;
            } else |err| {
                log.warn("failed to open {s}: {}", .{ path, err });
                if (err == error.GetResourcesFailed) {
                    had_resources_failed = true;
                }
                last_err = err;
                continue;
            }
        }

        // Provide helpful error message
        if (had_resources_failed) {
            log.err("KMS backend requires exclusive display access.", .{});
            log.err("If running under X11/Wayland, use '--backend x11' or '--backend wayland' instead.", .{});
            log.err("For KMS, switch to a virtual console (Ctrl+Alt+F2) and run without a display server.", .{});
        }

        if (last_err) |err| {
            return err;
        }
        return error.NoDeviceFound;
    }

    fn findConnector(self: *Self) !void {
        // Get resource counts first
        var res = std.mem.zeroes(drm_mode_card_res);
        var result = drm_ioctl(self.fd, DRM_IOCTL_MODE_GETRESOURCES, @intFromPtr(&res));
        if (result != 0) {
            return error.GetResourcesFailed;
        }

        if (res.count_connectors == 0) {
            return error.NoConnectors;
        }

        // Allocate arrays
        const connector_ids = try self.allocator.alloc(u32, res.count_connectors);
        defer self.allocator.free(connector_ids);
        const crtc_ids = try self.allocator.alloc(u32, res.count_crtcs);
        defer self.allocator.free(crtc_ids);
        const encoder_ids = try self.allocator.alloc(u32, res.count_encoders);
        defer self.allocator.free(encoder_ids);

        res.connector_id_ptr = @intFromPtr(connector_ids.ptr);
        res.crtc_id_ptr = @intFromPtr(crtc_ids.ptr);
        res.encoder_id_ptr = @intFromPtr(encoder_ids.ptr);

        result = drm_ioctl(self.fd, DRM_IOCTL_MODE_GETRESOURCES, @intFromPtr(&res));
        if (result != 0) {
            return error.GetResourcesFailed;
        }

        // Find connected connector with mode
        for (connector_ids) |conn_id| {
            var conn = std.mem.zeroes(drm_mode_get_connector);
            conn.connector_id = conn_id;

            result = drm_ioctl(self.fd, DRM_IOCTL_MODE_GETCONNECTOR, @intFromPtr(&conn));
            if (result != 0) continue;

            if (conn.connection != DRM_MODE_CONNECTED or conn.count_modes == 0) {
                continue;
            }

            // Get modes
            const modes = try self.allocator.alloc(drm_mode_modeinfo, conn.count_modes);
            defer self.allocator.free(modes);
            conn.modes_ptr = @intFromPtr(modes.ptr);

            result = drm_ioctl(self.fd, DRM_IOCTL_MODE_GETCONNECTOR, @intFromPtr(&conn));
            if (result != 0) continue;

            // Get encoder
            var encoder = std.mem.zeroes(drm_mode_get_encoder);
            encoder.encoder_id = conn.encoder_id;
            result = drm_ioctl(self.fd, DRM_IOCTL_MODE_GETENCODER, @intFromPtr(&encoder));
            if (result != 0) continue;

            // Found a valid connector
            self.connector_id = conn_id;
            self.crtc_id = encoder.crtc_id;
            self.mode = modes[0]; // Use preferred/first mode
            self.width = modes[0].hdisplay;
            self.height = modes[0].vdisplay;

            // Save current CRTC
            var saved = std.mem.zeroes(drm_mode_crtc);
            saved.crtc_id = self.crtc_id;
            if (drm_ioctl(self.fd, DRM_IOCTL_MODE_GETCRTC, @intFromPtr(&saved)) == 0) {
                self.saved_crtc = saved;
            }

            log.info("found connector {}: {}x{}@{}Hz", .{
                conn_id,
                self.width,
                self.height,
                self.mode.vrefresh,
            });

            return;
        }

        return error.NoConnectedDisplay;
    }

    pub fn deinit(self: *Self) void {
        // Free clipboard data
        for (&self.clipboard_data) |*data| {
            if (data.*) |d| {
                self.allocator.free(d);
                data.* = null;
            }
        }

        // Cleanup evdev input
        if (self.input) |inp| {
            inp.deinit();
        }

        // Restore saved CRTC
        if (self.saved_crtc) |*saved| {
            _ = drm_ioctl(self.fd, DRM_IOCTL_MODE_SETCRTC, @intFromPtr(saved));
        }

        // Destroy buffers
        for (&self.buffers) |*buf| {
            if (buf.*) |*b| {
                b.destroy(self.fd);
                buf.* = null;
            }
        }

        // Drop master and close
        _ = drm_ioctl(self.fd, DRM_IOCTL_DROP_MASTER, @as(usize, 0));
        if (self.fd >= 0) {
            posix.close(self.fd);
        }

        self.allocator.destroy(self);
    }

    /// Create double buffers
    pub fn createBuffers(self: *Self) !void {
        for (&self.buffers, 0..) |*buf, i| {
            buf.* = DumbBuffer.create(self.fd, self.width, self.height) catch |err| {
                log.err("failed to create buffer {}: {}", .{ i, err });
                return err;
            };
        }
    }

    /// Set mode on display
    pub fn setMode(self: *Self) !void {
        if (self.buffers[0] == null) {
            try self.createBuffers();
        }

        var connector_id = self.connector_id;
        var crtc = drm_mode_crtc{
            .set_connectors_ptr = @intFromPtr(&connector_id),
            .count_connectors = 1,
            .crtc_id = self.crtc_id,
            .fb_id = self.buffers[0].?.fb_id,
            .x = 0,
            .y = 0,
            .gamma_size = 0,
            .mode_valid = 1,
            .mode = self.mode,
        };

        const result = drm_ioctl(self.fd, DRM_IOCTL_MODE_SETCRTC, @intFromPtr(&crtc));
        if (result != 0) {
            return error.SetCrtcFailed;
        }

        log.info("mode set: {}x{}@{}Hz", .{ self.width, self.height, self.mode.vrefresh });
    }

    /// Get back buffer for rendering
    pub fn getBackBuffer(self: *Self) ?[]u8 {
        const back = (self.front_buffer + 1) % 2;
        if (self.buffers[back]) |*buf| {
            return buf.map;
        }
        return null;
    }

    /// Flip buffers (swap front/back)
    pub fn flip(self: *Self) !void {
        const back = (self.front_buffer + 1) % 2;
        const buf = self.buffers[back] orelse return error.NoBuffer;

        var flip_req = drm_mode_page_flip{
            .crtc_id = self.crtc_id,
            .fb_id = buf.fb_id,
            .flags = DRM_MODE_PAGE_FLIP_EVENT,
            .reserved = 0,
            .user_data = self.frame_count,
        };

        const result = drm_ioctl(self.fd, DRM_IOCTL_MODE_PAGE_FLIP, @intFromPtr(&flip_req));
        if (result != 0) {
            return error.PageFlipFailed;
        }

        self.front_buffer = back;
        self.frame_count += 1;
    }

    /// Wait for vsync (page flip completion)
    pub fn waitVsync(self: *Self) !void {
        // Poll for DRM events
        var pfd = [_]posix.pollfd{.{
            .fd = self.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        _ = posix.poll(&pfd, 1000) catch return error.PollFailed;

        if (pfd[0].revents & posix.POLL.IN != 0) {
            // Read event (simplified - just drain the fd)
            var buf: [256]u8 = undefined;
            _ = posix.read(self.fd, &buf) catch {};
        }
    }

    // ========================================================================
    // Clipboard support (file-based for console use)
    // ========================================================================

    fn getClipboardPath(selection: u8) [:0]const u8 {
        return if (selection == 0) CLIPBOARD_PATH else PRIMARY_PATH;
    }

    /// Set clipboard content and persist to file
    pub fn setClipboard(self: *Self, selection: u8, text: []const u8) !void {
        if (selection > 1) return error.InvalidSelection;

        // Free existing data
        if (self.clipboard_data[selection]) |old| {
            self.allocator.free(old);
        }

        // Copy to internal buffer
        const data = try self.allocator.alloc(u8, text.len);
        @memcpy(data, text);
        self.clipboard_data[selection] = data;

        // Persist to file for cross-process sharing
        const path = getClipboardPath(selection);
        const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |err| {
            log.warn("failed to persist clipboard to {s}: {}", .{ path, err });
            return; // Still keep in memory even if file write fails
        };
        defer file.close();
        file.writeAll(text) catch |err| {
            log.warn("failed to write clipboard data: {}", .{err});
        };

        log.debug("clipboard set: {} bytes to selection {}", .{ text.len, selection });
    }

    /// Request clipboard content (loads from file if not in memory)
    pub fn requestClipboard(self: *Self, selection: u8) void {
        if (selection > 1) return;

        // If we don't have data in memory, try to load from file
        if (self.clipboard_data[selection] == null) {
            const path = getClipboardPath(selection);
            const file = std.fs.openFileAbsolute(path, .{}) catch {
                self.clipboard_pending[selection] = true;
                return;
            };
            defer file.close();

            const stat = file.stat() catch {
                self.clipboard_pending[selection] = true;
                return;
            };

            if (stat.size > 0 and stat.size < 1024 * 1024) { // Max 1MB
                const data = self.allocator.alloc(u8, @intCast(stat.size)) catch {
                    self.clipboard_pending[selection] = true;
                    return;
                };
                const bytes_read = file.readAll(data) catch {
                    self.allocator.free(data);
                    self.clipboard_pending[selection] = true;
                    return;
                };
                if (bytes_read == data.len) {
                    self.clipboard_data[selection] = data;
                } else {
                    self.allocator.free(data);
                }
            }
        }

        self.clipboard_pending[selection] = true;
    }

    /// Get clipboard data (returns null if not available)
    pub fn getClipboardData(self: *Self, selection: u8) ?[]const u8 {
        if (selection > 1) return null;
        return self.clipboard_data[selection];
    }

    /// Check if clipboard request is pending
    pub fn isClipboardPending(self: *Self) bool {
        const pending = self.clipboard_pending[0] or self.clipboard_pending[1];
        // Clear pending flags after check
        self.clipboard_pending[0] = false;
        self.clipboard_pending[1] = false;
        return pending;
    }

    // ========================================================================
    // Backend interface implementation
    // ========================================================================

    fn getCapabilitiesImpl(ctx: *anyopaque) backend.Capabilities {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return .{
            .name = "DRM/KMS",
            .max_width = self.width,
            .max_height = self.height,
            .supports_aa = true,
            .hardware_accelerated = false, // Dumb buffers are CPU-rendered
            .can_present = true,
        };
    }

    fn initFramebufferImpl(ctx: *anyopaque, config: backend.FramebufferConfig) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Check if mode needs to change
        if (config.width != self.width or config.height != self.height) {
            // Would need to find a matching mode - for now, just use current
            log.warn("requested size {}x{} differs from display {}x{}", .{
                config.width,
                config.height,
                self.width,
                self.height,
            });
        }

        try self.createBuffers();
        try self.setMode();
    }

    fn renderImpl(ctx: *anyopaque, request: backend.RenderRequest) anyerror!backend.RenderResult {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const start = std.time.nanoTimestamp();

        const buffer = self.getBackBuffer() orelse {
            return backend.RenderResult.failure(request.surface_id, "no back buffer");
        };

        // Clear if requested
        if (request.clear_color) |color| {
            const r: u8 = @intFromFloat(color[0] * 255.0);
            const g: u8 = @intFromFloat(color[1] * 255.0);
            const b: u8 = @intFromFloat(color[2] * 255.0);
            const a: u8 = @intFromFloat(color[3] * 255.0);

            var i: usize = 0;
            while (i < buffer.len) : (i += 4) {
                buffer[i] = b; // BGRA format for most DRM
                buffer[i + 1] = g;
                buffer[i + 2] = r;
                buffer[i + 3] = a;
            }
        }

        // TODO: Execute SDCS commands (would integrate with software renderer)
        _ = request.sdcs_data;

        const end = std.time.nanoTimestamp();
        return backend.RenderResult.success(
            request.surface_id,
            self.frame_count,
            @intCast(end - start),
        );
    }

    fn getPixelsImpl(ctx: *anyopaque) ?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.getBackBuffer();
    }

    fn resizeImpl(ctx: *anyopaque, width: u32, height: u32) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = width;
        _ = height;
        // DRM mode is fixed to display - can't resize arbitrarily
        log.warn("resize not supported for DRM backend", .{});
        _ = self;
    }

    fn pollEventsImpl(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.input) |inp| {
            _ = inp.poll();
        }
        return true;
    }

    fn getKeyEventsImpl(ctx: *anyopaque) []const backend.KeyEvent {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.input) |inp| {
            return inp.getKeyEvents();
        }
        return &[_]backend.KeyEvent{};
    }

    fn getMouseEventsImpl(ctx: *anyopaque) []const backend.MouseEvent {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.input) |inp| {
            return inp.getMouseEvents();
        }
        return &[_]backend.MouseEvent{};
    }

    fn setClipboardImpl(ctx: *anyopaque, selection: u8, text: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.setClipboard(selection, text);
    }

    fn requestClipboardImpl(ctx: *anyopaque, selection: u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.requestClipboard(selection);
    }

    fn getClipboardDataImpl(ctx: *anyopaque, selection: u8) ?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.getClipboardData(selection);
    }

    fn isClipboardPendingImpl(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.isClipboardPending();
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    pub const vtable = backend.Backend.VTable{
        .getCapabilities = getCapabilitiesImpl,
        .initFramebuffer = initFramebufferImpl,
        .render = renderImpl,
        .getPixels = getPixelsImpl,
        .resize = resizeImpl,
        .pollEvents = pollEventsImpl,
        .getKeyEvents = getKeyEventsImpl,
        .getMouseEvents = getMouseEventsImpl,
        .setClipboard = setClipboardImpl,
        .requestClipboard = requestClipboardImpl,
        .getClipboardData = getClipboardDataImpl,
        .isClipboardPending = isClipboardPendingImpl,
        .deinit = deinitImpl,
    };

    pub fn toBackend(self: *Self) backend.Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

/// Create DRM backend
pub fn create(allocator: std.mem.Allocator) !backend.Backend {
    const drm = try DrmBackend.initDefault(allocator);
    return drm.toBackend();
}

/// Create DRM backend with specific device
pub fn createWithDevice(allocator: std.mem.Allocator, device_path: []const u8) !backend.Backend {
    const drm = try DrmBackend.init(allocator, device_path);
    return drm.toBackend();
}

// ============================================================================
// Tests
// ============================================================================

test "DrmBackend struct size" {
    try std.testing.expect(@sizeOf(DrmBackend) > 0);
}

test "DumbBuffer struct size" {
    try std.testing.expect(@sizeOf(DumbBuffer) > 0);
}
