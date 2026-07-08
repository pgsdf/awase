// metadata.zig: L3a.2 increment 3. Build the MODINFO preload chain
// in dest-space per KERNEL-HANDOFF.md contract 2. The kernel locates
// everything through one physical pointer, modulep, and reads the
// chain with the sys/sys/linker.h preload conventions. Constants are
// the ones the L3a.1 verification pass confirmed against the bench
// sys/sys/linker.h and sys/x86/include/metadata.h.
//
// Scope of increment 3: the kernel file entry (NAME, TYPE, ADDR,
// SIZE) and the metadata records that do not depend on exiting boot
// services (HOWTO, ENVP, KERNEND, MODULEP), then MODINFO_END. The
// EFI_MAP and EFI_FB records are bound to the ExitBootServices
// sequence and belong to increment 4; building them here would force
// a premature exit. KERNEND is made self-consistent by a two-pass
// build: size the chain, place it, then write the page-rounded end
// that includes the chain itself back into its own record.

const std = @import("std");

// MODINFO record types (contract 2, VERIFIED constants).
const MODINFO_END: u32 = 0x0000;
const MODINFO_NAME: u32 = 0x0001;
const MODINFO_TYPE: u32 = 0x0002;
const MODINFO_ADDR: u32 = 0x0003;
const MODINFO_SIZE: u32 = 0x0004;
const MODINFO_METADATA: u32 = 0x8000;

const MODINFOMD_ENVP: u32 = 0x0006;
const MODINFOMD_HOWTO: u32 = 0x0007;
const MODINFOMD_KERNEND: u32 = 0x0008;
const MODINFOMD_MODULEP: u32 = 0x1006;

const kernel_type = "elf kernel";

/// A cursor writing MODINFO records into a dest-space buffer. All
/// offsets are dest-space (contract 0): the buffer's byte i
/// represents dest address base_dest + i. The caller translates to
/// staging for the actual writes.
pub const ChainWriter = struct {
    buf: []u8,
    len: usize = 0,
    base_dest: u64,

    pub fn init(buf: []u8, base_dest: u64) ChainWriter {
        return .{ .buf = buf, .base_dest = base_dest };
    }

    fn rounded(n: usize) usize {
        return (n + 7) & ~@as(usize, 7);
    }

    /// The dest address of the next record's start.
    pub fn cursorDest(self: *const ChainWriter) u64 {
        return self.base_dest + self.len;
    }

    fn record(self: *ChainWriter, mtype: u32, payload: []const u8) !void {
        const need = 8 + rounded(payload.len);
        if (self.len + need > self.buf.len) return error.ChainOverflow;
        std.mem.writeInt(u32, self.buf[self.len..][0..4], mtype, .little);
        std.mem.writeInt(u32, self.buf[self.len + 4 ..][0..4], @intCast(payload.len), .little);
        @memcpy(self.buf[self.len + 8 ..][0..payload.len], payload);
        // Zero the round-up padding.
        var pad = self.len + 8 + payload.len;
        while (pad < self.len + need) : (pad += 1) self.buf[pad] = 0;
        self.len += need;
    }

    fn recordU64(self: *ChainWriter, mtype: u32, v: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try self.record(mtype, &b);
    }

    fn recordU32(self: *ChainWriter, mtype: u32, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.record(mtype, &b);
    }

    /// Record the offset where a u64 payload sits, so a second pass
    /// can patch it (used for KERNEND). Returns the byte offset of
    /// the payload within buf.
    fn recordU64Patchable(self: *ChainWriter, mtype: u32, v: u64) !usize {
        try self.recordU64(mtype, v);
        return self.len - 8;
    }
};

pub const KernelEntry = struct {
    name: []const u8, // e.g. "kernel"
    addr: u64, // dest-space load base of the kernel image
    size: u64, // loaded image size
    howto: u32,
};

pub const ChainResult = struct {
    /// Dest address of the chain start; this is modulep.
    modulep: u64,
    /// Page-rounded dest end past the chain; this is kernend.
    kernend: u64,
    /// Total bytes written.
    len: usize,
};

/// Build the increment 3 chain into buf, whose byte 0 maps to
/// chain_base_dest. envp_dest is the dest address of the environment
/// block (already placed by the caller). Returns modulep and the
/// self-consistent kernend.
pub fn buildChain(
    buf: []u8,
    chain_base_dest: u64,
    kernel: KernelEntry,
    envp_dest: u64,
) !ChainResult {
    var w = ChainWriter.init(buf, chain_base_dest);

    // Kernel file entry: NAME first (contract 2.1), then TYPE, ADDR,
    // SIZE, then the MODINFOMD records.
    try w.record(MODINFO_NAME, kernel.name);
    try w.record(MODINFO_TYPE, kernel_type);
    try w.recordU64(MODINFO_ADDR, kernel.addr);
    try w.recordU64(MODINFO_SIZE, kernel.size);
    try w.recordU32(MODINFO_METADATA | MODINFOMD_HOWTO, kernel.howto);
    try w.recordU64(MODINFO_METADATA | MODINFOMD_ENVP, envp_dest);
    // KERNEND: placeholder now, patched after the chain length and
    // thus the true end are known (two-pass self-consistency).
    const kernend_off = try w.recordU64Patchable(MODINFO_METADATA | MODINFOMD_KERNEND, 0);
    // MODULEP self-reference: the chain's own dest base.
    try w.recordU64(MODINFO_METADATA | MODINFOMD_MODULEP, chain_base_dest);
    // End of chain.
    try w.record(MODINFO_END, &.{});

    // Now the chain occupies [chain_base_dest, chain_base_dest+len).
    // kernend is the page-rounded end past it (contract 2.2/2.4).
    const raw_end = chain_base_dest + w.len;
    const kernend = std.mem.alignForward(u64, raw_end, 4096);
    std.mem.writeInt(u64, buf[kernend_off..][0..8], kernend, .little);

    return .{ .modulep = chain_base_dest, .kernend = kernend, .len = w.len };
}

test "chain layout and kernend self-consistency" {
    var buf: [512]u8 = undefined;
    const base: u64 = 0x1c00000;
    const envp: u64 = 0x1bf0000;
    const r = try buildChain(&buf, base, .{
        .name = "kernel",
        .addr = 0x200000,
        .size = 0x1a00000,
        .howto = 0,
    }, envp);
    try std.testing.expect(r.modulep == base);
    // kernend is page-rounded and past the chain.
    try std.testing.expect(r.kernend >= base + r.len);
    try std.testing.expect(r.kernend % 4096 == 0);
    // First record is NAME (contract 2.1: must come first).
    try std.testing.expect(std.mem.readInt(u32, buf[0..4], .little) == MODINFO_NAME);
    // The KERNEND payload in the buffer equals r.kernend (patched).
    var found: u64 = 0;
    var off: usize = 0;
    while (off + 8 <= r.len) {
        const t = std.mem.readInt(u32, buf[off..][0..4], .little);
        const l = std.mem.readInt(u32, buf[off + 4 ..][0..4], .little);
        if (t == (MODINFO_METADATA | MODINFOMD_KERNEND))
            found = std.mem.readInt(u64, buf[off + 8 ..][0..8], .little);
        off += 8 + ((l + 7) & ~@as(usize, 7));
    }
    try std.testing.expect(found == r.kernend);
}
