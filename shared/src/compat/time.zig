//! compat.time: Awase-owned timing primitives.
//!
//! Part of the compatibility boundary (ADR shared 0001) and the concurrency
//! and timing boundary specifically (ADR shared 0002). The 0.16 cycle removed
//! std.Thread.sleep and routed sleeping through std.Io.sleep, which takes an Io
//! handle. Sleeping is not I/O, and the boundary does not exist because timing
//! is volatile; it exists because 0.16 relocated sleep behind the same Io
//! dependency Awase isolates. Callers depend on this interface, which takes no
//! Io handle.
//!
//! This defines the boundary interface. The backing implementation may evolve;
//! today it is a posix sleep through the posix surface this tree already owns
//! (AD-6, posix_safe). The Duration type lets the boundary own the unit, so
//! call sites express an amount of time rather than a bare nanosecond count.

const std = @import("std");
const posix = std.posix;
const posix_safe = @import("../posix_safe.zig");

/// A length of time. Stored internally as nanoseconds; construct through the
/// fromX helpers so the unit is explicit at the call site and owned here.
pub const Duration = struct {
    nanoseconds: u64,

    pub fn fromNanoseconds(ns: u64) Duration {
        return .{ .nanoseconds = ns };
    }

    pub fn fromMicroseconds(us: u64) Duration {
        return .{ .nanoseconds = us * std.time.ns_per_us };
    }

    pub fn fromMilliseconds(ms: u64) Duration {
        return .{ .nanoseconds = ms * std.time.ns_per_ms };
    }

    pub fn fromSeconds(s: u64) Duration {
        return .{ .nanoseconds = s * std.time.ns_per_s };
    }
};

/// Block the current thread for `duration`. Independent of std.Io. Resumes
/// across signal interruptions so the full duration elapses.
pub fn sleep(duration: Duration) void {
    posix_safe.safeSleep(duration.nanoseconds);
}

/// A monotonic instant, in nanoseconds since an unspecified epoch.
///
/// Semantics, deliberately narrow to prevent misuse:
///   - Monotonic: the value never moves backward and is unaffected by wall
///     clock adjustments (NTP steps, manual clock changes, leap seconds).
///   - Unspecified epoch: the zero point is arbitrary (typically system boot).
///     Only differences between two values from this function are meaningful.
///   - For elapsed-time measurement only. Subtract an earlier reading from a
///     later one to obtain a nanosecond interval.
///   - NOT a wall clock: it does not represent calendar or Unix time and must
///     not be formatted or displayed as a date or time of day.
///   - NOT portable across processes or boots: it must not be persisted to a
///     file, exchanged over a socket, or compared against a value from another
///     process. Use the shared clock-file format for any cross-process time.
///
/// Independent of std.Io. Backed by clock_gettime(MONOTONIC) over the same
/// posix.system surface this module already owns for sleep (ADR shared 0002).
pub fn nowMonotonic() i128 {
    var ts: posix.timespec = undefined;
    _ = posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}
