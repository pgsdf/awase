const std = @import("std");
const posix = std.posix;
const backend = @import("backend");
const builtin = @import("builtin");

const log = std.log.scoped(.bsd_input);

// Link libc for ioctl and console access
const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("sys/consio.h"); // For KDSKBMODE, KDGKBMODE
    @cInclude("sys/kbio.h"); // For keyboard mode constants
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("unistd.h"); // For open/close
    @cInclude("libinput.h"); // For libinput support
    @cInclude("libudev.h"); // For udev context
});

// Evdev event types
const EV_KEY: u16 = 0x01;
const EV_REL: u16 = 0x02;
const EV_ABS: u16 = 0x03;

// Evdev ioctl numbers - FreeBSD uses different encoding than Linux
// FreeBSD: IOC_OUT (read) = 0x40000000, IOC_IN (write) = 0x80000000
// Linux:   _IOC_READ = 0x80000000, _IOC_WRITE = 0x40000000
// FreeBSD evdev uses Linux-compatible numbers for compatibility
const is_freebsd = builtin.os.tag == .freebsd;

// EVIOCGNAME(len) = _IOC(_IOC_READ, 'E', 0x06, len)
// EVIOCGBIT(ev, len) = _IOC(_IOC_READ, 'E', 0x20 + ev, len)
fn EVIOCGNAME(len: usize) c_ulong {
    // FreeBSD evdev uses Linux ioctl encoding for compatibility
    return @as(c_ulong, 0x80000000) | (@as(c_ulong, len) << 16) | (@as(c_ulong, 'E') << 8) | 0x06;
}

fn EVIOCGBIT(ev: u8, len: usize) c_ulong {
    return @as(c_ulong, 0x80000000) | (@as(c_ulong, len) << 16) | (@as(c_ulong, 'E') << 8) | (@as(c_ulong, 0x20) + ev);
}

// Keyboard mode constants (from sys/kbio.h)
const K_RAW: c_int = 0; // Raw scancode mode
const K_XLATE: c_int = 1; // Translated ASCII mode
const K_CODE: c_int = 2; // Key code mode

// Input event structure for evdev
const InputEvent = extern struct {
    tv_sec: isize,
    tv_usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

// ============================================================================
// FreeBSD input support (evdev + sysmouse + VT console keyboard)
// ============================================================================

/// Maximum number of input devices to track
pub const MAX_INPUT_DEVICES = 4;

/// Input device types
pub const InputDeviceType = enum {
    keyboard,
    mouse,
    unknown,
};

/// Keyboard input mode
pub const KeyboardMode = enum {
    none, // No keyboard available
    libinput, // Using libinput (preferred for graphics mode)
    evdev, // Using evdev device (/dev/input/event*)
    vt_raw, // Using VT console in raw scancode mode
    tty_raw, // Using VT/tty device with raw termios mode
};

/// BSD input handler - manages keyboard and mouse input on FreeBSD
pub const BsdInput = struct {
    allocator: std.mem.Allocator,

    // Input device file descriptors
    mouse_fd: posix.fd_t,
    tty_fd: posix.fd_t,

    // Evdev keyboard device (if available)
    evdev_keyboard_fd: posix.fd_t,

    // VT console device (for raw keyboard mode)
    console_fd: posix.fd_t,
    orig_kb_mode: c_int, // Original keyboard mode for restoration

    // libinput context (for graphics mode input)
    libinput_ctx: ?*c.struct_libinput,
    udev_ctx: ?*c.struct_udev,
    libinput_fd: posix.fd_t,

    // Keyboard input mode being used
    keyboard_mode: KeyboardMode,

    // Original terminal settings (for restoration)
    orig_termios: ?c.struct_termios,

    // Mouse state
    mouse_x: i32,
    mouse_y: i32,
    mouse_buttons: u8, // Bit flags: 0=left, 1=middle, 2=right
    screen_width: u32,
    screen_height: u32,

    // Modifier key state (for scancode tracking)
    shift_pressed: bool,
    ctrl_pressed: bool,
    alt_pressed: bool,
    modifiers: u8, // Bit flags: 0=shift, 1=alt, 2=ctrl, 3=meta

    // Event queues
    key_events: [backend.MAX_KEY_EVENTS]backend.KeyEvent,
    key_event_count: usize,
    mouse_events: [backend.MAX_MOUSE_EVENTS]backend.MouseEvent,
    mouse_event_count: usize,

    // Sysmouse packet buffer
    mouse_buf: [5]u8,
    mouse_buf_len: usize,

    // Escape sequence buffer for keyboard (tty mode only)
    esc_buf: [16]u8,
    esc_buf_len: usize,
    esc_timeout: i64, // Timestamp when escape started

    const Self = @This();

    /// Sysmouse button masks (active low in protocol, we invert)
    const MOUSE_LEFT: u8 = 0x01;
    const MOUSE_MIDDLE: u8 = 0x02;
    const MOUSE_RIGHT: u8 = 0x04;

    /// Initialize BSD input handler
    pub fn init(allocator: std.mem.Allocator, screen_width: u32, screen_height: u32) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .mouse_fd = -1,
            .tty_fd = -1,
            .evdev_keyboard_fd = -1,
            .console_fd = -1,
            .orig_kb_mode = K_XLATE,
            .libinput_ctx = null,
            .udev_ctx = null,
            .libinput_fd = -1,
            .keyboard_mode = .none,
            .orig_termios = null,
            .mouse_x = @intCast(screen_width / 2),
            .mouse_y = @intCast(screen_height / 2),
            .mouse_buttons = 0,
            .screen_width = screen_width,
            .screen_height = screen_height,
            .shift_pressed = false,
            .ctrl_pressed = false,
            .alt_pressed = false,
            .modifiers = 0,
            .key_events = undefined,
            .key_event_count = 0,
            .mouse_events = undefined,
            .mouse_event_count = 0,
            .mouse_buf = undefined,
            .mouse_buf_len = 0,
            .esc_buf = undefined,
            .esc_buf_len = 0,
            .esc_timeout = 0,
        };

        // Open sysmouse for mouse input
        self.mouse_fd = posix.open("/dev/sysmouse", .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch |err| blk: {
            log.warn("failed to open /dev/sysmouse: {} (is moused running?)", .{err});
            break :blk -1;
        };

        if (self.mouse_fd >= 0) {
            log.info("opened /dev/sysmouse for mouse input", .{});
        }

        // Try keyboard input methods in order of preference:
        // 1. libinput (works properly in graphics mode on FreeBSD)
        // 2. evdev (if available on FreeBSD with evdev support)
        // 3. VT console raw mode (for direct console access)
        // 4. /dev/tty raw mode (fallback)

        // Method 1: Try libinput (preferred for graphics mode)
        if (self.tryLibinputKeyboard()) {
            log.info("keyboard: using libinput", .{});
        }
        // Method 2: Try evdev keyboard
        else if (self.tryEvdevKeyboard()) {
            log.info("keyboard: using evdev device", .{});
        }
        // Method 3: Try VT console raw keyboard mode
        else if (self.tryVtConsoleKeyboard()) {
            log.info("keyboard: using VT console raw mode", .{});
        }
        // Method 4: Fall back to VT/tty raw mode
        else if (self.tryTtyKeyboard()) {
            // Note: tryTtyKeyboard logs which device it opened
        } else {
            log.warn("no keyboard input method available", .{});
        }

        // Log input device status
        const kb_available = self.keyboard_mode != .none;
        const mouse_available = self.mouse_fd >= 0;

        if (mouse_available and kb_available) {
            log.info("BSD input initialized: mouse and keyboard ({s}) available", .{@tagName(self.keyboard_mode)});
        } else if (kb_available) {
            log.info("BSD input initialized: keyboard ({s}) only", .{@tagName(self.keyboard_mode)});
            log.warn("for mouse: ensure moused is running (service moused start)", .{});
        } else if (mouse_available) {
            log.warn("BSD input: mouse available but keyboard failed", .{});
        } else {
            log.warn("no input devices available on FreeBSD", .{});
            log.warn("for mouse: ensure moused is running (service moused start)", .{});
        }

        return self;
    }

    /// libinput interface functions for udev integration
    const libinput_interface = c.struct_libinput_interface{
        .open_restricted = openRestricted,
        .close_restricted = closeRestricted,
    };

    fn openRestricted(path: [*c]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
        _ = user_data;
        const fd = c.open(path, flags);
        if (fd < 0) {
            return -1;
        }
        return fd;
    }

    fn closeRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.c) void {
        _ = user_data;
        _ = c.close(fd);
    }

    /// Try to initialize libinput for keyboard input
    /// libinput is preferred for graphics mode as it works correctly when
    /// the console is switched to KMS/DRM graphics mode
    fn tryLibinputKeyboard(self: *Self) bool {
        // Create udev context
        self.udev_ctx = c.udev_new();
        if (self.udev_ctx == null) {
            log.debug("libinput: failed to create udev context", .{});
            return false;
        }

        // Create libinput context using udev backend
        self.libinput_ctx = c.libinput_udev_create_context(
            &libinput_interface,
            null, // user_data
            self.udev_ctx,
        );

        if (self.libinput_ctx == null) {
            log.debug("libinput: failed to create context", .{});
            _ = c.udev_unref(self.udev_ctx);
            self.udev_ctx = null;
            return false;
        }

        // Assign seat (use default seat)
        if (c.libinput_udev_assign_seat(self.libinput_ctx, "seat0") < 0) {
            log.debug("libinput: failed to assign seat", .{});
            _ = c.libinput_unref(self.libinput_ctx);
            self.libinput_ctx = null;
            _ = c.udev_unref(self.udev_ctx);
            self.udev_ctx = null;
            return false;
        }

        // Get the file descriptor for polling
        self.libinput_fd = c.libinput_get_fd(self.libinput_ctx);
        if (self.libinput_fd < 0) {
            log.debug("libinput: failed to get fd", .{});
            _ = c.libinput_unref(self.libinput_ctx);
            self.libinput_ctx = null;
            _ = c.udev_unref(self.udev_ctx);
            self.udev_ctx = null;
            return false;
        }

        // Dispatch once to process initial device discovery
        _ = c.libinput_dispatch(self.libinput_ctx);

        // Consume initial events (device added, etc.)
        while (c.libinput_get_event(self.libinput_ctx)) |event| {
            const event_type = c.libinput_event_get_type(event);
            if (event_type == c.LIBINPUT_EVENT_DEVICE_ADDED) {
                const device = c.libinput_event_get_device(event);
                if (device != null) {
                    const name = c.libinput_device_get_name(device);
                    if (name != null) {
                        log.debug("libinput: device added: {s}", .{name});
                    }
                }
            }
            c.libinput_event_destroy(event);
        }

        self.keyboard_mode = .libinput;
        log.info("libinput initialized successfully", .{});
        return true;
    }

    /// Try to open an evdev keyboard device
    fn tryEvdevKeyboard(self: *Self) bool {
        // Scan /dev/input/ for event devices
        var path_buf: [64]u8 = undefined;

        var i: u32 = 0;
        while (i < 32) : (i += 1) {
            const path_z = std.fmt.bufPrintZ(&path_buf, "/dev/input/event{}", .{i}) catch continue;

            const fd = posix.open(path_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch |err| {
                if (i == 0) {
                    log.debug("failed to open /dev/input/event0: {}", .{err});
                }
                continue;
            };

            // Check if this is a keyboard device
            if (self.isEvdevKeyboard(fd)) {
                self.evdev_keyboard_fd = fd;
                self.keyboard_mode = .evdev;
                log.info("found evdev keyboard at /dev/input/event{}", .{i});
                return true;
            }

            posix.close(fd);
        }

        log.debug("no evdev keyboard devices found in /dev/input/", .{});
        return false;
    }

    /// Check if an evdev device is a keyboard
    fn isEvdevKeyboard(self: *Self, fd: posix.fd_t) bool {
        _ = self;

        // Try to get device name first (simple check that evdev ioctls work)
        var name: [256]u8 = undefined;
        const name_ioctl = EVIOCGNAME(256);
        log.debug("trying EVIOCGNAME ioctl: 0x{x} on fd {}", .{ name_ioctl, fd });
        const name_result = c.ioctl(fd, name_ioctl, &name);
        if (name_result < 0) {
            // Get errno for more details - on FreeBSD, ENOTTY (25) means not a tty ioctl
            const errno_val = std.c._errno().*;
            log.debug("EVIOCGNAME failed (result={}, errno={}), not an evdev device", .{ name_result, errno_val });
            return false;
        }

        // Log the device name
        const name_len = std.mem.indexOfScalar(u8, &name, 0) orelse name.len;
        log.debug("evdev device name: {s}", .{name[0..name_len]});

        // Get event types supported by this device
        var ev_bits: [4]u8 = [_]u8{0} ** 4;
        const ev_ioctl = EVIOCGBIT(0, 4);
        const ev_result = c.ioctl(fd, ev_ioctl, &ev_bits);
        if (ev_result < 0) {
            log.debug("EVIOCGBIT(0) failed", .{});
            return false;
        }

        // Check for EV_KEY support (bit 1)
        const has_key = (ev_bits[0] & (1 << EV_KEY)) != 0;
        if (!has_key) {
            log.debug("device does not support EV_KEY", .{});
            return false;
        }

        // Get key bits to check for keyboard keys
        var key_bits: [96]u8 = [_]u8{0} ** 96;
        const key_ioctl = EVIOCGBIT(EV_KEY, 96);
        const key_result = c.ioctl(fd, key_ioctl, &key_bits);
        if (key_result < 0) {
            log.debug("EVIOCGBIT(EV_KEY) failed", .{});
            return false;
        }

        // Check for KEY_Q (16) and KEY_W (17) - most keyboards have these
        const has_q = (key_bits[16 / 8] & (@as(u8, 1) << @intCast(16 % 8))) != 0;
        const has_w = (key_bits[17 / 8] & (@as(u8, 1) << @intCast(17 % 8))) != 0;
        // Also check KEY_A (30) and KEY_SPACE (57) for robustness
        const has_a = (key_bits[30 / 8] & (@as(u8, 1) << @intCast(30 % 8))) != 0;
        const has_space = (key_bits[57 / 8] & (@as(u8, 1) << @intCast(57 % 8))) != 0;

        const is_keyboard = (has_q and has_w) or (has_a and has_space);

        if (is_keyboard) {
            log.info("evdev keyboard detected: {s}", .{name[0..name_len]});
        }

        return is_keyboard;
    }

    /// Try to set up VT console raw keyboard mode
    /// NOTE: KDSKBMODE is disabled because it affects keyboard input globally,
    /// breaking other VTs. Instead, we try direct keyboard devices.
    fn tryVtConsoleKeyboard(self: *Self) bool {
        // Try direct keyboard devices on FreeBSD
        // These provide raw keyboard access without affecting VT keyboard mode
        const kbd_paths = [_][:0]const u8{
            "/dev/kbdmux0", // Keyboard multiplexer (preferred)
            "/dev/ukbd0", // USB keyboard
            "/dev/atkbd0", // AT keyboard
            "/dev/kbd0", // Generic keyboard
        };

        for (kbd_paths) |path| {
            self.console_fd = posix.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch continue;

            // Successfully opened a keyboard device
            self.keyboard_mode = .vt_raw;
            log.info("opened keyboard device: {s}", .{path});
            return true;
        }

        // KDSKBMODE approach is disabled - it breaks other VTs
        // The /dev/tty fallback will be used instead
        log.debug("no direct keyboard devices found, will use tty fallback", .{});
        return false;
    }

    /// Try to open /dev/tty for keyboard input (fallback mode)
    /// Uses true raw mode on the VT device for console graphics compatibility
    fn tryTtyKeyboard(self: *Self) bool {
        // Try to open the actual VT device first, then fall back to /dev/tty
        // Using the VT device directly works better when in graphics mode
        const tty_paths = [_][:0]const u8{
            "/dev/ttyv0", // FreeBSD first virtual terminal
            "/dev/ttyv1",
            "/dev/ttyv2",
            "/dev/tty", // Controlling terminal (last resort)
        };

        for (tty_paths) |path| {
            self.tty_fd = posix.open(path, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0) catch continue;

            if (self.setTrueRawMode()) {
                self.keyboard_mode = .tty_raw;
                log.info("keyboard: using {s} (raw termios mode)", .{path});

                // Check if this is actually /dev/tty (controlling terminal)
                // vs a specific VT device
                if (std.mem.eql(u8, path, "/dev/tty")) {
                    log.warn("keyboard input may not work from another terminal", .{});
                    log.warn("for best results, enable evdev: kldload evdev && sysctl kern.evdev.rcpt_mask=12", .{});
                }

                return true;
            }

            posix.close(self.tty_fd);
            self.tty_fd = -1;
        }

        log.debug("failed to open any tty device for keyboard", .{});
        return false;
    }

    /// Set terminal to true raw mode for keyboard input
    /// This disables ALL processing so we get raw bytes
    fn setTrueRawMode(self: *Self) bool {
        if (self.tty_fd < 0) return false;

        var t: c.struct_termios = undefined;

        // Get current settings
        if (c.tcgetattr(self.tty_fd, &t) < 0) return false;

        // Save original settings
        self.orig_termios = t;

        // Set true raw mode - disable everything
        // Input: no break processing, no CR-NL, no parity, no strip, no flow control
        t.c_iflag &= ~@as(c_uint, c.IGNBRK | c.BRKINT | c.PARMRK | c.ISTRIP |
            c.INLCR | c.IGNCR | c.ICRNL | c.IXON);

        // Output: no post-processing
        t.c_oflag &= ~@as(c_uint, c.OPOST);

        // Local: no echo, no canonical, no signals, no extended
        t.c_lflag &= ~@as(c_uint, c.ECHO | c.ECHONL | c.ICANON | c.ISIG | c.IEXTEN);

        // Control: 8-bit characters
        t.c_cflag &= ~@as(c_uint, c.CSIZE | c.PARENB);
        t.c_cflag |= c.CS8;

        // Non-blocking read
        t.c_cc[c.VMIN] = 0;
        t.c_cc[c.VTIME] = 0;

        // Apply immediately
        if (c.tcsetattr(self.tty_fd, c.TCSANOW, &t) < 0) return false;

        // Flush any pending input
        _ = c.tcflush(self.tty_fd, c.TCIFLUSH);

        return true;
    }

    /// Set terminal to raw mode for keyboard input (legacy, kept for compatibility)
    fn setRawMode(self: *Self) bool {
        return self.setTrueRawMode();
    }

    /// Restore original terminal mode
    fn restoreMode(self: *Self) void {
        if (self.tty_fd >= 0 and self.orig_termios != null) {
            _ = c.tcsetattr(self.tty_fd, c.TCSANOW, &self.orig_termios.?);
        }
    }

    /// Restore original VT console keyboard mode
    fn restoreKbMode(self: *Self) void {
        // No longer using KDSKBMODE, so nothing to restore
        // Direct keyboard devices don't require mode restoration
        _ = self;
    }

    /// Cleanup and close all input devices
    pub fn deinit(self: *Self) void {
        // Restore terminal/keyboard modes before closing
        self.restoreMode();
        self.restoreKbMode();

        // Clean up libinput context
        if (self.libinput_ctx != null) {
            _ = c.libinput_unref(self.libinput_ctx);
            self.libinput_ctx = null;
        }
        if (self.udev_ctx != null) {
            _ = c.udev_unref(self.udev_ctx);
            self.udev_ctx = null;
        }

        if (self.mouse_fd >= 0) {
            posix.close(self.mouse_fd);
        }
        if (self.tty_fd >= 0) {
            posix.close(self.tty_fd);
        }
        if (self.evdev_keyboard_fd >= 0) {
            posix.close(self.evdev_keyboard_fd);
        }
        if (self.console_fd >= 0) {
            posix.close(self.console_fd);
        }
        self.allocator.destroy(self);
    }

    /// Update screen dimensions (for mouse clamping)
    pub fn setScreenSize(self: *Self, width: u32, height: u32) void {
        self.screen_width = width;
        self.screen_height = height;
        self.mouse_x = @max(0, @min(self.mouse_x, @as(i32, @intCast(width)) - 1));
        self.mouse_y = @max(0, @min(self.mouse_y, @as(i32, @intCast(height)) - 1));
    }

    /// Poll for input events and fill event queues
    pub fn poll(self: *Self) bool {
        self.key_event_count = 0;
        self.mouse_event_count = 0;

        self.pollMouse();
        self.pollKeyboard();

        return true;
    }

    /// Poll sysmouse for mouse events
    fn pollMouse(self: *Self) void {
        if (self.mouse_fd < 0) return;

        var buf: [64]u8 = undefined;
        while (true) {
            const n = posix.read(self.mouse_fd, &buf) catch break;
            if (n == 0) break;

            // Process bytes through packet state machine
            for (buf[0..n]) |byte| {
                self.processSysmouseByte(byte);
            }
        }
    }

    /// Process a single byte from sysmouse (MouseSystems protocol)
    fn processSysmouseByte(self: *Self, byte: u8) void {
        if (self.mouse_buf_len == 0) {
            if ((byte & 0xF8) == 0x80) {
                self.mouse_buf[0] = byte;
                self.mouse_buf_len = 1;
            }
            return;
        }

        self.mouse_buf[self.mouse_buf_len] = byte;
        self.mouse_buf_len += 1;

        if (self.mouse_buf_len >= 5) {
            self.processMousePacket();
            self.mouse_buf_len = 0;
        }
    }

    /// Process a complete 5-byte sysmouse packet
    fn processMousePacket(self: *Self) void {
        const status = self.mouse_buf[0];
        const dx1: i32 = @as(i32, @as(i8, @bitCast(self.mouse_buf[1])));
        const dy1: i32 = @as(i32, @as(i8, @bitCast(self.mouse_buf[2])));
        const dx2: i32 = @as(i32, @as(i8, @bitCast(self.mouse_buf[3])));
        const dy2: i32 = @as(i32, @as(i8, @bitCast(self.mouse_buf[4])));

        const dx = dx1 + dx2;
        const dy = dy1 + dy2;

        self.mouse_x = @max(0, @min(self.mouse_x + dx, @as(i32, @intCast(self.screen_width)) - 1));
        self.mouse_y = @max(0, @min(self.mouse_y - dy, @as(i32, @intCast(self.screen_height)) - 1));

        const new_buttons: u8 = (~status) & 0x07;
        const changed = self.mouse_buttons ^ new_buttons;

        if (changed != 0) {
            if (changed & MOUSE_LEFT != 0) {
                self.queueMouseEvent(.left, if (new_buttons & MOUSE_LEFT != 0) .press else .release);
            }
            if (changed & MOUSE_MIDDLE != 0) {
                self.queueMouseEvent(.middle, if (new_buttons & MOUSE_MIDDLE != 0) .press else .release);
            }
            if (changed & MOUSE_RIGHT != 0) {
                self.queueMouseEvent(.right, if (new_buttons & MOUSE_RIGHT != 0) .press else .release);
            }
            self.mouse_buttons = new_buttons;
        }

        if (dx != 0 or dy != 0) {
            self.queueMouseEvent(.left, .motion);
        }
    }

    /// Queue a mouse event
    fn queueMouseEvent(self: *Self, button: backend.MouseButton, event_type: backend.MouseEventType) void {
        if (self.mouse_event_count >= backend.MAX_MOUSE_EVENTS) return;

        self.mouse_events[self.mouse_event_count] = .{
            .x = self.mouse_x,
            .y = self.mouse_y,
            .button = button,
            .event_type = event_type,
            .modifiers = self.modifiers,
        };
        self.mouse_event_count += 1;
    }

    /// Poll keyboard for key events based on current keyboard mode
    fn pollKeyboard(self: *Self) void {
        switch (self.keyboard_mode) {
            .libinput => self.pollLibinputKeyboard(),
            .evdev => self.pollEvdevKeyboard(),
            .vt_raw => self.pollVtKeyboard(),
            .tty_raw => self.pollTtyKeyboard(),
            .none => {},
        }
    }

    /// Poll libinput for keyboard events
    fn pollLibinputKeyboard(self: *Self) void {
        if (self.libinput_ctx == null) return;

        // Dispatch any pending events
        _ = c.libinput_dispatch(self.libinput_ctx);

        // Process all available events
        while (c.libinput_get_event(self.libinput_ctx)) |event| {
            const event_type = c.libinput_event_get_type(event);

            switch (event_type) {
                c.LIBINPUT_EVENT_KEYBOARD_KEY => {
                    const kb_event = c.libinput_event_get_keyboard_event(event);
                    if (kb_event != null) {
                        const key_code = c.libinput_event_keyboard_get_key(kb_event);
                        const key_state = c.libinput_event_keyboard_get_key_state(kb_event);
                        const pressed = key_state == c.LIBINPUT_KEY_STATE_PRESSED;

                        // Update modifier state
                        self.updateModifiers(@intCast(key_code), pressed);

                        // Queue key event
                        self.queueKeyEvent(key_code, pressed);
                        log.debug("libinput key: code={} {s} modifiers=0x{x:0>2}", .{
                            key_code,
                            if (pressed) "pressed" else "released",
                            self.modifiers,
                        });
                    }
                },
                c.LIBINPUT_EVENT_POINTER_MOTION => {
                    const ptr_event = c.libinput_event_get_pointer_event(event);
                    if (ptr_event != null) {
                        const dx: i32 = @intFromFloat(c.libinput_event_pointer_get_dx(ptr_event));
                        const dy: i32 = @intFromFloat(c.libinput_event_pointer_get_dy(ptr_event));

                        self.mouse_x = @max(0, @min(self.mouse_x + dx, @as(i32, @intCast(self.screen_width)) - 1));
                        self.mouse_y = @max(0, @min(self.mouse_y + dy, @as(i32, @intCast(self.screen_height)) - 1));

                        self.queueMouseEvent(.left, .motion);
                    }
                },
                c.LIBINPUT_EVENT_POINTER_BUTTON => {
                    const ptr_event = c.libinput_event_get_pointer_event(event);
                    if (ptr_event != null) {
                        const button_code = c.libinput_event_pointer_get_button(ptr_event);
                        const button_state = c.libinput_event_pointer_get_button_state(ptr_event);
                        const pressed = button_state == c.LIBINPUT_BUTTON_STATE_PRESSED;

                        // Map libinput button codes to our button enum
                        // BTN_LEFT = 0x110, BTN_RIGHT = 0x111, BTN_MIDDLE = 0x112
                        const button: backend.MouseButton = switch (button_code) {
                            0x110 => .left,
                            0x111 => .right,
                            0x112 => .middle,
                            else => .left,
                        };

                        self.queueMouseEvent(button, if (pressed) .press else .release);
                    }
                },
                else => {},
            }

            c.libinput_event_destroy(event);
        }
    }

    /// Poll evdev keyboard device
    fn pollEvdevKeyboard(self: *Self) void {
        if (self.evdev_keyboard_fd < 0) return;

        var events: [16]InputEvent = undefined;
        const event_size = @sizeOf(InputEvent);

        while (true) {
            const buf_ptr: [*]u8 = @ptrCast(&events);
            const buf_slice = buf_ptr[0 .. events.len * event_size];
            const n = posix.read(self.evdev_keyboard_fd, buf_slice) catch break;
            if (n == 0) break;

            const num_events = n / event_size;
            for (events[0..num_events]) |ev| {
                if (ev.type == EV_KEY) {
                    // Update modifier state
                    self.updateModifiers(ev.code, ev.value != 0);

                    // Queue key event (value: 0=release, 1=press, 2=repeat)
                    if (ev.value == 1) { // Press only
                        self.queueKeyEvent(ev.code, true);
                        log.debug("evdev key: code={} pressed modifiers=0x{x:0>2}", .{ ev.code, self.modifiers });
                    } else if (ev.value == 0) { // Release
                        self.queueKeyEvent(ev.code, false);
                    }
                }
            }
        }
    }

    /// Poll VT console for raw keycodes
    fn pollVtKeyboard(self: *Self) void {
        if (self.console_fd < 0) return;

        var buf: [64]u8 = undefined;
        while (true) {
            const n = posix.read(self.console_fd, &buf) catch break;
            if (n == 0) break;

            for (buf[0..n]) |scancode| {
                self.processVtScancode(scancode);
            }
        }
    }

    /// Process a VT console scancode (K_CODE mode)
    fn processVtScancode(self: *Self, scancode: u8) void {
        // In K_CODE mode, the high bit indicates release (0x80)
        const released = (scancode & 0x80) != 0;
        const code = scancode & 0x7F;

        // Convert AT/XT scancode to evdev keycode
        const evdev_code = self.scancodeToEvdev(code);
        if (evdev_code == 0) return;

        // Update modifier state
        self.updateModifiers(@intCast(evdev_code), !released);

        // Queue key event
        self.queueKeyEvent(evdev_code, !released);

        log.debug("VT scancode: 0x{x:0>2} -> evdev {} {s} modifiers=0x{x:0>2}", .{
            scancode,
            evdev_code,
            if (released) "released" else "pressed",
            self.modifiers,
        });
    }

    /// Convert AT/XT scancode to evdev keycode
    fn scancodeToEvdev(self: *Self, scancode: u8) u32 {
        _ = self;
        // Standard AT set 1 scancode to evdev keycode mapping
        // These map the basic PC keyboard scancodes to Linux evdev codes
        return switch (scancode) {
            0x01 => 1, // ESC
            0x02 => 2, // 1
            0x03 => 3, // 2
            0x04 => 4, // 3
            0x05 => 5, // 4
            0x06 => 6, // 5
            0x07 => 7, // 6
            0x08 => 8, // 7
            0x09 => 9, // 8
            0x0A => 10, // 9
            0x0B => 11, // 0
            0x0C => 12, // -
            0x0D => 13, // =
            0x0E => 14, // Backspace
            0x0F => 15, // Tab
            0x10 => 16, // Q
            0x11 => 17, // W
            0x12 => 18, // E
            0x13 => 19, // R
            0x14 => 20, // T
            0x15 => 21, // Y
            0x16 => 22, // U
            0x17 => 23, // I
            0x18 => 24, // O
            0x19 => 25, // P
            0x1A => 26, // [
            0x1B => 27, // ]
            0x1C => 28, // Enter
            0x1D => 29, // Left Ctrl
            0x1E => 30, // A
            0x1F => 31, // S
            0x20 => 32, // D
            0x21 => 33, // F
            0x22 => 34, // G
            0x23 => 35, // H
            0x24 => 36, // J
            0x25 => 37, // K
            0x26 => 38, // L
            0x27 => 39, // ;
            0x28 => 40, // '
            0x29 => 41, // `
            0x2A => 42, // Left Shift
            0x2B => 43, // \
            0x2C => 44, // Z
            0x2D => 45, // X
            0x2E => 46, // C
            0x2F => 47, // V
            0x30 => 48, // B
            0x31 => 49, // N
            0x32 => 50, // M
            0x33 => 51, // ,
            0x34 => 52, // .
            0x35 => 53, // /
            0x36 => 54, // Right Shift
            0x37 => 55, // Keypad *
            0x38 => 56, // Left Alt
            0x39 => 57, // Space
            0x3A => 58, // Caps Lock
            0x3B => 59, // F1
            0x3C => 60, // F2
            0x3D => 61, // F3
            0x3E => 62, // F4
            0x3F => 63, // F5
            0x40 => 64, // F6
            0x41 => 65, // F7
            0x42 => 66, // F8
            0x43 => 67, // F9
            0x44 => 68, // F10
            0x45 => 69, // Num Lock
            0x46 => 70, // Scroll Lock
            0x47 => 71, // Keypad 7 / Home
            0x48 => 72, // Keypad 8 / Up
            0x49 => 73, // Keypad 9 / PgUp
            0x4A => 74, // Keypad -
            0x4B => 75, // Keypad 4 / Left
            0x4C => 76, // Keypad 5
            0x4D => 77, // Keypad 6 / Right
            0x4E => 78, // Keypad +
            0x4F => 79, // Keypad 1 / End
            0x50 => 80, // Keypad 2 / Down
            0x51 => 81, // Keypad 3 / PgDn
            0x52 => 82, // Keypad 0 / Ins
            0x53 => 83, // Keypad . / Del
            0x57 => 87, // F11
            0x58 => 88, // F12
            else => 0, // Unknown
        };
    }

    /// Update modifier key state
    fn updateModifiers(self: *Self, code: u16, pressed: bool) void {
        switch (code) {
            42, 54 => { // Left/Right Shift
                self.shift_pressed = pressed;
                if (pressed) self.modifiers |= 0x01 else self.modifiers &= ~@as(u8, 0x01);
            },
            56 => { // Left Alt
                self.alt_pressed = pressed;
                if (pressed) self.modifiers |= 0x02 else self.modifiers &= ~@as(u8, 0x02);
            },
            29 => { // Left Ctrl
                self.ctrl_pressed = pressed;
                if (pressed) self.modifiers |= 0x04 else self.modifiers &= ~@as(u8, 0x04);
            },
            else => {},
        }
    }

    /// Poll /dev/tty for keyboard input (fallback cooked mode)
    fn pollTtyKeyboard(self: *Self) void {
        if (self.tty_fd < 0) return;

        var buf: [64]u8 = undefined;
        while (true) {
            const n = posix.read(self.tty_fd, &buf) catch break;
            if (n == 0) break;

            for (buf[0..n]) |byte| {
                self.processKeyByte(byte);
            }
        }

        // Check for escape sequence timeout
        self.checkEscapeTimeout();
    }

    /// Process a byte from keyboard input
    fn processKeyByte(self: *Self, byte: u8) void {
        const now = std.time.milliTimestamp();

        // Handle escape sequences
        if (self.esc_buf_len > 0) {
            // Check for timeout (50ms)
            if (now - self.esc_timeout > 50) {
                // Timeout - emit escape and reset
                self.queueKeyEvent(1, true); // ESC key (evdev code 1)
                self.esc_buf_len = 0;
            }
        }

        if (byte == 0x1B) { // ESC
            if (self.esc_buf_len == 0) {
                self.esc_buf[0] = byte;
                self.esc_buf_len = 1;
                self.esc_timeout = now;
                return;
            }
        }

        if (self.esc_buf_len > 0) {
            if (self.esc_buf_len < self.esc_buf.len) {
                self.esc_buf[self.esc_buf_len] = byte;
                self.esc_buf_len += 1;
            }

            // Try to parse escape sequence
            if (self.parseEscapeSequence()) {
                self.esc_buf_len = 0;
            }
            return;
        }

        // Regular key - convert to key code and queue
        // Save current modifiers - byteToKeyCode may modify them for shifted chars
        const saved_modifiers = self.modifiers;
        const key_code = self.byteToKeyCode(byte);
        if (key_code != 0) {
            self.queueKeyEvent(key_code, true);
            log.debug("keyboard input: byte=0x{x:0>2} -> key_code={} modifiers=0x{x:0>2}", .{
                byte,
                key_code,
                self.modifiers,
            });
        }
        // Restore modifiers - the modifier flags set by byteToKeyCode are
        // only for that specific key event, not persistent state
        self.modifiers = saved_modifiers;
    }

    /// Check for escape sequence timeout
    fn checkEscapeTimeout(self: *Self) void {
        if (self.esc_buf_len > 0) {
            const now = std.time.milliTimestamp();
            if (now - self.esc_timeout > 50) {
                // Timeout - emit escape and clear buffer
                if (self.esc_buf_len == 1) {
                    self.queueKeyEvent(1, true); // ESC key code
                }
                self.esc_buf_len = 0;
            }
        }
    }

    /// Parse ANSI escape sequences and emit key events
    fn parseEscapeSequence(self: *Self) bool {
        if (self.esc_buf_len < 2) return false;

        // CSI sequences: ESC [
        if (self.esc_buf[1] == '[') {
            if (self.esc_buf_len < 3) return false;

            const final_byte = self.esc_buf[self.esc_buf_len - 1];

            // Arrow keys: ESC [ A/B/C/D
            switch (final_byte) {
                'A' => { self.queueKeyEvent(103, true); return true; }, // Up
                'B' => { self.queueKeyEvent(108, true); return true; }, // Down
                'C' => { self.queueKeyEvent(106, true); return true; }, // Right
                'D' => { self.queueKeyEvent(105, true); return true; }, // Left
                'H' => { self.queueKeyEvent(102, true); return true; }, // Home
                'F' => { self.queueKeyEvent(107, true); return true; }, // End
                '~' => {
                    // Extended keys: ESC [ n ~
                    if (self.esc_buf_len >= 4) {
                        const num = self.esc_buf[2];
                        switch (num) {
                            '1' => { self.queueKeyEvent(102, true); return true; }, // Home
                            '2' => { self.queueKeyEvent(110, true); return true; }, // Insert
                            '3' => { self.queueKeyEvent(111, true); return true; }, // Delete
                            '4' => { self.queueKeyEvent(107, true); return true; }, // End
                            '5' => { self.queueKeyEvent(104, true); return true; }, // PgUp
                            '6' => { self.queueKeyEvent(109, true); return true; }, // PgDn
                            else => {},
                        }
                    }
                    return true;
                },
                else => {},
            }

            // If we have a complete-ish sequence, consume it
            if (final_byte >= 0x40 and final_byte <= 0x7E) {
                return true;
            }

            return false;
        }

        // SS3 sequences: ESC O (for F1-F4 on some terminals)
        if (self.esc_buf[1] == 'O') {
            if (self.esc_buf_len < 3) return false;

            switch (self.esc_buf[2]) {
                'P' => { self.queueKeyEvent(59, true); return true; }, // F1
                'Q' => { self.queueKeyEvent(60, true); return true; }, // F2
                'R' => { self.queueKeyEvent(61, true); return true; }, // F3
                'S' => { self.queueKeyEvent(62, true); return true; }, // F4
                else => return true,
            }
        }

        // Alt+key: ESC followed by printable char
        if (self.esc_buf_len == 2 and self.esc_buf[1] >= 0x20) {
            self.modifiers |= 0x02; // Alt
            const key_code = self.byteToKeyCode(self.esc_buf[1]);
            self.queueKeyEvent(key_code, true);
            self.modifiers &= ~@as(u8, 0x02);
            return true;
        }

        return false;
    }

    /// Convert ASCII byte to evdev key code
    /// This maps ASCII characters to Linux evdev key codes for compatibility
    /// with the application layer which expects evdev codes
    fn byteToKeyCode(self: *Self, byte: u8) u32 {
        // Control characters
        if (byte < 32) {
            // Set ctrl modifier for Ctrl+letter combinations
            if (byte >= 1 and byte <= 26) {
                self.modifiers |= 0x04; // CTRL modifier
            }
            return switch (byte) {
                0x01 => 30, // Ctrl+A -> A
                0x02 => 48, // Ctrl+B -> B
                0x03 => 46, // Ctrl+C -> C
                0x04 => 32, // Ctrl+D -> D
                0x05 => 18, // Ctrl+E -> E
                0x06 => 33, // Ctrl+F -> F
                0x07 => 34, // Ctrl+G -> G
                0x08 => 14, // Backspace
                0x09 => 15, // Tab
                0x0A, 0x0D => 28, // Enter
                0x0B => 37, // Ctrl+K -> K
                0x0C => 38, // Ctrl+L -> L
                0x0E => 49, // Ctrl+N -> N
                0x0F => 24, // Ctrl+O -> O
                0x10 => 25, // Ctrl+P -> P
                0x11 => 16, // Ctrl+Q -> Q
                0x12 => 19, // Ctrl+R -> R
                0x13 => 31, // Ctrl+S -> S
                0x14 => 20, // Ctrl+T -> T
                0x15 => 22, // Ctrl+U -> U
                0x16 => 47, // Ctrl+V -> V
                0x17 => 17, // Ctrl+W -> W
                0x18 => 45, // Ctrl+X -> X
                0x19 => 21, // Ctrl+Y -> Y
                0x1A => 44, // Ctrl+Z -> Z
                0x1B => 1,  // ESC
                else => 0,  // Unknown control character
            };
        }

        // Space
        if (byte == ' ') return 57;

        // Numbers 0-9 (ASCII 48-57 -> evdev 11, 2-10)
        if (byte >= '0' and byte <= '9') {
            if (byte == '0') return 11;
            return @as(u32, byte - '0') + 1; // '1'->2, '2'->3, ..., '9'->10
        }

        // Lowercase letters a-z (ASCII 97-122 -> evdev key codes)
        if (byte >= 'a' and byte <= 'z') {
            return switch (byte) {
                'a' => 30, 'b' => 48, 'c' => 46, 'd' => 32, 'e' => 18,
                'f' => 33, 'g' => 34, 'h' => 35, 'i' => 23, 'j' => 36,
                'k' => 37, 'l' => 38, 'm' => 50, 'n' => 49, 'o' => 24,
                'p' => 25, 'q' => 16, 'r' => 19, 's' => 31, 't' => 20,
                'u' => 22, 'v' => 47, 'w' => 17, 'x' => 45, 'y' => 21,
                'z' => 44,
                else => 0,
            };
        }

        // Uppercase letters A-Z (ASCII 65-90 -> evdev + shift modifier)
        if (byte >= 'A' and byte <= 'Z') {
            self.modifiers |= 0x01; // SHIFT modifier
            return switch (byte) {
                'A' => 30, 'B' => 48, 'C' => 46, 'D' => 32, 'E' => 18,
                'F' => 33, 'G' => 34, 'H' => 35, 'I' => 23, 'J' => 36,
                'K' => 37, 'L' => 38, 'M' => 50, 'N' => 49, 'O' => 24,
                'P' => 25, 'Q' => 16, 'R' => 19, 'S' => 31, 'T' => 20,
                'U' => 22, 'V' => 47, 'W' => 17, 'X' => 45, 'Y' => 21,
                'Z' => 44,
                else => 0,
            };
        }

        // Punctuation and symbols (unshifted versions)
        return switch (byte) {
            '-' => 12,  // MINUS
            '=' => 13,  // EQUAL
            '[' => 26,  // LEFTBRACE
            ']' => 27,  // RIGHTBRACE
            ';' => 39,  // SEMICOLON
            '\'' => 40, // APOSTROPHE
            '`' => 41,  // GRAVE
            '\\' => 43, // BACKSLASH
            ',' => 51,  // COMMA
            '.' => 52,  // DOT
            '/' => 53,  // SLASH
            // Shifted symbols - set shift modifier and return base key
            '!' => blk: { self.modifiers |= 0x01; break :blk 2; },   // Shift+1
            '@' => blk: { self.modifiers |= 0x01; break :blk 3; },   // Shift+2
            '#' => blk: { self.modifiers |= 0x01; break :blk 4; },   // Shift+3
            '$' => blk: { self.modifiers |= 0x01; break :blk 5; },   // Shift+4
            '%' => blk: { self.modifiers |= 0x01; break :blk 6; },   // Shift+5
            '^' => blk: { self.modifiers |= 0x01; break :blk 7; },   // Shift+6
            '&' => blk: { self.modifiers |= 0x01; break :blk 8; },   // Shift+7
            '*' => blk: { self.modifiers |= 0x01; break :blk 9; },   // Shift+8
            '(' => blk: { self.modifiers |= 0x01; break :blk 10; },  // Shift+9
            ')' => blk: { self.modifiers |= 0x01; break :blk 11; },  // Shift+0
            '_' => blk: { self.modifiers |= 0x01; break :blk 12; },  // Shift+MINUS
            '+' => blk: { self.modifiers |= 0x01; break :blk 13; },  // Shift+EQUAL
            '{' => blk: { self.modifiers |= 0x01; break :blk 26; },  // Shift+LEFTBRACE
            '}' => blk: { self.modifiers |= 0x01; break :blk 27; },  // Shift+RIGHTBRACE
            ':' => blk: { self.modifiers |= 0x01; break :blk 39; },  // Shift+SEMICOLON
            '"' => blk: { self.modifiers |= 0x01; break :blk 40; },  // Shift+APOSTROPHE
            '~' => blk: { self.modifiers |= 0x01; break :blk 41; },  // Shift+GRAVE
            '|' => blk: { self.modifiers |= 0x01; break :blk 43; },  // Shift+BACKSLASH
            '<' => blk: { self.modifiers |= 0x01; break :blk 51; },  // Shift+COMMA
            '>' => blk: { self.modifiers |= 0x01; break :blk 52; },  // Shift+DOT
            '?' => blk: { self.modifiers |= 0x01; break :blk 53; },  // Shift+SLASH
            0x7F => 14, // DEL -> Backspace
            else => 0,  // Unknown character
        };
    }

    /// Queue a key event
    fn queueKeyEvent(self: *Self, key_code: u32, pressed: bool) void {
        if (self.key_event_count >= backend.MAX_KEY_EVENTS) return;

        self.key_events[self.key_event_count] = .{
            .key_code = key_code,
            .modifiers = self.modifiers,
            .pressed = pressed,
        };
        self.key_event_count += 1;
    }

    /// Get queued key events (clears queue)
    pub fn getKeyEvents(self: *Self) []const backend.KeyEvent {
        const count = self.key_event_count;
        self.key_event_count = 0;
        return self.key_events[0..count];
    }

    /// Get queued mouse events (clears queue)
    pub fn getMouseEvents(self: *Self) []const backend.MouseEvent {
        const count = self.mouse_event_count;
        self.mouse_event_count = 0;
        return self.mouse_events[0..count];
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "BsdInput struct size" {
    try std.testing.expect(@sizeOf(BsdInput) > 0);
}

test "KeyboardMode enum" {
    try std.testing.expect(@intFromEnum(KeyboardMode.none) == 0);
    try std.testing.expect(@intFromEnum(KeyboardMode.libinput) == 1);
    try std.testing.expect(@intFromEnum(KeyboardMode.evdev) == 2);
    try std.testing.expect(@intFromEnum(KeyboardMode.vt_raw) == 3);
    try std.testing.expect(@intFromEnum(KeyboardMode.tty_raw) == 4);
}

test "EVIOCGNAME ioctl encoding" {
    // EVIOCGNAME(256) should produce a specific value
    const result = EVIOCGNAME(256);
    // Check it has the read bit set (0x80000000) and 'E' magic
    try std.testing.expect((result & 0x80000000) != 0);
    try std.testing.expect(((result >> 8) & 0xFF) == 'E');
    try std.testing.expect((result & 0xFF) == 0x06);
}

test "EVIOCGBIT ioctl encoding" {
    // EVIOCGBIT(0, 4) for event types
    const result = EVIOCGBIT(0, 4);
    try std.testing.expect((result & 0x80000000) != 0);
    try std.testing.expect(((result >> 8) & 0xFF) == 'E');
    try std.testing.expect((result & 0xFF) == 0x20); // 0x20 + 0

    // EVIOCGBIT(EV_KEY, 96) for key bits
    const key_result = EVIOCGBIT(EV_KEY, 96);
    try std.testing.expect((key_result & 0xFF) == 0x21); // 0x20 + 1
}

test "evdev event types" {
    try std.testing.expect(EV_KEY == 0x01);
    try std.testing.expect(EV_REL == 0x02);
    try std.testing.expect(EV_ABS == 0x03);
}

test "InputEvent struct layout" {
    // Verify InputEvent matches evdev input_event structure
    try std.testing.expect(@sizeOf(InputEvent) == @sizeOf(isize) * 2 + 8);
    try std.testing.expect(@offsetOf(InputEvent, "type") == @sizeOf(isize) * 2);
    try std.testing.expect(@offsetOf(InputEvent, "code") == @sizeOf(isize) * 2 + 2);
    try std.testing.expect(@offsetOf(InputEvent, "value") == @sizeOf(isize) * 2 + 4);
}

test "keyboard mode constants" {
    try std.testing.expect(K_RAW == 0);
    try std.testing.expect(K_XLATE == 1);
    try std.testing.expect(K_CODE == 2);
}
