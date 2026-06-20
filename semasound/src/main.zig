// semasound: userland audio broker (AD-3 F.5).
//
// F.5.a (ADR 0021): binds the Unix stream socket, does the Hello handshake,
// spawns a reader thread per client filling that client's ring, runs the
// mixer/output thread (output.zig) as the sole writer to /dev/audiofs0 paced
// by the device's blocking write, and runs the xrun consumer (xrun.zig) that
// polls /dev/audiofs_notify and records xrun events (record-and-continue).

const std = @import("std");
const posix = std.posix;
const compat = @import("compat");
const protocol = @import("protocol.zig");
const client_mod = @import("client.zig");
const output = @import("output.zig");
const xrun = @import("xrun.zig");
const resampler = @import("resampler.zig");
const estimator_thread = @import("estimator_thread.zig");
const election = @import("election.zig");
const DeviceFd = @import("device_fd.zig").DeviceFd;
const target_mod = @import("target.zig");
const policy_mod = @import("policy.zig");
const policy_state = @import("policy_state.zig");
const state_mod = @import("state.zig");

// F.5.c (ADR 0025 Decision 2): the static two-target topology. `default` is
// the device target (fd installed at startup); `null` is the paced discard
// sink. Each target is a fully isolated mixing domain (Decision 1).
var g_targets = [_]target_mod.Target{
    .{ .name = "default", .sink = .{ .device = -1 } },
    .{ .name = "null", .sink = .null_sink },
};
var g_stop = std.atomic.Value(bool).init(false);
var g_xrun_count = std.atomic.Value(u64).init(0);
// System-production counter for the F.5.b output-domain drift estimator
// (output.zig bumps it per write; the estimator thread reads it).
// Device fd, opened by main before the listener serves anyone; written once
// at startup, then read-only (output thread writes audio through it, accept
// path issues election ioctls on it). Also installed into g_targets[0].
// AD-50 device layer: the device fd is a single-owner DeviceFd. The
// output thread owns lifecycle (release/adopt) and reads its hot path
// via snapshot() without locking; the accept path touches the fd only
// through use(), under the lock, so the fd cannot be closed and recycled
// mid-ioctl. This replaces the AD-47 bare atomic whose "never close, so
// no reader races a close" policy deadlocked the reconnect against
// audiofs's exclusive open (EBUSY while the dead fd was held).
var g_out_dev: DeviceFd = .init(-1);
// AD-50: the null target's Ctx takes the same DeviceFd pointer shape;
// this one stays -1 for the daemon's life (runNull never opens a device).
var g_null_dev: DeviceFd = .init(-1);

const POLICY_ETC = "/usr/local/etc/semasound";

fn nowNs() i64 {
    return @intCast(compat.time.nowMonotonic());
}

// Migration shims for the removed std.posix.write and std.posix.open. Both go
// through posix.system.* (the Class F write path and the Class E open idiom used
// across the tree). writeBytes is single-shot and fire-and-forget at most call
// sites; its one caller that acts on failure keeps catching the owned error.
fn writeBytes(fd: posix.fd_t, bytes: []const u8) error{WriteFailed}!void {
    const n = posix.system.write(fd, bytes.ptr, bytes.len);
    if (n < 0) return error.WriteFailed;
}

fn openWronly(path: []const u8) !posix.fd_t {
    var path_buf = try posix.toPosixPath(path);
    const fd = posix.system.open(&path_buf, .{ .ACCMODE = .WRONLY }, @as(posix.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    return fd;
}

// F.5.f (ADR 0028 Decision 3): prompt, signal-driven shutdown. The handler
// performs SIGNAL-SAFE immediate teardown only: a one-line notice (write),
// unlinking the socket path (unlink), and _exit. Deliberately no cooperative
// unwinding: waking a blocked accept or a blocked device write portably from
// a handler is fragile machinery, and everything a cooperative path would
// clean up is already crash-safe (stale-socket unlink at startup, kernel fd
// reclamation, GET_FORMAT rest-state seeding, runtime-instance publish_seq).
fn handleSignal(_: posix.SIG) callconv(.c) void {
    const msg = "semasound: signal received, shutting down\n";
    writeBytes(posix.STDERR_FILENO, msg) catch {};
    _ = posix.system.unlink(protocol.SOCKET_PATH);
    std.c._exit(0);
}

fn installSignalHandlers() void {
    var sa = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &sa, null);
    posix.sigaction(posix.SIG.INT, &sa, null);
}

// F.5.d (ADR 0026 Decision 3): reload every target's policy from etc and
// rewrite the validation surfaces. Called at startup and on every accepted
// connection before the routing decision (live-edit contract). Single
// accept thread; the audio threads see only the mirrored duck_milli atomic
// and per-client override flags.
fn reloadPolicies() void {
    for (&g_targets) |*t| {
        var pb: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/{s}.policy", .{ POLICY_ETC, t.name }) catch continue;
        t.policy = policy_mod.loadFile(path);
        t.duck_milli.store(t.policy.duck_milli, .monotonic);
        policy_state.writeValidation(t.name, &t.policy);
    }
}

// Group busyness (ADR 0026 Decision 6): another target sharing this
// target's group has active clients, where "active" is precisely the
// admitted-and-not-reaped definition the 0-to-1 election uses (operator
// amendment).
fn groupBusy(tgt: *target_mod.Target) bool {
    const g = tgt.policy.group() orelse return false;
    for (&g_targets) |*o| {
        if (o == tgt) continue;
        const og = o.policy.group() orelse continue;
        if (std.mem.eql(u8, g, og) and o.set.activeCount() > 0) return true;
    }
    return false;
}

// Group preemption (ADR 0026 Decision 6): the ONE place stream termination
// survives, and it is protocol-visible: each preempted client receives
// STATUS_PREEMPTED, then its socket is shut down; its reader sees EOF and
// the slot reaps. Never emitted for ducking (operator amendment).
fn preemptGroupPeers(tgt: *target_mod.Target) void {
    const g = tgt.policy.group() orelse return;
    for (&g_targets) |*o| {
        if (o == tgt) continue;
        const og = o.policy.group() orelse continue;
        if (!std.mem.eql(u8, g, og)) continue;
        var ptrs: [client_mod.MAX_CLIENTS]*client_mod.Client = undefined;
        const n = o.set.snapshotActive(&ptrs);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const c = ptrs[i];
            writeBytes(c.fd, &[_]u8{protocol.STATUS_PREEMPTED}) catch {};
            compat.posix.shutdown(c.fd, .both) catch {};
            std.debug.print("semasound: policy: preempted client {d} on {s} (group {s})\n", .{ c.id, o.name, g });
            var db: [64]u8 = undefined;
            const d = std.fmt.bufPrint(&db, "id={d} group={s}", .{ c.id, g }) catch db[0..0];
            o.events.append(.preempted, nowNs(), o.frames_written.load(.monotonic), d);
        }
    }
}

fn readFull(fd: posix.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.read(fd, buf[off..]);
        if (n == 0) return error.Eof;
        off += n;
    }
}

fn handleAccept(conn: posix.fd_t, id: u32) void {
    var hello: protocol.Hello = undefined;
    readFull(conn, std.mem.asBytes(&hello)) catch {
        _ = posix.system.close(conn);
        return;
    };
    if (!protocol.helloIsAcceptable(hello)) {
        writeBytes(conn, &[_]u8{protocol.STATUS_REJECTED}) catch {};
        writeBytes(conn, "error: F.5.b accepts 16-bit mono/stereo at a supported rate\n") catch {};
        _ = posix.system.close(conn);
        return;
    }
    // F.5.c (ADR 0025 Decision 3): resolve the Hello's target. Empty routes
    // to "default"; unknown names are rejected, broker surviving. The binding
    // is immutable for the connection's lifetime (re-route is a reconnect).
    const tname = protocol.targetName(&hello);
    const requested = target_mod.find(&g_targets, tname) orelse {
        writeBytes(conn, &[_]u8{protocol.STATUS_REJECTED}) catch {};
        writeBytes(conn, "error: unknown target\n") catch {};
        _ = posix.system.close(conn);
        return;
    };

    // F.5.d (ADR 0026): policy gate. Reload (live-edit contract), evaluate
    // rules on the REQUESTED target, then group exclusivity (with the one
    // protocol-visible preemption case), then one-hop ADMISSION-ONLY
    // fallback (operator amendment: no migration, no retry; a denial after
    // the hop is final).
    reloadPolicies();
    const label = protocol.labelOf(&hello);
    const class = protocol.classOf(&hello);
    var tgt = requested;
    var denied = policy_mod.evaluate(&requested.policy, label, class) == .deny;
    if (!denied and groupBusy(requested)) {
        if (requested.policy.isOverrideClass(class)) {
            preemptGroupPeers(requested);
        } else {
            denied = true;
        }
    }
    if (denied) {
        var admitted_via_fallback = false;
        if (requested.policy.fallbackTarget()) |ftn| {
            if (target_mod.find(&g_targets, ftn)) |ft| {
                if (ft != requested and
                    policy_mod.evaluate(&ft.policy, label, class) == .allow and
                    !groupBusy(ft))
                {
                    tgt = ft;
                    admitted_via_fallback = true;
                    var db: [96]u8 = undefined;
                    const d = std.fmt.bufPrint(&db, "label={s} class={s} to={s}", .{ label, class, ft.name }) catch db[0..0];
                    requested.events.append(.fallback, nowNs(), requested.frames_written.load(.monotonic), d);
                }
            }
        }
        if (!admitted_via_fallback) {
            var db: [80]u8 = undefined;
            const d = std.fmt.bufPrint(&db, "label={s} class={s}", .{ label, class }) catch db[0..0];
            requested.events.append(.denied, nowNs(), requested.frames_written.load(.monotonic), d);
            policy_state.writeLastEvaluation(requested.name, label, class, "deny");
            writeBytes(conn, &[_]u8{protocol.STATUS_REJECTED}) catch {};
            writeBytes(conn, "error: denied by policy\n") catch {};
            _ = posix.system.close(conn);
            std.debug.print("semasound: policy: denied label={s} class={s} on {s}\n", .{ label, class, requested.name });
            return;
        }
    }
    policy_state.writeLastEvaluation(requested.name, label, class, "allow");
    // Stage 2 (ADR 0024 Decisions 1+2) carried per-target (ADR 0025 Decision
    // 5 invariant: election is a function of THIS target's client set alone):
    // hardware-rate election runs ONLY on the target's 0-to-1 transition,
    // here in the accept path before the reader starts, so a client never
    // spans an election and its resampler choice below is immutable for its
    // lifetime. Device targets only; the null sink is fixed at 48 kHz. The
    // accept loop is single-threaded, so the count check and the add are not
    // racing another admission. (A dying-but-unreaped client makes the count
    // nonzero and conservatively suppresses election: the new client is
    // resampled to the current rate, which is correct overlap behavior.)
    if (tgt.isDevice() and tgt.set.activeCount() == 0) {
        const before = tgt.election.rate();
        _ = g_out_dev.use(u32, election.applyElectionFd, .{ &tgt.election, election.electFor(hello.rate_hz) });
        const after = tgt.election.rate();
        if (after != before) {
            var db: [48]u8 = undefined;
            const d = std.fmt.bufPrint(&db, "from={d} to={d}", .{ before, after }) catch db[0..0];
            tgt.events.append(.election, nowNs(), tgt.frames_written.load(.monotonic), d);
        }
    }
    const c = tgt.set.add(conn, id) orelse {
        writeBytes(conn, &[_]u8{protocol.STATUS_REJECTED}) catch {};
        _ = posix.system.close(conn);
        return;
    };
    // Set the client's input format and install a resampler unless the input
    // is already at the target's rate in stereo (the bit-exact passthrough
    // case). Immutable for the client's lifetime (see above).
    c.in_rate = hello.rate_hz;
    c.in_channels = hello.channels;
    c.override_member = tgt.policy.isOverrideClass(class);
    c.setIdentity(label, class);
    const hw_rate: u32 = tgt.hwRate();
    if (!(hello.rate_hz == hw_rate and hello.channels == protocol.CANON_CHANNELS)) {
        c.resampler = resampler.Resampler.init(hello.rate_hz, hw_rate);
    }
    writeBytes(conn, &[_]u8{protocol.STATUS_ACCEPTED}) catch {
        c.closed.store(true, .release); // reap frees the slot and fd
        return;
    };
    c.thread = std.Thread.spawn(.{}, client_mod.readerRun, .{c}) catch {
        c.closed.store(true, .release);
        return;
    };
    std.debug.print(
        "semasound: client {d} accepted ({d} active on {s}) label={s} class={s} requested={s} rate={d} ch={d} hw={d}{s}{s}\n",
        .{ id, tgt.set.activeCount(), tgt.name, label, class, requested.name, hello.rate_hz, hello.channels, tgt.hwRate(), if (c.resampler != null) " [resampling]" else " [passthrough]", if (c.override_member) " [override]" else "" },
    );
    {
        var db: [96]u8 = undefined;
        const d = std.fmt.bufPrint(&db, "id={d} label={s} class={s} rate={d}", .{ id, label, class, hello.rate_hz }) catch db[0..0];
        tgt.events.append(.admitted, nowNs(), tgt.frames_written.load(.monotonic), d);
    }
}

pub fn main() !void {
    const lfd = try compat.posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer _ = posix.system.close(lfd);

    _ = posix.system.unlink(protocol.SOCKET_PATH);

    var addr: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = [_]u8{0} ** 104,
    };
    if (protocol.SOCKET_PATH.len >= addr.path.len) return error.SocketPathTooLong;
    @memcpy(addr.path[0..protocol.SOCKET_PATH.len], protocol.SOCKET_PATH);
    try compat.posix.bind(lfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    try compat.posix.listen(lfd, 8);

    std.debug.print("semasound F.5.a: listening on {s}\n", .{protocol.SOCKET_PATH});
    installSignalHandlers();

    // Stage 2: main owns the device fd so the accept path can issue election
    // ioctls on it (single-open device; the output thread writes through the
    // same fd). Opened before the listener serves anyone, so the fd is always
    // valid when handleAccept runs. Seed the elected-rate state from the
    // device: the lazy rest state means it may rest at a non-48k rate from a
    // previous broker run.
    // AD-47: a missing device no longer aborts the daemon. The output
    // thread starts on the null sink and its device layer reconnects;
    // election seeding happens at reopen instead.
    const startup_fd: std.posix.fd_t = openWronly(protocol.DEVICE_PATH) catch |e| blk: {
        std.debug.print("semasound: cannot open {s}: {any}; starting on null sink, device layer will reconnect\n", .{ protocol.DEVICE_PATH, e });
        break :blk -1;
    };
    if (startup_fd >= 0) {
        g_out_dev.adopt(startup_fd);
        std.debug.print(
            "semasound: output open on {s} ({d} Hz canonical), mixing\n",
            .{ protocol.DEVICE_PATH, protocol.CANON_RATE },
        );
        election.seedFromDevice(&g_targets[0].election, startup_fd);
    }
    g_targets[0].sink = .{ .device = startup_fd };
    std.debug.print("semasound: target default -> {s}\n", .{protocol.DEVICE_PATH});
    std.debug.print("semasound: target null -> paced discard sink\n", .{});

    // F.5.d: policy surfaces and initial load (ADR 0026 Decisions 2+3).
    for (&g_targets) |*t| policy_state.ensureDir(t.name);
    for (&g_targets) |*t| state_mod.writeStatic(t);
    reloadPolicies();
    for (&g_targets) |*t| {
        std.debug.print("semasound: policy[{s}]: {s}\n", .{ t.name, if (t.policy.isValid()) "valid" else "INVALID (see policy-errors)" });
    }

    const out_thread = try std.Thread.spawn(.{}, output.run, .{output.Ctx{
        .set = &g_targets[0].set,
        .stop = &g_stop,
        .frames_written = &g_targets[0].frames_written,
        .fd = &g_out_dev,
        .election = &g_targets[0].election,
        .name = "default",
        .duck_milli = &g_targets[0].duck_milli,
        .events = &g_targets[0].events,
    }});
    out_thread.detach();

    const pub_thread = try std.Thread.spawn(.{}, state_mod.run, .{state_mod.Ctx{
        .targets = g_targets[0..],
        .stop = &g_stop,
    }});
    pub_thread.detach();

    const null_thread = try std.Thread.spawn(.{}, output.runNull, .{output.Ctx{
        .set = &g_targets[1].set,
        .stop = &g_stop,
        .frames_written = &g_targets[1].frames_written,
        .fd = &g_null_dev,
        .election = null,
        .name = "null",
        .duck_milli = &g_targets[1].duck_milli,
        .events = &g_targets[1].events,
    }});
    null_thread.detach();

    const xrun_thread = try std.Thread.spawn(.{}, xrun.run, .{xrun.Ctx{
        .stop = &g_stop,
        .xrun_count = &g_xrun_count,
    }});
    xrun_thread.detach();

    // F.5.b output-domain drift estimator. Runs on its own 5s-window cadence,
    // reads the F.4 clock and the output-frame counter, and fans the shared
    // trim out to active clients' resamplers. Separate from the mix loop by
    // design (ADR 0007).
    // Drift estimation is a device-target concern (ADR 0025 Decision 5):
    // one estimator for `default`; the null sink has no hardware to drift
    // against and gets none.
    const est_thread = try std.Thread.spawn(.{}, estimator_thread.run, .{estimator_thread.Ctx{
        .set = &g_targets[0].set,
        .stop = &g_stop,
    }});
    est_thread.detach();

    var next_id: u32 = 1;
    while (!g_stop.load(.acquire)) {
        const conn = compat.posix.accept(lfd, null, null, 0) catch |e| {
            std.debug.print("semasound: accept error {any}\n", .{e});
            continue;
        };
        handleAccept(conn, next_id);
        next_id += 1;
    }
}
