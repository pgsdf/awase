// chainload_target: emulation-only stand-in for stock loader.efi.
//
// Installed as EFI\freebsd\loader.efi inside a scratch ESP image so
// the L0 chainload path can be exercised under qemu/OVMF before
// bare-metal bench runs (parent ADR 0001 Decision 7: emulation for
// iteration, bench as sole authority). Prints a marker, echoes any
// forwarded load options, and returns. Never deployed to hardware.

const std = @import("std");
const uefi = std.os.uefi;

fn L(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

pub fn main() uefi.Status {
    const con_out = uefi.system_table.con_out orelse return .unsupported;
    _ = con_out.outputString(L("CHAINLOAD TARGET REACHED\r\n")) catch {};

    // Echo forwarded load options, proving criterion 5 end to end.
    if (uefi.system_table.boot_services) |bs| blk: {
        const img = (bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch break :blk) orelse break :blk;
        if (img.load_options_size > 0) {
            if (img.load_options) |opts| {
                _ = con_out.outputString(L("LOAD OPTIONS: ")) catch {};
                const p: [*:0]const u16 = @ptrCast(@alignCast(opts));
                _ = con_out.outputString(p) catch {};
                _ = con_out.outputString(L("\r\n")) catch {};
            }
        }
        bs.stall(1_000_000) catch {};
    }

    // Emulation hygiene: the whole point of this stand-in is to
    // print its markers and end the run. Returning .success hands
    // control back to the firmware, which under some OVMF builds
    // (the bench edk2-qemu port among them) falls through to the
    // interactive Boot Manager and repaints a full-screen menu over
    // serial, burying the markers in cursor-positioning escapes and
    // defeating the captured-log grep. Shut the machine down instead
    // so the serial ends exactly at the markers. This is
    // emulation-only; the stand-in is never deployed to hardware.
    // resetSystem is noreturn: the machine powers off here.
    uefi.system_table.runtime_services.resetSystem(.shutdown, .success, null);
}
