// pgsd-sessiond/src/ui.zig
//
// Graphical login UI. Draws a centered login panel on black with
// bright amber text, captures username and password, optionally
// overrides the session type via a Tab-invoked picker, exposes
// power management via a Ctrl-Q-invoked menu, and orchestrates
// the auth lifecycle in cooperation with main.runUiOnly.
//
// State machine (Stage 8):
//
//   START
//     | connection established, surface shown
//     V
//   IDENTIFY
//     | keystrokes accumulate into username
//     | Enter (non-empty username) -> PASSWORD
//     | ESC clears username, stays in IDENTIFY
//     | Tab is a no-op here
//     | Ctrl-Q -> POWER_MENU (pre = IDENTIFY)
//     V
//   PASSWORD
//     | keystrokes accumulate into password buffer (drawn as bullets)
//     | Enter -> SUBMITTING
//     | Tab -> PICKER (overlay; password buffer preserved)
//     | ESC clears password (stays in PASSWORD)
//     | Ctrl-Q -> POWER_MENU (pre = PASSWORD)
//     V
//   PICKER (overlay on top of PASSWORD)
//     | Up/Down move picker_cursor among ENABLED session types,
//     |   wrapping; disabled types are skipped.
//     | Tab or Enter commits picker_cursor to selected_session
//     |   and returns to PASSWORD.
//     | ESC discards picker_cursor; returns to PASSWORD with
//     |   selected_session unchanged.
//     | Ctrl-Q -> closes picker, opens POWER_MENU (pre = PASSWORD)
//     V
//   POWER_MENU (overlay; reachable from IDENTIFY, PASSWORD, PICKER)
//     | Sub-phase .choosing: Up/Down cycle through {Shutdown,
//     |   Restart, Suspend}. Enter or S/R/Z selects.
//     |   Shutdown/Restart advance to .confirming_*; Suspend arms
//     |   state.power_action directly.
//     |   ESC or Ctrl-Q returns to pre_power_field.
//     | Sub-phase .confirming_shutdown / .confirming_restart:
//     |   Y or Enter arms state.power_action.
//     |   N or ESC returns to .choosing.
//     |   Ctrl-Q closes the entire menu (returns to pre_power_field).
//     | When state.power_action becomes non-null, main.runUiOnly
//     | reads it and invokes the corresponding FreeBSD command.
//     V
//   SUBMITTING
//     | main.runUiOnly sees this state and runs PAM auth.
//     | UI ignores ALL input here (including Ctrl-Q) for the brief
//     |   window auth takes; the user can wait.
//     | On AUTH SUCCESS: main resolves selected_session.sessionId()
//     |   to a .session file, tears down the surface, fork+execs
//     |   the session leader. When the session leader exits, the
//     |   outer session-loop in runUiOnly redisplays the login UI
//     |   from a fresh State (per ADR 0001 §Logout).
//     | On AUTH FAILURE (retryable, retries remaining): main calls
//     |   state.resetForRetry("..."), which clears the password
//     |   buffer, returns the field to PASSWORD, and shows the
//     |   message until the user types.
//     | On AUTH FAILURE (3 attempts exhausted): outer session-loop
//     |   redisplays a fresh login screen with a "too many failed
//     |   attempts" status message. The daemon does NOT exit on
//     |   auth failure (that would be a DoS vector).
//     V
//   POWER ACTION (state.power_action != null)
//     | main.runUiOnly invokes shutdown -p now / shutdown -r now /
//     | acpiconf -s 3. Shutdown and Restart hand control to init,
//     | and pgsd-sessiond is killed by init shortly after. Suspend
//     | blocks until the system wakes, then loops back to a fresh
//     | login screen.
//
// Drawing palette:
//   black:      RGBA(0, 0, 0, 1)
//   amber:      RGBA(1.0, 0.55, 0.0, 1.0)  // "bright amber CRT"
//   dim amber:  RGBA(0.5, 0.27, 0.0, 1.0)  // supplementary info
//
// Surface size and scale: the caller queries the framebuffer
// dimensions via conn.queryOutputInfo and creates the surface at
// native resolution. Every draw() call passes the surface_w and
// surface_h that were used; ui.zig centers its layout on those
// dimensions. Text is rendered at SCALE x glyph size (3x by
// default), the same approach term uses for HiDPI. All layout
// constants in this file are pre-SCALE; multiply by SCALE where
// they appear in draw paths.

const std = @import("std");
const semadraw = @import("semadraw");
const compat = @import("compat");
const font = @import("font.zig");
const keymap = @import("keymap.zig");
const sysinfo = @import("sysinfo.zig");

const Encoder = semadraw.Encoder;
const AppEvent = semadraw.AppEvent;

// =============================================================================
// Configuration
// =============================================================================

/// Bitmap font scale. Glyphs are stretched by this factor at blit
/// time (compositor side, via drawGlyphRun's cell_width and
/// cell_height arguments). 3x makes 8x16 glyphs render as 24x48,
/// which is large enough to read comfortably from typical sit-at-
/// the-keyboard distance even on a 4K display.
pub const SCALE: u32 = 3;

/// Fallback surface size when conn.queryOutputInfo fails. Matches
/// the sparrow laptop display. The caller (main.runUiOnly) uses
/// these only as a last-ditch fallback if the daemon refuses or
/// has no output yet.
pub const FALLBACK_WIDTH: u32 = 1024;
pub const FALLBACK_HEIGHT: u32 = 768;

pub const TARGET_FPS: u32 = 30; // login screen is mostly static
// SM-4: caret blink period, wall-clock based. The blink used to be
// derived from the frame counter (CURSOR_BLINK_FRAMES=15 at 30 fps);
// with redraws gated on actual change, wall time is the phase source
// and the main loop redraws only when the phase flips.
pub const CURSOR_BLINK_MS: i64 = 500;

/// Cadence at which maybeRefreshNetwork() re-runs the getifaddrs
/// walk to pick up interface changes. Set to 1 second: long
/// enough that the syscall cost is negligible (one call/second
/// is far below the threshold where it would matter for a
/// mostly-idle login screen), short enough that the user sees
/// network state updates within a perceptible window once DHCP
/// or a manual `ifconfig up` completes.
///
/// The initial sysinfo.network() call at State.init runs once;
/// this is the inter-call interval for subsequent refreshes.
pub const NETWORK_REFRESH_INTERVAL_MS: i64 = 1000;

// Palette
//
// Two color families are used:
//
//   AMBER / DIM amber: the "interactive" foreground. All UI
//   surfaces the user acts on - field labels, field contents
//   and borders, the picker overlay, the power menu, the
//   selection bar, the hint footer, status messages - render
//   in amber. Bright AMBER is the active foreground; DIM is
//   used for inactive variants of the same elements (e.g. the
//   non-focused field label).
//
//   CYAN / DIM cyan: the "non-interactive context" foreground.
//   The sysinfo block at the top of the screen (hostname,
//   network status, memory) is read-once context that tells
//   the user what machine they are on, not something they
//   interact with. Rendering it in cyan provides a pre-
//   attentive distinction from the amber interactive
//   surfaces: even before the user reads any text, the colour
//   tells them "the cyan stuff is reference; the amber stuff
//   is where you act".
//
//   The cyan-vs-amber distinction is encoded redundantly with
//   spatial position (cyan at the top, amber throughout the
//   middle and bottom), so colour-blind users who cannot
//   distinguish the two hues still get the signal from layout.
//
// WCAG contrast on pure black background:
//   - AMBER  (1.0, 0.55, 0.0): luminance ratio ~12:1
//   - CYAN   (0.0, 0.8, 0.8):  luminance ratio ~7.5:1
//   Both exceed WCAG AA (4.5:1) and AAA (7:1) for normal text.
const AMBER_R: f32 = 1.0;
const AMBER_G: f32 = 0.55;
const AMBER_B: f32 = 0.0;
const AMBER_A: f32 = 1.0;

const DIM_R: f32 = 0.5;
const DIM_G: f32 = 0.27;
const DIM_B: f32 = 0.0;
const DIM_A: f32 = 1.0;

const CYAN_R: f32 = 0.0;
const CYAN_G: f32 = 0.8;
const CYAN_B: f32 = 0.8;
const CYAN_A: f32 = 1.0;

const DIM_CYAN_R: f32 = 0.0;
const DIM_CYAN_G: f32 = 0.4;
const DIM_CYAN_B: f32 = 0.4;
const DIM_CYAN_A: f32 = 1.0;

// Layout, in unscaled (pre-SCALE) pixel units. Multiply by SCALE
// where they appear in draw paths.
const FIELD_WIDTH_CHARS: u32 = 32; // 32 chars * 8 px/char = 256 unscaled px
const FIELD_INNER_PAD_U: f32 = 8.0; // unscaled
const FIELD_BORDER_WIDTH_U: f32 = 1.0; // unscaled (1 px before scale -> SCALE px after)

const USERNAME_MAX: usize = 32; // matches FIELD_WIDTH_CHARS
const PASSWORD_MAX: usize = 256; // generous; PAM truncates anyway

// Cursor blink: visible 15 frames, hidden 15 frames at 30 fps = 1 Hz

// =============================================================================
// State
// =============================================================================

pub const FieldState = enum {
    identify,
    password,
    /// Stage 7: session-picker overlay open. Up/Down move the
    /// cursor among ENABLED picker entries (disabled entries are
    /// skipped). Tab or Enter confirm and return to .password.
    /// ESC cancels (returns to .password without changing
    /// state.selected_session). Other input is ignored.
    picker,
    /// Stage 8: power-menu overlay open. The overlay shadows the
    /// picker if both are open simultaneously (in practice Ctrl-Q
    /// from inside the picker closes the picker before opening
    /// the power menu via the .pre_power_field bookmark). Up/Down
    /// move the cursor among three power options; Enter or the
    /// accelerator letter selects. Selecting Shutdown or Restart
    /// advances to a confirmation phase (state.power_menu_phase);
    /// selecting Suspend acts immediately. ESC backs out: from
    /// confirmation back to choosing; from choosing back to
    /// pre_power_field.
    power_menu,
    /// Stage 6: password has been submitted; main is performing
    /// PAM auth. UI renders an "Authenticating..." indicator and
    /// ignores all input (including Ctrl-Q) for the brief window
    /// auth takes. After auth resolves, main either calls launch()
    /// (success path, the surface will be torn down) or resets to
    /// .password with status_message set (failure path).
    submitting,
};

/// Stage 8: power-menu top-level choices. All three are real
/// operations with no v1 "not installed" placeholders; Suspend
/// is a no-op on platforms where `acpiconf -s 3` is unsupported
/// (the operator finds out by trying it).
pub const PowerOption = enum {
    shutdown,
    restart,
    suspend_,

    /// Display label shown in the menu.
    pub fn displayName(self: PowerOption) []const u8 {
        return switch (self) {
            .shutdown => "Shutdown",
            .restart => "Restart",
            .suspend_ => "Suspend",
        };
    }

    /// Accelerator letter shown in brackets.
    pub fn accelerator(self: PowerOption) u8 {
        return switch (self) {
            .shutdown => 'S',
            .restart => 'R',
            .suspend_ => 'Z',
        };
    }

    /// Whether selecting this option requires a Y/N confirm step.
    /// Shutdown and Restart are destructive and require confirm;
    /// Suspend is recoverable (the user wakes the machine and is
    /// back at the login screen) and does not.
    pub fn requiresConfirm(self: PowerOption) bool {
        return switch (self) {
            .shutdown, .restart => true,
            .suspend_ => false,
        };
    }

    /// Walk to the next option, wrapping. No "enabled" filter
    /// since all three are always live.
    pub fn next(self: PowerOption) PowerOption {
        return switch (self) {
            .shutdown => .restart,
            .restart => .suspend_,
            .suspend_ => .shutdown,
        };
    }

    pub fn prev(self: PowerOption) PowerOption {
        return switch (self) {
            .shutdown => .suspend_,
            .restart => .shutdown,
            .suspend_ => .restart,
        };
    }
};

/// Stage 8: which sub-state the power menu is in. .choosing is the
/// landing state when the menu opens; user selects an option here.
/// The two .confirming_* states are entered for shutdown/restart
/// after the user selects but before main invokes the command.
/// Suspend skips the confirm step. .in_progress is entered by
/// main after invoking the command; for shutdown/restart it
/// renders until init kills us, for suspend it renders briefly
/// while acpiconf blocks (the system is asleep at that point so
/// the user doesn't see it anyway, but on resume it stays just
/// long enough for one render before main clears it).
pub const PowerMenuPhase = enum {
    choosing,
    confirming_shutdown,
    confirming_restart,
    in_progress,
};

/// Stage 7: session-type categories the picker presents. v1 ships
/// .terminal as the only enabled choice; the other three are
/// visible-but-disabled placeholders for backends that will land
/// in future work (per ADR 0001 §Stage 7 v1 visual scope).
///
/// Each variant maps to a fixed `.session` file id via sessionId().
/// The picker default is .terminal; the per-user default_session
/// attribute is currently ignored by Stage 7 because only one
/// session type is real. When additional types come online, a
/// future commit can map per-user defaults onto picker defaults.
pub const SessionType = enum {
    terminal,
    x11,
    wayland,
    nde,

    /// Display label shown in the picker.
    pub fn displayName(self: SessionType) []const u8 {
        return switch (self) {
            .terminal => "Terminal",
            .x11 => "X11",
            .wayland => "Wayland",
            .nde => "NDE",
        };
    }

    /// .session file id (basename without extension). Only used
    /// when enabled() is true; disabled entries can't be selected.
    pub fn sessionId(self: SessionType) []const u8 {
        return switch (self) {
            .terminal => "default",
            .x11 => "x11",
            .wayland => "wayland",
            .nde => "nde",
        };
    }

    /// Whether this session type has a working backend in v1.
    /// Only .terminal is enabled; the other three render dim and
    /// the picker cursor skips over them.
    pub fn enabled(self: SessionType) bool {
        return switch (self) {
            .terminal => true,
            else => false,
        };
    }

    /// Secondary text shown after the display name. For enabled
    /// entries, this is the canonical session's Name (matching
    /// `default.session`'s Name= field). For disabled entries,
    /// this is "(not installed)" to make the disabled state
    /// explicit.
    pub fn detail(self: SessionType) []const u8 {
        return switch (self) {
            .terminal => "Default Awase Session",
            .x11, .wayland, .nde => "not installed",
        };
    }

    /// Walk to the next ENABLED variant in declaration order,
    /// wrapping. If no other enabled variant exists, returns self
    /// unchanged. Used by the picker's Down arrow.
    pub fn nextEnabled(self: SessionType) SessionType {
        var cur = self;
        const all = [_]SessionType{ .terminal, .x11, .wayland, .nde };
        // Find current index.
        var idx: usize = 0;
        for (all, 0..) |t, i| if (t == cur) { idx = i; break; };
        // Walk forward.
        var steps: usize = 0;
        while (steps < all.len) : (steps += 1) {
            idx = (idx + 1) % all.len;
            cur = all[idx];
            if (cur.enabled()) return cur;
        }
        return self;
    }

    /// Walk to the previous ENABLED variant. Mirror of nextEnabled.
    pub fn prevEnabled(self: SessionType) SessionType {
        var cur = self;
        const all = [_]SessionType{ .terminal, .x11, .wayland, .nde };
        var idx: usize = 0;
        for (all, 0..) |t, i| if (t == cur) { idx = i; break; };
        var steps: usize = 0;
        while (steps < all.len) : (steps += 1) {
            idx = if (idx == 0) all.len - 1 else idx - 1;
            cur = all[idx];
            if (cur.enabled()) return cur;
        }
        return self;
    }
};

pub const ExitReason = union(enum) {
    quit, // Ctrl-Q
    /// Stage 5 legacy. Stage 6 main.runUiOnly does NOT use this
    /// for the submit path: instead, it polls state.field for the
    /// .submitting transition and uses state.username / state.password
    /// directly. Retained for the --ui-only-no-auth historical mode
    /// (which Stage 6 no longer wires up; left in place in case a
    /// future flag re-enables it for testing).
    submitted: struct { username: []const u8, password_len: usize },
};

pub const State = struct {
    allocator: std.mem.Allocator,
    field: FieldState,
    username: std.ArrayListUnmanaged(u8),
    password: std.ArrayListUnmanaged(u8),
    typing_started: bool, // for cursor steady-on before first input

    // System info displayed at the top of the login UI.
    // - hostname: captured once at startup. Stable for the
    //   process lifetime; even if FreeBSD's hostname were
    //   changed at runtime via hostname(1), the login UI
    //   would not see it.
    // - realmem_str / physmem_str: captured once. Memory
    //   topology is stable for a running system.
    // - network_str: captured once at startup, then
    //   periodically refreshed by maybeRefreshNetwork()
    //   while the UI is up. The initial snapshot can show
    //   "no network" if DHCP has not completed by the time
    //   the UI launches; the periodic refresh updates the
    //   display once the interface comes up. See
    //   maybeRefreshNetwork() for the cadence.
    hostname: []const u8,
    network_str: []const u8, // "em0 192.168.1.42" or "no network"
    realmem_str: []const u8, // "16384 MB"
    physmem_str: []const u8, // "16278 MB"

    /// Wall-clock timestamp (ms since epoch) of the last call
    /// to maybeRefreshNetwork() that actually performed the
    /// getifaddrs walk. Used to throttle re-polling to the
    /// NETWORK_REFRESH_INTERVAL_MS cadence regardless of frame
    /// rate.
    network_last_refresh_ms: i64,

    /// Stage 6: status line displayed below the fields. Set by main
    /// when an auth attempt fails ("authentication failed; 2
    /// attempts remaining") or when an unrecoverable PAM error
    /// occurs. Cleared automatically on the next keystroke that
    /// modifies a field, so the user sees the message until they
    /// react. Owned by the caller (main) and lifetime is tied to
    /// the runUiOnly stack frame; ui.zig only reads the slice and
    /// never frees it.
    status_message: ?[]const u8,

    /// Stage 7: which session type is currently selected for this
    /// login. Default is .terminal (the only enabled choice in v1).
    /// Set by the picker on Tab/Enter confirm; used by main when
    /// resolving the .session file to launch. The selection does
    /// NOT persist beyond this login (per ADR 0001 §Login UI v1).
    selected_session: SessionType = .terminal,

    /// Stage 7: cursor position within the picker overlay. Live
    /// only while field == .picker. Initialised to selected_session
    /// each time the picker opens, so the user starts on what they
    /// last confirmed. ESC discards picker_cursor; Tab/Enter commits
    /// it to selected_session.
    picker_cursor: SessionType = .terminal,

    /// Stage 8: where to return when the power menu is dismissed
    /// without committing to an action (via ESC or another Ctrl-Q).
    /// Set when the power menu opens; read when it closes. Live
    /// only while field == .power_menu.
    pre_power_field: FieldState = .identify,

    /// Stage 8: which sub-phase of the power menu we're in. Live
    /// only while field == .power_menu. .choosing is the landing
    /// state; .confirming_* is entered when the user selects
    /// shutdown or restart.
    power_menu_phase: PowerMenuPhase = .choosing,

    /// Stage 8: cursor within the power menu choices in .choosing
    /// phase. Default .shutdown puts the cursor on the most
    /// disruptive option, requiring deliberate confirmation; this
    /// is intentional (users who Ctrl-Q out of muscle memory should
    /// see the confirm step, not slip into a suspend).
    power_menu_cursor: PowerOption = .shutdown,

    /// Stage 8: set when the user confirms a power action.
    /// main.runUiOnly reads this and invokes the corresponding
    /// FreeBSD command. The field is cleared after main acts on it
    /// (Suspend is the only one that returns; Shutdown and Restart
    /// terminate the system and don't come back).
    power_action: ?PowerOption = null,

    /// Stage 6: legacy field. ExitReason has only one remaining
    /// caller (the disconnected-event handler in main, which sets
    /// .quit when semadrawd vanishes). Stage 8's power menu
    /// replaced the previous Ctrl-Q-quits semantics, so the .quit
    /// variant is now reserved for that involuntary case.
    exit_reason: ?ExitReason,

    pub fn init(allocator: std.mem.Allocator) !State {
        // Gather sysinfo. Each piece may fail independently; on
        // failure, substitute a benign placeholder so the UI can
        // still render and the user can still log in. A failed
        // sysctl is not a reason to refuse login.
        const host = sysinfo.hostname(allocator) catch
            try allocator.dupe(u8, "unknown");
        errdefer allocator.free(host);

        // Uppercase the hostname for display. The login UI uses
        // all-caps for the major identifying strings (HOSTNAME,
        // IDENTIFY, PASSWORD) to match the CRT-era visual style.
        // DNS and POSIX hostnames are case-insensitive so this
        // transformation is lossless for our purposes; no other
        // code path consumes state.hostname (it's display-only).
        for (host) |*ch| ch.* = std.ascii.toUpper(ch.*);

        const realmem = sysinfo.realMemBytes() catch 0;
        const physmem = sysinfo.physMemBytes() catch 0;
        const realmem_str = if (realmem == 0)
            try allocator.dupe(u8, "unknown")
        else
            try sysinfo.formatMemMB(allocator, realmem);
        errdefer allocator.free(realmem_str);
        const physmem_str = if (physmem == 0)
            try allocator.dupe(u8, "unknown")
        else
            try sysinfo.formatMemMB(allocator, physmem);
        errdefer allocator.free(physmem_str);

        const net_str = blk: {
            const maybe_net = sysinfo.network(allocator) catch null;
            if (maybe_net) |net| {
                var net_mut = net;
                defer net_mut.deinit(allocator);
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{s} {s}",
                    .{ net.ifname, net.ipv4Slice() },
                );
            }
            break :blk try allocator.dupe(u8, "no network");
        };

        return State{
            .allocator = allocator,
            .field = .identify,
            .username = .empty,
            .password = .empty,
            .typing_started = false,
            .hostname = host,
            .network_str = net_str,
            .realmem_str = realmem_str,
            .physmem_str = physmem_str,
            .network_last_refresh_ms = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms))),
            .status_message = null,
            .selected_session = .terminal,
            .picker_cursor = .terminal,
            .pre_power_field = .identify,
            .power_menu_phase = .choosing,
            .power_menu_cursor = .shutdown,
            .power_action = null,
            .exit_reason = null,
        };
    }

    pub fn deinit(self: *State) void {
        self.username.deinit(self.allocator);
        self.password.deinit(self.allocator);
        self.allocator.free(self.hostname);
        self.allocator.free(self.network_str);
        self.allocator.free(self.realmem_str);
        self.allocator.free(self.physmem_str);
    }

    /// Periodically re-query the network state and update
    /// network_str if it has changed.
    ///
    /// Why: sysinfo.network() runs once at State.init, but the
    /// UI launches early in boot, often before DHCP has finished
    /// negotiating an address. The initial snapshot can therefore
    /// say "no network" even on a machine that is physically
    /// connected; once the interface comes up a few seconds
    /// later, nothing was updating the display. This method
    /// closes that gap by re-running the getifaddrs walk at the
    /// NETWORK_REFRESH_INTERVAL_MS cadence.
    ///
    /// Cadence: throttled by wall-clock time so the call is safe
    /// to invoke every frame from the main loop. Returns
    /// immediately if less than NETWORK_REFRESH_INTERVAL_MS has
    /// elapsed since the last actual refresh.
    ///
    /// Allocation: builds a candidate string with the new
    /// formatted result, compares to the current network_str,
    /// and either keeps the candidate (freeing the old) or
    /// discards it (freeing the candidate). The string is only
    /// replaced when its content actually changed, so the
    /// display never flickers on a no-op refresh.
    ///
    /// Errors: silently ignored. A failed getifaddrs leaves the
    /// previous network_str in place; from the user's
    /// perspective the display simply does not update this
    /// cycle. The next cycle (or the one after) will try again.
    /// This is intentional: a login screen with a stale network
    /// indicator is far less disruptive than one that pops an
    /// error dialog.
    pub fn maybeRefreshNetwork(self: *State) bool {
        const now = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms)));
        if (now - self.network_last_refresh_ms < NETWORK_REFRESH_INTERVAL_MS) {
            return false;
        }
        self.network_last_refresh_ms = now;

        const candidate = blk: {
            const maybe_net = sysinfo.network(self.allocator) catch break :blk null;
            if (maybe_net) |net| {
                var net_mut = net;
                defer net_mut.deinit(self.allocator);
                break :blk std.fmt.allocPrint(
                    self.allocator,
                    "{s} {s}",
                    .{ net.ifname, net.ipv4Slice() },
                ) catch null;
            }
            break :blk self.allocator.dupe(u8, "no network") catch null;
        };

        if (candidate) |new_str| {
            if (std.mem.eql(u8, new_str, self.network_str)) {
                self.allocator.free(new_str);
            } else {
                self.allocator.free(self.network_str);
                self.network_str = new_str;
                // SM-4: the string changed; tell the caller a
                // redraw is warranted.
                return true;
            }
        }
        return false;
    }

    // Handle one input action. SM-4: redraws are gated on actual
    // change now (the main loop's needs_redraw flag); the drain
    // path marks the flag on key events, so by the time this runs
    // the redraw is already scheduled. The caret blink is wall-
    // clock phased and redraws twice a second, only after typing
    // has started.
    pub fn handleAction(self: *State, action: keymap.Action) !void {
        // .submitting locks the UI: main is calling PAM, the user
        // shouldn't be able to mutate username or password while
        // the auth call is in flight. The power menu is also locked
        // out here; if the user wants to power off they can wait
        // for PAM to finish (a few seconds at most).
        if (self.field == .submitting) {
            return;
        }

        // Stage 8: .power_menu is the most modal overlay. Handle
        // it before anything else (including picker) so that
        // entering the menu can shadow the picker if necessary.
        if (self.field == .power_menu) {
            self.handlePowerMenuInput(action);
            return;
        }

        // Stage 7: .picker is a modal overlay over the .password
        // field. Different keybinding semantics: arrows move,
        // Tab/Enter confirm, ESC cancels, everything else ignored.
        // Handle it here as a separate switch from the main
        // identify/password input path.
        if (self.field == .picker) {
            switch (action) {
                .power_menu => {
                    // Ctrl-Q from inside the picker: close the
                    // picker (without committing the cursor
                    // selection) and open the power menu rooted
                    // at .password (the picker's parent state).
                    // openPowerMenu sets self.field = .power_menu;
                    // ESC from the menu will return to .password.
                    self.openPowerMenu(.password);
                },
                .up => self.picker_cursor = self.picker_cursor.prevEnabled(),
                .down => self.picker_cursor = self.picker_cursor.nextEnabled(),
                .tab, .enter => {
                    // Confirm: commit picker_cursor to selected_session
                    // and return to the password field. picker_cursor
                    // is guaranteed to point at an enabled entry
                    // because (a) it was initialised to .terminal
                    // (enabled) on open, and (b) up/down only move
                    // to enabled entries.
                    self.selected_session = self.picker_cursor;
                    self.field = .password;
                    // Clear any status message; the user has now
                    // committed a choice, prior auth failures are
                    // no longer relevant context.
                    self.status_message = null;
                },
                .clear => {
                    // ESC: discard picker_cursor, return to password
                    // with selected_session unchanged.
                    self.field = .password;
                },
                // print, backspace, none: ignored while picker is open.
                else => {},
            }
            return;
        }

        switch (action) {
            .none => {},
            .power_menu => {
                // Stage 8: Ctrl-Q opens the power menu from identify
                // or password. Reachable from either state so the
                // user can power off without having first identified.
                self.openPowerMenu(self.field);
            },
            .clear => {
                self.activeField().clearRetainingCapacity();
                self.status_message = null;
            },
            .backspace => {
                const f = self.activeField();
                if (f.items.len > 0) {
                    _ = f.pop();
                    self.status_message = null;
                }
            },
            .print => |ch| {
                self.typing_started = true;
                self.status_message = null;
                const f = self.activeField();
                const cap = self.activeFieldMax();
                if (f.items.len < cap) {
                    try f.append(self.allocator, ch);
                }
            },
            .enter => {
                switch (self.field) {
                    .identify => {
                        if (self.username.items.len > 0) {
                            self.field = .password;
                            self.typing_started = false;
                        }
                    },
                    .password => {
                        // Stage 6: transition to .submitting and let
                        // main pick up the request via state.field on
                        // the next loop iteration. Don't set
                        // exit_reason; we want the UI to keep
                        // rendering an "Authenticating..." indicator.
                        self.field = .submitting;
                    },
                    .picker, .power_menu, .submitting => unreachable, // guarded above
                }
            },
            .session_picker => {
                // Stage 7: Ctrl-S opens the session picker overlay.
                // Same behavior and same guard as .tab below: only from
                // the password field, because selected_session is
                // per-login and there is no point choosing one before
                // the user has identified themselves.
                //
                // This exists because bare Tab stopped being delivered
                // to this daemon while Ctrl chords kept arriving. See
                // keymap.translate. Both routes are kept.
                if (self.field == .password) {
                    self.picker_cursor = self.selected_session;
                    self.field = .picker;
                    self.status_message = null;
                }
            },
            .tab => {
                // Stage 7: Tab opens the session picker overlay,
                // but ONLY from the password field. From identify,
                // Tab is a no-op (we don't want users tabbing to a
                // picker before they've identified themselves; the
                // selected_session is per-login anyway).
                if (self.field == .password) {
                    self.picker_cursor = self.selected_session;
                    self.field = .picker;
                    self.status_message = null;
                }
            },
            .up, .down => {
                // Arrow keys outside the picker/power-menu are
                // ignored. The login fields are single-line, so
                // there's nothing to navigate.
            },
        }
    }

    /// Stage 8 helper: open the power menu, recording the field
    /// to return to on ESC/cancel. Cursor starts at .shutdown
    /// (intentionally; users who Ctrl-Q out of muscle memory
    /// should see the confirm step rather than slip into Suspend).
    fn openPowerMenu(self: *State, return_to: FieldState) void {
        // Defensive: power menu can't be the return target.
        // .submitting also shouldn't appear here (we never call
        // openPowerMenu while submitting). Coerce both to
        // .identify so the user lands somewhere sane on ESC.
        const safe_return: FieldState = switch (return_to) {
            .identify, .password => return_to,
            .picker, .power_menu, .submitting => .identify,
        };
        self.pre_power_field = safe_return;
        self.power_menu_phase = .choosing;
        self.power_menu_cursor = .shutdown;
        self.field = .power_menu;
        self.status_message = null;
    }

    /// Stage 8 helper: input handling for the power menu states.
    /// Separated from handleAction so the main switch stays small
    /// and the menu's state machine is self-contained.
    fn handlePowerMenuInput(self: *State, action: keymap.Action) void {
        switch (self.power_menu_phase) {
            .choosing => self.handlePowerMenuChoosing(action),
            .confirming_shutdown => self.handlePowerMenuConfirming(action, .shutdown),
            .confirming_restart => self.handlePowerMenuConfirming(action, .restart),
            .in_progress => {
                // Command has been invoked; ignore all input. For
                // shutdown/restart we'll be killed by init shortly;
                // for suspend the system is already asleep.
            },
        }
    }

    fn handlePowerMenuChoosing(self: *State, action: keymap.Action) void {
        switch (action) {
            .up => self.power_menu_cursor = self.power_menu_cursor.prev(),
            .down => self.power_menu_cursor = self.power_menu_cursor.next(),
            .enter => self.commitPowerMenuChoice(self.power_menu_cursor),
            .print => |ch| {
                // Accelerator letters: S/R/Z (case-insensitive).
                const lower: u8 = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
                switch (lower) {
                    's' => self.commitPowerMenuChoice(.shutdown),
                    'r' => self.commitPowerMenuChoice(.restart),
                    'z' => self.commitPowerMenuChoice(.suspend_),
                    else => {},
                }
            },
            .clear, .power_menu => {
                // ESC or another Ctrl-Q closes the menu, returning
                // to whatever field the user opened it from.
                self.field = self.pre_power_field;
            },
            // tab, backspace, none: ignored in the menu.
            else => {},
        }
    }

    fn handlePowerMenuConfirming(self: *State, action: keymap.Action, option: PowerOption) void {
        switch (action) {
            .print => |ch| {
                const lower: u8 = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
                switch (lower) {
                    'y' => {
                        // Confirm: arm the action for main to read.
                        self.power_action = option;
                        // Stay in .power_menu so the UI renders
                        // "Shutting down..." or similar until main
                        // takes over.
                    },
                    'n' => {
                        // Cancel back to choosing.
                        self.power_menu_phase = .choosing;
                    },
                    else => {},
                }
            },
            .enter => {
                // Enter on the confirm screen treats as Y.
                self.power_action = option;
            },
            .clear => {
                // ESC backs out of confirm to choosing.
                self.power_menu_phase = .choosing;
            },
            .power_menu => {
                // Ctrl-Q from confirm closes the menu entirely,
                // same as ESC twice. Returns to pre_power_field.
                self.field = self.pre_power_field;
            },
            // up, down, tab, backspace, none: ignored.
            else => {},
        }
    }

    /// Stage 8 helper: act on a choice from the power menu's
    /// choosing phase. Shutdown and Restart advance to confirm;
    /// Suspend arms the action immediately.
    fn commitPowerMenuChoice(self: *State, option: PowerOption) void {
        if (option.requiresConfirm()) {
            self.power_menu_phase = switch (option) {
                .shutdown => .confirming_shutdown,
                .restart => .confirming_restart,
                .suspend_ => unreachable, // !requiresConfirm
            };
            // Move the cursor to track the choice so a subsequent
            // ESC/back-out lands the user where they were.
            self.power_menu_cursor = option;
        } else {
            self.power_action = option;
        }
    }

    /// Stage 6 helper: called by main after an auth attempt fails
    /// with a retryable error. Returns the state to the .password
    /// field with the password buffer cleared, sets the status
    /// message, and resets typing_started so the cursor sits steady
    /// until the user types. Username is preserved (standard X
    /// login screen behaviour).
    pub fn resetForRetry(self: *State, status: []const u8) void {
        self.password.clearRetainingCapacity();
        self.field = .password;
        self.typing_started = false;
        self.status_message = status;
    }

    fn activeField(self: *State) *std.ArrayListUnmanaged(u8) {
        return switch (self.field) {
            .identify => &self.username,
            .password => &self.password,
            .picker, .power_menu, .submitting => unreachable, // guarded in handleAction
        };
    }

    fn activeFieldMax(self: *const State) usize {
        return switch (self.field) {
            .identify => USERNAME_MAX,
            .password => PASSWORD_MAX,
            .picker, .power_menu, .submitting => unreachable,
        };
    }
};

// =============================================================================
// Drawing
// =============================================================================
//
// The login panel is drawn vertically centered on the surface.
// All measurements are in pixels relative to the surface origin
// (top-left).
//
// Pre-computed font atlas is exposed by font.zig as font.Font.ATLAS
// (compile-time evaluation of generateAtlas). Reference it by name
// rather than re-declaring a local copy.

// Render a string at (x, y) in the given color, using the bitmap
// font scaled up by SCALE. Each glyph occupies (GLYPH_WIDTH * SCALE)
// by (GLYPH_HEIGHT * SCALE) pixels on the surface. The compositor
// stretches the atlas glyph from its native 8x16 to that cell size
// at blit time.
//
// Characters outside the supported range render as the fallback
// glyph (filled box).
fn drawText(
    enc: *Encoder,
    text: []const u8,
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
) !void {
    if (text.len == 0) return;

    const scaled_w: u32 = font.Font.GLYPH_WIDTH * SCALE;
    const scaled_h: u32 = font.Font.GLYPH_HEIGHT * SCALE;
    const scaled_w_f: f32 = @floatFromInt(scaled_w);

    // Build the glyph run. One entry per byte (ASCII; no UTF-8
    // decoding needed because Identify/Password/sysinfo strings are
    // all ASCII for v1). Per-glyph x_offset must reflect the scaled
    // cell width, not the atlas glyph width.
    var glyphs_buf: [USERNAME_MAX + PASSWORD_MAX + 64]semadraw.Encoder.Glyph = undefined;
    if (text.len > glyphs_buf.len) return; // shouldn't happen at our sizes
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const idx = font.Font.charToIndexWithFallback(@intCast(text[i]));
        glyphs_buf[i] = .{
            .index = idx,
            .x_offset = @as(f32, @floatFromInt(i)) * scaled_w_f,
            .y_offset = 0,
        };
    }

    try enc.drawGlyphRun(
        x,
        y,
        r,
        g,
        b,
        a,
        scaled_w,
        scaled_h,
        font.Font.ATLAS_COLS,
        font.Font.ATLAS_WIDTH,
        font.Font.ATLAS_HEIGHT,
        glyphs_buf[0..text.len],
        &font.Font.ATLAS,
    );
}

// Draw a rectangular border at (x, y, w, h) by filling four
// thin rectangles. Border thickness scales with SCALE so it
// remains visible at high zooms (1 unscaled px -> SCALE px).
fn drawBorder(enc: *Encoder, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32, a: f32) !void {
    const t: f32 = FIELD_BORDER_WIDTH_U * @as(f32, @floatFromInt(SCALE));
    try enc.fillRect(x, y, w, t, r, g, b, a); // top
    try enc.fillRect(x, y + h - t, w, t, r, g, b, a); // bottom
    try enc.fillRect(x, y, t, h, r, g, b, a); // left
    try enc.fillRect(x + w - t, y, t, h, r, g, b, a); // right
}

/// Draw one frame of the login UI into the encoder. The caller
/// supplies the surface dimensions (queried from the daemon) so
/// the layout can center on the real display rather than assuming
/// a fixed size.
pub fn draw(state: *const State, enc: *Encoder, blink_phase: u64, surface_w: f32, surface_h: f32) !void {
    const sf: f32 = @floatFromInt(SCALE);
    const scaled_gw: f32 = @as(f32, @floatFromInt(font.Font.GLYPH_WIDTH)) * sf;
    const scaled_gh: f32 = @as(f32, @floatFromInt(font.Font.GLYPH_HEIGHT)) * sf;
    const line_step: f32 = scaled_gh + 8.0 * sf; // line height + leading

    // Background: pure black covering the full surface.
    try enc.fillRect(0, 0, surface_w, surface_h, 0, 0, 0, 1);

    // System info block, centered horizontally, anchored near the
    // top quarter of the surface. Four lines: hostname, network,
    // realmem, physmem. Rendered in the cyan palette to mark
    // them as non-interactive context (see palette block at top
    // of file for rationale).
    const sysinfo_top: f32 = surface_h * 0.18;

    // Hostname (bright cyan).
    {
        const text = state.hostname;
        const w: f32 = @as(f32, @floatFromInt(text.len)) * scaled_gw;
        const x: f32 = (surface_w - w) / 2;
        try drawText(enc, text, x, sysinfo_top, CYAN_R, CYAN_G, CYAN_B, CYAN_A);
    }
    // Network status (dim cyan).
    {
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "network: {s}", .{state.network_str}) catch state.network_str;
        const w: f32 = @as(f32, @floatFromInt(text.len)) * scaled_gw;
        const x: f32 = (surface_w - w) / 2;
        try drawText(enc, text, x, sysinfo_top + line_step, DIM_CYAN_R, DIM_CYAN_G, DIM_CYAN_B, DIM_CYAN_A);
    }
    // Real mem (dim cyan).
    {
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "real mem   = {s}", .{state.realmem_str}) catch state.realmem_str;
        const w: f32 = @as(f32, @floatFromInt(text.len)) * scaled_gw;
        const x: f32 = (surface_w - w) / 2;
        try drawText(enc, text, x, sysinfo_top + 2 * line_step, DIM_CYAN_R, DIM_CYAN_G, DIM_CYAN_B, DIM_CYAN_A);
    }
    // Actual mem (dim cyan).
    {
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "actual mem = {s}", .{state.physmem_str}) catch state.physmem_str;
        const w: f32 = @as(f32, @floatFromInt(text.len)) * scaled_gw;
        const x: f32 = (surface_w - w) / 2;
        try drawText(enc, text, x, sysinfo_top + 3 * line_step, DIM_CYAN_R, DIM_CYAN_G, DIM_CYAN_B, DIM_CYAN_A);
    }

    // Fields, centered vertically. The Identify field sits slightly
    // above center; the Password field sits below it. Both fields'
    // y positions are computed from the surface height so they look
    // right regardless of resolution.
    const fields_center: f32 = surface_h * 0.55;
    const field_height: f32 = scaled_gh + 12.0 * sf;
    const field_spacing: f32 = field_height + 24.0 * sf;

    // Identify field (always visible).
    try drawField(
        state,
        enc,
        blink_phase,
        .identify,
        "IDENTIFY:",
        state.username.items,
        false,
        fields_center - field_height / 2 - field_spacing / 2,
        surface_w,
    );

    // Password field: shown once the user has advanced past
    // Identify, in any of .password (active typing), .picker
    // (session-picker overlay open above), or .submitting
    // (auth in flight). The picker is drawn as an overlay on top;
    // it does not replace the field underneath, so the user
    // retains context for where they were when they opened the
    // picker.
    // Password field: shown once the user has advanced past
    // Identify, in any of .password (active typing), .picker
    // (session-picker overlay open above), .power_menu (overlay
    // open above, but only when the menu was opened from
    // password), or .submitting (auth in flight). The picker
    // and power menu are drawn as overlays on top; they do not
    // replace the field underneath, so the user retains context
    // for where they were when they opened the overlay.
    const password_visible = state.field == .password or
        state.field == .picker or
        state.field == .submitting or
        (state.field == .power_menu and state.pre_power_field == .password);
    if (password_visible) {
        try drawField(
            state,
            enc,
            blink_phase,
            .password,
            "PASSWORD:",
            state.password.items,
            true,
            fields_center - field_height / 2 + field_spacing / 2,
            surface_w,
        );
    }

    // Stage 6: "Authenticating..." indicator while PAM auth is in
    // flight. Drawn between the field and the hint line.
    if (state.field == .submitting) {
        const msg = "Authenticating...";
        const w: f32 = @as(f32, @floatFromInt(msg.len)) * scaled_gw;
        const x: f32 = (surface_w - w) / 2;
        const y: f32 = fields_center + field_height * 1.5 + line_step;
        try drawText(enc, msg, x, y, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
    }

    // Stage 6: status message (auth failures, fatal errors).
    // Drawn just above the hint line in amber.
    if (state.status_message) |status| {
        const w: f32 = @as(f32, @floatFromInt(status.len)) * scaled_gw;
        const x: f32 = (surface_w - w) / 2;
        const y: f32 = surface_h - line_step * 3.5;
        try drawText(enc, status, x, y, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
    }

    // Stage 7: session-picker overlay.
    if (state.field == .picker) {
        try drawPicker(state, enc, surface_w, surface_h);
    }

    // Stage 8: power-menu overlay.
    if (state.field == .power_menu) {
        try drawPowerMenu(state, enc, surface_w, surface_h);
    }

    // Hint line, anchored near the bottom of the surface. Hint
    // text varies by state. Accessibility note: keybindings are
    // essential information for operating the UI, so the hint
    // line is rendered in bright amber rather than dim. The prior
    // dim treatment under-prioritised the user's most direct
    // affordance for what they can do next; bright amber matches
    // the rest of the UI's foreground colour and ensures the
    // hint is read first, not last.
    //
    // Format: legend style "[KEY] Action   [KEY] Action ..."
    // - Key names in ALL CAPS inside square brackets, matching
    //   how the physical keyboard labels them.
    // - Action verb in Title Case immediately after the bracket.
    // - Three spaces separate legend chips so the brackets
    //   visually group each chip without needing dividers.
    // - States that accept no input (.submitting,
    //   .in_progress) show an informational status instead of
    //   a legend, since legend chips would imply pressable
    //   keys.
    {
        const hint = switch (state.field) {
            .power_menu => switch (state.power_menu_phase) {
                .choosing => "[UP/DN] Select   [ENTER] Choose   [ESC] Cancel",
                .confirming_shutdown => "[Y] Power off   [N] Back   [ESC] Cancel",
                .confirming_restart => "[Y] Reboot   [N] Back   [ESC] Cancel",
                .in_progress => "Please wait...",
            },
            .picker => "[UP/DN] Select   [ENTER] Confirm   [ESC] Cancel",
            // Advertise CTRL-S, not TAB. Bare Tab is not currently
            // delivered to this daemon (Ctrl chords are), so a legend
            // chip saying [TAB] tells the user to press a key that does
            // nothing. Tab still works to confirm inside the picker,
            // which the .picker legend does not need to mention because
            // [ENTER] is the one users reach for.
            .password => "[ENTER] Log in   [CTRL-S] Change session   [ESC] Clear   [CTRL-Q] Power",
            .identify => "[ENTER] Continue   [ESC] Clear   [CTRL-Q] Power",
            .submitting => "Authenticating...",
        };
        const w: f32 = @as(f32, @floatFromInt(hint.len)) * scaled_gw;
        const x: f32 = (surface_w - w) / 2;
        const y: f32 = surface_h - line_step * 2;
        try drawText(enc, hint, x, y, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
    }
}

fn drawPicker(
    state: *const State,
    enc: *Encoder,
    surface_w: f32,
    surface_h: f32,
) !void {
    const sf: f32 = @floatFromInt(SCALE);
    const scaled_gw: f32 = @as(f32, @floatFromInt(font.Font.GLYPH_WIDTH)) * sf;
    const scaled_gh: f32 = @as(f32, @floatFromInt(font.Font.GLYPH_HEIGHT)) * sf;
    const row_pad_y: f32 = 6.0 * sf;
    const panel_pad: f32 = 16.0 * sf;

    // Title and entry layout.
    const title = "Session type:";

    // Filter to enabled session types only. Unavailable sessions
    // (X11, Wayland, NDE in v1) are not shown to the user. The
    // picker is still opened to confirm the chosen session even
    // when only one option exists; that confirmation has value
    // even without a meaningful choice. Accessibility note: the
    // earlier behaviour drew all four entries with three of them
    // labelled "not installed", which created visual scanning
    // noise. Hiding unavailable entries entirely is consistent
    // with the SessionType.enabled() contract and reduces the
    // number of rows the eye has to track.
    const all = [_]SessionType{ .terminal, .x11, .wayland, .nde };
    var enabled_buf: [4]SessionType = undefined;
    var enabled_n: usize = 0;
    for (all) |t| {
        if (t.enabled()) {
            enabled_buf[enabled_n] = t;
            enabled_n += 1;
        }
    }
    const enabled = enabled_buf[0..enabled_n];

    // Defensive: if no session types are enabled at all, drawing
    // an empty picker makes no sense. This is unreachable in v1
    // (Terminal is always enabled) and the picker code path is
    // not reached in that hypothetical state - main would never
    // launch the UI without a usable session. Bail silently
    // rather than divide by zero or draw a degenerate panel.
    if (enabled.len == 0) return;

    // Compute panel dimensions from the widest row.
    //   "  DisplayName    detail"
    // where the row starts at a constant indent (no cursor prefix
    // - the cursor is now a reverse-video bar drawn behind the
    // row, see below), DisplayName is left-padded to a fixed
    // column so detail aligns across rows.
    const NAME_COL_WIDTH: usize = 10; // "Wayland   " padded
    const ROW_INDENT: usize = 2;       // leading spaces before the name
    var max_chars: usize = title.len;
    for (enabled) |t| {
        const row_chars: usize = ROW_INDENT + NAME_COL_WIDTH + t.detail().len;
        if (row_chars > max_chars) max_chars = row_chars;
    }
    const content_w: f32 = @as(f32, @floatFromInt(max_chars)) * scaled_gw;
    const row_h: f32 = scaled_gh + row_pad_y;
    // title + blank + N rows. Panel height grows with enabled_n,
    // so a single-enabled picker is appropriately short.
    const content_h: f32 = (@as(f32, @floatFromInt(enabled.len + 2))) * row_h;
    const panel_w: f32 = content_w + 2 * panel_pad;
    const panel_h: f32 = content_h + 2 * panel_pad;
    const panel_x: f32 = (surface_w - panel_w) / 2;
    const panel_y: f32 = (surface_h - panel_h) / 2;

    // Solid black panel background to occlude what's underneath,
    // then amber border.
    try enc.fillRect(panel_x, panel_y, panel_w, panel_h, 0, 0, 0, 1);
    try drawBorder(enc, panel_x, panel_y, panel_w, panel_h, AMBER_R, AMBER_G, AMBER_B, AMBER_A);

    // Title row (bright amber).
    const text_x: f32 = panel_x + panel_pad;
    var y: f32 = panel_y + panel_pad;
    try drawText(enc, title, text_x, y, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
    y += row_h * 2; // skip a blank row after the title

    // Selection bar geometry. The bar is wider than the text on
    // each side by bar_pad_x, and vertically extends a few pixels
    // above and below the glyph row so the text sits centred in
    // the bar with visible padding. Accessibility note: a full-
    // row reverse-video bar (amber background, black foreground)
    // makes the cursor row unmistakable even at a glance, which
    // a two-character "[>] " prefix cannot achieve. The earlier
    // prefix-only treatment relied on the user actively scanning
    // for the marker; the bar makes the focus visible at the
    // pre-attentive level.
    const bar_pad_x: f32 = 4.0 * sf;
    const bar_pad_y: f32 = row_pad_y / 2.0;

    // Session rows.
    for (enabled) |t| {
        const is_cursor = (t == state.picker_cursor);

        // Pad the display name to NAME_COL_WIDTH so detail columns line up.
        const name = t.displayName();
        var name_padded: [NAME_COL_WIDTH]u8 = undefined;
        @memset(&name_padded, ' ');
        const copy_n = @min(name.len, NAME_COL_WIDTH);
        @memcpy(name_padded[0..copy_n], name[0..copy_n]);

        // Indent + name + detail. No cursor-prefix glyphs; the bar
        // carries the focus indication on its own.
        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            "  {s}{s}",
            .{ name_padded[0..NAME_COL_WIDTH], t.detail() },
        ) catch line_buf[0..0];

        if (is_cursor) {
            // Reverse-video selection bar. Fill amber background
            // across the panel's content area for this row, then
            // draw the text in black on top. Both rects share
            // bar_pad_x / bar_pad_y so the highlight looks like a
            // proper button rather than a tight box around the
            // glyphs.
            try enc.fillRect(
                text_x - bar_pad_x,
                y - bar_pad_y,
                content_w + 2 * bar_pad_x,
                scaled_gh + 2 * bar_pad_y,
                AMBER_R,
                AMBER_G,
                AMBER_B,
                AMBER_A,
            );
            try drawText(enc, line, text_x, y, 0, 0, 0, 1);
        } else {
            // Non-selected enabled row: bright amber on black,
            // same as before this accessibility pass. (Disabled
            // rows used to render in DIM but are now filtered out
            // entirely; the dim-row path is dead.)
            try drawText(enc, line, text_x, y, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
        }
        y += row_h;
    }
}

fn drawPowerMenu(
    state: *const State,
    enc: *Encoder,
    surface_w: f32,
    surface_h: f32,
) !void {
    const sf: f32 = @floatFromInt(SCALE);
    const scaled_gw: f32 = @as(f32, @floatFromInt(font.Font.GLYPH_WIDTH)) * sf;
    const scaled_gh: f32 = @as(f32, @floatFromInt(font.Font.GLYPH_HEIGHT)) * sf;
    const row_pad_y: f32 = 6.0 * sf;
    const panel_pad: f32 = 16.0 * sf;
    const row_h: f32 = scaled_gh + row_pad_y;

    switch (state.power_menu_phase) {
        .choosing => {
            const title = "Power options:";
            const all = [_]PowerOption{ .shutdown, .restart, .suspend_ };

            // Compute panel dimensions from widest row.
            //   "  [S] Shutdown" -> 2 + 4 + name
            // where the row starts at a constant indent (no cursor
            // prefix - the cursor is a reverse-video bar drawn
            // behind the row, see below), "[S] " is the accelerator
            // letter in brackets, and the name is the displayName.
            // Accessibility note: a full-row reverse-video bar
            // (amber background, black foreground) makes the
            // cursor row unmistakable. The prior "[>] " prefix
            // required active scanning; the bar carries the focus
            // indication pre-attentively.
            const ROW_INDENT: usize = 2;
            var max_chars: usize = title.len;
            for (all) |opt| {
                const row_chars: usize = ROW_INDENT + 4 + opt.displayName().len;
                if (row_chars > max_chars) max_chars = row_chars;
            }
            const content_w: f32 = @as(f32, @floatFromInt(max_chars)) * scaled_gw;
            const content_h: f32 = (@as(f32, @floatFromInt(all.len + 2))) * row_h;
            const panel_w: f32 = content_w + 2 * panel_pad;
            const panel_h: f32 = content_h + 2 * panel_pad;
            const panel_x: f32 = (surface_w - panel_w) / 2;
            const panel_y: f32 = (surface_h - panel_h) / 2;

            try enc.fillRect(panel_x, panel_y, panel_w, panel_h, 0, 0, 0, 1);
            try drawBorder(enc, panel_x, panel_y, panel_w, panel_h, AMBER_R, AMBER_G, AMBER_B, AMBER_A);

            const text_x: f32 = panel_x + panel_pad;
            var y: f32 = panel_y + panel_pad;
            try drawText(enc, title, text_x, y, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
            y += row_h * 2;

            // Selection bar geometry matches drawPicker's so the
            // two overlays look visually consistent.
            const bar_pad_x: f32 = 4.0 * sf;
            const bar_pad_y: f32 = row_pad_y / 2.0;

            for (all) |opt| {
                const is_cursor = (opt == state.power_menu_cursor);
                var buf: [64]u8 = undefined;
                const accel = opt.accelerator();
                // Indent + accelerator + name. No cursor prefix
                // glyphs; the bar carries the focus.
                const line = std.fmt.bufPrint(
                    &buf,
                    "  [{c}] {s}",
                    .{ accel, opt.displayName() },
                ) catch buf[0..0];

                if (is_cursor) {
                    try enc.fillRect(
                        text_x - bar_pad_x,
                        y - bar_pad_y,
                        content_w + 2 * bar_pad_x,
                        scaled_gh + 2 * bar_pad_y,
                        AMBER_R,
                        AMBER_G,
                        AMBER_B,
                        AMBER_A,
                    );
                    try drawText(enc, line, text_x, y, 0, 0, 0, 1);
                } else {
                    try drawText(enc, line, text_x, y, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
                }
                y += row_h;
            }
        },
        .confirming_shutdown, .confirming_restart => {
            const is_shutdown = state.power_menu_phase == .confirming_shutdown;
            const title = if (is_shutdown) "Confirm shutdown?" else "Confirm restart?";
            const yes_line = if (is_shutdown)
                "[Y] Yes, power off"
            else
                "[Y] Yes, reboot";
            const no_line = "[N] No, cancel";

            // Compute panel dimensions from widest row.
            var max_chars: usize = title.len;
            if (yes_line.len > max_chars) max_chars = yes_line.len;
            if (no_line.len > max_chars) max_chars = no_line.len;
            const content_w: f32 = @as(f32, @floatFromInt(max_chars)) * scaled_gw;
            // title + blank + Y + N = 4 rows
            const content_h: f32 = 4 * row_h;
            const panel_w: f32 = content_w + 2 * panel_pad;
            const panel_h: f32 = content_h + 2 * panel_pad;
            const panel_x: f32 = (surface_w - panel_w) / 2;
            const panel_y: f32 = (surface_h - panel_h) / 2;

            try enc.fillRect(panel_x, panel_y, panel_w, panel_h, 0, 0, 0, 1);
            try drawBorder(enc, panel_x, panel_y, panel_w, panel_h, AMBER_R, AMBER_G, AMBER_B, AMBER_A);

            const text_x: f32 = panel_x + panel_pad;
            var y: f32 = panel_y + panel_pad;
            try drawText(enc, title, text_x, y, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
            y += row_h * 2;
            try drawText(enc, yes_line, text_x, y, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
            y += row_h;
            try drawText(enc, no_line, text_x, y, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
        },
        .in_progress => {
            // Action has been invoked. Display a single-line status
            // banner appropriate to the action that was armed.
            const action = state.power_action orelse .shutdown;
            const banner: []const u8 = switch (action) {
                .shutdown => "Shutting down...",
                .restart => "Restarting...",
                .suspend_ => "Suspending...",
            };

            const content_w: f32 = @as(f32, @floatFromInt(banner.len)) * scaled_gw;
            const content_h: f32 = row_h;
            const panel_w: f32 = content_w + 2 * panel_pad;
            const panel_h: f32 = content_h + 2 * panel_pad;
            const panel_x: f32 = (surface_w - panel_w) / 2;
            const panel_y: f32 = (surface_h - panel_h) / 2;

            try enc.fillRect(panel_x, panel_y, panel_w, panel_h, 0, 0, 0, 1);
            try drawBorder(enc, panel_x, panel_y, panel_w, panel_h, AMBER_R, AMBER_G, AMBER_B, AMBER_A);

            const text_x: f32 = panel_x + panel_pad;
            const y: f32 = panel_y + panel_pad;
            try drawText(enc, banner, text_x, y, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
        },
    }
}

fn drawField(
    state: *const State,
    enc: *Encoder,
    blink_phase: u64,
    which: FieldState,
    label: []const u8,
    contents: []const u8,
    mask: bool,
    y_top: f32,
    surface_w: f32,
) !void {
    const sf: f32 = @floatFromInt(SCALE);
    const scaled_gw: f32 = @as(f32, @floatFromInt(font.Font.GLYPH_WIDTH)) * sf;
    const scaled_gh: f32 = @as(f32, @floatFromInt(font.Font.GLYPH_HEIGHT)) * sf;
    const inner_pad: f32 = FIELD_INNER_PAD_U * sf;
    const label_gap: f32 = 12.0 * sf;
    const field_height: f32 = scaled_gh + 12.0 * sf;
    const text_y_offset: f32 = 6.0 * sf;

    const label_w: f32 = @as(f32, @floatFromInt(label.len)) * scaled_gw;
    const field_w: f32 = @as(f32, @floatFromInt(FIELD_WIDTH_CHARS)) * scaled_gw + 2 * inner_pad;
    const total_w: f32 = label_w + label_gap + field_w;
    const x_label: f32 = (surface_w - total_w) / 2;
    const x_field: f32 = x_label + label_w + label_gap;

    // Label: amber for the active field, dim for the inactive one.
    const is_active = (which == state.field);
    if (is_active) {
        try drawText(enc, label, x_label, y_top + text_y_offset, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
    } else {
        try drawText(enc, label, x_label, y_top + text_y_offset, DIM_R, DIM_G, DIM_B, DIM_A);
    }

    // Field border (always amber if the field is shown).
    try drawBorder(enc, x_field, y_top, field_w, field_height, AMBER_R, AMBER_G, AMBER_B, AMBER_A);

    // Field contents: either the literal text or a row of asterisks
    // (one per byte). Asterisks are simpler than a block glyph and
    // require no special font handling; they're a safe ASCII choice.
    if (mask) {
        var buf: [PASSWORD_MAX]u8 = undefined;
        const n = @min(contents.len, buf.len);
        @memset(buf[0..n], '*');
        try drawText(
            enc,
            buf[0..n],
            x_field + inner_pad,
            y_top + text_y_offset,
            AMBER_R,
            AMBER_G,
            AMBER_B,
            AMBER_A,
        );
    } else {
        try drawText(
            enc,
            contents,
            x_field + inner_pad,
            y_top + text_y_offset,
            AMBER_R,
            AMBER_G,
            AMBER_B,
            AMBER_A,
        );
    }

    // Cursor (only on the active field). Width and height both
    // scale with SCALE so the cursor looks proportionate to text.
    if (is_active) {
        const show_cursor = !state.typing_started or blink_phase == 0;
        if (show_cursor) {
            const cx: f32 = x_field + inner_pad +
                @as(f32, @floatFromInt(contents.len)) * scaled_gw;
            const cy: f32 = y_top + text_y_offset;
            const cursor_w: f32 = 2.0 * sf;
            try enc.fillRect(cx, cy, cursor_w, scaled_gh, AMBER_R, AMBER_G, AMBER_B, AMBER_A);
        }
    }
}

// =============================================================================
// Event handling
// =============================================================================
//
// Called by main.runUiOnly's event loop for every translated event.
// Returns true to continue, false to exit. main translates raw
// client.Event into the AppEvent shape (which we kept from the
// App-framework draft) so this function does not need to know
// about the low-level protocol.

pub fn handleEvent(state: *State, event: AppEvent) !bool {
    switch (event) {
        .quit => return false,
        .key => |k| {
            // Both press and release events arrive; only react to
            // press. semadraw's KeyEvent.pressed is bool.
            if (!k.pressed) return true;
            const action = keymap.translate(k.key_code, k.modifiers);
            try state.handleAction(action);
            if (state.exit_reason != null) return false;
        },
        else => {},
    }
    return true;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// State-machine tests do NOT touch sysinfo (which would read
// /proc, sysctl, getifaddrs at test time and depend on the runtime
// environment). Build a State manually with stub strings.

fn makeTestState(allocator: std.mem.Allocator) !State {
    return State{
        .allocator = allocator,
        .field = .identify,
        .username = .empty,
        .password = .empty,
        .typing_started = false,
        .hostname = try allocator.dupe(u8, "testhost"),
        .network_str = try allocator.dupe(u8, "lo0 127.0.0.1"),
        .realmem_str = try allocator.dupe(u8, "1024 MB"),
        .physmem_str = try allocator.dupe(u8, "1000 MB"),
        // Test stub: set far enough in the future that
        // maybeRefreshNetwork() will not fire if a test ever
        // invokes the draw path. State-machine tests do not call
        // maybeRefreshNetwork directly, but the field is part of
        // the struct contract and must be initialised.
        .network_last_refresh_ms = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms))) + NETWORK_REFRESH_INTERVAL_MS,
        .status_message = null,
        .selected_session = .terminal,
        .picker_cursor = .terminal,
        .pre_power_field = .identify,
        .power_menu_phase = .choosing,
        .power_menu_cursor = .shutdown,
        .power_action = null,
        .exit_reason = null,
    };
}

test "handleAction prints characters into the username buffer" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.{ .print = 'i' });
    try s.handleAction(.{ .print = 'c' });
    try testing.expectEqualStrings("vic", s.username.items);
    try testing.expect(s.password.items.len == 0);
}

test "Enter on non-empty username transitions to password state" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.{ .print = 'i' });
    try s.handleAction(.{ .print = 'c' });
    try s.handleAction(.enter);
    try testing.expectEqual(FieldState.password, s.field);
    try testing.expect(s.exit_reason == null);
}

test "Enter on empty username is ignored" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.enter);
    try testing.expectEqual(FieldState.identify, s.field);
    try testing.expect(s.exit_reason == null);
}

test "Enter on password state transitions to submitting (Stage 6)" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter); // identify -> password
    try s.handleAction(.{ .print = 'p' });
    try s.handleAction(.{ .print = 'w' });
    try s.handleAction(.enter); // password -> submitting
    try testing.expectEqual(FieldState.submitting, s.field);
    try testing.expect(s.exit_reason == null);
    try testing.expectEqualStrings("v", s.username.items);
    try testing.expectEqualStrings("pw", s.password.items);
}

test "submitting state ignores all input including Ctrl-Q (Stage 8 lock)" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter);
    try s.handleAction(.{ .print = 'p' });
    try s.handleAction(.enter); // -> submitting
    try testing.expectEqual(FieldState.submitting, s.field);

    // Print, backspace, enter, clear, Ctrl-Q: all no-ops.
    // Stage 8 changed the .submitting lock to be complete (no
    // emergency escape via Ctrl-Q) since the auth call is
    // synchronous and brief; the user can wait.
    try s.handleAction(.{ .print = 'x' });
    try s.handleAction(.backspace);
    try s.handleAction(.enter);
    try s.handleAction(.clear);
    try s.handleAction(.power_menu);
    try testing.expectEqual(FieldState.submitting, s.field);
    try testing.expectEqualStrings("v", s.username.items);
    try testing.expectEqualStrings("p", s.password.items);
    try testing.expect(s.exit_reason == null);
}

test "resetForRetry returns to password state, clears password, sets status" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter);
    try s.handleAction(.{ .print = 'b' });
    try s.handleAction(.{ .print = 'a' });
    try s.handleAction(.{ .print = 'd' });
    try s.handleAction(.enter); // -> submitting

    s.resetForRetry("authentication failed");

    try testing.expectEqual(FieldState.password, s.field);
    try testing.expectEqualStrings("v", s.username.items); // preserved
    try testing.expectEqual(@as(usize, 0), s.password.items.len);
    try testing.expect(s.status_message != null);
    try testing.expectEqualStrings("authentication failed", s.status_message.?);
}

test "status_message is cleared on next print" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    s.status_message = "some prior failure";
    try s.handleAction(.{ .print = 'x' });
    try testing.expect(s.status_message == null);
}

test "status_message is cleared on backspace (when something is deleted)" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'x' });
    s.status_message = "stale failure";
    try s.handleAction(.backspace);
    try testing.expect(s.status_message == null);
}

test "status_message is cleared on ESC" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    s.status_message = "stale failure";
    try s.handleAction(.clear);
    try testing.expect(s.status_message == null);
}

test "Backspace removes last character" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.{ .print = 'i' });
    try s.handleAction(.{ .print = 'c' });
    try s.handleAction(.backspace);
    try testing.expectEqualStrings("vi", s.username.items);
}

test "Backspace on empty field is a no-op" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.backspace);
    try testing.expectEqual(@as(usize, 0), s.username.items.len);
}

test "ESC clears the active field but does not change state" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.{ .print = 'i' });
    try s.handleAction(.{ .print = 'c' });
    try s.handleAction(.clear);
    try testing.expectEqual(@as(usize, 0), s.username.items.len);
    try testing.expectEqual(FieldState.identify, s.field);
}

test "ESC in password state clears password, not username, stays in password" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.{ .print = 'i' });
    try s.handleAction(.{ .print = 'c' });
    try s.handleAction(.enter); // -> password state
    try s.handleAction(.{ .print = 'p' });
    try s.handleAction(.{ .print = 'w' });
    try s.handleAction(.clear);
    try testing.expectEqualStrings("vic", s.username.items);
    try testing.expectEqual(@as(usize, 0), s.password.items.len);
    try testing.expectEqual(FieldState.password, s.field);
}

test "Ctrl-Q from identify opens the power menu (Stage 8)" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);
    try testing.expectEqual(FieldState.power_menu, s.field);
    try testing.expectEqual(PowerMenuPhase.choosing, s.power_menu_phase);
    try testing.expectEqual(PowerOption.shutdown, s.power_menu_cursor);
    try testing.expectEqual(FieldState.identify, s.pre_power_field);
    try testing.expect(s.exit_reason == null);
}

test "Username buffer caps at USERNAME_MAX" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    var i: usize = 0;
    while (i < USERNAME_MAX + 10) : (i += 1) {
        try s.handleAction(.{ .print = 'x' });
    }
    try testing.expectEqual(USERNAME_MAX, s.username.items.len);
}

// =============================================================================
// Stage 7: SessionType helpers
// =============================================================================

test "SessionType.displayName returns expected labels" {
    try testing.expectEqualStrings("Terminal", SessionType.terminal.displayName());
    try testing.expectEqualStrings("X11", SessionType.x11.displayName());
    try testing.expectEqualStrings("Wayland", SessionType.wayland.displayName());
    try testing.expectEqualStrings("NDE", SessionType.nde.displayName());
}

test "SessionType.sessionId returns expected file ids" {
    try testing.expectEqualStrings("default", SessionType.terminal.sessionId());
    try testing.expectEqualStrings("x11", SessionType.x11.sessionId());
    try testing.expectEqualStrings("wayland", SessionType.wayland.sessionId());
    try testing.expectEqualStrings("nde", SessionType.nde.sessionId());
}

test "SessionType.enabled: only terminal is enabled in v1" {
    try testing.expect(SessionType.terminal.enabled());
    try testing.expect(!SessionType.x11.enabled());
    try testing.expect(!SessionType.wayland.enabled());
    try testing.expect(!SessionType.nde.enabled());
}

test "SessionType.nextEnabled/prevEnabled with only one enabled entry stays put" {
    // v1: only .terminal is enabled. Up/down should be no-ops.
    try testing.expectEqual(SessionType.terminal, SessionType.terminal.nextEnabled());
    try testing.expectEqual(SessionType.terminal, SessionType.terminal.prevEnabled());
}

// =============================================================================
// Stage 7: picker state machine
// =============================================================================

test "Tab from identify is a no-op" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.tab);
    try testing.expectEqual(FieldState.identify, s.field);
}

test "Tab from password opens picker overlay" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter); // identify -> password
    try testing.expectEqual(FieldState.password, s.field);

    try s.handleAction(.tab); // password -> picker
    try testing.expectEqual(FieldState.picker, s.field);
    // Cursor starts on the current selection.
    try testing.expectEqual(SessionType.terminal, s.picker_cursor);
    // selected_session unchanged until confirm.
    try testing.expectEqual(SessionType.terminal, s.selected_session);
}

test "Ctrl-S from password opens picker overlay" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter); // identify -> password
    try testing.expectEqual(FieldState.password, s.field);

    try s.handleAction(.session_picker); // password -> picker
    try testing.expectEqual(FieldState.picker, s.field);
    // Same behavior as the Tab route: cursor starts on the current
    // selection, and selected_session is unchanged until confirm.
    try testing.expectEqual(SessionType.terminal, s.picker_cursor);
    try testing.expectEqual(SessionType.terminal, s.selected_session);
}

test "Ctrl-S from identify is a no-op" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try testing.expectEqual(FieldState.identify, s.field);

    try s.handleAction(.session_picker);
    // Same guard as Tab: no picker before the user has identified.
    try testing.expectEqual(FieldState.identify, s.field);
}

test "Picker: Enter confirms cursor selection, returns to password" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter);
    try s.handleAction(.tab); // -> picker

    try s.handleAction(.enter); // confirm
    try testing.expectEqual(FieldState.password, s.field);
    try testing.expectEqual(SessionType.terminal, s.selected_session);
}

test "Picker: Tab also confirms (acts like Enter)" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter);
    try s.handleAction(.tab); // -> picker

    try s.handleAction(.tab); // confirm
    try testing.expectEqual(FieldState.password, s.field);
    try testing.expectEqual(SessionType.terminal, s.selected_session);
}

test "Picker: ESC cancels without changing selection" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    s.selected_session = .terminal;
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter);
    try s.handleAction(.tab); // -> picker

    // Pretend the cursor moved (in v1 it can't, but force the
    // state to verify ESC doesn't commit picker_cursor).
    s.picker_cursor = .x11;

    try s.handleAction(.clear); // ESC
    try testing.expectEqual(FieldState.password, s.field);
    // selected_session must NOT have been overwritten with picker_cursor.
    try testing.expectEqual(SessionType.terminal, s.selected_session);
}

test "Picker: Up/Down skip disabled entries (v1: cursor stays on terminal)" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter);
    try s.handleAction(.tab); // -> picker

    try s.handleAction(.down);
    try testing.expectEqual(SessionType.terminal, s.picker_cursor);

    try s.handleAction(.up);
    try testing.expectEqual(SessionType.terminal, s.picker_cursor);
}

test "Picker: print/backspace are ignored" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter);
    try s.handleAction(.{ .print = 'p' });
    try s.handleAction(.tab); // -> picker

    try s.handleAction(.{ .print = 'x' });
    try s.handleAction(.backspace);

    // Username and password unchanged; still in picker.
    try testing.expectEqual(FieldState.picker, s.field);
    try testing.expectEqualStrings("v", s.username.items);
    try testing.expectEqualStrings("p", s.password.items);
}

test "Picker: Ctrl-Q closes picker and opens power menu (Stage 8)" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter);
    try s.handleAction(.tab); // -> picker

    try s.handleAction(.power_menu);
    try testing.expectEqual(FieldState.power_menu, s.field);
    // Pre_power_field is .password (not .picker) so ESC from the
    // menu returns to the password field. The picker is gone;
    // user can reopen with Tab if they still want it.
    try testing.expectEqual(FieldState.password, s.pre_power_field);
    try testing.expectEqual(PowerMenuPhase.choosing, s.power_menu_phase);
}

test "Picker: opening clears status_message" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter);
    s.status_message = "stale failure";
    try s.handleAction(.tab); // -> picker
    try testing.expect(s.status_message == null);
}

// =============================================================================
// Stage 8: PowerOption helpers
// =============================================================================

test "PowerOption.next/prev wrap forward and backward" {
    try testing.expectEqual(PowerOption.restart, PowerOption.shutdown.next());
    try testing.expectEqual(PowerOption.suspend_, PowerOption.restart.next());
    try testing.expectEqual(PowerOption.shutdown, PowerOption.suspend_.next());

    try testing.expectEqual(PowerOption.suspend_, PowerOption.shutdown.prev());
    try testing.expectEqual(PowerOption.shutdown, PowerOption.restart.prev());
    try testing.expectEqual(PowerOption.restart, PowerOption.suspend_.prev());
}

test "PowerOption.requiresConfirm: shutdown and restart yes, suspend no" {
    try testing.expect(PowerOption.shutdown.requiresConfirm());
    try testing.expect(PowerOption.restart.requiresConfirm());
    try testing.expect(!PowerOption.suspend_.requiresConfirm());
}

test "PowerOption display labels and accelerators" {
    try testing.expectEqualStrings("Shutdown", PowerOption.shutdown.displayName());
    try testing.expectEqualStrings("Restart", PowerOption.restart.displayName());
    try testing.expectEqualStrings("Suspend", PowerOption.suspend_.displayName());
    try testing.expectEqual(@as(u8, 'S'), PowerOption.shutdown.accelerator());
    try testing.expectEqual(@as(u8, 'R'), PowerOption.restart.accelerator());
    try testing.expectEqual(@as(u8, 'Z'), PowerOption.suspend_.accelerator());
}

// =============================================================================
// Stage 8: power-menu state machine
// =============================================================================

test "Ctrl-Q from password opens power menu rooted at password" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter); // -> password

    try s.handleAction(.power_menu);
    try testing.expectEqual(FieldState.power_menu, s.field);
    try testing.expectEqual(FieldState.password, s.pre_power_field);
    try testing.expectEqual(PowerMenuPhase.choosing, s.power_menu_phase);
}

test "Power menu: Up/Down cycle through options" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);

    try testing.expectEqual(PowerOption.shutdown, s.power_menu_cursor);
    try s.handleAction(.down);
    try testing.expectEqual(PowerOption.restart, s.power_menu_cursor);
    try s.handleAction(.down);
    try testing.expectEqual(PowerOption.suspend_, s.power_menu_cursor);
    try s.handleAction(.down);
    try testing.expectEqual(PowerOption.shutdown, s.power_menu_cursor); // wrap

    try s.handleAction(.up);
    try testing.expectEqual(PowerOption.suspend_, s.power_menu_cursor); // wrap back
}

test "Power menu: Enter on shutdown advances to confirm_shutdown" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);
    // cursor is on .shutdown by default
    try s.handleAction(.enter);
    try testing.expectEqual(PowerMenuPhase.confirming_shutdown, s.power_menu_phase);
    try testing.expect(s.power_action == null); // not armed yet
}

test "Power menu: 'S' accelerator advances to confirm_shutdown" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);
    try s.handleAction(.{ .print = 's' });
    try testing.expectEqual(PowerMenuPhase.confirming_shutdown, s.power_menu_phase);
}

test "Power menu: 'R' accelerator advances to confirm_restart" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);
    try s.handleAction(.{ .print = 'r' });
    try testing.expectEqual(PowerMenuPhase.confirming_restart, s.power_menu_phase);
}

test "Power menu: 'Z' (suspend) arms action immediately, no confirm" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);
    try s.handleAction(.{ .print = 'z' });
    // No confirm phase; action is armed directly.
    try testing.expectEqual(PowerMenuPhase.choosing, s.power_menu_phase);
    try testing.expect(s.power_action != null);
    try testing.expectEqual(PowerOption.suspend_, s.power_action.?);
}

test "Power menu: accelerators are case-insensitive" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);
    try s.handleAction(.{ .print = 'S' });
    try testing.expectEqual(PowerMenuPhase.confirming_shutdown, s.power_menu_phase);
}

test "Power menu confirm: Y arms the shutdown action" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);
    try s.handleAction(.{ .print = 's' });
    try testing.expectEqual(PowerMenuPhase.confirming_shutdown, s.power_menu_phase);

    try s.handleAction(.{ .print = 'y' });
    try testing.expect(s.power_action != null);
    try testing.expectEqual(PowerOption.shutdown, s.power_action.?);
}

test "Power menu confirm: Enter is equivalent to Y" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);
    try s.handleAction(.{ .print = 'r' });
    try s.handleAction(.enter);
    try testing.expect(s.power_action != null);
    try testing.expectEqual(PowerOption.restart, s.power_action.?);
}

test "Power menu confirm: N returns to choosing without arming" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);
    try s.handleAction(.{ .print = 's' });

    try s.handleAction(.{ .print = 'n' });
    try testing.expectEqual(PowerMenuPhase.choosing, s.power_menu_phase);
    try testing.expect(s.power_action == null);
}

test "Power menu confirm: ESC returns to choosing without arming" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);
    try s.handleAction(.{ .print = 's' });

    try s.handleAction(.clear);
    try testing.expectEqual(PowerMenuPhase.choosing, s.power_menu_phase);
    try testing.expect(s.power_action == null);
}

test "Power menu choosing: ESC returns to pre_power_field" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter); // -> password
    try s.handleAction(.power_menu);
    try testing.expectEqual(FieldState.power_menu, s.field);

    try s.handleAction(.clear);
    try testing.expectEqual(FieldState.password, s.field);
    try testing.expect(s.power_action == null);
}

test "Power menu choosing: Ctrl-Q closes menu (like ESC)" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);

    try s.handleAction(.power_menu);
    try testing.expectEqual(FieldState.identify, s.field);
    try testing.expect(s.power_action == null);
}

test "Power menu confirm: Ctrl-Q closes the entire menu (not back to choosing)" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);
    try s.handleAction(.{ .print = 's' });
    try testing.expectEqual(PowerMenuPhase.confirming_shutdown, s.power_menu_phase);

    try s.handleAction(.power_menu);
    try testing.expectEqual(FieldState.identify, s.field);
    try testing.expect(s.power_action == null);
}

test "Power menu: opening from picker roots at password" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter);
    try s.handleAction(.tab); // -> picker
    try testing.expectEqual(FieldState.picker, s.field);

    try s.handleAction(.power_menu);
    try testing.expectEqual(FieldState.power_menu, s.field);
    try testing.expectEqual(FieldState.password, s.pre_power_field);
}

test "Power menu: opening clears status_message" {
    var s = try makeTestState(testing.allocator);
    defer s.deinit();
    s.status_message = "previous failure";
    try s.handleAction(.power_menu);
    try testing.expect(s.status_message == null);
}
