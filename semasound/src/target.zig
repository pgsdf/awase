// F.5.c (ADR 0025): the target, a named, isolated mixing domain.
//
// A target owns a full instance of the F.5.a/b spine: its own client set,
// its own mixer/output pacing, its own elected hardware rate and 0-to-1
// election (device targets), its own drift estimation (device targets), and
// its own xrun consumption (device targets). A client belongs to exactly one
// target for the lifetime of its connection (binding immutable, re-route is
// a reconnect; ADR 0025 Decision 3). Nothing is shared between targets.
//
// v1 topology is static (ADR 0025 Decision 2): `default` backed by
// /dev/audiofs0 with full F.5.b election, and `null`, a timer-paced discard
// sink fixed at 48 kHz with no device, no election, no clock, no xruns. The
// null sink exists so routing, per-target isolation, and F.5.d policy are
// exercisable on one-device hardware; a second real device slots in as a
// named target with no model change.

const std = @import("std");
const client_mod = @import("client.zig");
const election = @import("election.zig");
const policy_mod = @import("policy.zig");
const events_mod = @import("events.zig");

pub const Sink = union(enum) {
    device: std.posix.fd_t,
    null_sink: void,
};

pub const Target = struct {
    name: []const u8,
    sink: Sink,
    set: client_mod.ClientSet = .{},
    frames_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    election: election.State = .{},

    // F.5.d (ADR 0026): the target's loaded policy. Owned and mutated by the
    // single accept thread (reload-per-connection, Decision 3); the audio
    // threads never read it. The duck factor is mirrored into duck_milli (an
    // atomic) for the output pass.
    policy: policy_mod.LoadedPolicy = .{},
    duck_milli: std.atomic.Value(u32) = std.atomic.Value(u32).init(250),

    // F.5.e (ADR 0027 Decision 3): the per-target event ring. Audio threads
    // touch it only via the constrained append.
    events: events_mod.EventRing = .{},

    /// The rate clients on this target are mixed at. Device targets carry
    /// the elected rate (F.5.b session-opener semantics, per-target); the
    /// null sink is fixed at canonical 48 kHz (ADR 0025 Decision 5).
    pub fn hwRate(self: *const Target) u32 {
        return switch (self.sink) {
            .device => self.election.rate(),
            .null_sink => 48000,
        };
    }

    pub fn isDevice(self: *const Target) bool {
        return self.sink == .device;
    }
};

/// Resolve a target by name. Names come from protocol.targetName (already
/// NUL-trimmed, empty mapped to "default"); unknown names are the caller's
/// rejection case (ADR 0025 Decision 3).
pub fn find(targets: []Target, name: []const u8) ?*Target {
    for (targets) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

test "find resolves by name and rejects unknown" {
    var ts = [_]Target{
        .{ .name = "default", .sink = .{ .device = -1 } },
        .{ .name = "null", .sink = .null_sink },
    };
    try std.testing.expect(find(&ts, "default") == &ts[0]);
    try std.testing.expect(find(&ts, "null") == &ts[1]);
    try std.testing.expect(find(&ts, "hdmi") == null);
}

test "null sink is fixed at 48000; device target carries elected rate" {
    var ts = [_]Target{
        .{ .name = "default", .sink = .{ .device = -1 } },
        .{ .name = "null", .sink = .null_sink },
    };
    try std.testing.expectEqual(@as(u32, 48000), ts[1].hwRate());
    try std.testing.expectEqual(@as(u32, 48000), ts[0].hwRate()); // default seed
    ts[0].election.elected.store(44100, .release);
    try std.testing.expectEqual(@as(u32, 44100), ts[0].hwRate());
    try std.testing.expectEqual(@as(u32, 48000), ts[1].hwRate()); // isolated
}
