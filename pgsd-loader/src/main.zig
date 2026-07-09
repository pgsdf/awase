// pgsd-loader: stage L0, presence and chainload (ADR 0003).
//
// Prints a banner and chainloads the stock FreeBSD loader from the
// same device this image was loaded from, forwarding load options
// unchanged. On any failure it reports, pauses briefly so the
// operator can read the report, and returns a non-success status so
// firmware falls through the boot order to the fallback entry
// (ADR 0003 Decision 1). L0 introduces no new boot authority
// (Decision 5): stock loader.efi remains authoritative for kernel
// loading, configuration processing, and handoff; this image only
// precedes it.

const std = @import("std");
const uefi = std.os.uefi;
const bas_boot = @import("bas_boot.zig");
const elf_load = @import("elf_load.zig");
const metadata = @import("metadata.zig");
const handoff = @import("handoff.zig");

// Vendor GUID for PGSD boot-evidence variables (generated for this
// project; recorded in the L3a campaign ledger). The armed test
// path writes its verdict here because this platform's console is
// not reliably observable (ledger F3); the booted OS reads it back
// with efivar(8).
const pgsd_guid = uefi.Guid{
    .time_low = 0x50475344,
    .time_mid = 0x6261,
    .time_high_and_version = 0x4c33,
    .clock_seq_high_and_reserved = 0x8a,
    .clock_seq_low = 0x01,
    .node = .{ 0x70, 0x67, 0x73, 0x64, 0x62, 0x61 },
};

fn recordVerdict(verdict: []const u8) void {
    const rs = uefi.system_table.runtime_services;
    rs.setVariable(
        std.unicode.utf8ToUtf16LeStringLiteral("PgsdBasVerdict"),
        &pgsd_guid,
        .{ .non_volatile = true, .bootservice_access = true, .runtime_access = true },
        verdict,
    ) catch {};
}

const banner = "pgsd-loader " ++ version ++ " (L0: presence and chainload)\r\n";
pub const version = "0.1.0";

/// Path to the stock loader on the same device, per ADR 0003
/// Decision 2: read, never written.
const chainload_path = "\\EFI\\freebsd\\loader.efi";

/// Comptime UTF-8 to UTF-16 for string literals.
fn L(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// Print a runtime ASCII string to the console, best-effort.
fn printAscii(s: []const u8) void {
    const con_out = uefi.system_table.con_out orelse return;
    var buf: [128:0]u16 = undefined;
    var i: usize = 0;
    for (s) |c| {
        if (i >= buf.len - 1) break;
        buf[i] = c;
        i += 1;
    }
    buf[i] = 0;
    _ = con_out.outputString(buf[0..i :0]) catch {};
}

fn print(comptime s: []const u8) void {
    const con_out = uefi.system_table.con_out orelse return;
    _ = con_out.outputString(L(s)) catch {};
}

/// Report a failure and stall so the report is readable before
/// firmware moves on to the fallback entry.
fn fail(comptime what: []const u8, status_name: []const u8) uefi.Status {
    print("pgsd-loader: " ++ what ++ ": ");
    printAscii(status_name);
    print("\r\npgsd-loader: falling through to firmware boot order\r\n");
    if (uefi.system_table.boot_services) |bs| {
        bs.stall(3_000_000) catch {};
    }
    return .load_error;
}

pub fn main() uefi.Status {
    print(banner);

    const bs = uefi.system_table.boot_services orelse
        return fail("boot services unavailable", "");

    // Our own LoadedImage: source device and load options to forward.
    const self_image = (bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch |e|
        return fail("cannot open own LoadedImage", @errorName(e))) orelse
        return fail("cannot open own LoadedImage", "NullInterface");

    const device_handle = self_image.device_handle orelse
        return fail("no device handle on own image", "");

    // L3a.2 increment 1: BAS verification mode, armed only when
    // this binary runs under the dedicated test name (ADR 0004
    // Decision 2; the default path below is untouched). Verifies
    // the active slot through all three integrity layers and
    // reports; control transfer is a later increment, so it
    // chainloads regardless, keeping every armed boot bootable.
    if (bas_boot.armed(self_image.file_path)) {
        print("pgsd-loader: BAS verification mode (L3a.2 increment 1)\r\n");
        if (bas_boot.verifyActiveSlot(device_handle, printAscii)) |res| {
            // Increment 2: load the verified kernel image per the
            // handoff contract, attest, free. Runs only when the
            // slot carries an artifact named kernel; a slot
            // without one is scaffolding, reported and skipped.
            var vb: [224]u8 = undefined;
            var elf_note: []const u8 = "elf=skip";
            var enbuf: [176]u8 = undefined;
            if (bas_boot.openSlotFile(device_handle, res.slot, "kernel")) |sf| {
                const bsp = uefi.system_table.boot_services.?;
                if (elf_load.loadKernel(bsp, sf.file, printAscii)) |lr| {
                    var lb: [128]u8 = undefined;
                    if (std.fmt.bufPrint(&lb, "ELF: LOADED entry=0x{x} base=0x{x} end=0x{x} staging=0x{x}\r\n", .{ lr.entry, lr.base_paddr, lr.image_end, lr.staging })) |m| printAscii(m) else |_| {}
                    // Increment 3: build the MODINFO chain in
                    // dest-space above the loaded image. stage_offset
                    // maps dest to staging (contract 0); the env
                    // block and chain sit page-aligned past
                    // image_end. Still verify-then-chainload: the
                    // chain is built and attested, not transferred
                    // to. EFI_MAP and EFI_FB are bound to
                    // ExitBootServices and belong to increment 4.
                    // Coordinate convention (KERNEL-HANDOFF 5.3,
                    // matching elf_load's segment placement): work
                    // in image-base-relative offsets. A relative
                    // offset R is physically at staging+R, and the
                    // kernel reads it at KERNBASE+R which the upper
                    // page tables send to staging+R. Every value
                    // handed to the kernel (modulep, envp, kernend,
                    // and the ADDR entry) is therefore relative to
                    // base_paddr, exactly as the loaded segments are.
                    const image_span = lr.image_end - lr.base_paddr;
                    const fb = handoff.framebuffer(bsp);
                    const envp_rel = std.mem.alignForward(u64, image_span, 4096);
                    const env_bytes = [_]u8{ 0, 0 };
                    const env_stage: [*]u8 = @ptrFromInt(lr.staging + envp_rel);
                    @memcpy(env_stage[0..env_bytes.len], &env_bytes);
                    const chain_rel = std.mem.alignForward(u64, envp_rel + env_bytes.len, 4096);
                    var chain_buf: [16384]u8 = undefined;
                    // Capture the memory map for EFI_MAP. In this
                    // attestable increment the map is captured during
                    // a run that still chainloads, so it proves the
                    // record format and sizing; 4b-final re-captures
                    // the final map (whose key ExitBootServices
                    // needs) into the same generously sized slot.
                    const fw_handle: u64 = @intFromPtr(uefi.system_table);
                    const efb = handoff.efiFbFrom(fb);
                    const mm_opt: ?handoff.MemMap = handoff.captureMemoryMap(bsp) catch null;
                    if (mm_opt == null) printAscii("HO: memory map capture failed; EFI_MAP empty\r\n");
                    const map_in: metadata.EfiMapInput = if (mm_opt) |mm| .{
                        .descriptors = mm.buffer[0 .. mm.count * mm.descriptor_size],
                        .descriptor_size = mm.descriptor_size,
                        .descriptor_version = mm.descriptor_version,
                    } else .{ .descriptors = &.{}, .descriptor_size = 0, .descriptor_version = 0 };
                    // ADDR is the kernel image's own relative base,
                    // which is 0 (the image begins at base_paddr);
                    // the kernel adds KERNBASE. SIZE is the span.
                    // Kernel-visible offsets are KVO = rel +
                    // base_paddr (the kernel adds KERNBASE and the
                    // tables map KERNBASE+KVO -> staging+KVO-base).
                    // The physical write stays at staging + rel.
                    const chain_kvo = chain_rel + lr.base_paddr;
                    const envp_kvo = envp_rel + lr.base_paddr;
                    if (metadata.buildChainFull(&chain_buf, chain_kvo, .{
                        .name = "kernel",
                        .addr = lr.base_paddr,
                        .size = image_span,
                        .howto = 0,
                    }, envp_kvo, fw_handle, efb, map_in)) |ch| {
                        const chain_stage: [*]u8 = @ptrFromInt(lr.staging + chain_rel);  // physical = staging + rel
                        @memcpy(chain_stage[0..ch.len], chain_buf[0..ch.len]);
                        var mb: [128]u8 = undefined;
                        if (std.fmt.bufPrint(&mb, "META: modulep=0x{x} kernend=0x{x} chainlen={d}\r\n", .{ ch.modulep, ch.kernend, ch.len })) |m| printAscii(m) else |_| {}

                        // Increment 4a: build the remaining handoff
                        // state (page tables, framebuffer record) and
                        // attest it, still short of ExitBootServices.
                        // The memory map is captured last in 4b (its
                        // key must be the final one), so 4a validates
                        // the page tables and framebuffer only.
                        var ho_note: []const u8 = "ho=skip";
                        var hbuf: [112]u8 = undefined;
                        if (handoff.buildPageTables(bsp, lr.staging, lr.base_paddr)) |pt| {
                            const okpt = handoff.checkPageTables(pt, lr.staging);
                            // 4b preflight: verify the coordinate
                            // convention end to end while the console
                            // still exists. The kernel will read
                            // KERNBASE+modulep through the upper page
                            // tables, which resolve to staging+dest.
                            // Read staging+modulep here and confirm
                            // it finds the chain's first record
                            // (MODINFO_NAME=1); read staging+envp and
                            // confirm the env terminator. If these
                            // match, the trampoline is safe to
                            // attempt; if not, the bug is found with
                            // a console alive.
                            // modulep and envp are image-base
                            // relative; physical = staging + rel,
                            // the same expression the kernel's page
                            // walk resolves KERNBASE+rel to.
                            const chain_phys: [*]u8 = @ptrFromInt(lr.staging + chain_rel);
                            const name_type = std.mem.readInt(u32, chain_phys[0..4], .little);
                            const env_phys: [*]u8 = @ptrFromInt(lr.staging + envp_rel);  // physical
                            const env_ok = env_phys[0] == 0 and env_phys[1] == 0;
                            // Walk the chain in place and confirm the
                            // EFI_MAP record (0x9004) is present: this
                            // is what the kernel keys efi_boot on, and
                            // it is at staging+chain, the exact bytes
                            // the kernel's page walk resolves.
                            var efi_map_seen = false;
                            var woff: usize = 0;
                            while (woff + 8 <= ch.len) {
                                const wt = std.mem.readInt(u32, chain_phys[woff..][0..4], .little);
                                const wl = std.mem.readInt(u32, chain_phys[woff + 4 ..][0..4], .little);
                                if (wt == (0x8000 | 0x1004)) efi_map_seen = true;
                                woff += 8 + ((wl + 7) & ~@as(usize, 7));
                            }
                            const staging_read_ok = (name_type == 1) and env_ok and efi_map_seen;

                            // The decisive check: walk the built page
                            // tables exactly as the kernel's MMU will,
                            // for KERNBASE+modulep (must reach the
                            // chain) and the kernel entry vaddr (must
                            // reach where elf_load placed the entry
                            // segment). The direct staging read above
                            // cannot catch a wrong page-table anchor;
                            // this can.
                            const want_chain_phys = lr.staging + ch.modulep - lr.base_paddr;
                            const walk_mod = handoff.pageWalk(pt.pml4, handoff.KERNBASE + ch.modulep);
                            const walk_entry = handoff.pageWalk(pt.pml4, lr.entry);
                            const want_entry_phys = lr.staging + (lr.entry - handoff.KERNBASE) - lr.base_paddr;
                            const walk_mod_ok = walk_mod != null and walk_mod.? == want_chain_phys;
                            const walk_entry_ok = walk_entry != null and walk_entry.? == want_entry_phys;
                            var wl2: [96]u8 = undefined;
                            if (std.fmt.bufPrint(&wl2, "WALK: mod={} entry={} mp=0x{x} ep=0x{x}\r\n", .{ walk_mod_ok, walk_entry_ok, walk_mod orelse 0, walk_entry orelse 0 })) |m| printAscii(m) else |_| {}
                            const readback_ok = staging_read_ok and walk_mod_ok and walk_entry_ok;
                            var hb: [160]u8 = undefined;
                            if (std.fmt.bufPrint(&hb, "HO: pml4=0x{x} pt_ok={} fb={} readback={}\r\n", .{ pt.pml4, okpt, fb.present, readback_ok })) |m| printAscii(m) else |_| {}
                            const ndesc: usize = if (mm_opt) |mm| mm.count else 0;
                            ho_note = std.fmt.bufPrint(&hbuf, "ho=prepared pml4=0x{x} ptok={} fb={} rb={} clen={d} ndesc={d}", .{ pt.pml4, okpt, fb.present, readback_ok, ch.len, ndesc }) catch "ho=prepared";
                        } else |he| {
                            printAscii("HO: FAIL ");
                            printAscii(@errorName(he));
                            printAscii("\r\n");
                            ho_note = std.fmt.bufPrint(&hbuf, "ho=FAIL:{s}", .{@errorName(he)}) catch "ho=FAIL";
                        }
                        elf_note = std.fmt.bufPrint(&enbuf, "elf=loaded base=0x{x} modulep=0x{x} kernend=0x{x} {s}", .{ lr.base_paddr, ch.modulep, ch.kernend, ho_note }) catch "elf=loaded meta=built ho=built";
                    } else |em| {
                        printAscii("META: FAIL ");
                        printAscii(@errorName(em));
                        printAscii("\r\n");
                        elf_note = std.fmt.bufPrint(&enbuf, "elf=loaded meta=FAIL:{s}", .{@errorName(em)}) catch "meta=FAIL";
                    }
                    // Verify-only increment: staging pages are left
                    // allocated (loader_data is reclaimed by the
                    // booted OS after the stock chainload exits boot
                    // services); the handoff increment owns the
                    // allocation for real.
                } else |e2| {
                    printAscii("ELF: FAIL ");
                    printAscii(@errorName(e2));
                    printAscii("\r\n");
                    elf_note = std.fmt.bufPrint(&enbuf, "elf=FAIL:{s}", .{@errorName(e2)}) catch "elf=FAIL";
                }
                sf.close();
            } else |_| {
                printAscii("ELF: no kernel artifact in slot; skipping (increment 2)\r\n");
            }
            const v = std.fmt.bufPrint(&vb, "PASS gen={d} slot={d} {s}", .{ res.generation, res.slot, elf_note }) catch "PASS";
            recordVerdict(v);
            print("BAS: active slot VERIFIED; chainloading (increment 1)\r\n");
        } else |e| {
            var vb: [96]u8 = undefined;
            const v = std.fmt.bufPrint(&vb, "FAIL {s}", .{@errorName(e)}) catch "FAIL";
            recordVerdict(v);
            printAscii("BAS: verification FAILED: ");
            printAscii(@errorName(e));
            printAscii("; chainloading (increment 1)\r\n");
        }
        // Armed mode only: dwell so the verdict is readable on
        // hardware whose firmware boots faster than a human reads
        // (L0 campaign observability note). The default path has
        // no dwell and no output; this is test scaffolding on the
        // armed name.
        _ = bs.stall(5_000_000) catch {};
    }

    // The device path of the volume we were loaded from, extended
    // with the stock loader's file path. The chainloaded image gets
    // the same device handle semantics it would have had from
    // firmware, which is what the behavioral invariant requires.
    const device_path = (bs.handleProtocol(uefi.protocol.DevicePath, device_handle) catch |e|
        return fail("cannot open device path", @errorName(e))) orelse
        return fail("cannot open device path", "NullInterface");

    const target_path = device_path.createFileDevicePath(
        uefi.pool_allocator,
        std.unicode.utf8ToUtf16LeStringLiteral(chainload_path),
    ) catch |e|
        return fail("cannot build target device path", @errorName(e));

    print("pgsd-loader: chainloading " ++ chainload_path ++ "\r\n");

    const child = bs.loadImage(false, uefi.handle, .{ .device_path = target_path }) catch |e|
        return fail("LoadImage failed", @errorName(e));

    // Forward our load options to the chainloaded loader unchanged
    // (ADR 0003 closure criterion 5).
    if (self_image.load_options_size > 0) {
        if (bs.handleProtocol(uefi.protocol.LoadedImage, child) catch null) |child_image| {
            child_image.load_options = self_image.load_options;
            child_image.load_options_size = self_image.load_options_size;
        }
    }

    const exit = bs.startImage(child) catch |e|
        return fail("StartImage failed", @errorName(e));

    // The stock loader normally never returns; if it does, report
    // its exit and pass a non-success status to firmware so the
    // boot order falls through to the fallback entry.
    print("pgsd-loader: chainloaded loader returned: ");
    printAscii(@tagName(exit.code));
    print("\r\n");
    if (uefi.system_table.boot_services) |b| b.stall(3_000_000) catch {};
    if (exit.code == .success) return .load_error;
    return exit.code;
}
