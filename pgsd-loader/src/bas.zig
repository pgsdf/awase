// bas.zig: the TxFAT32 selector record, single source of truth for
// both the host publication tool (bas_selector_tool.zig) and the
// loader read path (L3a.2). BOOT-ARTIFACT-STORE 0.3 section 7.1;
// invariants I1 through I5 are the correctness frame.

const std = @import("std");

pub const record_size: usize = 512;
pub const selector_size: usize = 2 * record_size;
pub const magic = "PGBA";
pub const format_version: u32 = 1;

pub const Record = struct {
    generation: u64,
    active_slot: u32,
    manifest_sha256: [32]u8,

    /// Serialize to a 512-byte record with CRC32 (section 7.1
    /// layout: magic 0..4, version 4..8, generation 8..16,
    /// slot 16..20, manifest hash 20..52, reserved zero, CRC32 of
    /// bytes 0..508 at 508..512).
    pub fn encode(self: Record) [record_size]u8 {
        var buf = [_]u8{0} ** record_size;
        @memcpy(buf[0..4], magic);
        std.mem.writeInt(u32, buf[4..8], format_version, .little);
        std.mem.writeInt(u64, buf[8..16], self.generation, .little);
        std.mem.writeInt(u32, buf[16..20], self.active_slot, .little);
        @memcpy(buf[20..52], &self.manifest_sha256);
        const crc = std.hash.Crc32.hash(buf[0..508]);
        std.mem.writeInt(u32, buf[508..512], crc, .little);
        return buf;
    }

    /// Decode and validate one record. null means invalid (wrong
    /// magic, unsupported version, or CRC failure); a null record
    /// is never interpreted further (invariant I3).
    pub fn decode(buf: *const [record_size]u8) ?Record {
        if (!std.mem.eql(u8, buf[0..4], magic)) return null;
        if (std.mem.readInt(u32, buf[4..8], .little) != format_version) return null;
        const stored = std.mem.readInt(u32, buf[508..512], .little);
        if (std.hash.Crc32.hash(buf[0..508]) != stored) return null;
        var r = Record{
            .generation = std.mem.readInt(u64, buf[8..16], .little),
            .active_slot = std.mem.readInt(u32, buf[16..20], .little),
            .manifest_sha256 = undefined,
        };
        @memcpy(&r.manifest_sha256, buf[20..52]);
        return r;
    }
};

pub const ReadResult = struct {
    /// The reachable-designating record, section 7.2 read rule:
    /// highest valid generation. null means destroyed selector.
    winner: ?Record,
    /// Index (0 or 1) of the record a commit must overwrite: the
    /// invalid one, or the lower generation (section 7.3, always
    /// overwrite the loser). Meaningful even when winner is null.
    loser_index: u1,
};

/// Apply the read rule to the two records of a selector image.
pub fn read(image: *const [selector_size]u8) ReadResult {
    const a = Record.decode(image[0..record_size]);
    const b = Record.decode(image[record_size..selector_size]);
    if (a == null and b == null) return .{ .winner = null, .loser_index = 0 };
    if (a == null) return .{ .winner = b, .loser_index = 0 };
    if (b == null) return .{ .winner = a, .loser_index = 1 };
    if (a.?.generation >= b.?.generation)
        return .{ .winner = a, .loser_index = 1 };
    return .{ .winner = b, .loser_index = 0 };
}

test "roundtrip and read rule" {
    var img = [_]u8{0} ** selector_size;
    // Zeroed selector: destroyed, loser 0.
    var rr = read(&img);
    try std.testing.expect(rr.winner == null);
    // Commit gen 1 slot 3 into loser.
    var h = [_]u8{0xab} ** 32;
    const r1 = Record{ .generation = 1, .active_slot = 3, .manifest_sha256 = h };
    const e1 = r1.encode();
    @memcpy(img[0..record_size], &e1);
    rr = read(&img);
    try std.testing.expect(rr.winner.?.generation == 1);
    try std.testing.expect(rr.winner.?.active_slot == 3);
    try std.testing.expect(rr.loser_index == 1);
    // Commit gen 2 slot 5 into the loser; winner flips.
    h[0] = 0xcd;
    const e2 = (Record{ .generation = 2, .active_slot = 5, .manifest_sha256 = h }).encode();
    @memcpy(img[record_size..selector_size], &e2);
    rr = read(&img);
    try std.testing.expect(rr.winner.?.generation == 2);
    try std.testing.expect(rr.winner.?.active_slot == 5);
    try std.testing.expect(rr.loser_index == 0);
    // Corrupt the winner: survivor rule (monotonic reachability, I2).
    img[record_size + 100] ^= 0xff;
    rr = read(&img);
    try std.testing.expect(rr.winner.?.generation == 1);
    try std.testing.expect(rr.winner.?.active_slot == 3);
}
