// F.5.e (ADR 0027): state publication. One publisher thread per broker
// wakes at 1 Hz; each cycle takes ONE in-memory snapshot per target and
// derives every dynamic surface from it (the single-snapshot projection
// rule, operator amendment: no surface is authoritative independently, and
// `clients` is the authoritative enumeration of streams). `state` is
// rewritten EVERY cycle and carries the liveness signal (publish_seq,
// publish_ts), so observers distinguish quiescence from publisher stall
// from broker death; `clients`, `events`, and `last-event` skip the write
// when unchanged. All writes are atomic via policy_state.writeAtomic.
//
// AUDIO THREADS PERFORM NO FILESYSTEM IO. Their only observability
// contribution is the constrained events.EventRing.append (see events.zig).

const std = @import("std");
const compat = @import("compat");
const client_mod = @import("client.zig");
const target_mod = @import("target.zig");
const events_mod = @import("events.zig");
const policy_state = @import("policy_state.zig");
const protocol = @import("protocol.zig");

pub const SEMASOUND_VERSION = "F.5.e";

/// Write the static surfaces for a target, once at startup (ADR 0027 D1).
pub fn writeStatic(t: *const target_mod.Target) void {
    var dirbuf: [256]u8 = undefined;
    const dir = std.fmt.bufPrint(&dirbuf, "{s}/{s}", .{ policy_state.RUN_BASE, t.name }) catch return;

    var b: [256]u8 = undefined;
    if (std.fmt.bufPrint(&b, "semasound {s}\n", .{t.name})) |v|
        policy_state.writeAtomic(dir, "identity", v)
    else |_| {}
    if (std.fmt.bufPrint(&b, "{s}\n", .{SEMASOUND_VERSION})) |v|
        policy_state.writeAtomic(dir, "version", v)
    else |_| {}
    policy_state.writeAtomic(dir, "backend", switch (t.sink) {
        .device => "audiofs\n",
        .null_sink => "discard\n",
    });
    policy_state.writeAtomic(dir, "device", switch (t.sink) {
        .device => protocol.DEVICE_PATH ++ "\n",
        .null_sink => "none\n",
    });
    if (std.fmt.bufPrint(
        &b,
        "rates=8000-48000\nformat=s16le\nchannels=1,2\nmixing=true\nelection={s}\n",
        .{if (t.sink == .device) "true" else "false"},
    )) |v|
        policy_state.writeAtomic(dir, "capabilities", v)
    else |_| {}
}

/// Format the `state` surface from snapshot values. Pure; testable.
pub fn formatState(
    buf: []u8,
    nclients: usize,
    hw_rate: u32,
    frames: u64,
    duck_engaged: bool,
    publish_seq: u64,
    publish_ts: i64,
) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "status={s}\nclients={d}\nhw_rate={d}\nframes_written={d}\nduck={s}\npublish_seq={d}\npublish_ts={d}\n",
        .{
            if (nclients > 0) "playing" else "idle",
            nclients,
            hw_rate,
            frames,
            if (duck_engaged) "engaged" else "off",
            publish_seq,
            publish_ts,
        },
    ) catch buf[0..0];
}

/// Format one `clients` line. Pure; testable.
pub fn formatClientLine(buf: []u8, c: *const client_mod.Client, target_rate: u32) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "id={d} label={s} class={s} rate={d} target_rate={d} mode={s} override={d}\n",
        .{
            c.id,
            c.labelSlice(),
            c.classSlice(),
            c.in_rate,
            target_rate,
            if (c.resampler != null) "resampling" else "passthrough",
            @intFromBool(c.override_member),
        },
    ) catch buf[0..0];
}

/// Format one `events` line. Pure; testable.
pub fn formatEventLine(buf: []u8, e: *const events_mod.Event) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "seq={d} ts={d} frames={d} kind={s} {s}\n",
        .{ e.seq, e.ts_ns, e.frames, e.kind.name(), e.detailSlice() },
    ) catch buf[0..0];
}

pub const Ctx = struct {
    targets: []target_mod.Target,
    stop: *std.atomic.Value(bool),
};

const MAX_TEXT: usize = 32 * 1024;

const PerTarget = struct {
    last_clients: [MAX_TEXT]u8 = undefined,
    last_clients_len: usize = 1, // sentinel: differs from any real first write
    last_event_seq: u64 = std.math.maxInt(u64), // sentinel: forces first write
};

pub fn run(ctx: Ctx) void {
    var per: [8]PerTarget = [_]PerTarget{.{}} ** 8;
    var publish_seq: u64 = 0;

    var ptrs: [client_mod.MAX_CLIENTS]*client_mod.Client = undefined;
    var evbuf: [events_mod.CAPACITY]events_mod.Event = undefined;
    var text: [MAX_TEXT]u8 = undefined;
    var line: [256]u8 = undefined;
    var dirbuf: [256]u8 = undefined;

    while (!ctx.stop.load(.acquire)) {
        publish_seq += 1;
        const now_ns: i64 = @intCast(compat.time.nowMonotonic());

        for (ctx.targets, 0..) |*t, ti| {
            if (ti >= per.len) break;
            const dir = std.fmt.bufPrint(&dirbuf, "{s}/{s}", .{ policy_state.RUN_BASE, t.name }) catch continue;

            // ONE snapshot per cycle (single-snapshot projection rule): the
            // active set, the event ring, and the scalar state, taken
            // together here; every surface below derives from these.
            const nc = t.set.snapshotActive(&ptrs);
            var total: u64 = 0;
            const nev = t.events.snapshot(&evbuf, &total);
            const frames = t.frames_written.load(.monotonic);
            const hw = t.hwRate();
            var duck_engaged = false;
            for (ptrs[0..nc]) |c| {
                if (c.override_member) {
                    duck_engaged = true;
                    break;
                }
            }

            // state: every cycle (liveness signal).
            var sbuf: [512]u8 = undefined;
            const st = formatState(&sbuf, nc, hw, frames, duck_engaged, publish_seq, now_ns);
            policy_state.writeAtomic(dir, "state", st);

            // clients: skip when unchanged.
            var n: usize = 0;
            for (ptrs[0..nc]) |c| {
                const l = formatClientLine(&line, c, hw);
                if (n + l.len > text.len) break;
                @memcpy(text[n .. n + l.len], l);
                n += l.len;
            }
            const pt = &per[ti];
            if (n != pt.last_clients_len or !std.mem.eql(u8, text[0..n], pt.last_clients[0..pt.last_clients_len])) {
                policy_state.writeAtomic(dir, "clients", text[0..n]);
                @memcpy(pt.last_clients[0..n], text[0..n]);
                pt.last_clients_len = n;
            }

            // events + last-event: skip when the newest seq is unchanged.
            if (total != pt.last_event_seq) {
                n = 0;
                var last_line_start: usize = 0;
                for (evbuf[0..nev]) |*e| {
                    const l = formatEventLine(&line, e);
                    if (n + l.len > text.len) break;
                    last_line_start = n;
                    @memcpy(text[n .. n + l.len], l);
                    n += l.len;
                }
                policy_state.writeAtomic(dir, "events", text[0..n]);
                policy_state.writeAtomic(dir, "last-event", text[last_line_start..n]);
                pt.last_event_seq = total;
            }
        }

        compat.time.sleep(compat.time.Duration.fromNanoseconds(1_000_000_000));
    }
}

test "formatState shapes the liveness signal" {
    var b: [512]u8 = undefined;
    const s = formatState(&b, 2, 44100, 12345, true, 7, 99);
    try std.testing.expect(std.mem.indexOf(u8, s, "status=playing\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "clients=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "hw_rate=44100\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "duck=engaged\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "publish_seq=7\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "publish_ts=99\n") != null);
}

test "formatEventLine carries seq ts frames kind detail" {
    var b: [256]u8 = undefined;
    var e = events_mod.Event{ .seq = 3, .ts_ns = 11, .frames = 22, .kind = .denied };
    const d = "label=x class=y";
    @memcpy(e.detail[0..d.len], d);
    e.detail_len = d.len;
    const s = formatEventLine(&b, &e);
    try std.testing.expectEqualStrings("seq=3 ts=11 frames=22 kind=denied label=x class=y\n", s);
}
