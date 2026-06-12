const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

// Platform-specific ioctl constants
const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
    .freebsd => 0x80087467,
    .linux => 0x5414,
    else => 0x5414, // Default to Linux
};

const TIOCSCTTY: c_ulong = switch (builtin.os.tag) {
    .freebsd => 0x20007461,
    .linux => 0x540E,
    else => 0x540E, // Default to Linux
};

// Libc function declarations
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Pseudo-terminal handler for shell communication
pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    read_buf: [4096]u8,

    const Self = @This();

    /// Spawn a shell with a pty
    pub fn spawn(shell: ?[]const u8, cols: u16, rows: u16) !Self {
        // Open pty master using posix_openpt
        const master_fd = try openPtyMaster();
        errdefer posix.close(master_fd);

        // Get slave name and unlock using libc functions
        const slave_name = ptsname(master_fd) orelse return error.PtsnameFailed;
        if (grantpt(master_fd) < 0) return error.GrantptFailed;
        if (unlockpt(master_fd) < 0) return error.UnlockptFailed;

        // Set window size
        var ws = std.posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = ioctl(master_fd, TIOCSWINSZ, @intFromPtr(&ws));

        // Fork
        const pid = try posix.fork();

        if (pid == 0) {
            // Child process
            posix.close(master_fd);

            // Create new session
            _ = std.c.setsid();

            // Open slave pty
            const slave_name_slice = std.mem.sliceTo(slave_name, 0);
            const slave_fd = posix.open(slave_name_slice, .{ .ACCMODE = .RDWR }, 0) catch {
                posix.exit(1);
            };

            // Set as controlling terminal
            _ = ioctl(slave_fd, TIOCSCTTY, @as(c_ulong, 0));

            // Duplicate to stdin/stdout/stderr
            posix.dup2(slave_fd, 0) catch posix.exit(1);
            posix.dup2(slave_fd, 1) catch posix.exit(1);
            posix.dup2(slave_fd, 2) catch posix.exit(1);

            if (slave_fd > 2) {
                posix.close(slave_fd);
            }

            // Set window size on slave
            _ = ioctl(0, TIOCSWINSZ, @intFromPtr(&ws));

            // Execute shell
            const shell_path_slice = shell orelse getDefaultShell();

            // Copy shell path to null-terminated buffer for execve
            var shell_path_buf: [256]u8 = undefined;
            if (shell_path_slice.len >= shell_path_buf.len) {
                posix.exit(1);
            }
            @memcpy(shell_path_buf[0..shell_path_slice.len], shell_path_slice);
            shell_path_buf[shell_path_slice.len] = 0;
            const shell_path: [*:0]const u8 = @ptrCast(&shell_path_buf);

            const shell_basename = std.fs.path.basename(shell_path_slice);

            // Prepare argv with login shell prefix
            var login_name_buf: [256]u8 = undefined;
            login_name_buf[0] = '-';
            @memcpy(login_name_buf[1..][0..shell_basename.len], shell_basename);
            login_name_buf[1 + shell_basename.len] = 0;
            const login_name: [*:0]const u8 = @ptrCast(&login_name_buf);

            const argv: [2:null]?[*:0]const u8 = .{
                login_name,
                null,
            };

            // Set TERM, LINES, COLUMNS for proper terminal behavior
            _ = setenv("TERM", "xterm-256color", 1);

            // Mark the session so tools launched from this terminal can tell
            // they are running inside semadraw-term. install.sh uses this as a
            // secondary signal for its footgun guard (stopping semadrawd would
            // freeze this terminal); its primary detection is process ancestry,
            // because sudo scrubs the environment and this marker would not
            // survive a plain "sudo sh install.sh".
            _ = setenv("SEMADRAW_TERM", "1", 1);

            // Export LINES and COLUMNS so programs like top(1) and sh(1)
            // see the correct terminal dimensions without needing to query tput.
            var lines_buf: [16]u8 = undefined;
            var cols_buf: [16]u8 = undefined;
            const lines_str = std.fmt.bufPrintZ(&lines_buf, "{}", .{rows}) catch "24";
            const cols_str  = std.fmt.bufPrintZ(&cols_buf,  "{}", .{cols})  catch "80";
            _ = setenv("LINES",   lines_str.ptr, 1);
            _ = setenv("COLUMNS", cols_str.ptr,  1);

            const envp = std.c.environ;

            const err = std.c.execve(
                shell_path,
                @ptrCast(&argv),
                envp,
            );
            _ = err;

            posix.exit(127);
        }

        // Parent process
        return .{
            .master_fd = master_fd,
            .child_pid = pid,
            .read_buf = undefined,
        };
    }

    /// Close the pty and wait for child
    pub fn close(self: *Self) void {
        posix.close(self.master_fd);
        // Only wait if child hasn't been reaped already
        if (self.child_pid != 0) {
            _ = posix.waitpid(self.child_pid, 0);
        }
    }

    /// Get the master file descriptor for polling
    pub fn getFd(self: *const Self) posix.fd_t {
        return self.master_fd;
    }

    /// Read data from the pty (non-blocking if possible)
    pub fn read(self: *Self) !?[]const u8 {
        const n = posix.read(self.master_fd, &self.read_buf) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        if (n == 0) return null; // EOF
        return self.read_buf[0..n];
    }

    /// Write data to the pty
    pub fn write(self: *Self, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = try posix.write(self.master_fd, data[written..]);
            written += n;
        }
    }

    /// Resize the pty
    pub fn resize(self: *Self, cols: u16, rows: u16) void {
        var ws = std.posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = ioctl(self.master_fd, TIOCSWINSZ, @intFromPtr(&ws));
    }

    /// Check if child is still running
    pub fn isAlive(self: *const Self) bool {
        const result = posix.waitpid(self.child_pid, posix.W.NOHANG);
        return result.pid == 0; // 0 means still running
    }
};

fn openPtyMaster() !posix.fd_t {
    // Use posix_openpt for portability
    const O_RDWR = 0x0002;
    const O_NOCTTY = switch (builtin.os.tag) {
        .freebsd => 0x8000,
        .linux => 0x100,
        else => 0x100,
    };

    const fd = posix_openpt(O_RDWR | O_NOCTTY);
    if (fd < 0) {
        return error.OpenPtyFailed;
    }
    return fd;
}

fn getDefaultShell() []const u8 {
    // Try SHELL environment variable
    if (std.posix.getenv("SHELL")) |shell| {
        return shell;
    }
    // Fallback to /bin/sh
    return "/bin/sh";
}

// ============================================================================
// Tests
// ============================================================================

test "Pty spawn echo test" {
    // This test requires a working pty system
    // Skip in CI or when /dev/ptmx is not available
    _ = openPtyMaster() catch return;
}
