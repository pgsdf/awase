// F.5.d (ADR 0026 Decision 2): the policy surfaces. For each target,
// /var/run/sema/audio/<target>/ carries policy-valid ("true\n" | "false\n"),
// policy-errors (one diagnostic per line, empty when valid), and
// policy-state (a small JSON view of the last evaluation). Each is rewritten
// ATOMICALLY (write-temp-then-rename) on every policy reload, per the Phase
// 12 contract. Filenames and formats are semaaud-compatible; only the prefix
// differs (recorded parity divergence: source of truth in etc, surfaces in
// run).
//
// Single accept thread only; no audio-thread involvement.

const std = @import("std");
const posix = std.posix;
const policy_mod = @import("policy.zig");

pub const RUN_BASE = "/var/run/sema/audio";

fn openCreateRdwr(path: []const u8, mode: posix.mode_t) !posix.fd_t {
    var path_buf = try posix.toPosixPath(path);
    const fd = posix.system.open(&path_buf, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, mode);
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

fn renamePath(old_path: []const u8, new_path: []const u8) !void {
    var old_buf = try posix.toPosixPath(old_path);
    var new_buf = try posix.toPosixPath(new_path);
    if (posix.system.rename(&old_buf, &new_buf) < 0) return error.RenameFailed;
}

fn makeDirPath(dir: []const u8) void {
    // mkdir -p over dir's own components (the ensureParents idiom carried in
    // shared infrastructure, applied to `dir` itself rather than its parent).
    var i: usize = 0;
    while (i < dir.len) {
        while (i < dir.len and dir[i] == '/') : (i += 1) {}
        if (i >= dir.len) break;
        while (i < dir.len and dir[i] != '/') : (i += 1) {}
        const partial = dir[0..i];
        var dir_buf = posix.toPosixPath(partial) catch return;
        _ = posix.system.mkdir(&dir_buf, 0o755);
    }
}

pub fn writeAtomic(dir: []const u8, name: []const u8, content: []const u8) void {
    var pathbuf: [256]u8 = undefined;
    var tmpbuf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&pathbuf, "{s}/{s}", .{ dir, name }) catch return;
    const tmp = std.fmt.bufPrint(&tmpbuf, "{s}/.{s}.tmp", .{ dir, name }) catch return;

    const fd = openCreateRdwr(tmp, 0o644) catch return;
    var ok = true;
    writeAllFd(fd, content) catch {
        ok = false;
    };
    _ = posix.system.close(fd);
    if (!ok) return;
    renamePath(tmp, path) catch {};
}

/// Ensure the per-target surface directory exists. Called once at startup
/// per target; failure is non-fatal (surfaces are observability only). The
/// mkdir -p idiom is fire-and-forget: pre-existing components are expected.
pub fn ensureDir(target_name: []const u8) void {
    var buf: [256]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/{s}", .{ RUN_BASE, target_name }) catch return;
    makeDirPath(dir);
}

/// Rewrite policy-valid and policy-errors for a target from a loaded policy.
pub fn writeValidation(target_name: []const u8, p: *const policy_mod.LoadedPolicy) void {
    var dirbuf: [256]u8 = undefined;
    const dir = std.fmt.bufPrint(&dirbuf, "{s}/{s}", .{ RUN_BASE, target_name }) catch return;

    writeAtomic(dir, "policy-valid", if (p.isValid()) "true\n" else "false\n");

    var errbuf: [policy_mod.MAX_ERRORS * (policy_mod.MAX_ERROR_LEN + 1)]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < p.nerrors) : (i += 1) {
        const e = p.errorAt(i);
        if (n + e.len + 1 > errbuf.len) break;
        @memcpy(errbuf[n .. n + e.len], e);
        n += e.len;
        errbuf[n] = '\n';
        n += 1;
    }
    writeAtomic(dir, "policy-errors", errbuf[0..n]);
}

/// Rewrite policy-state: a small JSON view of the last admission evaluation
/// on this target (ADR 0020's policy_state.zig concern; the fuller state
/// tree is F.5.e).
pub fn writeLastEvaluation(
    target_name: []const u8,
    label: []const u8,
    class: []const u8,
    decision: []const u8,
) void {
    var dirbuf: [256]u8 = undefined;
    const dir = std.fmt.bufPrint(&dirbuf, "{s}/{s}", .{ RUN_BASE, target_name }) catch return;
    var jb: [320]u8 = undefined;
    const j = std.fmt.bufPrint(
        &jb,
        "{{\"target\":\"{s}\",\"last\":{{\"label\":\"{s}\",\"class\":\"{s}\",\"decision\":\"{s}\"}}}}\n",
        .{ target_name, label, class, decision },
    ) catch return;
    writeAtomic(dir, "policy-state", j);
}
