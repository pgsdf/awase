// F.5.e (ADR 0027 Decision 3): the per-target in-memory event ring.
//
// HARD CONSTRAINT (operator amendment): append() is the only operation audio
// threads perform for observability, and it is O(1) under an uncontended
// mutex with NO allocation, NO syscalls, NO logging, and NO indirect calls:
// a bounded copy into a preallocated slot. The timestamp and frame position
// are taken as ARGUMENTS so the append itself reads no clock; callers reuse
// clock values they already hold (the audio loops read time for pacing
// anyway; the accept thread reads its own). Future edits may not expand this
// critical section; the sanctioned path for richer producer-side work is an
// SPSC ring per producer, not growth of the locked region.
//
// Seq guarantee (operator amendment): seq is monotonic per-target and never
// resets within a runtime instance. The ring keeps the latest CAPACITY
// events; on overflow the oldest drop, and the published events file then
// shows a seq gap, the defined, downstream-detectable overflow signal.

const std = @import("std");

pub const CAPACITY: usize = 128;
pub const MAX_DETAIL: usize = 96;

pub const Kind = enum {
    admitted,
    denied,
    preempted,
    fallback,
    election,
    reaped,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .admitted => "admitted",
            .denied => "denied",
            .preempted => "preempted",
            .fallback => "fallback",
            .election => "election",
            .reaped => "reaped",
        };
    }
};

pub const Event = struct {
    seq: u64 = 0,
    ts_ns: i64 = 0,
    frames: u64 = 0,
    kind: Kind = .admitted,
    detail: [MAX_DETAIL]u8 = undefined,
    detail_len: usize = 0,

    pub fn detailSlice(self: *const Event) []const u8 {
        return self.detail[0..self.detail_len];
    }
};

pub const EventRing = struct {
    mutex: std.Thread.Mutex = .{},
    buf: [CAPACITY]Event = [_]Event{.{}} ** CAPACITY,
    total: u64 = 0, // events ever appended; seq of the next event is total+1

    /// The constrained append. O(1), no allocation, no syscalls, no logging,
    /// no indirect calls: bounded copies into the preallocated slot.
    pub fn append(self: *EventRing, kind: Kind, ts_ns: i64, frames: u64, detail: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = &self.buf[@intCast(self.total % CAPACITY)];
        self.total += 1;
        slot.seq = self.total;
        slot.ts_ns = ts_ns;
        slot.frames = frames;
        slot.kind = kind;
        const n = @min(detail.len, MAX_DETAIL);
        @memcpy(slot.detail[0..n], detail[0..n]);
        slot.detail_len = n;
    }

    /// Copy out the retained events in ascending seq order. Returns the
    /// count copied (at most CAPACITY) and, via total_out, the seq of the
    /// newest event (0 if none). Publisher-side only.
    pub fn snapshot(self: *EventRing, out: []Event, total_out: *u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        total_out.* = self.total;
        const have: usize = @intCast(@min(self.total, CAPACITY));
        const n = @min(have, out.len);
        // Oldest retained event has seq total-have+1, located at
        // (total-have) % CAPACITY.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const idx: usize = @intCast((self.total - have + i) % CAPACITY);
            out[i] = self.buf[idx];
        }
        return n;
    }
};

test "seq is monotonic and never resets" {
    var r = EventRing{};
    r.append(.admitted, 1, 0, "a");
    r.append(.reaped, 2, 10, "b");
    var out: [CAPACITY]Event = undefined;
    var total: u64 = 0;
    const n = r.snapshot(&out, &total);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u64, 1), out[0].seq);
    try std.testing.expectEqual(@as(u64, 2), out[1].seq);
    try std.testing.expectEqual(@as(u64, 2), total);
}

test "overflow keeps the latest CAPACITY with a detectable seq gap" {
    var r = EventRing{};
    var i: usize = 0;
    while (i < CAPACITY + 10) : (i += 1) {
        r.append(.admitted, 0, 0, "x");
    }
    var out: [CAPACITY]Event = undefined;
    var total: u64 = 0;
    const n = r.snapshot(&out, &total);
    try std.testing.expectEqual(CAPACITY, n);
    try std.testing.expectEqual(@as(u64, CAPACITY + 10), total);
    // Oldest retained seq is 11: seqs 1..10 are the gap consumers can detect.
    try std.testing.expectEqual(@as(u64, 11), out[0].seq);
    try std.testing.expectEqual(@as(u64, CAPACITY + 10), out[n - 1].seq);
}

test "detail is bounded and copied" {
    var r = EventRing{};
    const long = "d" ** (MAX_DETAIL + 40);
    r.append(.denied, 0, 0, long);
    var out: [CAPACITY]Event = undefined;
    var total: u64 = 0;
    _ = r.snapshot(&out, &total);
    try std.testing.expectEqual(MAX_DETAIL, out[0].detail_len);
}
