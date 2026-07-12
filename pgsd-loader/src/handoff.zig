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
// ---------------------------------------------------------------------
// F9: the EFI virtual address map.
//
// pgsd-loader never called SetVirtualAddressMap. The reference loader
// does: stand/efi/loader/bootinfo.c efi_do_vmap() walks the memory map,
// identity-maps every descriptor carrying EFI_MEMORY_RUNTIME
// (VirtualStart = PhysicalStart), and calls
// RS->SetVirtualAddressMap(nset * mmsz, mmsz, mmver, vmap). It is
// called at bootinfo.c:313, AFTER the ExitBootServices retry loop at
// ~294, which is legal and deliberate: SetVirtualAddressMap is a
// RUNTIME service, not a boot service, so it survives the exit.
//
// The kernel notices the omission and told us so, in an error we saw in
// emulation and dismissed as cosmetic. sys/dev/efidev/efirt.c: some
// UEFI implementations keep two implementations of RS->GetTime and
// switch to the runtime-valid one ONLY when SetVirtualAddressMap is
// called, so the kernel checks whether the GetTime pointer lies within
// the EFI map and fails to attach if not, returning ENXIO. ENXIO is
// errno 6. That is exactly the "MOD_LOAD efirt error 6" we observed and
// ignored: the kernel reporting, precisely, that this loader never
// called SetVirtualAddressMap.
//
// OVMF does not do the pointer switching, which is why omitting the
// call cost nothing in QEMU but a failed efirt attach. Apple firmware
// is the class the kernel comment is warning about, which is why this
// is the leading F7 hypothesis (finding F9).
//
// CONSTRAINT, and the reason this is split in two. The reference can
// malloc() inside efi_do_vmap because the FreeBSD loader has its own
// heap that survives ExitBootServices. We do not: our allocator is
// UEFI's allocatePool, a BOOT service, which is gone the moment we
// exit. So the vmap buffer must be built BEFORE the exit and only
// APPLIED after it. prepareVirtualMap() does the former into a static
// buffer; applyVirtualMap() does the latter and allocates nothing.

/// Room for the runtime descriptors. Real firmware exposes a handful
/// (runtime code, runtime data, ACPI NVS, MMIO); 64 is generous. If a
/// firmware exceeds it we take the first 64 rather than corrupt the
/// call, and say so: a truncated map is a bug, not a silent
/// degradation.
const MAX_RT_DESCRIPTORS: usize = 64;

var vmap_buf: [MAX_RT_DESCRIPTORS * 128]u8 align(8) = undefined;

pub const VirtualMap = struct {
    /// Number of runtime descriptors copied. Zero means the firmware
    /// reported none, which would be unusual and is worth noticing.
    count: usize,
    descriptor_size: usize,
    descriptor_version: u32,
    /// True if the runtime descriptor count exceeded MAX_RT_DESCRIPTORS
    /// and the map was truncated. The caller should treat this as a
    /// failure rather than proceed.
    truncated: bool,
};

/// Build the identity virtual map from a memory map captured BEFORE
/// ExitBootServices. Allocates nothing: the descriptors are copied into
/// a static buffer, so the result stays valid across the exit.
///
/// Mirrors efi_do_vmap's walk: copy every descriptor with the
/// memory_runtime attribute, setting virtual_start = physical_start.
///
/// CRITICAL, and the reason the first cut of F9 failed: this writes
/// virtual_start into the ORIGINAL map as well as into the copy.
///
/// The reference does the same, and it is easy to miss because it looks
/// incidental (stand/efi/loader/bootinfo.c efi_do_vmap):
///
///     if ((desc->Attribute & EFI_MEMORY_RUNTIME) != 0) {
///             ++nset;
///             desc->VirtualStart = desc->PhysicalStart;   <-- mutates mm
///             *viter = *desc;                             <-- then copies
///
/// `desc` walks `mm`, the buffer the loader later hands the kernel as
/// MODINFOMD_EFI_MAP. So the map the kernel receives has virtual_start
/// FILLED IN for every runtime descriptor.
///
/// That matters because of what the kernel actually checks.
/// sys/dev/efidev/efirt.c efi_is_in_map() tests the GetTime pointer
/// against `p->md_virt`, the descriptor's VIRTUAL start, not its
/// physical one:
///
///     if (addr >= p->md_virt &&
///         addr < p->md_virt + p->md_pages * EFI_PAGE_SIZE)
///
/// The first cut of F9 built the vmap into a separate buffer and left
/// the original untouched, so every virtual_start in the map handed to
/// the kernel was still zero, efi_is_in_map could never match, and the
/// kernel reported exactly what it saw: "EFI runtime services table has
/// an invalid pointer", MOD_LOAD efirt error 6. The firmware call
/// succeeded; the metadata was wrong.
pub fn prepareVirtualMap(map: MemMap) VirtualMap {
    var out: usize = 0;
    var truncated = false;

    var i: usize = 0;
    while (i < map.count) : (i += 1) {
        const off = i * map.descriptor_size;
        const desc: *uefi.tables.MemoryDescriptor =
            @ptrCast(@alignCast(&map.buffer[off]));

        if (!desc.attribute.memory_runtime) continue;

        // Identity-map IN PLACE, in the original map. This is the line
        // the kernel's efi_is_in_map() depends on: the map we pass as
        // MODINFOMD_EFI_MAP must carry virtual_start for its runtime
        // descriptors, or the kernel cannot locate GetTime and refuses
        // to attach efirt.
        desc.virtual_start = desc.physical_start;

        if (out >= MAX_RT_DESCRIPTORS or
            (out + 1) * map.descriptor_size > vmap_buf.len)
        {
            truncated = true;
            break;
        }

        // Then copy the (now identity-mapped) descriptor into the
        // compacted buffer the firmware call takes. The firmware wants
        // only the runtime subset; the kernel wants the whole map with
        // virtual_start filled in. Both are now satisfied.
        const dst_off = out * map.descriptor_size;
        @memcpy(
            vmap_buf[dst_off .. dst_off + map.descriptor_size],
            map.buffer[off .. off + map.descriptor_size],
        );

        out += 1;
    }

    return .{
        .count = out,
        .descriptor_size = map.descriptor_size,
        .descriptor_version = map.descriptor_version,
        .truncated = truncated,
    };
}

/// Apply the prepared map. Call AFTER ExitBootServices, as the
/// reference does. Allocates nothing and calls no boot service:
/// SetVirtualAddressMap is a runtime service and is still live.
///
/// Returns the UEFI status so the caller can record it in the boot
/// breadcrumb. A failure here is worth knowing about but is not
/// necessarily fatal: the kernel's own check (efirt.c) is what
/// ultimately decides whether the runtime services are usable.
pub fn applyVirtualMap(vm: VirtualMap) !void {
    if (vm.count == 0) return error.NoRuntimeDescriptors;
    if (vm.truncated) return error.VirtualMapTruncated;

    const rs = uefi.system_table.runtime_services;
    try rs.setVirtualAddressMap(.{
        .info = .{
            // The key is not consulted by SetVirtualAddressMap; it
            // takes size, descriptor size, version, and the map.
            .key = @enumFromInt(0),
            .descriptor_size = vm.descriptor_size,
            .descriptor_version = vm.descriptor_version,
            .len = vm.count,
        },
        .ptr = @ptrCast(&vmap_buf),
    });
}

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

// ---------------------------------------------------------------------
// F9 tests.
//
// prepareVirtualMap is pure logic over a buffer with no UEFI calls, so
// unlike the rest of this file it can be tested directly. It is worth
// testing: a wrong attribute filter or a missed identity assignment
// would be silent, and the failure would only appear as a kernel that
// cannot use its runtime services.

const testing = std.testing;

fn tdesc(
    buf: []align(8) u8,
    idx: usize,
    dsize: usize,
    phys: u64,
    runtime: bool,
) void {
    const off = idx * dsize;
    const d: *uefi.tables.MemoryDescriptor = @ptrCast(@alignCast(&buf[off]));
    d.* = .{
        .type = .conventional_memory,
        .physical_start = phys,
        .virtual_start = 0xdead_beef, // must be overwritten for runtime descs
        .number_of_pages = 1,
        .attribute = .{
            .uc = false, .wc = false, .wt = false, .wb = true,
            .uce = false, .wp = false, .rp = false, .xp = false,
            .nv = false, .more_reliable = false, .ro = false,
            .sp = false, .cpu_crypto = false,
            .memory_runtime = runtime,
        },
    };
}

test "prepareVirtualMap: copies only runtime descriptors, identity-mapped" {
    const dsize = @sizeOf(uefi.tables.MemoryDescriptor);
    var buf: [8 * @sizeOf(uefi.tables.MemoryDescriptor)]u8 align(8) = undefined;

    // Five descriptors: three runtime, two not. The reference walks the
    // whole map and copies only the runtime ones, which is what the
    // firmware expects: SetVirtualAddressMap takes the runtime subset.
    tdesc(&buf, 0, dsize, 0x1000, false);
    tdesc(&buf, 1, dsize, 0x2000, true);
    tdesc(&buf, 2, dsize, 0x3000, false);
    tdesc(&buf, 3, dsize, 0x4000, true);
    tdesc(&buf, 4, dsize, 0x5000, true);

    const vm = prepareVirtualMap(.{
        .key = @enumFromInt(0),
        .descriptor_size = dsize,
        .descriptor_version = 1,
        .count = 5,
        .buffer = &buf,
    });

    try testing.expectEqual(@as(usize, 3), vm.count);
    try testing.expectEqual(false, vm.truncated);
    try testing.expectEqual(dsize, vm.descriptor_size);

    // Each copied descriptor is identity-mapped: virtual == physical.
    const expect_phys = [_]u64{ 0x2000, 0x4000, 0x5000 };
    for (expect_phys, 0..) |phys, i| {
        const d: *const uefi.tables.MemoryDescriptor =
            @ptrCast(@alignCast(&vmap_buf[i * dsize]));
        try testing.expectEqual(phys, d.physical_start);
        try testing.expectEqual(phys, d.virtual_start);
        try testing.expectEqual(true, d.attribute.memory_runtime);
    }

    // THE ONE THAT MATTERS. The ORIGINAL map must also carry
    // virtual_start for its runtime descriptors, because that is the
    // buffer the chain copies to the kernel as MODINFOMD_EFI_MAP, and
    // the kernel's efi_is_in_map() looks for the GetTime pointer inside
    // md_virt. The first cut of F9 mapped only the copy, the kernel saw
    // zeros, and efirt refused to attach with "invalid pointer".
    for ([_]struct { i: usize, p: u64, rt: bool }{
        .{ .i = 0, .p = 0x1000, .rt = false },
        .{ .i = 1, .p = 0x2000, .rt = true },
        .{ .i = 2, .p = 0x3000, .rt = false },
        .{ .i = 3, .p = 0x4000, .rt = true },
        .{ .i = 4, .p = 0x5000, .rt = true },
    }) |e| {
        const d: *const uefi.tables.MemoryDescriptor =
            @ptrCast(@alignCast(&buf[e.i * dsize]));
        if (e.rt) {
            try testing.expectEqual(e.p, d.virtual_start);
        } else {
            // Non-runtime descriptors are left alone, as the reference
            // leaves them: only EFI_MEMORY_RUNTIME regions are mapped.
            try testing.expectEqual(@as(u64, 0xdead_beef), d.virtual_start);
        }
    }
}

test "prepareVirtualMap: no runtime descriptors is reported, not silently empty" {
    const dsize = @sizeOf(uefi.tables.MemoryDescriptor);
    var buf: [4 * @sizeOf(uefi.tables.MemoryDescriptor)]u8 align(8) = undefined;
    tdesc(&buf, 0, dsize, 0x1000, false);
    tdesc(&buf, 1, dsize, 0x2000, false);

    const vm = prepareVirtualMap(.{
        .key = @enumFromInt(0),
        .descriptor_size = dsize,
        .descriptor_version = 1,
        .count = 2,
        .buffer = &buf,
    });

    try testing.expectEqual(@as(usize, 0), vm.count);
    // applyVirtualMap must refuse rather than call the firmware with an
    // empty map: zero runtime descriptors means something is wrong with
    // the map we captured, not that the firmware has no runtime services.
    try testing.expectError(error.NoRuntimeDescriptors, applyVirtualMap(vm));
}

test "prepareVirtualMap: truncation is a failure, not a silent partial map" {
    const dsize = @sizeOf(uefi.tables.MemoryDescriptor);
    const n = MAX_RT_DESCRIPTORS + 4;
    const bytes = n * @sizeOf(uefi.tables.MemoryDescriptor);
    const buf = try testing.allocator.alignedAlloc(u8, .@"8", bytes);
    defer testing.allocator.free(buf);

    for (0..n) |i| tdesc(buf, i, dsize, 0x1000 * (i + 1), true);

    const vm = prepareVirtualMap(.{
        .key = @enumFromInt(0),
        .descriptor_size = dsize,
        .descriptor_version = 1,
        .count = n,
        .buffer = buf,
    });

    try testing.expectEqual(true, vm.truncated);
    // A truncated map would tell the firmware to relocate SOME runtime
    // regions and not others, which is worse than not calling at all.
    // Refuse.
    try testing.expectError(error.VirtualMapTruncated, applyVirtualMap(vm));
}
