const std = @import("std");
const posix = std.posix;
const backend = @import("backend");

const log = std.log.scoped(.evdev_input);

// ============================================================================
// Linux evdev input support
// ============================================================================

/// Linux input event structure (from linux/input.h)
pub const input_event = extern struct {
    time: extern struct {
        tv_sec: isize,
        tv_usec: isize,
    },
    type: u16,
    code: u16,
    value: i32,
};

/// Event types
pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const EV_ABS: u16 = 0x03;

/// Relative axis codes
pub const REL_X: u16 = 0x00;
pub const REL_Y: u16 = 0x01;
pub const REL_WHEEL: u16 = 0x08;
pub const REL_HWHEEL: u16 = 0x06;

/// Key codes for mouse buttons
pub const BTN_LEFT: u16 = 0x110;
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;
pub const BTN_SIDE: u16 = 0x113;
pub const BTN_EXTRA: u16 = 0x114;

/// Modifier key codes
pub const KEY_LEFTSHIFT: u16 = 42;
pub const KEY_RIGHTSHIFT: u16 = 54;
pub const KEY_LEFTCTRL: u16 = 29;
pub const KEY_RIGHTCTRL: u16 = 97;
pub const KEY_LEFTALT: u16 = 56;
pub const KEY_RIGHTALT: u16 = 100;
pub const KEY_LEFTMETA: u16 = 125;
pub const KEY_RIGHTMETA: u16 = 126;

/// EVIOCGBIT ioctl for checking device capabilities
pub fn EVIOCGBIT(ev: u8, len: u13) u32 {
    // _IOC(_IOC_READ, 'E', 0x20 + ev, len)
    return 0x80000000 | (@as(u32, len) << 16) | (@as(u32, 'E') << 8) | (0x20 + @as(u32, ev));
}

/// Check if a bit is set in a byte array
pub fn testBit(bit: usize, array: []const u8) bool {
    const byte_idx = bit / 8;
    if (byte_idx >= array.len) return false;
    const bit_idx: u3 = @intCast(bit % 8);
    return (array[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

/// Input device types we care about
pub const InputDeviceType = enum {
    keyboard,
    mouse,
    unknown,
};

/// Maximum number of input devices to track
pub const MAX_INPUT_DEVICES = 8;

/// Evdev input handler - manages keyboard and mouse input from /dev/input/event*
pub const EvdevInput = struct {
    allocator: std.mem.Allocator,

    // Input device file descriptors
    input_fds: [MAX_INPUT_DEVICES]posix.fd_t,
    input_types: [MAX_INPUT_DEVICES]InputDeviceType,
    input_count: usize,

    // Mouse state
    mouse_x: i32,
    mouse_y: i32,
    mouse_buttons: u8, // Bit flags: 0=left, 1=middle, 2=right
    screen_width: u32,
    screen_height: u32,

    // Modifier key state
    modifiers: u8, // Bit flags: 0=shift, 1=alt, 2=ctrl, 3=meta

    // Event queues
    key_events: [backend.MAX_KEY_EVENTS]backend.KeyEvent,
    key_event_count: usize,
    mouse_events: [backend.MAX_MOUSE_EVENTS]backend.MouseEvent,
    mouse_event_count: usize,

    const Self = @This();

    /// Initialize evdev input handler
    pub fn init(allocator: std.mem.Allocator, screen_width: u32, screen_height: u32) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .input_fds = [_]posix.fd_t{-1} ** MAX_INPUT_DEVICES,
            .input_types = [_]InputDeviceType{.unknown} ** MAX_INPUT_DEVICES,
            .input_count = 0,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_buttons = 0,
            .screen_width = screen_width,
            .screen_height = screen_height,
            .modifiers = 0,
            .key_events = undefined,
            .key_event_count = 0,
            .mouse_events = undefined,
            .mouse_event_count = 0,
        };

        // Scan and open input devices
        self.scanInputDevices();

        return self;
    }

    /// Cleanup and close all input devices
    pub fn deinit(self: *Self) void {
        for (self.input_fds[0..self.input_count]) |fd| {
            if (fd >= 0) {
                posix.close(fd);
            }
        }
        self.allocator.destroy(self);
    }

    /// Update screen dimensions (for mouse clamping)
    pub fn setScreenSize(self: *Self, width: u32, height: u32) void {
        self.screen_width = width;
        self.screen_height = height;
        // Clamp current mouse position to new bounds
        self.mouse_x = @max(0, @min(self.mouse_x, @as(i32, @intCast(width)) - 1));
        self.mouse_y = @max(0, @min(self.mouse_y, @as(i32, @intCast(height)) - 1));
    }

    /// Scan and open available input devices
    fn scanInputDevices(self: *Self) void {
        log.debug("scanning for input devices in /dev/input/event*", .{});
        var devices_found: usize = 0;
        var keyboards_found: usize = 0;
        var mice_found: usize = 0;

        // Scan /dev/input/event* for keyboards and mice
        var i: usize = 0;
        while (i < 32 and self.input_count < MAX_INPUT_DEVICES) : (i += 1) {
            var path_buf: [32:0]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/input/event{}", .{i}) catch continue;

            const fd = posix.open(
                path,
                .{ .ACCMODE = .RDONLY, .NONBLOCK = true },
                0,
            ) catch |err| {
                // Only log permission errors as these are actionable
                if (err == error.AccessDenied) {
                    log.debug("cannot open /dev/input/event{}: permission denied", .{i});
                }
                continue;
            };

            devices_found += 1;
            const dev_type = detectDeviceType(fd);
            if (dev_type == .unknown) {
                posix.close(fd);
                continue;
            }

            self.input_fds[self.input_count] = fd;
            self.input_types[self.input_count] = dev_type;
            self.input_count += 1;

            switch (dev_type) {
                .keyboard => keyboards_found += 1,
                .mouse => mice_found += 1,
                .unknown => {},
            }

            log.info("opened input device /dev/input/event{} as {s}", .{
                i,
                @tagName(dev_type),
            });
        }

        log.info("input scan complete: {} devices checked, {} keyboards, {} mice", .{
            devices_found,
            keyboards_found,
            mice_found,
        });

        if (self.input_count == 0) {
            log.warn("no input devices found - keyboard and mouse input disabled", .{});
            log.warn("ensure /dev/input/event* is readable (root or input group)", .{});
        } else if (keyboards_found == 0) {
            log.warn("no keyboards detected - text input will not work", .{});
            log.warn("check that your keyboard is connected and /dev/input/event* is accessible", .{});
        }
    }

    /// Poll for input events and fill event queues
    /// Returns true always (input subsystem doesn't control app lifecycle)
    pub fn poll(self: *Self) bool {
        // Clear event queues for this poll cycle
        self.key_event_count = 0;
        self.mouse_event_count = 0;

        // Track mouse motion for batching
        var mouse_dx: i32 = 0;
        var mouse_dy: i32 = 0;
        var had_motion = false;

        // Read events from all input devices
        for (self.input_fds[0..self.input_count], self.input_types[0..self.input_count]) |fd, dev_type| {
            if (fd < 0) continue;

            // Read events in a loop until EAGAIN
            while (true) {
                var ev: input_event = undefined;
                const bytes_read = posix.read(fd, std.mem.asBytes(&ev)) catch |err| {
                    if (err == error.WouldBlock) break;
                    break;
                };
                if (bytes_read != @sizeOf(input_event)) break;

                // Process event based on device type
                switch (dev_type) {
                    .keyboard => self.processKeyboardEvent(&ev),
                    .mouse => {
                        const motion = self.processMouseEvent(&ev);
                        if (motion) |delta| {
                            mouse_dx += delta[0];
                            mouse_dy += delta[1];
                            had_motion = true;
                        }
                    },
                    .unknown => {},
                }
            }
        }

        // Emit batched mouse motion event
        if (had_motion) {
            self.mouse_x = @max(0, @min(self.mouse_x + mouse_dx, @as(i32, @intCast(self.screen_width)) - 1));
            self.mouse_y = @max(0, @min(self.mouse_y + mouse_dy, @as(i32, @intCast(self.screen_height)) - 1));

            if (self.mouse_event_count < backend.MAX_MOUSE_EVENTS) {
                self.mouse_events[self.mouse_event_count] = .{
                    .x = self.mouse_x,
                    .y = self.mouse_y,
                    .button = .left, // Doesn't matter for motion
                    .event_type = .motion,
                    .modifiers = self.modifiers,
                };
                self.mouse_event_count += 1;
            }
        }

        return true;
    }

    /// Get pending key events (clears the queue)
    pub fn getKeyEvents(self: *Self) []const backend.KeyEvent {
        const count = self.key_event_count;
        self.key_event_count = 0;
        return self.key_events[0..count];
    }

    /// Get pending mouse events (clears the queue)
    pub fn getMouseEvents(self: *Self) []const backend.MouseEvent {
        const count = self.mouse_event_count;
        self.mouse_event_count = 0;
        return self.mouse_events[0..count];
    }

    /// Get current modifier state
    pub fn getModifiers(self: *Self) u8 {
        return self.modifiers;
    }

    /// Get current mouse position
    pub fn getMousePosition(self: *Self) struct { x: i32, y: i32 } {
        return .{ .x = self.mouse_x, .y = self.mouse_y };
    }

    /// Process a keyboard event
    fn processKeyboardEvent(self: *Self, ev: *const input_event) void {
        if (ev.type != EV_KEY) return;

        const pressed = ev.value != 0; // 1 = press, 0 = release, 2 = repeat

        // Update modifier state
        switch (ev.code) {
            KEY_LEFTSHIFT, KEY_RIGHTSHIFT => {
                if (pressed) self.modifiers |= 0x01 else self.modifiers &= ~@as(u8, 0x01);
            },
            KEY_LEFTALT, KEY_RIGHTALT => {
                if (pressed) self.modifiers |= 0x02 else self.modifiers &= ~@as(u8, 0x02);
            },
            KEY_LEFTCTRL, KEY_RIGHTCTRL => {
                if (pressed) self.modifiers |= 0x04 else self.modifiers &= ~@as(u8, 0x04);
            },
            KEY_LEFTMETA, KEY_RIGHTMETA => {
                if (pressed) self.modifiers |= 0x08 else self.modifiers &= ~@as(u8, 0x08);
            },
            else => {},
        }

        // Queue key event
        if (self.key_event_count < backend.MAX_KEY_EVENTS) {
            self.key_events[self.key_event_count] = .{
                .key_code = ev.code,
                .modifiers = self.modifiers,
                .pressed = pressed,
            };
            self.key_event_count += 1;
            log.debug("keyboard event: code={} pressed={} modifiers=0x{x:0>2}", .{
                ev.code,
                pressed,
                self.modifiers,
            });
        } else {
            log.warn("keyboard event queue full, dropping event code={}", .{ev.code});
        }
    }

    /// Process a mouse event, returns motion delta if any
    fn processMouseEvent(self: *Self, ev: *const input_event) ?[2]i32 {
        switch (ev.type) {
            EV_REL => {
                // Relative motion
                switch (ev.code) {
                    REL_X => return .{ ev.value, 0 },
                    REL_Y => return .{ 0, ev.value },
                    REL_WHEEL => {
                        // Scroll wheel - emit as button press/release
                        const button: backend.MouseButton = if (ev.value > 0) .scroll_up else .scroll_down;
                        if (self.mouse_event_count < backend.MAX_MOUSE_EVENTS) {
                            self.mouse_events[self.mouse_event_count] = .{
                                .x = self.mouse_x,
                                .y = self.mouse_y,
                                .button = button,
                                .event_type = .press,
                                .modifiers = self.modifiers,
                            };
                            self.mouse_event_count += 1;
                        }
                    },
                    REL_HWHEEL => {
                        // Horizontal scroll wheel
                        const button: backend.MouseButton = if (ev.value > 0) .scroll_right else .scroll_left;
                        if (self.mouse_event_count < backend.MAX_MOUSE_EVENTS) {
                            self.mouse_events[self.mouse_event_count] = .{
                                .x = self.mouse_x,
                                .y = self.mouse_y,
                                .button = button,
                                .event_type = .press,
                                .modifiers = self.modifiers,
                            };
                            self.mouse_event_count += 1;
                        }
                    },
                    else => {},
                }
            },
            EV_KEY => {
                // Mouse button
                const button: ?backend.MouseButton = switch (ev.code) {
                    BTN_LEFT => .left,
                    BTN_RIGHT => .right,
                    BTN_MIDDLE => .middle,
                    BTN_SIDE => .button4,
                    BTN_EXTRA => .button5,
                    else => null,
                };

                if (button) |btn| {
                    const pressed = ev.value != 0;
                    const event_type: backend.MouseEventType = if (pressed) .press else .release;

                    // Update button state
                    const bit: u8 = switch (btn) {
                        .left => 0x01,
                        .middle => 0x02,
                        .right => 0x04,
                        else => 0,
                    };
                    if (pressed) {
                        self.mouse_buttons |= bit;
                    } else {
                        self.mouse_buttons &= ~bit;
                    }

                    if (self.mouse_event_count < backend.MAX_MOUSE_EVENTS) {
                        self.mouse_events[self.mouse_event_count] = .{
                            .x = self.mouse_x,
                            .y = self.mouse_y,
                            .button = btn,
                            .event_type = event_type,
                            .modifiers = self.modifiers,
                        };
                        self.mouse_event_count += 1;
                    }
                }
            },
            else => {},
        }
        return null;
    }
};

/// Detect what type of input device this is
pub fn detectDeviceType(fd: posix.fd_t) InputDeviceType {
    const linux = std.os.linux;

    // Check for supported event types
    var ev_bits: [4]u8 = undefined;
    const ev_result = linux.ioctl(@intCast(fd), EVIOCGBIT(0, ev_bits.len), @intFromPtr(&ev_bits));
    if (@as(isize, @bitCast(ev_result)) < 0) {
        return .unknown;
    }

    const has_key = testBit(EV_KEY, &ev_bits);
    const has_rel = testBit(EV_REL, &ev_bits);

    // Check for keyboard FIRST - prioritize keyboards over mice for combo devices
    // Many keyboards have scroll wheels, media keys, or touchpads that would
    // otherwise cause them to be incorrectly classified as mice
    if (has_key) {
        // Check for keyboard-like keys (letters, etc.)
        var key_bits: [64]u8 = undefined;
        const key_result = linux.ioctl(@intCast(fd), EVIOCGBIT(EV_KEY, key_bits.len), @intFromPtr(&key_bits));
        if (@as(isize, @bitCast(key_result)) >= 0) {
            // Check for letter keys (KEY_Q = 16 through KEY_P = 25)
            if (testBit(16, &key_bits) and testBit(17, &key_bits)) {
                return .keyboard;
            }
        }
    }

    // Then check for mouse - only if it's NOT a keyboard
    if (has_rel) {
        // Check for mouse buttons
        var key_bits: [64]u8 = undefined;
        const key_result = linux.ioctl(@intCast(fd), EVIOCGBIT(EV_KEY, key_bits.len), @intFromPtr(&key_bits));
        if (@as(isize, @bitCast(key_result)) >= 0) {
            if (testBit(BTN_LEFT, &key_bits)) {
                return .mouse;
            }
        }
    }

    return .unknown;
}

// ============================================================================
// Tests
// ============================================================================

test "EvdevInput struct size" {
    try std.testing.expect(@sizeOf(EvdevInput) > 0);
}

test "testBit" {
    const bits = [_]u8{ 0b00000101, 0b00001000 };
    try std.testing.expect(testBit(0, &bits) == true);
    try std.testing.expect(testBit(1, &bits) == false);
    try std.testing.expect(testBit(2, &bits) == true);
    try std.testing.expect(testBit(11, &bits) == true);
}
