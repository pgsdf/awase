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
            _ = res;
            print("BAS: active slot VERIFIED; chainloading (increment 1)\r\n");
        } else |e| {
            printAscii("BAS: verification FAILED: ");
            printAscii(@errorName(e));
            printAscii("; chainloading (increment 1)\r\n");
        }
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
