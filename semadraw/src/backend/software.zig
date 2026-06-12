const std = @import("std");
const backend = @import("backend");

/// Software renderer backend - CPU-based SDCS rendering
pub const SoftwareBackend = struct {
    allocator: std.mem.Allocator,
    framebuffer: ?[]u8,
    width: u32,
    height: u32,
    format: backend.PixelFormat,
    frame_count: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .framebuffer = null,
            .width = 0,
            .height = 0,
            .format = .rgba8,
            .frame_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.framebuffer) |fb| {
            self.allocator.free(fb);
            self.framebuffer = null;
        }
    }

    fn getCapabilitiesImpl(ctx: *anyopaque) backend.Capabilities {
        _ = ctx;
        return .{
            .name = "software",
            .max_width = 8192,
            .max_height = 8192,
            .supports_aa = true,
            .hardware_accelerated = false,
            .can_present = false,
        };
    }

    fn initFramebufferImpl(ctx: *anyopaque, config: backend.FramebufferConfig) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Free existing framebuffer
        if (self.framebuffer) |fb| {
            self.allocator.free(fb);
        }

        // Allocate new framebuffer
        const bytes_per_pixel: usize = switch (config.format) {
            .rgba8, .bgra8 => 4,
            .rgb8 => 3,
        };
        const size = @as(usize, config.width) * @as(usize, config.height) * bytes_per_pixel;

        self.framebuffer = try self.allocator.alloc(u8, size);
        self.width = config.width;
        self.height = config.height;
        self.format = config.format;

        // Clear to black
        @memset(self.framebuffer.?, 0);
    }

    /// AD-21 sub-item 9 / region damage: clear a rectangular region of
    /// the framebuffer to a background color. See backend.zig
    /// ClearRegionRequest doc comment for design rationale.
    fn clearRegionImpl(ctx: *anyopaque, request: backend.ClearRegionRequest) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const fb = self.framebuffer orelse return error.NoFramebuffer;

        const r = clampU8(request.color[0]);
        const g = clampU8(request.color[1]);
        const b = clampU8(request.color[2]);
        const a = clampU8(request.color[3]);

        const bytes_per_pixel: usize = switch (self.format) {
            .rgba8 => 4,
            .bgra8 => 4,
            .rgb8 => 3,
        };

        // Clamp the rect to framebuffer bounds.
        const fb_w_i: i32 = @intCast(self.width);
        const fb_h_i: i32 = @intCast(self.height);
        const x0: i32 = @max(0, request.x);
        const y0: i32 = @max(0, request.y);
        const x1: i32 = @min(fb_w_i, request.x + @as(i32, @intCast(request.width)));
        const y1: i32 = @min(fb_h_i, request.y + @as(i32, @intCast(request.height)));
        if (x0 >= x1 or y0 >= y1) return;

        const stride = @as(usize, @intCast(self.width)) * bytes_per_pixel;
        var py: i32 = y0;
        while (py < y1) : (py += 1) {
            var px: i32 = x0;
            while (px < x1) : (px += 1) {
                const idx = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(px)) * bytes_per_pixel;
                if (idx + bytes_per_pixel - 1 >= fb.len) continue;
                switch (self.format) {
                    .rgba8 => {
                        fb[idx + 0] = r;
                        fb[idx + 1] = g;
                        fb[idx + 2] = b;
                        fb[idx + 3] = a;
                    },
                    .bgra8 => {
                        fb[idx + 0] = b;
                        fb[idx + 1] = g;
                        fb[idx + 2] = r;
                        fb[idx + 3] = a;
                    },
                    .rgb8 => {
                        fb[idx + 0] = r;
                        fb[idx + 1] = g;
                        fb[idx + 2] = b;
                    },
                }
            }
        }
    }

    fn renderImpl(ctx: *anyopaque, request: backend.RenderRequest) anyerror!backend.RenderResult {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const start_time = std.time.nanoTimestamp();

        // Validate framebuffer
        const fb = self.framebuffer orelse return backend.RenderResult.failure(
            request.surface_id,
            "framebuffer not initialized",
        );

        // Clear if requested
        if (request.clear_color) |color| {
            self.clearFramebuffer(fb, color);
        }

        // Execute SDCS commands. The offset_x / offset_y from the
        // RenderRequest carries the surface's screen position; SDCS
        // commands inside this surface use surface-local coordinates,
        // so we translate them by (offset_x, offset_y) when writing
        // pixels into the framebuffer (per ADR 0005 section 3a).
        const offset_xf: f32 = @floatFromInt(request.offset_x);
        const offset_yf: f32 = @floatFromInt(request.offset_y);
        self.executeSdcs(fb, request.sdcs_data, offset_xf, offset_yf) catch |err| {
            return backend.RenderResult.failure(
                request.surface_id,
                @errorName(err),
            );
        };

        self.frame_count += 1;
        const end_time = std.time.nanoTimestamp();
        const render_time: u64 = @intCast(end_time - start_time);

        return backend.RenderResult.success(
            request.surface_id,
            self.frame_count,
            render_time,
        );
    }

    fn getPixelsImpl(ctx: *anyopaque) ?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.framebuffer;
    }

    fn resizeImpl(ctx: *anyopaque, width: u32, height: u32) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try initFramebufferImpl(ctx, .{
            .width = width,
            .height = height,
            .format = self.format,
        });
    }

    fn pollEventsImpl(_: *anyopaque) bool {
        // Software backend has no events to process
        return true;
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    // ========================================================================
    // Internal rendering functions
    // ========================================================================

    fn clearFramebuffer(self: *Self, fb: []u8, color: [4]f32) void {
        const r = clampU8(color[0]);
        const g = clampU8(color[1]);
        const b = clampU8(color[2]);
        const a = clampU8(color[3]);

        const bytes_per_pixel: usize = switch (self.format) {
            .rgba8 => 4,
            .bgra8 => 4,
            .rgb8 => 3,
        };

        var i: usize = 0;
        while (i < fb.len) : (i += bytes_per_pixel) {
            switch (self.format) {
                .rgba8 => {
                    fb[i + 0] = r;
                    fb[i + 1] = g;
                    fb[i + 2] = b;
                    fb[i + 3] = a;
                },
                .bgra8 => {
                    fb[i + 0] = b;
                    fb[i + 1] = g;
                    fb[i + 2] = r;
                    fb[i + 3] = a;
                },
                .rgb8 => {
                    fb[i + 0] = r;
                    fb[i + 1] = g;
                    fb[i + 2] = b;
                },
            }
        }
    }

    fn executeSdcs(self: *Self, fb: []u8, data: []const u8, offset_x: f32, offset_y: f32) !void {
        // Minimal SDCS execution - parse and execute commands
        // This is a simplified version; full implementation would use
        // the complete rendering logic from sdcs_replay.zig

        if (data.len < 64) return error.InvalidSdcs; // Header too small

        // Skip header (64 bytes)
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
            try self.executeCommand(fb, opcode, payload, offset_x, offset_y);

            // Align to 8 bytes
            offset += payload_len;
            const record_bytes = 8 + payload_len;
            const pad = (8 - (record_bytes % 8)) % 8;
            offset += pad;

            // Check for END
            if (opcode == 0x00F0) break;
        }
    }

    fn executeCommand(self: *Self, fb: []u8, opcode: u16, payload: []const u8, offset_x: f32, offset_y: f32) !void {
        switch (opcode) {
            0x0001 => {}, // RESET - no-op for now
            0x0010 => { // FILL_RECT
                if (payload.len >= 32) {
                    const x = readF32(payload[0..4]);
                    const y = readF32(payload[4..8]);
                    const w = readF32(payload[8..12]);
                    const h = readF32(payload[12..16]);
                    const r = readF32(payload[16..20]);
                    const g = readF32(payload[20..24]);
                    const b = readF32(payload[24..28]);
                    const a = readF32(payload[28..32]);

                    // Translate surface-local coords to framebuffer
                    // coords by applying the surface's offset.
                    self.fillRect(fb, x + offset_x, y + offset_y, w, h, r, g, b, a);
                }
            },
            0x00F0 => {}, // END
            else => {}, // Ignore unknown opcodes for now
        }
    }

    fn fillRect(self: *Self, fb: []u8, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32, a: f32) void {
        const fb_w = self.width;
        const fb_h = self.height;

        // Clamp to framebuffer bounds
        const x0: i32 = @intFromFloat(@max(0, x));
        const y0: i32 = @intFromFloat(@max(0, y));
        const x1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(fb_w)), x + w));
        const y1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(fb_h)), y + h));

        if (x0 >= x1 or y0 >= y1) return;

        const cr = clampU8(r);
        const cg = clampU8(g);
        const cb = clampU8(b);
        const ca = clampU8(a);

        const bytes_per_pixel: usize = 4; // RGBA8

        var py: i32 = y0;
        while (py < y1) : (py += 1) {
            var px: i32 = x0;
            while (px < x1) : (px += 1) {
                const idx = (@as(usize, @intCast(py)) * @as(usize, fb_w) + @as(usize, @intCast(px))) * bytes_per_pixel;
                if (idx + 3 < fb.len) {
                    // Simple SRC_OVER blend
                    if (ca == 255) {
                        fb[idx + 0] = cr;
                        fb[idx + 1] = cg;
                        fb[idx + 2] = cb;
                        fb[idx + 3] = ca;
                    } else if (ca > 0) {
                        const sa: f32 = @as(f32, @floatFromInt(ca)) / 255.0;
                        const da: f32 = @as(f32, @floatFromInt(fb[idx + 3])) / 255.0;
                        const out_a = sa + da * (1.0 - sa);

                        if (out_a > 0) {
                            fb[idx + 0] = blendChannel(cr, fb[idx + 0], sa, da, out_a);
                            fb[idx + 1] = blendChannel(cg, fb[idx + 1], sa, da, out_a);
                            fb[idx + 2] = blendChannel(cb, fb[idx + 2], sa, da, out_a);
                            fb[idx + 3] = @intFromFloat(@min(255.0, out_a * 255.0));
                        }
                    }
                }
            }
        }
    }

    const vtable = backend.Backend.VTable{
        .getCapabilities = getCapabilitiesImpl,
        .initFramebuffer = initFramebufferImpl,
        .render = renderImpl,
        .clearRegion = clearRegionImpl,
        .getPixels = getPixelsImpl,
        .resize = resizeImpl,
        .pollEvents = pollEventsImpl,
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

fn clampU8(v: f32) u8 {
    var x = v;
    if (x < 0.0) x = 0.0;
    if (x > 1.0) x = 1.0;
    return @intFromFloat(@round(x * 255.0));
}

fn readF32(bytes: *const [4]u8) f32 {
    const u = std.mem.readInt(u32, bytes, .little);
    return @bitCast(u);
}

fn blendChannel(src: u8, dst: u8, sa: f32, da: f32, out_a: f32) u8 {
    const s: f32 = @floatFromInt(src);
    const d: f32 = @floatFromInt(dst);
    const result = (s * sa + d * da * (1.0 - sa)) / out_a;
    return @intFromFloat(@min(255.0, @max(0.0, result)));
}

/// Create a software backend
pub fn create(allocator: std.mem.Allocator) !backend.Backend {
    const self = try allocator.create(SoftwareBackend);
    self.* = SoftwareBackend.init(allocator);
    return self.toBackend();
}

// ============================================================================
// Tests
// ============================================================================

test "SoftwareBackend init and deinit" {
    var sw = SoftwareBackend.init(std.testing.allocator);
    defer sw.deinit();

    const caps = SoftwareBackend.getCapabilitiesImpl(&sw);
    try std.testing.expectEqualStrings("software", caps.name);
    try std.testing.expect(!caps.hardware_accelerated);
}

test "SoftwareBackend framebuffer allocation" {
    var sw = SoftwareBackend.init(std.testing.allocator);
    defer sw.deinit();

    try SoftwareBackend.initFramebufferImpl(&sw, .{
        .width = 100,
        .height = 100,
        .format = .rgba8,
    });

    try std.testing.expectEqual(@as(u32, 100), sw.width);
    try std.testing.expectEqual(@as(u32, 100), sw.height);
    try std.testing.expect(sw.framebuffer != null);
    try std.testing.expectEqual(@as(usize, 100 * 100 * 4), sw.framebuffer.?.len);
}

test "clampU8" {
    try std.testing.expectEqual(@as(u8, 0), clampU8(-1.0));
    try std.testing.expectEqual(@as(u8, 0), clampU8(0.0));
    try std.testing.expectEqual(@as(u8, 128), clampU8(0.5));
    try std.testing.expectEqual(@as(u8, 255), clampU8(1.0));
    try std.testing.expectEqual(@as(u8, 255), clampU8(2.0));
}
