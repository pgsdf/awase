const std = @import("std");

// ============================================================================
// Event payload types
// ============================================================================

/// Audio domain event — emitted by semaaud on stream lifecycle transitions.
pub const AudioEvent = struct {
    stream_id:       u64,
    samples_written: u64,
    active:          bool,
};

/// Visual domain event — emitted by semadraw on frame completion.
pub const VisualEvent = struct {
    surface_id:   u32,
    frame_number: u64,
};

/// Input domain event — a compact representation of a semainput semantic event.
/// The full tagged union lives in semainput; chronofs uses a flat summary to
/// avoid a layering dependency on semainput internals.
pub const InputEvent = struct {
    /// Event type string, truncated to 32 bytes.
    event_type: [32]u8,
    event_type_len: u8,
    /// Source device identifier, truncated to 64 bytes.
    device: [64]u8,
    device_len: u8,
    /// Optional scalar payload (dx, dy, code, contact, etc.).
    x: i32,
    y: i32,

    pub fn fromType(event_type_str: []const u8, device_str: []const u8) InputEvent {
        var ev = InputEvent{
            .event_type = [_]u8{0} ** 32,
            .event_type_len = 0,
            .device = [_]u8{0} ** 64,
            .device_len = 0,
            .x = 0,
            .y = 0,
        };
        const tn = @min(event_type_str.len, 32);
        @memcpy(ev.event_type[0..tn], event_type_str[0..tn]);
        ev.event_type_len = @intCast(tn);
        const dn = @min(device_str.len, 64);
        @memcpy(ev.device[0..dn], device_str[0..dn]);
        ev.device_len = @intCast(dn);
        return ev;
    }

    pub fn typeName(self: *const InputEvent) []const u8 {
        return self.event_type[0..self.event_type_len];
    }

    pub fn deviceName(self: *const InputEvent) []const u8 {
        return self.device[0..self.device_len];
    }
};

// ============================================================================
// EventStream(T) — thread-safe ring buffer indexed by audio sample position
// ============================================================================

/// A timestamped entry in the stream.
pub fn Entry(comptime T: type) type {
    return struct {
        /// Audio sample position at which this event occurred.
        t: u64,
        payload: T,
    };
}

/// Append-only ring buffer of timestamped events.
///
/// - Capacity is fixed at compile time.
/// - When full, `append` silently evicts the oldest entry (ring behaviour).
/// - All operations acquire `mutex` for the duration, making the type safe for
///   concurrent access from separate writer and reader threads.
/// - `t` values must be non-decreasing for `at()` and `query()` to work
///   correctly; chronofs enforces this by deriving `t` from the monotonic
///   audio clock.
pub fn EventStream(comptime T: type, comptime capacity: usize) type {
    comptime std.debug.assert(capacity > 0);

    return struct {
        const Self = @This();
        const E = Entry(T);

        mutex:  std.Thread.Mutex,
        buf:    [capacity]E,
        /// Index of the next slot to write.
        head:   usize,
        /// Number of valid entries currently stored (0..capacity).
        count:  usize,

        pub fn init() Self {
            return .{
                .mutex = .{},
                .buf   = undefined,
                .head  = 0,
                .count = 0,
            };
        }

        /// Append an entry at time `t`.
        /// If the buffer is full the oldest entry is silently overwritten.
        pub fn append(self: *Self, t: u64, payload: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.buf[self.head] = .{ .t = t, .payload = payload };
            self.head = (self.head + 1) % capacity;
            if (self.count < capacity) self.count += 1;
        }

        /// Return the most recent entry, or null if the stream is empty.
        pub fn latest(self: *Self) ?E {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.latestLocked();
        }

        /// Return the latest entry where `entry.t <= t` (state resolution).
        /// Returns null if no such entry exists.
        pub fn at(self: *Self, t: u64) ?E {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count == 0) return null;

            // Walk forward (oldest → newest), keeping the last entry whose
            // t <= query t.  This gives us the most recent state at time t.
            var result: ?E = null;
            for (0..self.count) |i| {
                const entry = self.slotAt(i);
                if (entry.t <= t) {
                    result = entry;
                } else {
                    break; // entries are in non-decreasing t order
                }
            }
            return result;
        }

        /// Fill `out` with all entries where `t_start <= entry.t <= t_end`,
        /// in chronological order.  Returns the number of entries written.
        /// `out` is truncated if there are more matching entries than space.
        pub fn query(self: *Self, t_start: u64, t_end: u64, out: []E) usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count == 0 or t_start > t_end) return 0;

            var written: usize = 0;
            for (0..self.count) |i| {
                const entry = self.slotAt(i);
                if (entry.t >= t_start and entry.t <= t_end) {
                    if (written >= out.len) break;
                    out[written] = entry;
                    written += 1;
                }
            }
            return written;
        }

        /// Number of entries currently stored.
        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }

        /// True if the buffer has no entries.
        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count == 0;
        }

        // ---------------------------------------------------------------
        // Internal helpers (must be called with mutex held)
        // ---------------------------------------------------------------

        /// Return the i-th oldest entry (0 = oldest).
        fn slotAt(self: *const Self, i: usize) E {
            // The oldest entry lives at (head - count + i) mod capacity.
            const oldest = (self.head + capacity - self.count) % capacity;
            return self.buf[(oldest + i) % capacity];
        }

        fn latestLocked(self: *const Self) ?E {
            if (self.count == 0) return null;
            return self.slotAt(self.count - 1);
        }
    };
}

// ============================================================================
// DomainStreams — one EventStream per domain
// ============================================================================

const AUDIO_CAPACITY:  usize = 1024;
const VISUAL_CAPACITY: usize = 4096; // frames arrive more frequently
const INPUT_CAPACITY:  usize = 4096;

pub const AudioStream  = EventStream(AudioEvent,  AUDIO_CAPACITY);
pub const VisualStream = EventStream(VisualEvent, VISUAL_CAPACITY);
pub const InputStream  = EventStream(InputEvent,  INPUT_CAPACITY);

/// Owns one ring-buffered event stream per domain.
/// All streams are independently thread-safe.
pub const DomainStreams = struct {
    audio:  AudioStream,
    visual: VisualStream,
    input:  InputStream,

    pub fn init() DomainStreams {
        return .{
            .audio  = AudioStream.init(),
            .visual = VisualStream.init(),
            .input  = InputStream.init(),
        };
    }

    // Typed append helpers.

    pub fn appendAudio(self: *DomainStreams, t: u64, ev: AudioEvent) void {
        self.audio.append(t, ev);
    }

    pub fn appendVisual(self: *DomainStreams, t: u64, ev: VisualEvent) void {
        self.visual.append(t, ev);
    }

    pub fn appendInput(self: *DomainStreams, t: u64, ev: InputEvent) void {
        self.input.append(t, ev);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "EventStream append and latest" {
    var s = EventStream(u32, 8).init();

    try std.testing.expect(s.latest() == null);

    s.append(10, 100);
    const l = s.latest().?;
    try std.testing.expectEqual(@as(u64, 10), l.t);
    try std.testing.expectEqual(@as(u32, 100), l.payload);

    s.append(20, 200);
    const l2 = s.latest().?;
    try std.testing.expectEqual(@as(u64, 20), l2.t);
    try std.testing.expectEqual(@as(u32, 200), l2.payload);
}

test "EventStream at — state resolution" {
    var s = EventStream(u32, 8).init();
    s.append(10, 100);
    s.append(30, 300);
    s.append(50, 500);

    // Exactly on a timestamp.
    const e10 = s.at(10).?;
    try std.testing.expectEqual(@as(u32, 100), e10.payload);

    // Between timestamps — returns latest entry <= t.
    const e20 = s.at(20).?;
    try std.testing.expectEqual(@as(u32, 100), e20.payload);

    const e35 = s.at(35).?;
    try std.testing.expectEqual(@as(u32, 300), e35.payload);

    // Beyond last entry.
    const e99 = s.at(99).?;
    try std.testing.expectEqual(@as(u32, 500), e99.payload);

    // Before first entry — no entry qualifies.
    const e0 = s.at(5);
    try std.testing.expect(e0 == null);
}

test "EventStream query range" {
    var s = EventStream(u32, 16).init();
    s.append(10, 100);
    s.append(20, 200);
    s.append(30, 300);
    s.append(40, 400);
    s.append(50, 500);

    var out: [8]Entry(u32) = undefined;

    // Full range.
    const n1 = s.query(10, 50, &out);
    try std.testing.expectEqual(@as(usize, 5), n1);
    try std.testing.expectEqual(@as(u32, 100), out[0].payload);
    try std.testing.expectEqual(@as(u32, 500), out[4].payload);

    // Partial range.
    const n2 = s.query(20, 40, &out);
    try std.testing.expectEqual(@as(usize, 3), n2);
    try std.testing.expectEqual(@as(u32, 200), out[0].payload);
    try std.testing.expectEqual(@as(u32, 400), out[2].payload);

    // No entries in range.
    const n3 = s.query(60, 100, &out);
    try std.testing.expectEqual(@as(usize, 0), n3);

    // Out buffer too small — truncated.
    var small: [2]Entry(u32) = undefined;
    const n4 = s.query(10, 50, &small);
    try std.testing.expectEqual(@as(usize, 2), n4);
}

test "EventStream ring overflow evicts oldest" {
    // Capacity 4: fill then overflow.
    var s = EventStream(u32, 4).init();
    s.append(10, 100);
    s.append(20, 200);
    s.append(30, 300);
    s.append(40, 400);
    // Buffer is now full. Next append evicts t=10.
    s.append(50, 500);

    try std.testing.expectEqual(@as(usize, 4), s.len());

    // Oldest entry is now t=20.
    const e10 = s.at(10);
    try std.testing.expect(e10 == null);

    const e20 = s.at(20).?;
    try std.testing.expectEqual(@as(u32, 200), e20.payload);

    const e50 = s.at(50).?;
    try std.testing.expectEqual(@as(u32, 500), e50.payload);
}

test "EventStream concurrent append and query" {
    // Two threads: one appending, one querying. Verify no corruption.
    var s = EventStream(u64, 256).init();

    const writer = struct {
        fn run(stream: *EventStream(u64, 256)) void {
            var t: u64 = 0;
            while (t < 10_000) : (t += 1) {
                stream.append(t, t * 7);
            }
        }
    };

    const reader = struct {
        fn run(stream: *EventStream(u64, 256)) void {
            var reads: usize = 0;
            while (reads < 1000) : (reads += 1) {
                _ = stream.latest();
                std.Thread.sleep(1);
            }
        }
    };

    const wt = try std.Thread.spawn(.{}, writer.run, .{&s});
    const rt = try std.Thread.spawn(.{}, reader.run, .{&s});
    wt.join();
    rt.join();

    // After writing t=0..9999, latest should be t=9999 with payload 9999*7.
    const l = s.latest().?;
    try std.testing.expectEqual(@as(u64, 9_999), l.t);
    try std.testing.expectEqual(@as(u64, 9_999 * 7), l.payload);
}

test "DomainStreams typed append and query" {
    var ds = DomainStreams.init();

    ds.appendAudio(1000, .{ .stream_id = 1, .samples_written = 48_000, .active = true });
    ds.appendVisual(1500, .{ .surface_id = 42, .frame_number = 100 });
    ds.appendInput(1200, InputEvent.fromType("mouse_move", "pointer:rel-0"));

    const audio = ds.audio.at(1000).?;
    try std.testing.expectEqual(@as(u64, 1), audio.payload.stream_id);
    try std.testing.expect(audio.payload.active);

    const visual = ds.visual.at(2000).?;
    try std.testing.expectEqual(@as(u32, 42), visual.payload.surface_id);

    const input = ds.input.at(1200).?;
    try std.testing.expectEqualStrings("mouse_move", input.payload.typeName());
}

test "InputEvent fromType and typeName" {
    const ev = InputEvent.fromType("three_finger_swipe_begin", "touch:rel-0-b0-w0-a2-t3-0");
    try std.testing.expectEqualStrings("three_finger_swipe_begin", ev.typeName());
    try std.testing.expectEqualStrings("touch:rel-0-b0-w0-a2-t3-0", ev.deviceName());
}
