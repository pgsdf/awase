const std = @import("std");
const posix = std.posix;
const compat = @import("compat");
const sdcs = @import("sdcs");

// Owned raw-posix open/write idioms (Zig 0.16 removed std.fs.File) for the
// fd-based sdcs validate API. Corpus generation (makeDir + createFile) is left
// on std.fs for the filesystem phase.
fn openCreateRdwr(path: []const u8, mode: posix.mode_t) !posix.fd_t {
    var path_buf = try posix.toPosixPath(path);
    const fd = posix.system.open(&path_buf, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, mode);
    if (fd < 0) return error.OpenFailed;
    return fd;
}
fn openReadOnly(path: []const u8) !posix.fd_t {
    var path_buf = try posix.toPosixPath(path);
    const fd = posix.system.open(&path_buf, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    return fd;
}
fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const chunk = bytes[off..];
        const rc = posix.system.write(fd, chunk.ptr, chunk.len);
        if (rc < 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}

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

pub fn main(init: std.process.Init.Minimal) !void {
    const args_owned = compat.args.alloc(std.heap.page_allocator, init.args) catch {
        return;
    };
    defer args_owned.deinit(std.heap.page_allocator);
    const args = args_owned.argv;

    if (args.len < 2) {
        std.debug.print("Usage: {s} <input_file>\n", .{args[0]});
        std.debug.print("\nFuzzing harness for SDCS validator.\n", .{});
        std.debug.print("Processes input file and reports validation status.\n", .{});
        std.process.exit(2);
    }

    const input_path = args[1];

    // Open the input file
    const fd = openReadOnly(input_path) catch |err| {
        // File errors are not crashes, just exit cleanly
        std.debug.print("Could not open file: {any}\n", .{err});
        std.process.exit(1);
    };
    defer _ = posix.system.close(fd);

    // Run validation with diagnostics
    var diag = sdcs.ValidationDiagnostics{};
    const result = sdcs.validateFileWithDiagnostics(fd, &diag);

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

    const fd = openCreateRdwr(tmp_path, 0o644) catch {
        return 0;
    };
    writeAllFd(fd, slice) catch {
        _ = posix.system.close(fd);
        return 0;
    };
    _ = posix.system.close(fd);

    const read_fd = openReadOnly(tmp_path) catch {
        return 0;
    };
    defer _ = posix.system.close(read_fd);

    var diag = sdcs.ValidationDiagnostics{};
    sdcs.validateFileWithDiagnostics(read_fd, &diag) catch {};

    return 0;
}

/// Corpus generation: create a set of valid and edge-case SDCS files.
pub fn generateCorpus(output_dir: []const u8) !void {
    // Create output directory
    var dir_buf = try posix.toPosixPath(output_dir);
    const mkrc = posix.system.mkdir(&dir_buf, @as(posix.mode_t, 0o755));
    if (mkrc != 0 and posix.errno(mkrc) != .EXIST) return error.MakeDirFailed;

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

    const fd = try openCreateRdwr(path, 0o644);
    defer _ = posix.system.close(fd);

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
    try writeAllFd(fd, &header);

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
    try writeAllFd(fd, &chunk);

    // RESET command
    var reset_cmd: [8]u8 = undefined;
    @memset(&reset_cmd, 0);
    reset_cmd[0] = sdcs.Op.RESET & 0xff;
    reset_cmd[1] = (sdcs.Op.RESET >> 8) & 0xff;
    try writeAllFd(fd, &reset_cmd);

    // END command
    var end_cmd: [8]u8 = undefined;
    @memset(&end_cmd, 0);
    end_cmd[0] = sdcs.Op.END & 0xff;
    end_cmd[1] = (sdcs.Op.END >> 8) & 0xff;
    try writeAllFd(fd, &end_cmd);
}

fn generateAllOpcodes(output_dir: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/all_opcodes.sdcs", .{output_dir});

    const fd = try openCreateRdwr(path, 0o644);
    defer _ = posix.system.close(fd);

    const chunk_hdr_size: usize = 32;

    // Header
    var header: [64]u8 = undefined;
    @memset(&header, 0);
    @memcpy(header[0..8], sdcs.Magic);
    header[8] = sdcs.version_major & 0xff;
    header[10] = sdcs.version_minor & 0xff;
    header[12] = 64;
    try writeAllFd(fd, &header);

    // For simplicity, just write a minimal chunk with RESET and END
    // A full version would include all opcodes with valid payloads
    var chunk: [32]u8 = undefined;
    @memset(&chunk, 0);
    @memcpy(chunk[0..4], "CMDS");
    chunk[8] = 64;
    chunk[16] = chunk_hdr_size + 16;
    chunk[24] = 16;
    try writeAllFd(fd, &chunk);

    var reset_cmd: [8]u8 = undefined;
    @memset(&reset_cmd, 0);
    reset_cmd[0] = sdcs.Op.RESET & 0xff;
    reset_cmd[1] = (sdcs.Op.RESET >> 8) & 0xff;
    try writeAllFd(fd, &reset_cmd);

    var end_cmd: [8]u8 = undefined;
    @memset(&end_cmd, 0);
    end_cmd[0] = sdcs.Op.END & 0xff;
    end_cmd[1] = (sdcs.Op.END >> 8) & 0xff;
    try writeAllFd(fd, &end_cmd);
}

fn generateEdgeCases(output_dir: []const u8) !void {
    // Empty file
    {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/empty.sdcs", .{output_dir});
        const fd = try openCreateRdwr(path, 0o644);
        _ = posix.system.close(fd);
    }

    // Just header, no chunks
    {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/header_only.sdcs", .{output_dir});
        const fd = try openCreateRdwr(path, 0o644);
        defer _ = posix.system.close(fd);

        var header: [64]u8 = undefined;
        @memset(&header, 0);
        @memcpy(header[0..8], sdcs.Magic);
        header[8] = sdcs.version_major & 0xff;
        header[10] = sdcs.version_minor & 0xff;
        header[12] = 64;
        try writeAllFd(fd, &header);
    }

    // Truncated header
    {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/truncated_header.sdcs", .{output_dir});
        const fd = try openCreateRdwr(path, 0o644);
        defer _ = posix.system.close(fd);
        try writeAllFd(fd, sdcs.Magic);
    }
}
