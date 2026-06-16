const std = @import("std");
const compat = @import("compat");
const posix = std.posix;
const protocol = @import("protocol");
const socket_server = @import("socket_server");
const tcp_server = @import("tcp_server");
const client_session = @import("client_session");
const surface_registry = @import("surface_registry");
const shm = @import("shm");
const sdcs_validator = @import("sdcs_validator");
const compositor = @import("compositor");
const backend = @import("backend");
const events = @import("events");
const libsemainput = @import("libsemainput");
const input = @import("input");
const damage = @import("damage");
const privilege = @import("privilege");

const log = std.log.scoped(.semadrawd);

pub const std_options = std.Options{
    .log_level = .info,
};

/// Poll file descriptor (Zig-native version of pollfd)
const PollFd = extern struct {
    fd: posix.fd_t,
    events: i16,
    revents: i16,
};

// Per-source-role event_type constants live in shared/src/input.zig
// (input.POINTER_MOTION, input.TOUCH_DOWN, etc.) since AD-2a Phase 3.
// Previously duplicated here and in semadraw/src/backend/inputfs_input.zig.

/// AD-2a Phase 2.4.4: translate a raw inputfs `input.Event` into a
/// `LibsemainputInput` for the gesture recogniser. Returns null for
/// events the recogniser does not consume (keyboard, lighting,
/// device-lifecycle, pen, and unknown event_types).
///
/// The recogniser already accepts ts_ns and ts_audio_samples on its
/// input variants, so they're populated directly from the inputfs
/// event's ts_ordering (chronofs ns) and ts_sync (audio samples;
/// 0 means unavailable per shared/INPUT_EVENTS.md, mapped to null
/// here).
///
/// device_slot is preserved exactly. Per ADR 0016 Stage A the
/// recogniser keys per-device state on this field.
fn translateInputfsEvent(ev: input.Event) ?libsemainput.LibsemainputInput {
    const ts_audio: ?u64 = if (ev.ts_sync == 0) null else ev.ts_sync;

    return switch (ev.source_role) {
        input.SOURCE_POINTER => switch (ev.event_type) {
            input.POINTER_MOTION => blk: {
                const x = std.mem.readInt(i32, ev.payload[0..4], .little);
                const y = std.mem.readInt(i32, ev.payload[4..8], .little);
                const dx = std.mem.readInt(i32, ev.payload[8..12], .little);
                const dy = std.mem.readInt(i32, ev.payload[12..16], .little);
                const buttons = std.mem.readInt(u32, ev.payload[16..20], .little);
                break :blk .{ .pointer_motion = .{
                    .device_slot = ev.device_slot,
                    .x = x,
                    .y = y,
                    .dx = dx,
                    .dy = dy,
                    .buttons = buttons,
                    .ts_ns = ev.ts_ordering,
                    .ts_audio_samples = ts_audio,
                } };
            },
            input.POINTER_BUTTON_DOWN, input.POINTER_BUTTON_UP => blk: {
                const x = std.mem.readInt(i32, ev.payload[0..4], .little);
                const y = std.mem.readInt(i32, ev.payload[4..8], .little);
                const button = std.mem.readInt(u32, ev.payload[8..12], .little);
                break :blk .{ .pointer_button = .{
                    .device_slot = ev.device_slot,
                    .x = x,
                    .y = y,
                    .button = button,
                    .pressed = ev.event_type == input.POINTER_BUTTON_DOWN,
                    .ts_ns = ev.ts_ordering,
                    .ts_audio_samples = ts_audio,
                } };
            },
            input.POINTER_SCROLL => blk: {
                // Pointer scroll payload: x, y at offsets 0..7 (unused
                // by the recogniser; pointer_scroll is a no-op feed
                // per libsemainput.handleEvent), then scroll_dx,
                // scroll_dy at 8..15.
                const dx = std.mem.readInt(i32, ev.payload[8..12], .little);
                const dy = std.mem.readInt(i32, ev.payload[12..16], .little);
                break :blk .{ .pointer_scroll = .{
                    .device_slot = ev.device_slot,
                    .dx = dx,
                    .dy = dy,
                    .ts_ns = ev.ts_ordering,
                    .ts_audio_samples = ts_audio,
                } };
            },
            else => null, // enter/leave (5/6) and unknowns
        },
        input.SOURCE_TOUCH => switch (ev.event_type) {
            input.TOUCH_DOWN => blk: {
                const contact_id = std.mem.readInt(u32, ev.payload[0..4], .little);
                const x = std.mem.readInt(i32, ev.payload[4..8], .little);
                const y = std.mem.readInt(i32, ev.payload[8..12], .little);
                break :blk .{ .touch_down = .{
                    .device_slot = ev.device_slot,
                    .contact_id = contact_id,
                    .x = x,
                    .y = y,
                    .ts_ns = ev.ts_ordering,
                    .ts_audio_samples = ts_audio,
                } };
            },
            input.TOUCH_MOVE => blk: {
                const contact_id = std.mem.readInt(u32, ev.payload[0..4], .little);
                const x = std.mem.readInt(i32, ev.payload[4..8], .little);
                const y = std.mem.readInt(i32, ev.payload[8..12], .little);
                break :blk .{ .touch_move = .{
                    .device_slot = ev.device_slot,
                    .contact_id = contact_id,
                    .x = x,
                    .y = y,
                    .ts_ns = ev.ts_ordering,
                    .ts_audio_samples = ts_audio,
                } };
            },
            input.TOUCH_UP => blk: {
                const contact_id = std.mem.readInt(u32, ev.payload[0..4], .little);
                break :blk .{ .touch_up = .{
                    .device_slot = ev.device_slot,
                    .contact_id = contact_id,
                    .ts_ns = ev.ts_ordering,
                    .ts_audio_samples = ts_audio,
                } };
            },
            else => null,
        },
        // Keyboard, pen, lighting, device-lifecycle: not consumed by
        // the recogniser. Pen could feed touch_* in a future
        // extension; for now the recogniser doesn't model pen as
        // touch, so we drop it.
        else => null,
    };
}

/// Daemon configuration
pub const Config = struct {
    socket_path: []const u8 = protocol.DEFAULT_SOCKET_PATH,
    tcp_port: ?u16 = null, // TCP port for remote connections (null = disabled)
    tcp_addr: [4]u8 = .{ 0, 0, 0, 0 }, // TCP bind address
    max_clients: u32 = 256,
    log_level: std.log.Level = .info,
    backend_type: backend.BackendType = .software,
    width: u32 = 1920, // Display width in pixels
    height: u32 = 1080, // Display height in pixels
};

/// Remote client session wrapper
/// AD-46: consecutive non-coalescible send failures (WouldBlock on a
/// full client socket) tolerated before the client is disconnected.
/// At typical loop rates this is a few seconds of a completely
/// stalled client; a healthy slow client resets the streak on its
/// first drained send.
const AD46_SEND_FAIL_DISCONNECT: u32 = 64;

// AD-46 revision (2026-06-05, second bench): fd-level O_NONBLOCK was
// removed after it broke the receive path (readLargeMessage maps
// WouldBlock to 0 and treats 0 as ConnectionClosed, so every large
// SDCS message disconnected the client; the bench tail showed the
// reconnect churn). Client fds are BLOCKING again; the forward path
// gets its non-blocking behaviour per-call via MSG_DONTWAIT inside
// trySendMessage instead, which is the property AD-46 actually
// needs: sends that cannot wedge, reads untouched.

const RemoteSession = struct {
    client: tcp_server.RemoteClient,
    id: protocol.ClientId,
    state: client_session.SessionState,
    /// AD-31.2 / ADR 0006 §2: TCP connections have no peer-uid that
    /// the kernel can attest to. They are treated as NOBODY_UID for
    /// privilege purposes; subsequent uid-based decisions never
    /// grant elevated rights to a NOBODY_UID session.
    peer_uid: posix.uid_t,
    peer_gid: posix.gid_t,
    sdcs_buffer: ?[]u8, // Inline SDCS data for current surface

    pub fn getFd(self: *RemoteSession) posix.fd_t {
        return self.client.getFd();
    }
};

/// Daemon state
pub const Daemon = struct {
    allocator: std.mem.Allocator,
    config: Config,
    server: socket_server.SocketServer,
    tcp: ?tcp_server.TcpServer,
    clients: client_session.ClientManager,
    remote_clients: std.AutoHashMap(protocol.ClientId, *RemoteSession),
    next_remote_id: protocol.ClientId,
    surfaces: surface_registry.SurfaceRegistry,
    comp: compositor.Compositor,
    /// AD-2a Phase 2.4.3: one gesture recogniser per Daemon, shared
    /// across all clients. Held as a value (not a pointer); the
    /// libsemainput type is stack-shaped with allocator-borrowed
    /// lists. Initialised in initCompositor alongside the existing
    /// compositor init; deinitialised in Daemon.deinit. Fed in
    /// Phase 2.4.4; output forwarded to clients in Phase 2.4.5.
    gesture_recognizer: libsemainput.GestureRecognizer,
    /// AD-2a Phase 2.4.4: chronofs ns timestamp of the most recent
    /// input event fed into the recogniser this drain cycle. Phase
    /// 2.4.5's forwardGestureEvents copies this into
    /// GestureEventMsg.t_current at emit time, so gestures carry
    /// the timestamp of the input event that triggered the phase
    /// transition (per ADR 0017-rev2 addendum 2026-05-04). Reset
    /// on Daemon.init; updated each loop iteration that drains
    /// inputfs events.
    last_input_ts_ns: u64,
    /// AD-2a Phase 2.4.5: most recent keyboard modifier state seen
    /// at the daemon. Updated from forwardKeyEvents and
    /// forwardMouseEvents (both KeyEvent and MouseEvent carry
    /// .modifiers populated by the backend's inputfs_input
    /// keyboard dispatch; the daemon mirrors the value here so
    /// forwardGestureEvents can attach it to GestureEventMsg.flags
    /// without reaching into the backend).
    ///
    /// Bit layout matches the backend's u8 modifier encoding:
    ///   bit 0 = SHIFT, bit 1 = ALT, bit 2 = CTRL, bit 3 = META.
    /// GestureFlags happens to use the same bit ordering, so the
    /// translation at emit time is a direct cast.
    last_modifiers: u8,
    running: bool,
    /// AD-21 sub-item 3: id of the daemon-owned cursor surface, set by
    /// initCursorSurface during initCompositor and used by the position
    /// pump (sub-item 5) and SET_CURSOR handler (sub-item 7). Optional
    /// because creation can fail; the daemon continues running if it
    /// does, just without a visible cursor.
    cursor_surface_id: ?protocol.SurfaceId,
    /// AD-21 sub-item 5: last cursor surface position written, used for
    /// change detection. last_cursor_pos_set transitions from false to
    /// true on the first successful pump; after that, the pump compares
    /// the freshly computed (pointer - hotspot) against these to decide
    /// whether to mark damage and write a new position.
    last_cursor_pos_x: f32,
    last_cursor_pos_y: f32,
    last_cursor_pos_set: bool,
    /// AD-21 sub-item 8: last cursor surface visibility state, used for
    /// damage propagation when the cursor crosses the framebuffer
    /// boundary. The cursor surface itself is `visible: true` by
    /// default; this field tracks whether the most recent pump call
    /// computed visible == true so the next pump can detect a
    /// false→true or true→false transition and mark damage on the
    /// underlying surfaces under the cursor's previous "displayed"
    /// rect (empty when invisible). Distinct from the surface's own
    /// `visible` field, which is what gets toggled, this is the
    /// pump's record of what it last set, used for transition detect.
    last_cursor_visible: bool,
    /// AD-36: most recent absolute pointer coordinates derived from a
    /// `pointer.motion` event in the inputfs event ring. Updated in
    /// the main loop's inputfs_events scan (the same scan that feeds
    /// the gesture recogniser) so the cursor pump can read the
    /// current pointer position without going through the
    /// state-region mmap, which exhibits the AD-34 staleness bug for
    /// non-root mmaps.
    ///
    /// `last_motion_seen` starts false at daemon init and transitions
    /// to true on the first observed pointer.motion event. While
    /// false, pumpCursorPosition skips its work (no known position
    /// yet, same as before AD-36 when the state region wasn't valid).
    /// After it goes true, the pump uses last_motion_x/y as the
    /// current pointer coordinates.
    ///
    /// These are intentionally separate from last_cursor_pos_x/y
    /// (which track the cursor *surface* position with hotspot
    /// adjustment applied). last_motion_x/y are raw pointer
    /// coordinates from the inputfs event payload, used as the input
    /// to the pump's per-iteration position computation.
    last_motion_x: i32,
    last_motion_y: i32,
    last_motion_seen: bool,
    /// AD-24: focus-loss cursor reset.
    ///
    /// last_top_surface tracks the result of getTopVisibleSurface()
    /// from the previous focus-pump tick. The pump compares the
    /// current top against this; on a transition where the new top
    /// is null AND the cursor has been customised by a previous
    /// SET_CURSOR (cursor_is_default == false), the pump resets the
    /// cursor surface to the default arrow sprite.
    ///
    /// cursor_is_default tracks whether the cursor surface currently
    /// holds the embedded default sprite from cursor_arrow.sdcs. Set
    /// to true after initCursorSurface or resetCursorToDefault, set
    /// to false after a successful SET_CURSOR. Avoids re-attaching
    /// the default buffer redundantly on every null-focus tick.
    ///
    /// Per ADR 0005 §5: focus-A → focus-B is NOT a reset trigger
    /// (the new client is responsible for SET_CURSOR if it wants a
    /// custom sprite). Only focus-X → null triggers the reset.
    /// Per-client cursor caching is explicitly out of scope (ADR §9).
    last_top_surface: ?protocol.SurfaceId,
    cursor_is_default: bool,
    // Pending clipboard request tracking
    pending_clipboard_client: ?protocol.ClientId,
    pending_clipboard_selection: u8,

    /// AD-31.3 part 2: the daemon's own runtime uid. Read from
    /// SEMADRAW_RUN_UID at init time when running as root (the env
    /// var is the source of truth for the uid the daemon will drop
    /// to in dropPrivileges); read from posix.geteuid() when not
    /// running as root (development mode, where dropPrivileges
    /// skips entirely).
    ///
    /// Used as the owner_uid of daemon-owned surfaces (the cursor
    /// surface) and consulted by canModifySurface for the
    /// "daemon can modify daemon-owned surfaces" identity case
    /// that arises during compositor-internal operations.
    run_uid: posix.uid_t,

    /// AD-31.3 part 2: configured privileged uid (ADR 0006 §3).
    /// Read from SEMADRAW_PRIVILEGED_UID at init time. Null when
    /// the env-var is unset, in which case no client is
    /// privileged (the default, most restrictive posture).
    ///
    /// PGSD's s6 run-script sets this to the uid of
    /// `_pgsd_sessiond` so the login daemon can modify any
    /// surface and create high-z-order surfaces. Distributions
    /// that don't deploy pgsd-sessiond leave this unset.
    privileged_uid: ?posix.uid_t,

    /// AD-25 Round 1 (ADR 0007): pump-cadence instrumentation gate.
    /// Reads UTF_PUMP_INSTRUMENT at construction time. Any non-empty
    /// value enables; absent or empty leaves it off. Reading once at
    /// construction means zero per-pump syscall cost when off. When
    /// enabled, pumpCursorPosition emits a `pump_diagnostic` event
    /// per invocation that reaches the change-detection point.
    pump_instrument: bool,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Daemon {
        var server = try socket_server.SocketServer.bind(config.socket_path);
        errdefer server.deinit();

        // Initialize TCP server if port is configured
        var tcp: ?tcp_server.TcpServer = null;
        if (config.tcp_port) |port| {
            tcp = try tcp_server.TcpServer.bindAddr(config.tcp_addr, port);
        }
        errdefer if (tcp) |*t| t.deinit();

        // AD-31.3 part 2: resolve the daemon's runtime uid.
        //
        // Two cases:
        //   - Running as root: dropPrivileges will read
        //     SEMADRAW_RUN_UID and setuid to it. We read the same
        //     env var here so the cursor surface (created before
        //     the drop) carries the post-drop uid as its
        //     owner_uid. The drop itself happens later in main();
        //     here we are still root but already know the target
        //     uid.
        //   - Not running as root (development mode): dropPrivileges
        //     logs a warning and skips. The daemon stays at the
        //     operator's uid. run_uid is just posix.geteuid().
        const run_uid: posix.uid_t = blk: {
            const starting_uid = posix.getuid();
            if (starting_uid != 0) {
                break :blk posix.geteuid();
            }
            const env_uid = posix.getenv("SEMADRAW_RUN_UID") orelse {
                log.err("running as root but SEMADRAW_RUN_UID is unset; init cannot determine run uid", .{});
                return error.EnvVarMissing;
            };
            break :blk std.fmt.parseInt(posix.uid_t, env_uid, 10) catch {
                log.err("SEMADRAW_RUN_UID is not a valid integer: '{s}'", .{env_uid});
                return error.InvalidEnvUid;
            };
        };

        // AD-31.3 part 2: resolve the configured privileged uid.
        // ADR 0006 §3: the privileged client is recognised by uid
        // match against this value. Unset env var means no
        // privileged client (the default and most restrictive
        // posture). Log the resolution so operators can see what
        // the daemon decided.
        const privileged_uid: ?posix.uid_t = blk: {
            const env_priv = posix.getenv("SEMADRAW_PRIVILEGED_UID") orelse {
                log.info("SEMADRAW_PRIVILEGED_UID unset; no client will be granted privileged status", .{});
                break :blk null;
            };
            const parsed = std.fmt.parseInt(posix.uid_t, env_priv, 10) catch {
                log.err("SEMADRAW_PRIVILEGED_UID is not a valid integer: '{s}'; treating as unset", .{env_priv});
                break :blk null;
            };
            if (parsed == privilege.NOBODY_UID) {
                log.warn("SEMADRAW_PRIVILEGED_UID is set to NOBODY_UID ({d}); the isPrivilegedUid check refuses to honour this and treats it as unset", .{parsed});
                break :blk null;
            }
            if (parsed == 0) {
                log.warn("SEMADRAW_PRIVILEGED_UID is set to 0 (root); this grants any process running as root privileged client status, which is unusual outside of testing", .{});
            }
            log.info("SEMADRAW_PRIVILEGED_UID resolved: {d}", .{parsed});
            break :blk parsed;
        };

        return .{
            .allocator = allocator,
            .config = config,
            .server = server,
            .tcp = tcp,
            .clients = client_session.ClientManager.init(allocator),
            .remote_clients = std.AutoHashMap(protocol.ClientId, *RemoteSession).init(allocator),
            .next_remote_id = 0x80000000, // Remote clients start at high IDs
            .surfaces = surface_registry.SurfaceRegistry.init(allocator),
            .comp = undefined, // Initialized in initCompositor
            .gesture_recognizer = undefined, // Initialized in initCompositor
            .last_input_ts_ns = 0,
            .last_modifiers = 0,
            .running = false,
            .cursor_surface_id = null,
            .last_cursor_pos_x = 0,
            .last_cursor_pos_y = 0,
            .last_cursor_pos_set = false,
            .last_cursor_visible = true,
            .last_motion_x = 0,
            .last_motion_y = 0,
            .last_motion_seen = false,
            .last_top_surface = null,
            .cursor_is_default = true,
            .pending_clipboard_client = null,
            .pending_clipboard_selection = 0,
            .run_uid = run_uid,
            .privileged_uid = privileged_uid,
            .pump_instrument = blk: {
                const v = std.posix.getenv("UTF_PUMP_INSTRUMENT") orelse break :blk false;
                break :blk v.len > 0;
            },
        };
    }

    /// AD-31.3 part 2: surface-modify permission check.
    ///
    /// Returns true iff the peer with the given uid is allowed to
    /// modify the surface identified by surface_id. The rule, per
    /// ADR 0006 §4:
    ///
    ///   - If the surface does not exist, return false. (Callers
    ///     should also distinguish invalid_surface from
    ///     permission_denied where the protocol allows it; this
    ///     function does not, but the caller can check
    ///     surfaces.getSurface(id) first when finer-grained error
    ///     reporting is wanted.)
    ///   - If peer_uid matches the daemon's configured privileged
    ///     uid (SEMADRAW_PRIVILEGED_UID), allow. Privileged
    ///     clients can modify any surface, including daemon-owned
    ///     surfaces like the cursor.
    ///   - Otherwise, allow iff peer_uid == surface.owner_uid.
    ///
    /// NOBODY_UID is never privileged (isPrivilegedUid enforces
    /// this); TCP connections matching their own
    /// owner_uid=NOBODY_UID surfaces is the intended posture for
    /// AD-31.3 + ADR §6, however, and is the natural consequence
    /// of the uniform check.
    fn canModifySurface(self: *Daemon, surface_id: protocol.SurfaceId, peer_uid: posix.uid_t) bool {
        const surface = self.surfaces.getSurface(surface_id) orelse return false;
        if (privilege.isPrivilegedUid(peer_uid, self.privileged_uid)) return true;
        return peer_uid == surface.owner_uid;
    }

    /// AD-21 sub-item 3: create the daemon-owned cursor surface per
    /// ADR 0005 sections 1, 2, 3, and 6.
    ///
    /// The cursor is one daemon-owned surface (owner =
    /// CLIENT_ID_DAEMON) with a fixed 24×24 logical size, holding
    /// the default arrow sprite (semadraw/src/daemon/cursor_arrow.sdcs,
    /// generated by sdcs_make_cursor and embedded via @embedFile).
    /// Z-order is Z_ORDER_CURSOR, above the entire client range,
    /// which is enforced by the client-side clamp in handleSetZOrder
    /// and handleRemoteSetZOrder (sub-item 2). Hotspot is at
    /// pixel (0, 0): the arrow tip is the top-left corner.
    ///
    /// Initial position is (0, 0); the position pump (sub-item 5,
    /// not yet landed) updates it each composition cycle from the
    /// inputfs pointer position. The surface is visible by default;
    /// the visibility toggle (sub-item 8) hides it when geometry is
    /// unknown and the pointer is outside the framebuffer area.
    ///
    /// Failure to create the cursor surface is non-fatal: the
    /// daemon continues without a visible cursor and logs a warning.
    /// The cursor_surface_id field stays null; the position pump
    /// and SET_CURSOR handler are no-ops in that case.
    fn initCursorSurface(self: *Daemon) !void {
        // Embedded sprite bytes. Generated offline by
        // tools/sdcs_make_cursor and checked in. The build does
        // NOT regenerate this; re-run sdcs_make_cursor manually
        // after a sprite design change.
        const cursor_sdcs = @embedFile("cursor_arrow.sdcs");

        // AD-31.3 part 2: cursor surface is daemon-owned. Its
        // owner_uid is the daemon's runtime uid (`_semadraw` in
        // production, or the operator's uid in development mode).
        // No ordinary client will match this; the privileged
        // client (e.g. pgsd-sessiond) does match by virtue of the
        // privileged-bypass in canModifySurface.
        const surface = try self.surfaces.createSurface(
            protocol.CLIENT_ID_DAEMON,
            self.run_uid,
            24, // logical_width  - matches sprite dimensions
            24, // logical_height
        );

        try self.surfaces.attachInlineBuffer(surface.id, cursor_sdcs);
        try self.surfaces.setZOrder(surface.id, protocol.Z_ORDER_CURSOR);
        try self.surfaces.setHotspot(surface.id, 0, 0);
        try self.surfaces.setVisible(surface.id, true);

        // Initial position (0, 0). The position pump (sub-item 5)
        // updates this each composition cycle once it lands. Until
        // then the cursor sits at the top-left, which is acceptable
        // for verifying that the surface actually renders.
        try self.surfaces.setPosition(surface.id, 0, 0);

        // Mark the cursor surface for full damage so the first
        // composition cycle renders it. attachInlineBuffer alone
        // doesn't trigger compositor damage; clients normally
        // damage explicitly via the commit path. The cursor
        // surface bypasses that path (no client commit), so the
        // daemon damages it directly here.
        self.comp.damageSurface(surface.id) catch |err| {
            // Non-fatal: the cursor will appear once any other
            // surface triggers a full repaint, which happens
            // soon enough during normal compositor activity.
            log.warn("cursor initial damage mark failed: {}", .{err});
        };

        self.cursor_surface_id = surface.id;
        log.info("cursor surface created: id={} z={} hotspot=(0,0) size=24x24", .{
            surface.id, protocol.Z_ORDER_CURSOR,
        });
    }

    /// AD-24: reset the cursor surface to the embedded default sprite.
    ///
    /// Used by pumpCursorFocus when a previous SET_CURSOR custom
    /// sprite needs to be replaced because the focused client has
    /// gone away (no client surface visible). Mirrors the operations
    /// that initCursorSurface performs on the cursor surface, plus
    /// what handleSetCursor does in reverse: re-attach the default
    /// SDCS buffer, restore hotspot to (0, 0), restore logical size
    /// to 24x24, and damage the cursor surface so the next composite
    /// picks up the new sprite.
    ///
    /// No-op when the cursor surface was never created
    /// (initCursorSurface failed), caller should also guard this
    /// case for clarity, but the early-out keeps the helper
    /// self-contained.
    ///
    /// Updates self.cursor_is_default = true on completion.
    fn resetCursorToDefault(self: *Daemon) void {
        const cursor_id = self.cursor_surface_id orelse return;

        // Same embedded buffer as initCursorSurface. attachInlineBuffer
        // copies the bytes; the surface owns the copy and frees the
        // previous buffer. Bytes never change at runtime, so a fresh
        // @embedFile here yields the same data the daemon started
        // with.
        const cursor_sdcs = @embedFile("cursor_arrow.sdcs");

        self.surfaces.attachInlineBuffer(cursor_id, cursor_sdcs) catch |err| {
            // Non-fatal: the cursor stays at the previous (custom)
            // sprite for now. Logged so operators can see when the
            // reset failed; the next focus-loss tick will retry.
            log.warn("AD-24: resetCursorToDefault attachInlineBuffer failed: {}", .{err});
            return;
        };
        self.surfaces.setHotspot(cursor_id, 0, 0) catch {};
        self.surfaces.setLogicalSize(cursor_id, 24.0, 24.0) catch {};

        // Mark damage so the next composite picks up the new sprite.
        // Without this, the cursor would only re-render on the next
        // pointer move (when the position pump damages it).
        self.comp.damageSurface(cursor_id) catch |err| {
            log.warn("AD-24: resetCursorToDefault damageSurface failed: {}", .{err});
        };

        self.cursor_is_default = true;
        log.debug("AD-24: cursor surface reset to default sprite", .{});
    }

    /// AD-24: focus-loss cursor reset.
    ///
    /// Called once per main-loop iteration alongside
    /// pumpCursorPosition. Cheap on the no-change path: one list walk
    /// inside getTopVisibleSurface plus an optional compare. Allocations:
    /// zero.
    ///
    /// Per ADR 0005 §5: when focus changes from a client surface to
    /// null (no client surface visible), reset the cursor to the
    /// default sprite. When focus changes between client surfaces,
    /// do NOT reset, the new focused client must SET_CURSOR if it
    /// wants something non-default. When focus stays the same, no-op.
    ///
    /// State machine over (last_top, current_top):
    ///   (null,    null)    : no-op
    ///   (null,    Some(B)) : no-op (B may SET_CURSOR if it wants)
    ///   (Some(A), Some(A)) : no-op (no transition)
    ///   (Some(A), Some(B)) : no-op per ADR §5 (B's call)
    ///   (Some(A), null)    : RESET if cursor_is_default == false
    ///
    /// The `cursor_is_default` guard avoids redundantly re-attaching
    /// the default sprite on consecutive null-focus ticks (e.g. while
    /// no client is connected).
    fn pumpCursorFocus(self: *Daemon) void {
        const current_top = self.surfaces.getTopVisibleSurface();
        defer self.last_top_surface = current_top;

        // Only the focus-X → null transition triggers a reset.
        const lost_focus = self.last_top_surface != null and current_top == null;
        if (!lost_focus) return;

        // Already at default, nothing to do. Avoids redundant
        // attachInlineBuffer / damageSurface calls on every tick
        // while no client is connected.
        if (self.cursor_is_default) return;

        self.resetCursorToDefault();
    }

    /// AD-21 sub-items 5 and 8: position pump and visibility toggle.
    ///
    /// Called once per main-loop iteration before comp.needsComposite().
    /// Reads the latest pointer position from the inputfs state region,
    /// computes the cursor surface's new top-left as
    /// (pointer - hotspot), and if either the position or visibility
    /// differs from the last cycle:
    ///
    ///   1. Marks the cursor surface for full damage (when it'll be
    ///      visible after this cycle) so the cursor itself re-renders
    ///      at the new spot.
    ///   2. Walks every visible surface with z_order < Z_ORDER_CURSOR
    ///      and adds damage where the surface bounds intersect either
    ///      the displayed_old_rect or the displayed_new_rect,
    ///      "displayed" meaning the geometric rect when the cursor is
    ///      visible at that point, empty when not. Recorded in
    ///      surface-local coords for forward compatibility with damage-
    ///      aware compositing. (v1's compositor re-renders any damaged
    ///      surface fully, so the rect content is bookkeeping; the
    ///      forward-compatible thing is to record it correctly.)
    ///   3. Calls setVisible on the cursor surface if visibility
    ///      changed (per ADR 0005 section 7), then setPosition with
    ///      the new x, y. Position is updated even when invisible so
    ///      the surface is at the right spot when it next becomes
    ///      visible.
    ///
    /// Visibility (sub-item 8): the cursor surface is visible iff the
    /// raw pointer coordinates fall inside [0, fb_width) × [0, fb_height).
    /// When inputfs has geometry (the normal case), its clamp keeps
    /// the pointer in range and the cursor stays visible; this branch
    /// only matters during the brief boot window when drawfs is
    /// absent at module load and the inputfs accumulator runs
    /// unclamped. Per ADR 0005 sections 1 and 7.
    ///
    /// All steps are no-ops if any of the following hold:
    ///   - The cursor surface was never created (cursor_surface_id null
    ///     because initCursorSurface failed).
    ///   - No pointer.motion event has been observed yet
    ///     (last_motion_seen == false). The pump waits for the first
    ///     event-ring motion before doing any work; before that there
    ///     is no known cursor position to render.
    ///
    /// AD-36: position comes from `last_motion_x, last_motion_y`,
    /// updated by the main loop's inputfs_events scan whenever a
    /// pointer.motion event is published. The previous AD-21 design
    /// read position from the inputfs state region via
    /// `StateReader.pointerSnapshot()`, but that mmap exhibits the
    /// AD-34 staleness bug for non-root processes. The event ring
    /// works correctly for `_semadraw`; see ADR 0008.
    ///
    /// Fast path: if the cursor was invisible last cycle and is still
    /// invisible this cycle, only the recorded position is updated;
    /// no damage walking is performed (nothing to repaint underneath
    /// an invisible cursor).
    ///
    /// The pump is called every loop iteration regardless of socket
    /// activity, so it must be cheap on the no-change path. Cost
    /// breakdown when pointer hasn't moved: one optional bool check
    /// (last_motion_seen), three field reads, and a handful of f32
    /// compares. No syscalls. Allocations: zero.
    fn pumpCursorPosition(self: *Daemon) void {
        const cursor_id = self.cursor_surface_id orelse return;

        // AD-36: read the current pointer position from
        // last_motion_x/y rather than from the state-region mmap.
        // The main loop updates these from inputfs event-ring
        // motion events; see the pointer.motion harvest in run().
        // When no motion event has been observed yet, the pump has
        // no known position and skips this cycle, emitting a
        // pump_diagnostic with state_valid=false so the AD-25
        // Round 1 cadence analysis can still distinguish "pump ran
        // but no data" from "pump didn't run."
        if (!self.last_motion_seen) {
            if (self.pump_instrument) {
                events.emitPumpDiagnostic(false, false, false, 0, 0);
            }
            return;
        }

        // Synthetic ps with the just-read motion coordinates. The
        // rest of the function uses ps.x and ps.y exactly as the
        // pre-AD-36 code did with the state-region snapshot. Buttons
        // are not consumed here (cursor pump cares only about
        // position and visibility).
        const ps = input.PointerState{
            .x = self.last_motion_x,
            .y = self.last_motion_y,
            .buttons = 0,
        };

        // Compute the new cursor surface position. The hotspot lives
        // on the surface struct; for the default sprite it's (0, 0),
        // but a future SET_CURSOR could change it.
        const surf = self.surfaces.getSurface(cursor_id) orelse return;
        const new_x: f32 = @as(f32, @floatFromInt(ps.x)) - @as(f32, @floatFromInt(surf.hotspot_x));
        const new_y: f32 = @as(f32, @floatFromInt(ps.y)) - @as(f32, @floatFromInt(surf.hotspot_y));

        // AD-21 sub-item 8: visibility based on whether the pointer is
        // inside the daemon's idea of the framebuffer area, per ADR
        // 0005 section 7. This only matters when geometry is unknown
        // to inputfs (no clamp active); when geometry is known, the
        // inputfs clamp guarantees ps.x/ps.y stay in range and the
        // cursor stays visible.
        //
        // Test on the raw pointer coords (NOT the cursor surface's
        // top-left), per ADR §7 wording: "either coordinate is outside
        // the daemon's idea of the framebuffer area." Range is the
        // half-open interval [0, fb_width) × [0, fb_height); pixel
        // (fb_width-1, fb_height-1) is the bottom-right valid pixel.
        //
        // Source the dimensions from the compositor's active output,
        // not from self.config: the compositor overrides its
        // configured dimensions with the backend-reported native
        // display size when the two differ (per AD-17, see
        // compositor.initOutput). self.config retains the originally-
        // requested dimensions, which are stale once the override
        // fires. Surfaced during AD-21 sub-item 9 bare-metal
        // verification: with self.config = 1920x1080 (the daemon
        // default) and the actual framebuffer at 3840x2160, the
        // visibility check flipped to false at x>=1920 or y>=1080
        // and the cursor disappeared mid-screen.
        const dims = self.comp.outputDimensions() orelse {
            // No output yet (initOutput failed or hasn't run).
            // Skip the visibility check this cycle; the cursor stays
            // at its previous visibility state. The pump should
            // never reach here in practice, initCompositor calls
            // initOutput before initCursorSurface, so by the time
            // the pump runs an output exists.
            return;
        };
        const fb_w: i32 = @intCast(dims.width);
        const fb_h: i32 = @intCast(dims.height);
        const should_be_visible: bool =
            ps.x >= 0 and ps.x < fb_w and
            ps.y >= 0 and ps.y < fb_h;

        // Change detection: skip if neither position nor visibility
        // changed. On the first call, last_cursor_pos_set is false so
        // the position branch fires.
        const pos_changed: bool =
            !self.last_cursor_pos_set or
            new_x != self.last_cursor_pos_x or
            new_y != self.last_cursor_pos_y;
        const vis_changed: bool = should_be_visible != self.last_cursor_visible;

        // AD-25 Round 1 (ADR 0007): emit one pump_diagnostic per
        // invocation that reaches the change-detection point. Fires
        // regardless of whether the change-detection short-circuits
        // below, so the analysis can see pump cadence including the
        // no-change-this-iteration cases. state_valid is true here
        // because we got past the last_motion_seen check above
        // (AD-36 reframes this: state_valid now means "the pump has
        // a known current pointer position from the event ring,"
        // rather than the pre-AD-36 sense "the state region mmap was
        // populated and readable"). AD-34 E1: ps.x and ps.y carry
        // the raw integer coordinates from the most recent
        // pointer.motion event payload, so the analysis can still
        // distinguish "pump sees same value repeatedly" from "pump
        // sees varying values but pos_changed misses the change."
        if (self.pump_instrument) {
            events.emitPumpDiagnostic(pos_changed, vis_changed, true, ps.x, ps.y);
        }

        if (!pos_changed and !vis_changed) return;

        // Fast path: cursor was invisible last cycle and is still
        // invisible. No damage to propagate; just record the new
        // position so a future visible→invisible transition has the
        // right "old" reference. (last_cursor_pos_set must be set to
        // true so subsequent transitions compute old_rect from the
        // recorded coords rather than treating them as uninitialised.)
        if (!self.last_cursor_visible and !should_be_visible) {
            self.last_cursor_pos_x = new_x;
            self.last_cursor_pos_y = new_y;
            self.last_cursor_pos_set = true;
            // last_cursor_visible already false; no toggle needed.
            return;
        }

        // Geometric old/new cursor rects in framebuffer coordinates.
        // Sprite's logical_width/height defines the bounding box.
        const cw: u32 = @intFromFloat(@max(0.0, surf.logical_width));
        const ch: u32 = @intFromFloat(@max(0.0, surf.logical_height));

        // The "displayed" rects, what was/will-be actually painted to
        // the screen, are the geometric rects when visible, empty
        // when not. Damage walking only intersects against displayed
        // rects, since invisible cursor positions don't dirty anything
        // underneath.
        const displayed_old_rect: damage.Rect =
            if (self.last_cursor_pos_set and self.last_cursor_visible) .{
                .x = @intFromFloat(self.last_cursor_pos_x),
                .y = @intFromFloat(self.last_cursor_pos_y),
                .width = cw,
                .height = ch,
            } else damage.Rect.empty();

        const displayed_new_rect: damage.Rect = if (should_be_visible) .{
            .x = @intFromFloat(new_x),
            .y = @intFromFloat(new_y),
            .width = cw,
            .height = ch,
        } else damage.Rect.empty();

        // Step 1: damage the cursor surface itself so it re-renders
        // (when it'll be visible). Marking damage on a surface
        // that's about to become invisible is harmless, invisible
        // surfaces don't render, but we only mark when the cursor
        // will actually appear on the next composite to keep the
        // damage tracker tight.
        if (should_be_visible) {
            self.comp.damageSurface(cursor_id) catch |err| {
                log.warn("cursor pump: damageSurface failed: {}", .{err});
                // Continue anyway; the position update is still useful.
            };
        }

        // Step 2: propagate damage to underlying surfaces. Walk the
        // composition order and mark damage on any visible surface
        // beneath the cursor (z_order < Z_ORDER_CURSOR) whose bounds
        // intersect displayed_old_rect or displayed_new_rect.
        const order = self.surfaces.getCompositionOrder() catch &[_]*surface_registry.Surface{};
        for (order) |s| {
            if (s.id == cursor_id) continue;
            if (s.z_order >= protocol.Z_ORDER_CURSOR) continue;

            const sw: u32 = @intFromFloat(@max(0.0, s.logical_width));
            const sh: u32 = @intFromFloat(@max(0.0, s.logical_height));
            const surf_rect: damage.Rect = .{
                .x = @intFromFloat(s.position_x),
                .y = @intFromFloat(s.position_y),
                .width = sw,
                .height = sh,
            };

            // Compute intersection with each displayed cursor rect;
            // record in surface-local coords (subtract surface
            // position from intersection's framebuffer coords).
            // Empty rects (from invisibility or first pump) skip
            // naturally via cursor_rect.isEmpty().
            const cursor_rects = [_]damage.Rect{ displayed_old_rect, displayed_new_rect };
            for (cursor_rects) |cursor_rect| {
                if (cursor_rect.isEmpty()) continue;
                const isect = surf_rect.intersection(cursor_rect);
                if (isect.isEmpty()) continue;

                const local_rect: damage.Rect = .{
                    .x = isect.x - @as(i32, @intFromFloat(s.position_x)),
                    .y = isect.y - @as(i32, @intFromFloat(s.position_y)),
                    .width = isect.width,
                    .height = isect.height,
                };
                self.comp.damageRegion(s.id, local_rect) catch |err| {
                    log.warn("cursor pump: damageRegion(surface {}) failed: {}", .{ s.id, err });
                };
            }
        }

        // Step 2.5 (AD-21 sub-item 9 / region damage): emit output
        // region damage for the cursor's displayed old and new rects.
        // The surface-damage walk above handles the case where a
        // client surface lives under the cursor: that surface
        // re-renders and overwrites the cursor's old pixels with its
        // own content. But when no surface covers the cursor's old
        // rect (e.g. cursor was on the framebuffer background, no
        // client present, or only the cursor-surface itself was at
        // that location), the surface walk has nothing to mark, and
        // the old cursor pixels would persist on screen. Output
        // region damage tells the compositor to clear those pixels
        // to the framebuffer background colour at the start of the
        // next composite cycle, before any surface renders. The two
        // damage paths are complementary, not redundant, one
        // catches surfaces, the other catches the no-surface gaps.
        const output_rects = [_]damage.Rect{ displayed_old_rect, displayed_new_rect };
        for (output_rects) |orect| {
            if (orect.isEmpty()) continue;
            self.comp.damageOutputRegion(orect) catch |err| {
                log.warn("cursor pump: damageOutputRegion failed: {}", .{err});
            };
        }

        // Step 3: apply state changes. Per ADR §4 ordering: damage
        // propagation runs BEFORE the position/visibility change so
        // underlying surfaces are damaged for both old AND new
        // displayed rects before the cursor moves or hides/shows.
        if (vis_changed) {
            self.surfaces.setVisible(cursor_id, should_be_visible) catch |err| {
                log.warn("cursor pump: setVisible failed: {}", .{err});
            };
        }

        // Position is always updated (even when invisible) so the
        // surface is at the right spot whenever it next becomes
        // visible. setPosition is a cheap field write.
        self.surfaces.setPosition(cursor_id, new_x, new_y) catch |err| {
            log.warn("cursor pump: setPosition failed: {}", .{err});
            return;
        };

        self.last_cursor_pos_x = new_x;
        self.last_cursor_pos_y = new_y;
        self.last_cursor_pos_set = true;
        self.last_cursor_visible = should_be_visible;
    }

    /// Initialize compositor (must be called after init, before run)
    pub fn initCompositor(self: *Daemon) !void {
        self.comp = compositor.Compositor.init(self.allocator, &self.surfaces);

        // Install the audio hardware clock for drift-free scheduling.
        // Non-fatal: if the clock writer (audiofs, ADR 0018) is absent the compositor falls back to
        // the wall clock automatically.
        self.comp.setChronofsClockPath("/var/run/sema/clock");

        // Initialize output with configured resolution
        try self.comp.initOutput(0, .{
            .width = self.config.width,
            .height = self.config.height,
            .format = .rgba8,
            .refresh_hz = 60,
            .backend_type = self.config.backend_type,
        });

        // AD-2a Phase 2.4.3: bring up the gesture recogniser after
        // the compositor's error-prone initOutput step but before
        // the compositor starts. The library holds allocator-borrowed
        // std.ArrayList state that .init() leaves empty and
        // .deinit() (in Daemon.deinit) releases. No IO; no error
        // path; cannot fail.
        self.gesture_recognizer = libsemainput.GestureRecognizer.init(self.allocator);

        // AD-21 sub-item 3: create the daemon-owned cursor surface.
        // Non-fatal on failure; the daemon continues without a cursor.
        self.initCursorSurface() catch |err| {
            log.warn("cursor surface init failed: {}; continuing without cursor", .{err});
        };

        // Start compositor for composition loop
        self.comp.start();
    }

    pub fn deinit(self: *Daemon) void {
        // Clean up remote clients
        var iter = self.remote_clients.valueIterator();
        while (iter.next()) |session_ptr| {
            const session = session_ptr.*;
            if (session.sdcs_buffer) |buf| self.allocator.free(buf);
            session.client.close();
            self.allocator.destroy(session);
        }
        self.remote_clients.deinit();

        // AD-2a Phase 2.4.3: deinit the recogniser before the
        // compositor (reverse-init order). Releases the four
        // allocator-borrowed ArrayLists. Same contract as comp:
        // only valid after a successful initCompositor.
        self.gesture_recognizer.deinit();

        self.comp.deinit();
        self.surfaces.deinit();
        self.clients.deinit();
        if (self.tcp) |*tcp| tcp.deinit();
        self.server.deinit();
    }

    /// Main event loop using poll()
    pub fn run(self: *Daemon) !void {
        self.running = true;
        log.info("semadrawd starting on {s}", .{self.config.socket_path});
        if (self.tcp) |tcp| {
            log.info("TCP server listening on port {}", .{tcp.port});
        }

        // Poll fd array: [0] = server, [1] = tcp (optional), [...] = clients
        var poll_fds: std.ArrayListUnmanaged(PollFd) = .{};
        defer poll_fds.deinit(self.allocator);

        while (self.running) {
            // Rebuild poll fd list
            poll_fds.clearRetainingCapacity();

            // Add Unix socket server
            try poll_fds.append(self.allocator, .{
                .fd = self.server.getFd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            });

            // Add TCP server if enabled
            const tcp_fd: ?posix.fd_t = if (self.tcp) |tcp| tcp.getFd() else null;
            if (tcp_fd) |fd| {
                try poll_fds.append(self.allocator, .{
                    .fd = fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                });
            }

            // Add local client sockets
            var client_iter = self.clients.iterator();
            while (client_iter.next()) |session| {
                try poll_fds.append(self.allocator, .{
                    .fd = session.*.getFd(),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                });
            }

            // Add remote client sockets
            var remote_iter = self.remote_clients.valueIterator();
            while (remote_iter.next()) |session_ptr| {
                try poll_fds.append(self.allocator, .{
                    .fd = session_ptr.*.getFd(),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                });
            }

            // The backend's own pollable fd (/dev/draw for drawfs) is
            // DELIBERATELY NOT in the poll set (AD-32/AD-37 closure,
            // 2026-06-06). It sat here as an acknowledged no-op after
            // AD-2a removed its input-source role, "reserved for future
            // backend-side events". That reservation was the busy-spin:
            // drawfs_poll is correct level-triggered code (POLLIN while
            // the session's event queue is non-empty), the daemon's own
            // presents enqueue PRESENTED events at the animating
            // client's rate, nothing in this loop drained them, so poll
            // returned instantly forever (~32k iterations/s measured,
            // ~200k instrument lines/s, one-second log rotation).
            // A polled fd MUST come with a dispatch-path drain handler:
            // when backend-side events (display hotplug, output
            // reconfig) actually exist, re-add the fd HERE together
            // with its handler in the revents loop below, never one
            // without the other.

            // ADR 0009: the input wake descriptor is the kqueue
            // BRIDGE fd, not the raw notify cdev fd. The cdev's
            // d_poll is edge-only and can never deliver POLLIN
            // through poll(2): selwakeup from a publish triggers a
            // kernel rescan, d_poll returns 0 again by construction,
            // and the kernel sleeps out the remaining timeout. Round
            // U1 measured the consequence to the millisecond (gaps
            // of 100.9 to 107.3 ms under 130 Hz motion, zero early
            // wakes); the previous version of this comment claimed
            // event-rate iteration and was wrong for the entire life
            // of the direct-membership design. The backend now
            // registers the notify fd in a kqueue (EVFILT_READ,
            // EV_CLEAR, the cdev's kqueue path being the one that
            // reports readiness correctly) and returns the kqueue's
            // own descriptor, which IS pollable. Dispatch below must
            // drain the kevent on POLLIN (drainInputWake) per the
            // AD-32 rule, or the fd stays readable and the loop
            // spins. Null when the bridge is absent: poll-timeout
            // cadence, the pre-ADR-0009 behaviour.
            const input_wake_fd: ?posix.fd_t = self.comp.getInputfsPollFd();
            if (input_wake_fd) |fd| {
                try poll_fds.append(self.allocator, .{
                    .fd = fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                });
            }

            // Wait for events. 100ms timeout bounds how often we re-check
            // periodic tasks (composition scheduling, clipboard polling)
            // when nothing else is happening. Input responsiveness does
            // not depend on this timeout when the ADR 0009 wake bridge
            // is active (see input_wake_fd above); without the bridge
            // this timeout IS the input cadence. See AD-41.5 for the separate
            // diagnosis of why the timeout fires below its documented
            // 10 Hz rate.
            const poll_slice: []posix.pollfd = @ptrCast(poll_fds.items);
            const n = posix.poll(poll_slice, 100) catch |err| {
                log.err("poll error: {}", .{err});
                continue;
            };

            // Poll backend events (keyboard, window close, etc.)
            if (!self.comp.pollEvents()) {
                log.info("backend requested shutdown", .{});
                self.running = false;
                break;
            }

            // Forward keyboard events to focused surface's client
            const key_events = self.comp.getKeyEvents();
            if (key_events.len > 0) {
                self.forwardKeyEvents(key_events);
            }

            // Forward mouse events to focused surface's client
            const mouse_events = self.comp.getMouseEvents();
            if (mouse_events.len > 0) {
                self.forwardMouseEvents(mouse_events);
            }

            // AD-2a Phase 2.4.4: feed raw inputfs events into the
            // gesture recogniser via the side-channel buffer added
            // in Phase 2.4.2. The drawfs backend captures every
            // drained input.Event before the typed-event dispatch
            // path drops touch and pen events, so multi-touch
            // gestures (pinch, two-finger scroll, three-finger
            // swipe) reach the recogniser even though they have no
            // KeyEvent/MouseEvent translation.
            //
            // Each event's chronofs ns timestamp is captured into
            // self.last_input_ts_ns so Phase 2.4.5's
            // forwardGestureEvents can attach it to outgoing
            // GestureEventMsg as t_current.
            //
            // After the batch is fed, drain any gesture outputs the
            // recogniser produced and forward them. forwardGesture
            // Events is a stub in this commit (Phase 2.4.4); its
            // body lands in Phase 2.4.5.
            const inputfs_events = self.comp.getInputfsEvents();
            if (inputfs_events.len > 0) {
                for (inputfs_events) |ev| {
                    self.last_input_ts_ns = ev.ts_ordering;

                    // AD-36: harvest the latest pointer.motion event's
                    // absolute coordinates for pumpCursorPosition to
                    // consume. Iteration order is publication order
                    // per shared/INPUT_EVENTS.md, so the last
                    // POINTER_MOTION in the batch is the freshest
                    // known pointer position. Touch-synthesised motion
                    // (flags & FLAG_SYNTHESISED) is intentionally not
                    // filtered out: touch acting as a pointer should
                    // move the cursor the same as native mouse motion.
                    // Payload layout per shared/INPUT_EVENTS.md and
                    // inputfs/sys/dev/inputfs/inputfs.c line 3411:
                    // x i32 LE @ 0, y i32 LE @ 4, dx @ 8, dy @ 12,
                    // buttons u32 @ 16, session u32 @ 20.
                    if (ev.source_role == input.SOURCE_POINTER and
                        ev.event_type == input.POINTER_MOTION) {
                        self.last_motion_x = std.mem.readInt(i32, ev.payload[0..4], .little);
                        self.last_motion_y = std.mem.readInt(i32, ev.payload[4..8], .little);
                        self.last_motion_seen = true;
                    }

                    if (translateInputfsEvent(ev)) |lib_in| {
                        self.gesture_recognizer.handleEvent(lib_in) catch |err| {
                            log.warn("gesture_recognizer.handleEvent failed: {}", .{err});
                            // Continue: a single failed event shouldn't
                            // kill the loop. Errors here are
                            // OutOfMemory from ArrayList.append.
                        };
                    }
                }
                // Drain everything the recogniser produced this batch
                // and forward.
                while (self.gesture_recognizer.nextOutput()) |out| {
                    self.forwardGestureEvents(out, self.last_input_ts_ns);
                }
            }

            // Check for pending clipboard responses
            self.checkPendingClipboard();

            // Process socket events if any
            if (n > 0) {
                for (poll_fds.items) |*pfd| {
                    if (pfd.revents == 0) continue;

                    if (pfd.fd == self.server.getFd()) {
                        // New local client connection
                        self.handleNewConnection() catch |err| {
                            log.warn("failed to accept local connection: {}", .{err});
                        };
                    } else if (tcp_fd != null and pfd.fd == tcp_fd.?) {
                        // New remote client connection
                        self.handleNewRemoteConnection() catch |err| {
                            log.warn("failed to accept remote connection: {}", .{err});
                        };
                    } else if (input_wake_fd != null and pfd.fd == input_wake_fd.?) {
                        // ADR 0009: consume the kevent so EV_CLEAR
                        // re-arms and the kqueue fd's readiness
                        // clears. The event-ring harvest itself runs
                        // in the per-pass path below (getInputfsEvents
                        // and the pump); this branch only clears the
                        // wake.
                        self.comp.drainInputWake();
                    } else if (self.clients.findByFd(pfd.fd)) |session| {
                        // Local client event.
                        //
                        // Stash session.id locally because either branch
                        // below can destroy `session` via disconnectClient
                        // (which calls clients.destroySession → allocator.destroy).
                        // POLL.IN | POLL.HUP can both be set in the same
                        // revents (common when the client closes its end
                        // of the socket, kernel reports any pending
                        // readable data AND the hangup), and the second
                        // branch must not dereference a freed session.
                        const sid = session.id;
                        var disconnected = false;
                        if (pfd.revents & std.posix.POLL.IN != 0) {
                            self.handleClientMessage(session) catch |err| {
                                log.debug("client {} error: {}, disconnecting", .{ sid, err });
                                self.disconnectClient(sid);
                                disconnected = true;
                            };
                        }
                        if (!disconnected and pfd.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                            log.debug("client {} disconnected", .{sid});
                            self.disconnectClient(sid);
                        }
                    } else if (self.findRemoteByFd(pfd.fd)) |session| {
                        // Remote client event. Same lifecycle hazard as
                        // the local branch above; see comment there.
                        const sid = session.id;
                        var disconnected = false;
                        if (pfd.revents & std.posix.POLL.IN != 0) {
                            self.handleRemoteClientMessage(session) catch |err| {
                                log.debug("remote client {} error: {}, disconnecting", .{ sid, err });
                                self.disconnectRemoteClient(sid);
                                disconnected = true;
                            };
                        }
                        if (!disconnected and pfd.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                            log.debug("remote client {} disconnected", .{sid});
                            self.disconnectRemoteClient(sid);
                        }
                    }
                }
            }

            // AD-21 sub-item 5: drive the cursor surface from the
            // inputfs pointer position. Runs every loop iteration;
            // the no-change path is cheap (one atomic load + a few
            // f32 compares). Marks damage on the cursor and on
            // underlying surfaces under both old and new cursor
            // rects, so the next composite call below picks the
            // damage up.
            self.pumpCursorPosition();

            // AD-24: detect focus loss and reset the cursor to the
            // default sprite when the last focused client goes away.
            // Cheap on the no-change path: one list walk inside
            // getTopVisibleSurface plus an optional compare.
            self.pumpCursorFocus();

            // Perform composition if needed (always check, regardless of socket events)
            if (self.comp.needsComposite()) {
                if (self.comp.composite()) |result| {
                    events.emitFrameComplete(
                        0, // compositor-driven frames are not surface-specific
                        result.frame_number,
                        "software",
                        result.target_audio_samples,
                    );
                } else |err| {
                    log.warn("composite failed: {}", .{err});
                }
            }
        }

        log.info("semadrawd shutting down", .{});
    }

    fn findRemoteByFd(self: *Daemon, fd: posix.fd_t) ?*RemoteSession {
        var iter = self.remote_clients.valueIterator();
        while (iter.next()) |session_ptr| {
            if (session_ptr.*.getFd() == fd) return session_ptr.*;
        }
        return null;
    }

    fn handleNewRemoteConnection(self: *Daemon) !void {
        var tcp = self.tcp orelse return;
        const remote_client = try tcp.accept();

        const total_clients = self.clients.count() + self.remote_clients.count();
        if (total_clients >= self.config.max_clients) {
            log.warn("max clients reached, rejecting remote connection", .{});
            var client = remote_client;
            client.close();
            return;
        }

        const session = try self.allocator.create(RemoteSession);
        session.* = .{
            .client = remote_client,
            .id = self.next_remote_id,
            .state = .awaiting_hello,
            // AD-31.2 / ADR 0006 §2: TCP gets the NOBODY sentinels.
            .peer_uid = privilege.NOBODY_UID,
            .peer_gid = privilege.NOBODY_GID,
            .sdcs_buffer = null,
        };
        self.next_remote_id += 1;

        try self.remote_clients.put(session.id, session);

        const addr_str = session.client.getAddrString();
        log.info("remote client {} connected from {s} (peer uid={d} [NOBODY])", .{ session.id, std.mem.sliceTo(&addr_str, 0), session.peer_uid });
    }

    fn handleRemoteClientMessage(self: *Daemon, session: *RemoteSession) !void {
        var msg = try session.client.readMessage(self.allocator) orelse return;
        defer msg.deinit(self.allocator);

        switch (session.state) {
            .awaiting_hello => {
                if (msg.header.msg_type != .hello) {
                    try self.sendRemoteError(session, .protocol_error, 0);
                    return error.ProtocolError;
                }
                try self.handleRemoteHello(session, msg.payload);
            },
            .connected => {
                try self.handleRemoteRequest(session, msg.header.msg_type, msg.payload);
            },
            .disconnecting => {},
        }
    }

    fn handleRemoteHello(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.HelloMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return error.InvalidPayload;
        }

        const hello = try protocol.HelloMsg.deserialize(payload.?);

        if (hello.version_major != protocol.PROTOCOL_VERSION_MAJOR) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return error.VersionMismatch;
        }

        var reply_buf: [protocol.HelloReplyMsg.SIZE]u8 = undefined;
        const reply = protocol.HelloReplyMsg{
            .version_major = protocol.PROTOCOL_VERSION_MAJOR,
            .version_minor = protocol.PROTOCOL_VERSION_MINOR,
            .client_id = session.id,
            .server_flags = 1, // Flag 1 = remote connection (inline buffers)
        };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.hello_reply, &reply_buf);

        session.state = .connected;
        log.info("remote client {} completed handshake", .{session.id});
        events.emitClientConnected(session.id, hello.version_major, hello.version_minor, session.peer_uid);
    }

    fn handleRemoteRequest(self: *Daemon, session: *RemoteSession, msg_type: protocol.MsgType, payload: ?[]u8) !void {
        switch (msg_type) {
            .create_surface => try self.handleRemoteCreateSurface(session, payload),
            .destroy_surface => try self.handleRemoteDestroySurface(session, payload),
            .attach_buffer_inline => try self.handleRemoteAttachBufferInline(session, payload),
            .commit => try self.handleRemoteCommit(session, payload),
            .set_visible => try self.handleRemoteSetVisible(session, payload),
            .set_z_order => try self.handleRemoteSetZOrder(session, payload),
            .set_position => try self.handleRemoteSetPosition(session, payload),
            .set_cursor => try self.handleRemoteSetCursor(session, payload),
            .sync => try self.handleRemoteSync(session, payload),
            .output_info_request => try self.handleRemoteOutputInfoRequest(session, payload),
            .idle_query => try self.handleRemoteIdleQuery(session, payload),
            .disconnect => {
                session.state = .disconnecting;
            },
            else => {
                log.warn("remote client {} sent unexpected message type: {}", .{ session.id, msg_type });
                try self.sendRemoteError(session, .invalid_message, 0);
            },
        }
    }

    fn handleRemoteCreateSurface(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.CreateSurfaceMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.CreateSurfaceMsg.deserialize(payload.?);

        // AD-31.3 part 2: TCP connections have peer_uid =
        // NOBODY_UID per ADR 0006 §2, so surfaces created over TCP
        // get owner_uid = NOBODY_UID. canModifySurface (below)
        // will not match NOBODY_UID against any real client's
        // peer_uid; cross-connection modify of a TCP-created
        // surface is blocked. This is the intended ADR posture.
        const surface = self.surfaces.createSurface(session.id, session.peer_uid, msg.logical_width, msg.logical_height) catch {
            try self.sendRemoteError(session, .resource_limit, 0);
            return;
        };

        self.comp.onSurfaceCreated(surface.id) catch {};

        var reply_buf: [protocol.SurfaceCreatedMsg.SIZE]u8 = undefined;
        const reply = protocol.SurfaceCreatedMsg{ .surface_id = surface.id };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.surface_created, &reply_buf);

        log.debug("remote client {} created surface {}", .{ session.id, surface.id });
        events.emitSurfaceCreated(session.id, surface.id, msg.logical_width, msg.logical_height, surface.owner_uid);
    }

    fn handleRemoteDestroySurface(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.DestroySurfaceMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.DestroySurfaceMsg.deserialize(payload.?);

        if (!self.canModifySurface(msg.surface_id, session.peer_uid)) {
            try self.sendRemoteError(session, .permission_denied, msg.surface_id);
            return;
        }

        // AD-31.4 part B: capture owner_uid before destroySurface
        // deallocates the Surface struct. canModifySurface above
        // already confirmed the surface exists; the orelse path is
        // defensive and falls back to NOBODY_UID rather than
        // panicking.
        const owner_uid = if (self.surfaces.getSurface(msg.surface_id)) |s| s.owner_uid else privilege.NOBODY_UID;

        self.comp.onSurfaceDestroyed(msg.surface_id);
        self.surfaces.destroySurface(msg.surface_id);
        log.debug("remote client {} destroyed surface {}", .{ session.id, msg.surface_id });
        events.emitSurfaceDestroyed(session.id, msg.surface_id, owner_uid);
    }

    fn handleRemoteAttachBufferInline(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.AttachBufferInlineMsg.HEADER_SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.AttachBufferInlineMsg.deserialize(payload.?);
        const expected_len = protocol.AttachBufferInlineMsg.HEADER_SIZE + msg.sdcs_length;

        if (payload.?.len < expected_len) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        if (!self.canModifySurface(msg.surface_id, session.peer_uid)) {
            try self.sendRemoteError(session, .permission_denied, msg.surface_id);
            return;
        }

        // Store SDCS data for this session
        if (session.sdcs_buffer) |buf| self.allocator.free(buf);
        session.sdcs_buffer = try self.allocator.alloc(u8, msg.sdcs_length);
        @memcpy(session.sdcs_buffer.?, payload.?[protocol.AttachBufferInlineMsg.HEADER_SIZE..expected_len]);

        // Validate SDCS
        const validation = sdcs_validator.SdcsValidator.validateBuffer(session.sdcs_buffer.?);
        if (!validation.valid) {
            try self.sendRemoteError(session, .validation_failed, msg.surface_id);
            self.allocator.free(session.sdcs_buffer.?);
            session.sdcs_buffer = null;
            return;
        }

        // Attach to surface
        self.surfaces.attachInlineBuffer(msg.surface_id, session.sdcs_buffer.?) catch {
            try self.sendRemoteError(session, .invalid_surface, msg.surface_id);
            return;
        };

        log.debug("remote client {} attached {} bytes to surface {}", .{ session.id, msg.sdcs_length, msg.surface_id });
    }

    fn handleRemoteCommit(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.CommitMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.CommitMsg.deserialize(payload.?);

        if (!self.canModifySurface(msg.surface_id, session.peer_uid)) {
            try self.sendRemoteError(session, .permission_denied, msg.surface_id);
            return;
        }

        const frame_number = self.surfaces.commit(msg.surface_id) catch {
            try self.sendRemoteError(session, .invalid_surface, msg.surface_id);
            return;
        };

        self.comp.onSurfaceCommit(msg.surface_id) catch {};

        var reply_buf: [protocol.FrameCompleteMsg.SIZE]u8 = undefined;
        const reply = protocol.FrameCompleteMsg{
            .surface_id = msg.surface_id,
            .frame_number = frame_number,
            .timestamp_ns = @intCast(realtimeNowNs()),
        };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.frame_complete, &reply_buf);

        log.debug("remote client {} committed surface {} frame {}", .{ session.id, msg.surface_id, frame_number });
        events.emitFrameComplete(msg.surface_id, frame_number, "software", null);
    }

    fn handleRemoteSetVisible(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SetVisibleMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.SetVisibleMsg.deserialize(payload.?);

        if (!self.canModifySurface(msg.surface_id, session.peer_uid)) {
            try self.sendRemoteError(session, .permission_denied, msg.surface_id);
            return;
        }

        self.surfaces.setVisible(msg.surface_id, msg.visible != 0) catch {
            try self.sendRemoteError(session, .invalid_surface, msg.surface_id);
            return;
        };

        // When a surface becomes visible, trigger full repaint to ensure it gets rendered
        if (msg.visible != 0) {
            self.comp.damageAll();
        }
    }

    fn handleRemoteSetZOrder(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SetZOrderMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.SetZOrderMsg.deserialize(payload.?);

        if (!self.canModifySurface(msg.surface_id, session.peer_uid)) {
            try self.sendRemoteError(session, .permission_denied, msg.surface_id);
            return;
        }

        // Clamp to client range; same rationale as handleSetZOrder.
        const clamped_z: i32 = @max(protocol.Z_ORDER_MIN,
            @min(msg.z_order, protocol.Z_ORDER_CLIENT_MAX));

        self.surfaces.setZOrder(msg.surface_id, clamped_z) catch {
            try self.sendRemoteError(session, .invalid_surface, msg.surface_id);
            return;
        };
    }

    fn handleRemoteSetPosition(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SetPositionMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.SetPositionMsg.deserialize(payload.?);

        if (!self.canModifySurface(msg.surface_id, session.peer_uid)) {
            try self.sendRemoteError(session, .permission_denied, msg.surface_id);
            return;
        }

        self.surfaces.setPosition(msg.surface_id, msg.x, msg.y) catch {
            try self.sendRemoteError(session, .invalid_surface, msg.surface_id);
            return;
        };
    }

    /// AD-21 sub-item 7: SET_CURSOR handler (remote TCP clients).
    /// Mirror of handleSetCursor above; the only differences are
    /// session type (RemoteSession vs ClientSession) and reply path
    /// (session.client.sendMessage vs session.send /
    /// sendRemoteError vs session.sendError). Logic and validation
    /// order are identical; see handleSetCursor for full commentary.
    fn handleRemoteSetCursor(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SetCursorMsg.HEADER_SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.SetCursorMsg.deserialize(payload.?);

        const expected_len = protocol.SetCursorMsg.HEADER_SIZE + msg.sprite_length;
        if (payload.?.len < expected_len) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        if (msg.sprite_width > protocol.SPRITE_MAX_DIM or
            msg.sprite_height > protocol.SPRITE_MAX_DIM or
            msg.sprite_width == 0 or msg.sprite_height == 0)
        {
            try self.sendRemoteError(session, .validation_failed, 0);
            return;
        }

        if (msg.sprite_format != protocol.SPRITE_FORMAT_SDCS) {
            try self.sendRemoteError(session, .invalid_message, 0);
            return;
        }

        if (msg.sprite_length == 0) {
            try self.sendRemoteError(session, .validation_failed, 0);
            return;
        }

        const cursor_id = self.cursor_surface_id orelse {
            try self.sendRemoteError(session, .internal_error, 0);
            return;
        };

        const focus_id = self.surfaces.getTopVisibleSurface() orelse {
            try self.sendRemoteError(session, .permission_denied, 0);
            return;
        };
        if (!self.canModifySurface(focus_id, session.peer_uid)) {
            try self.sendRemoteError(session, .permission_denied, focus_id);
            return;
        }

        const sprite_data = payload.?[protocol.SetCursorMsg.HEADER_SIZE..expected_len];
        const validation = sdcs_validator.SdcsValidator.validateBuffer(sprite_data);
        if (!validation.valid) {
            try self.sendRemoteError(session, .validation_failed, 0);
            return;
        }

        self.surfaces.attachInlineBuffer(cursor_id, sprite_data) catch {
            try self.sendRemoteError(session, .internal_error, 0);
            return;
        };

        // AD-24: see handleSetCursor for rationale.
        self.cursor_is_default = false;

        self.surfaces.setHotspot(cursor_id, msg.hotspot_x, msg.hotspot_y) catch {};
        self.surfaces.setLogicalSize(
            cursor_id,
            @floatFromInt(msg.sprite_width),
            @floatFromInt(msg.sprite_height),
        ) catch {};

        self.comp.damageSurface(cursor_id) catch |err| {
            log.warn("remote set_cursor: damageSurface failed: {}", .{err});
        };

        var reply_buf: [protocol.CursorSetMsg.SIZE]u8 = undefined;
        const reply = protocol.CursorSetMsg{ .status = 0 };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.cursor_set, &reply_buf);

        log.debug("remote client {} set cursor: sprite {}x{}, hotspot ({}, {}), {} bytes", .{
            session.id, msg.sprite_width, msg.sprite_height,
            msg.hotspot_x, msg.hotspot_y, msg.sprite_length,
        });
    }

    fn handleRemoteSync(_: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SyncMsg.SIZE) {
            return error.InvalidPayload;
        }

        const msg = try protocol.SyncMsg.deserialize(payload.?);

        var reply_buf: [protocol.SyncDoneMsg.SIZE]u8 = undefined;
        const reply = protocol.SyncDoneMsg{ .sync_id = msg.sync_id };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.sync_done, &reply_buf);
    }

    /// AD-26 follow-up: TCP counterpart to handleOutputInfoRequest. See
    /// that function's comment for the rationale. TCP clients have the
    /// same need to know the framebuffer size and the same lack of
    /// direct /dev/draw access (TCP clients are usually on a different
    /// machine entirely).
    fn handleRemoteOutputInfoRequest(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.OutputInfoRequestMsg.SIZE) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        const msg = try protocol.OutputInfoRequestMsg.deserialize(payload.?);

        if (msg.output_id != 0) {
            try self.sendRemoteError(session, .validation_failed, msg.output_id);
            return;
        }

        const dims = self.comp.outputDimensions() orelse {
            try self.sendRemoteError(session, .validation_failed, msg.output_id);
            return;
        };

        var reply_buf: [protocol.OutputInfoReplyMsg.SIZE]u8 = undefined;
        const reply = protocol.OutputInfoReplyMsg{
            .output_id = msg.output_id,
            .width = dims.width,
            .height = dims.height,
        };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.output_info_reply, &reply_buf);
    }

    fn handleRemoteIdleQuery(self: *Daemon, session: *RemoteSession, payload: ?[]u8) !void {
        // idle_query is argument-free (ADR 0013 D5); a non-empty payload
        // is malformed.
        if (payload != null and payload.?.len != 0) {
            try self.sendRemoteError(session, .protocol_error, 0);
            return;
        }

        // ADR 0013 D1/D2: reply with the daemon's current
        // last_input_ts_ns (chronofs ns) at query time; no caching.
        var reply_buf: [protocol.IdleReplyMsg.SIZE]u8 = undefined;
        const reply = protocol.IdleReplyMsg{ .last_input_ts_ns = self.last_input_ts_ns };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.idle_reply, &reply_buf);
    }

    fn sendRemoteError(self: *Daemon, session: *RemoteSession, code: protocol.ErrorCode, context: u32) !void {
        _ = self;
        var reply_buf: [protocol.ErrorReplyMsg.SIZE]u8 = undefined;
        const reply = protocol.ErrorReplyMsg{ .code = code, .context = context };
        reply.serialize(&reply_buf);
        try session.client.sendMessage(.error_reply, &reply_buf);
    }

    fn disconnectRemoteClient(self: *Daemon, client_id: protocol.ClientId) void {
        // AD-31.4 part B: capture peer_uid before fetchRemove
        // deallocates the session. For TCP this is always
        // NOBODY_UID (per ADR 0006 §2) but we read from the
        // session for uniformity with the Unix path. The
        // fallback covers the unexpected-already-removed case.
        const peer_uid: posix.uid_t = if (self.remote_clients.get(client_id)) |s| s.peer_uid else privilege.NOBODY_UID;

        events.emitClientDisconnected(client_id, "disconnect", peer_uid);
        if (self.remote_clients.fetchRemove(client_id)) |entry| {
            const session = entry.value;
            self.surfaces.removeClientSurfaces(client_id);
            if (session.sdcs_buffer) |buf| self.allocator.free(buf);
            session.client.close();
            self.allocator.destroy(session);
        }
    }

    fn handleNewConnection(self: *Daemon) !void {
        const client_fd = try self.server.accept();

        if (self.clients.count() >= self.config.max_clients) {
            log.warn("max clients reached, rejecting connection", .{});
            closeFd(client_fd);
            return;
        }


        // AD-31.2: createSession now calls getpeereid(3) on the fd; if
        // it fails (or any subsequent allocation fails), the fd is ours
        // to close. Without this, a getpeereid failure would leak the
        // socket. Per ADR 0006 §2, getpeereid failure is a
        // connection-level error: close, log, no reply to the peer.
        const session = self.clients.createSession(client_fd) catch |err| {
            closeFd(client_fd);
            log.warn("failed to create client session: {} (errno may indicate cause; fd closed)", .{err});
            return err;
        };
        log.info("client {} connected (peer uid={d} gid={d})", .{ session.id, session.peer_uid, session.peer_gid });
    }

    fn handleClientMessage(self: *Daemon, session: *client_session.ClientSession) !void {
        var msg = try session.socket.readMessage(self.allocator) orelse return;
        defer msg.deinit(self.allocator);

        switch (session.state) {
            .awaiting_hello => {
                if (msg.header.msg_type != .hello) {
                    try session.sendError(.protocol_error, 0);
                    return error.ProtocolError;
                }
                try self.handleHello(session, msg.payload);
            },
            .connected => {
                try self.handleRequest(session, msg.header.msg_type, msg.payload);
            },
            .disconnecting => {},
        }
    }

    fn handleHello(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        _ = self;

        if (payload == null or payload.?.len < protocol.HelloMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return error.InvalidPayload;
        }

        const hello = try protocol.HelloMsg.deserialize(payload.?);

        // Version check
        if (hello.version_major != protocol.PROTOCOL_VERSION_MAJOR) {
            try session.sendError(.protocol_error, 0);
            return error.VersionMismatch;
        }

        // Send reply
        var reply_buf: [protocol.HelloReplyMsg.SIZE]u8 = undefined;
        const reply = protocol.HelloReplyMsg{
            .version_major = protocol.PROTOCOL_VERSION_MAJOR,
            .version_minor = protocol.PROTOCOL_VERSION_MINOR,
            .client_id = session.id,
            .server_flags = 0,
        };
        reply.serialize(&reply_buf);
        try session.send(.hello_reply, &reply_buf);

        session.state = .connected;
        log.info("client {} completed handshake", .{session.id});
        events.emitClientConnected(session.id, hello.version_major, hello.version_minor, session.peer_uid);
    }

    fn handleRequest(self: *Daemon, session: *client_session.ClientSession, msg_type: protocol.MsgType, payload: ?[]u8) !void {
        switch (msg_type) {
            .create_surface => try self.handleCreateSurface(session, payload),
            .destroy_surface => try self.handleDestroySurface(session, payload),
            .attach_buffer_inline => try self.handleAttachBufferInline(session, payload),
            .commit => try self.handleCommit(session, payload),
            .set_visible => try self.handleSetVisible(session, payload),
            .set_z_order => try self.handleSetZOrder(session, payload),
            .set_position => try self.handleSetPosition(session, payload),
            .set_cursor => try self.handleSetCursor(session, payload),
            .sync => try self.handleSync(session, payload),
            .clipboard_set => try self.handleClipboardSet(session, payload),
            .clipboard_request => try self.handleClipboardRequest(session, payload),
            .output_info_request => try self.handleOutputInfoRequest(session, payload),
            .idle_query => try self.handleIdleQuery(session, payload),
            .disconnect => {
                session.state = .disconnecting;
            },
            else => {
                log.warn("client {} sent unexpected message type: {}", .{ session.id, msg_type });
                try session.sendError(.invalid_message, 0);
            },
        }
    }

    fn handleCreateSurface(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.CreateSurfaceMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.CreateSurfaceMsg.deserialize(payload.?);

        // Check resource limits
        if (!session.usage.canCreateSurface(session.limits, msg.logical_width, msg.logical_height)) {
            try session.sendError(.resource_limit, 0);
            return;
        }

        // Create surface in registry.
        //
        // AD-31.3 part 2: owner_uid comes from the connecting
        // client's peer_uid (established by getpeereid at accept
        // time per AD-31.2). Two clients running as the same uid
        // create surfaces with the same owner_uid and (per
        // canModifySurface) can modify each other's surfaces;
        // clients running as different uids cannot.
        const surface = self.surfaces.createSurface(session.id, session.peer_uid, msg.logical_width, msg.logical_height) catch {
            try session.sendError(.resource_limit, 0);
            return;
        };
        try session.addSurface(surface.id, msg.logical_width, msg.logical_height);

        // Notify compositor
        self.comp.onSurfaceCreated(surface.id) catch {};

        // Send reply
        var reply_buf: [protocol.SurfaceCreatedMsg.SIZE]u8 = undefined;
        const reply = protocol.SurfaceCreatedMsg{ .surface_id = surface.id };
        reply.serialize(&reply_buf);
        try session.send(.surface_created, &reply_buf);

        log.debug("client {} created surface {}", .{ session.id, surface.id });
        events.emitSurfaceCreated(session.id, surface.id, msg.logical_width, msg.logical_height, surface.owner_uid);
    }

    fn handleDestroySurface(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.DestroySurfaceMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.DestroySurfaceMsg.deserialize(payload.?);

        // Verify ownership via registry
        if (!self.canModifySurface(msg.surface_id, session.peer_uid)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        // Get dimensions for usage tracking before destroying
        if (self.surfaces.getSurface(msg.surface_id)) |surface| {
            session.removeSurface(msg.surface_id, surface.logical_width, surface.logical_height);
        }

        // AD-31.4 part B: capture owner_uid before destroySurface
        // deallocates the Surface struct. canModifySurface earlier
        // confirmed the surface exists; the orelse path is
        // defensive.
        const owner_uid = if (self.surfaces.getSurface(msg.surface_id)) |s| s.owner_uid else privilege.NOBODY_UID;

        // Notify compositor
        self.comp.onSurfaceDestroyed(msg.surface_id);

        self.surfaces.destroySurface(msg.surface_id);
        log.debug("client {} destroyed surface {}", .{ session.id, msg.surface_id });
        events.emitSurfaceDestroyed(session.id, msg.surface_id, owner_uid);
    }

    fn handleAttachBufferInline(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.AttachBufferInlineMsg.HEADER_SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.AttachBufferInlineMsg.deserialize(payload.?);
        const expected_len = protocol.AttachBufferInlineMsg.HEADER_SIZE + msg.sdcs_length;

        if (payload.?.len < expected_len) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        if (!self.canModifySurface(msg.surface_id, session.peer_uid)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        // Store SDCS data for this session
        if (session.sdcs_buffer) |buf| session.allocator.free(buf);
        session.sdcs_buffer = try session.allocator.alloc(u8, msg.sdcs_length);
        @memcpy(session.sdcs_buffer.?, payload.?[protocol.AttachBufferInlineMsg.HEADER_SIZE..expected_len]);

        // Validate SDCS
        const validation = sdcs_validator.SdcsValidator.validateBuffer(session.sdcs_buffer.?);
        if (!validation.valid) {
            try session.sendError(.validation_failed, msg.surface_id);
            session.allocator.free(session.sdcs_buffer.?);
            session.sdcs_buffer = null;
            return;
        }

        // Attach to surface
        self.surfaces.attachInlineBuffer(msg.surface_id, session.sdcs_buffer.?) catch {
            try session.sendError(.invalid_surface, msg.surface_id);
            return;
        };
    }

    fn handleCommit(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.CommitMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.CommitMsg.deserialize(payload.?);

        // Verify ownership via registry
        if (!self.canModifySurface(msg.surface_id, session.peer_uid)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        // Mark surface as committed in registry
        const frame_number = self.surfaces.commit(msg.surface_id) catch {
            try session.sendError(.invalid_surface, msg.surface_id);
            return;
        };

        // Notify compositor of surface damage
        self.comp.onSurfaceCommit(msg.surface_id) catch {};

        // Send frame_complete
        var reply_buf: [protocol.FrameCompleteMsg.SIZE]u8 = undefined;
        const reply = protocol.FrameCompleteMsg{
            .surface_id = msg.surface_id,
            .frame_number = frame_number,
            .timestamp_ns = @intCast(realtimeNowNs()),
        };
        reply.serialize(&reply_buf);
        try session.send(.frame_complete, &reply_buf);

        log.debug("client {} committed surface {} frame {}", .{ session.id, msg.surface_id, frame_number });
        events.emitFrameComplete(msg.surface_id, frame_number, "software", null);
    }

    fn handleSetVisible(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SetVisibleMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.SetVisibleMsg.deserialize(payload.?);

        // Verify ownership via registry
        if (!self.canModifySurface(msg.surface_id, session.peer_uid)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        self.surfaces.setVisible(msg.surface_id, msg.visible != 0) catch {
            try session.sendError(.invalid_surface, msg.surface_id);
            return;
        };

        // When a surface becomes visible, trigger full repaint to ensure it gets rendered
        if (msg.visible != 0) {
            self.comp.damageAll();
        }

        log.debug("client {} set surface {} visible={}", .{ session.id, msg.surface_id, msg.visible != 0 });
    }

    fn handleSetZOrder(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SetZOrderMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.SetZOrderMsg.deserialize(payload.?);

        // Verify ownership via registry
        if (!self.canModifySurface(msg.surface_id, session.peer_uid)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        // Clamp client-requested z-order to the client range. The
        // cursor surface sits above this range (per ADR 0005); a
        // client cannot reach or exceed it. Out-of-range requests
        // are silently clamped rather than rejected, since client
        // libraries may legitimately use i32 max as a "force on
        // top" idiom.
        const clamped_z: i32 = @max(protocol.Z_ORDER_MIN,
            @min(msg.z_order, protocol.Z_ORDER_CLIENT_MAX));

        self.surfaces.setZOrder(msg.surface_id, clamped_z) catch {
            try session.sendError(.invalid_surface, msg.surface_id);
            return;
        };
        log.debug("client {} set surface {} z_order={} (requested {})",
            .{ session.id, msg.surface_id, clamped_z, msg.z_order });
    }

    fn handleSetPosition(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.SetPositionMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.SetPositionMsg.deserialize(payload.?);

        // Verify ownership via registry
        if (!self.canModifySurface(msg.surface_id, session.peer_uid)) {
            try session.sendError(.permission_denied, msg.surface_id);
            return;
        }

        self.surfaces.setPosition(msg.surface_id, msg.x, msg.y) catch {
            try session.sendError(.invalid_surface, msg.surface_id);
            return;
        };
        log.debug("client {} set surface {} position=({}, {})", .{ session.id, msg.surface_id, msg.x, msg.y });
    }

    /// AD-21 sub-item 7: SET_CURSOR handler (local-socket clients).
    ///
    /// Per ADR 0005 section 5. Replaces the cursor surface's sprite
    /// and hotspot. The requester must own the currently focused
    /// (top visible) client surface; SET_CURSOR from any other
    /// client is rejected with permission_denied so a client can't
    /// set a cursor while another client has focus.
    ///
    /// Validation order (fail-fast):
    ///   1. Payload length covers the fixed header (28 bytes).
    ///   2. Payload length covers HEADER_SIZE + sprite_length.
    ///   3. sprite_width and sprite_height ≤ SPRITE_MAX_DIM (256).
    ///   4. sprite_format is recognised (currently SPRITE_FORMAT_SDCS).
    ///   5. sprite_length > 0 (empty sprites are nonsensical).
    ///   6. Cursor surface exists (initCursorSurface succeeded).
    ///   7. Requester owns the top visible client surface.
    ///   8. SDCS bytes validate (sdcs_validator.validateBuffer).
    ///
    /// On success: attach the new sprite to the cursor surface,
    /// update hotspot and logical dimensions, mark the cursor
    /// surface for full damage so the next composite picks up the
    /// new sprite, and reply with cursor_set.
    ///
    /// The previous sprite buffer is freed by attachInlineBuffer
    /// (which deinits the old buffer before attaching the new one).
    /// There is no per-client cursor caching; ADR §5 explicitly
    /// defers that as a future ergonomic refinement.
    fn handleSetCursor(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        // 1. Header size check.
        if (payload == null or payload.?.len < protocol.SetCursorMsg.HEADER_SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.SetCursorMsg.deserialize(payload.?);

        // 2. Full payload covers header + declared sprite_length.
        const expected_len = protocol.SetCursorMsg.HEADER_SIZE + msg.sprite_length;
        if (payload.?.len < expected_len) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        // 3. Sprite dimensions within bounds.
        if (msg.sprite_width > protocol.SPRITE_MAX_DIM or
            msg.sprite_height > protocol.SPRITE_MAX_DIM or
            msg.sprite_width == 0 or msg.sprite_height == 0)
        {
            try session.sendError(.validation_failed, 0);
            return;
        }

        // 4. Sprite format recognised.
        if (msg.sprite_format != protocol.SPRITE_FORMAT_SDCS) {
            try session.sendError(.invalid_message, 0);
            return;
        }

        // 5. Sprite data non-empty.
        if (msg.sprite_length == 0) {
            try session.sendError(.validation_failed, 0);
            return;
        }

        // 6. Cursor surface must exist. Initialised by sub-item 3
        // during initCursorSurface; null only if that failed.
        const cursor_id = self.cursor_surface_id orelse {
            try session.sendError(.internal_error, 0);
            return;
        };

        // 7. Requester owns the top visible client surface
        // (getTopVisibleSurface excludes daemon-owned surfaces).
        const focus_id = self.surfaces.getTopVisibleSurface() orelse {
            try session.sendError(.permission_denied, 0);
            return;
        };
        if (!self.canModifySurface(focus_id, session.peer_uid)) {
            try session.sendError(.permission_denied, focus_id);
            return;
        }

        // 8. Validate SDCS bytes.
        const sprite_data = payload.?[protocol.SetCursorMsg.HEADER_SIZE..expected_len];
        const validation = sdcs_validator.SdcsValidator.validateBuffer(sprite_data);
        if (!validation.valid) {
            try session.sendError(.validation_failed, 0);
            return;
        }

        // Attach the new sprite to the cursor surface. attachInlineBuffer
        // copies the data; the surface owns the copy and frees the
        // previous buffer.
        self.surfaces.attachInlineBuffer(cursor_id, sprite_data) catch {
            try session.sendError(.internal_error, 0);
            return;
        };

        // AD-24: from this point on the cursor surface no longer
        // holds the default sprite. pumpCursorFocus uses this flag
        // to decide whether to reset on focus loss.
        self.cursor_is_default = false;

        // Update hotspot and logical dimensions to match the new sprite.
        self.surfaces.setHotspot(cursor_id, msg.hotspot_x, msg.hotspot_y) catch {};
        self.surfaces.setLogicalSize(
            cursor_id,
            @floatFromInt(msg.sprite_width),
            @floatFromInt(msg.sprite_height),
        ) catch {};

        // Mark the cursor surface for full damage so the next
        // composite cycle renders the new sprite. The position pump
        // would also damage on the next pointer move, but we shouldn't
        // wait for one to redraw a stale cursor.
        self.comp.damageSurface(cursor_id) catch |err| {
            log.warn("set_cursor: damageSurface failed: {}", .{err});
        };

        // Send acknowledgement reply.
        var reply_buf: [protocol.CursorSetMsg.SIZE]u8 = undefined;
        const reply = protocol.CursorSetMsg{ .status = 0 };
        reply.serialize(&reply_buf);
        try session.send(.cursor_set, &reply_buf);

        log.debug("client {} set cursor: sprite {}x{}, hotspot ({}, {}), {} bytes", .{
            session.id, msg.sprite_width, msg.sprite_height,
            msg.hotspot_x, msg.hotspot_y, msg.sprite_length,
        });
    }

    fn handleSync(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        _ = self;

        if (payload == null or payload.?.len < protocol.SyncMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.SyncMsg.deserialize(payload.?);

        // Send sync done immediately (no pending operations to wait for yet)
        var reply_buf: [protocol.SyncDoneMsg.SIZE]u8 = undefined;
        const reply = protocol.SyncDoneMsg{ .sync_id = msg.sync_id };
        reply.serialize(&reply_buf);
        try session.send(.sync_done, &reply_buf);
    }

    /// AD-26 follow-up: serve framebuffer size to clients via IPC so
    /// clients do not need to open /dev/draw directly. Per ADR 0006 §5,
    /// /dev/draw is restricted to the _semadraw user; only the daemon
    /// can call DRAWFSGIOC_GET_EFIFB_INFO. The compositor already holds
    /// the size from its own backend init (see drawfs.zig
    /// getDetectedDisplaySizeImpl), so we read it from there and reply.
    ///
    /// For output_id == 0 (the only currently valid id), return the
    /// primary output's dimensions. For any other id, return
    /// validation_failed. If the compositor has no output yet
    /// (initOutput failed or has not run), also return
    /// validation_failed; the client can choose to fall back.
    fn handleOutputInfoRequest(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.OutputInfoRequestMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.OutputInfoRequestMsg.deserialize(payload.?);

        if (msg.output_id != 0) {
            try session.sendError(.validation_failed, msg.output_id);
            return;
        }

        const dims = self.comp.outputDimensions() orelse {
            try session.sendError(.validation_failed, msg.output_id);
            return;
        };

        var reply_buf: [protocol.OutputInfoReplyMsg.SIZE]u8 = undefined;
        const reply = protocol.OutputInfoReplyMsg{
            .output_id = msg.output_id,
            .width = dims.width,
            .height = dims.height,
        };
        reply.serialize(&reply_buf);
        try session.send(.output_info_reply, &reply_buf);
    }

    fn handleIdleQuery(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        // idle_query is argument-free (ADR 0013 D5); a non-empty payload
        // is malformed.
        if (payload != null and payload.?.len != 0) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        // ADR 0013 D1/D2: reply with the daemon's current
        // last_input_ts_ns (chronofs ns) at query time; no caching.
        var reply_buf: [protocol.IdleReplyMsg.SIZE]u8 = undefined;
        const reply = protocol.IdleReplyMsg{ .last_input_ts_ns = self.last_input_ts_ns };
        reply.serialize(&reply_buf);
        try session.send(.idle_reply, &reply_buf);
    }

    fn handleClipboardSet(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.ClipboardSetMsg.HEADER_SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.ClipboardSetMsg.deserialize(payload.?);
        const text_start = protocol.ClipboardSetMsg.HEADER_SIZE;
        const text_end = text_start + msg.length;

        if (payload.?.len < text_end) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const text = payload.?[text_start..text_end];
        const selection: u8 = @intFromEnum(msg.selection);

        self.comp.setClipboard(selection, text) catch |err| {
            log.warn("clipboard set failed: {}", .{err});
            return;
        };

        log.debug("client {} set clipboard selection={} len={}", .{ session.id, selection, text.len });
    }

    fn handleClipboardRequest(self: *Daemon, session: *client_session.ClientSession, payload: ?[]u8) !void {
        if (payload == null or payload.?.len < protocol.ClipboardRequestMsg.SIZE) {
            try session.sendError(.protocol_error, 0);
            return;
        }

        const msg = try protocol.ClipboardRequestMsg.deserialize(payload.?);
        const selection: u8 = @intFromEnum(msg.selection);

        // Check if we already have clipboard data cached
        if (self.comp.getClipboardData(selection)) |data| {
            // Send clipboard data immediately
            try self.sendClipboardData(session, msg.selection, data);
        } else {
            // Request clipboard from backend - it's async
            // Store the pending request and client to respond to later
            self.pending_clipboard_client = session.id;
            self.pending_clipboard_selection = selection;
            self.comp.requestClipboard(selection);
        }
    }

    fn sendClipboardData(self: *Daemon, session: *client_session.ClientSession, selection: protocol.ClipboardSelection, data: []const u8) !void {
        _ = self;
        // Build response: header + text
        const header_size = protocol.ClipboardDataMsg.HEADER_SIZE;
        const total_size = header_size + data.len;

        var buf = try session.allocator.alloc(u8, total_size);
        defer session.allocator.free(buf);

        const header = protocol.ClipboardDataMsg{
            .selection = selection,
            .length = @intCast(data.len),
        };
        header.serialize(buf[0..header_size]);
        @memcpy(buf[header_size..], data);

        try session.send(.clipboard_data, buf);
        log.debug("sent clipboard data to client {}: selection={} len={}", .{ session.id, @intFromEnum(selection), data.len });
    }

    fn checkPendingClipboard(self: *Daemon) void {
        // If we have a pending clipboard request, check if data is available
        if (self.pending_clipboard_client) |client_id| {
            // Check if request is still pending in backend
            if (self.comp.isClipboardPending()) {
                return; // Still waiting
            }

            // Data should now be available
            if (self.comp.getClipboardData(self.pending_clipboard_selection)) |data| {
                // Find the client and send the data
                if (self.clients.sessions.get(client_id)) |session| {
                    const selection: protocol.ClipboardSelection = @enumFromInt(self.pending_clipboard_selection);
                    self.sendClipboardData(session, selection, data) catch |err| {
                        log.warn("failed to send clipboard data to client {}: {}", .{ client_id, err });
                    };
                }
            }

            // Clear pending request
            self.pending_clipboard_client = null;
        }
    }

    fn disconnectClient(self: *Daemon, client_id: protocol.ClientId) void {
        // AD-31.4 part B: capture peer_uid before destroySession
        // deallocates the session. For Unix this is the result
        // of getpeereid at accept time (per AD-31.2). The
        // fallback covers the unexpected-already-removed case.
        const peer_uid: posix.uid_t = if (self.clients.sessions.get(client_id)) |s| s.peer_uid else privilege.NOBODY_UID;

        events.emitClientDisconnected(client_id, "disconnect", peer_uid);
        // Clean up surfaces owned by this client
        self.surfaces.removeClientSurfaces(client_id);
        self.clients.destroySession(client_id);
        // Trigger full repaint to clear any remnants of destroyed surfaces
        self.comp.damageAll();
    }

    pub fn stop(self: *Daemon) void {
        self.running = false;
    }

    /// Forward keyboard events to the top visible surface's client
    fn forwardKeyEvents(self: *Daemon, key_events: []const backend.KeyEvent) void {
        // AD-2a Phase 2.4.5: track modifier state at the daemon
        // level. Done before the focused-surface lookup so modifier
        // state stays current even when there is no focused
        // surface; gesture events that arrive later (e.g. via
        // touch on an unfocused area) still see the correct
        // modifier mask.
        if (key_events.len > 0) {
            self.last_modifiers = key_events[key_events.len - 1].modifiers;
        }

        // Get the top visible surface to send keyboard input to
        const top_surface_id = self.surfaces.getTopVisibleSurface() orelse {
            log.debug("forwardKeyEvents: no top visible surface", .{});
            return;
        };
        const surface = self.surfaces.getSurface(top_surface_id) orelse {
            log.debug("forwardKeyEvents: surface {} not found", .{top_surface_id});
            return;
        };
        log.debug("forwardKeyEvents: {} events to surface {} (owner {})", .{ key_events.len, top_surface_id, surface.owner });

        for (key_events) |event| {
            const msg = protocol.KeyPressMsg{
                .surface_id = top_surface_id,
                .key_code = event.key_code,
                .modifiers = event.modifiers,
                .pressed = if (event.pressed) 1 else 0,
            };
            var payload: [protocol.KeyPressMsg.SIZE]u8 = undefined;
            msg.serialize(&payload);

            // AD-46: non-blocking send with backpressure policy. Key
            // events are not coalescible (a dropped press or release
            // is lost input), so WouldBlock counts toward the
            // consecutive-failure streak and the client is dropped at
            // the threshold instead of wedging the loop. A partial
            // write corrupts the client's stream mid-frame and forces
            // an immediate disconnect.
            if (self.clients.findById(surface.owner)) |session| {
                switch (session.trySend(.key_press, &payload)) {
                    .sent => session.send_fail_streak = 0,
                    .would_block => {
                        session.send_fail_streak += 1;
                        if (session.send_fail_streak >= AD46_SEND_FAIL_DISCONNECT) {
                            log.warn("AD-46: client {} not draining ({} consecutive key-event send failures), disconnecting", .{ surface.owner, session.send_fail_streak });
                            self.disconnectClient(session.id);
                            return;
                        }
                    },
                    .partial, .err => {
                        log.warn("AD-46: client {} stream corrupt or write error on key event, disconnecting", .{surface.owner});
                        self.disconnectClient(session.id);
                        return;
                    },
                }
            } else if (self.remote_clients.get(surface.owner)) |remote_session| {
                switch (remote_session.client.trySendMessage(.key_press, &payload)) {
                    .sent => {},
                    else => {
                        log.warn("AD-46: remote client {} stalled or errored on key event, disconnecting", .{surface.owner});
                        self.disconnectRemoteClient(remote_session.id);
                        return;
                    },
                }
            } else {
                log.warn("no client found for surface owner {}", .{surface.owner});
            }
        }
    }

    /// Forward mouse events to the top visible surface's client
    fn forwardMouseEvents(self: *Daemon, mouse_events: []const backend.MouseEvent) void {
        // AD-2a Phase 2.4.5: track modifier state at the daemon
        // level (see forwardKeyEvents for rationale). Done before
        // the focused-surface lookup so modifier state stays
        // current even when there is no focused surface.
        if (mouse_events.len > 0) {
            self.last_modifiers = mouse_events[mouse_events.len - 1].modifiers;
        }

        // Get the top visible surface to send mouse input to
        const top_surface_id = self.surfaces.getTopVisibleSurface() orelse return;
        const surface = self.surfaces.getSurface(top_surface_id) orelse return;

        for (mouse_events) |event| {
            const msg = protocol.MouseEventMsg{
                .surface_id = top_surface_id,
                .x = event.x,
                .y = event.y,
                .button = @enumFromInt(@intFromEnum(event.button)),
                .event_type = @enumFromInt(@intFromEnum(event.event_type)),
                .modifiers = event.modifiers,
            };
            var payload: [protocol.MouseEventMsg.SIZE]u8 = undefined;
            msg.serialize(&payload);

            // AD-46: non-blocking send with backpressure policy.
            // Motion is coalescible (the next event supersedes a
            // dropped one), so WouldBlock on motion is a clean drop;
            // press and release are not, and count toward the streak.
            const coalescible = event.event_type == .motion;
            if (self.clients.findById(surface.owner)) |session| {
                switch (session.trySend(.mouse_event, &payload)) {
                    .sent => session.send_fail_streak = 0,
                    .would_block => {
                        if (coalescible) {
                            session.dropped_motion += 1;
                        } else {
                            session.send_fail_streak += 1;
                            if (session.send_fail_streak >= AD46_SEND_FAIL_DISCONNECT) {
                                log.warn("AD-46: client {} not draining ({} consecutive send failures, {} motions dropped), disconnecting", .{ surface.owner, session.send_fail_streak, session.dropped_motion });
                                self.disconnectClient(session.id);
                                return;
                            }
                        }
                    },
                    .partial, .err => {
                        log.warn("AD-46: client {} stream corrupt or write error on mouse event, disconnecting", .{surface.owner});
                        self.disconnectClient(session.id);
                        return;
                    },
                }
            } else if (self.remote_clients.get(surface.owner)) |remote_session| {
                switch (remote_session.client.trySendMessage(.mouse_event, &payload)) {
                    .sent => {},
                    .would_block => {
                        if (!coalescible) {
                            log.warn("AD-46: remote client {} stalled on mouse event, disconnecting", .{surface.owner});
                            self.disconnectRemoteClient(remote_session.id);
                            return;
                        }
                    },
                    .partial, .err => {
                        log.warn("AD-46: remote client {} stream corrupt on mouse event, disconnecting", .{surface.owner});
                        self.disconnectRemoteClient(remote_session.id);
                        return;
                    },
                }
            }
        }
    }

    /// AD-2a Phase 2.4.5: forward a gesture event from the
    /// recogniser to the focused surface's client.
    ///
    /// Per ADR 0017-rev2 (and the 2026-05-04 addendum), this is
    /// the wire-protocol-shaping step in the three-layer split:
    ///   - Input layer owns timestamps + modifier state.
    ///   - Recogniser owns gesture semantics + finger_count.
    ///   - Daemon (this function) owns wire shape: derives phase
    ///     from variant, attaches t_current and modifier flags,
    ///     packs the per-variant payload, routes by focused
    ///     surface.
    ///
    /// Routing matches forwardMouseEvents: getTopVisibleSurface,
    /// then send to local-or-remote owner. If no surface is
    /// focused the event is dropped (the recogniser is fed
    /// regardless, so subsequent gestures still work once focus
    /// arrives).
    ///
    /// System-gesture interception (e.g. compositor-handled
    /// three-finger swipe for window switching) is not
    /// implemented in Phase 2.4 per the rev2 ADR's deferral; all
    /// gestures route to clients today. The interception point,
    /// when added, sits at the top of this function.
    fn forwardGestureEvents(self: *Daemon, out: libsemainput.LibsemainputOutput, ts_ns: u64) void {
        const top_surface_id = self.surfaces.getTopVisibleSurface() orelse return;
        const surface = self.surfaces.getSurface(top_surface_id) orelse return;

        // Build the per-variant slot: gesture_type, phase, finger_count,
        // and the serialised payload (already encoded into a stack
        // buffer here so the rest of the function can be variant-
        // agnostic). Maximum payload size is 20 bytes
        // (ThreeFingerSwipePayload).
        var payload_buf: [20]u8 = undefined;
        var payload_len: usize = 0;

        const gtype: protocol.GestureType, const phase: protocol.GesturePhase, const finger_count: u8 = switch (out) {
            .n_click => |p| blk: {
                const pl = protocol.NClickPayload{
                    .button = p.button,
                    .count = p.count,
                    .x = p.x,
                    .y = p.y,
                };
                pl.serialize(payload_buf[0..protocol.NClickPayload.SIZE]);
                payload_len = protocol.NClickPayload.SIZE;
                // n_click is a discrete gesture (no begin/update/end
                // split); represent as phase=update, the most neutral
                // mid-stream value. begin/end would imply a lifecycle
                // the gesture doesn't have.
                break :blk .{ .n_click, .update, p.finger_count };
            },
            .drag_start => |p| blk: {
                const pl = protocol.DragPayload{ .contact_id = p.contact_id, .x = p.x, .y = p.y };
                pl.serialize(payload_buf[0..protocol.DragPayload.SIZE]);
                payload_len = protocol.DragPayload.SIZE;
                break :blk .{ .drag_start, .begin, p.finger_count };
            },
            .drag_move => |p| blk: {
                const pl = protocol.DragPayload{ .contact_id = p.contact_id, .x = p.x, .y = p.y };
                pl.serialize(payload_buf[0..protocol.DragPayload.SIZE]);
                payload_len = protocol.DragPayload.SIZE;
                break :blk .{ .drag_move, .update, p.finger_count };
            },
            .drag_end => |p| blk: {
                const pl = protocol.DragPayload{ .contact_id = p.contact_id, .x = p.x, .y = p.y };
                pl.serialize(payload_buf[0..protocol.DragPayload.SIZE]);
                payload_len = protocol.DragPayload.SIZE;
                break :blk .{ .drag_end, .end, p.finger_count };
            },
            .tap => |p| blk: {
                const pl = protocol.DragPayload{ .contact_id = p.contact_id, .x = p.x, .y = p.y };
                pl.serialize(payload_buf[0..protocol.DragPayload.SIZE]);
                payload_len = protocol.DragPayload.SIZE;
                // tap is discrete like n_click; phase=update.
                break :blk .{ .tap, .update, p.finger_count };
            },
            .scroll_begin => |p| blk: {
                payload_len = 0;
                break :blk .{ .scroll_begin, .begin, p.finger_count };
            },
            .two_finger_scroll => |p| blk: {
                const pl = protocol.TwoFingerScrollPayload{ .dx = p.dx, .dy = p.dy };
                pl.serialize(payload_buf[0..protocol.TwoFingerScrollPayload.SIZE]);
                payload_len = protocol.TwoFingerScrollPayload.SIZE;
                break :blk .{ .two_finger_scroll, .update, p.finger_count };
            },
            .scroll_end => |p| blk: {
                payload_len = 0;
                break :blk .{ .scroll_end, .end, p.finger_count };
            },
            .pinch_begin => |p| blk: {
                const pl = protocol.PinchBeginPayload{
                    .delta = p.delta,
                    .scale_factor = p.scale_factor,
                };
                pl.serialize(payload_buf[0..protocol.PinchBeginPayload.SIZE]);
                payload_len = protocol.PinchBeginPayload.SIZE;
                break :blk .{ .pinch_begin, .begin, p.finger_count };
            },
            .pinch => |p| blk: {
                const direction: protocol.PinchDirection = switch (p.direction) {
                    .in => .in,
                    .out => .out,
                };
                const pl = protocol.PinchPayload{
                    .delta = p.delta,
                    .scale_factor = p.scale_factor,
                    .direction = direction,
                };
                pl.serialize(payload_buf[0..protocol.PinchPayload.SIZE]);
                payload_len = protocol.PinchPayload.SIZE;
                break :blk .{ .pinch, .update, p.finger_count };
            },
            .pinch_end => |p| blk: {
                payload_len = 0;
                break :blk .{ .pinch_end, .end, p.finger_count };
            },
            .three_finger_swipe_begin => |p| blk: {
                const axis: protocol.SwipeAxis = switch (p.axis_locked) {
                    .none => .none,
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                };
                const pl = protocol.ThreeFingerSwipePayload{
                    .dx = p.dx,
                    .dy = p.dy,
                    .total_dx = p.total_dx,
                    .total_dy = p.total_dy,
                    .axis_locked = axis,
                    .confidence = p.confidence,
                };
                pl.serialize(payload_buf[0..protocol.ThreeFingerSwipePayload.SIZE]);
                payload_len = protocol.ThreeFingerSwipePayload.SIZE;
                break :blk .{ .three_finger_swipe_begin, .begin, p.finger_count };
            },
            .three_finger_swipe => |p| blk: {
                const axis: protocol.SwipeAxis = switch (p.axis_locked) {
                    .none => .none,
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                };
                const pl = protocol.ThreeFingerSwipePayload{
                    .dx = p.dx,
                    .dy = p.dy,
                    .total_dx = p.total_dx,
                    .total_dy = p.total_dy,
                    .axis_locked = axis,
                    .confidence = p.confidence,
                };
                pl.serialize(payload_buf[0..protocol.ThreeFingerSwipePayload.SIZE]);
                payload_len = protocol.ThreeFingerSwipePayload.SIZE;
                break :blk .{ .three_finger_swipe, .update, p.finger_count };
            },
            .three_finger_swipe_end => |p| blk: {
                payload_len = 0;
                break :blk .{ .three_finger_swipe_end, .end, p.finger_count };
            },
            .intent_hint => |p| blk: {
                const gesture: protocol.IntentGesture = switch (p.gesture) {
                    .two_finger_scroll => .two_finger_scroll,
                    .pinch => .pinch,
                    .three_finger_swipe => .three_finger_swipe,
                };
                const axis: protocol.IntentAxis = switch (p.axis) {
                    .none => .none,
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                    .in => .in,
                    .out => .out,
                };
                const pl = protocol.IntentHintPayload{
                    .gesture = gesture,
                    .axis = axis,
                    .confidence = p.confidence,
                };
                pl.serialize(payload_buf[0..protocol.IntentHintPayload.SIZE]);
                payload_len = protocol.IntentHintPayload.SIZE;
                // intent_hint is a prediction signal, not a phase
                // transition. phase=update is the closest neutral
                // value; clients that switch on phase to track
                // gesture lifecycle should ignore intent_hint
                // events and use the begin/end variants of the
                // predicted gesture instead.
                break :blk .{ .intent_hint, .update, p.finger_count };
            },
        };

        // Translate u8 backend modifier mask into u32 GestureFlags.
        // Bit ordering matches by construction (see Daemon.last_modifiers
        // doc comment); this is a direct bitcast through u32.
        const flags: protocol.GestureFlags = @bitCast(@as(u32, self.last_modifiers));

        const header = protocol.GestureEventMsg{
            .surface_id = top_surface_id,
            .gesture_type = gtype,
            .phase = phase,
            .finger_count = finger_count,
            .flags = flags,
            .t_current = ts_ns,
        };

        // Concatenate header + payload into a single buffer for the
        // send call. Maximum total wire size is 44 bytes
        // (24 header + 20 payload).
        var wire_buf: [protocol.GestureEventMsg.SIZE + 20]u8 = undefined;
        header.serialize(wire_buf[0..protocol.GestureEventMsg.SIZE]);
        if (payload_len > 0) {
            @memcpy(
                wire_buf[protocol.GestureEventMsg.SIZE..][0..payload_len],
                payload_buf[0..payload_len],
            );
        }
        const total_len = protocol.GestureEventMsg.SIZE + payload_len;

        // Try local first, then remote. Same routing pattern as
        // forwardMouseEvents.
        if (self.clients.findById(surface.owner)) |session| {
            session.send(.gesture_event, wire_buf[0..total_len]) catch |err| {
                log.warn("failed to send gesture event to local client {}: {}", .{ surface.owner, err });
            };
        } else if (self.remote_clients.get(surface.owner)) |remote_session| {
            remote_session.client.sendMessage(.gesture_event, wire_buf[0..total_len]) catch |err| {
                log.warn("failed to send gesture event to remote client {}: {}", .{ surface.owner, err });
            };
        }
    }
};

// ============================================================================
// AD-31.1: privilege drop
// ============================================================================
//
// semadrawd starts as root in the s6 supervision tree to permit:
//
//   - Opening /dev/draw (devfs default mode 0660 root:wheel until
//     AD-31.4 lands; even after, root opens are needed before the
//     privilege drop because retained fds outlive setuid).
//   - Mapping inputfs publication regions under /var/run/sema/input/.
//   - Binding the IPC listener at /var/run/sema/draw.sock and the
//     optional TCP listener.
//
// After Daemon.init() and Daemon.initCompositor() complete, all the
// privileged opens are done and the retained fds will outlive the
// setuid call. This function drops to a dedicated _semadraw system
// user so the long-running accept loop runs unprivileged. See
// semadraw/docs/adr/0006-multi-user-refactor.md §1 for the full
// design.
//
// The drop target uid/gid are passed via environment:
//   SEMADRAW_RUN_UID=<uid>
//   SEMADRAW_RUN_GID=<gid>
//
// install.sh creates the _semadraw user and the s6 run script
// discovers the uid/gid at startup and exports them.
//
// Behaviour by starting state:
//
//   - Running as root, env vars present and valid: drop, verify,
//     log success. This is the production path under s6.
//   - Running as root, env vars missing or invalid: refuse to
//     start. Running as root without dropping is a configuration
//     error.
//   - Running as non-root: log a warning that the drop was
//     skipped; continue. This is the development path (a bench
//     operator running semadrawd by hand).

const PrivilegeDropError = error{
    InvalidEnvUid,
    InvalidEnvGid,
    EnvVarMissing,
    SetgidFailed,
    SetuidFailed,
    DropVerifyFailed,
};

fn dropPrivileges() !void {
    const starting_uid = posix.getuid();
    if (starting_uid != 0) {
        log.warn("not running as root (uid={d}); skipping privilege drop", .{starting_uid});
        log.warn("this is acceptable for development; production deployment under s6 starts as root", .{});
        return;
    }

    // Read drop-target uid and gid from environment. posix.getenv returns
    // ?[]const u8; null means the variable is unset.
    const env_uid = posix.getenv("SEMADRAW_RUN_UID") orelse {
        log.err("running as root but SEMADRAW_RUN_UID is unset; refusing to start", .{});
        log.err("the s6 run script should set SEMADRAW_RUN_UID and SEMADRAW_RUN_GID before exec", .{});
        return PrivilegeDropError.EnvVarMissing;
    };
    const env_gid = posix.getenv("SEMADRAW_RUN_GID") orelse {
        log.err("running as root but SEMADRAW_RUN_GID is unset; refusing to start", .{});
        return PrivilegeDropError.EnvVarMissing;
    };

    const target_uid = std.fmt.parseInt(posix.uid_t, env_uid, 10) catch {
        log.err("SEMADRAW_RUN_UID is not a valid integer: '{s}'", .{env_uid});
        return PrivilegeDropError.InvalidEnvUid;
    };
    const target_gid = std.fmt.parseInt(posix.gid_t, env_gid, 10) catch {
        log.err("SEMADRAW_RUN_GID is not a valid integer: '{s}'", .{env_gid});
        return PrivilegeDropError.InvalidEnvGid;
    };

    if (target_uid == 0) {
        log.err("SEMADRAW_RUN_UID is 0; refusing to drop to root", .{});
        return PrivilegeDropError.InvalidEnvUid;
    }
    if (target_gid == 0) {
        log.err("SEMADRAW_RUN_GID is 0; refusing to drop to gid 0", .{});
        return PrivilegeDropError.InvalidEnvGid;
    }

    // setgid first, then setuid. Once setuid drops root, setgid would fail.
    posix.setgid(target_gid) catch |err| {
        log.err("setgid({d}) failed: {}", .{ target_gid, err });
        return PrivilegeDropError.SetgidFailed;
    };
    posix.setuid(target_uid) catch |err| {
        log.err("setuid({d}) failed: {}", .{ target_uid, err });
        return PrivilegeDropError.SetuidFailed;
    };

    // Verify the drop took. On a correctly-running kernel, a successful
    // setuid()/setgid() pair makes both real and effective ids match the
    // target. Step 6 of ADR 0006 §1: verify so a hypothetical kernel bug
    // that returned success without dropping does not leave the daemon
    // running as root with a false sense of security.
    //
    // We only verify uid here. std.posix exposes getuid/geteuid but not
    // getgid/getegid in Zig 0.15.2, and std.c does not expose them
    // either. The gid-side verification was always defense-in-depth: if
    // posix.setgid above returned success, the kernel reported the gid
    // actually changed. A kernel that lies about setgid success but
    // also lies consistently about getgid would defeat any check we
    // could write; that is not a real failure mode. The uid check still
    // catches the plausible failure mode (operator misconfiguration
    // where SEMADRAW_RUN_UID is wrong).
    const post_uid = posix.getuid();
    const post_euid = posix.geteuid();
    if (post_uid != target_uid or post_euid != target_uid) {
        log.err("privilege-drop verification failed: post-drop uid={d} euid={d}, expected uid={d}", .{
            post_uid, post_euid, target_uid,
        });
        return PrivilegeDropError.DropVerifyFailed;
    }

    log.info("dropped privileges: uid {d} -> {d}, gid -> {d}", .{
        starting_uid, target_uid, target_gid,
    });
}

pub fn main(init: std.process.Init.Minimal) !void {
    // Ignore SIGPIPE to prevent daemon from dying when clients disconnect
    // This is standard practice for server applications
    const act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &act, null);

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args_owned = try compat.args.alloc(allocator, init.args);
    defer args_owned.deinit(allocator);
    const args = args_owned.argv;

    var config = Config{};

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--socket") or std.mem.startsWith(u8, arg, "--socket=")) {
            const socket_path = if (std.mem.startsWith(u8, arg, "--socket="))
                arg["--socket=".len..]
            else blk: {
                i += 1;
                if (i >= args.len) {
                    log.err("missing argument for {s}", .{arg});
                    return error.InvalidArgument;
                }
                break :blk args[i];
            };
            config.socket_path = socket_path;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--backend") or std.mem.startsWith(u8, arg, "--backend=")) {
            const backend_name = if (std.mem.startsWith(u8, arg, "--backend="))
                arg["--backend=".len..]
            else blk: {
                i += 1;
                if (i >= args.len) {
                    log.err("missing argument for {s}", .{arg});
                    return error.InvalidArgument;
                }
                break :blk args[i];
            };
            if (std.mem.eql(u8, backend_name, "software")) {
                config.backend_type = .software;
            } else if (std.mem.eql(u8, backend_name, "headless")) {
                config.backend_type = .headless;
            } else if (std.mem.eql(u8, backend_name, "kms")) {
                config.backend_type = .kms;
            } else if (std.mem.eql(u8, backend_name, "x11")) {
                config.backend_type = .x11;
            } else if (std.mem.eql(u8, backend_name, "vulkan")) {
                config.backend_type = .vulkan;
            } else if (std.mem.eql(u8, backend_name, "vulkan_console") or std.mem.eql(u8, backend_name, "vulkan-console")) {
                config.backend_type = .vulkan_console;
            } else if (std.mem.eql(u8, backend_name, "wayland")) {
                config.backend_type = .wayland;
            } else if (std.mem.eql(u8, backend_name, "drawfs")) {
                config.backend_type = .drawfs;
            } else {
                log.err("unknown backend: {s} (valid: software, headless, kms, x11, vulkan, vulkan_console, wayland, drawfs)", .{backend_name});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tcp") or std.mem.startsWith(u8, arg, "--tcp=")) {
            const tcp_str = if (std.mem.startsWith(u8, arg, "--tcp="))
                arg["--tcp=".len..]
            else blk: {
                i += 1;
                if (i >= args.len) {
                    log.err("missing argument for {s}", .{arg});
                    return error.InvalidArgument;
                }
                break :blk args[i];
            };
            config.tcp_port = std.fmt.parseInt(u16, tcp_str, 10) catch {
                log.err("invalid TCP port: {s}", .{tcp_str});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--tcp-addr") or std.mem.startsWith(u8, arg, "--tcp-addr=")) {
            const addr_str = if (std.mem.startsWith(u8, arg, "--tcp-addr="))
                arg["--tcp-addr=".len..]
            else blk: {
                i += 1;
                if (i >= args.len) {
                    log.err("missing argument for {s}", .{arg});
                    return error.InvalidArgument;
                }
                break :blk args[i];
            };
            // Parse IP address (simple dotted quad parsing)
            var parts: [4]u8 = undefined;
            var part_idx: usize = 0;
            var iter = std.mem.splitScalar(u8, addr_str, '.');
            while (iter.next()) |part| {
                if (part_idx >= 4) {
                    log.err("invalid IP address: {s}", .{addr_str});
                    return error.InvalidArgument;
                }
                parts[part_idx] = std.fmt.parseInt(u8, part, 10) catch {
                    log.err("invalid IP address: {s}", .{addr_str});
                    return error.InvalidArgument;
                };
                part_idx += 1;
            }
            if (part_idx != 4) {
                log.err("invalid IP address: {s}", .{addr_str});
                return error.InvalidArgument;
            }
            config.tcp_addr = parts;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--resolution") or std.mem.startsWith(u8, arg, "--resolution=")) {
            const res_str = if (std.mem.startsWith(u8, arg, "--resolution="))
                arg["--resolution=".len..]
            else blk: {
                i += 1;
                if (i >= args.len) {
                    log.err("missing argument for {s}", .{arg});
                    return error.InvalidArgument;
                }
                break :blk args[i];
            };
            // Parse resolution in WIDTHxHEIGHT format
            var res_iter = std.mem.splitScalar(u8, res_str, 'x');
            const width_str = res_iter.next() orelse {
                log.err("invalid resolution format: {s} (expected WIDTHxHEIGHT)", .{res_str});
                return error.InvalidArgument;
            };
            const height_str = res_iter.next() orelse {
                log.err("invalid resolution format: {s} (expected WIDTHxHEIGHT)", .{res_str});
                return error.InvalidArgument;
            };
            config.width = std.fmt.parseInt(u32, width_str, 10) catch {
                log.err("invalid width in resolution: {s}", .{res_str});
                return error.InvalidArgument;
            };
            config.height = std.fmt.parseInt(u32, height_str, 10) catch {
                log.err("invalid height in resolution: {s}", .{res_str});
                return error.InvalidArgument;
            };
            if (config.width < 320 or config.height < 200) {
                log.err("resolution too small (minimum 320x200)", .{});
                return error.InvalidArgument;
            }
            if (config.width > 7680 or config.height > 4320) {
                log.err("resolution too large (maximum 7680x4320)", .{});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            log.info("semadrawd - SemaDraw compositor daemon", .{});
            log.info("Usage: semadrawd [OPTIONS]", .{});
            log.info("Options:", .{});
            log.info("  -s, --socket PATH     Socket path (default: {s})", .{protocol.DEFAULT_SOCKET_PATH});
            log.info("  -b, --backend TYPE    Backend type: software, headless, kms, x11, vulkan, vulkan_console, wayland, drawfs (default: software)", .{});
            log.info("  -r, --resolution WxH  Display resolution (default: 1920x1080)", .{});
            log.info("  -t, --tcp PORT        Enable TCP remote connections on PORT (default: disabled)", .{});
            log.info("  --tcp-addr ADDR       TCP bind address (default: 0.0.0.0)", .{});
            log.info("  -h, --help            Show this help", .{});
            return;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    var daemon = Daemon.init(allocator, config) catch |err| switch (err) {
        // Friendly message for the most common operator-facing case:
        // another semadrawd is already listening on the socket path.
        // socket_server.bind detects this via a probe connect; without
        // that detection a second instance would silently displace the
        // first, leaving a zombie listener.
        error.AlreadyRunning => {
            log.err("another semadrawd is already listening on {s}; refusing to start", .{config.socket_path});
            log.err("if no semadrawd should be running, check `sockstat -u | grep semadraw`", .{});
            log.err("or `service semadraw status`; remove stale processes before retrying", .{});
            return error.AlreadyRunning;
        },
        else => return err,
    };
    defer daemon.deinit();

    // Initialise session token for unified event log emission.
    events.initSession();

    try daemon.initCompositor();

    // AD-31.1: drop privileges before the long-running accept loop.
    // All device opens and listener binds completed inside Daemon.init
    // and Daemon.initCompositor; the retained fds outlive setuid.
    // See dropPrivileges above and ADR 0006 §1.
    try dropPrivileges();

    try daemon.run();
}

// ============================================================================
// Migration time idiom (P2 Tranche 2): file-local wall-clock helper.
// Replaces std.time.nanoTimestamp(), removed in Zig 0.16. REALTIME preserves
// the wall-clock semantics of these externally visible timestamp values.
// Duplicated per file by design during migration; consolidation deferred.
// ============================================================================

fn realtimeNowNs() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

// ============================================================================
// Migration raw-fd idiom (P2 WT3): file-local close helper.
// Replaces posix.close, removed in Zig 0.16, with the raw libc call. Mirrors
// the closeFd precedent in socket_server. Duplicated per file by design.
// ============================================================================

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}
