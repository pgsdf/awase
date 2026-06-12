const std = @import("std");
const sdcs = @import("sdcs.zig");

fn putU16LE(buf: []u8, off: *usize, v: u16) void {
    buf[off.* + 0] = @intCast(v & 0xff);
    buf[off.* + 1] = @intCast((v >> 8) & 0xff);
    off.* += 2;
}

fn putU32LE(buf: []u8, off: *usize, v: u32) void {
    buf[off.* + 0] = @intCast(v & 0xff);
    buf[off.* + 1] = @intCast((v >> 8) & 0xff);
    buf[off.* + 2] = @intCast((v >> 16) & 0xff);
    buf[off.* + 3] = @intCast((v >> 24) & 0xff);
    off.* += 4;
}

fn putF32LE(buf: []u8, off: *usize, v: f32) void {
    const u: u32 = @bitCast(v);
    putU32LE(buf, off, u);
}

fn appendZeros(list: *std.ArrayList(u8), gpa: std.mem.Allocator, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try list.append(gpa, 0);
}

// NOTE: Zig 0.15+ std.ArrayList APIs require an allocator per call.
// Use appendCmdAlloc for all command emission.

fn appendCmdAlloc(list: *std.ArrayList(u8), gpa: std.mem.Allocator, opcode: u16, payload: []const u8) !void {
    var hdr_bytes: [8]u8 = undefined;
    var off: usize = 0;
    putU16LE(hdr_bytes[0..], &off, opcode);
    putU16LE(hdr_bytes[0..], &off, 0); // flags
    putU32LE(hdr_bytes[0..], &off, @intCast(payload.len));

    try list.appendSlice(gpa, hdr_bytes[0..]);
    if (payload.len != 0) try list.appendSlice(gpa, payload);

    const record_bytes = @sizeOf(sdcs.CmdHdr) + payload.len;
    const pad = sdcs.pad8Len(record_bytes);
    if (pad != 0) try appendZeros(list, gpa, pad);
}

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    cmds: std.ArrayList(u8),

    pub const Rect = struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    };

    pub const BlendMode = struct {
        pub const SrcOver: u32 = 0;
        pub const Src: u32 = 1;
        pub const Clear: u32 = 2;
        pub const Add: u32 = 3;
    };

    pub const StrokeJoin = enum(u32) {
        Miter = 0,
        Bevel = 1,
        Round = 2,
    };

    pub const StrokeCap = enum(u32) {
        Butt = 0,
        Square = 1,
        Round = 2,
    };

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .allocator = allocator, .cmds = std.ArrayList(u8){} };
    }

    pub fn deinit(self: *Encoder) void {
        self.cmds.deinit(self.allocator);
    }

    pub fn reset(self: *Encoder) !void {
        // Start a new command stream.
        self.cmds.items.len = 0;
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.RESET, &[_]u8{});
    }

    /// Return the encoded command stream as an owned byte slice (raw commands only).
    /// Caller owns the returned memory.
    /// Note: This returns raw commands without SDCS header. For inline buffer transmission
    /// to the daemon, use finishBytesWithHeader() instead.
    pub fn finishBytes(self: *Encoder) ![]u8 {
        return try self.cmds.toOwnedSlice(self.allocator);
    }

    /// Return a complete SDCS buffer with header and chunk wrapper.
    /// Suitable for inline buffer transmission to the daemon.
    /// Caller owns the returned memory.
    pub fn finishBytesWithHeader(self: *Encoder) ![]u8 {
        // Append END opcode only if not already present as the last command.
        const end_size = 8; // CmdHdr size
        const already_has_end = self.cmds.items.len >= end_size and
            std.mem.readInt(u16, self.cmds.items[self.cmds.items.len - end_size ..][0..2], .little) == sdcs.Op.END;
        if (!already_has_end) {
            try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.END, &[_]u8{});
        }

        const payload_len = self.cmds.items.len;
        const payload_pad = sdcs.pad8Len(payload_len);
        const padded_payload = payload_len + payload_pad;

        // Total size: Header (64) + ChunkHeader (32) + padded payload
        const total_size = @sizeOf(sdcs.Header) + @sizeOf(sdcs.ChunkHeader) + padded_payload;
        const buffer = try self.allocator.alloc(u8, total_size);
        errdefer self.allocator.free(buffer);

        // Write header
        var header: sdcs.Header = .{
            .magic = undefined,
            .version_major = sdcs.version_major,
            .version_minor = sdcs.version_minor,
            .header_bytes = @sizeOf(sdcs.Header),
            .flags = 0,
            .chunk_count = 1,
            .stream_bytes = total_size,
            .chunk_dir_offset = @sizeOf(sdcs.Header),
            .reserved0 = 0,
            .reserved1 = 0,
            .reserved2 = 0,
        };
        @memcpy(header.magic[0..], sdcs.Magic);
        @memcpy(buffer[0..@sizeOf(sdcs.Header)], std.mem.asBytes(&header));

        // Write chunk header
        const chunk_offset = @sizeOf(sdcs.Header);
        var chunk: sdcs.ChunkHeader = .{
            .type = sdcs.ChunkType.CMDS,
            .flags = 0,
            .offset = chunk_offset,
            .bytes = @sizeOf(sdcs.ChunkHeader) + padded_payload,
            .payload_bytes = payload_len,
        };
        @memcpy(buffer[chunk_offset..][0..@sizeOf(sdcs.ChunkHeader)], std.mem.asBytes(&chunk));

        // Write payload
        const payload_offset = chunk_offset + @sizeOf(sdcs.ChunkHeader);
        @memcpy(buffer[payload_offset..][0..payload_len], self.cmds.items);

        // Zero padding
        if (payload_pad > 0) {
            @memset(buffer[payload_offset + payload_len ..][0..payload_pad], 0);
        }

        return buffer;
    }

    pub fn setClipRects(self: *Encoder, rects: []const Rect) !void {
        // Payload: u32 count (little endian) followed by count rects (x,y,w,h) as f32 LE.
        // We cap count for safety in this early implementation.
        if (rects.len > 1024) return error.OutOfMemory;

        const payload_len: usize = 4 + rects.len * 16;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        var off: usize = 0;
        putU32LE(payload, &off, @intCast(rects.len));
        for (rects) |rc| {
            putF32LE(payload, &off, rc.x);
            putF32LE(payload, &off, rc.y);
            putF32LE(payload, &off, rc.w);
            putF32LE(payload, &off, rc.h);
        }

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_CLIP_RECTS, payload);
    }

    pub fn clearClip(self: *Encoder) !void {
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.CLEAR_CLIP, &[_]u8{});
    }

    pub fn strokeRect(
        self: *Encoder,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        stroke_width: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    ) !void {
        if (!(stroke_width > 0.0)) return error.InvalidArgument;

        var payload: [36]u8 = undefined;
        var off: usize = 0;

        putF32LE(payload[0..], &off, x);
        putF32LE(payload[0..], &off, y);
        putF32LE(payload[0..], &off, w);
        putF32LE(payload[0..], &off, h);
        putF32LE(payload[0..], &off, stroke_width);
        putF32LE(payload[0..], &off, r);
        putF32LE(payload[0..], &off, g);
        putF32LE(payload[0..], &off, b);
        putF32LE(payload[0..], &off, a);

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.STROKE_RECT, payload[0..]);
    }

    pub fn setBlend(self: *Encoder, mode: u32) !void {
        var payload: [4]u8 = undefined;
        var off: usize = 0;
        putU32LE(payload[0..], &off, mode);
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_BLEND, payload[0..]);
    }

    /// Set anti-aliasing mode.
    /// enabled: 1 = enable AA, 0 = disable AA (default is disabled)
    pub fn setAntialias(self: *Encoder, enabled: bool) !void {
        var payload: [4]u8 = undefined;
        var off: usize = 0;
        putU32LE(payload[0..], &off, if (enabled) 1 else 0);
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_ANTIALIAS, payload[0..]);
    }

    pub fn setTransform2D(self: *Encoder, a: f32, b: f32, c: f32, d: f32, e: f32, f: f32) !void {
        // Payload: 6 f32 values (a b c d e f), little endian
        var payload: [24]u8 = undefined;
        var off: usize = 0;
        putF32LE(payload[0..], &off, a);
        putF32LE(payload[0..], &off, b);
        putF32LE(payload[0..], &off, c);
        putF32LE(payload[0..], &off, d);
        putF32LE(payload[0..], &off, e);
        putF32LE(payload[0..], &off, f);
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_TRANSFORM_2D, payload[0..]);
    }

    pub fn resetTransform(self: *Encoder) !void {
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.RESET_TRANSFORM, &[_]u8{});
    }

    pub fn fillRect(self: *Encoder, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32, a: f32) !void {
        var payload: [32]u8 = undefined;
        var off: usize = 0;
        putF32LE(payload[0..], &off, x);
        putF32LE(payload[0..], &off, y);
        putF32LE(payload[0..], &off, w);
        putF32LE(payload[0..], &off, h);
        putF32LE(payload[0..], &off, r);
        putF32LE(payload[0..], &off, g);
        putF32LE(payload[0..], &off, b);
        putF32LE(payload[0..], &off, a);
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.FILL_RECT, payload[0..]);
    }

    pub fn strokeLine(
        self: *Encoder,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        stroke_width: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    ) !void {
        if (!(stroke_width > 0.0)) return error.InvalidArgument;

        var payload: [36]u8 = undefined;
        var off: usize = 0;

        putF32LE(payload[0..], &off, x1);
        putF32LE(payload[0..], &off, y1);
        putF32LE(payload[0..], &off, x2);
        putF32LE(payload[0..], &off, y2);
        putF32LE(payload[0..], &off, stroke_width);
        putF32LE(payload[0..], &off, r);
        putF32LE(payload[0..], &off, g);
        putF32LE(payload[0..], &off, b);
        putF32LE(payload[0..], &off, a);

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.STROKE_LINE, payload[0..]);
    }

    pub fn setStrokeJoin(self: *Encoder, join: StrokeJoin) !void {
        var payload: [4]u8 = undefined;
        var off: usize = 0;
        putU32LE(payload[0..], &off, @intFromEnum(join));
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_STROKE_JOIN, payload[0..]);
    }

    pub fn setStrokeCap(self: *Encoder, cap: StrokeCap) !void {
        var payload: [4]u8 = undefined;
        var off: usize = 0;
        putU32LE(payload[0..], &off, @intFromEnum(cap));
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_STROKE_CAP, payload[0..]);
    }

    /// Set the miter limit for stroke joins.
    /// When a miter join would extend beyond miter_limit * stroke_width / 2,
    /// it falls back to a bevel join instead.
    /// Default value is 4.0 (same as SVG default).
    /// Must be >= 1.0; values less than 1.0 are clamped to 1.0.
    pub fn setMiterLimit(self: *Encoder, limit: f32) !void {
        var payload: [4]u8 = undefined;
        var off: usize = 0;
        putF32LE(payload[0..], &off, limit);
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_MITER_LIMIT, payload[0..]);
    }

    /// Stroke a quadratic Bezier curve from (x0,y0) through control point (cx,cy) to (x1,y1).
    /// Payload format: x0, y0, cx, cy, x1, y1, stroke_width, r, g, b, a (11 x f32 = 44 bytes)
    pub fn strokeQuadBezier(
        self: *Encoder,
        x0: f32,
        y0: f32,
        cx: f32,
        cy: f32,
        x1: f32,
        y1: f32,
        stroke_width: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    ) !void {
        if (!(stroke_width > 0.0)) return error.InvalidArgument;

        var payload: [44]u8 = undefined;
        var off: usize = 0;

        putF32LE(payload[0..], &off, x0);
        putF32LE(payload[0..], &off, y0);
        putF32LE(payload[0..], &off, cx);
        putF32LE(payload[0..], &off, cy);
        putF32LE(payload[0..], &off, x1);
        putF32LE(payload[0..], &off, y1);
        putF32LE(payload[0..], &off, stroke_width);
        putF32LE(payload[0..], &off, r);
        putF32LE(payload[0..], &off, g);
        putF32LE(payload[0..], &off, b);
        putF32LE(payload[0..], &off, a);

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.STROKE_QUAD_BEZIER, payload[0..]);
    }

    /// Point structure for path operations.
    pub const Point = struct {
        x: f32,
        y: f32,
    };

    /// Stroke a polyline path through the given points.
    /// Uses current join and cap settings. Minimum 2 points required.
    /// Payload format: stroke_width, r, g, b, a (5 x f32), point_count (u32), points (N x 2 x f32)
    pub fn strokePath(
        self: *Encoder,
        points: []const Point,
        stroke_width: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    ) !void {
        if (!(stroke_width > 0.0)) return error.InvalidArgument;
        if (points.len < 2) return error.InvalidArgument;
        if (points.len > 65535) return error.InvalidArgument; // Reasonable limit

        // Header: stroke_width, r, g, b, a (5 f32 = 20 bytes) + point_count (u32 = 4 bytes)
        const header_len: usize = 24;
        const points_len: usize = points.len * 8; // 2 f32 per point
        const payload_len: usize = header_len + points_len;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        var off: usize = 0;
        putF32LE(payload, &off, stroke_width);
        putF32LE(payload, &off, r);
        putF32LE(payload, &off, g);
        putF32LE(payload, &off, b);
        putF32LE(payload, &off, a);
        putU32LE(payload, &off, @intCast(points.len));

        for (points) |pt| {
            putF32LE(payload, &off, pt.x);
            putF32LE(payload, &off, pt.y);
        }

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.STROKE_PATH, payload);
    }

    /// Stroke a cubic Bezier curve from (x0,y0) through control points (cx1,cy1) and (cx2,cy2) to (x1,y1).
    /// Payload format: x0, y0, cx1, cy1, cx2, cy2, x1, y1, stroke_width, r, g, b, a (13 x f32 = 52 bytes)
    pub fn strokeCubicBezier(
        self: *Encoder,
        x0: f32,
        y0: f32,
        cx1: f32,
        cy1: f32,
        cx2: f32,
        cy2: f32,
        x1: f32,
        y1: f32,
        stroke_width: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    ) !void {
        if (!(stroke_width > 0.0)) return error.InvalidArgument;

        var payload: [52]u8 = undefined;
        var off: usize = 0;

        putF32LE(payload[0..], &off, x0);
        putF32LE(payload[0..], &off, y0);
        putF32LE(payload[0..], &off, cx1);
        putF32LE(payload[0..], &off, cy1);
        putF32LE(payload[0..], &off, cx2);
        putF32LE(payload[0..], &off, cy2);
        putF32LE(payload[0..], &off, x1);
        putF32LE(payload[0..], &off, y1);
        putF32LE(payload[0..], &off, stroke_width);
        putF32LE(payload[0..], &off, r);
        putF32LE(payload[0..], &off, g);
        putF32LE(payload[0..], &off, b);
        putF32LE(payload[0..], &off, a);

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.STROKE_CUBIC_BEZIER, payload[0..]);
    }

    /// Glyph structure for text rendering operations.
    pub const Glyph = struct {
        index: u32, // Glyph index in atlas (row * atlas_cols + col)
        x_offset: f32, // X offset from base position
        y_offset: f32, // Y offset from base position
    };

    /// Draw a run of glyphs using a simple grid-based glyph atlas.
    /// The atlas contains alpha values (0-255) for each pixel.
    /// Glyphs are arranged in a grid with cell_width × cell_height cells.
    /// Payload format: base_x, base_y, r, g, b, a, cell_w, cell_h, atlas_cols,
    ///                 atlas_w, atlas_h, glyph_count, [glyphs...], [atlas...]
    pub fn drawGlyphRun(
        self: *Encoder,
        base_x: f32,
        base_y: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
        cell_width: u32,
        cell_height: u32,
        atlas_cols: u32,
        atlas_width: u32,
        atlas_height: u32,
        glyphs: []const Glyph,
        atlas_data: []const u8,
    ) !void {
        if (glyphs.len == 0) return error.InvalidArgument;
        if (glyphs.len > 65535) return error.InvalidArgument;
        if (cell_width == 0 or cell_height == 0) return error.InvalidArgument;
        if (atlas_cols == 0) return error.InvalidArgument;
        if (atlas_width == 0 or atlas_height == 0) return error.InvalidArgument;
        if (atlas_data.len != @as(usize, atlas_width) * @as(usize, atlas_height)) {
            return error.InvalidArgument;
        }

        // Header: 48 bytes
        // Per-glyph: 12 bytes each (index u32, x_offset f32, y_offset f32)
        // Atlas: atlas_width * atlas_height bytes
        const header_len: usize = 48;
        const glyphs_len: usize = glyphs.len * 12;
        const payload_len: usize = header_len + glyphs_len + atlas_data.len;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        var off: usize = 0;
        putF32LE(payload, &off, base_x);
        putF32LE(payload, &off, base_y);
        putF32LE(payload, &off, r);
        putF32LE(payload, &off, g);
        putF32LE(payload, &off, b);
        putF32LE(payload, &off, a);
        putU32LE(payload, &off, cell_width);
        putU32LE(payload, &off, cell_height);
        putU32LE(payload, &off, atlas_cols);
        putU32LE(payload, &off, atlas_width);
        putU32LE(payload, &off, atlas_height);
        putU32LE(payload, &off, @intCast(glyphs.len));

        for (glyphs) |glyph| {
            putU32LE(payload, &off, glyph.index);
            putF32LE(payload, &off, glyph.x_offset);
            putF32LE(payload, &off, glyph.y_offset);
        }

        @memcpy(payload[header_len + glyphs_len ..], atlas_data);

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.DRAW_GLYPH_RUN, payload);
    }

    /// Blit an RGBA image at the specified destination position.
    /// The image is drawn at 1:1 scale, affected by the current transform.
    /// Payload format: dst_x(f32), dst_y(f32), img_w(u32), img_h(u32), pixels(RGBA bytes)
    pub fn blitImage(
        self: *Encoder,
        dst_x: f32,
        dst_y: f32,
        img_w: u32,
        img_h: u32,
        pixels: []const u8,
    ) !void {
        const expected_len: usize = @as(usize, img_w) * @as(usize, img_h) * 4;
        if (pixels.len != expected_len) return error.InvalidArgument;
        if (img_w == 0 or img_h == 0) return error.InvalidArgument;

        // Header: dst_x, dst_y (f32), img_w, img_h (u32) = 16 bytes
        const header_len: usize = 16;
        const payload_len: usize = header_len + pixels.len;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        var off: usize = 0;
        putF32LE(payload, &off, dst_x);
        putF32LE(payload, &off, dst_y);
        putU32LE(payload, &off, img_w);
        putU32LE(payload, &off, img_h);

        @memcpy(payload[header_len..], pixels);

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.BLIT_IMAGE, payload);
    }

    pub fn end(self: *Encoder) !void {
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.END, &[_]u8{});
    }

    pub fn writeToFile(self: *Encoder, file: std.fs.File) !void {
        try sdcs.writeHeader(file);

        const chunk_pos = try file.getPos();
        var ch = sdcs.ChunkHeader{
            .type = sdcs.ChunkType.CMDS,
            .flags = 0,
            .offset = chunk_pos,
            .bytes = 0,
            .payload_bytes = 0,
        };
        try file.writeAll(std.mem.asBytes(&ch));

        const payload_start = try file.getPos();
        try file.writeAll(self.cmds.items);

        // Pad chunk payload to 8-byte alignment
        const payload_bytes: u64 = self.cmds.items.len;
        const pad = sdcs.pad8Len(self.cmds.items.len);
        if (pad != 0) {
            const zeros = [_]u8{0} ** 8;
            try file.writeAll(zeros[0..pad]);
        }

        const end_pos = try file.getPos();
        const aligned_payload: u64 = end_pos - payload_start;

        ch.payload_bytes = payload_bytes;
        ch.bytes = @sizeOf(sdcs.ChunkHeader) + aligned_payload;

        try file.seekTo(chunk_pos);
        try file.writeAll(std.mem.asBytes(&ch));
        try file.seekTo(end_pos);
    }
};
