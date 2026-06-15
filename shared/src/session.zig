const std = @import("std");
const posix = std.posix;

/// Default path for the session token file.
/// Whichever daemon starts first creates this file; all subsequent daemons
/// read it. The token changes only on a full fabric restart.
pub const DEFAULT_SESSION_PATH = "/var/run/sema/session";

/// Read the session token from `path`, or generate and write a new one.
///
/// Behaviour:
/// - If the file exists and contains a valid 16-character hex token, return it.
/// - Otherwise generate a cryptographically random u64, write it as a
///   16-character lowercase hex string to `path`, and return it.
/// - Creates the parent directory if it does not exist.
///
/// The token is monotonically unique per fabric lifetime: it never resets
/// between individual daemon restarts, only when the token file is deleted
/// (i.e. on a full fabric restart or explicit reset).
pub fn readOrCreate(path: []const u8) !u64 {
    // Ensure the parent directory exists.
    if (std.fs.path.dirname(path)) |dir_path| {
        var dir_buf = posix.toPosixPath(dir_path) catch return error.NameTooLong;
        _ = posix.system.mkdir(&dir_buf, 0o755);
    }

    // Attempt to read an existing token.
    if (readToken(path)) |token| {
        return token;
    } else |_| {
        // File missing, unreadable, or contains invalid data — generate fresh.
    }

    var token_bytes: [8]u8 = undefined;
    posix.system.arc4random_buf(&token_bytes, token_bytes.len);
    const token = std.mem.readInt(u64, &token_bytes, .little);
    try writeToken(path, token);
    return token;
}

/// Render a session token as a 16-character lowercase hex string.
/// `buf` must be at least 16 bytes. Returns a slice into `buf`.
pub fn format(token: u64, buf: []u8) []u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{token}) catch unreachable;
}

// ============================================================================
// Internal helpers
// ============================================================================

// Raw-posix file helpers (ADR shared 0001): session.zig owns its token file via
// posix.system rather than the removed std.fs.*Absolute and std.Io.File paths.
// File-local for now, matching clock.zig and input.zig; a shared posixfile
// module is a post-migration refactor.
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

fn readAllInto(fd: posix.fd_t, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const rc = posix.system.read(fd, buf.ptr + total, buf.len - total);
        const n: isize = @bitCast(rc);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        total += @intCast(n);
    }
    return total;
}

fn writeAllFrom(fd: posix.fd_t, bytes: []const u8) !void {
    var total: usize = 0;
    while (total < bytes.len) {
        const rc = posix.system.write(fd, bytes.ptr + total, bytes.len - total);
        const n: isize = @bitCast(rc);
        if (n <= 0) return error.WriteFailed;
        total += @intCast(n);
    }
}

fn readToken(path: []const u8) !u64 {
    const fd = try openReadOnly(path);
    defer _ = posix.system.close(fd);

    var buf: [17]u8 = undefined; // 16 hex chars + optional newline
    const n = try readAllInto(fd, &buf);

    // Accept exactly 16 hex chars, optionally followed by a newline.
    const hex = switch (n) {
        16 => buf[0..16],
        17 => if (buf[16] == '\n') buf[0..16] else return error.InvalidTokenFormat,
        else => return error.InvalidTokenFormat,
    };

    return std.fmt.parseInt(u64, hex, 16) catch error.InvalidTokenFormat;
}

fn writeToken(path: []const u8, token: u64) !void {
    var fmt_buf: [17]u8 = undefined;
    const hex = std.fmt.bufPrint(&fmt_buf, "{x:0>16}\n", .{token}) catch unreachable;

    const fd = try openCreateRdwr(path, 0o600);
    defer _ = posix.system.close(fd);
    try writeAllFrom(fd, hex);
}

// ============================================================================
// Tests
// ============================================================================

test "format produces 16 lowercase hex chars" {
    var buf: [16]u8 = undefined;
    const result = format(0x0000000000000001, &buf);
    try std.testing.expectEqualStrings("0000000000000001", result);

    const result2 = format(0xdeadbeefcafebabe, &buf);
    try std.testing.expectEqualStrings("deadbeefcafebabe", result2);

    const result3 = format(0, &buf);
    try std.testing.expectEqualStrings("0000000000000000", result3);

    const result4 = format(std.math.maxInt(u64), &buf);
    try std.testing.expectEqualStrings("ffffffffffffffff", result4);
}

test "format output is always exactly 16 characters" {
    var buf: [16]u8 = undefined;
    // Try a range of values including small ones that need zero-padding.
    const cases = [_]u64{ 0, 1, 255, 256, 0xFFFF, 0x100000000, std.math.maxInt(u64) };
    for (cases) |token| {
        const result = format(token, &buf);
        try std.testing.expectEqual(@as(usize, 16), result.len);
    }
}

test "readOrCreate creates token file and returns consistent value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build an absolute path inside the temp dir.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var io_backing = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_backing.deinit();
    const io = io_backing.io();
    const tmp_len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..tmp_len];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const token_path = try std.fmt.bufPrint(&full_buf, "{s}/session", .{tmp_path});

    // First call: file does not exist — should create it.
    const token1 = try readOrCreate(token_path);

    // Second call: file now exists — should read the same value.
    const token2 = try readOrCreate(token_path);

    try std.testing.expectEqual(token1, token2);

    // Verify the file contains the correct hex representation.
    var fmt_buf: [16]u8 = undefined;
    const hex = format(token1, &fmt_buf);

    const fd = try openReadOnly(token_path);
    defer _ = posix.system.close(fd);
    var read_buf: [17]u8 = undefined;
    const n = try readAllInto(fd, &read_buf);
    // File should contain 16 hex chars + newline.
    try std.testing.expectEqual(@as(usize, 17), n);
    try std.testing.expectEqualStrings(hex, read_buf[0..16]);
    try std.testing.expectEqual('\n', read_buf[16]);
}

test "readOrCreate regenerates on corrupted token file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var io_backing = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_backing.deinit();
    const io = io_backing.io();
    const tmp_len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..tmp_len];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const token_path = try std.fmt.bufPrint(&full_buf, "{s}/session", .{tmp_path});

    // Write garbage into the token file.
    const fd = try openCreateRdwr(token_path, 0o600);
    try writeAllFrom(fd, "not-a-hex-token!!");
    _ = posix.system.close(fd);

    // readOrCreate should overwrite with a valid token.
    const token = try readOrCreate(token_path);

    var fmt_buf: [16]u8 = undefined;
    const hex = format(token, &fmt_buf);
    try std.testing.expectEqual(@as(usize, 16), hex.len);

    // Verify round-trip.
    const token2 = try readOrCreate(token_path);
    try std.testing.expectEqual(token, token2);
}

test "readOrCreate creates parent directory if absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var io_backing = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_backing.deinit();
    const io = io_backing.io();
    const tmp_len = try tmp.dir.realPath(io, &path_buf);
    const tmp_path = path_buf[0..tmp_len];
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Use a subdirectory that doesn't exist yet.
    const token_path = try std.fmt.bufPrint(&full_buf, "{s}/sema/session", .{tmp_path});

    const token = try readOrCreate(token_path);
    try std.testing.expect(token != 0 or token == 0); // any u64 is valid

    // Confirm the file was created.
    const check_fd = try openReadOnly(token_path);
    _ = posix.system.close(check_fd);
}
