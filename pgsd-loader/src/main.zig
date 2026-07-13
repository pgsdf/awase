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
const module_elf = @import("module_elf.zig");

// FreeBSD sys/reboot.h: RB_SERIAL selects the serial console at
// kernel init, before the kenv console= is fully in effect. The PGSD
// kernel has no framebuffer console, so serial is the only console;
// set it in boothowto so the kernel does not come up console-less.
const RB_SERIAL: u32 = 0x1000;

// FreeBSD sys/reboot.h: RB_VERBOSE (0x800) is what sets the kernel's
// `bootverbose`. sys/kern/init_main.c: `if (boothowto & RB_VERBOSE)`.
//
// This is a bit in the boothowto word passed as MODINFOMD_HOWTO
// metadata, NOT a kernel environment variable. An earlier attempt set
// `boot_verbose=1` in the env, which does nothing: the kernel never
// reads such a variable. The env is the wrong knob and the howto word
// is the right one.
//
// We need it because the efirt attach failure (MOD_LOAD error 6) has
// two possible causes in sys/dev/efidev/efirt.c and BOTH of their
// distinguishing messages are printed only `if (bootverbose)`. Without
// this bit the kernel cannot tell us which defect we have, which is
// why F9 was built on a guess.
const RB_VERBOSE: u32 = 0x800;

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
    // Either armed name runs the attestation path; only the -boot
    // name additionally attempts the transfer (gated below on
    // bootArmed). A -bas run attests and chainloads as before.
    if (bas_boot.armed(self_image.file_path) or bas_boot.bootArmed(self_image.file_path)) {
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
                    // Boot environment: "name=value\0"... terminated by
                    // an empty string (double NUL). console=comconsole
                    // plus hw.uart.console binds the serial console (the
                    // PGSD kernel has no framebuffer console).
                    // acpi.rsdp passes the ACPI Root System Description
                    // Pointer discovered from the EFI configuration
                    // tables: a UEFI kernel finds ACPI only through this
                    // kenv (the legacy BIOS-region scan does not work on
                    // UEFI), and without it panics with "running without
                    // device atpic requires a local APIC".
                    // vfs.root.mountfrom names the root to mount.
                    const env_stage: [*]u8 = @ptrFromInt(lr.staging + envp_rel);
                    // The kernel env. console binding (F7) and the
                    // ACPI RSDP (F7) live here. bootverbose does NOT:
                    // it is a boothowto BIT (RB_VERBOSE), set where the
                    // chain is built, not an environment variable. See
                    // the RB_VERBOSE comment at the top of this file.
                    // vfs.root.mountfrom: the root filesystem the kernel mounts.
                    //
                    // This was "zfs:zroot/ROOT/awase-verified-pgsd-clean",
                    // a boot environment created during an install THREE
                    // reinstalls ago. It does not exist. The bench has one
                    // BE: zroot/ROOT/default.
                    //
                    // The consequence was the whole of F7's presentation.
                    // The kernel booted, initialised, probed devices, and
                    // then could not mount a root that was not there, so it
                    // dropped to the mountroot> prompt and waited for input.
                    // On a PGSD kernel that prompt is invisible: AD-39
                    // removes vt, vt_efifb, sc and vga so drawfs can own the
                    // framebuffer, and the only console left is a UART at
                    // io:0x3f8 that an Apple machine does not have. A kernel
                    // waiting at an invisible prompt presents as a blank
                    // screen, forever.
                    //
                    // f7probe showed this all along. The emulation runs
                    // reached mountroot> and it was explained away as "QEMU
                    // has no zroot pool". The bench HAS one, and still
                    // failed, because the name was wrong in both places. The
                    // same failure was being read as two different things.
                    const env_fixed = "console=comconsole\x00comconsole_speed=115200\x00hw.uart.console=io:0x3f8\x00vfs.root.mountfrom=zfs:zroot/ROOT/default\x00";
                    var env_len: usize = 0;
                    @memcpy(env_stage[0..env_fixed.len], env_fixed);
                    env_len = env_fixed.len;
                    if (handoff.findAcpiRsdp()) |rsdp| {
                        var rb: [40]u8 = undefined;
                        if (std.fmt.bufPrint(&rb, "acpi.rsdp=0x{x}\x00", .{rsdp})) |kv| {
                            @memcpy(env_stage[env_len .. env_len + kv.len], kv);
                            env_len += kv.len;
                        } else |_| {}
                    }
                    env_stage[env_len] = 0; // final terminating NUL (double NUL)
                    env_len += 1;
                    const env_bytes_len = env_len;

                    // ADR 0006: preload zfs.ko.
                    //
                    // The root filesystem is ZFS and ZFS is a MODULE: it
                    // is not in the PGSD kernel and not in GENERIC. The
                    // stock loader preloads it from loader.conf. This
                    // loader cannot read loader.conf and, until now, could
                    // not preload anything at all, so the kernel booted,
                    // could not mount root, dropped to an invisible
                    // mountroot> prompt, and showed a blank screen
                    // (campaign finding F15).
                    //
                    // PLACEMENT. The image goes BETWEEN the env and the
                    // chain, so it lies BELOW chain_rel. kernend is
                    // align(chain_base + chain_len), so it covers the
                    // module only if the module is beneath the chain. The
                    // reference does exactly this: bi_load() puts the
                    // chain above the highest loaded file. Above the
                    // chain, the kernel would allocate over the module
                    // bytes and die somewhere unrelated.
                    const mod_rel = std.mem.alignForward(u64, envp_rel + env_bytes_len, 4096);
                    var mods_buf: [1]metadata.ModuleEntry = undefined;
                    var mods: []const metadata.ModuleEntry = &.{};
                    var mod_end_rel: u64 = mod_rel;

                    // The whole module image must fit inside the staging
                    // allocation. Bounds-check rather than trust: writing
                    // past staging is silent memory corruption on a
                    // machine with no console.
                    const mod_room: u64 = lr.staging_limit_rel -| mod_rel;
                    const mod_dest: [*]u8 = @ptrFromInt(lr.staging + mod_rel);

                    if (bas_boot.readSlotFileInto(
                        device_handle,
                        res.slot,
                        "zfs.ko",
                        mod_dest[0..@intCast(mod_room)],
                    )) |mod_size| {
                        const mod_image = mod_dest[0..mod_size];
                        if (module_elf.parseModule(mod_image)) |me| {
                            mods_buf[0] = .{
                                .name = "zfs.ko",
                                .addr = mod_rel + lr.base_paddr,
                                .size = mod_size,
                                .elfhdr = std.mem.asBytes(&me.ehdr),
                                .shdr = me.shdr_bytes,
                            };
                            mods = mods_buf[0..1];
                            mod_end_rel = mod_rel + mod_size;
                            var zb: [96]u8 = undefined;
                            if (std.fmt.bufPrint(&zb, "MOD: zfs.ko {d} bytes at 0x{x} shnum={d}\r\n", .{ mod_size, mod_rel + lr.base_paddr, me.shnum })) |m| printAscii(m) else |_| {}
                        } else |e| {
                            // A module the kernel would reject. Say so
                            // now, in the loader, where there is still a
                            // console; the same failure at boot is a blank
                            // screen.
                            var zb: [96]u8 = undefined;
                            if (std.fmt.bufPrint(&zb, "MOD: zfs.ko PARSE FAILED: {s}\r\n", .{@errorName(e)})) |m| printAscii(m) else |_| {}
                        }
                    } else |e| {
                        var zb: [96]u8 = undefined;
                        if (std.fmt.bufPrint(&zb, "MOD: zfs.ko READ FAILED: {s}\r\n", .{@errorName(e)})) |m| printAscii(m) else |_| {}
                    }

                    const chain_rel = std.mem.alignForward(u64, mod_end_rel, 4096);
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
                        .howto = RB_SERIAL | RB_VERBOSE,
                    }, envp_kvo, fw_handle, efb, map_in, mods)) |ch| {
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
                            // The env begins with the console= key and
                            // ends with the double-NUL terminator;
                            // confirm both. The terminator position is
                            // derived from env_bytes_len so this stays
                            // correct if the env content changes.
                            const env_ok = env_phys[0] == 'c' and env_phys[env_bytes_len - 2] == 0 and env_phys[env_bytes_len - 1] == 0;
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
                            // Env presence: walk KERNBASE+envp and
                            // confirm the first byte is 'c' (the
                            // console= key that now leads the env), so
                            // the env the kernel reads resolves too.
                            const walk_env = handoff.pageWalk(pt.pml4, handoff.KERNBASE + envp_rel + lr.base_paddr);
                            const walk_env_ok = walk_env != null and @as(*const u8, @ptrFromInt(walk_env.?)).* == 'c';
                            var wl2: [96]u8 = undefined;
                            if (std.fmt.bufPrint(&wl2, "WALK: mod={} entry={} mp=0x{x} ep=0x{x}\r\n", .{ walk_mod_ok, walk_entry_ok, walk_mod orelse 0, walk_entry orelse 0 })) |m| printAscii(m) else |_| {}
                            const readback_ok = staging_read_ok and walk_mod_ok and walk_entry_ok and walk_env_ok;
                            var hb: [160]u8 = undefined;
                            if (std.fmt.bufPrint(&hb, "HO: pml4=0x{x} pt_ok={} fb={} readback={}\r\n", .{ pt.pml4, okpt, fb.present, readback_ok })) |m| printAscii(m) else |_| {}
                            const ndesc: usize = if (mm_opt) |mm| mm.count else 0;
                            ho_note = std.fmt.bufPrint(&hbuf, "ho=prepared pml4=0x{x} ptok={} fb={} rb={} clen={d} ndesc={d}", .{ pt.pml4, okpt, fb.present, readback_ok, ch.len, ndesc }) catch "ho=prepared";

                            // 4b-final: the boot attempt. Gated on
                            // bootArmed (a distinct -boot.efi name) AND
                            // every attestation passing, so a -bas.efi
                            // run or any failed check still chainloads.
                            // Past ExitBootServices there is no console
                            // and no fallback within this boot.
                            if (readback_ok and bas_boot.bootArmed(self_image.file_path)) {
                                const tramp = handoff.transferAddr();
                                const clipc = handoff.transferCliAddr();
                                if (tramp >= 0x1_0000_0000) {
                                    // The transfer code must be below
                                    // 4 GiB to stay mapped by the low
                                    // 1:1 after the cr3 load; if not,
                                    // abort to the chainload.
                                    var tb: [64]u8 = undefined;
                                    ho_note = std.fmt.bufPrint(&tb, "boot=ABORT tramp_high=0x{x}", .{tramp}) catch "boot=ABORT";
                                } else if (handoff.buildHandoffStack(bsp, ch.modulep, ch.kernend)) |hrsp| {
                                    // Record the attempt BEFORE exit:
                                    // if the transfer hangs, the next
                                    // (fallback) boot reads this and we
                                    // know we reached the jump.
                                    var ab: [200]u8 = undefined;
                                    const av = std.fmt.bufPrint(&ab, "BOOT_ATTEMPT entry=0x{x} pml4=0x{x} tramp=0x{x} clipc=0x{x} rsp=0x{x} imgbase=0x{x}", .{ lr.entry, pt.pml4, tramp, clipc, hrsp, @intFromPtr(self_image.image_base) }) catch "BOOT_ATTEMPT";
                                    recordVerdict(av);
                                    // Final map capture + EFI_MAP
                                    // rebuild + ExitBootServices, with
                                    // the retry the map race requires.
                                    // ADR 0005 Decision 4: NVRAM markers
                                    // through this region survive a
                                    // reset, so a metal fault after the
                                    // BOOT_ATTEMPT breadcrumb localizes
                                    // to the last marker written. The
                                    // markers are best-effort: a failed
                                    // post-exit write is information,
                                    // not a step to retry.
                                    // F8: the exit sequence, restructured to
                                    // match the reference.
                                    //
                                    // stand/efi/loader/bootinfo.c bi_load()
                                    // does, in this order:
                                    //
                                    //   file_addmetadata(HOWTO, ENVP, ...)  build records
                                    //   bi_load_efi_data(kfp, exit_bs)      map, EXIT, vmap
                                    //   md_copymodules(0, is64)             THEN copy the
                                    //                                       chain to kernel
                                    //                                       memory
                                    //
                                    // The module chain is serialized into
                                    // kernel memory AFTER ExitBootServices.
                                    // Everything before the exit is
                                    // file_addmetadata, which appends records
                                    // to a list in the loader's own heap: no
                                    // firmware call, no allocation from the
                                    // firmware.
                                    //
                                    // The invariant that buys is exact:
                                    // between the successful GetMemoryMap and
                                    // ExitBootServices, the reference does
                                    // NOTHING. Its inner for(;;) loop grows
                                    // the buffer and re-fetches the map, so
                                    // the final GetMemoryMap has no
                                    // allocation after it; the outer
                                    // for(retry=2) loop re-runs the whole
                                    // thing if the exit fails on a stale key.
                                    // That structure, and the Matthew Garrett
                                    // comment above it, exist because
                                    // firmware can change the memory map
                                    // under a loader that does work in that
                                    // window.
                                    //
                                    // We used to do five things in that
                                    // window, two of them firmware calls:
                                    //
                                    //   recordVerdict("MARK_MAP_CAPTURED")   SetVariable!
                                    //   prepareVirtualMap(fmap)
                                    //   buildChainFull(...)
                                    //   memcpy(staging, chain)
                                    //   recordVerdict("MARK_CHAIN_REBUILT")  SetVariable!
                                    //
                                    // SetVariable is precisely the class of
                                    // call that can perturb the map, which is
                                    // what the retry loop is defending
                                    // against. We were doing it twice, inside
                                    // the window the defence protects.
                                    //
                                    // Now: build the chain into a LOCAL
                                    // buffer first (no firmware, no staging
                                    // write), then capture-and-exit with
                                    // nothing in between, then copy the chain
                                    // into kernel staging once boot services
                                    // are gone and nothing can move the map.
                                    //
                                    // ADR 0005 Decision 3 (fail closed) is
                                    // preserved: the chain is still built
                                    // from the FINAL map, because
                                    // prepareVirtualMap and buildChainFull
                                    // both run against the map we exit on. A
                                    // rebuild failure still aborts to
                                    // chainload rather than exiting boot
                                    // services on a stale map. The only
                                    // change is WHERE the bytes land and WHEN.
                                    var tries: u8 = 0;
                                    while (tries < 3) : (tries += 1) {
                                        const fmap = handoff.captureMemoryMap(bsp) catch break;

                                        // F9: identity-map the runtime
                                        // descriptors in place, before the
                                        // chain reads the map. The kernel's
                                        // efi_is_in_map() looks for GetTime
                                        // inside md_virt, so the map handed to
                                        // the kernel must carry virtual_start.
                                        const vmap = handoff.prepareVirtualMap(fmap);

                                        // Build the chain into a LOCAL buffer.
                                        // Memory only: no firmware call, no
                                        // write to kernel staging. This is the
                                        // analogue of file_addmetadata, which
                                        // the reference also does before the
                                        // exit.
                                        const fch = metadata.buildChainFull(&chain_buf, chain_rel + lr.base_paddr, .{
                                            .name = "kernel",
                                            .addr = lr.base_paddr,
                                            .size = image_span,
                                            .howto = RB_SERIAL | RB_VERBOSE,
                                        }, envp_rel + lr.base_paddr, fw_handle, efb, .{
                                            .descriptors = fmap.buffer[0 .. fmap.count * fmap.descriptor_size],
                                            .descriptor_size = fmap.descriptor_size,
                                            .descriptor_version = fmap.descriptor_version,
                                        }, mods) catch {
                                            // Fail closed (ADR 0005 Decision 3):
                                            // a stale map must never reach the
                                            // kernel. Boot services are still
                                            // live here, so this marker is a
                                            // legal call and chainload is still
                                            // reachable.
                                            recordVerdict("MARK_REBUILD_FAILED abort=chainload");
                                            ho_note = "boot=REBUILD_FAILED";
                                            break;
                                        };

                                        // THE WINDOW. Nothing between the map
                                        // capture above and the exit below
                                        // touches the firmware. No marker is
                                        // written here, deliberately: a
                                        // SetVariable in this window is exactly
                                        // what the reference's retry loop
                                        // exists to survive, and writing one
                                        // would be doing the thing the defence
                                        // defends against.
                                        bsp.exitBootServices(uefi.handle, fmap.key) catch continue;

                                        // Past ExitBootServices: no boot
                                        // services, no console. One marker
                                        // here, in physical mode before the
                                        // cr3 load, partitions the fault:
                                        // present means EBS returned and the
                                        // fault is in the trampoline or the
                                        // kernel; absent means EBS itself
                                        // reset.
                                        recordVerdict("MARK_EXITED_BOOTSERVICES");

                                        // Now copy the chain into kernel
                                        // staging, as the reference does with
                                        // md_copymodules AFTER the exit.
                                        // Plain memory: boot services are gone
                                        // and nothing can move the map under
                                        // us.
                                        const cs: [*]u8 = @ptrFromInt(lr.staging + chain_rel);
                                        @memcpy(cs[0..fch.len], chain_buf[0..fch.len]);

                                        // F9: apply the virtual map. Last
                                        // firmware call before the jump; the
                                        // marker is written BEFORE it, because
                                        // after SetVirtualAddressMap the
                                        // runtime-services pointer we hold is
                                        // no longer valid to call through.
                                        if (vmap.count > 0 and !vmap.truncated) {
                                            recordVerdict("MARK_VMAP_ATTEMPT");
                                            handoff.applyVirtualMap(vmap) catch {};
                                        } else {
                                            recordVerdict("MARK_VMAP_SKIPPED");
                                        }

                                        handoff.transferToKernel(lr.entry, pt.pml4, hrsp);
                                    }
                                    // All exit attempts failed, or the
                                    // rebuild failed closed: fall through
                                    // and chainload (boot services still
                                    // active). REBUILD_FAILED sets its
                                    // own note above; only overwrite when
                                    // the loop exhausted its exit tries.
                                    if (!std.mem.eql(u8, ho_note, "boot=REBUILD_FAILED"))
                                        ho_note = "boot=EXIT_FAILED";
                                } else |_| {
                                    ho_note = "boot=stack_alloc_failed";
                                }
                            }
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
