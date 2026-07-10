// mk-fake-kernel: emit a deterministic minimal ELF64 ET_EXEC image
// for smoke testing the increment 2 loader. Two PT_LOAD segments
// (one with bss) at paddrs 0x200000/0x204000, entry at the linked
// virtual base. Usage: mk-fake-kernel <out> [truncate|contract]
//
// Modes:
//   (default)  entry writes KOK to COM1 then halts: proves control
//              transfer under emulation (the cr3 switch, stack, and
//              jump reached the entry). Reads nothing.
//   contract   entry exercises the handoff contract (ADR 0005 step
//              2): it reads modulep from the handoff stack the way
//              btext does (high 32 bits of [rsp+4]), follows
//              KERNBASE+modulep as the metadata chain, checks the
//              first record type is MODINFO_NAME (=1), and writes
//              a result to COM1: "HOK" if the chain was found
//              through the kernel's own mapping (the loader handed
//              over a correct, correctly-mapped modulep), or "HBAD"
//              if the first record type was wrong. A wrong modulep
//              or a wrong upper mapping shows as HBAD or a fault,
//              not a silent success, which is the diagnostic the
//              static KOK cannot give.
//   truncate   the file is cut mid-segment: a valid ELF header
//              whose load fails, for the refusal pass.

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
    const contract = n >= 3 and std.mem.eql(u8, args_buf[2], "contract");

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
    // Entry code (segment 0 at file offset 0x1000). Two variants.
    //
    // Default (KOK): write KOK to COM1 then hlt loop. A correct
    // trampoline jumps here and this runs, proving control transfer
    // under emulation. Raw port I/O needs no memory mapping, so it
    // works post-ExitBootServices.
    const kok_code = [_]u8{
        0xBA, 0xF8, 0x03, 0x00, 0x00, // mov $0x3f8, %edx
        0xB0, 0x4B, 0xEE, // mov $'K', %al ; out %al, %dx
        0xB0, 0x4F, 0xEE, // mov $'O', %al ; out
        0xB0, 0x4B, 0xEE, // mov $'K', %al ; out
        0xF4, // hlt
        0xEB, 0xFD, // jmp .-1 (loop on hlt)
    };
    // Contract: read modulep from the handoff stack as btext does
    // (the qword at rsp holds modulep in its high 32 bits, so the
    // 32-bit value at [rsp+4] is modulep), form the virtual address
    // KERNBASE + modulep, load the first u32 of the metadata chain
    // there (the leading record's type), and emit HOK if it is
    // MODINFO_NAME (1) or HBAD otherwise. This dereferences the
    // kernel's own upper mapping of the chain, so a wrong modulep
    // or a wrong upper page table shows as HBAD or a fault rather
    // than a false success. KERNBASE = 0xffffffff80000000.
    const contract_code = [_]u8{
        // esi = modulep (32-bit) from [rsp+4]
        0x8B, 0x74, 0x24, 0x04, // mov 0x4(%rsp), %esi
        // rdi = KERNBASE (0xffffffff80000000) via movabs
        0x48, 0xBF, 0x00, 0x00, 0x00, 0x80, 0xFF, 0xFF, 0xFF, 0xFF,
        // rdi += rsi  (KERNBASE + modulep; esi zero-extended)
        0x48, 0x01, 0xF7, // add %rsi, %rdi
        // eax = *(u32*)rdi  (leading record type)
        0x8B, 0x07, // mov (%rdi), %eax
        // dx = 0x3f8 (COM1)
        0xBA, 0xF8, 0x03, 0x00, 0x00, // mov $0x3f8, %edx
        // cmp eax, 1 (MODINFO_NAME); jne .bad
        0x83, 0xF8, 0x01, // cmp $1, %eax
        0x75, 0x0B, // jne .bad (+11 to the HBAD sequence)
        // .ok: write 'H','O','K'
        0xB0, 0x48, 0xEE, // mov $'H',%al; out
        0xB0, 0x4F, 0xEE, // mov $'O',%al; out
        0xB0, 0x4B, 0xEE, // mov $'K',%al; out
        0xEB, 0x09, // jmp .halt (+9 over the HBAD sequence)
        // .bad: write 'H','B','D' (jne rel8 above is +11 from its
        // own next IP, which lands exactly here)
        0xB0, 0x48, 0xEE, // mov $'H',%al; out
        0xB0, 0x42, 0xEE, // mov $'B',%al; out
        0xB0, 0x44, 0xEE, // mov $'D',%al; out
        // .halt:
        0xF4, // hlt
        0xEB, 0xFD, // jmp .-1
    };
    const entry_code: []const u8 = if (contract) &contract_code else &kok_code;
    @memcpy(img[0x1000 .. 0x1000 + entry_code.len], entry_code);
    for (img[0x1000 + entry_code.len .. 0x1040], 0..) |*b, i| b.* = @intCast(i & 0xff);
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
