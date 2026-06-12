const std = @import("std");
const shared_clock = @import("shared_clock");

// ============================================================================
// Clock abstraction
// ============================================================================

/// A pluggable clock source for the frame scheduler.
///
/// The default is WallClockSource, which delegates to std.time.nanoTimestamp().
/// MockClockSource is provided for deterministic testing.
/// ChronofsClockSource (defined in the chronofs module) will drive scheduling
/// from the audio hardware clock for drift-free AV synchronisation.
pub const ClockSource = struct {
    context: *anyopaque,
    nowFn: *const fn (context: *anyopaque) i128,

    /// Return the current time in nanoseconds.
    pub fn now(self: ClockSource) i128 {
        return self.nowFn(self.context);
    }
};

// ============================================================================
// WallClockSource, production default
// ============================================================================

/// Clock source backed by std.time.nanoTimestamp().
/// Construct with WallClockSource.init(), then call .source() to get a
/// ClockSource suitable for passing to FrameScheduler.init().
pub const WallClockSource = struct {
    _dummy: u8 = 0,

    pub fn init() WallClockSource {
        return .{};
    }

    pub fn source(self: *WallClockSource) ClockSource {
        return .{
            .context = @ptrCast(self),
            .nowFn = nowImpl,
        };
    }

    fn nowImpl(_: *anyopaque) i128 {
        return std.time.nanoTimestamp();
    }
};

// ============================================================================
// MockClockSource, deterministic testing
// ============================================================================

/// A manually-advanced clock for use in tests.
/// Call advance() to move time forward; the scheduler will see exactly that
/// value when it next calls clock.now().
///
/// Example:
///   var mock = MockClockSource.init();
///   var sched = FrameScheduler.init(60, mock.source());
///   sched.start();
///   mock.advance(16_666_667); // one frame at 60 Hz
///   try std.testing.expect(sched.shouldComposite());
pub const MockClockSource = struct {
    time_ns: i128,

    pub fn init() MockClockSource {
        return .{ .time_ns = 0 };
    }

    /// Advance the clock by delta_ns nanoseconds.
    pub fn advance(self: *MockClockSource, delta_ns: u64) void {
        self.time_ns += @as(i128, delta_ns);
    }

    /// Set the clock to an absolute value.
    pub fn setTime(self: *MockClockSource, ns: i128) void {
        self.time_ns = ns;
    }

    pub fn source(self: *MockClockSource) ClockSource {
        return .{
            .context = @ptrCast(self),
            .nowFn = nowImpl,
        };
    }

    fn nowImpl(ctx: *anyopaque) i128 {
        const self: *MockClockSource = @ptrCast(@alignCast(ctx));
        return self.time_ns;
    }
};

// ============================================================================
// ChronofsClockSource, audio-hardware-clock driven scheduling
// ============================================================================

/// Clock source that delegates to the shared audio hardware clock.
///
/// `now()` returns the current audio sample position converted to nanoseconds
/// via `ClockReader.toNs()`.  This keeps the frame scheduler in lockstep with
/// the audio clock so `frame_complete` events and audio stream events share the
/// same timeline.
///
/// When the clock is invalid (clock writer absent), `now()` falls back to
/// std.time.nanoTimestamp() so the compositor keeps rendering at wall rate.
pub const ChronofsClockSource = struct {
    reader: shared_clock.ClockReader,
    _wall_fallback: WallClockSource,

    pub fn init(clock_path: []const u8) ChronofsClockSource {
        return .{
            .reader = shared_clock.ClockReader.init(clock_path),
            ._wall_fallback = WallClockSource.init(),
        };
    }

    pub fn deinit(self: ChronofsClockSource) void {
        self.reader.deinit();
    }

    pub fn isValid(self: *const ChronofsClockSource) bool {
        return self.reader.isValid();
    }

    /// AD-43.3a fix (c), adoption gate: true when the published
    /// sample count advances across one read window. chronofs
    /// clock_valid never resets and valid-with-paused-samples is a
    /// designed state (fresh boot, engine not yet clocking), so
    /// validity alone must never be the adoption criterion for a
    /// pacing clock. The engine publishes whole interrupt periods
    /// (1024 samples, ~21 ms at 48 kHz, ~23 ms at 44.1 kHz), so the
    /// window must exceed one period; 50 ms covers rates down to
    /// ~20.5 kHz. The cost is one 50 ms sleep, once, at daemon
    /// start.
    pub fn isAdvancing(self: *const ChronofsClockSource) bool {
        if (!self.reader.isValid()) return false;
        const a = self.reader.read();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        const b = self.reader.read();
        return b > a;
    }

    pub fn source(self: *ChronofsClockSource) ClockSource {
        return .{
            .context = @ptrCast(self),
            .nowFn = nowImpl,
        };
    }

    /// Current sample position in nanoseconds.
    /// Falls back to wall clock if audio clock is not yet valid.
    pub fn nowNs(self: *const ChronofsClockSource) i128 {
        if (self.reader.isValid()) {
            const samples = self.reader.read();
            const rate = self.reader.sampleRate();
            return @intCast(shared_clock.toNanoseconds(samples, rate));
        }
        return std.time.nanoTimestamp();
    }

    /// Current audio sample position (for embedding in events).
    /// Returns null if clock is not valid.
    pub fn samplePosition(self: *const ChronofsClockSource) ?u64 {
        if (!self.reader.isValid()) return null;
        return self.reader.read();
    }

    fn nowImpl(ctx: *anyopaque) i128 {
        const self: *ChronofsClockSource = @ptrCast(@alignCast(ctx));
        return self.nowNs();
    }
};

/// Return the next frame boundary in audio sample frames above `clock.now()`.
///
/// Formula: `((samples_now / spf) + 1) * spf`
/// where `spf = sample_rate / refresh_hz`.
///
/// At 48kHz / 60Hz: spf = 800, so frames land on multiples of 800 samples.
/// Returns 0 if the clock is not valid (caller should fall back to wall time).
pub fn nextFrameTarget(reader: shared_clock.ClockReader, refresh_hz: u32) u64 {
    if (!reader.isValid()) return 0;
    const sample_rate = reader.sampleRate();
    if (sample_rate == 0 or refresh_hz == 0) return 0;
    const spf: u64 = sample_rate / refresh_hz;
    if (spf == 0) return 0;
    const now = reader.read();
    return ((now / spf) + 1) * spf;
}

// ============================================================================
// FrameStats
// ============================================================================

/// Frame timing statistics
pub const FrameStats = struct {
    total_frames: u64 = 0,
    missed_frames: u64 = 0,
    last_frame_ns: u64 = 0,
    avg_frame_ns: u64 = 0,
    max_frame_ns: u64 = 0,
    min_frame_ns: u64 = std.math.maxInt(u64),

    pub fn update(self: *FrameStats, duration_ns: u64, missed: bool) void {
        self.total_frames += 1;
        if (missed) self.missed_frames += 1;
        self.last_frame_ns = duration_ns;
        self.max_frame_ns = @max(self.max_frame_ns, duration_ns);
        self.min_frame_ns = @min(self.min_frame_ns, duration_ns);
        if (self.avg_frame_ns == 0) {
            self.avg_frame_ns = duration_ns;
        } else {
            self.avg_frame_ns = (self.avg_frame_ns * 9 + duration_ns) / 10;
        }
    }

    pub fn getMissRate(self: *const FrameStats) f64 {
        if (self.total_frames == 0) return 0.0;
        return @as(f64, @floatFromInt(self.missed_frames)) /
            @as(f64, @floatFromInt(self.total_frames));
    }

    pub fn getAverageFps(self: *const FrameStats) f64 {
        if (self.avg_frame_ns == 0) return 0.0;
        return 1_000_000_000.0 / @as(f64, @floatFromInt(self.avg_frame_ns));
    }
};

// ============================================================================
// FrameScheduler
// ============================================================================

/// Frame scheduler, manages timing for vsync-aligned composition.
///
/// Construct with a ClockSource so the time source can be swapped without
/// changing scheduling logic. Pass WallClockSource.source() for production
/// and MockClockSource.source() for deterministic tests.
pub const FrameScheduler = struct {
    clock: ClockSource,
    target_hz: u32,
    frame_interval_ns: u64,
    next_deadline_ns: i128,
    frame_number: u64,
    running: bool,
    stats: FrameStats,
    frame_callback: ?*const fn (frame: u64, deadline_ns: i128) void,

    const Self = @This();

    pub fn init(target_hz: u32, clock: ClockSource) Self {
        const interval = @divFloor(1_000_000_000, @as(u64, target_hz));
        return .{
            .clock = clock,
            .target_hz = target_hz,
            .frame_interval_ns = interval,
            .next_deadline_ns = 0,
            .frame_number = 0,
            .running = false,
            .stats = .{},
            .frame_callback = null,
        };
    }

    pub fn start(self: *Self) void {
        self.running = true;
        self.next_deadline_ns = self.clock.now() + @as(i128, self.frame_interval_ns);
        self.frame_number = 0;
    }

    pub fn stop(self: *Self) void {
        self.running = false;
    }

    pub fn setCallback(self: *Self, callback: *const fn (u64, i128) void) void {
        self.frame_callback = callback;
    }

    pub fn getTimeUntilDeadline(self: *const Self) i64 {
        const remaining = self.next_deadline_ns - self.clock.now();
        return @intCast(@max(0, remaining));
    }

    pub fn shouldComposite(self: *const Self) bool {
        if (!self.running) return false;
        return self.clock.now() >= self.next_deadline_ns;
    }

    pub fn beginFrame(self: *Self) FrameHandle {
        return .{
            .scheduler = self,
            .start_time = self.clock.now(),
            .frame_number = self.frame_number,
        };
    }

    fn advanceFrame(self: *Self, duration_ns: u64) void {
        const now = self.clock.now();
        const missed = now > self.next_deadline_ns + @as(i128, self.frame_interval_ns / 2);

        self.stats.update(duration_ns, missed);
        self.frame_number += 1;

        if (now > self.next_deadline_ns) {
            const intervals_behind = @divFloor(
                @as(u128, @intCast(now - self.next_deadline_ns)),
                self.frame_interval_ns,
            );
            self.next_deadline_ns += @as(i128, @intCast((intervals_behind + 1) * self.frame_interval_ns));
        } else {
            self.next_deadline_ns += @as(i128, self.frame_interval_ns);
        }

        if (self.frame_callback) |cb| {
            cb(self.frame_number, self.next_deadline_ns);
        }
    }

    /// Block until the next frame deadline using wall time.
    /// When a MockClockSource is in use the clock never advances on its own,
    /// so this returns immediately, which is the correct behaviour for tests.
    pub fn waitForDeadline(self: *Self) void {
        const wait_ns = self.getTimeUntilDeadline();
        if (wait_ns > 0) {
            std.Thread.sleep(@intCast(wait_ns));
        }
    }

    pub fn getFrameNumber(self: *const Self) u64 {
        return self.frame_number;
    }

    pub fn getStats(self: *const Self) FrameStats {
        return self.stats;
    }

    pub fn setTargetHz(self: *Self, hz: u32) void {
        self.target_hz = hz;
        self.frame_interval_ns = @divFloor(1_000_000_000, @as(u64, hz));
    }

    pub fn getPresentationTime(self: *const Self, frame_offset: u64) i128 {
        return self.next_deadline_ns + @as(i128, frame_offset * self.frame_interval_ns);
    }
};

// ============================================================================
// FrameHandle
// ============================================================================

pub const FrameHandle = struct {
    scheduler: *FrameScheduler,
    start_time: i128,
    frame_number: u64,

    pub fn end(self: *FrameHandle) void {
        const end_time = self.scheduler.clock.now();
        const duration: u64 = @intCast(end_time - self.start_time);
        self.scheduler.advanceFrame(duration);
    }

    pub fn getElapsed(self: *const FrameHandle) u64 {
        const now = self.scheduler.clock.now();
        return @intCast(now - self.start_time);
    }

    pub fn getRemaining(self: *const FrameHandle) i64 {
        return self.scheduler.getTimeUntilDeadline();
    }
};

// ============================================================================
// AdaptiveScheduler
// ============================================================================

pub const AdaptiveScheduler = struct {
    scheduler: FrameScheduler,
    min_hz: u32,
    max_hz: u32,
    sample_window: u32,
    sample_count: u32,
    window_misses: u32,

    pub fn init(min_hz: u32, max_hz: u32, clock: ClockSource) AdaptiveScheduler {
        return .{
            .scheduler = FrameScheduler.init(max_hz, clock),
            .min_hz = min_hz,
            .max_hz = max_hz,
            .sample_window = 60,
            .sample_count = 0,
            .window_misses = 0,
        };
    }

    pub fn start(self: *AdaptiveScheduler) void {
        self.scheduler.start();
        self.sample_count = 0;
        self.window_misses = 0;
    }

    pub fn stop(self: *AdaptiveScheduler) void {
        self.scheduler.stop();
    }

    pub fn beginFrame(self: *AdaptiveScheduler) FrameHandle {
        return self.scheduler.beginFrame();
    }

    pub fn endFrame(self: *AdaptiveScheduler, handle: *FrameHandle) void {
        const start_stats = self.scheduler.stats;
        handle.end();
        if (self.scheduler.stats.missed_frames > start_stats.missed_frames) {
            self.window_misses += 1;
        }
        self.sample_count += 1;
        if (self.sample_count >= self.sample_window) {
            self.adjustRate();
            self.sample_count = 0;
            self.window_misses = 0;
        }
    }

    fn adjustRate(self: *AdaptiveScheduler) void {
        const miss_rate = @as(f32, @floatFromInt(self.window_misses)) /
            @as(f32, @floatFromInt(self.sample_window));
        if (miss_rate > 0.1 and self.scheduler.target_hz > self.min_hz) {
            const new_hz = @max(self.min_hz, self.scheduler.target_hz - 10);
            self.scheduler.setTargetHz(new_hz);
        } else if (miss_rate < 0.02 and self.scheduler.target_hz < self.max_hz) {
            const new_hz = @min(self.max_hz, self.scheduler.target_hz + 5);
            self.scheduler.setTargetHz(new_hz);
        }
    }

    pub fn shouldComposite(self: *const AdaptiveScheduler) bool {
        return self.scheduler.shouldComposite();
    }

    pub fn waitForDeadline(self: *AdaptiveScheduler) void {
        self.scheduler.waitForDeadline();
    }

    pub fn getStats(self: *const AdaptiveScheduler) FrameStats {
        return self.scheduler.getStats();
    }

    pub fn getCurrentHz(self: *const AdaptiveScheduler) u32 {
        return self.scheduler.target_hz;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WallClockSource returns increasing time" {
    var wall = WallClockSource.init();
    const clock = wall.source();
    const t0 = clock.now();
    std.Thread.sleep(1_000_000); // 1ms
    const t1 = clock.now();
    try std.testing.expect(t1 > t0);
}

test "MockClockSource advances correctly" {
    var mock = MockClockSource.init();
    const clock = mock.source();
    try std.testing.expectEqual(@as(i128, 0), clock.now());
    mock.advance(16_666_667);
    try std.testing.expectEqual(@as(i128, 16_666_667), clock.now());
    mock.advance(16_666_667);
    try std.testing.expectEqual(@as(i128, 33_333_334), clock.now());
}

test "FrameScheduler basic with WallClock" {
    var wall = WallClockSource.init();
    var sched = FrameScheduler.init(60, wall.source());
    sched.start();

    try std.testing.expect(sched.running);
    try std.testing.expectEqual(@as(u64, 16_666_666), sched.frame_interval_ns);

    var handle = sched.beginFrame();
    std.Thread.sleep(1_000_000); // 1ms
    handle.end();

    try std.testing.expectEqual(@as(u64, 1), sched.stats.total_frames);
    try std.testing.expect(sched.stats.last_frame_ns >= 1_000_000);
}

test "FrameScheduler deterministic with MockClock" {
    var mock = MockClockSource.init();
    var sched = FrameScheduler.init(60, mock.source());
    sched.start();

    try std.testing.expect(!sched.shouldComposite());

    mock.advance(sched.frame_interval_ns);
    try std.testing.expect(sched.shouldComposite());

    var handle = sched.beginFrame();
    mock.advance(2_000_000); // 2ms render time
    handle.end();

    try std.testing.expectEqual(@as(u64, 1), sched.stats.total_frames);
    try std.testing.expectEqual(@as(u64, 2_000_000), sched.stats.last_frame_ns);

    try std.testing.expect(!sched.shouldComposite());

    mock.advance(sched.frame_interval_ns - 2_000_000);
    try std.testing.expect(sched.shouldComposite());
}

test "FrameScheduler missed frame detection with MockClock" {
    var mock = MockClockSource.init();
    var sched = FrameScheduler.init(60, mock.source());
    sched.start();

    mock.advance(sched.frame_interval_ns * 3);
    try std.testing.expect(sched.shouldComposite());

    var handle = sched.beginFrame();
    mock.advance(1_000_000);
    handle.end();

    try std.testing.expectEqual(@as(u64, 1), sched.stats.missed_frames);
}

test "FrameStats update" {
    var stats = FrameStats{};

    stats.update(16_000_000, false);
    try std.testing.expectEqual(@as(u64, 1), stats.total_frames);
    try std.testing.expectEqual(@as(u64, 0), stats.missed_frames);

    stats.update(20_000_000, true);
    try std.testing.expectEqual(@as(u64, 2), stats.total_frames);
    try std.testing.expectEqual(@as(u64, 1), stats.missed_frames);
}

test "AdaptiveScheduler init with MockClock" {
    var mock = MockClockSource.init();
    const adaptive = AdaptiveScheduler.init(30, 60, mock.source());
    try std.testing.expectEqual(@as(u32, 30), adaptive.min_hz);
    try std.testing.expectEqual(@as(u32, 60), adaptive.max_hz);
    try std.testing.expectEqual(@as(u32, 60), adaptive.scheduler.target_hz);
}

test "nextFrameTarget with MockClock via shared_clock.ClockWriter" {
    // Write a clock region to a temp file, read it back, verify nextFrameTarget.
    const tmp_path = "/tmp/sema_c4_test_clock";
    {
        var writer = try shared_clock.ClockWriter.init(tmp_path);
        defer writer.deinit();
        // Simulate: 48kHz, 1200 samples written (1.5 frames into 60Hz session).
        writer.write(48_000, 1200);
    }
    var reader = shared_clock.ClockReader.init(tmp_path);
    defer reader.deinit();

    try std.testing.expect(reader.isValid());
    try std.testing.expectEqual(@as(u32, 48_000), reader.sampleRate());

    // spf = 48000 / 60 = 800. now = 1200.
    // nextFrameTarget = ((1200 / 800) + 1) * 800 = (1 + 1) * 800 = 1600.
    const target = nextFrameTarget(reader, 60);
    try std.testing.expectEqual(@as(u64, 1600), target);

    // At exactly a boundary (now = 800): next = ((800/800)+1)*800 = 1600.
    writer: {
        var w = shared_clock.ClockWriter.init(tmp_path) catch break :writer;
        defer w.deinit();
        w.write(48_000, 800);
    }
    var reader2 = shared_clock.ClockReader.init(tmp_path);
    defer reader2.deinit();
    const target2 = nextFrameTarget(reader2, 60);
    try std.testing.expectEqual(@as(u64, 1600), target2);
}
