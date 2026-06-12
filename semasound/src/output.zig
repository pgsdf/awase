// F.5.a mixer/output thread (ADR 0021 Decisions 3, 4).
//
// The sole writer to /dev/audiofs0. Each pass: reap finished clients,
// snapshot the active set, pop one frame-aligned chunk from every client
// ring, mix (sum/clip/zero-fill), and blocking-write the mixed chunk to
// audiofs. The blocking write is the pacer: when audiofs's ring is full the
// write blocks until the DAC drains a fragment, so the loop runs at the true
// hardware rate. No clock sampling is in this loop (ADR 0007: rate-correction
// by construction, not position-correction). With no clients the mix is
// silence and the loop still paces on the write, keeping the stream alive.

const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const mixer = @import("mixer.zig");
const events_mod = @import("events.zig");
const client_mod = @import("client.zig");
const election_mod = @import("election.zig");

/// AD-47 device layer state for run(): .real writes the mix to the
/// device, whose blocking write paces the loop; .null_sink discards
/// it, paces on a monotonic timer at the canonical rate (the F.5.c
/// pattern), and retries the device open at ~1 s cadence. Device
/// errors transition real to null_sink; a successful reopen
/// transitions back after reseeding election state. writeAll can
/// never terminate the loop (the 2026-06-06 AD-47 finding: one
/// error.NoDevice at kldunload killed the engine permanently while
/// the accept thread kept admitting clients into the dead mixer).
const DeviceState = enum { real, null_sink };

pub const CHUNK_FRAMES: usize = 1024;
pub const CHUNK_BYTES: usize = CHUNK_FRAMES * protocol.BYTES_PER_FRAME; // 4096

pub const Ctx = struct {
    set: *client_mod.ClientSet,
    stop: *std.atomic.Value(bool),
    // Monotonic count of output frames written to audiofs. This is the
    // "system production" signal the F.5.b output-domain drift estimator
    // (predictor.zig + the estimator loop) differences against the F.4
    // kernel clock's samples_written to get the output-domain slope error.
    // It is NOT read in this mix loop (ADR 0007: the clock must not schedule
    // the mixer); only the estimator thread reads it, on its own cadence.
    frames_written: *std.atomic.Value(u64),
    // AD-47 device layer: the SHARED device fd atomic, owned by main.
    // The accept path loads it for election ioctls; run()'s reconnect
    // path republishes it after a reopen (Stage 2 single-open
    // semantics preserved: one live fd, many readers of its value;
    // ADR 0019 SET_FORMAT reconfigures the live stream under us and
    // wakes a blocked writer, which writeAll's loop absorbs). A value
    // of -1 means no device: run() starts on the null sink and
    // reconnects. runNull receives a permanently -1 atomic.
    fd: *std.atomic.Value(std.posix.fd_t),
    // AD-47: election state to reseed after a device reopen (a
    // reloaded module rests at its own rate, not ours). Null for
    // runNull.
    election: ?*election_mod.State,
    // Target name, for log attribution (F.5.c: one output loop per target).
    name: []const u8,
    // F.5.d ducking (ADR 0026 Decision 5): the target's duck factor in
    // milli-units, mirrored from policy at reload. Reference-counted duck
    // state is computed per pass from the snapshot: gains are duck_milli for
    // non-override clients while any override client is active, else 1000.
    duck_milli: *const std.atomic.Value(u32),
    // F.5.e (ADR 0027): the target's event ring. The ONLY observability
    // operation this thread performs is the constrained append (reaped
    // events); timestamps reuse the clock this loop already reads.
    events: *events_mod.EventRing,
};

/// Per-pass gains (ADR 0026 Decision 5): unity unless at least one active
/// override-class client is present, in which case every NON-override
/// source is ducked. Computing from the snapshot each pass realizes the
/// reference-counted semantics exactly: ducking holds while the override
/// count is nonzero and restores when it returns to zero.
fn computeGains(ptrs: []*client_mod.Client, gains: []u32, duck: u32) void {
    var any_override = false;
    for (ptrs) |c| {
        if (c.override_member) {
            any_override = true;
            break;
        }
    }
    for (ptrs, 0..) |c, i| {
        gains[i] = if (any_override and !c.override_member) duck else 1000;
    }
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try posix.write(fd, bytes[off..]);
        off += n;
    }
}

pub fn run(ctx: Ctx) void {
    // AD-47 device layer state.
    var dev_state: DeviceState = if (ctx.fd.load(.monotonic) >= 0) .real else .null_sink;
    if (dev_state == .null_sink) {
        std.debug.print("semasound: output[{s}] starting on null sink; device absent, reconnecting\n", .{ctx.name});
    }
    const period_ns: u64 = CHUNK_FRAMES * 1_000_000_000 / protocol.CANON_RATE;
    var next_ns: i128 = std.time.nanoTimestamp() + period_ns;
    var last_reconnect_ms: i64 = 0;

    var out: [CHUNK_BYTES]u8 = undefined;
    var src_storage: [client_mod.MAX_CLIENTS][CHUNK_BYTES]u8 = undefined;
    var ptrs: [client_mod.MAX_CLIENTS]*client_mod.Client = undefined;
    var sources: [client_mod.MAX_CLIENTS][]const u8 = undefined;
    var gains: [client_mod.MAX_CLIENTS]u32 = undefined;
    var src_owner: [client_mod.MAX_CLIENTS]usize = undefined;

    var last_report: i64 = std.time.milliTimestamp();
    var short_ev: u64 = 0; // active clients that supplied a partial chunk this pass
    var absent_ev: u64 = 0; // active clients that supplied nothing this pass

    while (!ctx.stop.load(.acquire)) {
        var reaped_ids: [client_mod.MAX_CLIENTS]u32 = undefined;
        const nreaped = ctx.set.reap(&reaped_ids);

        const nc = ctx.set.snapshotActive(&ptrs);
        var nsrc: usize = 0;
        var j: usize = 0;
        while (j < nc) : (j += 1) {
            const got = ptrs[j].ring.popFramesInto(src_storage[nsrc][0..], protocol.BYTES_PER_FRAME);
            if (got == 0) {
                absent_ev += 1; // active client supplied nothing this pass
            } else {
                if (got < CHUNK_BYTES) short_ev += 1; // partial chunk this pass
                sources[nsrc] = src_storage[nsrc][0..got];
                src_owner[nsrc] = j;
                nsrc += 1;
            }
        }

        // F.5.d ducking: per-source gains from the full active snapshot (an
        // override client with no data this pass still holds the duck).
        var snap_gains: [client_mod.MAX_CLIENTS]u32 = undefined;
        computeGains(ptrs[0..nc], snap_gains[0..nc], ctx.duck_milli.load(.monotonic));
        var k: usize = 0;
        while (k < nsrc) : (k += 1) gains[k] = snap_gains[src_owner[k]];

        mixer.mixGains(&out, sources[0..nsrc], gains[0..nsrc]);

        // AD-47 device layer: the write step is a state machine and can
        // never terminate the loop.
        switch (dev_state) {
            .real => {
                writeAll(ctx.fd.load(.monotonic), &out) catch |e| {
                    std.debug.print("semasound: audiofs write error {any}; output[{s}] continues on null sink, device layer reconnecting\n", .{ e, ctx.name });
                    dev_state = .null_sink;
                    next_ns = std.time.nanoTimestamp() + period_ns;
                };
            },
            .null_sink => {
                // Timer pacing at the canonical rate (F.5.c pattern):
                // the mix is discarded; clients stream at real-time
                // cadence against their ring drain, silently.
                const t = std.time.nanoTimestamp();
                if (next_ns > t) {
                    std.Thread.sleep(@intCast(next_ns - t));
                    next_ns += period_ns;
                } else {
                    next_ns = t + period_ns;
                }
                // Rate-limited reconnect: one open attempt per second.
                const rc_now = std.time.milliTimestamp();
                if (rc_now - last_reconnect_ms >= 1000) {
                    last_reconnect_ms = rc_now;
                    if (posix.open(protocol.DEVICE_PATH, .{ .ACCMODE = .WRONLY }, 0)) |nfd| {
                        ctx.fd.store(nfd, .monotonic);
                        if (ctx.election) |est| election_mod.seedFromDevice(est, nfd);
                        dev_state = .real;
                        std.debug.print("semasound: device reopened on {s}; output[{s}] resumed\n", .{ protocol.DEVICE_PATH, ctx.name });
                    } else |_| {}
                }
            },
        }
        // Account the frames just written (the system-production signal for
        // the output-domain estimator). Monotonic; read only by the estimator
        // thread on its own cadence, never here.
        _ = ctx.frames_written.fetchAdd(CHUNK_FRAMES, .monotonic);

        const now = std.time.milliTimestamp();
        if (nreaped > 0) {
            // Reaped events: bounded formatting into a stack buffer, then
            // the constrained append, reusing the clock read above. No
            // allocation, no syscalls, no logging in the append path.
            const fr = ctx.frames_written.load(.monotonic);
            var db: [32]u8 = undefined;
            var ri: usize = 0;
            while (ri < nreaped) : (ri += 1) {
                const d = std.fmt.bufPrint(&db, "id={d}", .{reaped_ids[ri]}) catch db[0..0];
                ctx.events.append(.reaped, now * 1_000_000, fr, d);
            }
        }
        if (now - last_report >= 1000) {
            switch (dev_state) {
                // AD-47: the healthy heartbeat stays byte-identical;
                // the F.5 suites grep it and never run degraded.
                .real => std.debug.print(
                    "semasound: playing[{s}], {d} client(s); underflow short={d} absent={d} per s\n",
                    .{ ctx.name, ctx.set.activeCount(), short_ev, absent_ev },
                ),
                .null_sink => std.debug.print(
                    "semasound: degraded[{s}], {d} client(s); device absent, reconnecting\n",
                    .{ ctx.name, ctx.set.activeCount() },
                ),
            }
            short_ev = 0;
            absent_ev = 0;
            last_report = now;
        }
    }
}

/// F.5.c null sink (ADR 0025 Decision 2): the same reap/snapshot/pop/mix
/// pass as the device loop, but the mixed chunk is DISCARDED and pacing
/// comes from a monotonic timer at the canonical rate instead of blocking-
/// write backpressure. Clients routed here stream at real-time cadence
/// (their blocking writes pace against ring drain exactly as on a device)
/// with nothing audible and no hardware involvement: no election, no clock,
/// no xruns.
pub fn runNull(ctx: Ctx) void {
    var out: [CHUNK_BYTES]u8 = undefined;
    var src_storage: [client_mod.MAX_CLIENTS][CHUNK_BYTES]u8 = undefined;
    var ptrs: [client_mod.MAX_CLIENTS]*client_mod.Client = undefined;
    var sources: [client_mod.MAX_CLIENTS][]const u8 = undefined;

    const period_ns: u64 = CHUNK_FRAMES * 1_000_000_000 / 48000; // ~21.3 ms
    var next_ns: i128 = std.time.nanoTimestamp() + period_ns;

    var last_report: i64 = std.time.milliTimestamp();

    while (!ctx.stop.load(.acquire)) {
        var reaped_ids: [client_mod.MAX_CLIENTS]u32 = undefined;
        const nreaped = ctx.set.reap(&reaped_ids);

        const nc = ctx.set.snapshotActive(&ptrs);
        var nsrc: usize = 0;
        var j: usize = 0;
        while (j < nc) : (j += 1) {
            const got = ptrs[j].ring.popFramesInto(src_storage[nsrc][0..], protocol.BYTES_PER_FRAME);
            if (got > 0) {
                sources[nsrc] = src_storage[nsrc][0..got];
                nsrc += 1;
            }
        }
        mixer.mix(&out, sources[0..nsrc]); // discard sink: gains immaterial
        // Discard. The pop above is the real work: it drains client rings at
        // paced cadence, which is what keeps null-routed clients streaming.
        _ = ctx.frames_written.fetchAdd(CHUNK_FRAMES, .monotonic);

        const now = std.time.milliTimestamp();
        if (nreaped > 0) {
            // Reaped events: bounded formatting into a stack buffer, then
            // the constrained append, reusing the clock read above. No
            // allocation, no syscalls, no logging in the append path.
            const fr = ctx.frames_written.load(.monotonic);
            var db: [32]u8 = undefined;
            var ri: usize = 0;
            while (ri < nreaped) : (ri += 1) {
                const d = std.fmt.bufPrint(&db, "id={d}", .{reaped_ids[ri]}) catch db[0..0];
                ctx.events.append(.reaped, now * 1_000_000, fr, d);
            }
        }
        if (now - last_report >= 1000 and ctx.set.activeCount() > 0) {
            std.debug.print(
                "semasound: playing[{s}], {d} client(s) (discard)\n",
                .{ ctx.name, ctx.set.activeCount() },
            );
            last_report = now;
        }

        // Pace to the deadline; carry the schedule so jitter does not
        // accumulate.
        const t = std.time.nanoTimestamp();
        if (next_ns > t) {
            const rem: u64 = @intCast(next_ns - t);
            std.Thread.sleep(rem);
        }
        next_ns += period_ns;
    }
}
