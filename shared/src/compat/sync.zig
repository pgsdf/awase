//! compat.sync: Awase-owned in-process synchronization primitives.
//!
//! Part of the compatibility boundary (ADR shared 0001) and the concurrency
//! and timing boundary specifically (ADR shared 0002). The 0.16 cycle removed
//! std.Thread.Mutex and routed mutual exclusion through std.Io.Mutex, whose
//! lock and unlock take an Io handle. A mutex is not I/O, and Awase does not
//! accept std.Io as the ownership model for synchronization: callers depend on
//! this interface, which takes no Io handle, so an Io context does not become a
//! transitive dependency of every locked data structure.
//!
//! This defines the boundary interface. The backing implementation may evolve.
//! Today it is an atomic spin lock, which suits the short critical sections the
//! tree actually guards (ring buffers, the clock reader). It does not yield to
//! a scheduler under contention; a site that needs that should use std.Io.Mutex
//! directly with a recorded justification (ADR shared 0002, Consequences).

const std = @import("std");

/// Lock state. Only unlocked and locked are tracked; the short critical
/// sections this guards do not benefit from separate contended bookkeeping.
const State = enum(u8) { unlocked, locked };

/// A small mutual-exclusion lock, independent of std.Io. The default value is
/// unlocked, so a field of this type may be initialized as `.{}`.
pub const Mutex = struct {
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.unlocked),

    /// Acquire the lock, spinning until it is available.
    pub fn lock(self: *Mutex) void {
        while (!self.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    /// Try to acquire the lock without blocking. Returns true on success.
    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgStrong(.unlocked, .locked, .acquire, .monotonic) == null;
    }

    /// Release the lock. The caller must hold it.
    pub fn unlock(self: *Mutex) void {
        self.state.store(.unlocked, .release);
    }
};

test "Mutex guards a critical section" {
    var m: Mutex = .{};
    try std.testing.expect(m.tryLock());
    try std.testing.expect(!m.tryLock());
    m.unlock();
    m.lock();
    try std.testing.expect(!m.tryLock());
    m.unlock();
    try std.testing.expect(m.tryLock());
    m.unlock();
}
