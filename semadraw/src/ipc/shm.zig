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
        errdefer posix.close(fd);

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
        errdefer posix.close(fd);

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
        posix.close(self.fd);

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
        return posix.memfd_create("semadraw", .{ .CLOEXEC = true }) catch {
            return fallbackAnonShm(size);
        };
    }
    return fallbackAnonShm(size);
}

/// Fallback for systems without memfd_create
fn fallbackAnonShm(size: usize) !posix.fd_t {
    // Generate unique name
    var name_buf: [64]u8 = undefined;
    const timestamp: u64 = @intCast(std.time.nanoTimestamp());
    const name = std.fmt.bufPrintZ(&name_buf, "/semadraw-{x}", .{timestamp}) catch unreachable;

    const fd = try shmOpen(name, size);

    // Immediately unlink so it's anonymous
    shmUnlink(name);

    return fd;
}

/// Open or create shared memory
fn shmOpen(name: [:0]const u8, size: usize) !posix.fd_t {
    const fd = posix.shm_open(
        name,
        .{ .ACCMODE = .RDWR, .CREAT = true },
        0o600,
    ) catch |err| {
        return err;
    };
    errdefer posix.close(fd);

    // Set size
    try posix.ftruncate(fd, @intCast(size));

    return fd;
}

/// Unlink shared memory
fn shmUnlink(name: []const u8) void {
    // Convert to null-terminated
    var buf: [256]u8 = undefined;
    if (name.len < buf.len) {
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        posix.shm_unlink(buf[0..name.len :0]) catch {};
    }
}

// ============================================================================
// SCM_RIGHTS - File descriptor passing
// ============================================================================

/// Control message buffer for fd passing
pub const CmsgBuffer = struct {
    buf: [CMSG_SPACE(@sizeOf(c_int))]u8 align(@alignOf(c.cmsghdr)),

    pub fn init() CmsgBuffer {
        return .{ .buf = undefined };
    }
};

/// Send a file descriptor over a Unix socket
pub fn sendFd(sock_fd: posix.fd_t, fd_to_send: posix.fd_t, data: []const u8) !void {
    var cmsg_buf = CmsgBuffer.init();

    var iov = [_]posix.iovec_const{
        .{
            .base = data.ptr,
            .len = data.len,
        },
    };

    var msg = posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cmsg_buf.buf,
        .controllen = CMSG_SPACE(@sizeOf(c_int)),
        .flags = 0,
    };

    // Set up control message
    const cmsg: *c.cmsghdr = @ptrCast(&cmsg_buf.buf);
    cmsg.cmsg_len = CMSG_LEN(@sizeOf(c_int));
    cmsg.cmsg_level = c.SOL_SOCKET;
    cmsg.cmsg_type = c.SCM_RIGHTS;

    // Copy fd into cmsg data
    const fd_ptr: *c_int = @ptrCast(@alignCast(CMSG_DATA(cmsg)));
    fd_ptr.* = fd_to_send;

    const result = posix.sendmsg(sock_fd, &msg, 0);
    if (result < 0) {
        return error.SendFailed;
    }
}

/// Receive a file descriptor over a Unix socket
pub fn recvFd(sock_fd: posix.fd_t, data_buf: []u8) !struct { fd: posix.fd_t, len: usize } {
    var cmsg_buf = CmsgBuffer.init();

    var iov = [_]posix.iovec{
        .{
            .base = data_buf.ptr,
            .len = data_buf.len,
        },
    };

    var msg = posix.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cmsg_buf.buf,
        .controllen = CMSG_SPACE(@sizeOf(c_int)),
        .flags = 0,
    };

    const result = posix.recvmsg(sock_fd, &msg, 0);
    if (result == 0) {
        return error.ConnectionClosed;
    }

    // Extract fd from control message
    const cmsg: *c.cmsghdr = @ptrCast(&cmsg_buf.buf);
    if (cmsg.cmsg_level == c.SOL_SOCKET and cmsg.cmsg_type == c.SCM_RIGHTS) {
        const fd_ptr: *const c_int = @ptrCast(@alignCast(CMSG_DATA(cmsg)));
        return .{ .fd = fd_ptr.*, .len = result };
    }

    return error.NoFdReceived;
}

// CMSG helper macros (Zig equivalents)
fn CMSG_ALIGN(len: usize) usize {
    return (len + @sizeOf(usize) - 1) & ~(@sizeOf(usize) - 1);
}

fn CMSG_SPACE(len: usize) usize {
    return CMSG_ALIGN(@sizeOf(c.cmsghdr)) + CMSG_ALIGN(len);
}

fn CMSG_LEN(len: usize) usize {
    return CMSG_ALIGN(@sizeOf(c.cmsghdr)) + len;
}

fn CMSG_DATA(cmsg: *c.cmsghdr) [*]u8 {
    const base: [*]u8 = @ptrCast(cmsg);
    return base + CMSG_ALIGN(@sizeOf(c.cmsghdr));
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
