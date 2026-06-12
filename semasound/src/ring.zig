// F.5.a per-client input ring (ADR 0021 Decision 2).
//
// Single-producer (the client's reader thread) / single-consumer (the
// mixer/output thread) byte ring. push blocks via short sleep-retry while
// full, so a fast client is flow-controlled by the mixer's drain rate
// (which is itself paced by audiofs's blocking write). popInto is
// non-blocking: the mixer takes what is there and zero-fills the rest, so
// it never stalls on a slow client.
//
// No std.Thread.Condition: the UTF Zig in tree uses mutex + std.Thread.sleep
// for this shape, so we match it.

const std = @import("std");

pub const CAP: usize = 64 * 1024; // ~340 ms at 48 kHz/16-bit/stereo

pub const Ring = struct {
    buf: [CAP]u8 = undefined,
    head: usize = 0, // monotonic write counter; index is head % CAP
    tail: usize = 0, // monotonic read counter
    mutex: std.Thread.Mutex = .{},

    pub fn available(self: *Ring) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.head - self.tail;
    }

    // Cumulative flow totals for the F.5.b drift estimator. head and tail are
    // already monotonic byte counters that never reset, so they ARE the flow
    // totals: head = total bytes ever pushed (by the client's reader), tail =
    // total bytes ever popped (by the mixer). The estimator differences these
    // across its window to get the per-client production/consumption mismatch
    // (the ring-fill TREND), which is the signal that actually reflects client
    // drift; the output-vs-hardware-clock slope is structurally blind to it
    // because the mixer's output is hardware-paced by backpressure. Returned
    // in bytes; the estimator converts to frames. Read under the lock so a
    // value is consistent.
    pub fn totalPushed(self: *Ring) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.head;
    }
    pub fn totalPopped(self: *Ring) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tail;
    }

    /// Push all of `bytes`, blocking (sleep-retry) while full. Returns false
    /// if `stop` is set before all bytes are written.
    pub fn pushBlocking(self: *Ring, bytes: []const u8, stop: *std.atomic.Value(bool)) bool {
        var written: usize = 0;
        while (written < bytes.len) {
            self.mutex.lock();
            const used = self.head - self.tail;
            const free = CAP - used;
            if (free == 0) {
                self.mutex.unlock();
                if (stop.load(.acquire)) return false;
                std.Thread.sleep(2 * std.time.ns_per_ms);
                continue;
            }
            const n = @min(free, bytes.len - written);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                self.buf[(self.head + i) % CAP] = bytes[written + i];
            }
            self.head += n;
            self.mutex.unlock();
            written += n;
        }
        return true;
    }

    /// Pop up to dst.len bytes into dst; returns the number popped. Never
    /// blocks.
    pub fn popInto(self: *Ring, dst: []u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const used = self.head - self.tail;
        const n = @min(used, dst.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dst[i] = self.buf[(self.tail + i) % CAP];
        }
        self.tail += n;
        return n;
    }

    /// Pop only whole `frame`-sized units, up to the largest multiple of
    /// `frame` that fits both the available bytes and dst. A trailing
    /// partial frame stays in the ring until the rest arrives, so the
    /// output path never desyncs channel alignment. Returns bytes popped.
    pub fn popFramesInto(self: *Ring, dst: []u8, frame: usize) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const used = self.head - self.tail;
        const usable = (used / frame) * frame;
        const cap = (dst.len / frame) * frame;
        const n = @min(usable, cap);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dst[i] = self.buf[(self.tail + i) % CAP];
        }
        self.tail += n;
        return n;
    }
};

test "ring push/pop roundtrip" {
    var r = Ring{};
    var stop = std.atomic.Value(bool).init(false);
    const in = [_]u8{ 1, 2, 3, 4, 5 };
    try std.testing.expect(r.pushBlocking(&in, &stop));
    try std.testing.expectEqual(@as(usize, 5), r.available());
    var out: [8]u8 = undefined;
    const n = r.popInto(&out);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualSlices(u8, &in, out[0..n]);
    try std.testing.expectEqual(@as(usize, 0), r.available());
}

test "ring wraps correctly" {
    var r = Ring{};
    var stop = std.atomic.Value(bool).init(false);
    // advance head/tail near CAP so the next push wraps
    var sink: [CAP]u8 = undefined;
    var filler: [CAP - 4]u8 = undefined;
    _ = r.pushBlocking(&filler, &stop);
    _ = r.popInto(&sink); // tail now at CAP-4, head at CAP-4
    const in = [_]u8{ 9, 8, 7, 6, 5, 4 }; // crosses the CAP boundary
    try std.testing.expect(r.pushBlocking(&in, &stop));
    var out: [6]u8 = undefined;
    const n = r.popInto(&out);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualSlices(u8, &in, out[0..n]);
}

test "popFramesInto keeps a partial frame" {
    var r = Ring{};
    var stop = std.atomic.Value(bool).init(false);
    const in = [_]u8{ 1, 2, 3, 4, 5, 6 }; // one 4-byte frame + 2 leftover
    try std.testing.expect(r.pushBlocking(&in, &stop));
    var out: [16]u8 = undefined;
    const n = r.popFramesInto(&out, 4);
    try std.testing.expectEqual(@as(usize, 4), n); // only the whole frame
    try std.testing.expectEqual(@as(usize, 2), r.available()); // leftover held
}
