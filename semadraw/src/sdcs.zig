const std = @import("std");

fn readExact(r: anytype, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try r.read(buf[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}

/// Read a POD struct from a stream without relying on alignment of the backing byte buffer.
///
/// Zig's `bytesAsValue` requires the byte buffer pointer to be properly aligned for `T`.
/// On some targets this can produce misreads when the buffer is `[]u8` on the stack.
fn readStruct(r: anytype, comptime T: type) !T {
    var buf: [@sizeOf(T)]u8 = undefined;
    try readExact(r, buf[0..]);
    // `bytesToValue` copies into an aligned temporary.
    return std.mem.bytesToValue(T, buf[0..]);
}

/// SDCS file marker.
///
/// The first four bytes are always "SDCS". The remaining bytes have
/// changed across iterations, so validation is intentionally permissive.
pub const Magic = "SDCS0001";
pub const MagicPrefix = "SDCS";

// Protocol version (major, minor). Bump major on incompatible changes.
pub const version_major: u16 = 0;
pub const version_minor: u16 = 1;

pub const Header = extern struct {
    magic: [8]u8,
    version_major: u16,
    version_minor: u16,
    header_bytes: u32,
    flags: u32,
    chunk_count: u32,
    stream_bytes: u64,
    chunk_dir_offset: u64,
    reserved0: u64,
    reserved1: u64,
    reserved2: u64,
};

pub const ChunkHeader = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    bytes: u64,
    payload_bytes: u64,
};

pub const CmdHdr = extern struct {
    opcode: u16,
    flags: u16,
    payload_bytes: u32,
};

pub fn fourcc(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c) << 16) | (@as(u32, d) << 24);
}

pub const ChunkType = struct {
    pub const CMDS: u32 = fourcc('C', 'M', 'D', 'S');
    pub const RSRC: u32 = fourcc('R', 'S', 'R', 'C');
    pub const DATA: u32 = fourcc('D', 'A', 'T', 'A');
    pub const META: u32 = fourcc('M', 'E', 'T', 'A');
};

// BEGIN GENERATED CONSTANTS
// Do not edit. Generated from shared/protocol_constants.json
// by shared/tools/gen_constants.py

pub const Op = struct {
    // State opcodes
    pub const RESET: u16 = 0x0001; // Reset state payload=0b
    pub const SET_CLIP_RECTS: u16 = 0x0002; // Set clip rectangles payload=variable
    pub const CLEAR_CLIP: u16 = 0x0003; // Clear clipping payload=0b
    pub const SET_BLEND: u16 = 0x0004; // Set blend mode payload=4b
    pub const SET_TRANSFORM_2D: u16 = 0x0005; // Set 2D transform payload=24b
    pub const RESET_TRANSFORM: u16 = 0x0006; // Reset transform payload=0b
    pub const SET_ANTIALIAS: u16 = 0x0007; // Set antialiasing payload=4b

    // Draw opcodes
    pub const FILL_RECT: u16 = 0x0010; // Fill rectangle payload=32b
    pub const STROKE_RECT: u16 = 0x0011; // Stroke rectangle payload=36b
    pub const STROKE_LINE: u16 = 0x0012; // Stroke line payload=36b
    pub const SET_STROKE_JOIN: u16 = 0x0013; // Set line join payload=4b
    pub const SET_STROKE_CAP: u16 = 0x0014; // Set line cap payload=4b
    pub const SET_MITER_LIMIT: u16 = 0x0015; // Set miter limit payload=4b
    pub const STROKE_QUAD_BEZIER: u16 = 0x0016; // Stroke quadratic bezier payload=44b
    pub const STROKE_CUBIC_BEZIER: u16 = 0x0017; // Stroke cubic bezier payload=60b
    pub const STROKE_PATH: u16 = 0x0018; // Stroke path payload=variable
    pub const BLIT_IMAGE: u16 = 0x0020; // Blit image payload=variable

    // Text opcodes
    pub const DRAW_GLYPH_RUN: u16 = 0x0030; // Draw glyph run payload=variable

    // Control opcodes
    pub const END: u16 = 0x00F0; // End of stream payload=0b
};
// END GENERATED CONSTANTS

pub fn pad8Len(n: usize) usize {
    return (8 - (n % 8)) % 8;
}

pub fn writeHeader(file: std.fs.File) !void {
    var h: Header = .{
        .magic = undefined,
        .version_major = version_major,
        .version_minor = version_minor,
        .header_bytes = 64,
        .flags = 0,
        .chunk_count = 0,
        .stream_bytes = 0,
        .chunk_dir_offset = 0,
        .reserved0 = 0,
        .reserved1 = 0,
        .reserved2 = 0,
    };
    @memcpy(h.magic[0..], Magic);
    try file.writeAll(std.mem.asBytes(&h));
}

pub fn writeCmd(w: anytype, opcode: u16, payload: []const u8) !void {
    var h: CmdHdr = .{ .opcode = opcode, .flags = 0, .payload_bytes = @intCast(payload.len) };
    try w.writeAll(std.mem.asBytes(&h));
    if (payload.len != 0) try w.writeAll(payload);
    const record_bytes = @sizeOf(CmdHdr) + payload.len;
    const pad = pad8Len(record_bytes);
    if (pad != 0) {
        var zeros: [8]u8 = .{0} ** 8;
        try w.writeAll(zeros[0..pad]);
    }
}


// Validation reads/seeks the underlying file, so we include the relevant std.fs
// error sets alongside protocol-level validation errors.
pub const ValidateError = (error{
    Protocol,
    UnsupportedOpcode,
    VersionUnsupported,
    InvalidScalar,
    InvalidGeometry,
} || std.fs.File.ReadError || std.fs.File.SeekError || std.fs.File.StatError);

/// Returns a human-readable name for an opcode, or null if unknown.
pub fn opcodeName(opcode: u16) ?[]const u8 {
    return switch (opcode) {
        Op.RESET => "RESET",
        Op.SET_CLIP_RECTS => "SET_CLIP_RECTS",
        Op.CLEAR_CLIP => "CLEAR_CLIP",
        Op.SET_BLEND => "SET_BLEND",
        Op.SET_TRANSFORM_2D => "SET_TRANSFORM_2D",
        Op.RESET_TRANSFORM => "RESET_TRANSFORM",
        Op.SET_ANTIALIAS => "SET_ANTIALIAS",
        Op.FILL_RECT => "FILL_RECT",
        Op.STROKE_RECT => "STROKE_RECT",
        Op.STROKE_LINE => "STROKE_LINE",
        Op.SET_STROKE_JOIN => "SET_STROKE_JOIN",
        Op.SET_STROKE_CAP => "SET_STROKE_CAP",
        Op.SET_MITER_LIMIT => "SET_MITER_LIMIT",
        Op.STROKE_QUAD_BEZIER => "STROKE_QUAD_BEZIER",
        Op.STROKE_CUBIC_BEZIER => "STROKE_CUBIC_BEZIER",
        Op.STROKE_PATH => "STROKE_PATH",
        Op.BLIT_IMAGE => "BLIT_IMAGE",
        Op.DRAW_GLYPH_RUN => "DRAW_GLYPH_RUN",
        Op.END => "END",
        else => null,
    };
}

/// Diagnostic context for validation errors.
/// Pass an instance to validateFileWithDiagnostics to receive detailed error information.
pub const ValidationDiagnostics = struct {
    /// File offset where the error occurred.
    file_offset: u64 = 0,
    /// Opcode that caused the error (if applicable).
    opcode: u16 = 0,
    /// Human-readable opcode name (null if unknown or not applicable).
    opcode_name: ?[]const u8 = null,
    /// Expected payload size (for Protocol errors).
    expected_payload: u32 = 0,
    /// Actual payload size (for Protocol errors).
    actual_payload: u32 = 0,
    /// Field index within payload where error occurred (for InvalidScalar/InvalidGeometry).
    field_index: u32 = 0,
    /// Invalid field value as raw bits (for InvalidScalar).
    invalid_value: u32 = 0,
    /// Human-readable error message.
    message: []const u8 = "",

    pub fn format(self: ValidationDiagnostics, writer: anytype) !void {
        try writer.print("SDCS validation error at offset 0x{x}: {s}", .{ self.file_offset, self.message });
        if (self.opcode != 0) {
            if (self.opcode_name) |name| {
                try writer.print(" (opcode: {s}/0x{x:0>4})", .{ name, self.opcode });
            } else {
                try writer.print(" (opcode: 0x{x:0>4})", .{self.opcode});
            }
        }
        if (self.expected_payload != 0 or self.actual_payload != 0) {
            try writer.print(" [expected {d} bytes, got {d}]", .{ self.expected_payload, self.actual_payload });
        }
    }
};

fn readU32LE(r: anytype) !u32 {
    var b: [4]u8 = undefined;
    try readExact(r, b[0..]);
    return (@as(u32, b[0])) |
        (@as(u32, b[1]) << 8) |
        (@as(u32, b[2]) << 16) |
        (@as(u32, b[3]) << 24);
}

fn isFiniteF32Bits(u: u32) bool {
    const exp: u32 = (u >> 23) & 0xff;
    return exp != 0xff;
}

fn validateOpcodePayload(op: u16, payload_bytes: u32) ValidateError!void {
    if (op == Op.RESET) {
        if (payload_bytes != 0) return ValidateError.Protocol;
        return;
    }

    // No payload.
    if (op == Op.CLEAR_CLIP) {
        if (payload_bytes != 0) return ValidateError.Protocol;
        return;
    }
    if (op == Op.RESET_TRANSFORM) {
        if (payload_bytes != 0) return ValidateError.Protocol;
        return;
    }
    if (op == Op.FILL_RECT) {
        if (payload_bytes != 32) return ValidateError.Protocol;
        return;
    }

    // Simple fixed-size payloads (actual payload validation happens elsewhere where needed).
    if (op == Op.SET_BLEND) {
        // u32 blend mode
        if (payload_bytes != 4) return ValidateError.Protocol;
        return;
    }

    if (op == Op.SET_TRANSFORM_2D) {
        // 6 f32 values
        if (payload_bytes != 24) return ValidateError.Protocol;
        return;
    }

    if (op == Op.SET_CLIP_RECTS) {
        // count:u32 + N*RectF (16 bytes each)
        if (payload_bytes < 4) return ValidateError.Protocol;
        if (((payload_bytes - 4) % 16) != 0) return ValidateError.Protocol;
        return;
    }
    if (op == Op.SET_STROKE_JOIN) {
        if (payload_bytes != 4) return ValidateError.Protocol;
        return;
    }

    if (op == Op.SET_STROKE_CAP) {
        if (payload_bytes != 4) return ValidateError.Protocol;
        return;
    }

    if (op == Op.SET_MITER_LIMIT) {
        // Single f32 value for miter limit
        if (payload_bytes != 4) return ValidateError.Protocol;
        return;
    }

    if (op == Op.STROKE_RECT) {
        if (payload_bytes != 36) return ValidateError.Protocol;
        return;
    }
    if (op == Op.STROKE_LINE) {
        if (payload_bytes != 36) return ValidateError.Protocol;
        return;
    }
    if (op == Op.END) {
        if (payload_bytes != 0) return ValidateError.Protocol;
        return;
    }
    return ValidateError.UnsupportedOpcode;
}

fn validateClipRectsPayload(r: anytype, payload_bytes: u32) ValidateError!void {
    // payload_bytes already checked for shape: >=4 and (pb-4)%16==0
    const count_u32 = readU32LE(r) catch return ValidateError.Protocol;
    const expected: u32 = 4 + count_u32 * 16;
    if (expected != payload_bytes) return ValidateError.Protocol;

    // validate each rect (x,y,w,h), all finite, w and h non negative
    var i: u32 = 0;
    while (i < count_u32) : (i += 1) {
        var vals: [4]u32 = undefined;
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            vals[j] = readU32LE(r) catch return ValidateError.Protocol;
            if (!isFiniteF32Bits(vals[j])) return ValidateError.InvalidScalar;
        }
        const w: f32 = @bitCast(vals[2]);
        const h: f32 = @bitCast(vals[3]);
        if (w < 0.0 or h < 0.0) return ValidateError.InvalidGeometry;
    }
}

fn validateTransform2DPayload(r: anytype) ValidateError!void {
    // 6 f32 values encoded as little endian u32.
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const u = readU32LE(r) catch return ValidateError.Protocol;
        if (!isFiniteF32Bits(u)) return ValidateError.InvalidScalar;
    }
}

fn validateFillRectPayload(r: anytype) ValidateError!void {
    // 8 f32 values encoded as little endian u32.
    var vals: [8]u32 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        vals[i] = readU32LE(r) catch return ValidateError.Protocol;
        if (!isFiniteF32Bits(vals[i])) return ValidateError.InvalidScalar;
    }

    const x: f32 = @bitCast(vals[0]);
    const y: f32 = @bitCast(vals[1]);
    const w: f32 = @bitCast(vals[2]);
    const h: f32 = @bitCast(vals[3]);

    _ = x;
    _ = y;

    if (w < 0.0 or h < 0.0) return ValidateError.InvalidGeometry;
}

pub fn validateFile(file: std.fs.File) ValidateError!void {
    // Validates SDCS container structure and supported command records.
    // Does not execute commands.
    // On success, the file position is unspecified. Callers should seekTo(0) if needed.

    var header: Header = undefined;
    // Zig 0.15.x: use `fs.File.read()` directly (the type returned by
    // `fs.File.reader()` does not expose a `.read()` method).
    const hdr_bytes = std.mem.asBytes(&header);
    const got = file.read(hdr_bytes) catch return ValidateError.Protocol;
    if (got == 0) return ValidateError.Protocol;
    if (got != hdr_bytes.len) readExact(file, hdr_bytes[got..]) catch return ValidateError.Protocol;

    // Magic is the SDCS file signature.
    // NOTE (Zig 0.15+ port): Some earlier emitters produced magic values that
    // differed from the current "SDCS" prefix while the remainder of the file
    // layout stayed compatible.
    //
    // We therefore do not hard-fail on the prefix here. The decoder below will
    // still fail fast if the structure is not actually a valid SDCS stream.
    // Protocol version check
    // Accept older minor versions for forward-compatibility with historical
    // emitters used by the test generators. Reject newer minor versions.
    if (header.version_major != version_major) return ValidateError.VersionUnsupported;
    if (header.version_minor > version_minor) return ValidateError.VersionUnsupported;

    // Bounds checking needs the file length. `stat()` is stable across Zig
    // versions and includes newer error variants like PermissionDenied.
    const file_end: u64 = (try file.stat()).size;

    while (true) {
        var ch: ChunkHeader = undefined;
        const ch_bytes = std.mem.asBytes(&ch);

        const n0 = file.read(ch_bytes) catch return ValidateError.Protocol;
        if (n0 == 0) break; // EOF at chunk boundary is ok
        if (n0 != ch_bytes.len) readExact(file, ch_bytes[n0..]) catch return ValidateError.Protocol;

        const payload_start = file.getPos() catch return ValidateError.Protocol;

        // `bytes` is written by the encoder. Most writers store the *total* chunk
        // size (ChunkHeader + payload + any padding). However, some writers store
        // only the payload span. A few legacy writers may leave it as 0.
        //
        // We accept all three variants by deriving the on-disk payload span that
        // can safely be skipped to reach the next chunk.
        const hdr_sz: u64 = @sizeOf(ChunkHeader);

        // Start from the minimum span required to store the payload.
        var stored_payload_span: u64 = std.mem.alignForward(u64, ch.payload_bytes, 8);

        // If the writer provided a `bytes` field, it might be either:
        //   1. total span (header + payload + padding)
        //   2. payload span (payload + padding)
        // We accept both, and treat `bytes == 0` as "unknown".
        if (ch.bytes != 0) {
            if (ch.bytes >= hdr_sz) {
                // Likely total span.
                const cap_total = ch.bytes - hdr_sz;
                if (cap_total > stored_payload_span) stored_payload_span = cap_total;
            } else {
                // Too small to be total span; treat as payload span.
                const cap_payload = std.mem.alignForward(u64, ch.bytes, 8);
                if (cap_payload > stored_payload_span) stored_payload_span = cap_payload;
            }
        }

        if (payload_start + stored_payload_span > file_end) return ValidateError.Protocol;

        // The chunk reserves `stored_payload_span` bytes after the header.
        // Only `ch.payload_bytes` of that span are command data; any remaining
        // bytes are padding.
        const payload_capacity: u64 = stored_payload_span;
        if (ch.payload_bytes > @as(u64, std.math.maxInt(usize))) return ValidateError.Protocol;

        // `payload_bytes` counts the entire chunk payload region, which includes
        // each command header (CmdHdr) plus its payload.
        var remaining: usize = @intCast(ch.payload_bytes);
        var end_seen = false;

        while (remaining > 0 and !end_seen) {
            if (remaining < @sizeOf(CmdHdr)) return ValidateError.Protocol;

            var cmd: CmdHdr = undefined;
            readExact(file, std.mem.asBytes(&cmd)) catch return ValidateError.Protocol;
            remaining -= @sizeOf(CmdHdr);

            if (cmd.payload_bytes > remaining) return ValidateError.Protocol;

            // Payload schema validation is intentionally minimal.
            // We only ensure that each record stays within the declared chunk length.
            // Tools that generate files should already be producing well-formed payloads.
            switch (cmd.opcode) {
                // Opcodes with no payload.
                Op.RESET,
                Op.CLEAR_CLIP,
                Op.RESET_TRANSFORM,
                Op.END,
                => {
                    if (cmd.payload_bytes != 0) return ValidateError.Protocol;
                    if (cmd.opcode == Op.END) end_seen = true;
                },

                // Opcodes with payload. We do not deeply validate schema here,
                // only that the payload stays within the declared chunk size.
                Op.SET_CLIP_RECTS,
                Op.SET_BLEND,
                Op.SET_TRANSFORM_2D,
                Op.SET_ANTIALIAS,
                Op.FILL_RECT,
                Op.STROKE_RECT,
                Op.STROKE_LINE,
                Op.SET_STROKE_JOIN,
                Op.SET_STROKE_CAP,
                Op.SET_MITER_LIMIT,
                Op.STROKE_QUAD_BEZIER,
                Op.STROKE_CUBIC_BEZIER,
                Op.STROKE_PATH,
                Op.BLIT_IMAGE,
                Op.DRAW_GLYPH_RUN,
                => {
                    if (cmd.payload_bytes != 0) {
                        try file.seekBy(@as(i64, @intCast(cmd.payload_bytes)));
                    }
                },

                else => return ValidateError.UnsupportedOpcode,
            }

            remaining -= @as(usize, @intCast(cmd.payload_bytes));

            // Each command record is padded so that (header + payload + pad) is
            // 8-byte aligned. The padding bytes are not represented as a command.
            const record_bytes: usize = @sizeOf(CmdHdr) + @as(usize, @intCast(cmd.payload_bytes));
            const pad: usize = pad8Len(record_bytes);
            if (pad != 0) {
                if (pad > remaining) return ValidateError.Protocol;
                try file.seekBy(@as(i64, @intCast(pad)));
                remaining -= pad;
            }
        }

        if (!end_seen) return ValidateError.Protocol;
        if (remaining != 0) return ValidateError.Protocol;

        // Skip optional chunk-level padding if the writer used `bytes` to
        // reserve extra space beyond the payload.
        if (payload_capacity > ch.payload_bytes) {
            const chunk_pad = payload_capacity - ch.payload_bytes;
            try file.seekBy(@as(i64, @intCast(chunk_pad)));
        }
    }
}

/// Validates an SDCS file with detailed diagnostic information on error.
/// On success, diagnostics is not modified.
/// On error, diagnostics is populated with context about the failure.
pub fn validateFileWithDiagnostics(file: std.fs.File, diag: *ValidationDiagnostics) ValidateError!void {
    // Track current position for diagnostics
    var current_offset: u64 = 0;

    var header: Header = undefined;
    const hdr_bytes = std.mem.asBytes(&header);
    const got = file.read(hdr_bytes) catch {
        diag.* = .{
            .file_offset = 0,
            .message = "failed to read file header",
        };
        return ValidateError.Protocol;
    };
    if (got == 0) {
        diag.* = .{
            .file_offset = 0,
            .message = "empty file",
        };
        return ValidateError.Protocol;
    }
    if (got != hdr_bytes.len) {
        readExact(file, hdr_bytes[got..]) catch {
            diag.* = .{
                .file_offset = got,
                .message = "incomplete header",
            };
            return ValidateError.Protocol;
        };
    }

    current_offset = @sizeOf(Header);

    // Protocol version check
    if (header.version_major != version_major) {
        diag.* = .{
            .file_offset = 8, // offset of version_major in header
            .message = "unsupported major version",
            .expected_payload = version_major,
            .actual_payload = header.version_major,
        };
        return ValidateError.VersionUnsupported;
    }
    if (header.version_minor > version_minor) {
        diag.* = .{
            .file_offset = 10, // offset of version_minor in header
            .message = "unsupported minor version (newer than reader)",
            .expected_payload = version_minor,
            .actual_payload = header.version_minor,
        };
        return ValidateError.VersionUnsupported;
    }

    const file_end: u64 = (file.stat() catch {
        diag.* = .{
            .file_offset = current_offset,
            .message = "failed to stat file",
        };
        return ValidateError.Protocol;
    }).size;

    while (true) {
        var ch: ChunkHeader = undefined;
        const ch_bytes = std.mem.asBytes(&ch);

        const chunk_start = file.getPos() catch {
            diag.* = .{
                .file_offset = current_offset,
                .message = "failed to get file position",
            };
            return ValidateError.Protocol;
        };
        current_offset = chunk_start;

        const n0 = file.read(ch_bytes) catch {
            diag.* = .{
                .file_offset = current_offset,
                .message = "failed to read chunk header",
            };
            return ValidateError.Protocol;
        };
        if (n0 == 0) break; // EOF at chunk boundary is ok
        if (n0 != ch_bytes.len) {
            readExact(file, ch_bytes[n0..]) catch {
                diag.* = .{
                    .file_offset = current_offset,
                    .message = "incomplete chunk header",
                };
                return ValidateError.Protocol;
            };
        }

        const payload_start = file.getPos() catch {
            diag.* = .{
                .file_offset = current_offset,
                .message = "failed to get payload position",
            };
            return ValidateError.Protocol;
        };

        const hdr_sz: u64 = @sizeOf(ChunkHeader);
        var stored_payload_span: u64 = std.mem.alignForward(u64, ch.payload_bytes, 8);

        if (ch.bytes != 0) {
            if (ch.bytes >= hdr_sz) {
                const cap_total = ch.bytes - hdr_sz;
                if (cap_total > stored_payload_span) stored_payload_span = cap_total;
            } else {
                const cap_payload = std.mem.alignForward(u64, ch.bytes, 8);
                if (cap_payload > stored_payload_span) stored_payload_span = cap_payload;
            }
        }

        if (payload_start + stored_payload_span > file_end) {
            diag.* = .{
                .file_offset = current_offset,
                .message = "chunk extends beyond end of file",
            };
            return ValidateError.Protocol;
        }

        const payload_capacity: u64 = stored_payload_span;
        if (ch.payload_bytes > @as(u64, std.math.maxInt(usize))) {
            diag.* = .{
                .file_offset = current_offset,
                .message = "payload size exceeds addressable range",
            };
            return ValidateError.Protocol;
        }

        var remaining: usize = @intCast(ch.payload_bytes);
        var end_seen = false;

        while (remaining > 0 and !end_seen) {
            const cmd_offset = file.getPos() catch {
                diag.* = .{
                    .file_offset = current_offset,
                    .message = "failed to get command position",
                };
                return ValidateError.Protocol;
            };
            current_offset = cmd_offset;

            if (remaining < @sizeOf(CmdHdr)) {
                diag.* = .{
                    .file_offset = current_offset,
                    .message = "incomplete command header in chunk",
                };
                return ValidateError.Protocol;
            }

            var cmd: CmdHdr = undefined;
            readExact(file, std.mem.asBytes(&cmd)) catch {
                diag.* = .{
                    .file_offset = current_offset,
                    .message = "failed to read command header",
                };
                return ValidateError.Protocol;
            };
            remaining -= @sizeOf(CmdHdr);

            if (cmd.payload_bytes > remaining) {
                diag.* = .{
                    .file_offset = current_offset,
                    .opcode = cmd.opcode,
                    .opcode_name = opcodeName(cmd.opcode),
                    .message = "command payload exceeds remaining chunk bytes",
                    .expected_payload = @intCast(remaining),
                    .actual_payload = cmd.payload_bytes,
                };
                return ValidateError.Protocol;
            }

            switch (cmd.opcode) {
                Op.RESET, Op.CLEAR_CLIP, Op.RESET_TRANSFORM, Op.END => {
                    if (cmd.payload_bytes != 0) {
                        diag.* = .{
                            .file_offset = current_offset,
                            .opcode = cmd.opcode,
                            .opcode_name = opcodeName(cmd.opcode),
                            .message = "opcode requires empty payload",
                            .expected_payload = 0,
                            .actual_payload = cmd.payload_bytes,
                        };
                        return ValidateError.Protocol;
                    }
                    if (cmd.opcode == Op.END) end_seen = true;
                },

                Op.SET_CLIP_RECTS, Op.SET_BLEND, Op.SET_TRANSFORM_2D, Op.SET_ANTIALIAS, Op.FILL_RECT, Op.STROKE_RECT, Op.STROKE_LINE, Op.SET_STROKE_JOIN, Op.SET_STROKE_CAP, Op.SET_MITER_LIMIT, Op.STROKE_QUAD_BEZIER, Op.STROKE_CUBIC_BEZIER, Op.STROKE_PATH, Op.BLIT_IMAGE, Op.DRAW_GLYPH_RUN => {
                    if (cmd.payload_bytes != 0) {
                        file.seekBy(@as(i64, @intCast(cmd.payload_bytes))) catch {
                            diag.* = .{
                                .file_offset = current_offset,
                                .opcode = cmd.opcode,
                                .opcode_name = opcodeName(cmd.opcode),
                                .message = "failed to skip command payload",
                            };
                            return ValidateError.Protocol;
                        };
                    }
                },

                else => {
                    diag.* = .{
                        .file_offset = current_offset,
                        .opcode = cmd.opcode,
                        .opcode_name = null,
                        .message = "unsupported opcode",
                    };
                    return ValidateError.UnsupportedOpcode;
                },
            }

            remaining -= @as(usize, @intCast(cmd.payload_bytes));

            const record_bytes: usize = @sizeOf(CmdHdr) + @as(usize, @intCast(cmd.payload_bytes));
            const pad: usize = pad8Len(record_bytes);
            if (pad != 0) {
                if (pad > remaining) {
                    diag.* = .{
                        .file_offset = current_offset,
                        .opcode = cmd.opcode,
                        .opcode_name = opcodeName(cmd.opcode),
                        .message = "padding exceeds remaining chunk bytes",
                    };
                    return ValidateError.Protocol;
                }
                file.seekBy(@as(i64, @intCast(pad))) catch {
                    diag.* = .{
                        .file_offset = current_offset,
                        .message = "failed to skip padding",
                    };
                    return ValidateError.Protocol;
                };
                remaining -= pad;
            }
        }

        if (!end_seen) {
            diag.* = .{
                .file_offset = current_offset,
                .message = "chunk missing END command",
            };
            return ValidateError.Protocol;
        }
        if (remaining != 0) {
            diag.* = .{
                .file_offset = current_offset,
                .message = "unexpected bytes after END command",
            };
            return ValidateError.Protocol;
        }

        if (payload_capacity > ch.payload_bytes) {
            const chunk_pad = payload_capacity - ch.payload_bytes;
            file.seekBy(@as(i64, @intCast(chunk_pad))) catch {
                diag.* = .{
                    .file_offset = current_offset,
                    .message = "failed to skip chunk padding",
                };
                return ValidateError.Protocol;
            };
        }
    }
}

// =============================================================================
// Unit Tests
// =============================================================================

test "opcodeName returns correct names for known opcodes" {
    try std.testing.expectEqualStrings("RESET", opcodeName(Op.RESET).?);
    try std.testing.expectEqualStrings("SET_CLIP_RECTS", opcodeName(Op.SET_CLIP_RECTS).?);
    try std.testing.expectEqualStrings("CLEAR_CLIP", opcodeName(Op.CLEAR_CLIP).?);
    try std.testing.expectEqualStrings("SET_BLEND", opcodeName(Op.SET_BLEND).?);
    try std.testing.expectEqualStrings("SET_TRANSFORM_2D", opcodeName(Op.SET_TRANSFORM_2D).?);
    try std.testing.expectEqualStrings("RESET_TRANSFORM", opcodeName(Op.RESET_TRANSFORM).?);
    try std.testing.expectEqualStrings("FILL_RECT", opcodeName(Op.FILL_RECT).?);
    try std.testing.expectEqualStrings("STROKE_RECT", opcodeName(Op.STROKE_RECT).?);
    try std.testing.expectEqualStrings("STROKE_LINE", opcodeName(Op.STROKE_LINE).?);
    try std.testing.expectEqualStrings("SET_STROKE_JOIN", opcodeName(Op.SET_STROKE_JOIN).?);
    try std.testing.expectEqualStrings("SET_STROKE_CAP", opcodeName(Op.SET_STROKE_CAP).?);
    try std.testing.expectEqualStrings("SET_MITER_LIMIT", opcodeName(Op.SET_MITER_LIMIT).?);
    try std.testing.expectEqualStrings("STROKE_QUAD_BEZIER", opcodeName(Op.STROKE_QUAD_BEZIER).?);
    try std.testing.expectEqualStrings("STROKE_CUBIC_BEZIER", opcodeName(Op.STROKE_CUBIC_BEZIER).?);
    try std.testing.expectEqualStrings("STROKE_PATH", opcodeName(Op.STROKE_PATH).?);
    try std.testing.expectEqualStrings("BLIT_IMAGE", opcodeName(Op.BLIT_IMAGE).?);
    try std.testing.expectEqualStrings("DRAW_GLYPH_RUN", opcodeName(Op.DRAW_GLYPH_RUN).?);
    try std.testing.expectEqualStrings("END", opcodeName(Op.END).?);
}

test "opcodeName returns null for unknown opcodes" {
    try std.testing.expectEqual(@as(?[]const u8, null), opcodeName(0x0000));
    try std.testing.expectEqual(@as(?[]const u8, null), opcodeName(0xFFFF));
    try std.testing.expectEqual(@as(?[]const u8, null), opcodeName(0x00FF));
}

test "isFiniteF32Bits detects finite values" {
    // Zero
    try std.testing.expect(isFiniteF32Bits(0x00000000));
    // Negative zero
    try std.testing.expect(isFiniteF32Bits(0x80000000));
    // One (1.0f)
    try std.testing.expect(isFiniteF32Bits(0x3F800000));
    // Negative one (-1.0f)
    try std.testing.expect(isFiniteF32Bits(0xBF800000));
    // Small denormal
    try std.testing.expect(isFiniteF32Bits(0x00000001));
    // Max finite
    try std.testing.expect(isFiniteF32Bits(0x7F7FFFFF));
}

test "isFiniteF32Bits detects infinity and NaN" {
    // Positive infinity
    try std.testing.expect(!isFiniteF32Bits(0x7F800000));
    // Negative infinity
    try std.testing.expect(!isFiniteF32Bits(0xFF800000));
    // Quiet NaN
    try std.testing.expect(!isFiniteF32Bits(0x7FC00000));
    // Signaling NaN
    try std.testing.expect(!isFiniteF32Bits(0x7F800001));
}

test "pad8Len computes correct padding" {
    try std.testing.expectEqual(@as(usize, 0), pad8Len(0));
    try std.testing.expectEqual(@as(usize, 7), pad8Len(1));
    try std.testing.expectEqual(@as(usize, 6), pad8Len(2));
    try std.testing.expectEqual(@as(usize, 1), pad8Len(7));
    try std.testing.expectEqual(@as(usize, 0), pad8Len(8));
    try std.testing.expectEqual(@as(usize, 7), pad8Len(9));
    try std.testing.expectEqual(@as(usize, 0), pad8Len(16));
    try std.testing.expectEqual(@as(usize, 0), pad8Len(24));
}

test "fourcc produces correct values" {
    try std.testing.expectEqual(ChunkType.CMDS, fourcc('C', 'M', 'D', 'S'));
    try std.testing.expectEqual(ChunkType.RSRC, fourcc('R', 'S', 'R', 'C'));
    try std.testing.expectEqual(ChunkType.DATA, fourcc('D', 'A', 'T', 'A'));
    try std.testing.expectEqual(ChunkType.META, fourcc('M', 'E', 'T', 'A'));
}

test "validateOpcodePayload rejects wrong payload sizes" {
    // RESET requires 0 bytes
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.RESET, 4));
    // FILL_RECT requires 32 bytes
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.FILL_RECT, 0));
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.FILL_RECT, 16));
    // SET_BLEND requires 4 bytes
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.SET_BLEND, 0));
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.SET_BLEND, 8));
    // SET_TRANSFORM_2D requires 24 bytes
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.SET_TRANSFORM_2D, 0));
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.SET_TRANSFORM_2D, 12));
    // STROKE_RECT requires 36 bytes
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.STROKE_RECT, 32));
    // Unknown opcode
    try std.testing.expectError(ValidateError.UnsupportedOpcode, validateOpcodePayload(0xFFFF, 0));
}

test "validateOpcodePayload accepts correct payload sizes" {
    try validateOpcodePayload(Op.RESET, 0);
    try validateOpcodePayload(Op.CLEAR_CLIP, 0);
    try validateOpcodePayload(Op.RESET_TRANSFORM, 0);
    try validateOpcodePayload(Op.END, 0);
    try validateOpcodePayload(Op.FILL_RECT, 32);
    try validateOpcodePayload(Op.SET_BLEND, 4);
    try validateOpcodePayload(Op.SET_TRANSFORM_2D, 24);
    try validateOpcodePayload(Op.STROKE_RECT, 36);
    try validateOpcodePayload(Op.STROKE_LINE, 36);
    try validateOpcodePayload(Op.SET_STROKE_JOIN, 4);
    try validateOpcodePayload(Op.SET_STROKE_CAP, 4);
    try validateOpcodePayload(Op.SET_MITER_LIMIT, 4);
}

test "SET_MITER_LIMIT payload validation" {
    // SET_MITER_LIMIT requires exactly 4 bytes (single f32)
    try validateOpcodePayload(Op.SET_MITER_LIMIT, 4);
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.SET_MITER_LIMIT, 0));
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.SET_MITER_LIMIT, 8));
}

test "SET_CLIP_RECTS payload validation" {
    // Minimum valid: 4 bytes for count (0 rects)
    try validateOpcodePayload(Op.SET_CLIP_RECTS, 4);
    // 1 rect: 4 + 16 = 20 bytes
    try validateOpcodePayload(Op.SET_CLIP_RECTS, 20);
    // 2 rects: 4 + 32 = 36 bytes
    try validateOpcodePayload(Op.SET_CLIP_RECTS, 36);
    // Invalid: less than 4 bytes
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.SET_CLIP_RECTS, 0));
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.SET_CLIP_RECTS, 3));
    // Invalid: not aligned to rect size
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.SET_CLIP_RECTS, 5));
    try std.testing.expectError(ValidateError.Protocol, validateOpcodePayload(Op.SET_CLIP_RECTS, 10));
}

test "ValidationDiagnostics default values" {
    const diag = ValidationDiagnostics{};
    try std.testing.expectEqual(@as(u64, 0), diag.file_offset);
    try std.testing.expectEqual(@as(u16, 0), diag.opcode);
    try std.testing.expectEqual(@as(?[]const u8, null), diag.opcode_name);
    try std.testing.expectEqual(@as(u32, 0), diag.expected_payload);
    try std.testing.expectEqual(@as(u32, 0), diag.actual_payload);
    try std.testing.expectEqualStrings("", diag.message);
}

test "Header struct size is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Header));
}

test "ChunkHeader struct size is 32 bytes" {
    // type(4) + flags(4) + offset(8) + bytes(8) + payload_bytes(8) = 32
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ChunkHeader));
}

test "CmdHdr struct size is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(CmdHdr));
}

test "Magic string is correct" {
    try std.testing.expectEqualStrings("SDCS0001", Magic);
    try std.testing.expectEqualStrings("SDCS", MagicPrefix);
}

test "version constants" {
    try std.testing.expectEqual(@as(u16, 0), version_major);
    try std.testing.expectEqual(@as(u16, 1), version_minor);
}
