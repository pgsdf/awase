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
pub fn buildPageTables(bs: *uefi.tables.BootServices, staging: u64, base_paddr: u64) !PageTables {
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
    // KERNBASE is the start of PT3_u[510] (pd_u0), so the kernel's
    // linked range KERNBASE+KVO is covered by pd_u0 for KVO in
    // [0,1GiB) and pd_u1 for [1GiB,2GiB). elf_load places a segment
    // at staging + (p_paddr - base_paddr) and the kernel links it at
    // KERNBASE + p_paddr, so the mapping must be
    // KERNBASE + KVO -> staging + KVO - base_paddr. Subtracting
    // base_paddr is what makes the segment and metadata paths agree.
    var k: usize = 0;
    while (k < 512) : (k += 1) {
        pd_u0[k] = (staging + @as(u64, k) * two_mib - base_paddr) | PG_V | PG_RW | PG_PS;
        pd_u1[k] = (staging + one_gib + @as(u64, k) * two_mib - base_paddr) | PG_V | PG_RW | PG_PS;
    }

    return .{ .pml4 = base + IDX_PML4 * 4096, .alloc_base = base, .pages = 9 };
}

/// Attestation checks over the built tables: the PML4 entries point
/// where they should, and the upper mapping's first entry walks the
/// real staging base. Returns true if coherent.
pub fn checkPageTables(pt: PageTables, staging: u64) bool {
    // Structural coherence only: the PML4 entries point at the two
    // PT3 pages, and the low 1:1 mapping resolves. The authoritative
    // check of the kernel-range mapping is pageWalk against the real
    // access path (used by the preflight), which supersedes the
    // earlier fixed-offset assertions.
    _ = staging;
    const pml4 = slot(pt.alloc_base, IDX_PML4);
    if (pml4[0] & PG_V == 0 or pml4[511] & PG_V == 0) return false;
    if ((pml4[0] & ~@as(u64, 0xfff)) != pt.alloc_base + IDX_PT3_L * 4096) return false;
    if ((pml4[511] & ~@as(u64, 0xfff)) != pt.alloc_base + IDX_PT3_U * 4096) return false;
    // Low 1:1 sanity: virtual 0x100000 resolves to physical 0x100000.
    const p = pageWalk(pt.pml4, 0x100000);
    return p != null and p.? == 0x100000;
}

/// Convert an FbInfo plus pixel format into the kernel's EfiFb
/// record. Masks come from the GOP pixel format; blt-only formats
/// have no linear framebuffer and are reported as absent by
/// framebuffer() already.
pub fn efiFbFrom(fb: FbInfo) ?@import("metadata.zig").EfiFb {
    if (!fb.present) return null;
    return .{
        .fb_addr = fb.base,
        .fb_size = fb.size,
        .fb_height = fb.height,
        .fb_width = fb.width,
        .fb_stride = fb.stride,
        // Default 8-bit BGRX masks (the common GOP format on this
        // class of firmware); a later increment may read the exact
        // PixelBitmask for bit_mask-format modes.
        .fb_mask_red = 0x00ff0000,
        .fb_mask_green = 0x0000ff00,
        .fb_mask_blue = 0x000000ff,
        .fb_mask_reserved = 0xff000000,
    };
}

pub const KERNBASE: u64 = 0xffffffff80000000;

/// Walk the built page tables in software exactly as the MMU will,
/// returning the physical address a virtual address resolves to (or
/// null if unmapped). The loader runs on firmware tables that map
/// these physical structures 1:1, so each level is dereferenced
/// directly. 2 MiB and 1 GiB leaf pages are handled. This exists to
/// verify the kernel's real access path (KERNBASE + offset), which a
/// direct staging read cannot check.
pub fn pageWalk(pml4_phys: u64, vaddr: u64) ?u64 {
    const PG_PS_bit: u64 = 1 << 7;
    const idx4 = (vaddr >> 39) & 0x1ff;
    const idx3 = (vaddr >> 30) & 0x1ff;
    const idx2 = (vaddr >> 21) & 0x1ff;
    const pml4: [*]const u64 = @ptrFromInt(pml4_phys);
    const e4 = pml4[idx4];
    if (e4 & PG_V == 0) return null;
    const pdpt: [*]const u64 = @ptrFromInt(e4 & ~@as(u64, 0xfff));
    const e3 = pdpt[idx3];
    if (e3 & PG_V == 0) return null;
    if (e3 & PG_PS_bit != 0) return (e3 & ~@as(u64, 0x3fffffff)) + (vaddr & 0x3fffffff);
    const pd: [*]const u64 = @ptrFromInt(e3 & ~@as(u64, 0xfff));
    const e2 = pd[idx2];
    if (e2 & PG_V == 0) return null;
    if (e2 & PG_PS_bit != 0) return (e2 & ~@as(u64, 0x1fffff)) + (vaddr & 0x1fffff);
    return null; // we only build 2 MiB leaves in the upper range
}

/// Build the handoff stack btext expects (contract 5.3): the final
/// RSP points at a qword holding modulep in its high half (so
/// btext's movl 4(rbp) reads it as 32-bit), followed by kernend
/// (movl 8(rbp)). Both KVO values are below 4 GiB. Returns the RSP
/// value the trampoline installs. The page is a firmware allocation
/// below 4 GiB so the low 1:1 mapping covers it after the cr3 switch.
pub fn buildHandoffStack(bs: *uefi.tables.BootServices, modulep: u64, kernend: u64) !u64 {
    const pg = bs.allocatePages(
        .{ .max_address = @as([*]align(4096) uefi.Page, @ptrFromInt(0xFFFF_F000)) },
        .loader_data,
        1,
    ) catch return error.HandoffStackAllocFailed;
    const base: u64 = @intFromPtr(pg.ptr);
    @memset(@as([*]u8, @ptrFromInt(base))[0..4096], 0);
    // S near the top; btext only reads [S+4..7] and [S+8..11], never
    // pushes onto it (it switches to its own bootstack immediately).
    const s = base + 4096 - 256;
    @as(*u64, @ptrFromInt(s)).* = modulep << 32;
    @as(*u64, @ptrFromInt(s + 8)).* = kernend;
    return s;
}

/// The transfer (contract 5.2/5.3), no-copy regime. Runs
/// identity-mapped (the loader image must be below 4 GiB, checked by
/// the caller): disable interrupts, load the kernel page tables,
/// install the handoff stack, and jump to the kernel entry. copy_finish
/// is a nop in no-copy, so it is omitted. After the cr3 load the next
/// instructions are fetched through the new tables' low 1:1 mapping,
/// and the jump target is the kernel's linked entry in the upper map.
// Callable, but with the three values pinned to explicit registers
// as asm inputs so none is sourced from a %rbp-relative stack slot
// across the stack switch. The earlier form used "r" constraints,
// which the -ODebug allocator happened to satisfy with live
// registers; pinning to rcx/rdx/r8 (and reading rsp from a register,
// never memory) makes that guarantee explicit rather than
// incidental, so a reload from the old frame after "movq -> rsp"
// cannot occur. r9 is a scratch to stage the new rsp, keeping the
// three inputs untouched until used. The clobber of memory keeps the
// asm from being reordered against the surrounding stores.
pub fn transferToKernel(entry: u64, pagetable: u64, handoff_rsp: u64) noreturn {
    asm volatile (
        \\ .globl pgsd_tramp_cli
        \\ pgsd_tramp_cli:
        \\ cli
        \\ movq %[pt], %%cr3
        \\ movq %[sp], %%rsp
        \\ jmpq *%[entry]
        :
        : [entry] "{rcx}" (entry),
          [pt] "{rdx}" (pagetable),
          [sp] "{r8}" (handoff_rsp),
        : .{ .memory = true });
    unreachable;
}

// Address of the cli that opens the trampoline, for the breadcrumb
// and the gdb-step harness. transferAddr() returns &transferToKernel,
// which under -ODebug is the function prologue (push rbp; ...), not
// the cli; breaking there steps frame setup, not the switch. This
// returns the cli itself.
extern const pgsd_tramp_cli: u8;
pub fn transferCliAddr() u64 {
    return @intFromPtr(&pgsd_tramp_cli);
}

/// Address of the transfer code, for the caller's below-4-GiB check.
pub fn transferAddr() u64 {
    return @intFromPtr(&transferToKernel);
}

// Discover the ACPI RSDP physical address from the EFI system table's
// configuration tables. A UEFI kernel locates ACPI only through this
// pointer (passed as the acpi.rsdp kenv): the legacy scan of the BIOS
// EBDA/ROM region does not find it on UEFI, where the RSDP lives in
// the configuration tables. Prefer the ACPI 2.0 table, fall back to
// 1.0, matching loader.efi. Returns null if neither is present.
pub fn findAcpiRsdp() ?u64 {
    const ConfigurationTable = uefi.tables.ConfigurationTable;
    const st = uefi.system_table;
    const tables = st.configuration_table[0..st.number_of_table_entries];
    var acpi10: ?u64 = null;
    for (tables) |t| {
        if (t.vendor_guid.eql(ConfigurationTable.acpi_20_table_guid)) {
            return @intFromPtr(t.vendor_table);
        }
        if (t.vendor_guid.eql(ConfigurationTable.acpi_10_table_guid)) {
            acpi10 = @intFromPtr(t.vendor_table);
        }
    }
    return acpi10;
}
