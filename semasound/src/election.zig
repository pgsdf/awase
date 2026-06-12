// F.5.b Stage 2: hardware-rate election (ADR 0024 Decisions 1 and 2).
//
// Policy (Decision 1): if the session is exactly one client whose rate is a
// hardware rate {32000, 44100, 48000}, elect that rate so the client plays
// bit-exact with no resampling; in all other cases elect 48000 and resample
// every client to it.
//
// Boundary (Decision 2, Stage 2 realization, ratified 2026-06-04): election
// occurs ONLY on the 0-to-1 active-client transition, evaluated in the accept
// path before the new client's reader starts. A client therefore never spans
// an election, so its resampler configuration is immutable for the lifetime
// of the connection and the Stage 1 single-writer ownership holds with no
// rebuild protocol. When the active set drops to zero the hardware is left at
// its current rate (lazy rest state); the next 0-to-1 admission re-elects.
//
// The SET_FORMAT ioctl (ADR 0019) reconfigures the live stream kernel-side
// (validates the rate, flushes the user ring so no old-rate bytes play at the
// wrong pitch, stop/start under the existing lifecycle, clock monotonic), so
// issuing it while the output loop writes silence is safe and inaudible.

const std = @import("std");

// /dev/audiofs0 ioctl surface, mirroring audiofs_ioctl.h (ADR 0019 s.3).
pub const AudiofsFormat = extern struct {
    rate_hz: u32, // 32000 | 44100 | 48000
    format_word: u16, // HDA SDnFMT word (GET only)
    bits: u8, // 16 in v1
    channels: u8, // 2 in v1
    supported_rates: u32, // bitmask, GET only
};

// FreeBSD ioccom.h encoding. IOC_OUT = read (GET), IOC_IN = write (SET).
const IOC_OUT: u64 = 0x4000_0000;
const IOC_IN: u64 = 0x8000_0000;
const IOCPARM_MASK: u64 = 0x1fff;
fn ior(comptime group: u8, comptime num: u8, comptime T: type) u64 {
    return IOC_OUT | ((@sizeOf(T) & IOCPARM_MASK) << 16) |
        (@as(u64, group) << 8) | num;
}
fn iow(comptime group: u8, comptime num: u8, comptime T: type) u64 {
    return IOC_IN | ((@sizeOf(T) & IOCPARM_MASK) << 16) |
        (@as(u64, group) << 8) | num;
}
pub const IOC_GET_FORMAT: u64 = ior('A', 1, AudiofsFormat);
pub const IOC_SET_FORMAT: u64 = iow('A', 2, AudiofsFormat);

// FreeBSD ioctl takes an unsigned long request; declare the libc prototype
// directly rather than relying on std.c's signature.
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

// Per-target election state (F.5.c, ADR 0025 Decision 5: election on any
// target is a function of that target's client set alone). Written only by
// the election path (single accept thread); read by the accept path's
// resampler decision. Seeded from GET_FORMAT at startup because the lazy
// rest state means the device may rest at a non-48k rate from a previous
// broker run.
pub const State = struct {
    elected: std.atomic.Value(u32) = std.atomic.Value(u32).init(48000),

    pub fn rate(self: *const State) u32 {
        return self.elected.load(.acquire);
    }
};

/// Decision 1 policy for a fresh single-client session.
pub fn electFor(rate_hz: u32) u32 {
    return switch (rate_hz) {
        32000, 44100, 48000 => rate_hz,
        else => 48000,
    };
}

/// Seed the elected-rate state from the device's actual current format.
/// Called once at startup after the device is open.
pub fn seedFromDevice(st: *State, fd: std.posix.fd_t) void {
    var f = std.mem.zeroes(AudiofsFormat);
    if (ioctl(fd, @intCast(IOC_GET_FORMAT), &f) == 0 and f.rate_hz != 0) {
        st.elected.store(f.rate_hz, .release);
        std.debug.print("semasound: election: device at {d} Hz at startup\n", .{f.rate_hz});
    } else {
        std.debug.print("semasound: election: GET_FORMAT failed, assuming 48000\n", .{});
    }
}

/// Apply an election: if the rate differs from the current one, issue exactly
/// one SET_FORMAT (ADR 0019 reconfigures the live stream; we are at a session
/// boundary so only silence is in flight). Returns the rate now in effect.
pub fn applyElection(st: *State, fd: std.posix.fd_t, new_rate: u32) u32 {
    const cur = st.elected.load(.acquire);
    if (new_rate == cur) return cur;
    var f = std.mem.zeroes(AudiofsFormat);
    f.rate_hz = new_rate;
    f.bits = 16;
    f.channels = 2;
    if (ioctl(fd, @intCast(IOC_SET_FORMAT), &f) == 0) {
        st.elected.store(new_rate, .release);
        std.debug.print("semasound: election: SET_FORMAT {d} -> {d} Hz\n", .{ cur, new_rate });
        return new_rate;
    }
    std.debug.print("semasound: election: SET_FORMAT to {d} FAILED, staying at {d}\n", .{ new_rate, cur });
    return cur;
}

test "electFor: hardware rates elected natively, others fall back to 48k" {
    try std.testing.expectEqual(@as(u32, 32000), electFor(32000));
    try std.testing.expectEqual(@as(u32, 44100), electFor(44100));
    try std.testing.expectEqual(@as(u32, 48000), electFor(48000));
    try std.testing.expectEqual(@as(u32, 48000), electFor(22050));
    try std.testing.expectEqual(@as(u32, 48000), electFor(8000));
    try std.testing.expectEqual(@as(u32, 48000), electFor(11025));
}

test "ioctl request encodings match audiofs_ioctl.h" {
    // struct audiofs_format is 12 bytes; _IOR('A',1,T)/_IOW('A',2,T).
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(AudiofsFormat));
    try std.testing.expectEqual(@as(u64, 0x400C_4101), IOC_GET_FORMAT);
    try std.testing.expectEqual(@as(u64, 0x800C_4102), IOC_SET_FORMAT);
}
