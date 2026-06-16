const std = @import("std");
const compat = @import("compat");
const posix = std.posix;
const client = @import("semadraw_client");
const screen = @import("screen");
const vt100 = @import("vt100");
const pty = @import("pty");
const renderer = @import("renderer");
const font = @import("font");

const log = std.log.scoped(.semadraw_term);

pub const std_options = std.Options{
    .log_level = .info,
};

// ============================================================================
// Constants
// ============================================================================

/// Maximum number of sessions (Alt+F1 through Alt+F8)
const MAX_SESSIONS: usize = 8;

// ============================================================================
// Session
// ============================================================================

/// A single terminal session: one PTY, one screen, one VT100 parser.
const Session = struct {
    scr:    screen.Screen,
    parser: vt100.Parser,
    shell:  pty.Pty,
    alive:  bool,
    /// True if this session has produced output since last viewed
    bell:   bool,

    fn init(allocator: std.mem.Allocator, shell_path: ?[]const u8, cols: u32, rows: u32) !Session {
        var scr = try screen.Screen.init(allocator, cols, rows);
        errdefer scr.deinit();
        const sh = try pty.Pty.spawn(shell_path, @intCast(cols), @intCast(rows));
        // AD-14 root cause fix: parser is initialized with a placeholder scr
        // pointer that the caller MUST rebind via bindParser() after this
        // Session is in its final memory location. Previously, this function
        // initialized the parser with `&scr` (the local), which captured the
        // address of the stack-local screen. The returned Session contains a
        // fresh copy of `scr` (Zig copy-by-value), but `parser.scr` still
        // pointed at the dead local. Subsequent stack reuse overwrote the
        // dangling target's `cells.len` with arbitrary values, producing the
        // ReleaseSafe-only `index 0, len 0` panic in putCharWithWidth at
        // various points after the first putChar (timing-sensitive because
        // the dangling target's contents depend on what other locals the
        // optimizer placed in the same slot).
        //
        // The placeholder `&scr` here is harmless because the caller is
        // contractually obligated to rebind before parser.feed* is called.
        // bindParser() exists to make this rebinding visible at call sites
        // rather than implicit. A future refactor could split the type so
        // that a Session-without-parser is a distinct type from a complete
        // Session, but for now the contract is documented and enforced
        // by the call site.
        const p = vt100.Parser.init(&scr);
        return .{
            .scr    = scr,
            .parser = p,
            .shell  = sh,
            .alive  = true,
            .bell   = false,
        };
    }

    /// Rebind the parser's screen pointer to point at this Session's own
    /// scr field. MUST be called after the Session is in its final memory
    /// location (e.g. inside an array or on the heap), and BEFORE any call
    /// to parser.feed* on this session. See Session.init's comment for the
    /// AD-14 root cause this addresses.
    fn bindParser(self: *Session) void {
        self.parser.scr = &self.scr;
    }

    fn deinit(self: *Session) void {
        self.shell.close();
        self.scr.deinit();
    }
};

// ============================================================================
// Mouse state
// ============================================================================

const MouseState = struct {
    left_down: bool = false,
    middle_down: bool = false,
    right_down: bool = false,
    chord_handled: bool = false,
    left_press_col: u32 = 0,
    left_press_row: u32 = 0,
    drag_started: bool = false,

    fn reset(self: *MouseState) void {
        self.left_down = false;
        self.middle_down = false;
        self.right_down = false;
        self.chord_handled = false;
        self.drag_started = false;
    }
};

var mouse_state = MouseState{};

// ============================================================================
// Chord menu
// ============================================================================

pub const ChordMenu = struct {
    visible: bool = false,
    menu_type: MenuType = .edit,
    x: i32 = 0,
    y: i32 = 0,
    selected: ?usize = null,

    pub const MenuType = enum { edit, paste };

    pub const EDIT_LABELS:  [2][]const u8 = .{ " Copy         ", " Clear        " };
    pub const PASTE_LABELS: [2][]const u8 = .{ " Paste        ", " Paste Primary" };

    pub fn show(self: *ChordMenu, px: i32, py: i32, mtype: MenuType) void {
        self.visible = true;
        self.menu_type = mtype;
        self.x = px;
        self.y = py;
        self.selected = null;
    }

    pub fn hide(self: *ChordMenu) void {
        self.visible = false;
        self.selected = null;
    }

    pub fn getLabels(self: *const ChordMenu) []const []const u8 {
        return switch (self.menu_type) {
            .edit  => &EDIT_LABELS,
            .paste => &PASTE_LABELS,
        };
    }

    pub fn updateSelectionScaled(self: *ChordMenu, px: i32, py: i32, cell_w: u32, cell_h: u32, scale: u32) void {
        if (!self.visible) return;
        const item_h_u = cell_h + 4 * scale;
        const item_w_u = cell_w * 14;
        const menu_w: i32 = @intCast(item_w_u + 4 * scale);
        const menu_h: i32 = @intCast(item_h_u * 2 + 4 * scale);
        const item_h: i32 = @intCast(item_h_u);
        const border: i32 = @intCast(2 * scale);
        if (px < self.x or px >= self.x + menu_w or
            py < self.y or py >= self.y + menu_h)
        {
            self.selected = null;
            return;
        }
        const rel_y = py - self.y - border;
        if (rel_y >= 0 and rel_y < item_h) {
            self.selected = 0;
        } else if (rel_y >= item_h and rel_y < item_h * 2) {
            self.selected = 1;
        } else {
            self.selected = null;
        }
    }

    pub fn updateSelection(self: *ChordMenu, px: i32, py: i32) void {
        self.updateSelectionScaled(px, py, font.Font.GLYPH_WIDTH, font.Font.GLYPH_HEIGHT, 1);
    }
};

var chord_menu = ChordMenu{};

// ============================================================================
// Config
// ============================================================================

const Config = struct {
    cols: u32 = 80,
    rows: u32 = 24,
    scale: u32 = 1,
    /// AD-26: when true, the terminal surface is sized to the full
    /// active framebuffer instead of the configured cols/rows.
    /// Cols/rows are computed from the framebuffer dimensions and
    /// the cell size at the configured scale; any explicit -c/-r
    /// values are ignored. The status bar still sits in the bottom
    /// row, so the renderable cell grid is one row shorter than
    /// (fb_height / cell_h). At scale values that don't divide the
    /// framebuffer exactly there can be a few pixels of unused
    /// margin at the right/bottom edge; this is the natural
    /// consequence of cell-aligned sizing and considered acceptable.
    fullscreen: bool = false,
    shell: ?[]const u8 = null,
    socket_path: ?[]const u8 = null,
};

// ============================================================================
// Key/modifier constants
// ============================================================================

const Modifiers = struct {
    const SHIFT: u8 = 0x01;
    const ALT:   u8 = 0x02;
    const CTRL:  u8 = 0x04;
};

const Ascii = struct {
    const TAB: u8 = 0x09;
    const CR:  u8 = 0x0D;
    const ESC: u8 = 0x1B;
    const DEL: u8 = 0x7F;
};

const Key = struct {
    const ESC:        u32 = 1;
    const @"1":       u32 = 2;
    const @"2":       u32 = 3;
    const @"3":       u32 = 4;
    const @"4":       u32 = 5;
    const @"5":       u32 = 6;
    const @"6":       u32 = 7;
    const @"7":       u32 = 8;
    const @"8":       u32 = 9;
    const @"9":       u32 = 10;
    const @"0":       u32 = 11;
    const MINUS:      u32 = 12;
    const EQUAL:      u32 = 13;
    const BACKSPACE:  u32 = 14;
    const TAB:        u32 = 15;
    const Q:          u32 = 16;
    const W:          u32 = 17;
    const E:          u32 = 18;
    const R:          u32 = 19;
    const T:          u32 = 20;
    const Y:          u32 = 21;
    const U:          u32 = 22;
    const I:          u32 = 23;
    const O:          u32 = 24;
    const P:          u32 = 25;
    const LEFTBRACE:  u32 = 26;
    const RIGHTBRACE: u32 = 27;
    const ENTER:      u32 = 28;
    const A:          u32 = 30;
    const S:          u32 = 31;
    const D:          u32 = 32;
    const F:          u32 = 33;
    const G:          u32 = 34;
    const H:          u32 = 35;
    const J:          u32 = 36;
    const K:          u32 = 37;
    const L:          u32 = 38;
    const SEMICOLON:  u32 = 39;
    const APOSTROPHE: u32 = 40;
    const GRAVE:      u32 = 41;
    const BACKSLASH:  u32 = 43;
    const Z:          u32 = 44;
    const X:          u32 = 45;
    const C:          u32 = 46;
    const V:          u32 = 47;
    const B:          u32 = 48;
    const N:          u32 = 49;
    const M:          u32 = 50;
    const COMMA:      u32 = 51;
    const DOT:        u32 = 52;
    const SLASH:      u32 = 53;
    const SPACE:      u32 = 57;
    const F1:         u32 = 59;
    const F2:         u32 = 60;
    const F3:         u32 = 61;
    const F4:         u32 = 62;
    const F5:         u32 = 63;
    const F6:         u32 = 64;
    const F7:         u32 = 65;
    const F8:         u32 = 66;
    const F9:         u32 = 67;
    const F10:        u32 = 68;
    const F11:        u32 = 87;
    const F12:        u32 = 88;
    const HOME:       u32 = 102;
    const UP:         u32 = 103;
    const PAGE_UP:    u32 = 104;
    const LEFT:       u32 = 105;
    const RIGHT:      u32 = 106;
    const END:        u32 = 107;
    const DOWN:       u32 = 108;
    const PAGE_DOWN:  u32 = 109;
    const INSERT:     u32 = 110;
    const DELETE:     u32 = 111;
};

// ============================================================================
// TermState: shared state for the run loop
// ============================================================================

const TermState = struct {
    allocator:     std.mem.Allocator,
    config:        Config,
    sessions:      [MAX_SESSIONS]?Session,
    active:        usize,
    session_count: usize,

    fn activeSession(self: *TermState) *Session {
        return &(self.sessions[self.active].?);
    }

    fn switchTo(self: *TermState, i: usize) void {
        if (i >= MAX_SESSIONS or self.sessions[i] == null or i == self.active) return;
        self.active = i;
        self.sessions[i].?.bell = false;
        self.sessions[i].?.scr.dirty = true;
        log.info("switched to session {}", .{i + 1});
    }

    fn newSession(self: *TermState) !?usize {
        for (0..MAX_SESSIONS) |i| {
            if (self.sessions[i] == null) {
                self.sessions[i] = try Session.init(
                    self.allocator, self.config.shell,
                    self.config.cols, self.config.rows);
                // AD-14 fix: rebind parser to point at the Session's actual
                // scr field, now that the Session is in its final array
                // location. See Session.init for the rationale.
                self.sessions[i].?.bindParser();
                self.session_count += 1;
                log.info("created session {}", .{i + 1});
                return i;
            }
        }
        log.warn("all {} session slots are in use", .{MAX_SESSIONS});
        return null;
    }

    fn closeActive(self: *TermState) void {
        if (self.session_count <= 1) {
            self.sessions[self.active].?.alive = false;
            return;
        }
        self.sessions[self.active].?.deinit();
        self.sessions[self.active] = null;
        self.session_count -= 1;
        log.info("closed session {}", .{self.active + 1});
        // Find nearest live session (search backwards)
        var next = self.active;
        var checked: usize = 0;
        while (checked < MAX_SESSIONS) : (checked += 1) {
            if (next == 0) next = MAX_SESSIONS - 1 else next -= 1;
            if (self.sessions[next] != null) {
                self.active = next;
                self.sessions[next].?.scr.dirty = true;
                break;
            }
        }
    }
};

// ============================================================================
// main
// ============================================================================

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args_owned = try compat.args.alloc(allocator, init.args);
    defer args_owned.deinit(allocator);
    const args = args_owned.argv;

    var config = Config{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cols") or std.mem.startsWith(u8, arg, "--cols=")) {
            const s = if (std.mem.startsWith(u8, arg, "--cols=")) arg["--cols=".len..] else blk: {
                i += 1; if (i >= args.len) return error.InvalidArgument; break :blk args[i];
            };
            config.cols = std.fmt.parseInt(u32, s, 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--rows") or std.mem.startsWith(u8, arg, "--rows=")) {
            const s = if (std.mem.startsWith(u8, arg, "--rows=")) arg["--rows=".len..] else blk: {
                i += 1; if (i >= args.len) return error.InvalidArgument; break :blk args[i];
            };
            config.rows = std.fmt.parseInt(u32, s, 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--shell") or std.mem.startsWith(u8, arg, "--shell=")) {
            config.shell = if (std.mem.startsWith(u8, arg, "--shell=")) arg["--shell=".len..] else blk: {
                i += 1; if (i >= args.len) return error.InvalidArgument; break :blk args[i];
            };
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--socket") or std.mem.startsWith(u8, arg, "--socket=")) {
            config.socket_path = if (std.mem.startsWith(u8, arg, "--socket=")) arg["--socket=".len..] else blk: {
                i += 1; if (i >= args.len) return error.InvalidArgument; break :blk args[i];
            };
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--scale") or std.mem.startsWith(u8, arg, "--scale=")) {
            const s = if (std.mem.startsWith(u8, arg, "--scale=")) arg["--scale=".len..] else blk: {
                i += 1; if (i >= args.len) return error.InvalidArgument; break :blk args[i];
            };
            config.scale = std.fmt.parseInt(u32, s, 10) catch return error.InvalidArgument;
            if (config.scale < 1 or config.scale > 4) return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--fullscreen")) {
            // AD-26: fullscreen takes no value; the surface is sized
            // from the active framebuffer's dimensions and the cell
            // size at the configured scale. Any explicit -c/-r is
            // ignored when this flag is set; the override is logged
            // at run time.
            config.fullscreen = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            const f = compat.fs.stdout();
            f.writeAll(
                \\semadraw-term - Terminal emulator for SemaDraw
                \\
                \\Usage: semadraw-term [OPTIONS]
                \\
                \\Options:
                \\  -c, --cols N      Terminal columns (default: 80)
                \\  -r, --rows N      Terminal rows (default: 24)
                \\  -z, --scale N     Font scale multiplier 1-4 (default: 1)
                \\  -f, --fullscreen  Size surface to fill the framebuffer
                \\                    (overrides -c/-r; combine with -z to
                \\                    pick how many cells fit)
                \\  -e, --shell PATH  Shell to execute (default: $SHELL or /bin/sh)
                \\  -s, --socket PATH Socket path (default: /var/run/semadraw.sock)
                \\  -h, --help        Show this help
                \\
                \\Sessions:
                \\  Alt+F1..F8  Switch to session 1..8
                \\  Alt+N       New session
                \\  Alt+W       Close active session
                \\
                \\Clipboard:
                \\  Ctrl+Shift+C  Copy selection
                \\  Ctrl+Shift+V  Paste from clipboard
                \\  Shift+PgUp/Dn Scroll scrollback
                \\
            ) catch {};
            return;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    try run(allocator, config);
}

// ============================================================================
// run
// ============================================================================

// ============================================================================
// Display size auto-detection via the daemon's output_info IPC.
//
// AD-26 (2026-05-10) originally implemented this by opening /dev/draw
// and calling DRAWFSGIOC_GET_EFIFB_INFO directly. Per ADR 0006 §5
// /dev/draw is restricted to the _semadraw user; non-root clients
// (including this terminal, normally run as the operator) cannot
// open it. The correct path is to ask the daemon, which holds the
// information from its own backend init and exposes it via the
// output_info_request / output_info_reply protocol pair.
// ============================================================================

const DisplaySize = struct {
    fb_width:  u32,
    fb_height: u32,
    cols:      u32,
    rows:      u32,
};

/// Query the daemon for the primary output's pixel dimensions, then
/// compute terminal cols/rows from cell size. Returns null if the
/// daemon refuses the query (e.g. no output initialised yet) or if
/// the computed cell counts would be zero.
///
/// The connection must already be established.
fn queryDisplaySizeViaIpc(conn: *client.Connection, cell_w: u32, cell_h: u32) ?DisplaySize {
    const info = conn.queryOutputInfo(0) catch return null;
    if (info.width == 0 or info.height == 0) return null;

    const cols = info.width / cell_w;
    // Subtract one row for the status bar
    const rows = (info.height / cell_h) -| 1;
    if (cols == 0 or rows == 0) return null;

    return .{
        .fb_width  = info.width,
        .fb_height = info.height,
        .cols      = cols,
        .rows      = rows,
    };
}

fn run(allocator: std.mem.Allocator, config: Config) !void {
    log.info("starting semadraw-term {}x{} scale={} fullscreen={}", .{
        config.cols, config.rows, config.scale, config.fullscreen,
    });

    const cell_w = font.Font.GLYPH_WIDTH  * config.scale;
    const cell_h = font.Font.GLYPH_HEIGHT * config.scale;

    // AD-26.2: connect to the daemon before size determination. The
    // daemon is the authoritative source for output dimensions (see
    // queryDisplaySizeViaIpc above and ADR 0006 §5); we cannot query
    // /dev/draw directly from a non-_semadraw user. The connection
    // also has to happen before surface creation, which has not
    // changed; the only ordering change is that the size query now
    // depends on the connection too.
    var conn = if (config.socket_path) |p|
        try client.connectTo(allocator, p)
    else
        try client.connect(allocator);
    defer conn.disconnect();

    log.info("connected to semadrawd", .{});

    // AD-26: in fullscreen mode, query the framebuffer and size the
    // terminal to fill it. The auto-detect path that already exists
    // for the no-args case fires here unconditionally; we just don't
    // gate on (cols == 80 and rows == 24).
    //
    // Auto-detect (no fullscreen flag) keeps its original behaviour:
    // it only fires when cols/rows are at their defaults, so a user
    // who passes explicit -c/-r without -f gets the size they asked
    // for. With -f, explicit cols/rows are ignored; we log the
    // override so the operator can see it happen.
    var actual_cols = config.cols;
    var actual_rows = config.rows;
    if (config.fullscreen) {
        if (queryDisplaySizeViaIpc(conn, cell_w, cell_h)) |size| {
            // Note when explicit dimensions are being overridden so
            // the operator understands why -c/-r had no effect.
            if (actual_cols != 80 or actual_rows != 24) {
                log.info("--fullscreen overrides explicit cols/rows ({}x{} -> {}x{})", .{
                    actual_cols, actual_rows, size.cols, size.rows,
                });
            }
            actual_cols = size.cols;
            actual_rows = size.rows;
            log.info("fullscreen: framebuffer {}x{} -> {}x{} cells at scale {}", .{
                size.fb_width, size.fb_height, actual_cols, actual_rows, config.scale,
            });
        } else {
            // Fallback when the daemon refuses or has no output yet:
            // behave as if --fullscreen was not passed. Not fatal;
            // the user gets a windowed term at the configured
            // cols/rows. Logged so failed queries are visible in
            // journals.
            log.warn("--fullscreen: output query failed; continuing at {}x{}", .{
                actual_cols, actual_rows,
            });
        }
    } else if (actual_cols == 80 and actual_rows == 24) {
        // Pre-AD-26 auto-detect path, unchanged in spirit; routed
        // through the daemon's IPC since AD-26.2. Fires only when
        // cols/rows are at defaults so explicit -c/-r still wins.
        if (queryDisplaySizeViaIpc(conn, cell_w, cell_h)) |size| {
            actual_cols = size.cols;
            actual_rows = size.rows;
            log.info("auto-detected display: {}x{} -> {}x{} cells", .{
                size.fb_width, size.fb_height, actual_cols, actual_rows,
            });
        }
    }

    const width_px  = actual_cols * cell_w;
    // Extra row at bottom for the session status bar
    const height_px = actual_rows * cell_h + cell_h;

    var surface = try client.Surface.create(conn, @floatFromInt(width_px), @floatFromInt(height_px));
    defer surface.destroy();
    try surface.show();
    log.info("surface created {}x{}", .{ width_px, height_px });

    // Build initial session
    var initial = try Session.init(allocator, config.shell, actual_cols, actual_rows);

    // Renderer is sized to terminal rows only (status bar is drawn as an overlay)
    var rend = renderer.Renderer.initWithScale(allocator, &initial.scr, config.scale);
    defer rend.deinit();

    var state_config = config;
    state_config.cols = actual_cols;
    state_config.rows = actual_rows;

    var state = TermState{
        .allocator     = allocator,
        .config        = state_config,
        .sessions      = [_]?Session{null} ** MAX_SESSIONS,
        .active        = 0,
        .session_count = 1,
    };
    state.sessions[0] = initial;
    // Point renderer at the initial session's screen
    rend.scr = &state.sessions[0].?.scr;
    // AD-14 fix: rebind parser to point at the Session's actual scr field,
    // now that the Session is in its final array location. See Session.init
    // for the rationale. The renderer rebinding above (rend.scr) was already
    // present pre-AD-14; the parser rebinding was missing, producing the
    // ReleaseSafe-only `index 0, len 0` panic class diagnosed via lldb on
    // 2026-05-05 (AD-14.1 second-attempt repro).
    state.sessions[0].?.bindParser();

    log.info("session 1 started", .{});
    try renderFrame(allocator, &state, &rend, surface, conn, true);

    const blink_ms: i64 = 500;
    var last_blink  = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms)));
    var last_pty_ms = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms)));
    var last_switch_ms: i64 = 0; // debounce session switch keys
    var blink_vis   = true;
    var running     = true;

    // AD-40 reconnect layer state (the semasound device-layer
    // pattern, AD-47 precedent): the terminal survives compositor
    // restarts. While disconnected, the PTYs keep pumping and the
    // screen model keeps updating; only the connection and surface
    // are replaced on reconnect.
    var connected = true;
    var last_reconnect_ms: i64 = 0;

    while (running) {
        const sess = state.activeSession();

        // Build pollfd array: conn first (when connected), then all
        // live PTY fds (AD-40: the conn fd leaves the set during an
        // outage; PTY draining below is connection-independent).
        var pfds: [MAX_SESSIONS + 1]posix.pollfd = undefined;
        var nfds: usize = 0;
        if (connected) {
            pfds[nfds] = .{ .fd = conn.getFd(), .events = posix.POLL.IN, .revents = 0 };
            nfds += 1;
        }
        for (0..MAX_SESSIONS) |si| {
            if (state.sessions[si]) |*s| {
                pfds[nfds] = .{ .fd = s.shell.getFd(), .events = posix.POLL.IN, .revents = 0 };
                nfds += 1;
            }
        }
        _ = posix.poll(pfds[0..nfds], 16) catch continue;

        // Cursor blink: only trigger if PTY has been quiet for at least one blink interval
        const now = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms)));
        if (sess.scr.shouldCursorBlink() and now - last_blink >= blink_ms and now - last_pty_ms >= blink_ms) {
            blink_vis   = !blink_vis;
            last_blink  = now;
            sess.scr.dirty = true;
        }
        if (!sess.scr.shouldCursorBlink()) blink_vis = true;

        // Drain all PTY fds
        var needs_render = false;
        var pfi: usize = if (connected) 1 else 0;
        for (0..MAX_SESSIONS) |si| {
            if (state.sessions[si]) |*s| {
                defer pfi += 1;
                if (pfi >= nfds) break;
                const pfd = pfds[pfi];

                if (pfd.revents & posix.POLL.IN != 0) {
                    // Drain all available PTY data before rendering to avoid
                    // rendering mid-sequence (e.g. cursor at col 0 before prompt)
                    while (true) {
                        const data = s.shell.read() catch break;
                        if (data == null) break;
                        s.parser.feedSlice(data.?);
                        if (si == state.active) {
                            needs_render = true;
                            last_pty_ms = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms)));
                        } else s.bell = true;
                        // Check if more data is available
                        var check = [1]posix.pollfd{.{ .fd = s.shell.getFd(), .events = posix.POLL.IN, .revents = 0 }};
                        const r = posix.poll(&check, 0) catch break;
                        if (r == 0) break;
                    }
                }

                if (pfd.revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                    var wr_status: c_int = undefined;
                    const wr_pid = posix.system.waitpid(s.shell.child_pid, &wr_status, @intCast(posix.W.NOHANG));
                    if (wr_pid != 0) s.shell.child_pid = 0;
                    s.alive = false;
                    if (si == state.active) {
                        if (state.session_count <= 1) {
                            running = false;
                        } else {
                            state.closeActive();
                            rend.scr = &state.activeSession().scr;
                            needs_render = true;
                        }
                    } else {
                        s.deinit();
                        state.sessions[si] = null;
                        state.session_count -= 1;
                    }
                }
            }
        }

        // AD-40 reconnect attempt, 1 Hz. Replays connect, surface
        // create at the ORIGINAL dimensions (no size re-query: a
        // mid-session resize would disturb the grid), and show, then
        // forces a full repaint from client-side screen state. The
        // old connection and surface objects are abandoned, never
        // destroyed: their teardown would touch the dead socket (the
        // semasound never-close-dead-fds policy).
        if (!connected) {
            const rc_now = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms)));
            if (rc_now - last_reconnect_ms >= 1000) {
                last_reconnect_ms = rc_now;
                reconnect: {
                    const new_conn = blk: {
                        if (config.socket_path) |p| break :blk client.connectTo(allocator, p) catch break :reconnect;
                        break :blk client.connect(allocator) catch break :reconnect;
                    };
                    const new_surface = client.Surface.create(new_conn, @floatFromInt(width_px), @floatFromInt(height_px)) catch break :reconnect;
                    new_surface.show() catch break :reconnect;
                    conn = new_conn;
                    surface = new_surface;
                    connected = true;
                    sess.scr.dirty = true;
                    needs_render = true;
                    log.info("reconnected to semadrawd; surface recreated, repainting", .{});
                }
            }
        }

        // Drain daemon events
        if (connected and pfds[0].revents & posix.POLL.IN != 0) {
            while (true) {
                const ev = conn.poll() catch break;
                if (ev == null) break;
                switch (ev.?) {
                    .disconnected => {
                        // AD-40: the compositor restarted; the shell
                        // and screen state are ours and survive. Drop
                        // to reconnecting; the PTYs keep pumping.
                        log.warn("semadrawd disconnected; terminal state held, reconnecting", .{});
                        connected = false;
                        last_reconnect_ms = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms)));
                    },
                    .error_reply  => |e| log.err("daemon error: {}", .{e.code}),
                    .key_press    => |k| {
                        if (k.pressed == 1) {
                            const now_sw = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms)));
                            const is_switch = handleSessionSwitch(&state, k.key_code, k.modifiers);
                            if (is_switch) {
                                // Debounce: ignore session switch repeats within 300ms
                                if (now_sw - last_switch_ms >= 300) {
                                    last_switch_ms = now_sw;
                                    rend.scr = &state.activeSession().scr;
                                    needs_render = true;
                                }
                            } else {
                                handleKeyPress(
                                    &state.activeSession().shell,
                                    &state.activeSession().scr,
                                    conn, k.key_code, k.modifiers);
                            }
                        }
                    },
                    .mouse_event => |m| {
                        handleMouseEvent(
                            &state.activeSession().shell,
                            &state.activeSession().scr,
                            conn, m, &rend);
                        if (chord_menu.visible and state.activeSession().scr.dirty) {
                            if (renderFrame(allocator, &state, &rend, surface, conn, blink_vis)) {
                                state.activeSession().scr.dirty = false;
                            } else |_| {
                                // AD-40: commit failed mid-stream;
                                // same transition as .disconnected.
                                log.warn("commit failed; semadrawd gone, terminal state held, reconnecting", .{});
                                connected = false;
                                last_reconnect_ms = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms)));
                            }
                        }
                    },
                    .clipboard_data => |clip| {
                        state.activeSession().shell.write(clip.data) catch |e| {
                            log.warn("paste failed: {}", .{e});
                        };
                    },
                    else => {},
                }
            }
        }

        if (connected and (state.activeSession().scr.dirty or needs_render)) {
            if (renderFrame(allocator, &state, &rend, surface, conn, blink_vis)) {
                state.activeSession().scr.dirty = false;
            } else |_| {
                // AD-40: commit failed mid-stream; same transition as
                // the .disconnected event. scr.dirty stays set so the
                // reconnect repaint has everything.
                log.warn("commit failed; semadrawd gone, terminal state held, reconnecting", .{});
                connected = false;
                last_reconnect_ms = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms)));
            }
        }
    }

    for (0..MAX_SESSIONS) |si| {
        if (state.sessions[si]) |*s| s.deinit();
    }
    log.info("semadraw-term exiting", .{});
}

// ============================================================================
// Session switching
// ============================================================================

fn handleSessionSwitch(state: *TermState, key_code: u32, modifiers: u8) bool {
    if ((modifiers & Modifiers.ALT) == 0) return false;

    const target: ?usize = switch (key_code) {
        Key.F1 => 0, Key.F2 => 1, Key.F3 => 2, Key.F4 => 3,
        Key.F5 => 4, Key.F6 => 5, Key.F7 => 6, Key.F8 => 7,
        else   => null,
    };
    if (target) |t| {
        if (state.sessions[t] != null) state.switchTo(t);
        return true;
    }
    if (key_code == Key.N) {
        const idx = state.newSession() catch |e| {
            log.err("failed to create session: {}", .{e}); return true;
        };
        if (idx) |ni| state.switchTo(ni);
        return true;
    }
    if (key_code == Key.W) {
        state.closeActive();
        return true;
    }
    return false;
}

// ============================================================================
// Render
// ============================================================================

fn renderFrame(
    allocator: std.mem.Allocator,
    state: *TermState,
    rend: *renderer.Renderer,
    surface: *client.Surface,
    conn: *client.Connection,
    blink_vis: bool,
) !void {
    _ = conn;
    const sess = state.activeSession();

    const orig = sess.scr.cursor_visible;
    if (!blink_vis) sess.scr.cursor_visible = false;
    defer sess.scr.cursor_visible = orig;

    const menu_ov: ?renderer.Renderer.MenuOverlay = if (chord_menu.visible) blk: {
        const ih = rend.getCellHeight() + 4 * rend.scale;
        const iw = rend.getCellWidth() * 14;
        break :blk .{
            .x          = chord_menu.x,
            .y          = chord_menu.y,
            .width      = iw + 4 * rend.scale,
            .height     = ih * 2 + 4 * rend.scale,
            .item_height = ih,
            .labels     = chord_menu.getLabels(),
            .selected_idx = chord_menu.selected,
        };
    } else null;

    // Build status bar labels
    var status_labels: [MAX_SESSIONS]?[]const u8 = [_]?[]const u8{null} ** MAX_SESSIONS;
    var label_bufs: [MAX_SESSIONS][4]u8 = undefined;
    for (0..MAX_SESSIONS) |si| {
        if (state.sessions[si] != null) {
            label_bufs[si][0] = ' ';
            label_bufs[si][1] = '1' + @as(u8, @intCast(si));
            // Show * if background session has unread output
            label_bufs[si][2] = if (state.sessions[si].?.bell) '*' else ' ';
            label_bufs[si][3] = ' ';
            status_labels[si] = label_bufs[si][0..4];
        }
    }

    const sdcs = try rend.renderWithOverlayAndStatusBar(menu_ov, &status_labels, state.active);
    defer allocator.free(sdcs);
    try surface.attachAndCommit(sdcs);
}

// ============================================================================
// Key handling
// ============================================================================

fn handleKeyPress(shell: *pty.Pty, scr: *screen.Screen, conn: *client.Connection, key_code: u32, modifiers: u8) void {
    const ctrl  = (modifiers & Modifiers.CTRL)  != 0;
    const shift = (modifiers & Modifiers.SHIFT) != 0;

    if (ctrl and shift) {
        switch (key_code) {
            Key.C => {
                if (scr.selection.active) {
                    if (scr.getSelectedText(scr.allocator) catch null) |text| {
                        conn.setClipboard(.clipboard, text) catch |e| log.warn("copy failed: {}", .{e});
                        scr.allocator.free(text);
                    }
                }
                return;
            },
            Key.V => {
                conn.requestClipboard(.clipboard) catch |e| log.warn("paste req failed: {}", .{e});
                return;
            },
            else => {},
        }
    }

    if (shift) {
        switch (key_code) {
            Key.PAGE_UP   => { _ = scr.scrollViewUp(scr.rows / 2);   return; },
            Key.PAGE_DOWN => { _ = scr.scrollViewDown(scr.rows / 2); return; },
            else => {},
        }
    }

    if (scr.isViewingScrollback()) scr.resetScrollView();

    var buf: [16]u8 = undefined;
    var len: usize  = 0;

    const gc = struct {
        fn f(lower: u8, s: bool, c: bool) u8 {
            if (c) return lower - 'a' + 1;
            if (s) return lower - 32;
            return lower;
        }
    }.f;

    switch (key_code) {
        Key.Q => { buf[0] = gc('q', shift, ctrl); len = 1; },
        Key.W => { buf[0] = gc('w', shift, ctrl); len = 1; },
        Key.E => { buf[0] = gc('e', shift, ctrl); len = 1; },
        Key.R => { buf[0] = gc('r', shift, ctrl); len = 1; },
        Key.T => { buf[0] = gc('t', shift, ctrl); len = 1; },
        Key.Y => { buf[0] = gc('y', shift, ctrl); len = 1; },
        Key.U => { buf[0] = gc('u', shift, ctrl); len = 1; },
        Key.I => { buf[0] = gc('i', shift, ctrl); len = 1; },
        Key.O => { buf[0] = gc('o', shift, ctrl); len = 1; },
        Key.P => { buf[0] = gc('p', shift, ctrl); len = 1; },
        Key.A => { buf[0] = gc('a', shift, ctrl); len = 1; },
        Key.S => { buf[0] = gc('s', shift, ctrl); len = 1; },
        Key.D => { buf[0] = gc('d', shift, ctrl); len = 1; },
        Key.F => { buf[0] = gc('f', shift, ctrl); len = 1; },
        Key.G => { buf[0] = gc('g', shift, ctrl); len = 1; },
        Key.H => { buf[0] = gc('h', shift, ctrl); len = 1; },
        Key.J => { buf[0] = gc('j', shift, ctrl); len = 1; },
        Key.K => { buf[0] = gc('k', shift, ctrl); len = 1; },
        Key.L => { buf[0] = gc('l', shift, ctrl); len = 1; },
        Key.Z => { buf[0] = gc('z', shift, ctrl); len = 1; },
        Key.X => { buf[0] = gc('x', shift, ctrl); len = 1; },
        Key.C => { buf[0] = gc('c', shift, ctrl); len = 1; },
        Key.V => { buf[0] = gc('v', shift, ctrl); len = 1; },
        Key.B => { buf[0] = gc('b', shift, ctrl); len = 1; },
        Key.N => { buf[0] = gc('n', shift, ctrl); len = 1; },
        Key.M => { buf[0] = gc('m', shift, ctrl); len = 1; },
        Key.@"1" => { buf[0] = if (shift) '!' else '1'; len = 1; },
        Key.@"2" => { buf[0] = if (shift) '@' else '2'; len = 1; },
        Key.@"3" => { buf[0] = if (shift) '#' else '3'; len = 1; },
        Key.@"4" => { buf[0] = if (shift) '$' else '4'; len = 1; },
        Key.@"5" => { buf[0] = if (shift) '%' else '5'; len = 1; },
        Key.@"6" => { buf[0] = if (shift) '^' else '6'; len = 1; },
        Key.@"7" => { buf[0] = if (shift) '&' else '7'; len = 1; },
        Key.@"8" => { buf[0] = if (shift) '*' else '8'; len = 1; },
        Key.@"9" => { buf[0] = if (shift) '(' else '9'; len = 1; },
        Key.@"0" => { buf[0] = if (shift) ')' else '0'; len = 1; },
        Key.MINUS      => { buf[0] = if (shift) '_' else '-';  len = 1; },
        Key.EQUAL      => { buf[0] = if (shift) '+' else '=';  len = 1; },
        Key.LEFTBRACE  => { buf[0] = if (shift) '{' else '[';  len = 1; },
        Key.RIGHTBRACE => { buf[0] = if (shift) '}' else ']';  len = 1; },
        Key.SEMICOLON  => { buf[0] = if (shift) ':' else ';';  len = 1; },
        Key.APOSTROPHE => { buf[0] = if (shift) '"' else '\''; len = 1; },
        Key.GRAVE      => { buf[0] = if (shift) '~' else '`';  len = 1; },
        Key.BACKSLASH  => { buf[0] = if (shift) '|' else '\\'; len = 1; },
        Key.COMMA      => { buf[0] = if (shift) '<' else ',';  len = 1; },
        Key.DOT        => { buf[0] = if (shift) '>' else '.';  len = 1; },
        Key.SLASH      => { buf[0] = if (shift) '?' else '/';  len = 1; },
        Key.ESC        => { buf[0] = Ascii.ESC; len = 1; },
        Key.BACKSPACE  => { buf[0] = Ascii.DEL; len = 1; },
        Key.TAB        => { buf[0] = Ascii.TAB; len = 1; },
        Key.ENTER      => { buf[0] = Ascii.CR;  len = 1; },
        Key.SPACE      => { buf[0] = ' ';        len = 1; },
        Key.UP         => { @memcpy(buf[0..3], "\x1b[A");  len = 3; },
        Key.DOWN       => { @memcpy(buf[0..3], "\x1b[B");  len = 3; },
        Key.RIGHT      => { @memcpy(buf[0..3], "\x1b[C");  len = 3; },
        Key.LEFT       => { @memcpy(buf[0..3], "\x1b[D");  len = 3; },
        Key.HOME       => { @memcpy(buf[0..3], "\x1b[H");  len = 3; },
        Key.END        => { @memcpy(buf[0..3], "\x1b[F");  len = 3; },
        Key.PAGE_UP    => { @memcpy(buf[0..4], "\x1b[5~"); len = 4; },
        Key.PAGE_DOWN  => { @memcpy(buf[0..4], "\x1b[6~"); len = 4; },
        Key.INSERT     => { @memcpy(buf[0..4], "\x1b[2~"); len = 4; },
        Key.DELETE     => { @memcpy(buf[0..4], "\x1b[3~"); len = 4; },
        Key.F1  => { @memcpy(buf[0..3], "\x1bOP");   len = 3; },
        Key.F2  => { @memcpy(buf[0..3], "\x1bOQ");   len = 3; },
        Key.F3  => { @memcpy(buf[0..3], "\x1bOR");   len = 3; },
        Key.F4  => { @memcpy(buf[0..3], "\x1bOS");   len = 3; },
        Key.F5  => { @memcpy(buf[0..5], "\x1b[15~"); len = 5; },
        Key.F6  => { @memcpy(buf[0..5], "\x1b[17~"); len = 5; },
        Key.F7  => { @memcpy(buf[0..5], "\x1b[18~"); len = 5; },
        Key.F8  => { @memcpy(buf[0..5], "\x1b[19~"); len = 5; },
        Key.F9  => { @memcpy(buf[0..5], "\x1b[20~"); len = 5; },
        Key.F10 => { @memcpy(buf[0..5], "\x1b[21~"); len = 5; },
        Key.F11 => { @memcpy(buf[0..5], "\x1b[23~"); len = 5; },
        Key.F12 => { @memcpy(buf[0..5], "\x1b[24~"); len = 5; },
        else => log.debug("unhandled key: {}", .{key_code}),
    }

    if (len > 0) shell.write(buf[0..len]) catch |e| log.warn("shell write failed: {}", .{e});
}

// ============================================================================
// Mouse handling
// ============================================================================

fn handleMouseEvent(
    shell: *pty.Pty,
    scr:   *screen.Screen,
    conn:  *client.Connection,
    mouse: client.protocol.MouseEventMsg,
    rend:  *renderer.Renderer,
) void {
    const event_type = mouse.event_type;
    const cell_x = @divFloor(mouse.x, @as(i32, @intCast(rend.getCellWidth())));
    const cell_y = @divFloor(mouse.y, @as(i32, @intCast(rend.getCellHeight())));
    const col: u32 = @intCast(@max(0, @min(cell_x, @as(i32, @intCast(scr.cols)) - 1)));
    const row: u32 = @intCast(@max(0, @min(cell_y, @as(i32, @intCast(scr.rows)) - 1)));

    const tracking = scr.getMouseTracking();

    if (tracking == .none) {
        if (event_type == .press) {
            switch (mouse.button) {
                .left   => mouse_state.left_down   = true,
                .middle => mouse_state.middle_down = true,
                .right  => mouse_state.right_down  = true,
                else    => {},
            }
        } else if (event_type == .release) {
            switch (mouse.button) {
                .left   => mouse_state.left_down   = false,
                .middle => mouse_state.middle_down = false,
                .right  => mouse_state.right_down  = false,
                else    => {},
            }
        }

        const chord = mouse_state.left_down and (mouse_state.middle_down or mouse_state.right_down);
        if (chord and event_type == .press and (mouse.button == .middle or mouse.button == .right)) {
            const mt: ChordMenu.MenuType = if (mouse.button == .middle) .edit else .paste;
            chord_menu.show(mouse.x, mouse.y, mt);
            chord_menu.updateSelectionScaled(mouse.x, mouse.y, rend.getCellWidth(), rend.getCellHeight(), rend.scale);
            mouse_state.chord_handled = true;
            scr.markAllRowsDirty();
            scr.dirty = true;
            return;
        }

        if (chord_menu.visible and event_type == .motion) {
            chord_menu.updateSelectionScaled(mouse.x, mouse.y, rend.getCellWidth(), rend.getCellHeight(), rend.scale);
            scr.dirty = true;
            return;
        }

        if (chord_menu.visible and event_type == .release and (mouse.button == .middle or mouse.button == .right)) return;

        if (chord_menu.visible and event_type == .release and mouse.button == .left) {
            if (chord_menu.selected) |idx| {
                switch (chord_menu.menu_type) {
                    .edit => {
                        if (idx == 0 and scr.selection.active) {
                            if (scr.getSelectedText(scr.allocator) catch null) |text| {
                                conn.setClipboard(.clipboard, text) catch |e| log.warn("copy: {}", .{e});
                                scr.allocator.free(text);
                            }
                        } else if (idx == 1) scr.clearSelection();
                    },
                    .paste => {
                        const sel: client.protocol.ClipboardSelection = if (idx == 0) .clipboard else .primary;
                        conn.requestClipboard(sel) catch |e| log.warn("paste: {}", .{e});
                    },
                }
            }
            chord_menu.hide();
            mouse_state.chord_handled = false;
            scr.dirty = true;
            return;
        }

        if (event_type == .release and mouse.button == .left) mouse_state.chord_handled = false;

        if (mouse.button == .middle and event_type == .press and !mouse_state.left_down and !mouse_state.right_down) {
            conn.requestClipboard(.primary) catch |e| log.warn("primary paste: {}", .{e});
            return;
        }

        if (!mouse_state.left_down and !mouse_state.middle_down and !mouse_state.right_down) {
            mouse_state.chord_handled = false;
            if (chord_menu.visible) { chord_menu.hide(); scr.dirty = true; }
        }

        if (mouse_state.chord_handled or chord_menu.visible) return;

        if (mouse.button == .left or (event_type == .motion and mouse_state.left_down)) {
            if (event_type == .press) {
                mouse_state.left_press_col = col;
                mouse_state.left_press_row = row;
                mouse_state.drag_started   = false;
            } else if (event_type == .motion and mouse_state.left_down) {
                if (!mouse_state.drag_started) {
                    const dx = @as(i32, @intCast(col)) - @as(i32, @intCast(mouse_state.left_press_col));
                    const dy = @as(i32, @intCast(row)) - @as(i32, @intCast(mouse_state.left_press_row));
                    if (dx * dx + dy * dy >= 4) {
                        scr.startSelection(mouse_state.left_press_col, mouse_state.left_press_row);
                        mouse_state.drag_started = true;
                    }
                }
                if (mouse_state.drag_started) scr.updateSelection(col, row);
            } else if (event_type == .release and mouse.button == .left) {
                if (mouse_state.drag_started) {
                    scr.endSelection();
                    if (scr.selection.active) {
                        if (scr.getSelectedText(scr.allocator) catch null) |text| {
                            conn.setClipboard(.primary, text) catch |e| log.warn("primary set: {}", .{e});
                            scr.allocator.free(text);
                        }
                    }
                }
                mouse_state.drag_started = false;
            }
        }
        return;
    }

    const encoding = scr.getMouseEncoding();
    const report = switch (tracking) {
        .none              => false,
        .x10               => event_type == .press,
        .vt200, .vt200_highlight => event_type == .press or event_type == .release,
        .btn_event         => event_type == .press or event_type == .release or
                              (event_type == .motion and isButtonPressed(mouse.button)),
        .any_event         => true,
    };
    if (!report) return;

    const x: u32 = col + 1;
    const y: u32 = row + 1;
    var buf: [32]u8 = undefined;
    var len: usize  = 0;

    switch (encoding) {
        .sgr => {
            const btn = getButtonCode(mouse.button, mouse.modifiers, event_type == .motion);
            len = formatSgrMouse(&buf, btn, x, y, if (event_type == .release) 'm' else 'M');
        },
        .urxvt => {
            const btn = getButtonCode(mouse.button, mouse.modifiers, event_type == .motion) + 32;
            len = formatUrxvtMouse(&buf, btn, x, y);
        },
        .x10, .utf8 => {
            const btn = getButtonCode(mouse.button, mouse.modifiers, event_type == .motion);
            buf[0] = Ascii.ESC; buf[1] = '['; buf[2] = 'M';
            buf[3] = if (event_type == .release) 32 + 3 else 32 + btn;
            buf[4] = @intCast(@min(x + 32, 255));
            buf[5] = @intCast(@min(y + 32, 255));
            len = 6;
        },
    }
    if (len > 0) shell.write(buf[0..len]) catch |e| log.warn("mouse write: {}", .{e});
}

fn isButtonPressed(b: client.protocol.MouseButtonId) bool {
    return switch (b) { .left, .middle, .right => true, else => false };
}

fn getButtonCode(b: client.protocol.MouseButtonId, mods: u8, motion: bool) u8 {
    var c: u8 = switch (b) {
        .left => 0, .middle => 1, .right => 2,
        .scroll_up => 64, .scroll_down => 65,
        .scroll_left => 66, .scroll_right => 67,
        else => 0,
    };
    if (mods & Modifiers.SHIFT != 0) c |= 4;
    if (mods & Modifiers.ALT   != 0) c |= 8;
    if (mods & Modifiers.CTRL  != 0) c |= 16;
    if (motion) c |= 32;
    return c;
}

fn formatSgrMouse(buf: []u8, btn: u8, x: u32, y: u32, term: u8) usize {
    var i: usize = 0;
    buf[i] = Ascii.ESC; i += 1; buf[i] = '['; i += 1; buf[i] = '<'; i += 1;
    i += formatDecimal(buf[i..], btn);   buf[i] = ';'; i += 1;
    i += formatDecimal(buf[i..], @intCast(x)); buf[i] = ';'; i += 1;
    i += formatDecimal(buf[i..], @intCast(y));
    buf[i] = term; i += 1;
    return i;
}

fn formatUrxvtMouse(buf: []u8, btn: u8, x: u32, y: u32) usize {
    var i: usize = 0;
    buf[i] = Ascii.ESC; i += 1; buf[i] = '['; i += 1;
    i += formatDecimal(buf[i..], btn);   buf[i] = ';'; i += 1;
    i += formatDecimal(buf[i..], @intCast(x)); buf[i] = ';'; i += 1;
    i += formatDecimal(buf[i..], @intCast(y));
    buf[i] = 'M'; i += 1;
    return i;
}

fn formatDecimal(buf: []u8, value: u32) usize {
    if (value == 0) { buf[0] = '0'; return 1; }
    var v = value; var len: usize = 0;
    var t = value; while (t > 0) : (t /= 10) len += 1;
    var i = len;
    while (v > 0) : (v /= 10) { i -= 1; buf[i] = @intCast('0' + (v % 10)); }
    return len;
}
