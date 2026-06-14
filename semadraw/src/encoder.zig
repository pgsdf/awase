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

    pub const FillRule = enum(u32) {
        nonzero = 0,
        even_odd = 1,
    };

    pub const ExtendMode = enum(u32) {
        pad = 0,
        repeat = 1,
        reflect = 2,
    };

    pub const PatternFilter = enum(u32) {
        nearest = 0,
    };

    pub const GradientStop = struct {
        offset: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
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

    /// Fill a path of one or more closed contours under a winding rule
    /// (ADR 0015). Each contour is a list of at least 3 points and is
    /// implicitly closed by the renderer (final point to first point);
    /// callers MUST NOT repeat the first point to close it. Curves are
    /// flattened to points by the caller, as with strokePath.
    /// Payload: r, g, b, a (4 x f32), fill_rule (u32), contour_count (u32),
    /// contour_lengths (contour_count x u32), points (sum x 2 x f32).
    pub fn fillPath(
        self: *Encoder,
        contours: []const []const Point,
        fill_rule: FillRule,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    ) !void {
        if (contours.len == 0) return error.InvalidArgument;
        if (contours.len > 65535) return error.InvalidArgument;

        var total_points: usize = 0;
        for (contours) |c| {
            if (c.len < 3) return error.InvalidArgument;
            total_points += c.len;
        }
        if (total_points > 65535) return error.InvalidArgument;

        const cc: usize = contours.len;
        const header_len: usize = 24;
        const table_len: usize = cc * 4;
        const points_len: usize = total_points * 8;
        const payload_len: usize = header_len + table_len + points_len;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        var off: usize = 0;
        putF32LE(payload, &off, r);
        putF32LE(payload, &off, g);
        putF32LE(payload, &off, b);
        putF32LE(payload, &off, a);
        putU32LE(payload, &off, @intFromEnum(fill_rule));
        putU32LE(payload, &off, @intCast(cc));

        for (contours) |c| {
            putU32LE(payload, &off, @intCast(c.len));
        }
        for (contours) |c| {
            for (c) |pt| {
                putF32LE(payload, &off, pt.x);
                putF32LE(payload, &off, pt.y);
            }
        }

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.FILL_PATH, payload);
    }

    /// Set the clip to an arbitrary path (ADR 0018, Stage C). The clip is one
    /// or more closed contours under a winding rule, authored in user space;
    /// the renderer bakes it to device space with the transform in effect when
    /// this command is decoded. Setting a path clip replaces any current clip
    /// (rectangles or path); CLEAR_CLIP clears it.
    ///
    /// Payload (ADR 0018 section 4): fill_rule (u32), contour_count (u32),
    /// contour_lengths (contour_count x u32), points (sum x 2 x f32). This is
    /// the FILL_PATH contour layout with the RGBA prefix removed.
    ///
    /// Argument validation mirrors fillPath, and additionally rejects
    /// non-finite coordinates (ADR 0018 section 7). Lengths are accumulated in
    /// usize to avoid overflow.
    pub fn setClipPath(
        self: *Encoder,
        contours: []const []const Point,
        fill_rule: FillRule,
    ) !void {
        if (contours.len == 0) return error.InvalidArgument;
        if (contours.len > 65535) return error.InvalidArgument;

        var total_points: usize = 0;
        for (contours) |c| {
            if (c.len < 3) return error.InvalidArgument;
            for (c) |pt| {
                if (!std.math.isFinite(pt.x) or !std.math.isFinite(pt.y)) {
                    return error.InvalidArgument;
                }
            }
            total_points += c.len;
        }
        if (total_points > 65535) return error.InvalidArgument;

        const cc: usize = contours.len;
        const header_len: usize = 8;
        const table_len: usize = cc * 4;
        const points_len: usize = total_points * 8;
        const payload_len: usize = header_len + table_len + points_len;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        var off: usize = 0;
        putU32LE(payload, &off, @intFromEnum(fill_rule));
        putU32LE(payload, &off, @intCast(cc));

        for (contours) |c| {
            putU32LE(payload, &off, @intCast(c.len));
        }
        for (contours) |c| {
            for (c) |pt| {
                putF32LE(payload, &off, pt.x);
                putF32LE(payload, &off, pt.y);
            }
        }

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_CLIP_PATH, payload);
    }

    /// Reset the current paint source to the inline-RGBA default (ADR 0016).
    pub fn setSourceNone(self: *Encoder) !void {
        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_SOURCE_NONE, &[_]u8{});
    }

    fn validateStops(stops: []const GradientStop) !void {
        if (stops.len < 2 or stops.len > 256) return error.InvalidArgument;
        var prev: f32 = 0.0;
        var first = true;
        for (stops) |s| {
            if (!std.math.isFinite(s.offset) or !std.math.isFinite(s.r) or
                !std.math.isFinite(s.g) or !std.math.isFinite(s.b) or
                !std.math.isFinite(s.a)) return error.InvalidArgument;
            if (s.offset < 0.0 or s.offset > 1.0) return error.InvalidArgument;
            if (!first and s.offset < prev) return error.InvalidArgument;
            prev = s.offset;
            first = false;
        }
    }

    fn writeStops(payload: []u8, off: *usize, stops: []const GradientStop) void {
        for (stops) |s| {
            putF32LE(payload, off, s.offset);
            putF32LE(payload, off, s.r);
            putF32LE(payload, off, s.g);
            putF32LE(payload, off, s.b);
            putF32LE(payload, off, s.a);
        }
    }

    /// Set a linear gradient paint source. Axis endpoints are in user space
    /// (ADR 0016 section 5). Rejects fewer than 2 or more than 256 stops, a
    /// non-finite input, offsets outside [0, 1] or out of order, and a
    /// degenerate (zero-length) axis.
    pub fn setSourceLinearGradient(
        self: *Encoder,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        stops: []const GradientStop,
        extend: ExtendMode,
    ) !void {
        if (!std.math.isFinite(x0) or !std.math.isFinite(y0) or
            !std.math.isFinite(x1) or !std.math.isFinite(y1)) return error.InvalidArgument;
        const dx = x1 - x0;
        const dy = y1 - y0;
        if (dx * dx + dy * dy <= 0.0) return error.InvalidArgument;
        try validateStops(stops);

        const payload_len: usize = 24 + stops.len * 20;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        var off: usize = 0;
        putF32LE(payload, &off, x0);
        putF32LE(payload, &off, y0);
        putF32LE(payload, &off, x1);
        putF32LE(payload, &off, y1);
        putU32LE(payload, &off, @intFromEnum(extend));
        putU32LE(payload, &off, @intCast(stops.len));
        writeStops(payload, &off, stops);

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_SOURCE_LINEAR_GRADIENT, payload);
    }

    /// Set a concentric radial gradient paint source. Center is in user space,
    /// radius in user units (ADR 0016 section 5). Rejects a non-finite input, a
    /// radius not greater than 0, and the same stop violations as the linear
    /// encoder.
    pub fn setSourceRadialGradient(
        self: *Encoder,
        cx: f32,
        cy: f32,
        radius: f32,
        stops: []const GradientStop,
        extend: ExtendMode,
    ) !void {
        if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or
            !std.math.isFinite(radius)) return error.InvalidArgument;
        if (radius <= 0.0) return error.InvalidArgument;
        try validateStops(stops);

        const payload_len: usize = 20 + stops.len * 20;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        var off: usize = 0;
        putF32LE(payload, &off, cx);
        putF32LE(payload, &off, cy);
        putF32LE(payload, &off, radius);
        putU32LE(payload, &off, @intFromEnum(extend));
        putU32LE(payload, &off, @intCast(stops.len));
        writeStops(payload, &off, stops);

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_SOURCE_RADIAL_GRADIENT, payload);
    }

    /// Set a pattern (surface) paint source (ADR 0017). The tile is inline
    /// straight-RGBA8, row-major, top-left origin, tile_w * tile_h * 4 bytes,
    /// reusing the BLIT_IMAGE texel layout. The affine (a, b, c, d, e, f) maps
    /// pattern (texel) space to user space, the same convention as
    /// setTransform2D. extend_x and extend_y are per-axis; filter is nearest
    /// (floor-based point sampling) in this stage. Rejects, with
    /// error.InvalidArgument: a non-finite affine component (checked first), a
    /// degenerate affine (det == 0 computed in f32 on the components written),
    /// tile_w or tile_h outside [1, 4096], and a texels length not equal to
    /// tile_w * tile_h * 4 (computed in usize). The extend and filter enums are
    /// type-checked, so an out-of-range selector cannot be constructed.
    pub fn setSourcePattern(
        self: *Encoder,
        a: f32,
        b: f32,
        c: f32,
        d: f32,
        e: f32,
        f: f32,
        extend_x: ExtendMode,
        extend_y: ExtendMode,
        filter: PatternFilter,
        tile_w: u32,
        tile_h: u32,
        texels: []const u8,
    ) !void {
        // Finiteness first, so the determinant never sees a non-finite input.
        if (!std.math.isFinite(a) or !std.math.isFinite(b) or
            !std.math.isFinite(c) or !std.math.isFinite(d) or
            !std.math.isFinite(e) or !std.math.isFinite(f)) return error.InvalidArgument;
        // Nondegeneracy in f32 on the components that will be serialized.
        const det = a * d - c * b;
        if (det == 0.0) return error.InvalidArgument;
        if (tile_w < 1 or tile_w > 4096) return error.InvalidArgument;
        if (tile_h < 1 or tile_h > 4096) return error.InvalidArgument;
        const expected_texels: usize = @as(usize, tile_w) * @as(usize, tile_h) * 4;
        if (texels.len != expected_texels) return error.InvalidArgument;

        const header_len: usize = 44;
        const payload_len: usize = header_len + texels.len;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        var off: usize = 0;
        putF32LE(payload, &off, a);
        putF32LE(payload, &off, b);
        putF32LE(payload, &off, c);
        putF32LE(payload, &off, d);
        putF32LE(payload, &off, e);
        putF32LE(payload, &off, f);
        putU32LE(payload, &off, @intFromEnum(extend_x));
        putU32LE(payload, &off, @intFromEnum(extend_y));
        putU32LE(payload, &off, @intFromEnum(filter));
        putU32LE(payload, &off, tile_w);
        putU32LE(payload, &off, tile_h);
        @memcpy(payload[header_len..], texels);

        try appendCmdAlloc(&self.cmds, self.allocator, sdcs.Op.SET_SOURCE_PATTERN, payload);
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

test "fillPath encodes multi-contour payload" {
    const testing = std.testing;
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();

    const outer = [_]Encoder.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    const inner = [_]Encoder.Point{
        .{ .x = 3, .y = 3 },
        .{ .x = 7, .y = 3 },
        .{ .x = 5, .y = 7 },
    };
    const contours = [_][]const Encoder.Point{ outer[0..], inner[0..] };

    try enc.fillPath(contours[0..], .even_odd, 0.25, 0.5, 0.75, 1.0);

    const buf = enc.cmds.items;
    // Command record: 8-byte header + payload + pad8.
    // payload_len = 24 + 4*2 + 8*(4+3) = 88; record = 8 + 88 = 96; pad8(96) = 0.
    try testing.expectEqual(@as(usize, 96), buf.len);

    const opcode = std.mem.readInt(u16, buf[0..2], .little);
    try testing.expectEqual(sdcs.Op.FILL_PATH, opcode);

    const payload_bytes = std.mem.readInt(u32, buf[4..8], .little);
    try testing.expectEqual(@as(u32, 88), payload_bytes);

    const payload = buf[8..];
    // fill_rule at payload offset 16, contour_count at 20.
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, payload[16..20], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, payload[20..24], .little));
    // contour_lengths at offset 24: 4 then 3.
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, payload[24..28], .little));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, payload[28..32], .little));
}

test "fillPath rejects degenerate input" {
    const testing = std.testing;
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();

    const two = [_]Encoder.Point{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 } };
    const bad = [_][]const Encoder.Point{two[0..]};
    try testing.expectError(error.InvalidArgument, enc.fillPath(bad[0..], .nonzero, 1, 1, 1, 1));

    const empty = [_][]const Encoder.Point{};
    try testing.expectError(error.InvalidArgument, enc.fillPath(empty[0..], .nonzero, 1, 1, 1, 1));
}

test "setClipPath encodes multi-contour payload" {
    const testing = std.testing;
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();

    const outer = [_]Encoder.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    const inner = [_]Encoder.Point{
        .{ .x = 3, .y = 3 },
        .{ .x = 7, .y = 3 },
        .{ .x = 5, .y = 7 },
    };
    const contours = [_][]const Encoder.Point{ outer[0..], inner[0..] };

    try enc.setClipPath(contours[0..], .even_odd);

    const buf = enc.cmds.items;
    // Command record: 8-byte header + payload + pad8.
    // payload_len = 8 + 4*2 + 8*(4+3) = 72; record = 8 + 72 = 80; pad8(80) = 0.
    try testing.expectEqual(@as(usize, 80), buf.len);

    const opcode = std.mem.readInt(u16, buf[0..2], .little);
    try testing.expectEqual(sdcs.Op.SET_CLIP_PATH, opcode);

    const payload_bytes = std.mem.readInt(u32, buf[4..8], .little);
    try testing.expectEqual(@as(u32, 72), payload_bytes);

    const payload = buf[8..];
    // No color prefix: fill_rule at payload offset 0, contour_count at 4.
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, payload[0..4], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, payload[4..8], .little));
    // contour_lengths at offset 8: 4 then 3.
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, payload[8..12], .little));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, payload[12..16], .little));
    // First point (0,0) begins at offset 16.
    try testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(std.mem.readInt(u32, payload[16..20], .little))));
}

test "setClipPath rejects degenerate and non-finite input" {
    const testing = std.testing;
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();

    // Fewer than 3 points.
    const two = [_]Encoder.Point{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 } };
    const bad = [_][]const Encoder.Point{two[0..]};
    try testing.expectError(error.InvalidArgument, enc.setClipPath(bad[0..], .nonzero));

    // No contours.
    const empty = [_][]const Encoder.Point{};
    try testing.expectError(error.InvalidArgument, enc.setClipPath(empty[0..], .nonzero));

    // Non-finite coordinate in an otherwise valid contour.
    const nan = [_]Encoder.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = std.math.inf(f32), .y = 0 },
        .{ .x = 5, .y = 5 },
    };
    const bad_nan = [_][]const Encoder.Point{nan[0..]};
    try testing.expectError(error.InvalidArgument, enc.setClipPath(bad_nan[0..], .nonzero));
}

test "setSourceNone encodes empty payload" {
    const testing = std.testing;
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();
    try enc.setSourceNone();
    const buf = enc.cmds.items;
    try testing.expectEqual(@as(usize, 8), buf.len); // header only, pad8(8)=0
    try testing.expectEqual(sdcs.Op.SET_SOURCE_NONE, std.mem.readInt(u16, buf[0..2], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[4..8], .little));
}

test "setSourceLinearGradient encodes payload" {
    const testing = std.testing;
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();
    const stops = [_]Encoder.GradientStop{
        .{ .offset = 0.0, .r = 1, .g = 0, .b = 0, .a = 1 },
        .{ .offset = 1.0, .r = 0, .g = 0, .b = 1, .a = 1 },
    };
    try enc.setSourceLinearGradient(0, 0, 100, 0, stops[0..], .pad);
    const buf = enc.cmds.items;
    // payload = 24 + 2*20 = 64; record = 8 + 64 = 72; pad8(72)=0.
    try testing.expectEqual(@as(usize, 72), buf.len);
    try testing.expectEqual(sdcs.Op.SET_SOURCE_LINEAR_GRADIENT, std.mem.readInt(u16, buf[0..2], .little));
    try testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, buf[4..8], .little));
    const payload = buf[8..];
    // extend at payload offset 16, stop_count at 20.
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, payload[16..20], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, payload[20..24], .little));
}

test "setSourceRadialGradient encodes payload" {
    const testing = std.testing;
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();
    const stops = [_]Encoder.GradientStop{
        .{ .offset = 0.0, .r = 1, .g = 1, .b = 1, .a = 1 },
        .{ .offset = 0.5, .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 },
        .{ .offset = 1.0, .r = 0, .g = 0, .b = 0, .a = 1 },
    };
    try enc.setSourceRadialGradient(50, 50, 40, stops[0..], .reflect);
    const buf = enc.cmds.items;
    // payload = 20 + 3*20 = 80; record = 8 + 80 = 88; pad8(88)=0.
    try testing.expectEqual(@as(usize, 88), buf.len);
    try testing.expectEqual(sdcs.Op.SET_SOURCE_RADIAL_GRADIENT, std.mem.readInt(u16, buf[0..2], .little));
    const payload = buf[8..];
    // extend at payload offset 12, stop_count at 16.
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, payload[12..16], .little));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, payload[16..20], .little));
}

test "gradient encoders reject invalid input" {
    const testing = std.testing;
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();
    const ok = [_]Encoder.GradientStop{
        .{ .offset = 0.0, .r = 0, .g = 0, .b = 0, .a = 1 },
        .{ .offset = 1.0, .r = 1, .g = 1, .b = 1, .a = 1 },
    };
    const one = [_]Encoder.GradientStop{ok[0]};
    try testing.expectError(error.InvalidArgument, enc.setSourceLinearGradient(0, 0, 10, 0, one[0..], .pad));
    try testing.expectError(error.InvalidArgument, enc.setSourceLinearGradient(5, 5, 5, 5, ok[0..], .pad)); // degenerate axis
    try testing.expectError(error.InvalidArgument, enc.setSourceRadialGradient(0, 0, 0, ok[0..], .pad)); // radius <= 0
    const bad_off = [_]Encoder.GradientStop{
        .{ .offset = -0.1, .r = 0, .g = 0, .b = 0, .a = 1 },
        .{ .offset = 1.0, .r = 1, .g = 1, .b = 1, .a = 1 },
    };
    try testing.expectError(error.InvalidArgument, enc.setSourceLinearGradient(0, 0, 10, 0, bad_off[0..], .pad));
    const dec = [_]Encoder.GradientStop{
        .{ .offset = 0.8, .r = 0, .g = 0, .b = 0, .a = 1 },
        .{ .offset = 0.2, .r = 1, .g = 1, .b = 1, .a = 1 },
    };
    try testing.expectError(error.InvalidArgument, enc.setSourceLinearGradient(0, 0, 10, 0, dec[0..], .pad));
    const nanstop = [_]Encoder.GradientStop{
        .{ .offset = 0.0, .r = std.math.nan(f32), .g = 0, .b = 0, .a = 1 },
        .{ .offset = 1.0, .r = 1, .g = 1, .b = 1, .a = 1 },
    };
    try testing.expectError(error.InvalidArgument, enc.setSourceLinearGradient(0, 0, 10, 0, nanstop[0..], .pad));
}

test "setSourcePattern encodes payload" {
    const testing = std.testing;
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();
    const tex = [_]u8{0} ** 16; // 2x2 RGBA8
    try enc.setSourcePattern(1, 0, 0, 1, 0, 0, .repeat, .reflect, .nearest, 2, 2, tex[0..]);
    const buf = enc.cmds.items;
    // payload = 44 + 2*2*4 = 60; record = 8 + 60 = 68; pad8(68) = 4 -> 72.
    try testing.expectEqual(@as(usize, 72), buf.len);
    try testing.expectEqual(sdcs.Op.SET_SOURCE_PATTERN, std.mem.readInt(u16, buf[0..2], .little));
    const payload = buf[8..];
    // a at offset 0; extend_x 24, extend_y 28, filter 32, tile_w 36, tile_h 40.
    try testing.expectEqual(@as(f32, 1.0), @as(f32, @bitCast(std.mem.readInt(u32, payload[0..4], .little))));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, payload[24..28], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, payload[28..32], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, payload[32..36], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, payload[36..40], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, payload[40..44], .little));
}

test "setSourcePattern rejects invalid input" {
    const testing = std.testing;
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();
    const tex = [_]u8{0} ** 16; // 2x2
    const empty = [_]u8{};
    // non-finite affine component (checked first).
    try testing.expectError(error.InvalidArgument, enc.setSourcePattern(std.math.nan(f32), 0, 0, 1, 0, 0, .pad, .pad, .nearest, 2, 2, tex[0..]));
    // degenerate affine: det = 2*0 - 0*0 = 0.
    try testing.expectError(error.InvalidArgument, enc.setSourcePattern(2, 0, 0, 0, 0, 0, .pad, .pad, .nearest, 2, 2, tex[0..]));
    // tile dimensions out of range.
    try testing.expectError(error.InvalidArgument, enc.setSourcePattern(1, 0, 0, 1, 0, 0, .pad, .pad, .nearest, 0, 2, empty[0..]));
    try testing.expectError(error.InvalidArgument, enc.setSourcePattern(1, 0, 0, 1, 0, 0, .pad, .pad, .nearest, 4097, 2, empty[0..]));
    // texels length does not match tile_w*tile_h*4.
    const short = [_]u8{0} ** 12;
    try testing.expectError(error.InvalidArgument, enc.setSourcePattern(1, 0, 0, 1, 0, 0, .pad, .pad, .nearest, 2, 2, short[0..]));
}
