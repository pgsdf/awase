// SM-2 T0 stage (ADR 0021 Section 9, ratified option (a)): the idle
// blank policy, the first tenant of the SM-2 agent's permanent home.
//
// Structural note. Sessiond ADR 0010 D6 left open whether the
// per-session policy agent is a thin separate daemon or is folded
// into pgsd-sessiond's own wait loop; ADR 0021 Section 9(a) was
// worded against the thin-daemon shape ("signal pgsd-sessiond").
// This implementation takes the folded shape: pgsd-sessiond is the
// process that blocks for the whole session anyway (launch.zig's
// waitpid), it is already the ADR 0010 session authority holding
// the control-socket privilege, and folding removes an entire
// agent-to-sessiond signaling channel that the T0-only stage does
// not need. The later SM-2 stages (lock trigger, SM-3 suspend) slot
// into the same tick. If a separate agent is ever wanted, this
// module lifts out unchanged and the "signal" becomes its IPC.
//
// The policy per tick (ADR 0021 Section 9(a) and ADR 0013 D2):
//
//   - query semadrawd's published last_input_ts_ns over the client
//     socket (idle_query, ADR 0013);
//   - compute idle = monotonic-now - last_input_ts_ns. The timestamp
//     domain is inputfs's nanouptime, which userland reads as
//     CLOCK_MONOTONIC (compat.time.nowMonotonic);
//   - at idle >= T0, send blank on the control socket, once per
//     idle period (the compositor acknowledges idempotently, but a
//     request per tick would be noise);
//   - idle below T0 re-arms: the compositor woke itself on input
//     (ADR 0021 Section 4), which is visible here purely as the
//     idle measure collapsing.
//
// A published value of 0 is the ADR 0013 D3 sentinel (no input seen
// since the daemon started) and is skipped rather than treated as
// infinite idle: blanking a display nobody has touched since a
// compositor restart, possibly seconds after boot, is not the
// operator's intent; the first real input starts the clock.
//
// Failure posture: fail-open to ON, recorded as intended in
// ADR 0021 Section 12. Every connection here is optional and
// retried on the next tick; a compositor restart mid-session shows
// up as query failure, both connections are dropped and re-dialed,
// and in the meantime the display simply does not blank.

const std = @import("std");
const posix = std.posix;
const compat = @import("compat");
const semadraw = @import("semadraw");

const control = semadraw.control;

/// Environment knob: blank timeout in seconds. 0 disables. The
/// default is the operator-requested 15 minutes (ADR 0021 Section 1);
/// the ADR 0009 timeline gains this as the optional T0 stage.
pub const ENV_BLANK_TIMEOUT = "PGSD_BLANK_TIMEOUT_S";

/// T0, the idle blank timeout.
///
/// Operator decision 2026-07-13: 120 seconds, from 900. Overridable with
/// PGSD_BLANK_TIMEOUT_S, which is what a bench operator wants when two
/// minutes is too eager for the work in front of them.
pub const DEFAULT_T0_S: u64 = 120;

/// How often the policy is ticked, in caller passes.
///
/// Hoisted here from launch.zig because there are now TWO callers (the
/// session wait loop, and the login render loop), and a policy rate
/// duplicated at each call site is a policy rate that drifts. Both
/// callers poll at a 1-second cadence, so this is a 10-second tick.
///
/// The tick is cheap: it asks semadrawd for the last-input time and
/// compares. The blank itself happens once, on the transition.
pub const POLICY_EVERY: u32 = 10;

pub const IdlePolicy = struct {
    allocator: std.mem.Allocator,
    t0_ns: u64,
    conn: ?*semadraw.client.Connection = null,
    ctl_fd: ?posix.fd_t = null,
    blank_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator) IdlePolicy {
        var t0_s: u64 = DEFAULT_T0_S;
        if (compat.args.getenv(ENV_BLANK_TIMEOUT)) |v| {
            t0_s = std.fmt.parseInt(u64, v, 10) catch DEFAULT_T0_S;
        }
        return .{
            .allocator = allocator,
            .t0_ns = t0_s * std.time.ns_per_s,
        };
    }

    pub fn deinit(self: *IdlePolicy) void {
        // disconnect() destroys the heap Connection (it owns itself
        // via its allocator); just drop the pointer after.
        if (self.conn) |conn| conn.disconnect();
        self.conn = null;
        if (self.ctl_fd) |fd| _ = posix.system.close(fd);
        self.ctl_fd = null;
    }

    /// One policy evaluation. Called from the session wait loop at
    /// policy rate (seconds); every failure path returns quietly and
    /// the next tick retries.
    pub fn tick(self: *IdlePolicy) void {
        if (self.t0_ns == 0) return;

        // Keep the control connection's inbound side drained: the
        // compositor sends display_state notifications on every
        // transition (ADR 0021 Section 8) and acks our requests;
        // this stage acts on none of them (idle collapsing on wake
        // is the signal it uses), but leaving them unread would
        // grow the socket buffer across a long session.
        self.drainCtl();

        if (self.conn == null) {
            self.conn = semadraw.client.Connection.connect(self.allocator) catch null;
            if (self.conn == null) return;
        }

        const last_input = self.conn.?.queryIdle() catch {
            // Compositor gone (restart, crash): drop both channels
            // and re-dial next tick. Fail-open. disconnect() also
            // destroys the Connection.
            self.conn.?.disconnect();
            self.conn = null;
            if (self.ctl_fd) |fd| {
                _ = posix.system.close(fd);
                self.ctl_fd = null;
            }
            return;
        };
        if (last_input == 0) return; // ADR 0013 D3 sentinel

        const now: u64 = @intCast(compat.time.nowMonotonic());
        if (now <= last_input) return; // clock skew guard
        const idle = now - last_input;

        if (idle >= self.t0_ns) {
            if (!self.blank_requested) {
                self.sendBlank();
            }
        } else {
            self.blank_requested = false;
        }
    }

    fn ensureCtl(self: *IdlePolicy) ?posix.fd_t {
        if (self.ctl_fd) |fd| return fd;
        const fd = compat.posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;
        // Derive the path length from the type rather than hardcoding it.
        //
        // This was `[_]u8{0} ** 104`, the sun_path size on FreeBSD, which
        // compiled only because the target happened to match. Wiring the
        // policy into the login render loop pulled idle.zig into a compile
        // path it had not been in, and the hardcoded 104 failed against a
        // platform whose sockaddr.un is 108. The number was never ours to
        // assert: it belongs to the struct.
        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = std.mem.zeroes(@FieldType(posix.sockaddr.un, "path")),
        };
        const path = control.DEFAULT_CTL_SOCKET_PATH;
        @memcpy(addr.path[0..path.len], path);
        compat.posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            _ = posix.system.close(fd);
            return null;
        };
        self.ctl_fd = fd;
        return fd;
    }

    fn sendBlank(self: *IdlePolicy) void {
        const fd = self.ensureCtl() orelse return;
        var out: [control.CtlHeader.SIZE]u8 = undefined;
        (control.CtlHeader{ .msg_type = .blank, .flags = 0, .length = 0 }).serialize(&out);
        var off: usize = 0;
        while (off < out.len) {
            const wn = posix.system.write(fd, out[off..].ptr, out.len - off);
            if (wn < 0) {
                // Peer gone; drop and re-dial next tick. blank stays
                // unrequested so the retry actually retries.
                _ = posix.system.close(fd);
                self.ctl_fd = null;
                return;
            }
            off += @intCast(wn);
        }
        self.blank_requested = true;
        // The ack (and the transition notification) arrive on this
        // socket and are consumed by drainCtl on subsequent ticks;
        // the request is fire-and-forget at this layer, matching the
        // secret-free trigger shape of sessiond ADR 0010 D6.
    }

    fn drainCtl(self: *IdlePolicy) void {
        const fd = self.ctl_fd orelse return;
        var scratch: [256]u8 = undefined;
        while (true) {
            const rc = posix.system.recv(fd, &scratch, scratch.len, posix.MSG.DONTWAIT);
            if (rc <= 0) {
                if (rc == 0) {
                    // Orderly close by the compositor.
                    _ = posix.system.close(fd);
                    self.ctl_fd = null;
                }
                return;
            }
        }
    }
};
