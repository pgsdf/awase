//! chronofs: TimeIndex, a single ordered-instant index (ADRs 0002, 0003, 0005).
//!
//! Holds (instant, handle) points on one bound axis (ADR 0002): sorted,
//! out-of-order-tolerant, non-evicting insertion; a functional
//! instant-to-handle relation with a per-index supersession policy; and static
//! or windowed retention measured on the bound axis (ADR 0003). The handle is
//! opaque and never decoded (ADR 0002 Decision 2). Resolution (ADR 0005) maps
//! a cursor and the boundary states to a value or a miss under each resample
//! policy, with signed staleness and the four-reason miss taxonomy.

const std = @import("std");
const instant_mod = @import("instant");

/// Opaque fetch key; chronofs never decodes it (ADR 0002 Decision 2).
pub const SeriesHandle = u64;
pub const Instant = instant_mod.Instant;

/// Which sample wins at a repeated instant (ADR 0003 Decision 2).
pub const Supersession = enum {
    /// Most recently inserted wins (correct when inserts arrive in order).
    last_insertion,
    /// A client-supplied monotonic sequence: strictly greater supersedes,
    /// equal or lesser is dropped (reorder-safe, idempotent re-delivery).
    sequenced,
};

/// How the index bounds its history (ADR 0003 Decision 3).
pub const Retention = enum {
    /// Keep every inserted sample; nothing dropped.
    static,
    /// Drop samples older than a horizon, a span on the bound axis behind the
    /// most recently indexed instant.
    windowed,
};

/// A read-only view of a stored point; the internal sequence is not exposed.
pub const PointView = struct {
    instant: Instant,
    handle: SeriesHandle,
};

/// Resampling policy: how a cursor between or beyond samples resolves
/// (ADR 0005).
pub const Resample = enum { hold_last, nearest, linear, none };

/// Why a resolve yielded no value (ADR 0005 Decision 5; the first three are
/// ADR 0003's boundary reasons, no_sample is the in-range reason).
pub const MissReason = enum { before_start, after_end, below_horizon, no_sample };

/// A resolved value: an opaque handle and signed staleness in nanoseconds
/// (t - sample.instant): >= 0 for a hold, < 0 when the sample is ahead of the
/// cursor. Saturates at the i64 bounds rather than overflowing.
pub const Value = struct {
    handle: SeriesHandle,
    staleness_ns: i64,
};

/// A linear bracket: the two surrounding handles and the fraction in [0, 1]
/// of the cursor between them. chronofs returns the handles and the fraction
/// and never blends the field data; the consumer interpolates (ADR 0005).
pub const Lerp = struct {
    lo: SeriesHandle,
    hi: SeriesHandle,
    frac: f32,
};

/// The result of a resolve (ADR 0005).
pub const Sample = union(enum) {
    miss: MissReason,
    value: Value,
    lerp: Lerp,
};

pub const Config = struct {
    supersession: Supersession = .last_insertion,
    retention: Retention = .static,
    /// Required > 0 when retention == .windowed; ignored otherwise.
    window_span_ns: Instant = 0,
};

pub const InsertError = error{
    /// Static retention is full; non-evicting, so the insert is refused
    /// rather than dropping an existing sample. Backing-store sizing is the
    /// capacity (an implementation detail per ADR 0003 Decision 3).
    Full,
    /// Windowed retention: the instant is older than the current horizon.
    BelowHorizon,
    /// The insert method does not match the index's supersession policy.
    PolicyMismatch,
};

pub fn TimeIndex(comptime capacity: usize) type {
    comptime std.debug.assert(capacity > 0);

    return struct {
        const Self = @This();
        const Point = struct {
            instant: Instant,
            handle: SeriesHandle,
            seq: u64,
        };

        buf: [capacity]Point,
        count: usize,
        supersession: Supersession,
        retention: Retention,
        window_span_ns: Instant,
        seq_counter: u64,

        pub fn init(cfg: Config) Self {
            return .{
                .buf = undefined,
                .count = 0,
                .supersession = cfg.supersession,
                .retention = cfg.retention,
                .window_span_ns = cfg.window_span_ns,
                .seq_counter = 0,
            };
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        /// Earliest retained instant, or null when empty.
        pub fn first(self: *const Self) ?Instant {
            return if (self.count == 0) null else self.buf[0].instant;
        }

        /// Latest retained instant, or null when empty.
        pub fn last(self: *const Self) ?Instant {
            return if (self.count == 0) null else self.buf[self.count - 1].instant;
        }

        /// The i-th point in ascending instant order (0 = earliest).
        pub fn pointAt(self: *const Self, i: usize) PointView {
            std.debug.assert(i < self.count);
            return .{ .instant = self.buf[i].instant, .handle = self.buf[i].handle };
        }

        /// Handle at exactly `t`, or null if no sample sits there.
        pub fn lookupExact(self: *const Self, t: Instant) ?SeriesHandle {
            const pos = self.lowerBound(t);
            if (pos < self.count and self.buf[pos].instant == t) return self.buf[pos].handle;
            return null;
        }

        /// Resolve a cursor `t` to a Sample under `policy` (ADR 0005).
        ///
        /// below_horizon is reported before any clamp or hold; an empty index
        /// is before_start. hold_last holds the predecessor (and holds past
        /// the last sample with growing staleness); nearest clamps at both
        /// ends with signed staleness, the earlier instant winning a tie;
        /// linear returns the bracketing handles and a fraction and does not
        /// extrapolate; none returns a value only on an exact hit.
        pub fn resolve(self: *const Self, t: Instant, policy: Resample) Sample {
            if (self.count == 0) return .{ .miss = .before_start };

            // below_horizon precedence: a windowed cursor below the horizon
            // returns below_horizon under every policy, before any clamp.
            if (self.retention == .windowed) {
                const latest = self.buf[self.count - 1].instant;
                if (belowHorizon(t, latest, self.window_span_ns)) return .{ .miss = .below_horizon };
            }

            const lb = self.lowerBound(t);
            if (lb < self.count and self.buf[lb].instant == t) {
                // Exact hit: every policy returns the sample with zero staleness.
                return .{ .value = .{ .handle = self.buf[lb].handle, .staleness_ns = 0 } };
            }

            const has_pred = lb > 0; // predecessor at buf[lb - 1]
            const has_succ = lb < self.count; // successor at buf[lb]

            switch (policy) {
                .hold_last => {
                    if (has_pred) {
                        const p = self.buf[lb - 1];
                        return .{ .value = .{ .handle = p.handle, .staleness_ns = staleness(t, p.instant) } };
                    }
                    return .{ .miss = .before_start };
                },
                .nearest => {
                    if (has_pred and has_succ) {
                        const p = self.buf[lb - 1];
                        const s = self.buf[lb];
                        const d_pred = @as(i128, t) - @as(i128, p.instant);
                        const d_succ = @as(i128, s.instant) - @as(i128, t);
                        const chosen = if (d_pred <= d_succ) p else s; // tie: earlier
                        return .{ .value = .{ .handle = chosen.handle, .staleness_ns = staleness(t, chosen.instant) } };
                    } else if (has_pred) {
                        const p = self.buf[lb - 1];
                        return .{ .value = .{ .handle = p.handle, .staleness_ns = staleness(t, p.instant) } };
                    } else {
                        const s = self.buf[lb];
                        return .{ .value = .{ .handle = s.handle, .staleness_ns = staleness(t, s.instant) } };
                    }
                },
                .linear => {
                    if (has_pred and has_succ) {
                        const p = self.buf[lb - 1];
                        const s = self.buf[lb];
                        const num: f32 = @floatFromInt(@as(i128, t) - @as(i128, p.instant));
                        const den: f32 = @floatFromInt(@as(i128, s.instant) - @as(i128, p.instant));
                        return .{ .lerp = .{ .lo = p.handle, .hi = s.handle, .frac = num / den } };
                    } else if (has_pred) {
                        return .{ .miss = .after_end }; // no extrapolation
                    } else {
                        return .{ .miss = .before_start };
                    }
                },
                .none => {
                    if (has_pred and has_succ) return .{ .miss = .no_sample };
                    if (has_pred) return .{ .miss = .after_end };
                    return .{ .miss = .before_start };
                },
            }
        }

        /// Insert under the last_insertion policy (auto-assigned sequence).
        pub fn insert(self: *Self, t: Instant, handle: SeriesHandle) InsertError!void {
            if (self.supersession != .last_insertion) return error.PolicyMismatch;
            const seq = self.seq_counter;
            self.seq_counter += 1;
            return self.insertWithSeq(t, handle, seq);
        }

        /// Insert under the sequenced policy; `seq` orders supersession.
        pub fn insertSeq(self: *Self, t: Instant, handle: SeriesHandle, seq: u64) InsertError!void {
            if (self.supersession != .sequenced) return error.PolicyMismatch;
            return self.insertWithSeq(t, handle, seq);
        }

        fn insertWithSeq(self: *Self, t: Instant, handle: SeriesHandle, seq: u64) InsertError!void {
            // Windowed retention: refuse an instant already below the horizon.
            if (self.retention == .windowed and self.count > 0) {
                const latest = self.buf[self.count - 1].instant;
                if (belowHorizon(t, latest, self.window_span_ns)) return error.BelowHorizon;
            }

            const pos = self.lowerBound(t);
            if (pos < self.count and self.buf[pos].instant == t) {
                // Repeated instant: supersede iff strictly greater sequence;
                // equal or lesser is dropped, leaving the incumbent.
                if (seq > self.buf[pos].seq) {
                    self.buf[pos] = .{ .instant = t, .handle = handle, .seq = seq };
                }
                return;
            }

            // New instant: insert in order, non-evicting (refuse when full).
            if (self.count >= capacity) return error.Full;
            var i = self.count;
            while (i > pos) : (i -= 1) self.buf[i] = self.buf[i - 1];
            self.buf[pos] = .{ .instant = t, .handle = handle, .seq = seq };
            self.count += 1;

            // A new latest may advance the horizon; drop the now-stale low end.
            if (self.retention == .windowed) self.evictBelowHorizon();
        }

        /// First index whose instant >= t; `count` if none. Binary search.
        fn lowerBound(self: *const Self, t: Instant) usize {
            var lo: usize = 0;
            var hi: usize = self.count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (self.buf[mid].instant < t) lo = mid + 1 else hi = mid;
            }
            return lo;
        }

        fn evictBelowHorizon(self: *Self) void {
            if (self.count == 0) return;
            const latest = self.buf[self.count - 1].instant;
            var drop: usize = 0;
            while (drop < self.count and belowHorizon(self.buf[drop].instant, latest, self.window_span_ns)) : (drop += 1) {}
            if (drop == 0) return;
            var i: usize = 0;
            while (i + drop < self.count) : (i += 1) self.buf[i] = self.buf[i + drop];
            self.count -= drop;
        }
    };
}

/// True iff `t` is strictly below the horizon `latest - span`, computed in
/// i128 to avoid overflow. The horizon is on the bound axis only (ADR 0003).
fn belowHorizon(t: Instant, latest: Instant, span: Instant) bool {
    if (t > latest) return false;
    const diff = @as(i128, latest) - @as(i128, t);
    return diff > @as(i128, span);
}

/// Signed staleness `t - inst` in nanoseconds, saturating at the i64 bounds
/// so an extreme in-range pair cannot overflow (ADR 0005). In practice the
/// resolved sample is near the cursor and the value is exact.
fn staleness(t: Instant, inst: Instant) i64 {
    const diff = @as(i128, t) - @as(i128, inst);
    if (diff > std.math.maxInt(i64)) return std.math.maxInt(i64);
    if (diff < std.math.minInt(i64)) return std.math.minInt(i64);
    return @intCast(diff);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "TimeIndex sorted insertion, out of order" {
    var idx = TimeIndex(16).init(.{});
    try idx.insert(30, 300);
    try idx.insert(10, 100);
    try idx.insert(40, 400);
    try idx.insert(20, 200);

    try testing.expectEqual(@as(usize, 4), idx.len());
    const expect = [_]Instant{ 10, 20, 30, 40 };
    for (expect, 0..) |t, i| {
        try testing.expectEqual(t, idx.pointAt(i).instant);
    }
    try testing.expectEqual(@as(Instant, 10), idx.first().?);
    try testing.expectEqual(@as(Instant, 40), idx.last().?);
    try testing.expectEqual(@as(SeriesHandle, 200), idx.lookupExact(20).?);
    try testing.expect(idx.lookupExact(25) == null);
}

test "TimeIndex last_insertion supersedes a repeated instant" {
    var idx = TimeIndex(8).init(.{ .supersession = .last_insertion });
    try idx.insert(10, 111);
    try idx.insert(20, 222);
    try idx.insert(10, 999); // repeat 10: last wins
    try testing.expectEqual(@as(usize, 2), idx.len());
    try testing.expectEqual(@as(SeriesHandle, 999), idx.lookupExact(10).?);
    try testing.expectEqual(@as(Instant, 10), idx.pointAt(0).instant);
    try testing.expectEqual(@as(Instant, 20), idx.pointAt(1).instant);
}

test "TimeIndex sequenced supersession: strictly-greater wins, else dropped" {
    var idx = TimeIndex(8).init(.{ .supersession = .sequenced });
    try idx.insertSeq(10, 100, 5);
    try idx.insertSeq(10, 200, 7); // 7 > 5: supersedes
    try testing.expectEqual(@as(SeriesHandle, 200), idx.lookupExact(10).?);
    try idx.insertSeq(10, 300, 3); // 3 < 7: dropped (reorder-safe)
    try testing.expectEqual(@as(SeriesHandle, 200), idx.lookupExact(10).?);
    try idx.insertSeq(10, 400, 7); // 7 == 7: dropped (idempotent)
    try testing.expectEqual(@as(SeriesHandle, 200), idx.lookupExact(10).?);
    try testing.expectEqual(@as(usize, 1), idx.len());
}

test "TimeIndex insert method must match policy" {
    var li = TimeIndex(4).init(.{ .supersession = .last_insertion });
    try testing.expectError(error.PolicyMismatch, li.insertSeq(10, 1, 1));
    var sq = TimeIndex(4).init(.{ .supersession = .sequenced });
    try testing.expectError(error.PolicyMismatch, sq.insert(10, 1));
}

test "TimeIndex static retention keeps all, Full on overflow" {
    var idx = TimeIndex(4).init(.{ .retention = .static });
    try idx.insert(10, 1);
    try idx.insert(20, 2);
    try idx.insert(30, 3);
    try idx.insert(40, 4);
    try testing.expectError(error.Full, idx.insert(50, 5));
    try testing.expectEqual(@as(usize, 4), idx.len());
    // A repeat at a full index still supersedes without growth.
    try idx.insert(40, 99);
    try testing.expectEqual(@as(SeriesHandle, 99), idx.lookupExact(40).?);
}

test "TimeIndex windowed retention drops below horizon and rejects stale insert" {
    var idx = TimeIndex(16).init(.{ .retention = .windowed, .window_span_ns = 100 });
    try idx.insert(100, 1);
    try idx.insert(200, 2); // latest 200, horizon 100; 100 retained (not strictly below)
    try testing.expectEqual(@as(usize, 2), idx.len());
    try idx.insert(250, 3); // latest 250, horizon 150; 100 now below -> dropped
    try testing.expectEqual(@as(usize, 2), idx.len());
    try testing.expectEqual(@as(Instant, 200), idx.first().?);
    // A stale insert below the current horizon (150) is rejected.
    try testing.expectError(error.BelowHorizon, idx.insert(140, 9));
    try testing.expectEqual(@as(usize, 2), idx.len());
    // An in-window, out-of-order insert is accepted and ordered.
    try idx.insert(220, 4);
    try testing.expectEqual(@as(usize, 3), idx.len());
    const order = [_]Instant{ 200, 220, 250 };
    for (order, 0..) |t, i| try testing.expectEqual(t, idx.pointAt(i).instant);
}

// ---------------------------------------------------------------------------
// Stage 2: resolution (ADR 0005)
// ---------------------------------------------------------------------------

fn buildTriple() TimeIndex(16) {
    var idx = TimeIndex(16).init(.{});
    idx.insert(10, 1) catch unreachable;
    idx.insert(20, 2) catch unreachable;
    idx.insert(30, 3) catch unreachable;
    return idx;
}

fn expectValue(s: Sample, handle: SeriesHandle, stale: i64) !void {
    switch (s) {
        .value => |v| {
            try testing.expectEqual(handle, v.handle);
            try testing.expectEqual(stale, v.staleness_ns);
        },
        else => return error.NotAValue,
    }
}

fn expectMiss(s: Sample, reason: MissReason) !void {
    switch (s) {
        .miss => |r| try testing.expectEqual(reason, r),
        else => return error.NotAMiss,
    }
}

fn expectLerp(s: Sample, lo: SeriesHandle, hi: SeriesHandle, frac: f32) !void {
    switch (s) {
        .lerp => |l| {
            try testing.expectEqual(lo, l.lo);
            try testing.expectEqual(hi, l.hi);
            try testing.expectApproxEqAbs(frac, l.frac, 1e-6);
        },
        else => return error.NotALerp,
    }
}

test "resolve hold_last: predecessor, holds past end, low-end miss" {
    var idx = buildTriple();
    try expectValue(idx.resolve(20, .hold_last), 2, 0); // exact
    try expectValue(idx.resolve(25, .hold_last), 2, 5); // predecessor + staleness
    try expectValue(idx.resolve(40, .hold_last), 3, 10); // holds past last, never after_end
    try expectMiss(idx.resolve(5, .hold_last), .before_start);
}

test "resolve nearest: clamps both ends, signed staleness, earlier-wins tie" {
    var idx = buildTriple();
    try expectValue(idx.resolve(22, .nearest), 2, 2); // nearer predecessor
    try expectValue(idx.resolve(28, .nearest), 3, -2); // nearer successor, negative staleness
    try expectValue(idx.resolve(25, .nearest), 2, 5); // tie -> earlier
    try expectValue(idx.resolve(40, .nearest), 3, 10); // clamp high
    try expectValue(idx.resolve(5, .nearest), 1, -5); // clamp low, negative staleness
}

test "resolve linear: bracket + fraction, no extrapolation" {
    var idx = buildTriple();
    try expectValue(idx.resolve(20, .linear), 2, 0); // exact hit
    try expectLerp(idx.resolve(25, .linear), 2, 3, 0.5);
    try expectLerp(idx.resolve(22, .linear), 2, 3, 0.2);
    try expectMiss(idx.resolve(40, .linear), .after_end); // does not extrapolate
    try expectMiss(idx.resolve(5, .linear), .before_start);
}

test "resolve none: exact hit only, interior is no_sample" {
    var idx = buildTriple();
    try expectValue(idx.resolve(20, .none), 2, 0);
    try expectMiss(idx.resolve(25, .none), .no_sample); // in range, no exact sample
    try expectMiss(idx.resolve(40, .none), .after_end);
    try expectMiss(idx.resolve(5, .none), .before_start);
}

test "resolve cross-cutting: empty index, below_horizon precedence" {
    var empty = TimeIndex(8).init(.{});
    try expectMiss(empty.resolve(100, .hold_last), .before_start);
    try expectMiss(empty.resolve(100, .nearest), .before_start);

    // Windowed [200, 250], span 100, horizon 150.
    var w = TimeIndex(16).init(.{ .retention = .windowed, .window_span_ns = 100 });
    try w.insert(200, 1);
    try w.insert(250, 2);
    // below_horizon takes precedence over what would otherwise be a clamp/hold.
    try expectMiss(w.resolve(140, .nearest), .below_horizon);
    try expectMiss(w.resolve(140, .hold_last), .below_horizon);
    // In-window but before the first sample is before_start, not below_horizon.
    try expectMiss(w.resolve(160, .hold_last), .before_start);
    // A normal in-window hold still works.
    try expectValue(w.resolve(210, .hold_last), 1, 10);
}
