//! chronofs: TimelineMap and TimelineView (ADR 0004, the planning document).
//!
//! The affine bridge between the coordination clock (u64 PCM sample frames,
//! clock.zig) and the data-time cursor (i64 ns since the Unix epoch,
//! instant.zig). The two axes are related by a rational rate and an origin,
//! not by identity (ADR 0004). TimelineMap holds the transport state (origin,
//! play-start frame, rational rate, paused); TimelineView binds a clock to a
//! map and reports the cursor now. chronofs computes time only; it never
//! touches field data.

const std = @import("std");
const instant_mod = @import("instant");

pub const Instant = instant_mod.Instant;
const NS_PER_S = instant_mod.NS_PER_S;

/// The affine map from coordination frames to a data-time instant.
///
/// While playing,
///   cursor(frame) = origin_ns + (frame - play_start_frame) * rate_num / rate_den
/// and while paused, cursor(frame) = origin_ns. The rate is data-time
/// nanoseconds per coordination frame, kept rational so 1x real time at any
/// audio sample rate is exact (e.g. 1e9 / 48000 ns per frame).
pub const TimelineMap = struct {
    /// Cursor value at play_start_frame (the anchor of the current segment).
    origin_ns: Instant,
    /// Coordination frame at which the current play segment is anchored.
    play_start_frame: u64,
    /// Data-time nanoseconds per coordination frame: rate_num / rate_den.
    /// Signed to allow reverse playback; rate_den must be > 0.
    rate_num: i64,
    rate_den: i64,
    paused: bool,

    /// A 1x real-time map for `sample_rate`, cursor at `origin_ns`, anchored
    /// at frame 0, paused. data-ns per frame = 1e9 / sample_rate.
    pub fn init(origin_ns: Instant, sample_rate: u32) TimelineMap {
        std.debug.assert(sample_rate > 0);
        return .{
            .origin_ns = origin_ns,
            .play_start_frame = 0,
            .rate_num = NS_PER_S,
            .rate_den = @intCast(sample_rate),
            .paused = true,
        };
    }

    /// The data-time cursor at coordination frame `frame`. Computed in i128
    /// and saturated to the instant range so a long advance cannot overflow.
    pub fn cursorAtFrame(self: *const TimelineMap, frame: u64) Instant {
        if (self.paused) return self.origin_ns;
        const df = @as(i128, frame) - @as(i128, self.play_start_frame);
        const adv = @divTrunc(df * @as(i128, self.rate_num), @as(i128, self.rate_den));
        return saturateInstant(@as(i128, self.origin_ns) + adv);
    }

    /// The cursor now, reading `clock.now()` (any type with `now() u64`).
    pub fn cursor(self: *const TimelineMap, clock: anytype) Instant {
        return self.cursorAtFrame(clock.now());
    }

    /// Freeze the cursor at its current value.
    pub fn pause(self: *TimelineMap, frame: u64) void {
        self.origin_ns = self.cursorAtFrame(frame);
        self.paused = true;
    }

    /// Resume playing from the frozen cursor at `frame` (no jump).
    pub fn play(self: *TimelineMap, frame: u64) void {
        self.play_start_frame = frame;
        self.paused = false;
    }

    /// Jump the cursor to `target_ns` at `frame`; the paused state is kept.
    pub fn scrub(self: *TimelineMap, target_ns: Instant, frame: u64) void {
        self.origin_ns = target_ns;
        self.play_start_frame = frame;
    }

    /// Change the rate without moving the cursor: re-anchor at `frame`, then
    /// set rate_num / rate_den (den must be > 0).
    pub fn setRate(self: *TimelineMap, num: i64, den: i64, frame: u64) void {
        std.debug.assert(den > 0);
        self.origin_ns = self.cursorAtFrame(frame);
        self.play_start_frame = frame;
        self.rate_num = num;
        self.rate_den = den;
    }
};

/// Binds a clock to a TimelineMap and reports the data-time cursor now.
/// Generic over the clock type so the production Clock and the test MockClock
/// (clock.zig) both fit; the only requirement is a `now() u64` method.
pub fn TimelineView(comptime ClockType: type) type {
    return struct {
        const Self = @This();

        clock: ClockType,
        map: TimelineMap,

        pub fn init(clock: ClockType, map: TimelineMap) Self {
            return .{ .clock = clock, .map = map };
        }

        /// The data-time cursor at the clock's current frame.
        pub fn cursorNow(self: *Self) Instant {
            return self.map.cursorAtFrame(self.clock.now());
        }

        pub fn pause(self: *Self) void {
            self.map.pause(self.clock.now());
        }

        pub fn play(self: *Self) void {
            self.map.play(self.clock.now());
        }

        pub fn scrub(self: *Self, target_ns: Instant) void {
            self.map.scrub(target_ns, self.clock.now());
        }
    };
}

fn saturateInstant(x: i128) Instant {
    if (x > instant_mod.MAX) return instant_mod.MAX;
    if (x < instant_mod.MIN) return instant_mod.MIN;
    return @intCast(x);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const MockClock = @import("clock").MockClock;

test "TimelineMap paused returns the origin" {
    var view = TimelineView(MockClock).init(MockClock.init(48_000), TimelineMap.init(1000, 48_000));
    try testing.expectEqual(@as(Instant, 1000), view.cursorNow());
    view.clock.advance(48_000);
    try testing.expectEqual(@as(Instant, 1000), view.cursorNow()); // still paused
}

test "TimelineMap playing advances by the rational rate, exactly" {
    var view = TimelineView(MockClock).init(MockClock.init(48_000), TimelineMap.init(0, 48_000));
    view.play();
    try testing.expectEqual(@as(Instant, 0), view.cursorNow());
    view.clock.advance(48_000);
    try testing.expectEqual(@as(Instant, 1_000_000_000), view.cursorNow());
    view.clock.advance(48_000);
    try testing.expectEqual(@as(Instant, 2_000_000_000), view.cursorNow());
}

test "TimelineMap is exact across a long advance (no drift)" {
    var view = TimelineView(MockClock).init(MockClock.init(48_000), TimelineMap.init(0, 48_000));
    view.play();
    const seconds: u64 = 3600;
    view.clock.advance(48_000 * seconds);
    try testing.expectEqual(@as(Instant, @as(i64, @intCast(seconds)) * NS_PER_S), view.cursorNow());
}

test "two views over the same clock and map agree (no skew)" {
    var m = TimelineMap.init(500, 48_000);
    m.play(0);
    var v1 = TimelineView(MockClock).init(MockClock.init(48_000), m);
    var v2 = TimelineView(MockClock).init(MockClock.init(48_000), m);
    v1.clock.advance(12_345);
    v2.clock.advance(12_345);
    try testing.expectEqual(v1.cursorNow(), v2.cursorNow());
}

test "scrub jumps the cursor to a target instant" {
    var view = TimelineView(MockClock).init(MockClock.init(48_000), TimelineMap.init(0, 48_000));
    view.play();
    view.clock.advance(48_000);
    try testing.expectEqual(@as(Instant, 1_000_000_000), view.cursorNow());
    view.scrub(5_000_000_000);
    try testing.expectEqual(@as(Instant, 5_000_000_000), view.cursorNow());
    view.clock.advance(48_000);
    try testing.expectEqual(@as(Instant, 6_000_000_000), view.cursorNow());
}

test "pause freezes and play resumes without a jump" {
    var view = TimelineView(MockClock).init(MockClock.init(48_000), TimelineMap.init(0, 48_000));
    view.play();
    view.clock.advance(48_000);
    view.pause();
    try testing.expectEqual(@as(Instant, 1_000_000_000), view.cursorNow());
    view.clock.advance(96_000); // time passes while paused
    try testing.expectEqual(@as(Instant, 1_000_000_000), view.cursorNow());
    view.play();
    try testing.expectEqual(@as(Instant, 1_000_000_000), view.cursorNow());
    view.clock.advance(48_000);
    try testing.expectEqual(@as(Instant, 2_000_000_000), view.cursorNow());
}

test "setRate changes speed without moving the cursor" {
    var view = TimelineView(MockClock).init(MockClock.init(48_000), TimelineMap.init(0, 48_000));
    view.play();
    view.clock.advance(48_000);
    try testing.expectEqual(@as(Instant, 1_000_000_000), view.cursorNow());
    view.map.setRate(2 * NS_PER_S, 48_000, view.clock.now()); // 2x, re-anchored
    try testing.expectEqual(@as(Instant, 1_000_000_000), view.cursorNow());
    view.clock.advance(48_000);
    try testing.expectEqual(@as(Instant, 3_000_000_000), view.cursorNow());
}
