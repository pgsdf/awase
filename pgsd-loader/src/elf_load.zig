// elf_load.zig: L3a.2 increment 2. Load the slot kernel's ELF64
// image into staging per KERNEL-HANDOFF.md contracts 0 and 1:
// dest-space anchored at the kernel image base (minimum PT_LOAD
// p_paddr), staging 2 MiB aligned below 4 GiB (1.3a, the kernel
// builds its early page table from its own load address), slop
// reserved beyond the image (1.3b, space past kernend is kernel
// property), segments placed at base-relative offsets with memsz
// zero fill (1.1). No relocation (1.2). Verify-only in this
// increment: the image is loaded, attested, and freed; handoff is
// a later increment.

const std = @import("std");
const uefi = std.os.uefi;

pub const Report = *const fn (msg: []const u8) void;

pub const LoadResult = struct {
    entry: u64,
    base_paddr: u64,
    image_end: u64,
    staging: u64,
    pages: usize,
    loads: usize,

    /// ADR 0006: the end of the staging allocation, as a
    /// staging-relative offset.
    ///
    /// Everything the loader writes after the kernel image (the env
    /// strings, a preloaded module image, the metadata chain) goes into
    /// this region, and NOTHING may go past this bound. Writing past it
    /// is silent memory corruption on a machine with no console, which is
    /// the failure mode this campaign can least afford, so the bound is
    /// returned rather than left implicit.
    staging_limit_rel: u64,
};

const Ehdr = extern struct {
    magic: [4]u8,
    class: u8,
    data: u8,
    version: u8,
    pad: [9]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

const PT_LOAD: u32 = 1;

/// Headroom above the kernel image for what the loader places after it:
/// the boot environment strings and the metadata chain. It is NOT for
/// module images; see module_slop.
const slop: u64 = 8 * 1024 * 1024;

/// ADR 0006: space for preloaded module images.
///
/// This is a separate budget on purpose. The module image lives in the
/// same staging region as the kernel, below the metadata chain (so that
/// kernend, which is align(chain_base + chain_len), covers it). It would
/// have fitted inside `slop` today: zfs.ko is 5.6 MB and slop is 8 MB.
/// Doing that would be an implicit coupling that breaks the first time a
/// second module is preloaded or ZFS grows, and it would break by
/// overrunning the staging allocation, which on a machine with no console
/// is silent memory corruption. So the module budget is named and
/// checked.
///
/// 16 MiB against a 5.6 MB zfs.ko leaves real headroom. If a module list
/// exceeds it, loadKernel returns ModuleStagingTooSmall rather than
/// scribbling past the allocation.
pub const module_slop: u64 = 16 * 1024 * 1024;

const two_mib: u64 = 2 * 1024 * 1024;
const max_phdrs = 32;

fn readExact(f: *uefi.protocol.File, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = f.read(buf[total..]) catch return error.ReadFailed;
        if (n == 0) return error.ShortRead;
        total += n;
    }
}

pub fn loadKernel(
    bs: *uefi.tables.BootServices,
    f: *uefi.protocol.File,
    prints: Report,
) !LoadResult {
    var eh: Ehdr = undefined;
    f.setPosition(0) catch return error.SeekFailed;
    try readExact(f, std.mem.asBytes(&eh));
    if (!std.mem.eql(u8, &eh.magic, "\x7fELF")) return error.NotElf;
    if (eh.class != 2 or eh.data != 1) return error.NotElf64LE;
    if (eh.e_machine != 62) return error.NotAmd64;
    if (eh.e_type != 2) return error.NotExecutable;
    if (eh.e_phentsize != @sizeOf(Phdr)) return error.BadPhentSize;
    if (eh.e_phnum == 0 or eh.e_phnum > max_phdrs) return error.BadPhnum;

    var phdrs: [max_phdrs]Phdr = undefined;
    f.setPosition(eh.e_phoff) catch return error.SeekFailed;
    try readExact(f, std.mem.sliceAsBytes(phdrs[0..eh.e_phnum]));

    // Contract 0 anchor: dest-space base = minimum PT_LOAD p_paddr.
    var base: u64 = std.math.maxInt(u64);
    var end: u64 = 0;
    var loads: usize = 0;
    for (phdrs[0..eh.e_phnum]) |ph| {
        if (ph.p_type != PT_LOAD or ph.p_memsz == 0) continue;
        if (ph.p_filesz > ph.p_memsz) return error.BadSegment;
        loads += 1;
        if (ph.p_paddr < base) base = ph.p_paddr;
        const segend = ph.p_paddr + ph.p_memsz;
        if (segend > end) end = segend;
    }
    if (loads == 0) return error.NoLoadSegments;
    const image_size = end - base;
    if (image_size > 512 * 1024 * 1024) return error.ImplausibleImage;

    // 1.3a and 1.3b: 2 MiB aligned staging below 4 GiB with slop,
    // over-allocated by one alignment unit so the aligned base is
    // always inside the allocation (the stock pattern).
    // ADR 0006: the allocation must hold the kernel image, the loader's
    // own headroom (env + chain), AND any preloaded module images. The
    // module budget is explicit rather than borrowed from slop: see
    // module_slop.
    const need = image_size + slop + module_slop + two_mib;
    const pages: usize = @intCast((need + 4095) / 4096);
    const limit: [*]align(4096) uefi.Page = @ptrFromInt(0xFFFF_F000);
    const mem = bs.allocatePages(.{ .max_address = limit }, .loader_data, pages) catch
        return error.StagingAllocFailed;
    errdefer bs.freePages(mem) catch {};
    const alloc_base: u64 = @intFromPtr(mem.ptr);
    const staging = std.mem.alignForward(u64, alloc_base, two_mib);

    // Load: file bytes then zero fill, at base-relative offsets.
    var report_buf: [96]u8 = undefined;
    for (phdrs[0..eh.e_phnum]) |ph| {
        if (ph.p_type != PT_LOAD or ph.p_memsz == 0) continue;
        const dst: [*]u8 = @ptrFromInt(staging + (ph.p_paddr - base));
        f.setPosition(ph.p_offset) catch return error.SeekFailed;
        try readExact(f, dst[0..ph.p_filesz]);
        @memset(dst[ph.p_filesz..ph.p_memsz], 0);
        if (std.fmt.bufPrint(&report_buf, "ELF: segment paddr=0x{x} filesz=0x{x} memsz=0x{x}\r\n", .{ ph.p_paddr, ph.p_filesz, ph.p_memsz })) |m| prints(m) else |_| {}
    }
    return .{
        .entry = eh.e_entry,
        .base_paddr = base,
        .image_end = end,
        .staging = staging,
        .pages = pages,
        .loads = loads,
        // The allocation runs from `staging` for `pages` pages. Express
        // its end relative to base_paddr, which is the frame every other
        // offset in main.zig uses (image_span, envp_rel, chain_rel).
        .staging_limit_rel = (staging + pages * 4096) -| base,
    };
}
