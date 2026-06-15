// F.5.b estimator thread (ADR 0024 Decision 5), per-client ring-trend model.
//
// Runs the rate-correcting controllers on their own low-frequency cadence,
// separate from the mix loop (ADR 0007: the clock must not schedule the
// mixer). One Estimator per client slot. Each window, for every active
// client, it reads that client's ring flow counters (cumulative bytes pushed
// by the reader vs popped by the mixer), computes the production/consumption
// mismatch (the ring-fill TREND), steps that client's controller, and writes
// the resulting trim back to that client.
//
// Why per-client ring-trend and not output-vs-clock slope: the mixer's output
// is hardware-paced by audiofs backpressure, so semasound's output frame rate
// equals the hardware clock rate by construction. An output-vs-clock slope is
// therefore structurally blind to client drift. A client's drift shows up
// only as its ring trending full or empty (it produces faster/slower than we
// consume), which is local to that client. So the signal is per-client and
// the trim is per-client. This also matches where F.5.c routing is headed.
//
// Rate matching, not level targeting (ADR 0007): the controller drives the
// trend (rate of change of occupancy) to zero, never toward a fill level. A
// client may settle at any occupancy and that is correct so long as its trend
// is zero. The ring level is not an input to the control law.
//
// Trim is a monotonic control signal: each window writes the current best
// absolute trim for that client, never a diff, so application is idempotent.

const std = @import("std");
const compat = @import("compat");
const client_mod = @import("client.zig");
const estimator_mod = @import("estimator.zig");
const ring_mod = @import("ring.zig");

// Estimation window. 5 s baseline: long enough to smooth the integer-byte
// quantization of the trend at low drift, short enough for convergence to be
// Estimation window default. 5 s baseline. Overridable at startup via the
// env var SEMASOUND_WINDOW_MS so the criterion-8 noise characterization can
// sweep window length (5/10/20 s) without recompiling. Drift moves over
// minutes; the window trades measurement noise against responsiveness, which
// is exactly what the characterization is measuring.
pub const WINDOW_MS_DEFAULT: u64 = 5000;

pub const Ctx = struct {
    set: *client_mod.ClientSet,
    stop: *std.atomic.Value(bool),
};

fn windowMs() u64 {
    const v = compat.args.getenv("SEMASOUND_WINDOW_MS") orelse return WINDOW_MS_DEFAULT;
    return std.fmt.parseInt(u64, v, 10) catch WINDOW_MS_DEFAULT;
}

pub fn run(ctx: Ctx) void {
    const window_ms = windowMs();

    // One controller per client slot, reset when a slot is reused (tracked by
    // the client id last seen in it).
    var est: [client_mod.MAX_CLIENTS]estimator_mod.Estimator = undefined;
    var seen_id: [client_mod.MAX_CLIENTS]u32 = undefined;
    var i: usize = 0;
    while (i < client_mod.MAX_CLIENTS) : (i += 1) {
        est[i] = estimator_mod.Estimator.init();
        seen_id[i] = 0;
    }

    var ptrs: [client_mod.MAX_CLIENTS]*client_mod.Client = undefined;

    const poll_ms: u64 = 250;
    var elapsed: u64 = 0;

    while (!ctx.stop.load(.acquire)) {
        compat.time.sleep(compat.time.Duration.fromMilliseconds(@intCast(poll_ms)));
        elapsed += poll_ms;
        if (elapsed < window_ms) continue;
        const window_secs = @as(f64, @floatFromInt(elapsed)) / 1000.0;
        elapsed = 0;

        const nc = ctx.set.snapshotActive(&ptrs);
        var j: usize = 0;
        while (j < nc) : (j += 1) {
            const c = ptrs[j];
            // Passthrough clients (no resampler) have no ratio to trim; skip.
            if (c.resampler == null) continue;

            // Map this client to a controller slot by id. If the slot's id
            // changed (slot reused by a new client), reset that controller so
            // a fresh client starts from a clean anchor.
            const slot = c.id % client_mod.MAX_CLIENTS;
            if (seen_id[slot] != c.id) {
                est[slot] = estimator_mod.Estimator.init();
                seen_id[slot] = c.id;
            }

            const pushed = c.ring.totalPushed();
            const popped = c.ring.totalPopped();
            const fill_frac = @as(f64, @floatFromInt(c.ring.available())) /
                @as(f64, @floatFromInt(ring_mod.CAP));
            const trim = est[slot].window(pushed, popped, fill_frac, window_secs);
            c.setTrim(trim);

            // RAW measurement trace (criterion-8 characterization): byte
            // deltas to frames (stereo, 4 bytes/frame), raw frame imbalance,
            // derived ppm, trim, and fill. frame_delta near +/-1 chunk (1024)
            // regardless of window => chunk-boundary quantization, not drift.
            const pd_frames = est[slot].last_pushed_delta / 4;
            const od_frames = est[slot].last_popped_delta / 4;
            const frame_delta = @as(i64, @intCast(pd_frames)) - @as(i64, @intCast(od_frames));
            const rate_ppm = est[slot].last_rate_error * 1e6;
            const filt_ppm = est[slot].last_filtered_error * 1e6;
            const trim_ppm = (trim - 1.0) * 1e6;
            // Component contributions (ppm), to prove which term drives trim
            // variance before any structural change.
            const p_ppm = est[slot].pred.last_p * 1e6;
            const i_ppm = est[slot].pred.last_i * 1e6;
            const level_ppm = est[slot].pred.last_level * 1e6;
            std.debug.print(
                "semasound: drift raw: client {d} win {d:.2}s frame_delta {d} rate {d:.1} filt {d:.1} p {d:.1} i {d:.1} level {d:.1} trim {d:.1} ppm fill {d:.0}%\n",
                .{ c.id, window_secs, frame_delta, rate_ppm, filt_ppm, p_ppm, i_ppm, level_ppm, trim_ppm, fill_frac * 100.0 },
            );
        }
    }
}
