// bas_launcher: emulation-only harness starting the loader under
// its ARMED name (L3a.2). Installed as the default boot application
// in a scratch ESP; it starts pgsd-loader WITH a known option
// string, standing in for a firmware boot entry carrying options,
// which FreeBSD 15.1's efibootmgr cannot create. pgsd-loader must
// forward the options unchanged to the chainload target, which
// echoes them. Never deployed to hardware.

const std = @import("std");
const uefi = std.os.uefi;

fn L(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

// Must outlive the child image's execution.
var options = std.unicode.utf8ToUtf16LeStringLiteral("pgsd-opt-test alpha beta").*;

pub fn main() uefi.Status {
    const con_out = uefi.system_table.con_out orelse return .unsupported;
    _ = con_out.outputString(L("boot-launcher: starting pgsd-loader-boot\r\n --\r\n")) catch {};

    const bs = uefi.system_table.boot_services orelse return .unsupported;

    const self_image = (bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch
        return .load_error) orelse return .load_error;
    const device_handle = self_image.device_handle orelse return .load_error;
    const device_path = (bs.handleProtocol(uefi.protocol.DevicePath, device_handle) catch
        return .load_error) orelse return .load_error;

    const target_path = device_path.createFileDevicePath(
        uefi.pool_allocator,
        std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\pgsd\\pgsd-loader-boot.efi"),
    ) catch return .load_error;

    const child = bs.loadImage(false, uefi.handle, .{ .device_path = target_path }) catch {
        _ = con_out.outputString(L("boot-launcher: LoadImage failed\r\n")) catch {};
        return .load_error;
    };

    if (bs.handleProtocol(uefi.protocol.LoadedImage, child) catch null) |child_image| {
        child_image.load_options = @ptrCast(&options);
        child_image.load_options_size = @intCast((options.len + 1) * 2);
    }

    _ = bs.startImage(child) catch return .load_error;
    return .success;
}
