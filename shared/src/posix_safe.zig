//! Safe POSIX I/O wrappers that bypass stdlib's `unexpectedErrno`
//! panic. AD-6 entry point.
//!
//! `std.posix.read` and `std.posix.write` carry a hand-maintained
//! list of "known" errno values for the underlying syscall. Errnos
//! outside that list flow through `unexpectedErrno`, which dumps a
//! stack trace and propagates a panic-style error. UTF's kernel
//! cdevs (drawfs, inputfs) and accepted cdevs (`/dev/dsp`) return
//! errnos that fall outside the stdlib's known set: `ENXIO` from
//! drawfs during session close, custom errnos from inputfs ring
//! overruns, `EBUSY` from contested DSP devices.
//!
//! These wrappers call `posix.system.read`/`write` directly (the
//! un-wrapped syscall layer) and convert any negative return to
//! `error.ReadFailed`/`error.WriteFailed`. Callers that want the
//! byte count check it themselves; callers that just want "did the
//! call succeed" use `try` / `catch break`.
//!
//! See `docs/UTF_ZIG_STDLIB_BOUNDARY.md` for the full discussion.
//! The original inline implementation in
//! `semadraw/src/backend/drawfs.zig` predates this module; future
//! cleanup may route that site through here.

const std = @import("std");
const posix = std.posix;

/// Read from `fd` into `buf`, returning the number of bytes read on
/// success or `error.ReadFailed` on any error.
///
/// Does not distinguish between errno values; UTF's call sites
/// uniformly want "stop reading and clean up" on any failure, so
/// the additional information is not useful at this layer. Specific
/// errno discrimination, if needed, can be done by the caller via
/// `posix.system.read` directly with the appropriate `@bitCast`.
pub fn safeRead(fd: posix.fd_t, buf: []u8) error{ReadFailed}!usize {
    const rc = posix.system.read(fd, buf.ptr, buf.len);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.ReadFailed;
    return @intCast(signed);
}

/// Write `buf` to `fd`, returning the number of bytes written on
/// success or `error.WriteFailed` on any error.
///
/// Same rationale as `safeRead`: the un-wrapped syscall does not
/// panic on unknown errnos, and UTF's call sites uniformly want
/// "stop writing and clean up" on any failure.
pub fn safeWrite(fd: posix.fd_t, buf: []const u8) error{WriteFailed}!usize {
    const rc = posix.system.write(fd, buf.ptr, buf.len);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.WriteFailed;
    return @intCast(signed);
}

test "safeRead from /dev/null returns EOF" {
    const fd = try posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    defer posix.close(fd);

    var buf: [16]u8 = undefined;
    const n = try safeRead(fd, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "safeWrite to /dev/null succeeds" {
    const fd = try posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    defer posix.close(fd);

    const buf = "test\n";
    const n = try safeWrite(fd, buf);
    try std.testing.expectEqual(buf.len, n);
}

test "safeRead from invalid fd returns ReadFailed" {
    var buf: [16]u8 = undefined;
    // fd -1 is unconditionally invalid; safeRead should return
    // error.ReadFailed without panicking on the EBADF errno.
    const result = safeRead(-1, &buf);
    try std.testing.expectError(error.ReadFailed, result);
}

test "safeWrite to invalid fd returns WriteFailed" {
    const buf = "test\n";
    const result = safeWrite(-1, buf);
    try std.testing.expectError(error.WriteFailed, result);
}
