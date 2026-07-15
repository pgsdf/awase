const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
});

/// Shared memory buffer for zero-copy SDCS transfer
pub const ShmBuffer = struct {
    fd: posix.fd_t,
    size: usize,
    /// Mapped memory - stores the raw mmap result for proper munmap
    mapped_ptr: ?*anyopaque,
    name: ?[]const u8,
    allocator: ?std.mem.Allocator,

    /// Create a new anonymous shared memory buffer
    pub fn create(size: usize) !ShmBuffer {
        // Use memfd_create for anonymous shared memory (Linux)
        // On FreeBSD, we'd use shm_open with SHM_ANON or a unique name
        const fd = try createAnonymousShm(size);
        errdefer closeFd(fd);

        const ptr = try posix.mmap(
            null,
            size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        return .{
            .fd = fd,
            .size = size,
            .mapped_ptr = ptr,
            .name = null,
            .allocator = null,
        };
    }

    /// Create a named shared memory buffer
    pub fn createNamed(allocator: std.mem.Allocator, name: []const u8, size: usize) !ShmBuffer {
        const name_z = try allocator.dupeZ(u8, name);
        errdefer allocator.free(name_z);

        const fd = try shmOpen(name_z, size);
        errdefer closeFd(fd);

        const ptr = try posix.mmap(
            null,
            size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        return .{
            .fd = fd,
            .size = size,
            .mapped_ptr = ptr,
            .name = name_z,
            .allocator = allocator,
        };
    }

    /// Open an existing shared memory buffer from fd (for daemon)
    pub fn fromFd(fd: posix.fd_t, size: usize, writable: bool) !ShmBuffer {
        const prot = if (writable)
            posix.PROT.READ | posix.PROT.WRITE
        else
            posix.PROT.READ;

        const ptr = try posix.mmap(
            null,
            size,
            prot,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        return .{
            .fd = fd,
            .size = size,
            .mapped_ptr = ptr,
            .name = null,
            .allocator = null,
        };
    }

    /// Get the buffer contents as a slice
    pub fn getSlice(self: *ShmBuffer) ?[]u8 {
        if (self.mapped_ptr) |p| {
            const byte_ptr: [*]u8 = @ptrCast(p);
            return byte_ptr[0..self.size];
        }
        return null;
    }

    /// Get read-only slice
    pub fn getConstSlice(self: *const ShmBuffer) ?[]const u8 {
        if (self.mapped_ptr) |p| {
            const byte_ptr: [*]const u8 = @ptrCast(p);
            return byte_ptr[0..self.size];
        }
        return null;
    }

    pub fn deinit(self: *ShmBuffer) void {
        if (self.mapped_ptr) |p| {
            const byte_ptr: [*]align(4096) u8 = @ptrCast(@alignCast(p));
            posix.munmap(byte_ptr[0..self.size]);
            self.mapped_ptr = null;
        }
        closeFd(self.fd);

        if (self.name) |name| {
            if (self.allocator) |alloc| {
                // Unlink the shared memory
                shmUnlink(name);
                alloc.free(name);
            }
        }
    }
};

/// Create anonymous shared memory (cross-platform)
fn createAnonymousShm(size: usize) !posix.fd_t {
    // Try memfd_create first (Linux 3.17+)
    if (@hasDecl(posix, "memfd_create")) {
        return posix.memfd_create("semadraw", posix.MFD.CLOEXEC) catch {
            return fallbackAnonShm(size);
        };
    }
    return fallbackAnonShm(size);
}

/// Fallback for systems without memfd_create
fn fallbackAnonShm(size: usize) !posix.fd_t {
    // Generate unique name
    var name_buf: [64]u8 = undefined;
    const timestamp: u64 = @intCast(monotonicNowNs());
    const name = std.fmt.bufPrintZ(&name_buf, "/semadraw-{x}", .{timestamp}) catch unreachable;

    const fd = try shmOpen(name, size);

    // Immediately unlink so it's anonymous
    shmUnlink(name);

    return fd;
}

/// Open or create shared memory
fn shmOpen(name: [:0]const u8, size: usize) !posix.fd_t {
    const flags: posix.O = .{ .ACCMODE = .RDWR, .CREAT = true };
    const rc = posix.system.shm_open(name, @bitCast(flags), 0o600);
    if (rc < 0) return error.ShmOpenFailed;
    const fd: posix.fd_t = @intCast(rc);
    errdefer closeFd(fd);

    // Set size
    try ftruncateFd(fd, @intCast(size));

    return fd;
}

/// Unlink shared memory
fn shmUnlink(name: []const u8) void {
    // Convert to null-terminated
    var buf: [256]u8 = undefined;
    if (name.len < buf.len) {
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        _ = posix.system.shm_unlink(buf[0..name.len :0]);
    }
}


// ============================================================================
// Tests
// ============================================================================

test "ShmBuffer create and access" {
    var shm = try ShmBuffer.create(4096);
    defer shm.deinit();

    const slice = shm.getSlice() orelse return error.NoSlice;
    try std.testing.expectEqual(@as(usize, 4096), slice.len);

    // Write and read back
    slice[0] = 0xAB;
    slice[4095] = 0xCD;
    try std.testing.expectEqual(@as(u8, 0xAB), slice[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), slice[4095]);
}

// ============================================================================
// Migration time idiom (P2 Tranche 2): file-local monotonic clock helper.
// Replaces std.time.nanoTimestamp(), removed in Zig 0.16. Monotonic is the
// correct clock for the interval/pacing maths here. Duplicated per file by
// design during migration; consolidation deferred.
// ============================================================================

fn monotonicNowNs() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

// ============================================================================
// Migration raw-fd idiom (P2 WT1): file-local close helper.
// Replaces posix.close, removed in Zig 0.16, with the raw libc call. Mirrors
// the closeFd precedent in socket_server. Duplicated per file by design
// during migration; consolidation deferred.
// ============================================================================

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

fn ftruncateFd(fd: posix.fd_t, len: i64) !void {
    if (posix.system.ftruncate(fd, len) != 0) return error.Truncate;
}
