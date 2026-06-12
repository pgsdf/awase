// F.5.a wire protocol and canonical format (ADR 0021).
//
// A client connects to the Unix stream socket, sends a Hello header, and
// receives a one-byte status. On acceptance it streams raw interleaved PCM
// in the canonical format until it closes. The header is versioned so later
// sub-milestones (F.5.b format adaptation, F.5.c targets) extend it by
// bumping HELLO_VERSION rather than reshaping the layout.

const std = @import("std");

pub const SOCKET_PATH = "/var/run/sema/audio.sock";
pub const DEVICE_PATH = "/dev/audiofs0";
pub const NOTIFY_PATH = "/dev/audiofs_notify";
pub const EVENTS_PATH = "/var/run/sema/audio/events";
pub const CLOCK_PATH = "/var/run/sema/clock";

// Canonical format for F.5.a: 48 kHz, 16-bit LE, stereo. Clients must
// present exactly this; arbitrary-rate clients are F.5.b.
pub const CANON_RATE: u32 = 48000;
pub const CANON_CHANNELS: u16 = 2;
pub const CANON_FORMAT: u16 = 1; // 16-bit LE PCM
pub const BYTES_PER_FRAME: usize = 4; // 16-bit * 2 channels

pub const HELLO_MAGIC: u32 = 0x534D4131; // 'SMA1'
pub const HELLO_VERSION: u16 = 3; // F.5.d: v3 adds label/class; v1/v2 rejected (ADR 0026 D1)

pub const Hello = extern struct {
    magic: u32,
    version: u16,
    format: u16,
    rate_hz: u32,
    channels: u16,
    _pad: u16,
    // F.5.c (ADR 0025): NUL-padded target name. Empty routes to "default".
    target: [16]u8,
    // F.5.d (ADR 0026): NUL-padded policy identity. label is an instance
    // name (empty -> "anon"); class is a category token such as music or
    // alert (empty -> "none"). Declaration-based, as in semaaud parity;
    // credential binding is recorded future hardening.
    label: [16]u8,
    class: [16]u8,
};

pub const STATUS_ACCEPTED: u8 = 0;
pub const STATUS_REJECTED: u8 = 1;
// F.5.d (ADR 0026 Decision 6): broker-initiated, protocol-visible disconnect
// for group-exclusivity preemption ONLY; never emitted for ducking.
pub const STATUS_PREEMPTED: u8 = 2;

pub fn helloIsCanonical(h: Hello) bool {
    return h.magic == HELLO_MAGIC and
        h.version == HELLO_VERSION and
        h.format == CANON_FORMAT and
        h.rate_hz == CANON_RATE and
        h.channels == CANON_CHANNELS;
}

// F.5.b Stage 1 (ADR 0024 Decision 3): accept 16-bit PCM, mono or stereo, at
// any supported rate. 24-bit/float/multichannel are rejected (deferred). The
// supported input rate set is bounded and sane; arbitrary rates outside it
// are refused rather than trusted. Hardware election is fixed at 48k in Stage
// 1, so any non-48k (or mono) client gets a resampler; 48k stereo is the
// bit-exact passthrough.
pub fn helloIsAcceptable(h: Hello) bool {
    if (h.magic != HELLO_MAGIC or h.version != HELLO_VERSION) return false;
    if (h.format != CANON_FORMAT) return false; // 16-bit LE only
    if (h.channels != 1 and h.channels != 2) return false; // mono or stereo
    return rateSupported(h.rate_hz);
}

pub fn rateSupported(rate: u32) bool {
    return switch (rate) {
        8000, 11025, 16000, 22050, 32000, 44100, 48000 => true,
        else => false,
    };
}

test "Hello header is 64 bytes (v3)" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Hello));
}

/// The Hello's target name with NUL padding trimmed; empty means "default"
/// (ADR 0025 Decision 3). The returned slice aliases the Hello.
pub fn targetName(h: *const Hello) []const u8 {
    var end: usize = h.target.len;
    while (end > 0 and h.target[end - 1] == 0) end -= 1;
    if (end == 0) return "default";
    return h.target[0..end];
}

test "targetName: empty routes to default, names trim NUL padding" {
    var h = std.mem.zeroes(Hello);
    try std.testing.expectEqualStrings("default", targetName(&h));
    @memcpy(h.target[0..4], "null");
    try std.testing.expectEqualStrings("null", targetName(&h));
}

fn trimmed(buf: []const u8, default_v: []const u8) []const u8 {
    var end: usize = buf.len;
    while (end > 0 and buf[end - 1] == 0) end -= 1;
    if (end == 0) return default_v;
    return buf[0..end];
}

/// The Hello's policy identity (ADR 0026 Decision 1). Slices alias the Hello.
pub fn labelOf(h: *const Hello) []const u8 {
    return trimmed(&h.label, "anon");
}
pub fn classOf(h: *const Hello) []const u8 {
    return trimmed(&h.class, "none");
}

test "labelOf/classOf default to anon/none and trim padding" {
    var h = std.mem.zeroes(Hello);
    try std.testing.expectEqualStrings("anon", labelOf(&h));
    try std.testing.expectEqualStrings("none", classOf(&h));
    @memcpy(h.label[0..5], "vlc-1");
    @memcpy(h.class[0..5], "music");
    try std.testing.expectEqualStrings("vlc-1", labelOf(&h));
    try std.testing.expectEqualStrings("music", classOf(&h));
}

test "canonical hello accepted, others rejected" {
    const ok = Hello{
        .magic = HELLO_MAGIC,
        .version = HELLO_VERSION,
        .format = CANON_FORMAT,
        .rate_hz = CANON_RATE,
        .channels = CANON_CHANNELS,
        ._pad = 0,
        .target = [_]u8{0} ** 16,
        .label = [_]u8{0} ** 16,
        .class = [_]u8{0} ** 16,
    };
    try std.testing.expect(helloIsCanonical(ok));

    var bad = ok;
    bad.rate_hz = 44100;
    try std.testing.expect(!helloIsCanonical(bad));
}
