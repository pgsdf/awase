const std = @import("std");
const shared_clock = @import("shared_clock");

// ============================================================================
// Clock — wraps the shared audio hardware clock
// ============================================================================

/// A read-only view of the audio hardware clock published by semaaud.
///
/// `now()` returns the current monotonic PCM sample frame count. Callers
/// should check `isValid()` before trusting the value — it is false until
/// semaaud has started and at least one audio stream has begun.
///
/// `Clock.init` is non-fatal: if the clock file is absent (semaaud not
/// running) the Clock opens in an invalid state and all reads return 0.
pub const Clock = struct {
    reader: shared_clock.ClockReader,

    /// Open the clock at the given path. Does not fail if the file is absent.
    pub fn init(path: []const u8) Clock {
        return .{ .reader = shared_clock.ClockReader.init(path) };
    }

    /// Open the clock at the default path (/var/run/sema/clock).
    pub fn initDefault() Clock {
        return init(shared_clock.CLOCK_PATH);
    }

    pub fn deinit(self: Clock) void {
        self.reader.deinit();
    }

    /// True if the clock file is open and at least one audio stream has
    /// started (i.e. clock_valid == 1 in the shared region).
    pub fn isValid(self: Clock) bool {
        return self.reader.isValid();
    }

    /// Current audio position in PCM sample frames.
    /// Returns 0 if not valid.
    pub fn now(self: Clock) u64 {
        return self.reader.read();
    }

    /// Sample rate of the active audio stream in Hz.
    /// Returns 0 if not valid.
    pub fn sampleRate(self: Clock) u32 {
        return self.reader.sampleRate();
    }

    /// Convert a sample position to nanoseconds using the current sample rate.
    /// Returns 0 if the sample rate is 0 or the clock is not valid.
    pub fn toNs(self: Clock, samples: u64) u64 {
        return shared_clock.toNanoseconds(samples, self.reader.sampleRate());
    }
};

// ============================================================================
// MockClock — deterministic stand-in for testing
// ============================================================================

/// A manually-advanced clock for use in tests and simulations.
///
/// `isValid()` always returns true — the mock clock is always live.
/// Advance the position with `advance(delta_samples)`.
///
/// Example:
///   var mock = MockClock.init(48_000);
///   mock.advance(48_000);  // advance by 1 second at 48kHz
///   std.debug.assert(mock.now() == 48_000);
///   std.debug.assert(mock.toNs(48_000) == 1_000_000_000);
pub const MockClock = struct {
    samples: u64,
    rate: u32,

    /// Create a mock clock at position 0 with the given sample rate.
    pub fn init(sample_rate: u32) MockClock {
        return .{ .samples = 0, .rate = sample_rate };
    }

    /// Advance the clock position by `delta` sample frames.
    pub fn advance(self: *MockClock, delta: u64) void {
        self.samples += delta;
    }

    /// Set the clock to an absolute sample position.
    pub fn setPosition(self: *MockClock, position: u64) void {
        self.samples = position;
    }

    /// Current position in PCM sample frames.
    pub fn now(self: MockClock) u64 {
        return self.samples;
    }

    /// Always returns true — the mock clock is always live.
    pub fn isValid(self: MockClock) bool {
        _ = self;
        return true;
    }

    /// Sample rate this mock clock was created with.
    pub fn sampleRate(self: MockClock) u32 {
        return self.rate;
    }

    /// Convert a sample position to nanoseconds.
    pub fn toNs(self: MockClock, samples: u64) u64 {
        return shared_clock.toNanoseconds(samples, self.rate);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MockClock basic" {
    var mock = MockClock.init(48_000);

    try std.testing.expectEqual(@as(u64, 0), mock.now());
    try std.testing.expect(mock.isValid());
    try std.testing.expectEqual(@as(u32, 48_000), mock.sampleRate());
}

test "MockClock advance accumulates correctly" {
    var mock = MockClock.init(48_000);

    mock.advance(48_000);
    try std.testing.expectEqual(@as(u64, 48_000), mock.now());

    mock.advance(48_000);
    try std.testing.expectEqual(@as(u64, 96_000), mock.now());

    mock.advance(1);
    try std.testing.expectEqual(@as(u64, 96_001), mock.now());
}

test "MockClock.advance(48000) followed by now() returns 48000" {
    // Explicit acceptance criterion from C-1 backlog.
    var mock = MockClock.init(48_000);
    mock.advance(48_000);
    try std.testing.expectEqual(@as(u64, 48_000), mock.now());
}

test "MockClock.toNs(48000) at 48kHz returns 1_000_000_000" {
    // Explicit acceptance criterion from C-1 backlog.
    const mock = MockClock.init(48_000);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), mock.toNs(48_000));
}

test "MockClock setPosition" {
    var mock = MockClock.init(48_000);
    mock.setPosition(999_999);
    try std.testing.expectEqual(@as(u64, 999_999), mock.now());
    mock.advance(1);
    try std.testing.expectEqual(@as(u64, 1_000_000), mock.now());
}

test "MockClock toNs at various rates" {
    const mock_44 = MockClock.init(44_100);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), mock_44.toNs(44_100));

    const mock_96 = MockClock.init(96_000);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), mock_96.toNs(96_000));
    try std.testing.expectEqual(@as(u64, 500_000_000), mock_96.toNs(48_000));
}

test "Clock.isValid() returns false before semaaud starts" {
    // Explicit acceptance criterion from C-1 backlog.
    // Use a path that will never exist.
    const clock = Clock.init("/var/run/sema/clock_c1_test_absent");
    defer clock.deinit();
    try std.testing.expect(!clock.isValid());
    try std.testing.expectEqual(@as(u64, 0), clock.now());
    try std.testing.expectEqual(@as(u32, 0), clock.sampleRate());
    try std.testing.expectEqual(@as(u64, 0), clock.toNs(48_000));
}

test "Clock wraps ClockReader correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const clock_path = try std.fmt.bufPrint(&full_buf, "{s}/clock", .{tmp_path});

    // Create a writer to publish the clock.
    var writer = try shared_clock.ClockWriter.init(clock_path);
    defer writer.deinit();

    // Clock before any stream: not valid.
    const clock = Clock.init(clock_path);
    defer clock.deinit();
    try std.testing.expect(!clock.isValid());

    // Start a stream at 48kHz.
    writer.streamBegin(48_000);
    try std.testing.expect(clock.isValid());
    try std.testing.expectEqual(@as(u32, 48_000), clock.sampleRate());
    try std.testing.expectEqual(@as(u64, 0), clock.now());

    // Publish 1 second of audio.
    writer.update(48_000);
    try std.testing.expectEqual(@as(u64, 48_000), clock.now());
    try std.testing.expectEqual(@as(u64, 1_000_000_000), clock.toNs(clock.now()));

    // Publish 2 seconds of audio.
    writer.update(96_000);
    try std.testing.expectEqual(@as(u64, 96_000), clock.now());
    try std.testing.expectEqual(@as(u64, 2_000_000_000), clock.toNs(clock.now()));
}
