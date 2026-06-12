const std = @import("std");
const sdcs = @import("sdcs");

/// SDCS validation for memory buffers (used by daemon for shm data)
pub const SdcsValidator = struct {
    /// Validate SDCS stream from a memory buffer
    pub fn validateBuffer(data: []const u8) ValidationResult {
        if (data.len < @sizeOf(sdcs.Header)) {
            return .{ .valid = false, .error_msg = "buffer too small for header" };
        }

        // Check header
        const header = std.mem.bytesAsValue(sdcs.Header, data[0..@sizeOf(sdcs.Header)]);

        // Magic prefix check
        if (!std.mem.startsWith(u8, &header.magic, sdcs.MagicPrefix)) {
            return .{ .valid = false, .error_msg = "invalid magic" };
        }

        // Version check
        if (header.version_major != sdcs.version_major) {
            return .{ .valid = false, .error_msg = "unsupported major version" };
        }
        if (header.version_minor > sdcs.version_minor) {
            return .{ .valid = false, .error_msg = "unsupported minor version" };
        }

        // Validate chunks
        var offset: usize = @sizeOf(sdcs.Header);
        while (offset < data.len) {
            // Need at least chunk header
            if (offset + @sizeOf(sdcs.ChunkHeader) > data.len) {
                return .{ .valid = false, .error_msg = "truncated chunk header", .offset = offset };
            }

            const chunk = std.mem.bytesAsValue(sdcs.ChunkHeader, data[offset..][0..@sizeOf(sdcs.ChunkHeader)]);
            offset += @sizeOf(sdcs.ChunkHeader);

            // Validate payload fits
            const payload_len: usize = @intCast(chunk.payload_bytes);
            if (offset + payload_len > data.len) {
                return .{ .valid = false, .error_msg = "chunk payload exceeds buffer", .offset = offset };
            }

            // Validate commands in this chunk
            const result = validateCommands(data[offset..][0..payload_len]);
            if (!result.valid) {
                return .{ .valid = false, .error_msg = result.error_msg, .offset = offset + result.offset };
            }

            // Move to next chunk (with padding)
            offset += std.mem.alignForward(usize, payload_len, 8);
        }

        return .{ .valid = true };
    }

    /// Validate command stream within a chunk
    fn validateCommands(payload: []const u8) ValidationResult {
        var offset: usize = 0;
        var end_seen = false;

        while (offset < payload.len and !end_seen) {
            if (offset + @sizeOf(sdcs.CmdHdr) > payload.len) {
                return .{ .valid = false, .error_msg = "truncated command header", .offset = offset };
            }

            const cmd = std.mem.bytesAsValue(sdcs.CmdHdr, payload[offset..][0..@sizeOf(sdcs.CmdHdr)]);
            offset += @sizeOf(sdcs.CmdHdr);

            const cmd_payload_len: usize = @intCast(cmd.payload_bytes);
            if (offset + cmd_payload_len > payload.len) {
                return .{ .valid = false, .error_msg = "command payload exceeds chunk", .offset = offset };
            }

            // Validate opcode is known
            if (sdcs.opcodeName(cmd.opcode) == null) {
                return .{ .valid = false, .error_msg = "unknown opcode", .offset = offset };
            }

            // Check END
            if (cmd.opcode == sdcs.Op.END) {
                end_seen = true;
            }

            // Skip payload and padding
            offset += cmd_payload_len;
            const record_bytes = @sizeOf(sdcs.CmdHdr) + cmd_payload_len;
            offset += sdcs.pad8Len(record_bytes);
        }

        if (!end_seen) {
            return .{ .valid = false, .error_msg = "missing END command" };
        }

        return .{ .valid = true };
    }

    /// Estimate resource requirements for rendering
    pub fn estimateResources(data: []const u8) ResourceEstimate {
        var estimate = ResourceEstimate{};

        if (data.len < @sizeOf(sdcs.Header)) {
            return estimate;
        }

        // Count commands and estimate complexity
        var offset: usize = @sizeOf(sdcs.Header);
        while (offset + @sizeOf(sdcs.ChunkHeader) <= data.len) {
            const chunk = std.mem.bytesAsValue(sdcs.ChunkHeader, data[offset..][0..@sizeOf(sdcs.ChunkHeader)]);
            offset += @sizeOf(sdcs.ChunkHeader);

            const payload_len: usize = @intCast(chunk.payload_bytes);
            if (offset + payload_len > data.len) break;

            // Count commands in chunk
            var cmd_offset: usize = 0;
            while (cmd_offset + @sizeOf(sdcs.CmdHdr) <= payload_len) {
                const cmd = std.mem.bytesAsValue(sdcs.CmdHdr, data[offset + cmd_offset ..][0..@sizeOf(sdcs.CmdHdr)]);
                estimate.command_count += 1;

                // Estimate based on command type
                switch (cmd.opcode) {
                    sdcs.Op.FILL_RECT, sdcs.Op.STROKE_RECT => {
                        estimate.draw_calls += 1;
                    },
                    sdcs.Op.STROKE_LINE => {
                        estimate.draw_calls += 1;
                    },
                    sdcs.Op.STROKE_PATH => {
                        estimate.draw_calls += 1;
                        estimate.path_complexity += cmd.payload_bytes / 8; // rough vertex count
                    },
                    sdcs.Op.BLIT_IMAGE => {
                        estimate.draw_calls += 1;
                        estimate.texture_ops += 1;
                    },
                    sdcs.Op.DRAW_GLYPH_RUN => {
                        estimate.draw_calls += 1;
                        estimate.glyph_count += cmd.payload_bytes / 16; // rough glyph count
                    },
                    sdcs.Op.END => break,
                    else => {},
                }

                cmd_offset += @sizeOf(sdcs.CmdHdr) + cmd.payload_bytes;
                cmd_offset += sdcs.pad8Len(@sizeOf(sdcs.CmdHdr) + cmd.payload_bytes);
            }

            offset += std.mem.alignForward(usize, payload_len, 8);
        }

        return estimate;
    }
};

/// Validation result
pub const ValidationResult = struct {
    valid: bool,
    error_msg: []const u8 = "",
    offset: usize = 0,
};

/// Resource estimate for render planning
pub const ResourceEstimate = struct {
    command_count: u32 = 0,
    draw_calls: u32 = 0,
    path_complexity: u32 = 0,
    texture_ops: u32 = 0,
    glyph_count: u32 = 0,
};

// ============================================================================
// Tests
// ============================================================================

test "SdcsValidator rejects empty buffer" {
    const result = SdcsValidator.validateBuffer(&[_]u8{});
    try std.testing.expect(!result.valid);
}

test "SdcsValidator rejects truncated header" {
    const data = [_]u8{ 'S', 'D', 'C', 'S' }; // Only 4 bytes, need 64
    const result = SdcsValidator.validateBuffer(&data);
    try std.testing.expect(!result.valid);
}
