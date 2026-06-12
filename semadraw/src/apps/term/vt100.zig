const std = @import("std");
const screen = @import("screen");

const log = std.log.scoped(.vt100);

/// VT100/ANSI escape sequence parser with UTF-8 support
/// Processes input bytes and performs terminal operations on a Screen
pub const Parser = struct {
    state: State,
    params: [16]u32,
    param_count: u8,
    intermediate: [4]u8,
    intermediate_count: u8,
    scr: *screen.Screen,

    // UTF-8 decoding state
    utf8_buf: [4]u8,
    utf8_len: u3, // bytes collected so far
    utf8_expected: u3, // total bytes expected

    // Private mode flag (for CSI ? sequences like DECSET/DECRST)
    private_mode: bool,

    // OSC (Operating System Command) parsing state
    osc_cmd: u16, // OSC command number (0-65535)
    osc_buf: [512]u8, // OSC string data buffer
    osc_len: u16, // Current length of OSC data
    osc_in_param: bool, // True if still parsing command number
    osc_esc_seen: bool, // True if ESC was seen (for ST terminator)

    const Self = @This();

    const State = enum {
        ground,
        escape,
        escape_intermediate,
        csi_entry,
        csi_param,
        csi_intermediate,
        osc_string,
        dcs_entry,
        ignore,
        utf8, // Collecting UTF-8 continuation bytes
    };

    pub fn init(scr: *screen.Screen) Self {
        return .{
            .state = .ground,
            .params = [_]u32{0} ** 16,
            .param_count = 0,
            .intermediate = [_]u8{0} ** 4,
            .intermediate_count = 0,
            .scr = scr,
            .utf8_buf = undefined,
            .utf8_len = 0,
            .utf8_expected = 0,
            .private_mode = false,
            .osc_cmd = 0,
            .osc_buf = undefined,
            .osc_len = 0,
            .osc_in_param = true,
            .osc_esc_seen = false,
        };
    }

    /// Process a single input byte
    pub fn feed(self: *Self, c: u8) void {
        switch (self.state) {
            .ground => self.handleGround(c),
            .escape => self.handleEscape(c),
            .escape_intermediate => self.handleEscapeIntermediate(c),
            .csi_entry => self.handleCsiEntry(c),
            .csi_param => self.handleCsiParam(c),
            .csi_intermediate => self.handleCsiIntermediate(c),
            .osc_string => self.handleOscString(c),
            .dcs_entry => self.handleDcsEntry(c),
            .ignore => self.handleIgnore(c),
            .utf8 => self.handleUtf8(c),
        }
    }

    /// Process multiple bytes
    pub fn feedSlice(self: *Self, data: []const u8) void {
        for (data) |c| {
            self.feed(c);
        }
    }

    fn reset(self: *Self) void {
        self.state = .ground;
        self.params = [_]u32{0} ** 16;
        self.param_count = 0;
        self.intermediate = [_]u8{0} ** 4;
        self.intermediate_count = 0;
        self.private_mode = false;
        self.osc_cmd = 0;
        self.osc_len = 0;
        self.osc_in_param = true;
        self.osc_esc_seen = false;
    }

    fn handleGround(self: *Self, c: u8) void {
        if (c == 0x1B) {
            // ESC
            self.state = .escape;
        } else if (c < 0x20) {
            // Control character
            self.handleControl(c);
        } else if (c >= 0x20 and c < 0x7F) {
            // ASCII printable
            self.scr.putChar(c);
        } else if (c == 0x7F) {
            // DEL - ignore
        } else if (c >= 0xC0 and c < 0xE0) {
            // UTF-8 2-byte sequence start
            self.utf8_buf[0] = c;
            self.utf8_len = 1;
            self.utf8_expected = 2;
            self.state = .utf8;
        } else if (c >= 0xE0 and c < 0xF0) {
            // UTF-8 3-byte sequence start
            self.utf8_buf[0] = c;
            self.utf8_len = 1;
            self.utf8_expected = 3;
            self.state = .utf8;
        } else if (c >= 0xF0 and c < 0xF8) {
            // UTF-8 4-byte sequence start
            self.utf8_buf[0] = c;
            self.utf8_len = 1;
            self.utf8_expected = 4;
            self.state = .utf8;
        }
        // Ignore invalid UTF-8 lead bytes (0x80-0xBF, 0xF8-0xFF)
    }

    fn handleUtf8(self: *Self, c: u8) void {
        // Check for valid continuation byte
        if (c >= 0x80 and c < 0xC0) {
            self.utf8_buf[self.utf8_len] = c;
            self.utf8_len += 1;

            if (self.utf8_len == self.utf8_expected) {
                // Complete UTF-8 sequence - decode to codepoint
                if (self.decodeUtf8()) |codepoint| {
                    self.scr.putChar(codepoint);
                }
                self.state = .ground;
                self.utf8_len = 0;
            }
        } else {
            // Invalid continuation byte - abort and re-process
            self.state = .ground;
            self.utf8_len = 0;
            self.feed(c); // Re-process this byte
        }
    }

    fn decodeUtf8(self: *Self) ?u21 {
        // Defensive: caller (handleUtf8) only invokes us when
        // utf8_len == utf8_expected, but a state-machine bug or future
        // refactor could violate that. Guard explicitly so the bounds
        // check never panics: if the lengths disagree or expected is
        // out of the 2..4 range this decoder handles, return null and
        // let the caller treat the partial sequence as invalid input.
        // Bug 5 (2026-05-04) surfaced as 'index N, len M' in this
        // function under release-mode optimization; the root cause was
        // the original `buf = utf8_buf[0..utf8_len]` slice combined
        // with a switch on utf8_expected, allowing an inconsistent
        // state to dispatch into a switch arm that read past buf.len.
        if (self.utf8_expected < 2 or self.utf8_expected > 4) return null;
        if (self.utf8_len != self.utf8_expected) return null;
        const buf = self.utf8_buf[0..self.utf8_expected];
        return switch (self.utf8_expected) {
            2 => blk: {
                // 110xxxxx 10xxxxxx
                const b0: u21 = buf[0] & 0x1F;
                const b1: u21 = buf[1] & 0x3F;
                const cp = (b0 << 6) | b1;
                // Check for overlong encoding
                break :blk if (cp >= 0x80) cp else null;
            },
            3 => blk: {
                // 1110xxxx 10xxxxxx 10xxxxxx
                const b0: u21 = buf[0] & 0x0F;
                const b1: u21 = buf[1] & 0x3F;
                const b2: u21 = buf[2] & 0x3F;
                const cp = (b0 << 12) | (b1 << 6) | b2;
                // Check for overlong encoding and surrogate range
                break :blk if (cp >= 0x800 and (cp < 0xD800 or cp > 0xDFFF)) cp else null;
            },
            4 => blk: {
                // 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
                const b0: u21 = buf[0] & 0x07;
                const b1: u21 = buf[1] & 0x3F;
                const b2: u21 = buf[2] & 0x3F;
                const b3: u21 = buf[3] & 0x3F;
                const cp = (b0 << 18) | (b1 << 12) | (b2 << 6) | b3;
                // Check for overlong encoding and valid range
                break :blk if (cp >= 0x10000 and cp <= 0x10FFFF) cp else null;
            },
            else => null,
        };
    }

    fn handleControl(self: *Self, c: u8) void {
        switch (c) {
            0x07 => {}, // Bell (ignore for now)
            0x08 => self.scr.backspace(),
            0x09 => self.scr.tab(),
            0x0A, 0x0B, 0x0C => self.scr.newline(), // LF, VT, FF
            0x0D => self.scr.carriageReturn(),
            else => {
                log.debug("unhandled control char: 0x{X:0>2}", .{c});
            },
        }
    }

    fn handleEscape(self: *Self, c: u8) void {
        if (c == '[') {
            // CSI
            self.state = .csi_entry;
            self.params = [_]u32{0} ** 16;
            self.param_count = 0;
            self.intermediate = [_]u8{0} ** 4;
            self.intermediate_count = 0;
        } else if (c == ']') {
            // OSC - initialize OSC state
            self.state = .osc_string;
            self.osc_cmd = 0;
            self.osc_len = 0;
            self.osc_in_param = true;
            self.osc_esc_seen = false;
        } else if (c == 'P') {
            // DCS
            self.state = .dcs_entry;
        } else if (c >= 0x20 and c <= 0x2F) {
            // Intermediate
            self.state = .escape_intermediate;
            if (self.intermediate_count < 4) {
                self.intermediate[self.intermediate_count] = c;
                self.intermediate_count += 1;
            }
        } else if (c >= 0x30 and c <= 0x7E) {
            // Final character
            self.handleEscapeSequence(c);
            self.reset();
        } else if (c == 0x1B) {
            // Another ESC, restart
            self.state = .escape;
        } else {
            self.reset();
        }
    }

    fn handleEscapeIntermediate(self: *Self, c: u8) void {
        if (c >= 0x20 and c <= 0x2F) {
            if (self.intermediate_count < 4) {
                self.intermediate[self.intermediate_count] = c;
                self.intermediate_count += 1;
            }
        } else if (c >= 0x30 and c <= 0x7E) {
            self.handleEscapeSequence(c);
            self.reset();
        } else {
            self.reset();
        }
    }

    fn handleEscapeSequence(self: *Self, c: u8) void {
        switch (c) {
            'c' => {
                // RIS - Full reset
                self.scr.eraseScreen();
                self.scr.setCursor(0, 0);
                self.scr.current_attr = screen.Attr.default();
                self.scr.setScrollRegion(0, self.scr.rows - 1);
                self.scr.insert_mode = false;
            },
            'D' => {
                // IND - Index (move cursor down, scroll if at bottom)
                if (self.scr.cursor_row >= self.scr.scroll_bottom) {
                    self.scr.scrollUp(1);
                } else {
                    self.scr.cursorDown(1);
                }
            },
            'E' => {
                // NEL - Next line (CR + IND)
                self.scr.carriageReturn();
                if (self.scr.cursor_row >= self.scr.scroll_bottom) {
                    self.scr.scrollUp(1);
                } else {
                    self.scr.cursorDown(1);
                }
            },
            'H' => {}, // HTS - Tab set (TODO)
            'M' => {
                // RI - Reverse index (move cursor up, scroll if at top)
                if (self.scr.cursor_row <= self.scr.scroll_top) {
                    self.scr.scrollDown(1);
                } else {
                    self.scr.cursorUp(1);
                }
            },
            '7' => {
                // DECSC - Save cursor position and attributes
                self.scr.saveCursor();
            },
            '8' => {
                // DECRC - Restore cursor position and attributes
                self.scr.restoreCursor();
            },
            else => {
                log.debug("unhandled ESC sequence: ESC {c} (0x{X:0>2})", .{ c, c });
            },
        }
    }

    fn handleCsiEntry(self: *Self, c: u8) void {
        if (c == '?') {
            // Private mode indicator (for DECSET/DECRST)
            self.private_mode = true;
            self.state = .csi_param;
        } else if (c >= '0' and c <= '9') {
            self.state = .csi_param;
            self.params[0] = c - '0';
            self.param_count = 1;
        } else if (c == ';') {
            self.state = .csi_param;
            self.param_count = 1;
        } else if (c >= 0x40 and c <= 0x7E) {
            // Final character with no params
            self.executeCsi(c);
            self.reset();
        } else if (c >= 0x20 and c <= 0x2F) {
            self.state = .csi_intermediate;
            if (self.intermediate_count < 4) {
                self.intermediate[self.intermediate_count] = c;
                self.intermediate_count += 1;
            }
        } else if (c == 0x1B) {
            self.state = .escape;
        } else {
            self.reset();
        }
    }

    fn handleCsiParam(self: *Self, c: u8) void {
        if (c >= '0' and c <= '9') {
            if (self.param_count == 0) self.param_count = 1;
            // Bug 6 (2026-05-04): idx must be a valid index into
            // self.params. Cap at params.len-1 so a runaway
            // param_count cannot index out of bounds. The cap is a
            // safety net; the ';' handler below already caps growth
            // at 16, but release-mode optimization in 2026-05-04
            // testing produced a panic 'index 3, len 3' attributed
            // to this line, suggesting either a state-machine path
            // grew param_count past the cap or the panic site
            // attribution itself was wrong. Either way, clamping idx
            // here is cheap (one min op) and makes the access safe
            // by construction.
            const cap = self.params.len - 1;
            const raw_idx: usize = self.param_count - 1;
            const idx = if (raw_idx > cap) cap else raw_idx;
            self.params[idx] = self.params[idx] * 10 + (c - '0');
        } else if (c == ';') {
            if (self.param_count < 16) {
                self.param_count += 1;
            }
        } else if (c >= 0x40 and c <= 0x7E) {
            // Final character
            self.executeCsi(c);
            self.reset();
        } else if (c >= 0x20 and c <= 0x2F) {
            self.state = .csi_intermediate;
            if (self.intermediate_count < 4) {
                self.intermediate[self.intermediate_count] = c;
                self.intermediate_count += 1;
            }
        } else if (c == 0x1B) {
            self.state = .escape;
        } else {
            self.reset();
        }
    }

    fn handleCsiIntermediate(self: *Self, c: u8) void {
        if (c >= 0x20 and c <= 0x2F) {
            if (self.intermediate_count < 4) {
                self.intermediate[self.intermediate_count] = c;
                self.intermediate_count += 1;
            }
        } else if (c >= 0x40 and c <= 0x7E) {
            self.executeCsi(c);
            self.reset();
        } else {
            self.reset();
        }
    }

    fn handleOscString(self: *Self, c: u8) void {
        // Check for ST terminator after ESC
        if (self.osc_esc_seen) {
            if (c == '\\') {
                // ESC \ = ST, execute OSC and reset
                self.executeOsc();
                self.reset();
                return;
            } else {
                // ESC followed by something else - abort OSC and re-process
                self.reset();
                self.state = .escape;
                self.handleEscape(c);
                return;
            }
        }

        // Check for terminators
        if (c == 0x07) {
            // BEL terminates OSC
            self.executeOsc();
            self.reset();
            return;
        } else if (c == 0x1B) {
            // ESC - might be start of ST
            self.osc_esc_seen = true;
            return;
        }

        // Parse OSC content
        if (self.osc_in_param) {
            // Still parsing command number
            if (c >= '0' and c <= '9') {
                self.osc_cmd = self.osc_cmd * 10 + (c - '0');
            } else if (c == ';') {
                // End of command number, start of data
                self.osc_in_param = false;
            } else {
                // Invalid character in command number - abort
                self.reset();
            }
        } else {
            // Collecting data bytes
            if (self.osc_len < self.osc_buf.len) {
                self.osc_buf[self.osc_len] = c;
                self.osc_len += 1;
            }
            // If buffer full, continue consuming but ignore extra bytes
        }
    }

    fn executeOsc(self: *Self) void {
        const data = self.osc_buf[0..self.osc_len];

        switch (self.osc_cmd) {
            0 => {
                // Set icon name and window title
                self.scr.setIconName(data);
                self.scr.setTitle(data);
            },
            1 => {
                // Set icon name only
                self.scr.setIconName(data);
            },
            2 => {
                // Set window title only
                self.scr.setTitle(data);
            },
            4 => {
                // Set indexed palette color: OSC 4 ; index ; color ST
                self.parseOscPaletteColor(data);
            },
            10 => {
                // Set foreground color: OSC 10 ; color ST
                if (self.parseOscColor(data)) |rgb| {
                    self.scr.setForegroundColor(rgb.r, rgb.g, rgb.b);
                }
            },
            11 => {
                // Set background color: OSC 11 ; color ST
                if (self.parseOscColor(data)) |rgb| {
                    self.scr.setBackgroundColor(rgb.r, rgb.g, rgb.b);
                }
            },
            104 => {
                // Reset palette color(s)
                if (data.len == 0) {
                    // Reset all colors
                    self.scr.resetPalette();
                } else {
                    // Reset specific color index
                    if (self.parseDecimalNumber(data)) |idx| {
                        if (idx <= 255) {
                            self.scr.resetPaletteColor(@intCast(idx));
                        }
                    }
                }
            },
            110 => {
                // Reset foreground color
                self.scr.resetForegroundColor();
            },
            111 => {
                // Reset background color
                self.scr.resetBackgroundColor();
            },
            else => {
                // Unsupported OSC command - ignore
            },
        }
    }

    fn parseOscPaletteColor(self: *Self, data: []const u8) void {
        // Format: index ; color
        // Find semicolon separator
        var sep_pos: ?usize = null;
        for (data, 0..) |c, i| {
            if (c == ';') {
                sep_pos = i;
                break;
            }
        }

        const sep = sep_pos orelse return;
        if (sep == 0 or sep >= data.len - 1) return;

        const index_str = data[0..sep];
        const color_str = data[sep + 1 ..];

        const index = self.parseDecimalNumber(index_str) orelse return;
        if (index > 255) return;

        const rgb = self.parseOscColor(color_str) orelse return;
        self.scr.setPaletteColor(@intCast(index), rgb.r, rgb.g, rgb.b) catch {};
    }

    fn parseOscColor(self: *Self, data: []const u8) ?Rgb {
        _ = self;
        if (data.len == 0) return null;

        // Format 1: #RRGGBB
        if (data[0] == '#') {
            if (data.len == 7) {
                const r = parseHexByte(data[1..3]) orelse return null;
                const g = parseHexByte(data[3..5]) orelse return null;
                const b = parseHexByte(data[5..7]) orelse return null;
                return Rgb{ .r = r, .g = g, .b = b };
            }
            return null;
        }

        // Format 2: rgb:RR/GG/BB or rgb:RRRR/GGGG/BBBB (X11 format)
        if (data.len >= 4 and std.mem.eql(u8, data[0..4], "rgb:")) {
            return parseX11Color(data[4..]);
        }

        return null;
    }

    fn parseDecimalNumber(self: *Self, data: []const u8) ?u32 {
        _ = self;
        if (data.len == 0) return null;
        var result: u32 = 0;
        for (data) |c| {
            if (c < '0' or c > '9') return null;
            result = result * 10 + (c - '0');
        }
        return result;
    }

    fn handleDcsEntry(self: *Self, c: u8) void {
        // DCS ends with ST (ESC \)
        if (c == 0x1B) {
            self.state = .escape;
        }
        // Consume until end
    }

    fn handleIgnore(self: *Self, c: u8) void {
        _ = c;
        self.reset();
    }

    fn getParam(self: *Self, idx: usize, default: u32) u32 {
        if (idx < self.param_count and self.params[idx] != 0) {
            return self.params[idx];
        }
        return default;
    }

    fn executeCsi(self: *Self, c: u8) void {
        switch (c) {
            'A' => {
                // CUU - Cursor up
                const n = self.getParam(0, 1);
                self.scr.cursorUp(n);
            },
            'B' => {
                // CUD - Cursor down
                const n = self.getParam(0, 1);
                self.scr.cursorDown(n);
            },
            'C' => {
                // CUF - Cursor forward
                const n = self.getParam(0, 1);
                self.scr.cursorRight(n);
            },
            'D' => {
                // CUB - Cursor back
                const n = self.getParam(0, 1);
                self.scr.cursorLeft(n);
            },
            'E' => {
                // CNL - Cursor next line
                const n = self.getParam(0, 1);
                self.scr.cursorDown(n);
                self.scr.carriageReturn();
            },
            'F' => {
                // CPL - Cursor previous line
                const n = self.getParam(0, 1);
                self.scr.cursorUp(n);
                self.scr.carriageReturn();
            },
            'G' => {
                // CHA - Cursor horizontal absolute
                const col = self.getParam(0, 1);
                self.scr.setCursor(col -| 1, self.scr.cursor_row);
            },
            'H', 'f' => {
                // CUP/HVP - Cursor position
                const row = self.getParam(0, 1);
                const col = self.getParam(1, 1);
                self.scr.setCursor(col -| 1, row -| 1);
            },
            'J' => {
                // ED - Erase in display
                const mode = self.getParam(0, 0);
                switch (mode) {
                    0 => self.scr.eraseToEndOfScreen(),
                    1 => self.scr.eraseToStartOfScreen(),
                    2, 3 => self.scr.eraseScreen(),
                    else => {
                        log.debug("unhandled ED mode: {}", .{mode});
                    },
                }
            },
            'K' => {
                // EL - Erase in line
                const mode = self.getParam(0, 0);
                switch (mode) {
                    0 => self.scr.eraseToEndOfLine(),
                    1 => self.scr.eraseToStartOfLine(),
                    2 => self.scr.eraseLine(),
                    else => {
                        log.debug("unhandled EL mode: {}", .{mode});
                    },
                }
            },
            'L' => {
                // IL - Insert lines
                const n = self.getParam(0, 1);
                self.scr.insertLines(n);
            },
            'M' => {
                // DL - Delete lines
                const n = self.getParam(0, 1);
                self.scr.deleteLines(n);
            },
            'P' => {
                // DCH - Delete characters
                const n = self.getParam(0, 1);
                self.scr.deleteChars(n);
            },
            '@' => {
                // ICH - Insert characters
                const n = self.getParam(0, 1);
                self.scr.insertChars(n);
            },
            'S' => {
                // SU - Scroll up
                const n = self.getParam(0, 1);
                self.scr.scrollUp(n);
            },
            'T' => {
                // SD - Scroll down
                const n = self.getParam(0, 1);
                self.scr.scrollDown(n);
            },
            'd' => {
                // VPA - Line position absolute
                const row = self.getParam(0, 1);
                self.scr.setCursor(self.scr.cursor_col, row -| 1);
            },
            'm' => {
                // SGR - Select graphic rendition
                self.executeSgr();
            },
            'r' => {
                // DECSTBM - Set scrolling region
                const top = self.getParam(0, 1);
                const bottom = self.getParam(1, self.scr.rows);
                self.scr.setScrollRegion(top -| 1, bottom -| 1);
            },
            's' => {
                // SCP - Save cursor position (ANSI.SYS)
                self.scr.saveCursor();
            },
            'u' => {
                // RCP - Restore cursor position (ANSI.SYS)
                self.scr.restoreCursor();
            },
            'h' => {
                // SM - Set mode (or DECSET for private modes)
                if (self.private_mode) {
                    self.executeDecset();
                } else {
                    const mode = self.getParam(0, 0);
                    switch (mode) {
                        4 => self.scr.insert_mode = true, // IRM - insert mode
                        else => log.debug("unhandled SM mode: {}", .{mode}),
                    }
                }
            },
            'l' => {
                // RM - Reset mode (or DECRST for private modes)
                if (self.private_mode) {
                    self.executeDecrst();
                } else {
                    const mode = self.getParam(0, 0);
                    switch (mode) {
                        4 => self.scr.insert_mode = false, // IRM - replace mode
                        else => log.debug("unhandled RM mode: {}", .{mode}),
                    }
                }
            },
            'q' => {
                // DECSCUSR - Set cursor style (CSI Ps SP q)
                if (self.intermediate_count == 1 and self.intermediate[0] == ' ') {
                    const style_param = self.getParam(0, 0);
                    const style: screen.Screen.CursorStyle = switch (style_param) {
                        0, 1 => .block_blink, // 0 = default (blinking block), 1 = blinking block
                        2 => .block_steady,
                        3 => .underline_blink,
                        4 => .underline_steady,
                        5 => .bar_blink,
                        6 => .bar_steady,
                        else => .block_blink, // Default for unknown values
                    };
                    self.scr.setCursorStyle(style);
                }
            },
            else => {
                log.debug("unhandled CSI: {c} (params={any})", .{ c, self.params[0..self.param_count] });
            },
        }
    }

    /// Execute DECSET (CSI ? Ps h) - Set private mode
    fn executeDecset(self: *Self) void {
        var i: usize = 0;
        while (i < self.param_count) : (i += 1) {
            const mode = self.params[i];
            switch (mode) {
                9 => {
                    // X10 mouse tracking
                    self.scr.setMouseTracking(.x10);
                },
                25 => {
                    // DECTCEM - Show cursor
                    self.scr.setCursorVisible(true);
                },
                47 => {
                    // Use alternate screen buffer (no clear)
                    self.scr.enterAltBuffer(false) catch {};
                },
                1000 => {
                    // VT200 mouse tracking (button events)
                    self.scr.setMouseTracking(.vt200);
                },
                1001 => {
                    // VT200 highlight mouse tracking
                    self.scr.setMouseTracking(.vt200_highlight);
                },
                1002 => {
                    // Button-event mouse tracking
                    self.scr.setMouseTracking(.btn_event);
                },
                1003 => {
                    // Any-event mouse tracking
                    self.scr.setMouseTracking(.any_event);
                },
                1004 => {
                    // Focus in/out event reporting
                    self.scr.setFocusEvents(true);
                },
                1005 => {
                    // UTF-8 mouse encoding
                    self.scr.setMouseEncoding(.utf8);
                },
                1006 => {
                    // SGR extended mouse encoding
                    self.scr.setMouseEncoding(.sgr);
                },
                1015 => {
                    // URXVT mouse encoding
                    self.scr.setMouseEncoding(.urxvt);
                },
                1047 => {
                    // Use alternate screen buffer (with clear)
                    self.scr.enterAltBuffer(true) catch {};
                },
                1049 => {
                    // Save cursor, use alternate screen buffer, clear
                    self.scr.enterAltBufferWithCursorSave() catch {};
                },
                else => {
                    log.debug("unhandled DECSET mode: {}", .{mode});
                },
            }
        }
    }

    /// Execute DECRST (CSI ? Ps l) - Reset private mode
    fn executeDecrst(self: *Self) void {
        var i: usize = 0;
        while (i < self.param_count) : (i += 1) {
            const mode = self.params[i];
            switch (mode) {
                9, 1000, 1001, 1002, 1003 => {
                    // Disable mouse tracking
                    self.scr.setMouseTracking(.none);
                },
                25 => {
                    // DECTCEM - Hide cursor
                    self.scr.setCursorVisible(false);
                },
                47 => {
                    // Use normal screen buffer
                    self.scr.exitAltBuffer();
                },
                1004 => {
                    // Disable focus event reporting
                    self.scr.setFocusEvents(false);
                },
                1005, 1006, 1015 => {
                    // Reset to default X10 mouse encoding
                    self.scr.setMouseEncoding(.x10);
                },
                1047 => {
                    // Use normal screen buffer (clear alt on exit)
                    // Note: Some terminals clear alt buffer on exit, we just switch
                    self.scr.exitAltBuffer();
                },
                1049 => {
                    // Use normal screen buffer, restore cursor
                    self.scr.exitAltBufferWithCursorRestore();
                },
                else => {
                    log.debug("unhandled DECRST mode: {}", .{mode});
                },
            }
        }
    }

    fn executeSgr(self: *Self) void {
        if (self.param_count == 0) {
            // No params = reset
            self.scr.current_attr = screen.Attr.default();
            return;
        }

        var i: usize = 0;
        while (i < self.param_count) {
            const p = self.params[i];
            switch (p) {
                0 => self.scr.current_attr = screen.Attr.default(),
                1 => self.scr.current_attr.bold = true,
                2 => self.scr.current_attr.dim = true,
                3 => self.scr.current_attr.italic = true,
                4 => self.scr.current_attr.underline = .single,
                5, 6 => self.scr.current_attr.blink = true,
                7 => self.scr.current_attr.reverse = true,
                8 => self.scr.current_attr.hidden = true,
                9 => self.scr.current_attr.strikethrough = true,
                21 => self.scr.current_attr.underline = .double,
                22 => {
                    self.scr.current_attr.bold = false;
                    self.scr.current_attr.dim = false;
                },
                23 => self.scr.current_attr.italic = false,
                24 => self.scr.current_attr.underline = .none,
                25 => self.scr.current_attr.blink = false,
                27 => self.scr.current_attr.reverse = false,
                28 => self.scr.current_attr.hidden = false,
                29 => self.scr.current_attr.strikethrough = false,
                53 => self.scr.current_attr.overline = true,
                55 => self.scr.current_attr.overline = false,
                30...37 => self.scr.current_attr.fg = screen.Color{ .indexed = @intCast(p - 30) },
                38 => {
                    // Extended foreground color
                    i += 1;
                    if (i < self.param_count) {
                        const mode = self.params[i];
                        if (mode == 5 and i + 1 < self.param_count) {
                            // 256 color
                            i += 1;
                            self.scr.current_attr.fg = screen.Color{ .indexed = @intCast(self.params[i]) };
                        } else if (mode == 2 and i + 3 < self.param_count) {
                            // RGB color
                            self.scr.current_attr.fg = screen.Color{ .rgb = .{
                                .r = @intCast(self.params[i + 1]),
                                .g = @intCast(self.params[i + 2]),
                                .b = @intCast(self.params[i + 3]),
                            } };
                            i += 3;
                        }
                    }
                },
                39 => self.scr.current_attr.fg = screen.Color.default_fg,
                40...47 => self.scr.current_attr.bg = screen.Color{ .indexed = @intCast(p - 40) },
                48 => {
                    // Extended background color
                    i += 1;
                    if (i < self.param_count) {
                        const mode = self.params[i];
                        if (mode == 5 and i + 1 < self.param_count) {
                            // 256 color
                            i += 1;
                            self.scr.current_attr.bg = screen.Color{ .indexed = @intCast(self.params[i]) };
                        } else if (mode == 2 and i + 3 < self.param_count) {
                            // RGB color
                            self.scr.current_attr.bg = screen.Color{ .rgb = .{
                                .r = @intCast(self.params[i + 1]),
                                .g = @intCast(self.params[i + 2]),
                                .b = @intCast(self.params[i + 3]),
                            } };
                            i += 3;
                        }
                    }
                },
                49 => self.scr.current_attr.bg = screen.Color.default_bg,
                90...97 => self.scr.current_attr.fg = screen.Color{ .indexed = @intCast(p - 90 + 8) },
                100...107 => self.scr.current_attr.bg = screen.Color{ .indexed = @intCast(p - 100 + 8) },
                else => {
                    log.debug("unhandled SGR param: {}", .{p});
                },
            }
            i += 1;
        }
    }
};

// ============================================================================
// Color parsing helper functions
// ============================================================================

/// RGB color type for OSC color parsing
const Rgb = struct { r: u8, g: u8, b: u8 };

/// Parse a 2-character hex byte (e.g., "FF" -> 255)
fn parseHexByte(data: []const u8) ?u8 {
    if (data.len != 2) return null;
    const high = hexDigitToValue(data[0]) orelse return null;
    const low = hexDigitToValue(data[1]) orelse return null;
    return high * 16 + low;
}

/// Parse a hex digit to its numeric value
fn hexDigitToValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Parse X11 color format: RR/GG/BB or RRRR/GGGG/BBBB
fn parseX11Color(data: []const u8) ?Rgb {
    // Find the two separators
    var sep1: ?usize = null;
    var sep2: ?usize = null;

    for (data, 0..) |c, i| {
        if (c == '/') {
            if (sep1 == null) {
                sep1 = i;
            } else if (sep2 == null) {
                sep2 = i;
            } else {
                return null; // Too many separators
            }
        }
    }

    const s1 = sep1 orelse return null;
    const s2 = sep2 orelse return null;

    const r_str = data[0..s1];
    const g_str = data[s1 + 1 .. s2];
    const b_str = data[s2 + 1 ..];

    // All components must have the same length (1-4 hex digits)
    if (r_str.len == 0 or r_str.len > 4) return null;
    if (r_str.len != g_str.len or r_str.len != b_str.len) return null;

    const r = parseHexComponent(r_str) orelse return null;
    const g = parseHexComponent(g_str) orelse return null;
    const b = parseHexComponent(b_str) orelse return null;

    return Rgb{ .r = r, .g = g, .b = b };
}

/// Parse a hex color component (1-4 hex digits) and scale to 0-255
fn parseHexComponent(data: []const u8) ?u8 {
    if (data.len == 0 or data.len > 4) return null;

    var value: u16 = 0;
    for (data) |c| {
        const digit = hexDigitToValue(c) orelse return null;
        value = value * 16 + digit;
    }

    // Scale based on component length:
    // 1 digit: multiply by 17 (0xF -> 0xFF)
    // 2 digits: use as-is
    // 3 digits: divide by 16 (0xFFF -> 0xFF)
    // 4 digits: divide by 256 (0xFFFF -> 0xFF)
    return switch (data.len) {
        1 => @intCast(value * 17),
        2 => @intCast(value),
        3 => @intCast(value >> 4),
        4 => @intCast(value >> 8),
        else => null,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Parser basic text" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);
    parser.feedSlice("Hello");

    try std.testing.expectEqual(@as(u32, 5), scr.cursor_col);
    try std.testing.expectEqual(@as(u21, 'H'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), scr.getCell(4, 0).char);
}

test "Parser cursor movement" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // Move cursor to (10, 5)
    parser.feedSlice("\x1b[6;11H");
    try std.testing.expectEqual(@as(u32, 10), scr.cursor_col);
    try std.testing.expectEqual(@as(u32, 5), scr.cursor_row);

    // Move up 2
    parser.feedSlice("\x1b[2A");
    try std.testing.expectEqual(@as(u32, 3), scr.cursor_row);

    // Move right 5
    parser.feedSlice("\x1b[5C");
    try std.testing.expectEqual(@as(u32, 15), scr.cursor_col);
}

test "Parser clear screen" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // Write something
    parser.feedSlice("Hello");

    // Clear screen
    parser.feedSlice("\x1b[2J");

    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(0, 0).char);
}

test "Parser colors" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // Set red foreground
    parser.feedSlice("\x1b[31mR");
    const cell = scr.getCell(0, 0);
    try std.testing.expectEqual(@as(u21, 'R'), cell.char);
    try std.testing.expectEqual(screen.Color{ .indexed = 1 }, cell.attr.fg);

    // Reset
    parser.feedSlice("\x1b[0mN");
    const cell2 = scr.getCell(1, 0);
    try std.testing.expectEqual(screen.Color.default_fg, cell2.attr.fg);
}

test "Parser UTF-8 2-byte" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // é = U+00E9 = 0xC3 0xA9 in UTF-8
    parser.feedSlice("\xC3\xA9");

    try std.testing.expectEqual(@as(u32, 1), scr.cursor_col);
    try std.testing.expectEqual(@as(u21, 0x00E9), scr.getCell(0, 0).char);
}

test "Parser UTF-8 3-byte" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // 中 = U+4E2D = 0xE4 0xB8 0xAD in UTF-8
    parser.feedSlice("\xE4\xB8\xAD");

    // Wide character takes 2 columns
    try std.testing.expectEqual(@as(u32, 2), scr.cursor_col);
    try std.testing.expectEqual(@as(u21, 0x4E2D), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u2, 2), scr.getCell(0, 0).width);
}

test "Parser UTF-8 4-byte" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // 😀 = U+1F600 = 0xF0 0x9F 0x98 0x80 in UTF-8
    parser.feedSlice("\xF0\x9F\x98\x80");

    try std.testing.expectEqual(@as(u32, 1), scr.cursor_col);
    try std.testing.expectEqual(@as(u21, 0x1F600), scr.getCell(0, 0).char);
}

test "Parser UTF-8 mixed" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // Mix of ASCII and UTF-8: "Héllo"
    parser.feedSlice("H\xC3\xA9llo");

    try std.testing.expectEqual(@as(u32, 5), scr.cursor_col);
    try std.testing.expectEqual(@as(u21, 'H'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 0x00E9), scr.getCell(1, 0).char); // é
    try std.testing.expectEqual(@as(u21, 'l'), scr.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'l'), scr.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), scr.getCell(4, 0).char);
}

test "Parser DECSC/DECRC (ESC 7/8)" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // Move cursor and save
    parser.feedSlice("\x1b[10;20H"); // Move to row 10, col 20
    parser.feedSlice("\x1b7"); // Save cursor (DECSC)

    try std.testing.expectEqual(@as(u32, 19), scr.cursor_col); // 0-indexed
    try std.testing.expectEqual(@as(u32, 9), scr.cursor_row);

    // Move cursor elsewhere
    parser.feedSlice("\x1b[1;1H"); // Move to row 1, col 1
    try std.testing.expectEqual(@as(u32, 0), scr.cursor_col);
    try std.testing.expectEqual(@as(u32, 0), scr.cursor_row);

    // Restore cursor
    parser.feedSlice("\x1b8"); // Restore cursor (DECRC)
    try std.testing.expectEqual(@as(u32, 19), scr.cursor_col);
    try std.testing.expectEqual(@as(u32, 9), scr.cursor_row);
}

test "Parser CSI s/u cursor save/restore" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // Move cursor and save with CSI s
    parser.feedSlice("\x1b[5;15H"); // Move to row 5, col 15
    parser.feedSlice("\x1b[s"); // Save cursor

    // Move cursor elsewhere
    parser.feedSlice("\x1b[20;70H");

    // Restore cursor with CSI u
    parser.feedSlice("\x1b[u");
    try std.testing.expectEqual(@as(u32, 14), scr.cursor_col); // 0-indexed
    try std.testing.expectEqual(@as(u32, 4), scr.cursor_row);
}

test "Parser DECSET/DECRST mode 1049 (alt screen)" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // Write to main screen
    parser.feedSlice("Main");
    parser.feedSlice("\x1b[5;10H"); // Position cursor
    try std.testing.expectEqual(@as(u21, 'M'), scr.getCell(0, 0).char);
    try std.testing.expect(!scr.using_alt_buffer);

    // Enter alt screen (mode 1049 = save cursor + switch + clear)
    parser.feedSlice("\x1b[?1049h");
    try std.testing.expect(scr.using_alt_buffer);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(0, 0).char); // cleared

    // Write to alt screen
    parser.feedSlice("Alt");
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);

    // Exit alt screen (mode 1049 = restore cursor + switch)
    parser.feedSlice("\x1b[?1049l");
    try std.testing.expect(!scr.using_alt_buffer);
    try std.testing.expectEqual(@as(u21, 'M'), scr.getCell(0, 0).char); // main restored
    try std.testing.expectEqual(@as(u32, 9), scr.cursor_col); // cursor restored
    try std.testing.expectEqual(@as(u32, 4), scr.cursor_row);
}

test "Parser IRM (insert mode, CSI 4 h) shifts the line right" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    parser.feedSlice("hello");
    parser.feedSlice("\x1b[H"); // home to row 0, col 0
    try std.testing.expect(!scr.insert_mode);

    // Insert mode on, type "XX": pushes "hello" right rather than overwriting.
    parser.feedSlice("\x1b[4h");
    try std.testing.expect(scr.insert_mode);
    parser.feedSlice("XX");

    // Row now reads "XXhello".
    try std.testing.expectEqual(@as(u21, 'X'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'X'), scr.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'h'), scr.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'e'), scr.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'l'), scr.getCell(4, 0).char);
    try std.testing.expectEqual(@as(u21, 'l'), scr.getCell(5, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), scr.getCell(6, 0).char);
}

test "Parser IRM reset (CSI 4 l) restores overwrite" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    parser.feedSlice("abcd");
    parser.feedSlice("\x1b[H"); // home
    parser.feedSlice("\x1b[4h"); // insert mode on
    parser.feedSlice("\x1b[4l"); // insert mode off
    try std.testing.expect(!scr.insert_mode);

    parser.feedSlice("Z"); // overwrites 'a', does not shift
    try std.testing.expectEqual(@as(u21, 'Z'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'b'), scr.getCell(1, 0).char);
}

test "Parser RIS clears insert mode" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    parser.feedSlice("\x1b[4h");
    try std.testing.expect(scr.insert_mode);
    parser.feedSlice("\x1bc"); // RIS
    try std.testing.expect(!scr.insert_mode);
}

test "Parser DECSET/DECRST mode 25 (cursor visibility)" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    try std.testing.expect(scr.cursor_visible);

    // Hide cursor
    parser.feedSlice("\x1b[?25l");
    try std.testing.expect(!scr.cursor_visible);

    // Show cursor
    parser.feedSlice("\x1b[?25h");
    try std.testing.expect(scr.cursor_visible);
}

test "Parser OSC 0 (set icon name and title)" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // OSC 0 ; text BEL
    parser.feedSlice("\x1b]0;My Terminal Title\x07");

    try std.testing.expectEqualStrings("My Terminal Title", scr.getTitle());
    try std.testing.expectEqualStrings("My Terminal Title", scr.getIconName());
}

test "Parser OSC 2 (set title only)" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // OSC 2 ; text ESC \ (ST terminator)
    parser.feedSlice("\x1b]2;Window Title\x1b\\");

    try std.testing.expectEqualStrings("Window Title", scr.getTitle());
    try std.testing.expectEqualStrings("", scr.getIconName());
}

test "Parser OSC 1 (set icon name only)" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // First set title
    parser.feedSlice("\x1b]2;Title\x07");
    // Then set icon name only
    parser.feedSlice("\x1b]1;Icon\x07");

    try std.testing.expectEqualStrings("Title", scr.getTitle());
    try std.testing.expectEqualStrings("Icon", scr.getIconName());
}

test "Parser OSC 10/11 (foreground/background colors)" {
    const allocator = std.testing.allocator;
    var scr = try screen.Screen.init(allocator, 80, 24);
    defer scr.deinit();

    var parser = Parser.init(&scr);

    // Set foreground to red (#FF0000)
    parser.feedSlice("\x1b]10;#FF0000\x07");
    const fg = scr.getEffectiveForeground();
    try std.testing.expectEqual(@as(u8, 255), fg.r);
    try std.testing.expectEqual(@as(u8, 0), fg.g);
    try std.testing.expectEqual(@as(u8, 0), fg.b);

    // Set background using X11 format
    parser.feedSlice("\x1b]11;rgb:00/FF/00\x07");
    const bg = scr.getEffectiveBackground();
    try std.testing.expectEqual(@as(u8, 0), bg.r);
    try std.testing.expectEqual(@as(u8, 255), bg.g);
    try std.testing.expectEqual(@as(u8, 0), bg.b);

    // Reset colors
    parser.feedSlice("\x1b]110;\x07");
    parser.feedSlice("\x1b]111;\x07");
    const fg2 = scr.getEffectiveForeground();
    const bg2 = scr.getEffectiveBackground();
    // Should be back to defaults (gray/black)
    try std.testing.expectEqual(@as(u8, 170), fg2.r); // default_fg color 7
    try std.testing.expectEqual(@as(u8, 0), bg2.r); // default_bg color 0
}

test "parseHexByte" {
    try std.testing.expectEqual(@as(?u8, 0), parseHexByte("00"));
    try std.testing.expectEqual(@as(?u8, 255), parseHexByte("FF"));
    try std.testing.expectEqual(@as(?u8, 255), parseHexByte("ff"));
    try std.testing.expectEqual(@as(?u8, 171), parseHexByte("AB"));
    try std.testing.expectEqual(@as(?u8, null), parseHexByte("GG"));
    try std.testing.expectEqual(@as(?u8, null), parseHexByte("F"));
}

test "parseX11Color" {
    // 2-digit format
    const c1 = parseX11Color("FF/00/80").?;
    try std.testing.expectEqual(@as(u8, 255), c1.r);
    try std.testing.expectEqual(@as(u8, 0), c1.g);
    try std.testing.expectEqual(@as(u8, 128), c1.b);

    // 4-digit format
    const c2 = parseX11Color("FFFF/0000/8080").?;
    try std.testing.expectEqual(@as(u8, 255), c2.r);
    try std.testing.expectEqual(@as(u8, 0), c2.g);
    try std.testing.expectEqual(@as(u8, 128), c2.b);

    // 1-digit format
    const c3 = parseX11Color("F/0/8").?;
    try std.testing.expectEqual(@as(u8, 255), c3.r);
    try std.testing.expectEqual(@as(u8, 0), c3.g);
    try std.testing.expectEqual(@as(u8, 136), c3.b);

    // Invalid formats
    try std.testing.expectEqual(@as(?Rgb, null), parseX11Color("FF/00"));
    try std.testing.expectEqual(@as(?Rgb, null), parseX11Color("FF/00/GG"));
}
