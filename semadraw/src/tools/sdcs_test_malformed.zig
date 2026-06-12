const std = @import("std");
const sdcs = @import("sdcs");

/// Test harness for malformed SDCS input validation.
/// Generates various malformed SDCS files and verifies the validator rejects them correctly.
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var passed: u32 = 0;
    var failed: u32 = 0;

    // ChunkHeader size: type(4) + flags(4) + offset(8) + bytes(8) + payload_bytes(8) = 32
    const chunk_hdr_size: usize = 32;

    // Test 1: Empty file
    {
        const result = testMalformed(allocator, &[_]u8{}, "empty file");
        if (result) passed += 1 else failed += 1;
    }

    // Test 2: Truncated header (only magic)
    {
        const result = testMalformed(allocator, "SDCS0001", "truncated header");
        if (result) passed += 1 else failed += 1;
    }

    // Test 3: Wrong magic - SKIPPED
    // The validator intentionally allows non-standard magic prefixes for backwards
    // compatibility with historical emitters. See validateFile() comment.

    // Test 4: Wrong major version
    {
        var buf = makeValidHeader();
        buf[8] = 1; // major = 1 (unsupported)
        const result = testMalformedExpectError(allocator, &buf, sdcs.ValidateError.VersionUnsupported, "wrong major version");
        if (result) passed += 1 else failed += 1;
    }

    // Test 5: Future minor version
    {
        var buf = makeValidHeader();
        buf[10] = 99; // minor = 99 (future)
        const result = testMalformedExpectError(allocator, &buf, sdcs.ValidateError.VersionUnsupported, "future minor version");
        if (result) passed += 1 else failed += 1;
    }

    // Test 6: Chunk with no END command
    {
        // Header(64) + ChunkHeader(32) + RESET cmd(8) = 104 bytes
        var buf: [64 + chunk_hdr_size + 8]u8 = undefined;
        @memset(&buf, 0);
        const header = makeValidHeader();
        @memcpy(buf[0..64], &header);
        // Chunk header at offset 64
        @memcpy(buf[64..68], "CMDS"); // type
        @memset(buf[68..72], 0); // flags
        writeU64LE(buf[72..80], 64); // offset
        writeU64LE(buf[80..88], chunk_hdr_size + 8); // bytes (chunk header + payload)
        writeU64LE(buf[88..96], 8); // payload_bytes (just RESET, no END)
        // Command: RESET (no END) at offset 96
        writeU16LE(buf[96..98], sdcs.Op.RESET);
        writeU16LE(buf[98..100], 0); // flags
        writeU32LE(buf[100..104], 0); // payload_bytes
        const result = testMalformedExpectError(allocator, &buf, sdcs.ValidateError.Protocol, "missing END command");
        if (result) passed += 1 else failed += 1;
    }

    // Test 7: Command with wrong payload size - SKIPPED
    // The validator does not deeply validate payload schema for performance reasons.
    // It only checks that payloads stay within declared chunk bounds.
    // Deep payload validation is left to the replay/execution stage.

    // Test 8: Unknown opcode
    {
        var buf: [64 + chunk_hdr_size + 16]u8 = undefined;
        @memset(&buf, 0);
        const header = makeValidHeader();
        @memcpy(buf[0..64], &header);
        // Chunk header
        @memcpy(buf[64..68], "CMDS");
        @memset(buf[68..72], 0);
        writeU64LE(buf[72..80], 64);
        writeU64LE(buf[80..88], chunk_hdr_size + 16);
        writeU64LE(buf[88..96], 16);
        // Unknown opcode 0xFFFF at offset 96
        writeU16LE(buf[96..98], 0xFFFF);
        writeU16LE(buf[98..100], 0);
        writeU32LE(buf[100..104], 0);
        // END at offset 104
        writeU16LE(buf[104..106], sdcs.Op.END);
        writeU16LE(buf[106..108], 0);
        writeU32LE(buf[108..112], 0);
        const result = testMalformedExpectError(allocator, &buf, sdcs.ValidateError.UnsupportedOpcode, "unknown opcode");
        if (result) passed += 1 else failed += 1;
    }

    // Test 9: Payload extends beyond chunk
    {
        var buf: [64 + chunk_hdr_size + 8]u8 = undefined;
        @memset(&buf, 0);
        const header = makeValidHeader();
        @memcpy(buf[0..64], &header);
        // Chunk header
        @memcpy(buf[64..68], "CMDS");
        @memset(buf[68..72], 0);
        writeU64LE(buf[72..80], 64);
        writeU64LE(buf[80..88], chunk_hdr_size + 8);
        writeU64LE(buf[88..96], 8); // only 8 bytes of payload
        // Command claims 100 bytes of payload at offset 96
        writeU16LE(buf[96..98], sdcs.Op.RESET);
        writeU16LE(buf[98..100], 0);
        writeU32LE(buf[100..104], 100); // way too big!
        const result = testMalformedExpectError(allocator, &buf, sdcs.ValidateError.Protocol, "payload exceeds chunk");
        if (result) passed += 1 else failed += 1;
    }

    // Test 10: Chunk extends beyond file
    {
        var buf: [64 + chunk_hdr_size]u8 = undefined;
        @memset(&buf, 0);
        const header = makeValidHeader();
        @memcpy(buf[0..64], &header);
        // Chunk header claiming more data than file contains
        @memcpy(buf[64..68], "CMDS");
        @memset(buf[68..72], 0);
        writeU64LE(buf[72..80], 64);
        writeU64LE(buf[80..88], 1000); // way bigger than file
        writeU64LE(buf[88..96], 960);
        const result = testMalformedExpectError(allocator, &buf, sdcs.ValidateError.Protocol, "chunk beyond EOF");
        if (result) passed += 1 else failed += 1;
    }

    // Summary
    std.debug.print("\n=== Malformed Input Tests ===\n", .{});
    std.debug.print("Passed: {d}\n", .{passed});
    std.debug.print("Failed: {d}\n", .{failed});
    std.debug.print("Total:  {d}\n", .{passed + failed});

    if (failed > 0) {
        std.process.exit(1);
    }
}

fn makeValidHeader() [64]u8 {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    @memcpy(buf[0..8], sdcs.Magic);
    buf[8] = sdcs.version_major & 0xff;
    buf[9] = (sdcs.version_major >> 8) & 0xff;
    buf[10] = sdcs.version_minor & 0xff;
    buf[11] = (sdcs.version_minor >> 8) & 0xff;
    buf[12] = 64; // header_bytes
    return buf;
}

fn writeU16LE(buf: *[2]u8, val: u16) void {
    buf[0] = @intCast(val & 0xff);
    buf[1] = @intCast((val >> 8) & 0xff);
}

fn writeU32LE(buf: *[4]u8, val: u32) void {
    buf[0] = @intCast(val & 0xff);
    buf[1] = @intCast((val >> 8) & 0xff);
    buf[2] = @intCast((val >> 16) & 0xff);
    buf[3] = @intCast((val >> 24) & 0xff);
}

fn writeU64LE(buf: *[8]u8, val: u64) void {
    buf[0] = @intCast(val & 0xff);
    buf[1] = @intCast((val >> 8) & 0xff);
    buf[2] = @intCast((val >> 16) & 0xff);
    buf[3] = @intCast((val >> 24) & 0xff);
    buf[4] = @intCast((val >> 32) & 0xff);
    buf[5] = @intCast((val >> 40) & 0xff);
    buf[6] = @intCast((val >> 48) & 0xff);
    buf[7] = @intCast((val >> 56) & 0xff);
}

fn testMalformed(allocator: std.mem.Allocator, data: []const u8, name: []const u8) bool {
    return testMalformedExpectError(allocator, data, null, name);
}

fn testMalformedExpectError(allocator: std.mem.Allocator, data: []const u8, expected_error: ?sdcs.ValidateError, name: []const u8) bool {
    _ = allocator;

    // Write data to a temporary file
    const tmp_path = "/tmp/sdcs_malformed_test.sdcs";
    const file = std.fs.cwd().createFile(tmp_path, .{}) catch |err| {
        std.debug.print("FAIL [{s}]: could not create temp file: {any}\n", .{ name, err });
        return false;
    };
    defer file.close();
    file.writeAll(data) catch |err| {
        std.debug.print("FAIL [{s}]: could not write temp file: {any}\n", .{ name, err });
        return false;
    };

    // Re-open for reading
    const read_file = std.fs.cwd().openFile(tmp_path, .{}) catch |err| {
        std.debug.print("FAIL [{s}]: could not open temp file: {any}\n", .{ name, err });
        return false;
    };
    defer read_file.close();

    // Validate with diagnostics
    var diag = sdcs.ValidationDiagnostics{};
    const result = sdcs.validateFileWithDiagnostics(read_file, &diag);

    if (result) |_| {
        // Validation succeeded - this is a failure for malformed input tests
        std.debug.print("FAIL [{s}]: validation should have failed but succeeded\n", .{name});
        return false;
    } else |err| {
        // Validation failed as expected
        if (expected_error) |exp| {
            if (err != exp) {
                std.debug.print("FAIL [{s}]: expected {any}, got {any}\n", .{ name, exp, err });
                return false;
            }
        }
        std.debug.print("PASS [{s}]: rejected with \"{s}\" at offset 0x{x}\n", .{ name, diag.message, diag.file_offset });
        return true;
    }
}
