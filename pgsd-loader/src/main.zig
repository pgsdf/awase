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
            var vb: [160]u8 = undefined;
            var elf_note: []const u8 = "elf=skip";
            var enbuf: [96]u8 = undefined;
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
                    const stage_off = lr.staging - lr.base_paddr;
                    const envp_dest = std.mem.alignForward(u64, lr.image_end, 4096);
                    // Minimal environment: empty (double NUL), the
                    // valid terminator; real vars arrive with the
                    // slot manifest in a later increment.
                    const env_bytes = [_]u8{ 0, 0 };
                    const env_stage: [*]u8 = @ptrFromInt(envp_dest + stage_off);
                    @memcpy(env_stage[0..env_bytes.len], &env_bytes);
                    const chain_dest = std.mem.alignForward(u64, envp_dest + env_bytes.len, 4096);
                    var chain_buf: [1024]u8 = undefined;
                    if (metadata.buildChain(&chain_buf, chain_dest, .{
                        .name = "kernel",
                        .addr = lr.base_paddr,
                        .size = lr.image_end - lr.base_paddr,
                        .howto = 0,
                    }, envp_dest)) |ch| {
                        const chain_stage: [*]u8 = @ptrFromInt(chain_dest + stage_off);
                        @memcpy(chain_stage[0..ch.len], chain_buf[0..ch.len]);
                        var mb: [128]u8 = undefined;
                        if (std.fmt.bufPrint(&mb, "META: modulep=0x{x} kernend=0x{x} chainlen={d}\r\n", .{ ch.modulep, ch.kernend, ch.len })) |m| printAscii(m) else |_| {}
                        elf_note = std.fmt.bufPrint(&enbuf, "elf=loaded entry=0x{x} base=0x{x} modulep=0x{x} kernend=0x{x}", .{ lr.entry, lr.base_paddr, ch.modulep, ch.kernend }) catch "elf=loaded meta=built";
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
