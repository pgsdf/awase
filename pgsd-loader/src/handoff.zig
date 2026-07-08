// handoff.zig: L3a.2 increment 4a. Build the remaining handoff state
// per KERNEL-HANDOFF.md contracts 3 and 5, attest it, and stop
// before ExitBootServices. Increment 4b performs the exit and the
// trampoline; splitting here isolates the one unobservable,
// untestable-until-boot step (the transfer across contract 4.2) from
// everything that can be validated while still chainloading.
//
// This increment builds and checks: the EFI memory map capture with
// its retained map key (contract 3.1, 3.2); the EFI_FB framebuffer
// record from GOP (contract 2.2); and the no-copy 9-page page table
// set (contract 5.1) whose upper mapping walks the real staging
// base. All of it is bytes plus computable invariants, so the armed
// path attests it and chainloads normally, exactly like increments
// 1 through 3.

const std = @import("std");
const uefi = std.os.uefi;

const two_mib: u64 = 2 * 1024 * 1024;
const one_gib: u64 = 1024 * 1024 * 1024;

// Page table entry flags.
const PG_V: u64 = 1 << 0;
const PG_RW: u64 = 1 << 1;
const PG_PS: u64 = 1 << 7;

pub const MemMap = struct {
    key: uefi.tables.MemoryMapKey,
    descriptor_size: usize,
    descriptor_version: u32,
    count: usize,
    buffer: []align(8) u8,
};

/// Capture the EFI memory map into a firmware allocation, returning
/// the map and its key. The allocation is made before this final
/// map fetch so it is accounted in the map (contract 3.3); the
/// caller must not allocate again before ExitBootServices, or the
/// key goes stale (contract 3.2).
pub fn captureMemoryMap(bs: *uefi.tables.BootServices) !MemMap {
    const info = try bs.getMemoryMapInfo();
    // Slack: the allocation for the buffer itself splits a region,
    // and firmware may allocate in callbacks (contract 3.2). Size
    // generously; increment 4b re-fetches if the key is stale.
    const slack_desc = 16;
    const bytes = (info.len + slack_desc) * info.descriptor_size;
    const buf = try bs.allocatePool(.loader_data, bytes);
    const aligned: []align(8) u8 = @alignCast(buf);
    const slice = try bs.getMemoryMap(aligned);
    return .{
        .key = slice.info.key,
        .descriptor_size = slice.info.descriptor_size,
        .descriptor_version = slice.info.descriptor_version,
        .count = slice.info.len,
        .buffer = aligned,
    };
}

pub const FbInfo = struct {
    present: bool,
    base: u64 = 0,
    size: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
};

/// Read the active GOP framebuffer for the EFI_FB record (contract
/// 2.2). Absent GOP is not fatal: the kernel boots on serial
/// without it, and this increment records present=false.
pub fn framebuffer(bs: *uefi.tables.BootServices) FbInfo {
    const gop = (bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch return .{ .present = false }) orelse
        return .{ .present = false };
    const mode = gop.mode;
    const info = mode.info;
    return .{
        .present = true,
        .base = mode.frame_buffer_base,
        .size = mode.frame_buffer_size,
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .stride = info.pixels_per_scan_line,
    };
}

pub const PageTables = struct {
    /// Physical address of PML4 (the value loaded into cr3).
    pml4: u64,
    /// The 9-page allocation base.
    alloc_base: u64,
    pages: usize,
};

// The nine pages, no-copy regime (contract 5.1): PML4, lower PT3,
// upper PT3, four lower PDs (1:1 of the low 4 GiB), and two upper
// PDs whose 2 MiB entries walk the staging base to map the kernel's
// linked range. Layout in the allocation, one 4 KiB page each:
//   0 PML4   1 PT3_l   2 PT3_u   3..6 PD_l0..3   7 PD_u0   8 PD_u1
const IDX_PML4 = 0;
const IDX_PT3_L = 1;
const IDX_PT3_U = 2;
const IDX_PD_L0 = 3;
const IDX_PD_U0 = 7;
const IDX_PD_U1 = 8;

fn slot(base: u64, page: usize) [*]u64 {
    return @ptrFromInt(base + page * 4096);
}

/// Build the no-copy page tables in a 9-page firmware allocation.
/// staging is the 2 MiB aligned dest-space anchor (the kernel image
/// base maps here). The upper mapping covers the kernel's linked
/// range [KERNBASE + kernbase_off, ...] onto the staging area.
pub fn buildPageTables(bs: *uefi.tables.BootServices, staging: u64) !PageTables {
    const nine = bs.allocatePages(
        .{ .max_address = @as([*]align(4096) uefi.Page, @ptrFromInt(0xFFFF_F000)) },
        .loader_data,
        9,
    ) catch return error.PageTableAllocFailed;
    const base: u64 = @intFromPtr(nine.ptr);
    // Zero all nine pages.
    @memset(@as([*]u8, @ptrFromInt(base))[0 .. 9 * 4096], 0);

    const pml4 = slot(base, IDX_PML4);
    const pt3_l = slot(base, IDX_PT3_L);
    const pt3_u = slot(base, IDX_PT3_U);

    // PML4[0] -> lower PT3 (1:1 low 4 GiB); PML4[511] -> upper PT3
    // (kernel linked range). 511 is the top slot, KERNBASE lives in
    // the top 2 GiB.
    pml4[0] = (base + IDX_PT3_L * 4096) | PG_V | PG_RW;
    pml4[511] = (base + IDX_PT3_U * 4096) | PG_V | PG_RW;

    // Lower PT3: four PDs give 1:1 of the low 4 GiB, each PD 512 x
    // 2 MiB identity pages (1 GiB per PD).
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        pt3_l[i] = (base + (IDX_PD_L0 + i) * 4096) | PG_V | PG_RW;
        const pd = slot(base, IDX_PD_L0 + i);
        var j: usize = 0;
        while (j < 512) : (j += 1) {
            const addr = @as(u64, i) * one_gib + @as(u64, j) * two_mib;
            pd[j] = addr | PG_V | PG_RW | PG_PS;
        }
    }

    // Upper PT3: the kernel's linked range is the top 2 GiB
    // (KERNBASE = 0xffffffff80000000), which is PT3 slots 510 and
    // 511, each a PD. These 2 MiB entries walk the staging base so
    // KERNBASE + offset resolves to staging + offset (contract 5.1,
    // the no-copy upper mapping walking the actual staging base).
    pt3_u[510] = (base + IDX_PD_U0 * 4096) | PG_V | PG_RW;
    pt3_u[511] = (base + IDX_PD_U1 * 4096) | PG_V | PG_RW;
    const pd_u0 = slot(base, IDX_PD_U0);
    const pd_u1 = slot(base, IDX_PD_U1);
    // Slot 510 covers KERNBASE-2GiB..KERNBASE, slot 511 covers
    // KERNBASE..top. The kernel is linked at KERNBASE (slot 511,
    // PD index 0 upward), mapped onto staging.
    var k: usize = 0;
    while (k < 512) : (k += 1) {
        pd_u1[k] = (staging + @as(u64, k) * two_mib) | PG_V | PG_RW | PG_PS;
        // Slot 510: one below, kept identity-walking staging minus
        // 1 GiB is not meaningful; map it to staging too as a
        // benign lower alias (only slot 511 is on the kernel's
        // path). Leave 510 covering the gap harmlessly at staging.
        pd_u0[k] = (staging + @as(u64, k) * two_mib) | PG_V | PG_RW | PG_PS;
    }

    return .{ .pml4 = base + IDX_PML4 * 4096, .alloc_base = base, .pages = 9 };
}

/// Attestation checks over the built tables: the PML4 entries point
/// where they should, and the upper mapping's first entry walks the
/// real staging base. Returns true if coherent.
pub fn checkPageTables(pt: PageTables, staging: u64) bool {
    const pml4 = slot(pt.alloc_base, IDX_PML4);
    if (pml4[0] & PG_V == 0 or pml4[511] & PG_V == 0) return false;
    if ((pml4[0] & ~@as(u64, 0xfff)) != pt.alloc_base + IDX_PT3_L * 4096) return false;
    if ((pml4[511] & ~@as(u64, 0xfff)) != pt.alloc_base + IDX_PT3_U * 4096) return false;
    const pd_u1 = slot(pt.alloc_base, IDX_PD_U1);
    if ((pd_u1[0] & ~@as(u64, 0x1fffff)) != staging) return false;
    if (pd_u1[0] & PG_PS == 0) return false;
    return true;
}
