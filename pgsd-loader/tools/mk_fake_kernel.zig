// mk-fake-kernel: emit a deterministic minimal ELF64 ET_EXEC image
// for smoke testing the increment 2 loader. Two PT_LOAD segments
// (one with bss) at paddrs 0x200000/0x204000, entry at the linked
// virtual base. Usage: mk-fake-kernel <out> [truncate]
// With truncate, the file is cut mid-segment: a valid ELF header
// whose load fails, for the refusal pass.

const std = @import("std");

pub fn main(init: std.process.Init.Minimal) !void {
    var args_buf: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.process.Args.Iterator.init(init.args);
    while (it.next()) |a| {
        if (n == args_buf.len) break;
        args_buf[n] = a;
        n += 1;
    }
    if (n < 2) {
        std.debug.print("usage: mk-fake-kernel <out> [truncate]\n", .{});
        std.process.exit(1);
    }
    const truncate = n >= 3 and std.mem.eql(u8, args_buf[2], "truncate");

    var img = [_]u8{0} ** 0x2100;
    // ELF header.
    @memcpy(img[0..4], "\x7fELF");
    img[4] = 2; // class 64
    img[5] = 1; // little endian
    img[6] = 1; // version
    std.mem.writeInt(u16, img[16..18], 2, .little); // ET_EXEC
    std.mem.writeInt(u16, img[18..20], 62, .little); // EM_X86_64
    std.mem.writeInt(u32, img[20..24], 1, .little); // version
    std.mem.writeInt(u64, img[24..32], 0xffffffff80200000, .little); // entry
    std.mem.writeInt(u64, img[32..40], 64, .little); // phoff
    std.mem.writeInt(u16, img[52..54], 64, .little); // ehsize
    std.mem.writeInt(u16, img[54..56], 56, .little); // phentsize
    std.mem.writeInt(u16, img[56..58], 2, .little); // phnum
    // Phdr helper.
    const P = struct {
        fn put(b: []u8, off: u64, vaddr: u64, paddr: u64, filesz: u64, memsz: u64) void {
            std.mem.writeInt(u32, b[0..4], 1, .little); // PT_LOAD
            std.mem.writeInt(u32, b[4..8], 5, .little); // flags RX
            std.mem.writeInt(u64, b[8..16], off, .little);
            std.mem.writeInt(u64, b[16..24], vaddr, .little);
            std.mem.writeInt(u64, b[24..32], paddr, .little);
            std.mem.writeInt(u64, b[32..40], filesz, .little);
            std.mem.writeInt(u64, b[40..48], memsz, .little);
            std.mem.writeInt(u64, b[48..56], 0x1000, .little);
        }
    };
    P.put(img[64..120], 0x1000, 0xffffffff80200000, 0x200000, 0x40, 0x40);
    P.put(img[120..176], 0x2000, 0xffffffff80204000, 0x204000, 0x20, 0x100);
    // Deterministic payloads.
    for (img[0x1000..0x1040], 0..) |*b, i| b.* = @intCast(i & 0xff);
    for (img[0x2000..0x2020], 0..) |*b, i| b.* = @intCast((i * 7) & 0xff);

    const out_len: usize = if (truncate) 0x1800 else img.len;
    const fd = std.posix.openat(std.posix.AT.FDCWD, args_buf[1], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch {
        std.debug.print("mk-fake-kernel: cannot create output\n", .{});
        std.process.exit(1);
    };
    defer _ = std.posix.system.close(fd);
    const wrote = std.posix.system.write(fd, &img, out_len);
    if (wrote != out_len) {
        std.debug.print("mk-fake-kernel: short write\n", .{});
        std.process.exit(1);
    }
}
