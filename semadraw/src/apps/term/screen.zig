const std = @import("std");
const font = @import("font");

/// Terminal screen buffer
/// Manages character grid with attributes, cursor, and scrolling
/// Supports alternative screen buffer (mode 1049) for vim, htop, less, etc.
/// Supports scrollback history for viewing past output
pub const Screen = struct {
    allocator: std.mem.Allocator,
    cols: u32,
    rows: u32,
    cells: []Cell,
    cursor_col: u32,
    cursor_row: u32,
    cursor_visible: bool,
    cursor_style: CursorStyle,
    cursor_blink: bool, // Whether cursor should blink (from style)
    scroll_top: u32,
    scroll_bottom: u32,
    current_attr: Attr,
    dirty: bool,
    dirty_rows: []bool, // Per-row dirty tracking for efficient rendering

    // IRM - Insert/Replace Mode (ANSI mode 4; CSI 4 h sets, CSI 4 l resets).
    // When true, printing a glyph shifts the rest of the line right instead
    // of overwriting. readline uses this (via the xterm-256color terminfo
    // smir/rmir caps) for mid-line edits.
    insert_mode: bool,

    // Alternative screen buffer support
    alt_cells: ?[]Cell,
    using_alt_buffer: bool,

    // Saved cursor state (for DECSC/DECRC and mode 1049)
    saved_cursor_col: u32,
    saved_cursor_row: u32,
    saved_attr: Attr,

    // Scrollback buffer (ring buffer of saved lines)
    scrollback: ?[][]Cell, // Array of saved lines (each line is cols cells)
    scrollback_max: u32, // Maximum number of lines to save
    scrollback_count: u32, // Current number of lines in scrollback
    scrollback_start: u32, // Ring buffer start index
    scroll_view_offset: u32, // How many lines we're scrolled back (0 = at bottom)

    // Terminal title (set via OSC 0/1/2)
    title: [256]u8, // Window/icon title (null-terminated)
    title_len: u8,
    icon_name: [256]u8, // Icon name (separate from title)
    icon_name_len: u8,

    // Color palette customization (OSC 4/10/11)
    custom_palette: ?*[256][3]u8, // Custom 256-color palette (null = use default)
    custom_fg: ?[3]u8, // Custom foreground color (OSC 10)
    custom_bg: ?[3]u8, // Custom background color (OSC 11)

    // Mouse tracking configuration (DECSET modes)
    mouse_tracking: MouseTrackingMode,
    mouse_encoding: MouseEncodingMode,
    mouse_focus_events: bool, // Mode 1004: Report focus in/out

    // Text selection state
    selection: Selection,

    /// Text selection state
    pub const Selection = struct {
        active: bool, // Whether there's an active selection
        selecting: bool, // Whether we're currently dragging to select
        start_col: u32,
        start_row: u32,
        end_col: u32,
        end_row: u32,

        pub fn none() Selection {
            return .{
                .active = false,
                .selecting = false,
                .start_col = 0,
                .start_row = 0,
                .end_col = 0,
                .end_row = 0,
            };
        }

        /// Get normalized selection (start before end)
        pub fn normalized(self: Selection) struct { start_col: u32, start_row: u32, end_col: u32, end_row: u32 } {
            if (self.start_row < self.end_row or (self.start_row == self.end_row and self.start_col <= self.end_col)) {
                return .{ .start_col = self.start_col, .start_row = self.start_row, .end_col = self.end_col, .end_row = self.end_row };
            } else {
                return .{ .start_col = self.end_col, .start_row = self.end_row, .end_col = self.start_col, .end_row = self.start_row };
            }
        }

        /// Check if a cell is within the selection
        pub fn contains(self: Selection, col: u32, row: u32) bool {
            if (!self.active) return false;
            const n = self.normalized();
            if (row < n.start_row or row > n.end_row) return false;
            if (row == n.start_row and row == n.end_row) {
                return col >= n.start_col and col <= n.end_col;
            } else if (row == n.start_row) {
                return col >= n.start_col;
            } else if (row == n.end_row) {
                return col <= n.end_col;
            }
            return true; // Middle row - fully selected
        }
    };

    /// Mouse tracking modes
    pub const MouseTrackingMode = enum(u16) {
        none = 0, // No mouse tracking
        x10 = 9, // X10 mode: Only report button presses
        vt200 = 1000, // VT200 mode: Report presses and releases
        vt200_highlight = 1001, // VT200 highlight mode
        btn_event = 1002, // Button-event mode: presses, releases, and motion with button down
        any_event = 1003, // Any-event mode: all motion events
    };

    /// Mouse encoding modes (how coordinates are reported)
    pub const MouseEncodingMode = enum(u16) {
        x10 = 0, // Default X10: CSI M Cb Cx Cy (limited to 223 columns/rows)
        utf8 = 1005, // UTF-8 encoding for coordinates
        sgr = 1006, // SGR extended: CSI < Pb ; Px ; Py M/m
        urxvt = 1015, // URXVT style: CSI Pb ; Px ; Py M
    };

    /// Cursor style (DECSCUSR - CSI Ps SP q)
    pub const CursorStyle = enum(u8) {
        block = 0, // Default block cursor (filled rectangle)
        block_blink = 1, // Blinking block
        block_steady = 2, // Steady block
        underline_blink = 3, // Blinking underline
        underline_steady = 4, // Steady underline
        bar_blink = 5, // Blinking bar (beam/I-beam)
        bar_steady = 6, // Steady bar

        /// Check if this style should blink
        pub fn shouldBlink(self: CursorStyle) bool {
            return switch (self) {
                .block, .block_blink, .underline_blink, .bar_blink => true,
                .block_steady, .underline_steady, .bar_steady => false,
            };
        }

        /// Get the shape type (block, underline, or bar)
        pub fn shape(self: CursorStyle) Shape {
            return switch (self) {
                .block, .block_blink, .block_steady => .block,
                .underline_blink, .underline_steady => .underline,
                .bar_blink, .bar_steady => .bar,
            };
        }

        pub const Shape = enum { block, underline, bar };
    };

    /// Default scrollback buffer size (lines)
    pub const DEFAULT_SCROLLBACK_LINES: u32 = 1000;

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cols: u32, rows: u32) !Self {
        return initWithScrollback(allocator, cols, rows, DEFAULT_SCROLLBACK_LINES);
    }

    pub fn initWithScrollback(allocator: std.mem.Allocator, cols: u32, rows: u32, scrollback_lines: u32) !Self {
        const cells = try allocator.alloc(Cell, cols * rows);
        for (cells) |*cell| {
            cell.* = Cell.blank();
        }

        // Allocate dirty row tracking
        const dirty_rows = try allocator.alloc(bool, rows);
        @memset(dirty_rows, true); // Initially mark all rows as dirty

        // Allocate scrollback buffer if enabled
        var scrollback: ?[][]Cell = null;
        if (scrollback_lines > 0) {
            scrollback = try allocator.alloc([]Cell, scrollback_lines);
            for (scrollback.?) |*line| {
                line.* = &[_]Cell{};
            }
        }

        return .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .cursor_col = 0,
            .cursor_row = 0,
            .cursor_visible = true,
            .cursor_style = .block,
            .cursor_blink = true,
            .scroll_top = 0,
            .scroll_bottom = rows - 1,
            .current_attr = Attr.default(),
            .dirty = true,
            .dirty_rows = dirty_rows,
            .insert_mode = false,
            // Alternative buffer initially not allocated
            .alt_cells = null,
            .using_alt_buffer = false,
            // Saved cursor defaults
            .saved_cursor_col = 0,
            .saved_cursor_row = 0,
            .saved_attr = Attr.default(),
            // Scrollback buffer
            .scrollback = scrollback,
            .scrollback_max = scrollback_lines,
            .scrollback_count = 0,
            .scrollback_start = 0,
            .scroll_view_offset = 0,
            // Terminal title
            .title = [_]u8{0} ** 256,
            .title_len = 0,
            .icon_name = [_]u8{0} ** 256,
            .icon_name_len = 0,
            // Color palette
            .custom_palette = null,
            .custom_fg = null,
            .custom_bg = null,
            // Mouse tracking
            .mouse_tracking = .none,
            .mouse_encoding = .x10,
            .mouse_focus_events = false,
            // Text selection
            .selection = Selection.none(),
        };
    }

    /// D-12 stage 4 (ADR 0022 section 5): resize the grid to a
    /// compositor-assigned configuration. Policy, operator-ratified:
    /// truncate/pad, no rewrap (classical xterm behaviour; content
    /// right of the new width or below the new height is cut, growth
    /// appears blank; full-screen apps repaint on SIGWINCH and
    /// readline redraws the prompt), and scrollback is DISCARDED with
    /// the view reset (each saved line is exactly cols cells wide, so
    /// a width change invalidates the whole ring). Both choices live
    /// entirely in this client; richer behaviour later never touches
    /// the configure/acknowledgement design. This is the reference
    /// client: its purpose is to exercise the substrate, not to be a
    /// good terminal.
    pub fn resize(self: *Self, new_cols: u32, new_rows: u32) !void {
        if (new_cols == 0 or new_rows == 0) return error.InvalidSize;
        if (new_cols == self.cols and new_rows == self.rows) return;

        // Primary buffer: intersection copy into a fresh blank grid.
        const new_cells = try self.allocator.alloc(Cell, new_cols * new_rows);
        errdefer self.allocator.free(new_cells);
        for (new_cells) |*cell| cell.* = Cell.blank();
        const copy_rows = @min(self.rows, new_rows);
        const copy_cols = @min(self.cols, new_cols);
        var r: u32 = 0;
        while (r < copy_rows) : (r += 1) {
            @memcpy(
                new_cells[r * new_cols ..][0..copy_cols],
                self.cells[r * self.cols ..][0..copy_cols],
            );
        }

        // Alt buffer, if allocated: same policy. Allocated before any
        // frees so failure leaves the screen untouched.
        var new_alt: ?[]Cell = null;
        if (self.alt_cells) |alt| {
            const na = try self.allocator.alloc(Cell, new_cols * new_rows);
            for (na) |*cell| cell.* = Cell.blank();
            r = 0;
            while (r < copy_rows) : (r += 1) {
                @memcpy(
                    na[r * new_cols ..][0..copy_cols],
                    alt[r * self.cols ..][0..copy_cols],
                );
            }
            new_alt = na;
        }
        errdefer if (new_alt) |na| self.allocator.free(na);

        const new_dirty = try self.allocator.alloc(bool, new_rows);
        @memset(new_dirty, true);

        // Point of no return: swap everything in.
        self.allocator.free(self.cells);
        self.cells = new_cells;
        if (self.alt_cells) |alt| {
            self.allocator.free(alt);
            self.alt_cells = new_alt;
        }
        self.allocator.free(self.dirty_rows);
        self.dirty_rows = new_dirty;
        self.cols = new_cols;
        self.rows = new_rows;

        // Scrollback: discard content, keep the ring allocation
        // (lines are freed and reset to empty; the ring itself is
        // sized by line count, not width).
        if (self.scrollback) |sb| {
            for (sb) |*line| {
                if (line.len > 0) {
                    self.allocator.free(line.*);
                    line.* = &[_]Cell{};
                }
            }
        }
        self.scrollback_count = 0;
        self.scrollback_start = 0;
        self.scroll_view_offset = 0;

        // Clamp everything that names a coordinate. The scroll region
        // resets to the full box: a region tuned to the old height is
        // meaningless in the new one, and applications re-establish
        // regions after SIGWINCH.
        self.cursor_col = @min(self.cursor_col, new_cols - 1);
        self.cursor_row = @min(self.cursor_row, new_rows - 1);
        self.saved_cursor_col = @min(self.saved_cursor_col, new_cols - 1);
        self.saved_cursor_row = @min(self.saved_cursor_row, new_rows - 1);
        self.scroll_top = 0;
        self.scroll_bottom = new_rows - 1;

        self.dirty = true;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.dirty_rows);
        if (self.alt_cells) |alt| {
            self.allocator.free(alt);
        }
        // Free scrollback buffer
        if (self.scrollback) |sb| {
            for (sb) |line| {
                if (line.len > 0) {
                    self.allocator.free(line);
                }
            }
            self.allocator.free(sb);
        }
        // Free custom palette if allocated
        if (self.custom_palette) |palette| {
            self.allocator.destroy(palette);
        }
    }

    /// Get cell at position
    ///
    /// AD-16.1: Bounds-checked. Out-of-range arguments are a caller bug;
    /// silently returning `&cells[wrong_index]` would corrupt adjacent
    /// rows or read past the buffer. Assert explicitly so the panic
    /// names the actual failure rather than appearing later as
    /// rendering corruption.
    pub fn getCell(self: *const Self, col: u32, row: u32) *const Cell {
        std.debug.assert(col < self.cols);
        std.debug.assert(row < self.rows);
        return &self.cells[row * self.cols + col];
    }

    /// Get mutable cell at position
    ///
    /// AD-16.1: see `getCell` above for the bounds-check rationale.
    fn getCellMut(self: *Self, col: u32, row: u32) *Cell {
        std.debug.assert(col < self.cols);
        std.debug.assert(row < self.rows);
        return &self.cells[row * self.cols + col];
    }

    // ========================================================================
    // Text selection
    // ========================================================================

    /// Start a new selection at the given position
    pub fn startSelection(self: *Self, col: u32, row: u32) void {
        self.selection = .{
            .active = true,
            .selecting = true,
            .start_col = @min(col, self.cols - 1),
            .start_row = @min(row, self.rows - 1),
            .end_col = @min(col, self.cols - 1),
            .end_row = @min(row, self.rows - 1),
        };
        self.markAllRowsDirty();
    }

    /// Update selection end position (while dragging)
    pub fn updateSelection(self: *Self, col: u32, row: u32) void {
        if (self.selection.selecting) {
            self.selection.end_col = @min(col, self.cols - 1);
            self.selection.end_row = @min(row, self.rows - 1);
            self.selection.active = true;
            self.markAllRowsDirty();
        }
    }

    /// End selection (stop dragging)
    pub fn endSelection(self: *Self) void {
        self.selection.selecting = false;
    }

    /// Clear selection
    pub fn clearSelection(self: *Self) void {
        if (self.selection.active) {
            self.selection = Selection.none();
            self.markAllRowsDirty();
        }
    }

    /// Check if a cell is selected
    pub fn isCellSelected(self: *const Self, col: u32, row: u32) bool {
        return self.selection.contains(col, row);
    }

    /// Get selected text as a string (caller must free)
    pub fn getSelectedText(self: *const Self, allocator: std.mem.Allocator) !?[]u8 {
        if (!self.selection.active) return null;

        const n = self.selection.normalized();
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        var row = n.start_row;
        while (row <= n.end_row) : (row += 1) {
            const start_col = if (row == n.start_row) n.start_col else 0;
            const end_col = if (row == n.end_row) n.end_col else self.cols - 1;

            // Find last non-blank cell in the row to trim trailing spaces
            var last_non_blank: u32 = start_col;
            var col = start_col;
            while (col <= end_col) : (col += 1) {
                const cell = self.getCell(col, row);
                if (cell.char != ' ' and cell.char != 0) {
                    last_non_blank = col;
                }
            }

            // Copy characters from the row
            col = start_col;
            while (col <= @min(end_col, last_non_blank)) : (col += 1) {
                const cell = self.getCell(col, row);
                const char = if (cell.char == 0) ' ' else cell.char;

                // Encode as UTF-8
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(char, &buf) catch 1;
                try result.appendSlice(allocator, buf[0..len]);
            }

            // Add newline between rows (but not after last row)
            if (row < n.end_row) {
                try result.append(allocator, '\n');
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    // ========================================================================
    // Dirty row tracking
    // ========================================================================

    /// Mark a specific row as dirty (needs re-rendering)
    pub fn markRowDirty(self: *Self, row: u32) void {
        if (row < self.rows) {
            self.dirty_rows[row] = true;
            self.dirty = true;
        }
    }

    /// Mark all rows as dirty (full re-render needed)
    pub fn markAllRowsDirty(self: *Self) void {
        @memset(self.dirty_rows, true);
        self.dirty = true;
    }

    /// Clear all dirty row flags (call after rendering)
    pub fn clearDirtyRows(self: *Self) void {
        @memset(self.dirty_rows, false);
        self.dirty = false;
    }

    /// Check if a specific row is dirty
    pub fn isRowDirty(self: *const Self, row: u32) bool {
        if (row < self.rows) {
            return self.dirty_rows[row];
        }
        return false;
    }

    /// Write a character at cursor position and advance cursor
    pub fn putChar(self: *Self, c: u21) void {
        self.putCharWithWidth(c, charWidth(c));
    }

    /// Write a character with explicit width
    ///
    /// AD-16.2: width==0 (combining marks, zero-width spaces, variation
    /// selectors) is rejected here. The Unicode-correct behaviour would
    /// be to merge the codepoint into the preceding cell as an
    /// attribute; doing that requires restructuring `Cell` to hold a
    /// combining-marks list, which is out of scope for AD-16. The
    /// practical-and-safe behaviour is to drop the codepoint, and the
    /// alternative (advancing the cursor for a glyph that consumes no
    /// cell) lands the cursor at `cols` and breaks `getCellMut` on the
    /// next call.
    pub fn putCharWithWidth(self: *Self, c: u21, width: u2) void {
        if (width == 0) return;

        // Handle line wrap
        if (self.cursor_col + width > self.cols) {
            self.newline();
        }

        // IRM: in insert mode, open a gap at the cursor so the rest of the
        // line shifts right instead of being overwritten. insertChars already
        // performs the (clamped) right shift and clears the gap; width==2
        // wide glyphs open two cells.
        if (self.insert_mode) {
            self.insertChars(width);
        }

        const cell = self.getCellMut(self.cursor_col, self.cursor_row);
        cell.char = c;
        cell.attr = self.current_attr;
        cell.width = width;
        cell.glyph_idx = font.Font.charToIndexWithFallback(c);
        self.cursor_col += 1;

        // For wide characters, add continuation cell
        if (width == 2 and self.cursor_col < self.cols) {
            const cont = self.getCellMut(self.cursor_col, self.cursor_row);
            cont.* = Cell.wideContinuation();
            cont.attr = self.current_attr;
            self.cursor_col += 1;
        }

        self.markRowDirty(self.cursor_row);
    }

    /// Determine display width of a Unicode codepoint
    /// Returns 0 for combining chars, 2 for wide chars (CJK), 1 otherwise
    pub fn charWidth(c: u21) u2 {
        // Zero-width characters
        if (c < 0x20) return 0; // Control chars
        if (c >= 0x0300 and c <= 0x036F) return 0; // Combining diacriticals
        if (c >= 0x200B and c <= 0x200F) return 0; // Zero-width spaces/joiners
        if (c >= 0xFE00 and c <= 0xFE0F) return 0; // Variation selectors

        // Wide characters (CJK, fullwidth, etc.)
        if (c >= 0x1100 and c <= 0x115F) return 2; // Hangul Jamo
        if (c >= 0x2E80 and c <= 0x9FFF) return 2; // CJK
        if (c >= 0xAC00 and c <= 0xD7A3) return 2; // Hangul Syllables
        if (c >= 0xF900 and c <= 0xFAFF) return 2; // CJK Compatibility
        if (c >= 0xFE10 and c <= 0xFE1F) return 2; // Vertical forms
        if (c >= 0xFE30 and c <= 0xFE6F) return 2; // CJK Compatibility Forms
        if (c >= 0xFF00 and c <= 0xFF60) return 2; // Fullwidth forms
        if (c >= 0xFFE0 and c <= 0xFFE6) return 2; // Fullwidth symbols
        if (c >= 0x20000 and c <= 0x2FFFF) return 2; // CJK Extension B+

        return 1;
    }

    /// Move cursor to next line
    pub fn newline(self: *Self) void {
        self.cursor_col = 0;
        if (self.cursor_row >= self.scroll_bottom) {
            self.scrollUp(1);
        } else {
            self.cursor_row += 1;
        }
        self.markRowDirty(self.cursor_row);
    }

    /// Carriage return (move cursor to column 0)
    pub fn carriageReturn(self: *Self) void {
        self.cursor_col = 0;
        self.markRowDirty(self.cursor_row);
    }

    /// Tab (move cursor to next 8-column boundary)
    pub fn tab(self: *Self) void {
        const next_tab = (self.cursor_col / 8 + 1) * 8;
        self.cursor_col = @min(next_tab, self.cols - 1);
        self.markRowDirty(self.cursor_row);
    }

    /// Backspace (move cursor left, don't delete)
    pub fn backspace(self: *Self) void {
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
            self.markRowDirty(self.cursor_row);
        }
    }

    /// Scroll up by n lines within scroll region
    /// Lines scrolling off the top are saved to scrollback (main buffer only)
    ///
    /// AD-16.3: when `lines_to_scroll` covers the entire region (n is
    /// at least the region height), `end_row - lines_to_scroll` would
    /// underflow `u32` and the shift-up loop would compute a garbage
    /// upper bound. Detect this case and clear the whole region
    /// directly; no copy is needed when every source row is being
    /// discarded anyway.
    pub fn scrollUp(self: *Self, n: u32) void {
        if (n == 0) return;

        const region_height = self.scroll_bottom - self.scroll_top + 1;
        const lines_to_scroll = @min(n, region_height);
        const start_row = self.scroll_top;
        const end_row = self.scroll_bottom;

        // Save lines to scrollback (only from main buffer, not alt buffer)
        // Only save when scroll region is at the top of screen
        if (!self.using_alt_buffer and start_row == 0) {
            self.saveLinesToScrollback(lines_to_scroll);
        }

        if (lines_to_scroll == region_height) {
            // Entire region scrolls: every source row is discarded.
            // Skip the copy loop (it would underflow `end_row -
            // lines_to_scroll` and read past the buffer) and just
            // clear all rows in the region.
            const clear_start = start_row * self.cols;
            const clear_count = region_height * self.cols;
            @memset(self.cells[clear_start..][0..clear_count], Cell.blank());
        } else {
            // Move lines up using block copy
            var row = start_row;
            while (row <= end_row - lines_to_scroll) : (row += 1) {
                const src_start = (row + lines_to_scroll) * self.cols;
                const dst_start = row * self.cols;
                @memcpy(self.cells[dst_start..][0..self.cols], self.cells[src_start..][0..self.cols]);
            }

            // Clear bottom lines using block fill
            const clear_start = (end_row - lines_to_scroll + 1) * self.cols;
            const clear_count = lines_to_scroll * self.cols;
            @memset(self.cells[clear_start..][0..clear_count], Cell.blank());
        }

        // Mark all rows in scroll region as dirty using block fill
        @memset(self.dirty_rows[start_row..][0 .. end_row - start_row + 1], true);

        // Reset scroll view when new content is added
        if (self.scroll_view_offset > 0) {
            self.scroll_view_offset = 0;
        }
    }

    /// Save lines from the top of screen to scrollback buffer
    fn saveLinesToScrollback(self: *Self, count: u32) void {
        const sb = self.scrollback orelse return;
        if (self.scrollback_max == 0) return;

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            // Calculate the index in the ring buffer
            var idx: u32 = undefined;
            if (self.scrollback_count < self.scrollback_max) {
                // Buffer not full yet, append
                idx = self.scrollback_count;
                self.scrollback_count += 1;
            } else {
                // Buffer full, overwrite oldest
                idx = self.scrollback_start;
                self.scrollback_start = (self.scrollback_start + 1) % self.scrollback_max;
            }

            // Free old line if any
            if (sb[idx].len > 0) {
                self.allocator.free(sb[idx]);
            }

            // Allocate and copy the line
            const new_line = self.allocator.alloc(Cell, self.cols) catch {
                sb[idx] = &[_]Cell{};
                continue;
            };
            const src_start = i * self.cols;
            @memcpy(new_line, self.cells[src_start..][0..self.cols]);
            sb[idx] = new_line;
        }
    }

    /// Scroll down by n lines within scroll region
    pub fn scrollDown(self: *Self, n: u32) void {
        const lines_to_scroll = @min(n, self.scroll_bottom - self.scroll_top + 1);
        const start_row = self.scroll_top;
        const end_row = self.scroll_bottom;

        // Move lines down (iterate in reverse to avoid overlap issues)
        var row = end_row;
        while (row >= start_row + lines_to_scroll) : (row -= 1) {
            const src_start = (row - lines_to_scroll) * self.cols;
            const dst_start = row * self.cols;
            @memcpy(self.cells[dst_start..][0..self.cols], self.cells[src_start..][0..self.cols]);
            if (row == start_row + lines_to_scroll) break;
        }

        // Clear top lines using block fill
        const clear_start = start_row * self.cols;
        const clear_count = lines_to_scroll * self.cols;
        @memset(self.cells[clear_start..][0..clear_count], Cell.blank());

        // Mark all rows in scroll region as dirty using block fill
        @memset(self.dirty_rows[start_row..][0 .. end_row - start_row + 1], true);
    }

    /// Set cursor position (0-indexed)
    pub fn setCursor(self: *Self, col: u32, row: u32) void {
        const old_row = self.cursor_row;
        self.cursor_col = @min(col, self.cols - 1);
        self.cursor_row = @min(row, self.rows - 1);
        // Mark both old and new cursor rows dirty
        self.markRowDirty(old_row);
        self.markRowDirty(self.cursor_row);
    }

    /// Move cursor up by n rows
    pub fn cursorUp(self: *Self, n: u32) void {
        const old_row = self.cursor_row;
        if (n <= self.cursor_row) {
            self.cursor_row -= n;
        } else {
            self.cursor_row = 0;
        }
        self.markRowDirty(old_row);
        self.markRowDirty(self.cursor_row);
    }

    /// Move cursor down by n rows
    pub fn cursorDown(self: *Self, n: u32) void {
        const old_row = self.cursor_row;
        self.cursor_row = @min(self.cursor_row + n, self.rows - 1);
        self.markRowDirty(old_row);
        self.markRowDirty(self.cursor_row);
    }

    /// Move cursor right by n columns
    pub fn cursorRight(self: *Self, n: u32) void {
        self.cursor_col = @min(self.cursor_col + n, self.cols - 1);
        self.markRowDirty(self.cursor_row);
    }

    /// Move cursor left by n columns
    pub fn cursorLeft(self: *Self, n: u32) void {
        if (n <= self.cursor_col) {
            self.cursor_col -= n;
        } else {
            self.cursor_col = 0;
        }
        self.markRowDirty(self.cursor_row);
    }

    /// Erase from cursor to end of line
    pub fn eraseToEndOfLine(self: *Self) void {
        const start = self.cursor_row * self.cols + self.cursor_col;
        const count = self.cols - self.cursor_col;
        @memset(self.cells[start..][0..count], Cell.blank());
        self.markRowDirty(self.cursor_row);
    }

    /// Erase from start of line to cursor
    pub fn eraseToStartOfLine(self: *Self) void {
        const start = self.cursor_row * self.cols;
        const count = self.cursor_col + 1;
        @memset(self.cells[start..][0..count], Cell.blank());
        self.markRowDirty(self.cursor_row);
    }

    /// Erase entire line
    pub fn eraseLine(self: *Self) void {
        const start = self.cursor_row * self.cols;
        @memset(self.cells[start..][0..self.cols], Cell.blank());
        self.markRowDirty(self.cursor_row);
    }

    /// Erase from cursor to end of screen
    pub fn eraseToEndOfScreen(self: *Self) void {
        // Erase from cursor to end of current line
        const line_start = self.cursor_row * self.cols + self.cursor_col;
        const line_count = self.cols - self.cursor_col;
        @memset(self.cells[line_start..][0..line_count], Cell.blank());

        // Erase all remaining lines
        if (self.cursor_row + 1 < self.rows) {
            const start = (self.cursor_row + 1) * self.cols;
            const count = (self.rows - self.cursor_row - 1) * self.cols;
            @memset(self.cells[start..][0..count], Cell.blank());
            @memset(self.dirty_rows[self.cursor_row + 1 ..][0 .. self.rows - self.cursor_row - 1], true);
        }
        self.markRowDirty(self.cursor_row);
    }

    /// Erase from start of screen to cursor
    pub fn eraseToStartOfScreen(self: *Self) void {
        // Erase all lines before cursor row
        if (self.cursor_row > 0) {
            const count = self.cursor_row * self.cols;
            @memset(self.cells[0..count], Cell.blank());
            @memset(self.dirty_rows[0..self.cursor_row], true);
        }

        // Erase from start of cursor line to cursor
        const line_start = self.cursor_row * self.cols;
        const line_count = self.cursor_col + 1;
        @memset(self.cells[line_start..][0..line_count], Cell.blank());
        self.markRowDirty(self.cursor_row);
    }

    /// Erase entire screen
    pub fn eraseScreen(self: *Self) void {
        @memset(self.cells, Cell.blank());
        self.markAllRowsDirty();
    }

    /// Set scroll region
    pub fn setScrollRegion(self: *Self, top: u32, bottom: u32) void {
        self.scroll_top = @min(top, self.rows - 1);
        self.scroll_bottom = @min(bottom, self.rows - 1);
        if (self.scroll_top > self.scroll_bottom) {
            self.scroll_top = 0;
            self.scroll_bottom = self.rows - 1;
        }
    }

    /// Delete n characters at cursor, shift remaining left
    ///
    /// AD-16.6: pre-fix this used `@memcpy` for the leftward shift.
    /// When `chars_to_delete > 0` and `chars_to_shift > chars_to_delete`,
    /// the source and destination slices overlap (source is `chars_to_delete`
    /// cells ahead of destination, but the slices each span `chars_to_shift`
    /// cells). Zig's `@memcpy` requires the slices to not alias at all
    /// and panics with "arguments alias" when they do. Triggered in
    /// practice by `ls` output during 2026-05-11 bench testing.
    ///
    /// Post-fix uses a manual forward loop. For a left-shift, forward
    /// iteration is safe because at iteration `i` we write to
    /// `dst_start + i` and read from `src_start + i` where
    /// `src_start > dst_start`; future iterations only read from
    /// positions `>= src_start + i + 1`, which are strictly greater
    /// than the position just written. No source cell is read after
    /// it has been clobbered.
    pub fn deleteChars(self: *Self, n: u32) void {
        const row_start = self.cursor_row * self.cols;
        const chars_to_delete = @min(n, self.cols - self.cursor_col);

        if (chars_to_delete == 0) return;

        const chars_to_shift = self.cols - self.cursor_col - chars_to_delete;

        // Shift characters left using forward iteration (safe for left-shift
        // overlap; see AD-16.6 comment above).
        const dst_start = row_start + self.cursor_col;
        const src_start = row_start + self.cursor_col + chars_to_delete;
        var i: u32 = 0;
        while (i < chars_to_shift) : (i += 1) {
            self.cells[dst_start + i] = self.cells[src_start + i];
        }

        // Clear remaining using block fill
        const clear_start = row_start + self.cursor_col + chars_to_shift;
        @memset(self.cells[clear_start..][0..chars_to_delete], Cell.blank());
        self.markRowDirty(self.cursor_row);
    }

    /// Insert n characters at cursor, shift remaining right
    ///
    /// AD-16.4: when `chars_to_insert == 0` (either `n == 0` or
    /// cursor at the right edge with no room to insert), the shift
    /// loop's condition `col >= cursor_col + 0` becomes `col >=
    /// cursor_col`. After processing `col == cursor_col`, the
    /// `col -= 1` step underflows `u32` to `MAX_U32` and the loop
    /// runs forever (or until the index is out of bounds and panics).
    /// Skip the shift entirely when there is nothing to insert.
    pub fn insertChars(self: *Self, n: u32) void {
        const row_start = self.cursor_row * self.cols;
        const chars_to_insert = @min(n, self.cols - self.cursor_col);

        if (chars_to_insert == 0) return;

        // Shift characters right using backward copy (reverse iteration for overlapping regions)
        var col = self.cols - 1;
        while (col >= self.cursor_col + chars_to_insert) : (col -= 1) {
            self.cells[row_start + col] = self.cells[row_start + col - chars_to_insert];
            if (col == self.cursor_col + chars_to_insert) break;
        }

        // Clear inserted area using block fill
        const clear_start = row_start + self.cursor_col;
        @memset(self.cells[clear_start..][0..chars_to_insert], Cell.blank());
        self.markRowDirty(self.cursor_row);
    }

    /// Delete n lines at cursor row, scroll rest up
    pub fn deleteLines(self: *Self, n: u32) void {
        const old_top = self.scroll_top;
        self.scroll_top = self.cursor_row;
        self.scrollUp(n);
        self.scroll_top = old_top;
    }

    /// Insert n lines at cursor row, scroll rest down
    pub fn insertLines(self: *Self, n: u32) void {
        const old_top = self.scroll_top;
        self.scroll_top = self.cursor_row;
        self.scrollDown(n);
        self.scroll_top = old_top;
    }

    // ========================================================================
    // Alternative screen buffer support (DECSET/DECRST modes 47, 1047, 1049)
    // ========================================================================

    /// Switch to alternative screen buffer
    /// If clear is true, clears the alt buffer (mode 1047/1049)
    pub fn enterAltBuffer(self: *Self, clear: bool) !void {
        if (self.using_alt_buffer) return;

        // Allocate alt buffer if not already allocated
        if (self.alt_cells == null) {
            self.alt_cells = try self.allocator.alloc(Cell, self.cols * self.rows);
        }

        // Swap buffers
        const temp = self.cells;
        self.cells = self.alt_cells.?;
        self.alt_cells = temp;

        self.using_alt_buffer = true;

        // Clear if requested (mode 1047/1049)
        if (clear) {
            for (self.cells) |*cell| {
                cell.* = Cell.blank();
            }
        }

        self.markAllRowsDirty();
    }

    /// Switch back to main screen buffer
    pub fn exitAltBuffer(self: *Self) void {
        if (!self.using_alt_buffer) return;

        // Swap buffers back
        const temp = self.cells;
        self.cells = self.alt_cells.?;
        self.alt_cells = temp;

        self.using_alt_buffer = false;
        self.markAllRowsDirty();
    }

    // ========================================================================
    // Cursor save/restore (DECSC/DECRC - ESC 7/8, CSI s/u)
    // ========================================================================

    /// Save cursor position and attributes (DECSC)
    pub fn saveCursor(self: *Self) void {
        self.saved_cursor_col = self.cursor_col;
        self.saved_cursor_row = self.cursor_row;
        self.saved_attr = self.current_attr;
    }

    /// Restore cursor position and attributes (DECRC)
    pub fn restoreCursor(self: *Self) void {
        const old_row = self.cursor_row;
        self.cursor_col = @min(self.saved_cursor_col, self.cols -| 1);
        self.cursor_row = @min(self.saved_cursor_row, self.rows -| 1);
        self.current_attr = self.saved_attr;
        self.markRowDirty(old_row);
        self.markRowDirty(self.cursor_row);
    }

    /// Enter alternate screen with cursor save (mode 1049)
    /// Saves cursor, switches to alt buffer, and clears it
    pub fn enterAltBufferWithCursorSave(self: *Self) !void {
        self.saveCursor();
        try self.enterAltBuffer(true);
    }

    /// Exit alternate screen with cursor restore (mode 1049)
    /// Switches back to main buffer and restores cursor
    pub fn exitAltBufferWithCursorRestore(self: *Self) void {
        self.exitAltBuffer();
        self.restoreCursor();
    }

    /// Set cursor visibility
    pub fn setCursorVisible(self: *Self, visible: bool) void {
        self.cursor_visible = visible;
        self.markRowDirty(self.cursor_row);
    }

    /// Set cursor style (DECSCUSR)
    pub fn setCursorStyle(self: *Self, style: CursorStyle) void {
        self.cursor_style = style;
        self.cursor_blink = style.shouldBlink();
        self.markRowDirty(self.cursor_row);
    }

    /// Get current cursor style
    pub fn getCursorStyle(self: *const Self) CursorStyle {
        return self.cursor_style;
    }

    /// Get cursor shape (block, underline, or bar)
    pub fn getCursorShape(self: *const Self) CursorStyle.Shape {
        return self.cursor_style.shape();
    }

    /// Check if cursor should blink
    pub fn shouldCursorBlink(self: *const Self) bool {
        return self.cursor_blink;
    }

    // ========================================================================
    // Terminal title (OSC 0/1/2)
    // ========================================================================

    /// Set window title (OSC 2) or both title and icon name (OSC 0)
    pub fn setTitle(self: *Self, text: []const u8) void {
        const len = @min(text.len, 255);
        @memcpy(self.title[0..len], text[0..len]);
        self.title_len = @intCast(len);
        self.title[len] = 0; // Null terminate
    }

    /// Set icon name (OSC 1)
    pub fn setIconName(self: *Self, text: []const u8) void {
        const len = @min(text.len, 255);
        @memcpy(self.icon_name[0..len], text[0..len]);
        self.icon_name_len = @intCast(len);
        self.icon_name[len] = 0; // Null terminate
    }

    /// Get current window title as a slice
    pub fn getTitle(self: *const Self) []const u8 {
        return self.title[0..self.title_len];
    }

    /// Get current icon name as a slice
    pub fn getIconName(self: *const Self) []const u8 {
        return self.icon_name[0..self.icon_name_len];
    }

    // ========================================================================
    // Color palette customization (OSC 4/10/11)
    // ========================================================================

    /// Set a custom palette color (OSC 4)
    pub fn setPaletteColor(self: *Self, index: u8, r: u8, g: u8, b: u8) !void {
        // Allocate custom palette on first use
        if (self.custom_palette == null) {
            self.custom_palette = try self.allocator.create([256][3]u8);
            // Initialize with default palette
            for (0..256) |i| {
                const default_rgb = (Color{ .indexed = @intCast(i) }).toRgb();
                self.custom_palette.?[i] = .{ default_rgb.r, default_rgb.g, default_rgb.b };
            }
        }
        self.custom_palette.?[index] = .{ r, g, b };
    }

    /// Set custom foreground color (OSC 10)
    pub fn setForegroundColor(self: *Self, r: u8, g: u8, b: u8) void {
        self.custom_fg = .{ r, g, b };
    }

    /// Set custom background color (OSC 11)
    pub fn setBackgroundColor(self: *Self, r: u8, g: u8, b: u8) void {
        self.custom_bg = .{ r, g, b };
    }

    /// Reset palette color to default (OSC 104)
    pub fn resetPaletteColor(self: *Self, index: u8) void {
        if (self.custom_palette) |palette| {
            const default_rgb = (Color{ .indexed = index }).toRgb();
            palette[index] = .{ default_rgb.r, default_rgb.g, default_rgb.b };
        }
    }

    /// Reset all palette colors to default (OSC 104 with no args)
    pub fn resetPalette(self: *Self) void {
        if (self.custom_palette) |palette| {
            self.allocator.destroy(palette);
            self.custom_palette = null;
        }
    }

    /// Reset foreground color to default (OSC 110)
    pub fn resetForegroundColor(self: *Self) void {
        self.custom_fg = null;
    }

    /// Reset background color to default (OSC 111)
    pub fn resetBackgroundColor(self: *Self) void {
        self.custom_bg = null;
    }

    /// Get effective palette color (custom if set, else default)
    pub fn getPaletteColor(self: *const Self, index: u8) struct { r: u8, g: u8, b: u8 } {
        if (self.custom_palette) |palette| {
            return .{ .r = palette[index][0], .g = palette[index][1], .b = palette[index][2] };
        }
        return (Color{ .indexed = index }).toRgb();
    }

    /// Get effective foreground color (custom if set, else default)
    pub fn getEffectiveForeground(self: *const Self) struct { r: u8, g: u8, b: u8 } {
        if (self.custom_fg) |fg| {
            return .{ .r = fg[0], .g = fg[1], .b = fg[2] };
        }
        return Color.default_fg.toRgb();
    }

    /// Get effective background color (custom if set, else default)
    pub fn getEffectiveBackground(self: *const Self) struct { r: u8, g: u8, b: u8 } {
        if (self.custom_bg) |bg| {
            return .{ .r = bg[0], .g = bg[1], .b = bg[2] };
        }
        return Color.default_bg.toRgb();
    }

    // ========================================================================
    // Mouse tracking (DECSET modes 9, 1000-1006, 1015)
    // ========================================================================

    /// Set mouse tracking mode
    pub fn setMouseTracking(self: *Self, mode: MouseTrackingMode) void {
        self.mouse_tracking = mode;
    }

    /// Get current mouse tracking mode
    pub fn getMouseTracking(self: *const Self) MouseTrackingMode {
        return self.mouse_tracking;
    }

    /// Set mouse encoding mode
    pub fn setMouseEncoding(self: *Self, mode: MouseEncodingMode) void {
        self.mouse_encoding = mode;
    }

    /// Get current mouse encoding mode
    pub fn getMouseEncoding(self: *const Self) MouseEncodingMode {
        return self.mouse_encoding;
    }

    /// Enable/disable focus event reporting (mode 1004)
    pub fn setFocusEvents(self: *Self, enabled: bool) void {
        self.mouse_focus_events = enabled;
    }

    /// Check if focus event reporting is enabled
    pub fn getFocusEvents(self: *const Self) bool {
        return self.mouse_focus_events;
    }

    /// Check if any mouse tracking is enabled
    pub fn isMouseTrackingEnabled(self: *const Self) bool {
        return self.mouse_tracking != .none;
    }

    // ========================================================================
    // Scrollback buffer navigation
    // ========================================================================

    /// Scroll view up (into history) by n lines
    /// Returns true if scroll position changed
    pub fn scrollViewUp(self: *Self, n: u32) bool {
        if (self.scrollback_count == 0) return false;

        const max_offset = self.scrollback_count;
        const new_offset = @min(self.scroll_view_offset + n, max_offset);

        if (new_offset != self.scroll_view_offset) {
            self.scroll_view_offset = new_offset;
            self.markAllRowsDirty();
            return true;
        }
        return false;
    }

    /// Scroll view down (toward present) by n lines
    /// Returns true if scroll position changed
    pub fn scrollViewDown(self: *Self, n: u32) bool {
        if (self.scroll_view_offset == 0) return false;

        if (n >= self.scroll_view_offset) {
            self.scroll_view_offset = 0;
        } else {
            self.scroll_view_offset -= n;
        }
        self.markAllRowsDirty();
        return true;
    }

    /// Reset scroll view to bottom (present)
    pub fn resetScrollView(self: *Self) void {
        if (self.scroll_view_offset > 0) {
            self.scroll_view_offset = 0;
            self.markAllRowsDirty();
        }
    }

    /// Check if currently viewing scrollback
    pub fn isViewingScrollback(self: *const Self) bool {
        return self.scroll_view_offset > 0;
    }

    /// Get cell at visible position (considering scroll offset)
    /// This returns the cell that should be displayed at the given screen position
    ///
    /// AD-16.5: when the user has scrolled far enough back that the
    /// view is entirely in scrollback (`scrollback_lines_visible >=
    /// rows`), `rows - scrollback_lines_visible` underflows `u32` and
    /// `screen_lines_visible` becomes a near-`MAX_U32` value, allowing
    /// the `screen_row >= screen_lines_visible` check below to wrongly
    /// admit out-of-range indices into `self.cells`. Cap the
    /// computation at zero explicitly.
    pub fn getVisibleCell(self: *const Self, col: u32, row: u32) Cell {
        if (self.scroll_view_offset == 0) {
            // Not scrolled, return normal cell
            return self.cells[row * self.cols + col];
        }

        // Calculate which line this row maps to in the combined view
        // scroll_view_offset = how many lines of scrollback we're viewing
        // The visible area is: [scrollback history] + [screen buffer]
        // With scroll_view_offset, we're looking at an earlier slice

        const scrollback_lines_visible = @min(self.scroll_view_offset, self.scrollback_count);
        const screen_lines_visible: u32 = if (scrollback_lines_visible >= self.rows)
            0
        else
            self.rows - scrollback_lines_visible;

        if (row < scrollback_lines_visible) {
            // This row is from scrollback
            const sb = self.scrollback orelse return Cell.blank();

            // Calculate which scrollback line to show
            // scrollback_count - scroll_view_offset + row gives us the line index
            // We need to account for the ring buffer
            const lines_from_end = self.scroll_view_offset - row;
            if (lines_from_end > self.scrollback_count) {
                return Cell.blank();
            }
            const line_idx = self.scrollback_count - lines_from_end;

            // Convert to ring buffer index
            const ring_idx = (self.scrollback_start + line_idx) % self.scrollback_max;
            const line = sb[ring_idx];
            if (line.len == 0 or col >= line.len) {
                return Cell.blank();
            }
            return line[col];
        } else {
            // This row is from screen buffer
            const screen_row = row - scrollback_lines_visible;
            if (screen_row >= screen_lines_visible) {
                return Cell.blank();
            }
            return self.cells[screen_row * self.cols + col];
        }
    }

    /// Get the number of lines available in scrollback
    pub fn getScrollbackCount(self: *const Self) u32 {
        return self.scrollback_count;
    }

    /// Validate terminal state invariants (debug mode only)
    /// Returns error details if validation fails, null if all invariants hold
    pub fn validateState(self: *const Self) ?StateValidationError {
        // Cursor bounds check
        if (self.cursor_col >= self.cols) {
            return .{ .kind = .cursor_col_out_of_bounds, .value = self.cursor_col, .limit = self.cols };
        }
        if (self.cursor_row >= self.rows) {
            return .{ .kind = .cursor_row_out_of_bounds, .value = self.cursor_row, .limit = self.rows };
        }

        // Scroll region validation
        if (self.scroll_top >= self.rows) {
            return .{ .kind = .scroll_top_out_of_bounds, .value = self.scroll_top, .limit = self.rows };
        }
        if (self.scroll_bottom >= self.rows) {
            return .{ .kind = .scroll_bottom_out_of_bounds, .value = self.scroll_bottom, .limit = self.rows };
        }
        if (self.scroll_top > self.scroll_bottom) {
            return .{ .kind = .scroll_region_inverted, .value = self.scroll_top, .limit = self.scroll_bottom };
        }

        // Scrollback buffer validation
        if (self.scrollback_max > 0) {
            if (self.scrollback_count > self.scrollback_max) {
                return .{ .kind = .scrollback_count_exceeds_max, .value = self.scrollback_count, .limit = self.scrollback_max };
            }
            if (self.scrollback_count > 0 and self.scrollback_start >= self.scrollback_max) {
                return .{ .kind = .scrollback_start_out_of_bounds, .value = self.scrollback_start, .limit = self.scrollback_max };
            }
        }

        // Scroll view validation
        if (self.scroll_view_offset > self.scrollback_count) {
            return .{ .kind = .scroll_view_exceeds_scrollback, .value = self.scroll_view_offset, .limit = self.scrollback_count };
        }

        return null; // All invariants hold
    }

    /// Assert that terminal state is valid (panics in debug mode if invalid)
    pub fn assertValid(self: *const Self) void {
        if (@import("builtin").mode == .Debug) {
            if (self.validateState()) |err| {
                std.debug.panic("Terminal state validation failed: {s} (value={}, limit={})", .{
                    @tagName(err.kind),
                    err.value,
                    err.limit,
                });
            }
        }
    }

    pub const StateValidationError = struct {
        kind: ErrorKind,
        value: u32,
        limit: u32,

        pub const ErrorKind = enum {
            cursor_col_out_of_bounds,
            cursor_row_out_of_bounds,
            scroll_top_out_of_bounds,
            scroll_bottom_out_of_bounds,
            scroll_region_inverted,
            scrollback_count_exceeds_max,
            scrollback_start_out_of_bounds,
            scroll_view_exceeds_scrollback,
        };
    };
};

/// Character cell
pub const Cell = struct {
    char: u21, // Unicode codepoint
    attr: Attr,
    /// Width of this character (1 for most, 2 for wide chars, 0 for continuation)
    width: u2,
    /// Cached glyph index for fast rendering (avoids charToIndex lookup per frame)
    glyph_idx: u32,

    pub fn blank() Cell {
        return .{
            .char = ' ',
            .attr = Attr.default(),
            .width = 1,
            .glyph_idx = font.Font.charToIndexWithFallback(' '),
        };
    }

    /// Create a cell for a wide character's continuation
    pub fn wideContinuation() Cell {
        return .{
            .char = 0,
            .attr = Attr.default(),
            .width = 0,
            .glyph_idx = font.Font.FALLBACK_INDEX,
        };
    }
};

/// Character attributes
pub const Attr = struct {
    fg: Color,
    bg: Color,
    bold: bool,
    dim: bool,
    italic: bool,
    underline: UnderlineStyle,
    blink: bool,
    reverse: bool,
    hidden: bool,
    strikethrough: bool,
    overline: bool,

    /// Underline style options
    pub const UnderlineStyle = enum(u8) {
        none = 0,
        single = 1,
        double = 2,
    };

    pub fn default() Attr {
        return .{
            .fg = Color.default_fg,
            .bg = Color.default_bg,
            .bold = false,
            .dim = false,
            .italic = false,
            .underline = .none,
            .blink = false,
            .reverse = false,
            .hidden = false,
            .strikethrough = false,
            .overline = false,
        };
    }

    /// Get effective foreground color (considering reverse video)
    pub fn effectiveFg(self: Attr) Color {
        return if (self.reverse) self.bg else self.fg;
    }

    /// Get effective background color (considering reverse video)
    pub fn effectiveBg(self: Attr) Color {
        return if (self.reverse) self.fg else self.bg;
    }
};

/// Terminal color (16 basic + 256 extended + RGB)
pub const Color = union(enum) {
    indexed: u8, // 0-255
    rgb: struct { r: u8, g: u8, b: u8 },

    pub const default_fg = Color{ .indexed = 7 }; // white/light gray
    pub const default_bg = Color{ .indexed = 0 }; // black

    // Standard 16 colors
    pub const black = Color{ .indexed = 0 };
    pub const red = Color{ .indexed = 1 };
    pub const green = Color{ .indexed = 2 };
    pub const yellow = Color{ .indexed = 3 };
    pub const blue = Color{ .indexed = 4 };
    pub const magenta = Color{ .indexed = 5 };
    pub const cyan = Color{ .indexed = 6 };
    pub const white = Color{ .indexed = 7 };
    pub const bright_black = Color{ .indexed = 8 };
    pub const bright_red = Color{ .indexed = 9 };
    pub const bright_green = Color{ .indexed = 10 };
    pub const bright_yellow = Color{ .indexed = 11 };
    pub const bright_blue = Color{ .indexed = 12 };
    pub const bright_magenta = Color{ .indexed = 13 };
    pub const bright_cyan = Color{ .indexed = 14 };
    pub const bright_white = Color{ .indexed = 15 };

    /// Convert indexed color to RGB (standard VGA palette)
    pub fn toRgb(self: Color) struct { r: u8, g: u8, b: u8 } {
        switch (self) {
            .rgb => |c| return .{ .r = c.r, .g = c.g, .b = c.b },
            .indexed => |idx| {
                if (idx < 16) {
                    // Standard 16 colors (VGA palette)
                    const palette = [16][3]u8{
                        .{ 0, 0, 0 }, // black
                        .{ 170, 0, 0 }, // red
                        .{ 0, 170, 0 }, // green
                        .{ 170, 85, 0 }, // yellow/brown
                        .{ 0, 0, 170 }, // blue
                        .{ 170, 0, 170 }, // magenta
                        .{ 0, 170, 170 }, // cyan
                        .{ 170, 170, 170 }, // white
                        .{ 85, 85, 85 }, // bright black (gray)
                        .{ 255, 85, 85 }, // bright red
                        .{ 85, 255, 85 }, // bright green
                        .{ 255, 255, 85 }, // bright yellow
                        .{ 85, 85, 255 }, // bright blue
                        .{ 255, 85, 255 }, // bright magenta
                        .{ 85, 255, 255 }, // bright cyan
                        .{ 255, 255, 255 }, // bright white
                    };
                    return .{ .r = palette[idx][0], .g = palette[idx][1], .b = palette[idx][2] };
                } else if (idx < 232) {
                    // 216-color cube (indices 16-231)
                    const cube_idx = idx - 16;
                    const b_val: u8 = @intCast(cube_idx % 6);
                    const g_val: u8 = @intCast((cube_idx / 6) % 6);
                    const r_val: u8 = @intCast(cube_idx / 36);
                    const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
                    return .{ .r = levels[r_val], .g = levels[g_val], .b = levels[b_val] };
                } else {
                    // Grayscale (indices 232-255)
                    const gray_level: u8 = @intCast(8 + (idx - 232) * 10);
                    return .{ .r = gray_level, .g = gray_level, .b = gray_level };
                }
            },
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Screen basic operations" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 24);
    defer scr.deinit();

    try std.testing.expectEqual(@as(u32, 0), scr.cursor_col);
    try std.testing.expectEqual(@as(u32, 0), scr.cursor_row);

    scr.putChar('H');
    scr.putChar('i');

    try std.testing.expectEqual(@as(u32, 2), scr.cursor_col);
    try std.testing.expectEqual(@as(u21, 'H'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), scr.getCell(1, 0).char);
}

test "Screen Unicode support" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 24);
    defer scr.deinit();

    // Test ASCII
    scr.putChar('A');
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u2, 1), scr.getCell(0, 0).width);

    // Test accented character (single-width)
    scr.putChar(0x00E9); // é
    try std.testing.expectEqual(@as(u21, 0x00E9), scr.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u2, 1), scr.getCell(1, 0).width);

    // Test CJK character (double-width)
    scr.putChar(0x4E2D); // 中
    try std.testing.expectEqual(@as(u21, 0x4E2D), scr.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u2, 2), scr.getCell(2, 0).width);
    try std.testing.expectEqual(@as(u2, 0), scr.getCell(3, 0).width); // continuation
    try std.testing.expectEqual(@as(u32, 4), scr.cursor_col);
}

test "Screen newline and scroll" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 3);
    defer scr.deinit();

    scr.setCursor(0, 2);
    scr.putChar('A');
    scr.newline();
    scr.putChar('B');

    // A should have scrolled up
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'B'), scr.getCell(0, 2).char);
}

test "Color RGB conversion" {
    const black = Color.black.toRgb();
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);

    const white = Color.bright_white.toRgb();
    try std.testing.expectEqual(@as(u8, 255), white.r);
    try std.testing.expectEqual(@as(u8, 255), white.g);
    try std.testing.expectEqual(@as(u8, 255), white.b);
}

test "Screen alternative buffer" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 24);
    defer scr.deinit();

    // Write to main buffer
    scr.putChar('M');
    scr.putChar('a');
    scr.putChar('i');
    scr.putChar('n');
    try std.testing.expectEqual(@as(u21, 'M'), scr.getCell(0, 0).char);
    try std.testing.expect(!scr.using_alt_buffer);

    // Switch to alt buffer (with clear)
    try scr.enterAltBuffer(true);
    try std.testing.expect(scr.using_alt_buffer);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(0, 0).char);

    // Write to alt buffer. Plain enterAltBuffer (mode 47) deliberately
    // does NOT move the cursor; only the 1049 WithCursorSave variant
    // touches it. Home explicitly so the assertion below tests buffer
    // isolation, not cursor position. (Expectation corrected when this
    // test first ran, 2026-07-15; it had never been wired to run.)
    scr.setCursor(0, 0);
    scr.putChar('A');
    scr.putChar('l');
    scr.putChar('t');
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);

    // Switch back to main buffer
    scr.exitAltBuffer();
    try std.testing.expect(!scr.using_alt_buffer);
    try std.testing.expectEqual(@as(u21, 'M'), scr.getCell(0, 0).char);
}

test "Screen cursor save/restore" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 24);
    defer scr.deinit();

    // Move cursor and set attribute
    scr.setCursor(10, 5);
    scr.current_attr.bold = true;

    // Save cursor
    scr.saveCursor();

    // Move cursor and change attribute
    scr.setCursor(30, 20);
    scr.current_attr.bold = false;
    scr.current_attr.italic = true;

    try std.testing.expectEqual(@as(u32, 30), scr.cursor_col);
    try std.testing.expectEqual(@as(u32, 20), scr.cursor_row);

    // Restore cursor
    scr.restoreCursor();

    try std.testing.expectEqual(@as(u32, 10), scr.cursor_col);
    try std.testing.expectEqual(@as(u32, 5), scr.cursor_row);
    try std.testing.expect(scr.current_attr.bold);
    try std.testing.expect(!scr.current_attr.italic);
}

test "Screen mode 1049 (alt buffer with cursor save)" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 24);
    defer scr.deinit();

    // Set up initial state
    scr.setCursor(15, 10);
    scr.putChar('X');
    scr.current_attr.underline = .single;

    // Enter alt buffer with cursor save (mode 1049)
    try scr.enterAltBufferWithCursorSave();
    try std.testing.expect(scr.using_alt_buffer);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(0, 0).char); // cleared

    // Move cursor in alt buffer
    scr.setCursor(5, 3);
    scr.putChar('Y');
    scr.current_attr.underline = .none;

    // Exit alt buffer with cursor restore (mode 1049)
    scr.exitAltBufferWithCursorRestore();
    try std.testing.expect(!scr.using_alt_buffer);
    try std.testing.expectEqual(@as(u32, 16), scr.cursor_col); // restored after 'X' was written
    try std.testing.expectEqual(@as(u32, 10), scr.cursor_row);
    try std.testing.expect(scr.current_attr.underline == .single);
    try std.testing.expectEqual(@as(u21, 'X'), scr.getCell(15, 10).char); // main buffer preserved
}

test "Scrollback buffer saves lines" {
    const allocator = std.testing.allocator;
    // Create a small screen with scrollback enabled
    var scr = try Screen.initWithScrollback(allocator, 10, 3, 10);
    defer scr.deinit();

    // Fill the screen
    scr.setCursor(0, 0);
    scr.putChar('L');
    scr.putChar('1');
    scr.setCursor(0, 1);
    scr.putChar('L');
    scr.putChar('2');
    scr.setCursor(0, 2);
    scr.putChar('L');
    scr.putChar('3');

    try std.testing.expectEqual(@as(u32, 0), scr.scrollback_count);

    // Scroll up (this should save L1 to scrollback)
    scr.setCursor(0, 2);
    scr.newline(); // This triggers scrollUp

    try std.testing.expectEqual(@as(u32, 1), scr.scrollback_count);
    // L2 should now be on row 0, L3 on row 1
    try std.testing.expectEqual(@as(u21, 'L'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, '2'), scr.getCell(1, 0).char);
}

test "Scrollback view navigation" {
    const allocator = std.testing.allocator;
    var scr = try Screen.initWithScrollback(allocator, 10, 3, 10);
    defer scr.deinit();

    // Fill with multiple lines and scroll them into history
    var line_num: u8 = '0';
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        scr.setCursor(0, 2);
        scr.putChar('L');
        scr.putChar(line_num);
        line_num += 1;
        scr.newline();
    }

    // Every iteration re-homes to the bottom row, so every newline
    // scrolls: six iterations, six lines in scrollback. (Expectation
    // corrected from 4 when this test first ran, 2026-07-15; the
    // original arithmetic assumed sequential writing without the
    // per-iteration setCursor.)
    try std.testing.expectEqual(@as(u32, 6), scr.scrollback_count);
    try std.testing.expectEqual(@as(u32, 0), scr.scroll_view_offset);

    // Scroll view up into history
    try std.testing.expect(scr.scrollViewUp(2));
    try std.testing.expectEqual(@as(u32, 2), scr.scroll_view_offset);
    try std.testing.expect(scr.isViewingScrollback());

    // Scroll view down
    try std.testing.expect(scr.scrollViewDown(1));
    try std.testing.expectEqual(@as(u32, 1), scr.scroll_view_offset);

    // Reset scroll view
    scr.resetScrollView();
    try std.testing.expectEqual(@as(u32, 0), scr.scroll_view_offset);
    try std.testing.expect(!scr.isViewingScrollback());
}

test "Scrollback getVisibleCell" {
    const allocator = std.testing.allocator;
    var scr = try Screen.initWithScrollback(allocator, 10, 3, 10);
    defer scr.deinit();

    // Put 'A' on first line, scroll it into history
    scr.putChar('A');
    scr.setCursor(0, 2);
    scr.newline();

    // Now 'A' is in scrollback, screen is empty
    try std.testing.expectEqual(@as(u32, 1), scr.scrollback_count);

    // Without scrollback view, we see the current screen
    try std.testing.expectEqual(@as(u21, ' '), scr.getVisibleCell(0, 0).char);

    // Scroll up to view history
    _ = scr.scrollViewUp(1);

    // Now we should see the scrollback line
    try std.testing.expectEqual(@as(u21, 'A'), scr.getVisibleCell(0, 0).char);
}

test "Scrollback not saved from alt buffer" {
    const allocator = std.testing.allocator;
    var scr = try Screen.initWithScrollback(allocator, 10, 3, 10);
    defer scr.deinit();

    // Put something on main screen
    scr.putChar('M');

    // Switch to alt buffer
    try scr.enterAltBuffer(true);
    try std.testing.expect(scr.using_alt_buffer);

    // Scroll in alt buffer - should NOT save to scrollback
    scr.putChar('A');
    scr.setCursor(0, 2);
    scr.newline();

    try std.testing.expectEqual(@as(u32, 0), scr.scrollback_count);

    // Exit alt buffer
    scr.exitAltBuffer();
    try std.testing.expectEqual(@as(u32, 0), scr.scrollback_count);
}

test "State validation" {
    const allocator = std.testing.allocator;
    var scr = try Screen.initWithScrollback(allocator, 10, 5, 10);
    defer scr.deinit();

    // Initial state should be valid
    try std.testing.expectEqual(@as(?Screen.StateValidationError, null), scr.validateState());

    // Valid cursor position
    scr.setCursor(9, 4);
    try std.testing.expectEqual(@as(?Screen.StateValidationError, null), scr.validateState());

    // Valid scroll region
    scr.setScrollRegion(1, 3);
    try std.testing.expectEqual(@as(?Screen.StateValidationError, null), scr.validateState());

    // Reset scroll region
    scr.setScrollRegion(0, 4);
    try std.testing.expectEqual(@as(?Screen.StateValidationError, null), scr.validateState());

    // After scrolling, state should still be valid
    scr.setCursor(0, 4);
    scr.newline();
    try std.testing.expectEqual(@as(?Screen.StateValidationError, null), scr.validateState());

    // Scrollback view state should be valid
    if (scr.scrollback_count > 0) {
        _ = scr.scrollViewUp(1);
        try std.testing.expectEqual(@as(?Screen.StateValidationError, null), scr.validateState());
        scr.resetScrollView();
        try std.testing.expectEqual(@as(?Screen.StateValidationError, null), scr.validateState());
    }
}

// ============================================================================
// AD-16: edge-case bug fixes
// ============================================================================
// These tests exercise the specific input sequences that AD-14.2's audit
// identified as latent bugs in screen.zig. They are kept together at the
// bottom of the file rather than scattered into existing test sections so
// the audit-to-fix-to-test mapping stays visible.

test "AD-16.2 putCharWithWidth ignores zero-width characters" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 80, 24);
    defer scr.deinit();

    // ASCII letter advances cursor by 1.
    scr.putChar('A');
    try std.testing.expectEqual(@as(u32, 1), scr.cursor_col);

    // Combining acute accent (U+0301) is width 0 per charWidth().
    // Pre-AD-16.2 this advanced the cursor and overwrote the cell;
    // post-fix it is dropped and the cursor stays put.
    scr.putChar(0x0301);
    try std.testing.expectEqual(@as(u32, 1), scr.cursor_col);
    // The 'A' cell is unchanged.
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);

    // A zero-width-joiner (U+200D) similarly drops.
    scr.putChar(0x200D);
    try std.testing.expectEqual(@as(u32, 1), scr.cursor_col);

    // Subsequent normal write lands at column 1.
    scr.putChar('B');
    try std.testing.expectEqual(@as(u32, 2), scr.cursor_col);
    try std.testing.expectEqual(@as(u21, 'B'), scr.getCell(1, 0).char);
}

test "AD-16.2 putCharWithWidth at right edge does not exceed cols" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 4, 4);
    defer scr.deinit();

    // Fill the row with normal-width chars; cursor lands at cols.
    scr.putChar('A');
    scr.putChar('B');
    scr.putChar('C');
    scr.putChar('D');
    try std.testing.expectEqual(@as(u32, 4), scr.cursor_col);

    // A combining mark here would, pre-fix, advance cursor to 5
    // and the next normal write would call getCellMut(5, 0),
    // which post-AD-16.1 panics. Post-AD-16.2 the combiner is
    // dropped and the next normal write triggers a newline as
    // expected.
    scr.putChar(0x0301);
    try std.testing.expectEqual(@as(u32, 4), scr.cursor_col);

    scr.putChar('E');
    try std.testing.expectEqual(@as(u21, 'E'), scr.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u32, 1), scr.cursor_col);
    try std.testing.expectEqual(@as(u32, 1), scr.cursor_row);
}

test "AD-16.3 scrollUp with n equal to region height clears region" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 4, 3);
    defer scr.deinit();

    // Fill three rows.
    scr.putChar('A');
    scr.newline();
    scr.putChar('B');
    scr.newline();
    scr.putChar('C');
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), scr.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'C'), scr.getCell(0, 2).char);

    // Scroll by exactly the region height (3). Pre-AD-16.3 this
    // underflowed `end_row - lines_to_scroll` (2 - 3 → near-MAX_U32)
    // and produced corrupt output. Post-fix the region is cleared.
    scr.scrollUp(3);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(0, 2).char);
}

test "AD-16.3 scrollUp with n much larger than region also clears" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 4, 3);
    defer scr.deinit();

    scr.putChar('A');
    scr.newline();
    scr.putChar('B');
    scr.newline();
    scr.putChar('C');

    // Larger n is capped to region height in lines_to_scroll.
    scr.scrollUp(100);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(0, 2).char);
}

test "AD-16.3 scrollUp with n=0 is a no-op" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 4, 3);
    defer scr.deinit();

    scr.putChar('A');
    scr.scrollUp(0);
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);
}

test "AD-16.4 insertChars with n=0 is a no-op" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 4, 3);
    defer scr.deinit();

    scr.putChar('A');
    scr.putChar('B');
    scr.setCursor(0, 0);

    // Pre-AD-16.4 this loop ran forever because the chars_to_insert==0
    // case made the backward-copy loop's terminator unreachable
    // (col >= cursor_col + 0 is always true once col reaches 0,
    // and col -= 1 underflows u32). Post-fix it returns immediately.
    scr.insertChars(0);
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), scr.getCell(1, 0).char);
}

test "AD-16.4 insertChars at right edge with no room is a no-op" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 4, 3);
    defer scr.deinit();

    scr.putChar('A');
    scr.putChar('B');
    scr.putChar('C');
    scr.putChar('D');

    // Cursor at cols (no room to insert). Pre-fix the @min in
    // chars_to_insert calculation reduced n to 0 and the loop
    // underflowed. setCursor clamps to cols-1, so the deferred-wrap
    // state (cursor_col == cols) the guard exists for is set
    // directly; via setCursor the cursor lands at the last column,
    // where an insert legitimately shifts D off. (Corrected when
    // this test first ran, 2026-07-15.)
    scr.cursor_col = 4;
    scr.insertChars(5);
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), scr.getCell(3, 0).char);
}

test "AD-16.5 getVisibleCell with scrollback view exceeding rows" {
    const allocator = std.testing.allocator;
    var scr = try Screen.initWithScrollback(allocator, 4, 3, 20);
    defer scr.deinit();

    // Fill enough rows to push lines into scrollback.
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        scr.putChar('A' + @as(u21, @intCast(i)));
        scr.newline();
    }

    // Scroll back further than the screen is tall.
    _ = scr.scrollViewUp(8);

    // Pre-AD-16.5 this read past the cells buffer because
    // screen_lines_visible underflowed to near-MAX_U32 and the
    // bounds check `screen_row >= screen_lines_visible` accepted
    // out-of-range rows. Post-fix the bottom rows return blank.
    const cell = scr.getVisibleCell(0, 2);
    _ = cell; // No panic is the actual assertion; content depends on layout.
}

test "AD-16.6 deleteChars with overlapping shift does not panic" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 8, 2);
    defer scr.deinit();

    // Fill the first row with 'A'..'H'.
    var i: u21 = 0;
    while (i < 8) : (i += 1) {
        scr.putChar('A' + i);
    }

    // Cursor to column 1, delete 1 character. Pre-fix this called
    // @memcpy with dst=cells[1..8] and src=cells[2..9] (overlapping),
    // which panics with "arguments alias" on a debug build. Post-fix
    // uses a manual forward loop, which is safe for left-shifts.
    scr.setCursor(1, 0);
    scr.deleteChars(1);

    // Expected after delete: A C D E F G H _ (where _ is blank).
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), scr.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), scr.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'G'), scr.getCell(5, 0).char);
    try std.testing.expectEqual(@as(u21, 'H'), scr.getCell(6, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(7, 0).char);
}

test "AD-16.6 deleteChars with n=0 is a no-op" {
    const allocator = std.testing.allocator;
    var scr = try Screen.init(allocator, 4, 2);
    defer scr.deinit();

    scr.putChar('A');
    scr.putChar('B');
    scr.putChar('C');
    scr.setCursor(0, 0);

    // Pre-fix this called @memcpy with chars_to_shift = cols - cursor_col
    // and identical src/dst (since chars_to_delete == 0 makes
    // src_start == dst_start). @memcpy on identical slices also fails
    // with "arguments alias". Post-fix returns early.
    scr.deleteChars(0);
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), scr.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), scr.getCell(2, 0).char);
}

// D-12 stage 4: resize under the operator-ratified policy,
// truncate/pad without rewrap, scrollback discarded.

test "resize grows with blank padding and preserves content" {
    var scr = try Screen.init(std.testing.allocator, 4, 2);
    defer scr.deinit();
    scr.putChar('A');
    scr.putChar('B');
    try scr.resize(6, 3);
    try std.testing.expectEqual(@as(u32, 6), scr.cols);
    try std.testing.expectEqual(@as(u32, 3), scr.rows);
    try std.testing.expectEqual(@as(u21, 'A'), scr.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), scr.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), scr.getCell(5, 2).char);
    try std.testing.expectEqual(@as(u32, 2), scr.scroll_bottom);
    try std.testing.expect(scr.dirty);
}

test "resize shrink truncates and clamps cursor and region" {
    var scr = try Screen.init(std.testing.allocator, 8, 4);
    defer scr.deinit();
    scr.cursor_col = 7;
    scr.cursor_row = 3;
    scr.saved_cursor_col = 7;
    scr.saved_cursor_row = 3;
    try scr.resize(3, 2);
    try std.testing.expectEqual(@as(u32, 2), scr.cursor_col);
    try std.testing.expectEqual(@as(u32, 1), scr.cursor_row);
    try std.testing.expectEqual(@as(u32, 2), scr.saved_cursor_col);
    try std.testing.expectEqual(@as(u32, 1), scr.saved_cursor_row);
    try std.testing.expectEqual(@as(u32, 0), scr.scroll_top);
    try std.testing.expectEqual(@as(u32, 1), scr.scroll_bottom);
}

test "resize discards scrollback and resets the view" {
    var scr = try Screen.init(std.testing.allocator, 4, 2);
    defer scr.deinit();
    // Fill and scroll so lines enter scrollback.
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        scr.putChar('x');
        scr.newline();
    }
    try std.testing.expect(scr.scrollback_count > 0);
    scr.scroll_view_offset = 1;
    try scr.resize(5, 3);
    try std.testing.expectEqual(@as(u32, 0), scr.scrollback_count);
    try std.testing.expectEqual(@as(u32, 0), scr.scroll_view_offset);
}

test "resize carries the alt buffer under the same policy" {
    var scr = try Screen.init(std.testing.allocator, 4, 2);
    defer scr.deinit();
    try scr.enterAltBuffer(true);
    scr.putChar('Z');
    try scr.resize(6, 3);
    try std.testing.expectEqual(@as(u21, 'Z'), scr.getCell(0, 0).char);
    scr.exitAltBuffer();
    try std.testing.expectEqual(@as(u32, 6), scr.cols);
}

test "resize to the same size is a no-op and zero is rejected" {
    var scr = try Screen.init(std.testing.allocator, 4, 2);
    defer scr.deinit();
    try scr.resize(4, 2);
    try std.testing.expectError(error.InvalidSize, scr.resize(0, 2));
}
