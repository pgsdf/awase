const std = @import("std");
const sdcs = @import("sdcs");

/// Fuzzing entry point for SDCS validator.
///
/// This module provides a fuzzing harness compatible with AFL, libFuzzer, and
/// Zig's built-in fuzzing infrastructure. The goal is to find crashes, hangs,
/// or unexpected behavior when processing malformed SDCS input.
///
/// Usage with AFL:
///   1. Build with: zig build -Doptimize=ReleaseSafe
///   2. Run: afl-fuzz -i corpus/ -o findings/ ./zig-out/bin/sdcs_fuzz @@
///
/// Usage with libFuzzer (if available):
///   Build with appropriate flags and link libFuzzer.
///
/// Usage standalone:
///   ./sdcs_fuzz <input_file>
///   Exits 0 on valid input, 1 on validation error, 2 on crash/panic.

pub fn main() !void {
    const args = std.process.argsAlloc(std.heap.page_allocator) catch {
        return;
    };
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <input_file>\n", .{args[0]});
        std.debug.print("\nFuzzing harness for SDCS validator.\n", .{});
        std.debug.print("Processes input file and reports validation status.\n", .{});
        std.process.exit(2);
    }

    const input_path = args[1];

    // Open the input file
    const file = std.fs.cwd().openFile(input_path, .{}) catch |err| {
        // File errors are not crashes, just exit cleanly
        std.debug.print("Could not open file: {any}\n", .{err});
        std.process.exit(1);
    };
    defer file.close();

    // Run validation with diagnostics
    var diag = sdcs.ValidationDiagnostics{};
    const result = sdcs.validateFileWithDiagnostics(file, &diag);

    if (result) |_| {
        // Valid input
        std.process.exit(0);
    } else |_| {
        // Invalid input - this is expected for fuzzing
        std.process.exit(1);
    }
}

/// libFuzzer-compatible entry point.
/// This function is called by libFuzzer with random data.
export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) c_int {
    if (size == 0) return 0;

    const slice = data[0..size];

    // Write to a memory-backed pseudo-file would be ideal, but for now
    // we use a temp file approach (slower but works)
    const tmp_path = "/tmp/sdcs_fuzz_input.sdcs";

    const file = std.fs.cwd().createFile(tmp_path, .{}) catch {
        return 0;
    };
    file.writeAll(slice) catch {
        file.close();
        return 0;
    };
    file.close();

    const read_file = std.fs.cwd().openFile(tmp_path, .{}) catch {
        return 0;
    };
    defer read_file.close();

    var diag = sdcs.ValidationDiagnostics{};
    sdcs.validateFileWithDiagnostics(read_file, &diag) catch {};

    return 0;
}

/// Corpus generation: create a set of valid and edge-case SDCS files.
pub fn generateCorpus(output_dir: []const u8) !void {
    // Create output directory
    std.fs.cwd().makeDir(output_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Generate minimal valid file
    try generateMinimalValid(output_dir);
    std.debug.print("Generated: {s}/minimal_valid.sdcs\n", .{output_dir});

    // Generate file with all opcodes
    try generateAllOpcodes(output_dir);
    std.debug.print("Generated: {s}/all_opcodes.sdcs\n", .{output_dir});

    // Generate edge case files
    try generateEdgeCases(output_dir);
    std.debug.print("Generated edge case files\n", .{});

    std.debug.print("\nCorpus generation complete.\n", .{});
}

fn generateMinimalValid(output_dir: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/minimal_valid.sdcs", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    // ChunkHeader: type(4) + flags(4) + offset(8) + bytes(8) + payload_bytes(8) = 32 bytes
    const chunk_hdr_size: usize = 32;

    // Write header
    var header: [64]u8 = undefined;
    @memset(&header, 0);
    @memcpy(header[0..8], sdcs.Magic);
    header[8] = sdcs.version_major & 0xff;
    header[9] = (sdcs.version_major >> 8) & 0xff;
    header[10] = sdcs.version_minor & 0xff;
    header[11] = (sdcs.version_minor >> 8) & 0xff;
    header[12] = 64;
    try file.writeAll(&header);

    // Write chunk header (32 bytes)
    var chunk: [32]u8 = undefined;
    @memset(&chunk, 0);
    @memcpy(chunk[0..4], "CMDS");
    // offset = 64 (at byte 8)
    chunk[8] = 64;
    // bytes = 48 (32 header + 16 payload) at byte 16
    chunk[16] = chunk_hdr_size + 16;
    // payload_bytes = 16 (RESET + END) at byte 24
    chunk[24] = 16;
    try file.writeAll(&chunk);

    // RESET command
    var reset_cmd: [8]u8 = undefined;
    @memset(&reset_cmd, 0);
    reset_cmd[0] = sdcs.Op.RESET & 0xff;
    reset_cmd[1] = (sdcs.Op.RESET >> 8) & 0xff;
    try file.writeAll(&reset_cmd);

    // END command
    var end_cmd: [8]u8 = undefined;
    @memset(&end_cmd, 0);
    end_cmd[0] = sdcs.Op.END & 0xff;
    end_cmd[1] = (sdcs.Op.END >> 8) & 0xff;
    try file.writeAll(&end_cmd);
}

fn generateAllOpcodes(output_dir: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/all_opcodes.sdcs", .{output_dir});

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const chunk_hdr_size: usize = 32;

    // Header
    var header: [64]u8 = undefined;
    @memset(&header, 0);
    @memcpy(header[0..8], sdcs.Magic);
    header[8] = sdcs.version_major & 0xff;
    header[10] = sdcs.version_minor & 0xff;
    header[12] = 64;
    try file.writeAll(&header);

    // For simplicity, just write a minimal chunk with RESET and END
    // A full version would include all opcodes with valid payloads
    var chunk: [32]u8 = undefined;
    @memset(&chunk, 0);
    @memcpy(chunk[0..4], "CMDS");
    chunk[8] = 64;
    chunk[16] = chunk_hdr_size + 16;
    chunk[24] = 16;
    try file.writeAll(&chunk);

    var reset_cmd: [8]u8 = undefined;
    @memset(&reset_cmd, 0);
    reset_cmd[0] = sdcs.Op.RESET & 0xff;
    reset_cmd[1] = (sdcs.Op.RESET >> 8) & 0xff;
    try file.writeAll(&reset_cmd);

    var end_cmd: [8]u8 = undefined;
    @memset(&end_cmd, 0);
    end_cmd[0] = sdcs.Op.END & 0xff;
    end_cmd[1] = (sdcs.Op.END >> 8) & 0xff;
    try file.writeAll(&end_cmd);
}

fn generateEdgeCases(output_dir: []const u8) !void {
    // Empty file
    {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/empty.sdcs", .{output_dir});
        const file = try std.fs.cwd().createFile(path, .{});
        file.close();
    }

    // Just header, no chunks
    {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/header_only.sdcs", .{output_dir});
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var header: [64]u8 = undefined;
        @memset(&header, 0);
        @memcpy(header[0..8], sdcs.Magic);
        header[8] = sdcs.version_major & 0xff;
        header[10] = sdcs.version_minor & 0xff;
        header[12] = 64;
        try file.writeAll(&header);
    }

    // Truncated header
    {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/truncated_header.sdcs", .{output_dir});
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(sdcs.Magic);
    }
}
