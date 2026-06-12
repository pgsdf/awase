//! chronofs: the instant axis representation (ADR 0004).
//!
//! An instant is signed nanoseconds since the Unix epoch
//! (1970-01-01T00:00:00Z), a uniform count with no civil-time, calendar, or
//! leap-second semantics (ADR 0004 Decision 3). The i64 range spans roughly
//! 1677-09-21 to 2262-04-11, the deliberate operational and scientific scope
//! (ADR 0004 Decision 4); deep-time data is out of scope and cannot be
//! represented.
//!
//! This is the data-time axis, distinct from the coordination clock's u64
//! sample-frame count; the two are related by the TimelineMap (timeline.zig),
//! not by identity.

const std = @import("std");

/// A point on the instant axis: signed nanoseconds since the Unix epoch.
pub const Instant = i64;

pub const NS_PER_US: Instant = 1_000;
pub const NS_PER_MS: Instant = 1_000_000;
pub const NS_PER_S: Instant = 1_000_000_000;

/// The Unix epoch, the zero of the instant axis.
pub const EPOCH: Instant = 0;

/// Inclusive representable bounds. These are the i64 limits, corresponding to
/// roughly 1677-09-21 .. 2262-04-11; the bound is a deliberate consequence of
/// nanosecond resolution under ADR 0004's scope, not an arbitrary limit.
pub const MIN: Instant = std.math.minInt(Instant);
pub const MAX: Instant = std.math.maxInt(Instant);

pub const Error = error{OutOfRange};

/// Construct an instant from whole seconds since the epoch. Returns
/// error.OutOfRange when the second count would overflow the nanosecond range
/// (out-of-scope data, e.g. deep time); detecting this at construction is one
/// of the implementation-defined options ADR 0004 Decision 4 permits.
pub fn fromSeconds(s: i64) Error!Instant {
    return std.math.mul(Instant, s, NS_PER_S) catch return error.OutOfRange;
}

/// Serialize as the two's-complement little-endian representation of an i64
/// (ADR 0004 Decision 5).
pub fn serialize(t: Instant, out: *[8]u8) void {
    std.mem.writeInt(Instant, out, t, .little);
}

/// Deserialize a two's-complement little-endian i64.
pub fn deserialize(bytes: *const [8]u8) Instant {
    return std.mem.readInt(Instant, bytes, .little);
}

// ============================================================================
// Tests
// ============================================================================

test "instant serialize/deserialize round-trip" {
    const cases = [_]Instant{ 0, 1, -1, NS_PER_S, -NS_PER_S, 1_700_000_000_000_000_000, MIN, MAX };
    for (cases) |t| {
        var buf: [8]u8 = undefined;
        serialize(t, &buf);
        try std.testing.expectEqual(t, deserialize(&buf));
    }
}

test "instant serialize is little-endian" {
    var buf: [8]u8 = undefined;
    serialize(1, &buf);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
    for (buf[1..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "instant fromSeconds" {
    try std.testing.expectEqual(@as(Instant, 0), try fromSeconds(0));
    try std.testing.expectEqual(NS_PER_S, try fromSeconds(1));
    try std.testing.expectEqual(-NS_PER_S, try fromSeconds(-1));
    // A second count large enough to overflow i64 nanoseconds is out of scope.
    try std.testing.expectError(error.OutOfRange, fromSeconds(std.math.maxInt(i64)));
}
