const std = @import("std");
const posix = std.posix;
const backend = @import("backend.zig");

/// Backend process manager - handles isolated backend processes
pub const BackendProcess = struct {
    allocator: std.mem.Allocator,
    /// Child process ID (0 if not forked)
    pid: posix.pid_t,
    /// Pipe for sending commands to backend (parent writes, child reads)
    cmd_pipe: [2]posix.fd_t,
    /// Pipe for receiving results from backend (child writes, parent reads)
    result_pipe: [2]posix.fd_t,
    /// Backend type
    backend_type: backend.BackendType,
    /// Whether the process is running
    running: bool,

    const Self = @This();

    /// Initialize backend process manager (does not fork yet)
    pub fn init(allocator: std.mem.Allocator, backend_type: backend.BackendType) Self {
        return .{
            .allocator = allocator,
            .pid = 0,
            .cmd_pipe = .{ -1, -1 },
            .result_pipe = .{ -1, -1 },
            .backend_type = backend_type,
            .running = false,
        };
    }

    /// Fork and start the backend process
    pub fn start(self: *Self) !void {
        if (self.running) return error.AlreadyRunning;

        // Create pipes
        self.cmd_pipe = try pipeFds();
        errdefer {
            closeFd(self.cmd_pipe[0]);
            closeFd(self.cmd_pipe[1]);
        }

        self.result_pipe = try pipeFds();
        errdefer {
            closeFd(self.result_pipe[0]);
            closeFd(self.result_pipe[1]);
        }

        // Fork
        const pid = try posix.fork();

        if (pid == 0) {
            // Child process - this becomes the backend
            self.runBackendChild() catch |err| {
                std.log.err("Backend child error: {}", .{err});
                posix.exit(1);
            };
            posix.exit(0);
        }

        // Parent process
        self.pid = pid;
        self.running = true;

        // Close child's ends of pipes
        closeFd(self.cmd_pipe[0]); // Close read end of cmd pipe
        self.cmd_pipe[0] = -1;
        closeFd(self.result_pipe[1]); // Close write end of result pipe
        self.result_pipe[1] = -1;
    }

    /// Stop the backend process
    pub fn stop(self: *Self) void {
        if (!self.running) return;

        // Send shutdown command
        self.sendShutdown() catch {};

        // Wait for child with timeout, then kill
        const start_ms = monotonicNowMs();
        while (monotonicNowMs() - start_ms < 1000) {
            const result = posix.waitpid(self.pid, .{ .NOHANG = true });
            if (result.pid != 0) {
                self.running = false;
                break;
            }
            sleepNs(10 * std.time.ns_per_ms);
        }

        if (self.running) {
            // Force kill
            posix.kill(self.pid, posix.SIG.KILL) catch {};
            _ = posix.waitpid(self.pid, .{});
            self.running = false;
        }

        self.closePipes();
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Send a render request to the backend process
    pub fn sendRenderRequest(self: *Self, request: backend.RenderRequest) !void {
        if (!self.running) return error.NotRunning;

        // Serialize and send request
        var buf: [4096]u8 = undefined;
        var offset: usize = 0;

        // Command type: RENDER = 1
        std.mem.writeInt(u32, buf[offset..][0..4], 1, .little);
        offset += 4;

        // Surface ID
        std.mem.writeInt(u32, buf[offset..][0..4], request.surface_id, .little);
        offset += 4;

        // Framebuffer config
        std.mem.writeInt(u32, buf[offset..][0..4], request.framebuffer.width, .little);
        offset += 4;
        std.mem.writeInt(u32, buf[offset..][0..4], request.framebuffer.height, .little);
        offset += 4;
        buf[offset] = @intFromEnum(request.framebuffer.format);
        offset += 1;

        // SDCS data length and data
        const sdcs_len: u32 = @intCast(request.sdcs_data.len);
        std.mem.writeInt(u32, buf[offset..][0..4], sdcs_len, .little);
        offset += 4;

        // Write header
        try writeAll(self.cmd_pipe[1], buf[0..offset]);

        // Write SDCS data separately
        try writeAll(self.cmd_pipe[1], request.sdcs_data);
    }

    /// Receive a render result from the backend process
    pub fn receiveResult(self: *Self) !backend.RenderResult {
        if (!self.running) return error.NotRunning;

        var buf: [256]u8 = undefined;

        // Read result header
        const n = try posix.read(self.result_pipe[0], &buf);
        if (n < 24) return error.InvalidResponse;

        const surface_id = std.mem.readInt(u32, buf[0..4], .little);
        const frame_number = std.mem.readInt(u64, buf[4..12], .little);
        const render_time = std.mem.readInt(u64, buf[12..20], .little);
        const success = buf[20] != 0;

        if (success) {
            return backend.RenderResult.success(surface_id, frame_number, render_time);
        } else {
            return backend.RenderResult.failure(surface_id, "backend error");
        }
    }

    // ========================================================================
    // Private functions
    // ========================================================================

    fn runBackendChild(self: *Self) !void {
        // Close parent's ends of pipes
        closeFd(self.cmd_pipe[1]); // Close write end of cmd pipe
        closeFd(self.result_pipe[0]); // Close read end of result pipe

        // Enter Capsicum sandbox on FreeBSD (future)
        // enterCapabilityMode() catch {};

        // Create backend
        var be = try backend.createBackend(self.allocator, self.backend_type);
        defer be.deinit();

        // Main loop - process commands
        while (true) {
            var cmd_buf: [4096]u8 = undefined;
            const n = posix.read(self.cmd_pipe[0], &cmd_buf) catch break;
            if (n == 0) break; // EOF

            const cmd_type = std.mem.readInt(u32, cmd_buf[0..4], .little);

            switch (cmd_type) {
                0 => break, // SHUTDOWN
                1 => { // RENDER
                    const result = self.handleRender(&be, cmd_buf[0..n]) catch |err| {
                        std.log.err("Render error: {}", .{err});
                        continue;
                    };
                    self.sendResult(result) catch break;
                },
                else => {},
            }
        }
    }

    fn handleRender(self: *Self, be: *backend.Backend, cmd_buf: []const u8) !backend.RenderResult {
        if (cmd_buf.len < 21) return error.InvalidCommand;

        const surface_id = std.mem.readInt(u32, cmd_buf[4..8], .little);
        const width = std.mem.readInt(u32, cmd_buf[8..12], .little);
        const height = std.mem.readInt(u32, cmd_buf[12..16], .little);
        const format: backend.PixelFormat = @enumFromInt(cmd_buf[16]);
        const sdcs_len = std.mem.readInt(u32, cmd_buf[17..21], .little);

        // Initialize framebuffer if needed
        try be.initFramebuffer(.{
            .width = width,
            .height = height,
            .format = format,
        });

        // Read SDCS data
        const sdcs_data = try self.allocator.alloc(u8, sdcs_len);
        defer self.allocator.free(sdcs_data);

        var offset: usize = 0;
        // First part may be in cmd_buf
        const header_size: usize = 21;
        if (cmd_buf.len > header_size) {
            const in_buf = @min(cmd_buf.len - header_size, sdcs_len);
            @memcpy(sdcs_data[0..in_buf], cmd_buf[header_size..][0..in_buf]);
            offset = in_buf;
        }

        // Read rest from pipe
        while (offset < sdcs_len) {
            const n = try posix.read(self.cmd_pipe[0], sdcs_data[offset..]);
            if (n == 0) return error.UnexpectedEof;
            offset += n;
        }

        // Render
        return be.render(.{
            .surface_id = surface_id,
            .sdcs_data = sdcs_data,
            .framebuffer = .{
                .width = width,
                .height = height,
                .format = format,
            },
        });
    }

    fn sendResult(self: *Self, result: backend.RenderResult) !void {
        var buf: [32]u8 = undefined;

        std.mem.writeInt(u32, buf[0..4], result.surface_id, .little);
        std.mem.writeInt(u64, buf[4..12], result.frame_number, .little);
        std.mem.writeInt(u64, buf[12..20], result.render_time_ns, .little);
        buf[20] = if (result.error_msg == null) 1 else 0;

        try writeAll(self.result_pipe[1], buf[0..21]);
    }

    fn sendShutdown(self: *Self) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], 0, .little); // SHUTDOWN = 0
        try writeAll(self.cmd_pipe[1], &buf);
    }

    fn closePipes(self: *Self) void {
        if (self.cmd_pipe[0] != -1) {
            closeFd(self.cmd_pipe[0]);
            self.cmd_pipe[0] = -1;
        }
        if (self.cmd_pipe[1] != -1) {
            closeFd(self.cmd_pipe[1]);
            self.cmd_pipe[1] = -1;
        }
        if (self.result_pipe[0] != -1) {
            closeFd(self.result_pipe[0]);
            self.result_pipe[0] = -1;
        }
        if (self.result_pipe[1] != -1) {
            closeFd(self.result_pipe[1]);
            self.result_pipe[1] = -1;
        }
    }
};

// ============================================================================
// Capsicum sandbox support (FreeBSD)
// ============================================================================

/// Enter Capsicum capability mode (FreeBSD only)
/// After this, the process can only use pre-opened file descriptors
pub fn enterCapabilityMode() !void {
    // cap_enter() is FreeBSD-specific
    // On Linux, we would use seccomp-bpf instead
    if (comptime @import("builtin").os.tag == .freebsd) {
        // TODO: Implement cap_enter() via @cImport
        // For now, this is a placeholder
    }
}

// ============================================================================
// Tests
// ============================================================================

test "BackendProcess init" {
    var bp = BackendProcess.init(std.testing.allocator, .software);
    defer bp.deinit();

    try std.testing.expect(!bp.running);
    try std.testing.expectEqual(@as(posix.pid_t, 0), bp.pid);
}

// ============================================================================
// Migration time idiom (P2 Tranche 3): file-local monotonic clock helper (ms).
// Replaces std.time.milliTimestamp(), removed in Zig 0.16. Monotonic is the
// correct clock for the interval maths here. Duplicated per file by design
// during migration; consolidation deferred.
// ============================================================================

fn monotonicNowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms);
}

fn sleepNs(ns: u64) void {
    var req: std.posix.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    while (true) {
        const rc = std.posix.system.nanosleep(&req, &req);
        if (rc == 0) return;
        if (std.posix.errno(rc) != .INTR) return;
        // EINTR: req now holds the remaining interval; loop to finish it
    }
}

// ============================================================================
// Migration raw-fd idiom (P2 WT2a): file-local close helper.
// Replaces posix.close, removed in Zig 0.16, with the raw libc call. Mirrors
// the closeFd precedent in socket_server. Duplicated per file by design.
// ============================================================================

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

// Migration raw-fd idiom (P2 WT2a): file-local blocking writeAll.
// Replaces posix.write, removed in Zig 0.16. Loops to completion over the
// raw libc write. A zero-byte return is treated as failure rather than
// spinning, since it means no forward progress on a blocking fd.
fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = posix.system.write(fd, bytes[off..].ptr, bytes.len - off);
        if (rc < 0) {
            if (posix.errno(rc) == .AGAIN) continue;
            return error.WriteFailed;
        }
        if (rc == 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}

// Migration raw-fd idiom (P2 WT2a): file-local pipe creator.
// Replaces posix.pipe, removed in Zig 0.16, with the raw libc call.
fn pipeFds() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (posix.system.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}
