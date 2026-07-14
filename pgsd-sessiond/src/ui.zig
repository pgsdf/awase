// pgsd-sessiond/src/ui.zig
//
// Graphical login UI. Draws a centered login panel on black with
// bright amber text, captures username and password, optionally
// overrides the session type via a Tab-invoked picker, exposes
// power management via a Ctrl-Q-invoked menu, and orchestrates
// the auth lifecycle in cooperation with main.runUiOnly.
//
// Navigation model (ADR 0011, ratified; the modal layout was retired
// 2026-07-12 and its overlay machinery deleted with it):
//
//   Two axes. VIEW is where you are; FOCUS is what has the keyboard.
//
//     view:  { login, session, power }   peers, not overlays
//     focus: { rail, content }
//
//   RAIL focus
//     | Up/Down move rail_cursor between views
//     | Enter opens the selected view (focus -> content)
//     | ESC returns focus to the current view's content
//
//   CONTENT focus, view = LOGIN
//     | keystrokes fill username, then password
//     | Enter: identify -> password -> submitting
//     | ESC clears the current field (predates this ADR)
//     | Up reaches the rail (ESC is taken)
//
//   CONTENT focus, view = SESSION
//     | Up/Down move picker_cursor among ENABLED session types
//     | Enter confirms into selected_session, returns to the rail
//     | ESC returns to the rail, selection unchanged
//
//   CONTENT focus, view = POWER
//     | Up/Down choose; Enter or S/R/Z selects
//     | Shutdown and Restart advance to a CONFIRM phase; Suspend arms
//     |   directly. Destructive actions are always gated.
//     | ESC returns to the rail
//
//   Global: Ctrl-Q -> Power view, Ctrl-S -> Session view, from anywhere.
//
//   SUBMITTING is the one modal state that survives, deliberately: PAM
//   is in flight and neither the fields nor the rail may be mutated
//   under it.
//
// What this model does NOT have, and the previous one needed:
// pre_power_field, the bookmark an overlay kept so it could restore
// what it covered. A peer view covers nothing, so there is nothing to
// restore. That deletion was ADR 0011's own test of the model, and
// retiring the modal layout removed the field from the codebase.

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

/// Memory telemetry cadence.
///
/// Slower than the network's because memory pressure is not something an
/// operator watches for a state CHANGE (up/down); they read a level. A
/// second is wasted work and a jittery bar. Two seconds is responsive
/// enough to see a machine start swapping and cheap enough to ignore.
pub const MEMORY_REFRESH_INTERVAL_MS: i64 = 2000;

/// Cells in the memory bar. Each cell is one discrete unit of the total,
/// so the resolution is 100/MEMORY_BAR_CELLS percent per cell.
pub const MEMORY_BAR_CELLS: usize = 16;

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

/// ADR 0011: the navigation axes.
///
/// The console model separates WHERE YOU ARE (view) from WHAT HAS THE
/// KEYBOARD (focus). Views are PEERS: Session and Power sit beside
/// Login rather than shadowing it. That is what lets the modal-unwind
/// bookkeeping go away, because a peer view has nothing to remember:
/// navigating away and back is not an interruption.
///
/// Deliberately NOT a view: Keyboard. Keyboard layout is a substrate
/// capability that does not exist yet (audit SA-5: two clients already
/// hardcode US layouts independently, and nothing below them owns
/// layout). A Keyboard view here would imply this UI owns a capability
/// the substrate does not provide, which would be a lie told by the
/// interface. It is not stubbed either, for the same reason. It arrives
/// when the substrate can actually apply a layout.
pub const View = enum {
    login,
    session,
    power,

    pub fn label(self: View) []const u8 {
        return switch (self) {
            .login => "Login",
            .session => "Session",
            .power => "Power",
        };
    }

    pub fn next(self: View) View {
        return switch (self) {
            .login => .session,
            .session => .power,
            .power => .login,
        };
    }

    pub fn prev(self: View) View {
        return switch (self) {
            .login => .power,
            .session => .login,
            .power => .session,
        };
    }
};

/// Which surface has the keyboard.
pub const Focus = enum {
    /// The navigation rail. Up/Down move between views; Enter or Right
    /// enters the selected view's content.
    rail,
    /// The active view's content. ESC or Left returns to the rail.
    content,
};

pub const FieldState = enum {
    identify,
    password,
    /// Stage 7: session-picker overlay open. Up/Down move the
    /// cursor among ENABLED picker entries (disabled entries are
    /// skipped). Tab or Enter confirm and return to .password.
    /// ESC cancels (returns to .password without changing
    /// state.selected_session). Other input is ignored.
    ///
    /// ADR 0011: retained only so the centered layout keeps working
    /// unchanged. In the console layout this is not a field state at
    /// all; Session is a peer VIEW.
    picker,
    /// Stage 8: power-menu overlay open.
    ///
    /// ADR 0011: as with .picker, retained for the centered layout.
    /// In the console layout Power is a peer VIEW, and the
    /// pre_power_field bookmark that this state required does not
    /// exist there.
    power_menu,
    /// Stage 6: password has been submitted; main is performing
    /// PAM auth. UI renders an "Authenticating..." indicator and
    /// ignores all input (including Ctrl-Q) for the brief window
    /// auth takes. After auth resolves, main either calls launch()
    /// (success path, the surface will be torn down) or resets to
    /// .password with status_message set (failure path).
    ///
    /// This one stays modal in BOTH layouts, deliberately (ADR 0011
    /// section 3): PAM is in flight and neither the fields nor the
    /// rail may be mutated under it.
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

    /// Live memory telemetry, raw. Rendering is ui.zig's job; State holds
    /// the numbers.
    ///
    /// Distinct from realmem_str/physmem_str above, which are INSTALLED
    /// memory: a system fact, constant, captured once. This is pressure,
    /// which changes continuously and is resampled on
    /// MEMORY_REFRESH_INTERVAL_MS. The login screen previously had only
    /// the former, so it reported how much RAM the machine has and never
    /// how much of it was in use.
    ///
    /// null until the first successful sample, and on sampling failure it
    /// KEEPS the last good value rather than reverting to null: a stale
    /// bar is more useful than a bar that flickers away, and matches the
    /// network indicator's fail-soft posture.
    mem: ?sysinfo.MemStats = null,
    memory_last_refresh_ms: i64 = 0,

    /// Log a telemetry failure once, not on every 2-second tick.
    mem_error_logged: bool = false,

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

    /// ADR 0011: the console navigation axes.
    ///
    /// These are live only in the console layout. The centered layout
    /// ignores them entirely and continues to drive everything from
    /// `field`, so both layouts coexist without either constraining
    /// the other.
    ///
    /// `view` is WHERE YOU ARE: Login, Session, and Power are peers,
    /// not overlays. `focus` is WHAT HAS THE KEYBOARD: the rail, or
    /// the active view's content.
    ///
    /// The point of the model is what it lets us NOT have. In the
    /// console layout there is no pre_power_field, because Power is a
    /// place you navigate to and leave, not an overlay that must
    /// remember what it covered. See handleActionConsole.
    view: View = .login,
    focus: Focus = .content,
    rail_cursor: View = .login,
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
    /// How the three segments divide the bar.
    ///
    /// The segments MUST sum to exactly MEMORY_BAR_CELLS. Rounding each
    /// independently does not guarantee that (three roundings can sum to
    /// cells+1 or cells-1), and a bar that is one cell short shows a gap
    /// while one cell over writes past its own width. So: round the first
    /// two, and give the remainder to free. Free is the right segment to
    /// absorb the error because it is the least interesting of the three
    /// and the one an operator is least likely to read precisely.
    const BarCells = struct {
        used: usize,
        cache: usize,
        free: usize,
    };

    fn barCells(m: sysinfo.MemStats) BarCells {
        if (m.total_bytes == 0) {
            return .{ .used = 0, .cache = 0, .free = MEMORY_BAR_CELLS };
        }
        const cells: u64 = MEMORY_BAR_CELLS;

        // Round to nearest rather than truncating, so a segment holding
        // most of a cell is shown rather than vanishing.
        const used = (m.used_bytes * cells + m.total_bytes / 2) / m.total_bytes;
        const cache = (m.cache_bytes * cells + m.total_bytes / 2) / m.total_bytes;

        var u: usize = @intCast(@min(used, cells));
        var c: usize = @intCast(@min(cache, cells - u));

        // A nonzero segment never rounds away to nothing: a machine using
        // a little memory should light one cell, not none. The bar is a
        // pressure indicator, and "some" must be visually distinct from
        // "none".
        if (u == 0 and m.used_bytes > 0 and cells > 0) u = 1;
        if (c == 0 and m.cache_bytes > 0 and u < cells) c = 1;

        const f: usize = MEMORY_BAR_CELLS - @min(u + c, MEMORY_BAR_CELLS);
        return .{ .used = u, .cache = @min(c, MEMORY_BAR_CELLS - u), .free = f };
    }

    /// Resample memory pressure if the interval has elapsed. Returns true
    /// if the values changed enough to warrant a redraw.
    ///
    /// Fail-soft, like the network refresh: a failed sysctl keeps the last
    /// good sample rather than clearing the bar. A login screen that
    /// flickers its telemetry away on a transient failure is worse than
    /// one showing a two-second-old number.
    pub fn maybeRefreshMemory(self: *State) bool {
        const now = @as(i64, @intCast(@divTrunc(compat.time.nowMonotonic(), std.time.ns_per_ms)));
        if (now - self.memory_last_refresh_ms < MEMORY_REFRESH_INTERVAL_MS) {
            return false;
        }
        self.memory_last_refresh_ms = now;

        const fresh = sysinfo.memStats() catch |e| {
            // Say WHICH failure, once, rather than silently showing
            // "mem --" forever.
            //
            // The first version failed on every call (hw.pagesize read at
            // the wrong width) and the only symptom was a dash on the login
            // screen. That is a diagnostic-free failure, and this project
            // has paid for enough of those: the bar could not tell anyone
            // why it was empty, so the answer had to be found by reading
            // source. Log it once and the next one costs a glance.
            if (!self.mem_error_logged) {
                self.mem_error_logged = true;
                std.log.warn("memory telemetry unavailable: {s}", .{@errorName(e)});
            }
            return false;
        };

        // Redraw only when something the operator can SEE would change.
        //
        // Memory moves constantly and redrawing for a change nobody can
        // perceive is work the login screen does not need to do. But the
        // gate must be the FINER of the two things drawn, not the coarser:
        // the label has 0.1G resolution and a cell is roughly 1G, so gating
        // on cells alone would leave the label stale for up to a gigabyte
        // of change. Gate on the label's granularity, which subsumes the
        // bar's.
        if (self.mem) |old| {
            const a = barCells(old);
            const b = barCells(fresh);
            const cells_same = a.used == b.used and a.cache == b.cache and a.free == b.free;

            // The label prints used to one decimal of a GiB. Quantise to
            // that, so "would the drawn text differ" is answered exactly
            // rather than approximated.
            const tenth_gib: u64 = (1 << 30) / 10;
            const label_same = (old.used_bytes / tenth_gib) == (fresh.used_bytes / tenth_gib);

            if (cells_same and label_same) {
                self.mem = fresh;
                return false;
            }
        }
        self.mem = fresh;
        return true;
    }

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
    /// ADR 0011: action handling for the console layout.
    ///
    /// Peer views, two axes. Compare against handleAction below, which
    /// is the modal version and stays for the centered layout.
    ///
    /// What is NOT here is the point of the ADR:
    ///
    ///   - No pre_power_field. Power is a view you navigate to and
    ///     leave. There is nothing to bookmark, because entering it
    ///     did not cover anything.
    ///   - No "Ctrl-Q from inside the picker closes the picker first"
    ///     special case. Ctrl-Q just sets view = .power. Session was
    ///     not shadowing anything, so nothing needs unwinding.
    ///
    /// Those two deletions are the ADR's own test of whether the model
    /// is more natural than the one it replaces. If they had to be
    /// reintroduced here, the model would have failed.
    pub fn handleAction(self: *State, action: keymap.Action) !void {
        // Modal, deliberately (ADR 0011 section 3): PAM is in flight.
        // Neither the fields nor the rail may be mutated under it.
        if (self.field == .submitting) return;

        // Global accelerator, from anywhere. It is muscle memory and it
        // works today. Note how little it has to do now.
        if (action == .power_menu) {
            self.view = .power;
            self.rail_cursor = .power;
            self.focus = .content;
            self.power_menu_phase = .choosing;
            self.power_menu_cursor = .shutdown;
            return;
        }

        // Ctrl-S remains a shortcut straight to the Session view, for
        // the same reason: it already exists and users know it.
        if (action == .session_picker) {
            self.view = .session;
            self.rail_cursor = .session;
            self.focus = .content;
            self.picker_cursor = self.selected_session;
            return;
        }

        switch (self.focus) {
            .rail => try self.handleRailAction(action),
            .content => try self.handleContentAction(action),
        }
    }

    /// Rail focus: choose a view.
    fn handleRailAction(self: *State, action: keymap.Action) !void {
        switch (action) {
            .up => self.rail_cursor = self.rail_cursor.prev(),
            .down => self.rail_cursor = self.rail_cursor.next(),
            .enter => {
                self.view = self.rail_cursor;
                self.focus = .content;
                // Entering a view initialises its cursor. Nothing is
                // remembered ACROSS views, which is the simplification:
                // a view is entered fresh, not restored.
                switch (self.view) {
                    .session => self.picker_cursor = self.selected_session,
                    .power => {
                        self.power_menu_phase = .choosing;
                        self.power_menu_cursor = .shutdown;
                    },
                    .login => {},
                }
            },
            // ESC from the rail returns focus to the current view's
            // content rather than doing nothing, so the rail is never a
            // dead end.
            .clear => self.focus = .content,
            else => {},
        }
    }

    /// Content focus: act within the active view.
    fn handleContentAction(self: *State, action: keymap.Action) !void {
        // ESC leaves the content and returns to the rail, from every
        // view. This is the ONLY back-navigation rule, and it is the
        // same everywhere, which is what a peer-view model buys.
        //
        // Exception: in the login view, ESC has an established meaning
        // (clear the current field) that predates this ADR and that
        // users rely on. Login therefore keeps it, and the rail is
        // reached from login with Left.
        if (action == .clear and self.view != .login) {
            self.focus = .rail;
            self.rail_cursor = self.view;
            return;
        }

        switch (self.view) {
            .login => try self.handleLoginContent(action),
            .session => try self.handleSessionContent(action),
            .power => self.handlePowerContent(action),
        }
    }

    /// The Session view: what the picker overlay used to be.
    fn handleSessionContent(self: *State, action: keymap.Action) !void {
        switch (action) {
            .up => self.picker_cursor = self.picker_cursor.prevEnabled(),
            .down => self.picker_cursor = self.picker_cursor.nextEnabled(),
            .tab, .enter => {
                // Confirm, and return to the rail. Not to "wherever we
                // came from": there is no such place, because we did
                // not cover anything to get here.
                self.selected_session = self.picker_cursor;
                self.status_message = null;
                self.focus = .rail;
                self.rail_cursor = .session;
            },
            else => {},
        }
    }

    /// The Login view's content: the fields. This is the old
    /// identify/password/submitting logic, unchanged in meaning.
    fn handleLoginContent(self: *State, action: keymap.Action) !void {
        switch (action) {
            .none => {},
            .print => |ch| {
                self.typing_started = true;
                // Clear a stale status message once the user starts
                // typing: a previous failure is no longer relevant
                // context the moment they begin a fresh attempt. This
                // behaviour predates ADR 0011 and was carried over from
                // the retired modal handler, where it was easy to lose.
                self.status_message = null;
                switch (self.field) {
                    .identify => {
                        if (self.username.items.len < USERNAME_MAX) {
                            try self.username.append(self.allocator, ch);
                        }
                    },
                    .password => {
                        if (self.password.items.len < PASSWORD_MAX) {
                            try self.password.append(self.allocator, ch);
                        }
                    },
                    else => {},
                }
            },
            .backspace => {
                self.typing_started = true;
                switch (self.field) {
                    .identify => {
                        if (self.username.pop() != null) self.status_message = null;
                    },
                    .password => {
                        if (self.password.pop() != null) self.status_message = null;
                    },
                    else => {},
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
                    .password => self.field = .submitting,
                    else => {},
                }
            },
            .clear => {
                // Login keeps ESC-clears-field, which predates ADR 0011.
                switch (self.field) {
                    .identify => self.username.clearRetainingCapacity(),
                    .password => self.password.clearRetainingCapacity(),
                    else => {},
                }
                self.status_message = null;
            },
            // Left is how login reaches the rail, since ESC is taken.
            .up => {
                self.focus = .rail;
                self.rail_cursor = .login;
            },
            else => {},
        }
    }

    /// The Power view. Same choosing/confirming logic as the modal
    /// menu, and the same confirm gate on destructive actions (ADR 0011
    /// section 3: easier navigation to the action makes confirmation
    /// MORE necessary, not less).
    ///
    /// The difference, and the whole point: exiting goes to the RAIL.
    /// There is no pre_power_field, because Power did not cover
    /// anything to get here. Compare handlePowerMenuChoosing, which
    /// does `self.field = self.pre_power_field` precisely because it
    /// did.
    fn handlePowerContent(self: *State, action: keymap.Action) void {
        switch (self.power_menu_phase) {
            .choosing => switch (action) {
                .up => self.power_menu_cursor = self.power_menu_cursor.prev(),
                .down => self.power_menu_cursor = self.power_menu_cursor.next(),
                .enter => self.commitPowerMenuChoice(self.power_menu_cursor),
                .print => |ch| switch (std.ascii.toLower(ch)) {
                    's' => self.commitPowerMenuChoice(.shutdown),
                    'r' => self.commitPowerMenuChoice(.restart),
                    'z' => self.commitPowerMenuChoice(.suspend_),
                    else => {},
                },
                .clear => {
                    self.focus = .rail;
                    self.rail_cursor = .power;
                },
                else => {},
            },
            .confirming_shutdown => self.confirmPowerConsole(action, .shutdown),
            .confirming_restart => self.confirmPowerConsole(action, .restart),
            .in_progress => {},
        }
    }

    /// Confirm phase in the console layout. Y or Enter arms; N or ESC
    /// backs out to .choosing, exactly as the modal version does.
    /// Destructive actions are still gated.
    fn confirmPowerConsole(self: *State, action: keymap.Action, option: PowerOption) void {
        switch (action) {
            .enter => self.power_action = option,
            .print => |ch| switch (std.ascii.toLower(ch)) {
                'y' => self.power_action = option,
                'n' => self.power_menu_phase = .choosing,
                else => {},
            },
            .clear => self.power_menu_phase = .choosing,
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
// -----------------------------------------------------------------
// Console palette (PGSD_SESSIOND_LAYOUT=console)
//
// Background is a deep navy, #12375c: hue 210deg, lightness 22%,
// saturation 67%. Primary text is white. Every other colour is derived
// against the background, and every text tier is contrast-checked
// rather than picked by eye, because the previous iteration taught
// that the dim tiers are where a palette quietly breaks: they look
// fine to the author and are unreadable on the bench.
//
// The role of colour changes here, and that is the point of the
// white-text direction. Previously amber was the text. Now white is
// the text and amber is the ACCENT: it marks focus (the active field's
// label, the cursor, the selected rail item) rather than carrying the
// content. That is a more conventional console reading and it lets the
// eye find the focused thing instantly instead of scanning a field of
// uniformly amber text.
//
// Amber remains the right accent hue by construction: #12375c's
// complement sits at about 30deg, which is amber/orange. The
// background chose the accent.
//
// A cool blue (CONTEXT) carries the header, keeping the established
// semantic that the sysinfo block is read-once reference rather than
// something you act on. It is close enough in hue to the background to
// recede, and far enough in lightness to remain legible.
//
// Contrast against #12375c (WCAG: 4.5 body, 3.0 large/UI):
//   TEXT       #eaf2fb  10.77  primary text: field values
//   TEXT_DIM   #9fb4cc   5.72  inactive labels, unselected rail items
//   AMBER      #ffb454   6.90  accent: focus (active label, cursor)
//   AMBER_DIM  #c98f45   4.34  accent, inactive
//   CONTEXT    #7fc7e8   6.51  header: hostname
//   CONTEXT_D  #5f8fb0   3.50  header: network, memory
//   RULE       #2f5c8a   1.75  separators; deliberately low, a rule is
//                              structure and not text
//
// TEXT and AMBER sit close in luminance (1.56:1) on purpose: they are
// told apart by hue, not brightness, so the accent marks focus without
// shouting over the content.
const C_BG_R: f32 = 0.071; // #12375c
const C_BG_G: f32 = 0.216;
const C_BG_B: f32 = 0.361;

const C_TEXT_R: f32 = 0.918; // #eaf2fb  primary text
const C_TEXT_G: f32 = 0.949;
const C_TEXT_B: f32 = 0.984;

const C_TEXT_DIM_R: f32 = 0.624; // #9fb4cc  secondary text
const C_TEXT_DIM_G: f32 = 0.706;
const C_TEXT_DIM_B: f32 = 0.800;

const C_AMBER_R: f32 = 1.0; // #ffb454  accent: focus
const C_AMBER_G: f32 = 0.706;
const C_AMBER_B: f32 = 0.329;

const C_AMBER_DIM_R: f32 = 0.788; // #c98f45
const C_AMBER_DIM_G: f32 = 0.561;
const C_AMBER_DIM_B: f32 = 0.271;

const C_MINT_R: f32 = 0.498; // #7fc7e8  header context, bright
const C_MINT_G: f32 = 0.780;
const C_MINT_B: f32 = 0.910;

const C_MINT_DIM_R: f32 = 0.373; // #5f8fb0  header context, dim
const C_MINT_DIM_G: f32 = 0.561;
const C_MINT_DIM_B: f32 = 0.690;

const C_RULE_R: f32 = 0.184; // #2f5c8a
const C_RULE_G: f32 = 0.361;
const C_RULE_B: f32 = 0.541;

// =============================================================================
// Console layout (prototype)
// =============================================================================
//
// An alternative to the centered login card: a two-pane operating-system
// console. Borrowed from workstation-console INTERACTION (keyboard-first,
// persistent navigation, information-dense, predictable layout), not from
// VT artwork. Modern typography and the existing palette are kept.
//
//   +--------------------------------------------------------------+
//   | hostname            network              mem                  |  header rule
//   +--------------+-----------------------------------------------+
//   | > Login      | Username: ______                              |
//   |   Session    | Password: ******                              |  rail | pane
//   |   Power      |                                               |
//   |              | Session: Terminal                             |
//   +--------------+-----------------------------------------------+
//   | [ENTER] Log in   [CTRL-S] Change session   [CTRL-Q] Power    |  legend
//   +--------------------------------------------------------------+
//
// PROTOTYPE SCOPE, deliberately narrow so this is cheap and reversible:
// this function renders the EXISTING State. It does not touch
// handleAction or FieldState. The rail is DECORATIVE: it shows the
// structure (Login / Session / Power as peer views) without implementing
// navigation, and its marker tracks state.field so it is at least
// honest about where you are. Making the rail navigable is a real
// state-machine revision (a focus axis of {rail, content} crossed with
// a view axis) and is deliberately NOT attempted here.
//
// The question this prototype exists to answer is the only one that
// matters: does this feel like an operating-system console, or like a
// busy dialog? If it does not, delete this function.
//
// Selected by PGSD_SESSIOND_LAYOUT=console.
//
// Layout snaps to the character grid. The renderer is monospace
// (8x16 glyphs scaled by SCALE), so a console layout is what these
// primitives are actually for; the centered card computes floating
// centers on a grid substrate, which is part of why it reads as an
// application dialog rather than system chrome.
//
// Header content, per the design review: hostname answers "am I at the
// right machine", network answers "can it reach anything". Memory is
// shown because State already carries it, but it is the metric that is
// easy to get rather than the one that is useful at a login prompt, and
// it is rendered dim for that reason.
//
// TODO (needs sysinfo + State, so out of scope for a draw()-only
// prototype): kernel identity. On this machine "n283562-...  PGSD"
// versus GENERIC is the single most operationally relevant fact, and a
// login header that stated it would have saved real time. Add
// sysinfo.kernelIdent() and a State field, then put it in the header.
/// The segmented memory bar.
///
/// Discrete cells rather than a continuous fill, so the operator reads a
/// LEVEL rather than estimating a proportion. Each cell is one unit of
/// MEMORY_BAR_CELLS, and the three segments always sum to exactly that
/// (see State.barCells, which owns the arithmetic and its invariant).
fn drawMemBar(
    state: *const State,
    enc: *Encoder,
    surface_w: f32,
    y: f32,
    gw: f32,
    gh: f32,
    pad_x: f32,
    sf: f32,
) !void {
    const m = state.mem orelse {
        // No sample yet. Say so rather than drawing an empty bar, which
        // would read as "no memory in use" and be a lie.
        const txt = "mem --";
        const x: f32 = surface_w - pad_x - @as(f32, @floatFromInt(txt.len)) * gw;
        try drawText(enc, txt, x, y, C_MINT_DIM_R, C_MINT_DIM_G, C_MINT_DIM_B, 1);
        return;
    };

    const b = State.barCells(m);

    // The numeric label: used of total, so the bar has a scale. Cache is
    // deliberately NOT in the number: an operator asking "how much memory
    // is this machine using" means active+wired, and putting cache in the
    // figure would reintroduce exactly the misreading the bar exists to
    // prevent.
    var lblbuf: [32]u8 = undefined;
    const lbl = std.fmt.bufPrint(&lblbuf, "{d:.1}/{d:.0}G", .{
        @as(f64, @floatFromInt(m.used_bytes)) / (1 << 30),
        @as(f64, @floatFromInt(m.total_bytes)) / (1 << 30),
    }) catch "mem";

    // Geometry: cells, then a gap, then the label, all right-aligned.
    const cell_w: f32 = gw * 0.55;
    const cell_gap: f32 = gw * 0.18;
    const cell_h: f32 = gh * 0.62;
    const bar_w: f32 = @as(f32, @floatFromInt(MEMORY_BAR_CELLS)) * (cell_w + cell_gap) - cell_gap;
    const lbl_w: f32 = @as(f32, @floatFromInt(lbl.len)) * gw;
    const gap: f32 = gw * 0.75;

    const lbl_x: f32 = surface_w - pad_x - lbl_w;
    const bar_x: f32 = lbl_x - gap - bar_w;
    const cell_y: f32 = y + (gh - cell_h) * 0.5;

    var i: usize = 0;
    while (i < MEMORY_BAR_CELLS) : (i += 1) {
        const cx: f32 = bar_x + @as(f32, @floatFromInt(i)) * (cell_w + cell_gap);

        if (i < b.used) {
            // Used: solid, full brightness. The thing that matters.
            try enc.fillRect(cx, cell_y, cell_w, cell_h, C_MINT_R, C_MINT_G, C_MINT_B, 1);
        } else if (i < b.used + b.cache) {
            // Cache: dim solid. Present, reclaimable, not pressure.
            try enc.fillRect(cx, cell_y, cell_w, cell_h, C_MINT_DIM_R, C_MINT_DIM_G, C_MINT_DIM_B, 1);
        } else {
            // Free: an outline, so the bar's full extent is always legible
            // and the operator can see the scale even at low usage. A gap
            // would make a nearly-idle machine look like a broken bar.
            const t: f32 = sf; // one scaled pixel
            try enc.fillRect(cx, cell_y, cell_w, t, C_RULE_R, C_RULE_G, C_RULE_B, 1);
            try enc.fillRect(cx, cell_y + cell_h - t, cell_w, t, C_RULE_R, C_RULE_G, C_RULE_B, 1);
            try enc.fillRect(cx, cell_y, t, cell_h, C_RULE_R, C_RULE_G, C_RULE_B, 1);
            try enc.fillRect(cx + cell_w - t, cell_y, t, cell_h, C_RULE_R, C_RULE_G, C_RULE_B, 1);
        }
    }

    try drawText(enc, lbl, lbl_x, y, C_MINT_DIM_R, C_MINT_DIM_G, C_MINT_DIM_B, 1);
}

pub fn draw(state: *const State, enc: *Encoder, blink_phase: u64, surface_w: f32, surface_h: f32) !void {
    const sf: f32 = @floatFromInt(SCALE);
    const gw: f32 = @as(f32, @floatFromInt(font.Font.GLYPH_WIDTH)) * sf;
    const gh: f32 = @as(f32, @floatFromInt(font.Font.GLYPH_HEIGHT)) * sf;
    const row: f32 = gh + 6.0 * sf; // line height + leading

    // Cell-snapped padding.
    const pad_x: f32 = gw;
    const pad_y: f32 = row * 0.5;

    try enc.fillRect(0, 0, surface_w, surface_h, C_BG_R, C_BG_G, C_BG_B, 1);

    // ---- Header: system status line, not application branding -------
    const header_h: f32 = row + pad_y * 2;
    {
        const y: f32 = pad_y;

        // Hostname, bright cyan: the machine's identity is the most
        // important thing in the header.
        try drawText(enc, state.hostname, pad_x, y, C_MINT_R, C_MINT_G, C_MINT_B, 1);

        // Network, dim cyan, right-of-center.
        const net_x: f32 = surface_w * 0.42;
        try drawText(enc, state.network_str, net_x, y, C_MINT_DIM_R, C_MINT_DIM_G, C_MINT_DIM_B, 1);

        // Memory: a segmented pressure bar, right-aligned.
        //
        // This replaces "mem 16278 MB", which was INSTALLED memory: a
        // constant, read once at init, that told an operator nothing they
        // could act on. The bar is live telemetry.
        //
        // Three segments, not two, and that is the design. FreeBSD fills
        // free RAM with cache aggressively, so a healthy machine has very
        // little genuinely free memory. A "used vs free" bar would show it
        // as nearly full when it is under no pressure at all, which is the
        // classic misreading of FreeBSD memory. Inactive pages are
        // reclaimable on demand: cache, not consumption.
        //
        //   solid  = active + wired   (genuinely consumed)
        //   dim    = inactive         (cache, reclaimable)
        //   outline= free             (unallocated)
        try drawMemBar(state, enc, surface_w, y, gw, gh, pad_x, sf);
    }
    // Header rule.
    try enc.fillRect(0, header_h, surface_w, sf, C_RULE_R, C_RULE_G, C_RULE_B, 1);

    // ---- Footer: the legend, unchanged in content ------------------
    const footer_h: f32 = row + pad_y * 2;
    const footer_top: f32 = surface_h - footer_h;
    try enc.fillRect(0, footer_top, surface_w, sf, C_RULE_R, C_RULE_G, C_RULE_B, 1);
    {
        const hint = legendFor(state);
        const x: f32 = pad_x;
        const y: f32 = footer_top + pad_y;
        try drawText(enc, hint, x, y, C_AMBER_R, C_AMBER_G, C_AMBER_B, 1);
    }

    // ---- Rail: persistent navigation (decorative in the prototype) --
    const rail_w: f32 = gw * 16;
    const body_top: f32 = header_h + sf;
    const body_bot: f32 = footer_top;
    try enc.fillRect(rail_w, body_top, sf, body_bot - body_top, C_RULE_R, C_RULE_G, C_RULE_B, 1);

    {
        // ADR 0011: the rail is navigable. Two things are shown, and
        // they are different: which view is ACTIVE (the one the pane is
        // rendering) and where the rail CURSOR is (only meaningful when
        // the rail has focus). When focus is on the rail, the cursor is
        // what the user is moving; when focus is on the content, the
        // cursor sits on the active view.
        var y: f32 = body_top + pad_y;
        inline for (.{ View.login, View.session, View.power }) |item| {
            const is_active = item == state.view;
            const is_cursor = state.focus == .rail and item == state.rail_cursor;

            // The marker distinguishes "you are here" from "you are
            // about to go here".
            const marker: []const u8 = if (is_cursor) ">" else if (is_active) "*" else " ";

            var buf: [32]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ marker, item.label() }) catch item.label();

            // Amber is the focus accent (see the palette note): it marks
            // where the keyboard is, not merely what is selected.
            if (is_cursor or (is_active and state.focus == .content)) {
                try drawText(enc, line, pad_x, y, C_AMBER_R, C_AMBER_G, C_AMBER_B, 1);
            } else {
                try drawText(enc, line, pad_x, y, C_TEXT_DIM_R, C_TEXT_DIM_G, C_TEXT_DIM_B, 1);
            }
            y += row;
        }
    }

    // ---- Pane: the ACTIVE VIEW -------------------------------------
    //
    // ADR 0011: the pane renders one view. Session and Power are not
    // overlays drawn on top of the login; they are peers, and the pane
    // shows whichever is active. There is nothing beneath them to
    // shadow, which is why nothing has to be remembered to get back.
    const pane_x: f32 = rail_w + sf + pad_x;
    const pane_y: f32 = body_top + pad_y;

    switch (state.view) {
        .login => try drawLoginView(state, enc, blink_phase, pane_x, pane_y, row, gw),
        .session => try drawSessionView(state, enc, pane_x, pane_y, row, gw),
        .power => try drawPowerView(state, enc, pane_x, pane_y, row, gw),
    }
}

/// The Login view: the fields, plus the submit affordance.
fn drawLoginView(
    state: *const State,
    enc: *Encoder,
    blink_phase: u64,
    pane_x: f32,
    pane_y: f32,
    row: f32,
    gw: f32,
) !void {
    var y: f32 = pane_y;

    try drawConsoleField(state, enc, blink_phase, .identify, "Username:", state.username.items, false, pane_x, y, gw);
    y += row;
    try drawConsoleField(state, enc, blink_phase, .password, "Password:", state.password.items, true, pane_x, y, gw);
    y += row * 2;

    // The selected session is legible without opening anything. That is
    // the peer-view model paying off before the rail is even used: a
    // value you previously had to open an overlay to see is just shown.
    {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "Session:  {s}", .{state.selected_session.displayName()}) catch "Session:";
        try drawText(enc, line, pane_x, y, C_TEXT_DIM_R, C_TEXT_DIM_G, C_TEXT_DIM_B, 1);
        y += row * 2;
    }

    // Submit affordance (ADR 0011 section 6). A framed label naming the
    // action that authenticates is a console idiom, not a GUI habit:
    // discoverability and keyboard-first are not in tension. It is not
    // clickable and does not pretend to be; it says what Enter does.
    {
        const label = if (state.field == .submitting) " Authenticating... " else " Log in  [ENTER] ";
        const w: f32 = @as(f32, @floatFromInt(label.len)) * gw;
        const h: f32 = row;
        const focused = state.field == .password and state.focus == .content;
        if (focused) {
            try drawBorder(enc, pane_x, y, w, h, C_AMBER_R, C_AMBER_G, C_AMBER_B, 1);
            try drawText(enc, label, pane_x, y + h * 0.15, C_AMBER_R, C_AMBER_G, C_AMBER_B, 1);
        } else {
            try drawBorder(enc, pane_x, y, w, h, C_TEXT_DIM_R, C_TEXT_DIM_G, C_TEXT_DIM_B, 1);
            try drawText(enc, label, pane_x, y + h * 0.15, C_TEXT_DIM_R, C_TEXT_DIM_G, C_TEXT_DIM_B, 1);
        }
        y += row * 2;
    }

    if (state.status_message) |msg| {
        try drawText(enc, msg, pane_x, y, C_AMBER_R, C_AMBER_G, C_AMBER_B, 1);
    }
}

/// The Session view: what the picker overlay used to be, as a pane.
fn drawSessionView(
    state: *const State,
    enc: *Encoder,
    pane_x: f32,
    pane_y: f32,
    row: f32,
    gw: f32,
) !void {
    _ = gw;
    var y: f32 = pane_y;

    try drawText(enc, "Session type", pane_x, y, C_TEXT_R, C_TEXT_G, C_TEXT_B, 1);
    y += row * 2;

    inline for (.{ SessionType.terminal, SessionType.x11, SessionType.wayland, SessionType.nde }) |st| {
        const is_cursor = st == state.picker_cursor and state.focus == .content;
        const is_selected = st == state.selected_session;
        const enabled = st.enabled();

        var buf: [64]u8 = undefined;
        const marker: []const u8 = if (is_cursor) ">" else if (is_selected) "*" else " ";
        const suffix: []const u8 = if (enabled) "" else "  (not installed)";
        const line = std.fmt.bufPrint(&buf, "{s} {s}{s}", .{ marker, st.displayName(), suffix }) catch st.displayName();

        if (!enabled) {
            // Disabled entries must LOOK unavailable, not merely be
            // unreachable by the cursor.
            try drawText(enc, line, pane_x, y, C_TEXT_DIM_R, C_TEXT_DIM_G, C_TEXT_DIM_B, 1);
        } else if (is_cursor) {
            try drawText(enc, line, pane_x, y, C_AMBER_R, C_AMBER_G, C_AMBER_B, 1);
        } else {
            try drawText(enc, line, pane_x, y, C_TEXT_R, C_TEXT_G, C_TEXT_B, 1);
        }
        y += row;
    }
}

/// The Power view. The confirm gate on destructive actions is kept
/// (ADR 0011 section 3): reaching the action is now easier, which makes
/// confirmation more necessary, not less.
fn drawPowerView(
    state: *const State,
    enc: *Encoder,
    pane_x: f32,
    pane_y: f32,
    row: f32,
    gw: f32,
) !void {
    _ = gw;
    var y: f32 = pane_y;

    switch (state.power_menu_phase) {
        .choosing => {
            try drawText(enc, "Power", pane_x, y, C_TEXT_R, C_TEXT_G, C_TEXT_B, 1);
            y += row * 2;
            inline for (.{ PowerOption.shutdown, PowerOption.restart, PowerOption.suspend_ }) |opt| {
                const is_cursor = opt == state.power_menu_cursor and state.focus == .content;
                var buf: [64]u8 = undefined;
                const marker: []const u8 = if (is_cursor) ">" else " ";
                const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ marker, opt.displayName() }) catch opt.displayName();
                if (is_cursor) {
                    try drawText(enc, line, pane_x, y, C_AMBER_R, C_AMBER_G, C_AMBER_B, 1);
                } else {
                    try drawText(enc, line, pane_x, y, C_TEXT_R, C_TEXT_G, C_TEXT_B, 1);
                }
                y += row;
            }
        },
        .confirming_shutdown, .confirming_restart => {
            const what: []const u8 = if (state.power_menu_phase == .confirming_shutdown)
                "Power off this machine?"
            else
                "Restart this machine?";
            try drawText(enc, what, pane_x, y, C_AMBER_R, C_AMBER_G, C_AMBER_B, 1);
            y += row * 2;
            try drawText(enc, "[Y] Yes    [N] No", pane_x, y, C_TEXT_R, C_TEXT_G, C_TEXT_B, 1);
        },
        .in_progress => {
            const banner: []const u8 = switch (state.power_action orelse .shutdown) {
                .shutdown => "Shutting down...",
                .restart => "Restarting...",
                .suspend_ => "Suspending...",
            };
            try drawText(enc, banner, pane_x, y, C_AMBER_R, C_AMBER_G, C_AMBER_B, 1);
        },
    }
}

/// The console legend, keyed on the (focus, view) pair. This is the
/// discoverability surface, and ADR 0011 simply gives it a second axis:
/// it already named the keys available in the current state.
fn legendFor(state: *const State) []const u8 {
    if (state.field == .submitting) return "Authenticating...";

    if (state.focus == .rail) {
        return "[UP/DN] Navigate   [ENTER] Open   [ESC] Back   [CTRL-Q] Power";
    }
    return switch (state.view) {
        .login => switch (state.field) {
            .identify => "[ENTER] Continue   [UP] Menu   [ESC] Clear   [CTRL-Q] Power",
            .password => "[ENTER] Log in   [UP] Menu   [CTRL-S] Session   [ESC] Clear   [CTRL-Q] Power",
            else => "[ENTER] Continue   [ESC] Clear   [CTRL-Q] Power",
        },
        .session => "[UP/DN] Select   [ENTER] Confirm   [ESC] Back",
        .power => switch (state.power_menu_phase) {
            .choosing => "[UP/DN] Select   [ENTER] Choose   [ESC] Back",
            .confirming_shutdown => "[Y] Power off   [N] Back   [ESC] Back",
            .confirming_restart => "[Y] Reboot   [N] Back   [ESC] Back",
            .in_progress => "Please wait...",
        },
    };
}
/// A labelled field row, grid-aligned. The console analogue of drawField.
fn drawConsoleField(
    state: *const State,
    enc: *Encoder,
    blink_phase: u64,
    which: FieldState,
    label: []const u8,
    contents: []const u8,
    mask: bool,
    x: f32,
    y: f32,
    gw: f32,
) !void {
    const focused = state.field == which or
        (which == .password and (state.field == .picker or state.field == .submitting));

    if (focused) {
        try drawText(enc, label, x, y, C_AMBER_R, C_AMBER_G, C_AMBER_B, 1); // accent = focus
    } else {
        try drawText(enc, label, x, y, C_TEXT_DIM_R, C_TEXT_DIM_G, C_TEXT_DIM_B, 1); // unfocused label
    }

    const val_x: f32 = x + @as(f32, @floatFromInt(label.len + 2)) * gw;

    var buf: [256]u8 = undefined;
    var shown: []const u8 = contents;
    if (mask) {
        const n = @min(contents.len, buf.len);
        for (0..n) |i| buf[i] = '*';
        shown = buf[0..n];
    }
    try drawText(enc, shown, val_x, y, C_TEXT_R, C_TEXT_G, C_TEXT_B, 1); // content is text, not accent

    // Cursor: block, on the active field only, blinking unless the user
    // has not typed yet (steady-on invites the first keystroke).
    if (state.field == which) {
        const on = !state.typing_started or (blink_phase % 2 == 0);
        if (on) {
            const cx: f32 = val_x + @as(f32, @floatFromInt(shown.len)) * gw;
            try enc.fillRect(cx, y, gw, @as(f32, @floatFromInt(font.Font.GLYPH_HEIGHT)) * @as(f32, @floatFromInt(SCALE)), C_AMBER_R, C_AMBER_G, C_AMBER_B, 1);
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

















// Console layout prototype: the legend is shared, so a change to one
// layout's hints cannot silently diverge from the other's.

test "console: view labels" {
    try testing.expectEqualStrings("Login", View.login.label());
    try testing.expectEqualStrings("Session", View.session.label());
    try testing.expectEqualStrings("Power", View.power.label());
}

// =============================================================================
// ADR 0011: console navigation model
// =============================================================================
//
// These are the ADR's bench requirements as unit tests. The important
// one is the last: pre_power_field must not be needed. If a future
// change reintroduces modal bookkeeping into the console path, the
// model stopped being more natural than the one it replaced.

fn makeConsoleState(alloc: std.mem.Allocator) !State {
    return makeTestState(alloc);
}

test "console: rail navigation, Up/Down move, Enter opens, ESC returns" {
    var s = try makeConsoleState(testing.allocator);
    defer s.deinit();

    // Login view, content focus, at rest.
    try testing.expectEqual(View.login, s.view);
    try testing.expectEqual(Focus.content, s.focus);

    // Up from the login fields reaches the rail (ESC is taken by
    // clear-field in the login view).
    try s.handleAction(.up);
    try testing.expectEqual(Focus.rail, s.focus);
    try testing.expectEqual(View.login, s.rail_cursor);

    // Down moves the cursor without changing the active view.
    try s.handleAction(.down);
    try testing.expectEqual(View.session, s.rail_cursor);
    try testing.expectEqual(View.login, s.view); // not entered yet

    // Enter opens it.
    try s.handleAction(.enter);
    try testing.expectEqual(View.session, s.view);
    try testing.expectEqual(Focus.content, s.focus);

    // ESC leaves the view content and returns to the rail.
    try s.handleAction(.clear);
    try testing.expectEqual(Focus.rail, s.focus);
    try testing.expectEqual(View.session, s.rail_cursor);
}

test "console: no view is reachable that cannot be left" {
    var s = try makeConsoleState(testing.allocator);
    defer s.deinit();

    inline for (.{ View.session, View.power }) |v| {
        s.view = v;
        s.focus = .content;
        try s.handleAction(.clear); // ESC
        try testing.expectEqual(Focus.rail, s.focus);
    }
}

test "console: Session view produces the same selected_session as the old picker" {
    var s = try makeConsoleState(testing.allocator);
    defer s.deinit();

    try s.handleAction(.session_picker); // Ctrl-S
    try testing.expectEqual(View.session, s.view);
    try testing.expectEqual(Focus.content, s.focus);
    try testing.expectEqual(SessionType.terminal, s.picker_cursor);

    try s.handleAction(.enter); // confirm
    try testing.expectEqual(SessionType.terminal, s.selected_session);
    // Returns to the RAIL, not to a bookmarked field: there is nothing
    // to bookmark, because Session covered nothing to get here.
    try testing.expectEqual(Focus.rail, s.focus);
}

test "console: Power still gates destructive actions behind a confirm" {
    var s = try makeConsoleState(testing.allocator);
    defer s.deinit();

    try s.handleAction(.power_menu); // Ctrl-Q
    try testing.expectEqual(View.power, s.view);
    try testing.expectEqual(PowerMenuPhase.choosing, s.power_menu_phase);
    try testing.expectEqual(PowerOption.shutdown, s.power_menu_cursor);

    // Enter on Shutdown must NOT shut down. It must confirm first.
    try s.handleAction(.enter);
    try testing.expectEqual(PowerMenuPhase.confirming_shutdown, s.power_menu_phase);
    try testing.expectEqual(@as(?PowerOption, null), s.power_action);

    // N backs out.
    try s.handleAction(.{ .print = 'n' });
    try testing.expectEqual(PowerMenuPhase.choosing, s.power_menu_phase);
    try testing.expectEqual(@as(?PowerOption, null), s.power_action);

    // Y arms it.
    try s.handleAction(.enter);
    try s.handleAction(.{ .print = 'y' });
    try testing.expectEqual(@as(?PowerOption, PowerOption.shutdown), s.power_action);
}

test "console: submitting locks the fields AND the rail" {
    var s = try makeConsoleState(testing.allocator);
    defer s.deinit();

    s.field = .submitting;

    // Nothing moves. Not the rail, not the view, not the fields.
    try s.handleAction(.up);
    try s.handleAction(.down);
    try s.handleAction(.enter);
    try s.handleAction(.power_menu); // even Ctrl-Q
    try s.handleAction(.{ .print = 'x' });

    try testing.expectEqual(Focus.content, s.focus);
    try testing.expectEqual(View.login, s.view);
    try testing.expectEqual(FieldState.submitting, s.field);
    try testing.expectEqual(@as(usize, 0), s.password.items.len);
}

test "console: Ctrl-Q reaches Power from every view" {
    inline for (.{ View.login, View.session, View.power }) |from| {
        var s = try makeConsoleState(testing.allocator);
        defer s.deinit();
        s.view = from;
        s.focus = .content;

        try s.handleAction(.power_menu);
        try testing.expectEqual(View.power, s.view);
        try testing.expectEqual(Focus.content, s.focus);
    }
}

test "console: login typing still works, and ESC still clears the field" {
    var s = try makeConsoleState(testing.allocator);
    defer s.deinit();

    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.{ .print = 'i' });
    try s.handleAction(.{ .print = 'c' });
    try testing.expectEqualStrings("vic", s.username.items);

    try s.handleAction(.clear); // ESC clears, does NOT leave
    try testing.expectEqual(@as(usize, 0), s.username.items.len);
    try testing.expectEqual(Focus.content, s.focus);
    try testing.expectEqual(View.login, s.view);

    try s.handleAction(.{ .print = 'v' });
    try s.handleAction(.enter); // identify -> password
    try testing.expectEqual(FieldState.password, s.field);
    try s.handleAction(.enter); // password -> submitting
    try testing.expectEqual(FieldState.submitting, s.field);
}


// Coverage carried over from the retired modal tests. The BEHAVIOUR
// survived the retirement; only the way it is reached changed, so the
// tests are rewritten against the view model rather than dropped.

test "console: power accelerators S/R/Z work, case-insensitively" {
    inline for (.{ 's', 'S' }) |ch| {
        var s = try makeConsoleState(testing.allocator);
        defer s.deinit();
        try s.handleAction(.power_menu);
        try s.handleAction(.{ .print = ch });
        try testing.expectEqual(PowerMenuPhase.confirming_shutdown, s.power_menu_phase);
    }
    inline for (.{ 'r', 'R' }) |ch| {
        var s = try makeConsoleState(testing.allocator);
        defer s.deinit();
        try s.handleAction(.power_menu);
        try s.handleAction(.{ .print = ch });
        try testing.expectEqual(PowerMenuPhase.confirming_restart, s.power_menu_phase);
    }
}

test "console: suspend arms immediately, with no confirm step" {
    var s = try makeConsoleState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.power_menu);
    try s.handleAction(.{ .print = 'z' });
    // Suspend is not destructive in the way shutdown and restart are:
    // it arms directly. This asymmetry is deliberate and predates
    // ADR 0011.
    try testing.expectEqual(@as(?PowerOption, PowerOption.suspend_), s.power_action);
}

test "console: status_message is cleared once the user starts typing" {
    var s = try makeConsoleState(testing.allocator);
    defer s.deinit();
    s.status_message = "Authentication failed";

    try s.handleAction(.{ .print = 'v' });
    try testing.expectEqual(@as(?[]const u8, null), s.status_message);
}

test "console: Session view cursor skips disabled entries" {
    var s = try makeConsoleState(testing.allocator);
    defer s.deinit();
    try s.handleAction(.session_picker);

    // v1: only .terminal is enabled, so the cursor cannot leave it.
    try s.handleAction(.down);
    try testing.expectEqual(SessionType.terminal, s.picker_cursor);
    try s.handleAction(.up);
    try testing.expectEqual(SessionType.terminal, s.picker_cursor);
}

test "console: entering the Session view clears a stale status message" {
    var s = try makeConsoleState(testing.allocator);
    defer s.deinit();
    s.status_message = "Authentication failed";

    try s.handleAction(.session_picker);
    try s.handleAction(.enter); // confirm
    try testing.expectEqual(@as(?[]const u8, null), s.status_message);
}

// Memory bar segmentation.
//
// The invariant that matters: the three segments sum to exactly
// MEMORY_BAR_CELLS. Rounding each independently does not guarantee it,
// and a bar that is one cell short shows a gap while one cell over writes
// past its own width.

test "barCells: segments always sum to exactly the cell count" {
    const cases = [_]sysinfo.MemStats{
        // A freshly booted machine: little used, little cached, mostly free.
        .{ .used_bytes = 500 << 20, .cache_bytes = 200 << 20, .free_bytes = 15 << 30, .total_bytes = 16 << 30 },
        // A working machine: FreeBSD has filled RAM with cache.
        .{ .used_bytes = 6 << 30, .cache_bytes = 9 << 30, .free_bytes = 1 << 30, .total_bytes = 16 << 30 },
        // Under real pressure.
        .{ .used_bytes = 15 << 30, .cache_bytes = 512 << 20, .free_bytes = 256 << 20, .total_bytes = 16 << 30 },
        // Pathological: everything used.
        .{ .used_bytes = 16 << 30, .cache_bytes = 0, .free_bytes = 0, .total_bytes = 16 << 30 },
        // Pathological: nothing anywhere.
        .{ .used_bytes = 0, .cache_bytes = 0, .free_bytes = 16 << 30, .total_bytes = 16 << 30 },
        // Degenerate: no total. Must not divide by zero.
        .{ .used_bytes = 0, .cache_bytes = 0, .free_bytes = 0, .total_bytes = 0 },
    };

    for (cases) |m| {
        const b = State.barCells(m);
        try std.testing.expectEqual(MEMORY_BAR_CELLS, b.used + b.cache + b.free);
    }
}

test "barCells: a nonzero segment never rounds away to nothing" {
    // 100 MB used of 16 GB is 0.6% of the bar, well under one cell of 16.
    // It must still light one cell: a pressure indicator has to distinguish
    // "some" from "none", or a slow leak is invisible until it is large.
    const m = sysinfo.MemStats{
        .used_bytes = 100 << 20,
        .cache_bytes = 50 << 20,
        .free_bytes = 16 << 30,
        .total_bytes = 16 << 30,
    };
    const b = State.barCells(m);
    try std.testing.expect(b.used >= 1);
    try std.testing.expect(b.cache >= 1);
    try std.testing.expectEqual(MEMORY_BAR_CELLS, b.used + b.cache + b.free);
}

test "barCells: cache is not counted as used" {
    // The whole point of the three-way split. FreeBSD fills RAM with cache,
    // so a machine with 9G inactive is NOT under memory pressure, and a
    // two-way "used vs free" bar would show it as 94% full. The used segment
    // must reflect only active+wired.
    const m = sysinfo.MemStats{
        .used_bytes = 4 << 30, // active + wired
        .cache_bytes = 11 << 30, // inactive: reclaimable
        .free_bytes = 1 << 30,
        .total_bytes = 16 << 30,
    };
    const b = State.barCells(m);
    // 4/16 = a quarter of the bar, not 15/16.
    try std.testing.expectEqual(@as(usize, 4), b.used);
    try std.testing.expect(b.cache > b.used);
}
