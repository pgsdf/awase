// device_fd.zig
//
// Single-owner lifecycle for the shared /dev/audiofs0 descriptor.
//
// Why this type exists (AD-50): the device fd was a bare shared atomic
// (std.atomic.Value(fd_t)) whose ownership was enforced by comment, not
// by structure. Three roles touched it: main seeded it at startup, the
// output thread republished it on reconnect, and the accept thread loaded
// its value and issued election ioctls on it. The AD-47 device layer
// could leave the output loop in a state where it had to close and reopen
// the device; combined with audiofs's exclusive open (audiofs_cdev_open
// returns EBUSY while a fd is held), the prior code that did NOT close the
// failed fd on the .real to .null_sink transition deadlocked its own
// reconnect. The obvious fix (close the fd on transition) was unsafe as a
// one-liner because the accept thread could be mid-ioctl on that same fd
// value when the output thread closed and the OS recycled the number: a
// use-after-close into a recycled descriptor.
//
// This type makes the ownership a property of the structure:
//
//   - LIFECYCLE OWNER: exactly one thread (the output loop for the
//     "default" target) calls release() and adopt(). It is the only
//     opener and closer after startup. Its own write hot path reads an
//     owner-local copy of the fd (snapshot()) and never locks.
//
//   - READERS: any other thread (the accept loop) touches the fd ONLY
//     through use(), which holds the lock for the duration of the call.
//     Because close() also takes the lock, a reader's ioctl cannot run
//     while the owner is closing or recycling the fd. The lock makes the
//     fd stable for the call; there is no bare load-then-use across
//     threads anymore.
//
// The mutex is contended only between the rare accept-path election ioctl
// and the rare device reconnect. The per-fragment write path does not
// touch it.
//
// Concurrency contract (the invariants a reviewer should check):
//   1. release() and adopt() are called from the owner thread only.
//   2. The owner reads the fd for its hot path via snapshot(), which is
//      sound because the owner is the sole mutator: it never observes a
//      value it did not itself write.
//   3. Every cross-thread use of the fd goes through use(); there is no
//      other accessor that returns the raw fd to a non-owner.
//   4. ioctl-vs-ioctl concurrency (owner seedFromDevice vs accept
//      applyElection on a freshly adopted, valid fd) is serialized by the
//      kernel cdev, not by this type; this type only prevents
//      use-after-close, which is the race that mattered.

const std = @import("std");
const compat = @import("compat");
const posix = std.posix;

pub const DeviceFd = struct {
    mu: compat.sync.Mutex = .{},
    fd: posix.fd_t = -1,

    pub fn init(fd: posix.fd_t) DeviceFd {
        return .{ .fd = fd };
    }

    /// Owner only. Close the device and mark it absent. Idempotent.
    /// Safe against a concurrent use() on another thread: that call
    /// either completes before this acquires the lock (it ran on the
    /// still-valid fd) or runs after (it sees -1 and is skipped).
    pub fn release(self: *DeviceFd) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.fd >= 0) {
            _ = posix.system.close(self.fd);
            self.fd = -1;
        }
    }

    /// Owner only. Adopt a freshly opened fd. Any prior fd is closed
    /// first as a defensive measure; the normal path release()s before
    /// reopening, so the prior fd is already -1 here.
    pub fn adopt(self: *DeviceFd, nfd: posix.fd_t) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.fd >= 0) _ = posix.system.close(self.fd);
        self.fd = nfd;
    }

    /// Owner-thread hot-path read. No lock: sound only because the owner
    /// is the sole mutator of fd, so it never reads a value it did not
    /// itself write. MUST NOT be called from any other thread; readers
    /// use() instead.
    pub fn snapshot(self: *const DeviceFd) posix.fd_t {
        return self.fd;
    }

    /// Reader (any thread). Run f(fd, args...) under the lock iff a device
    /// is present, returning its result; return null if absent. Holding
    /// the lock for the call makes the fd stable: it cannot be closed and
    /// recycled out from under f. This is the ONLY cross-thread accessor;
    /// there is deliberately no method that hands a non-owner a raw fd to
    /// use after the lock is dropped.
    pub fn use(
        self: *DeviceFd,
        comptime R: type,
        comptime f: anytype,
        args: anytype,
    ) ?R {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.fd < 0) return null;
        return @call(.auto, f, .{self.fd} ++ args);
    }

    /// Test/shutdown helper: present-ness without acquiring for use.
    pub fn isPresent(self: *DeviceFd) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.fd >= 0;
    }
};
