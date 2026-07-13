// Module preloading: the ELF parsing pgsd-loader needs, and no more.
//
// ADR 0006. The kernel LINKS preloaded modules itself: kern_linker.c
// linker_preload() calls LINKER_LINK_PRELOAD, and link_elf_obj.c
// link_elf_link_preload() does the section placement, symbol resolution
// and relocation. This loader does not relocate anything. It places the
// raw .ko bytes in memory and describes them.
//
// link_elf_link_preload() states exactly what it reads, and it is the
// whole specification:
//
//     type    = preload_search_info(modptr, MODINFO_TYPE);
//     baseptr = preload_search_info(modptr, MODINFO_ADDR);
//     sizeptr = preload_search_info(modptr, MODINFO_SIZE);
//     hdr     = preload_search_info(modptr, MODINFO_METADATA|MODINFOMD_ELFHDR);
//     shdr    = preload_search_info(modptr, MODINFO_METADATA|MODINFOMD_SHDR);
//     if (type == NULL || strcmp(type, preload_modtype_obj) != 0)
//             return (EFTYPE);
//     if (baseptr == NULL || sizeptr == NULL || hdr == NULL || shdr == NULL)
//             return (EINVAL);
//
// The two metadata records are the part that is easy to miss. The kernel
// does NOT re-read the ELF header out of the module image it was handed;
// it reads the COPIES the loader passed as metadata. So the loader must
// parse the ELF far enough to copy out the Elf64_Ehdr and the whole
// section-header table, and pass both.
//
// stand/common/load_elf_obj.c does exactly this
// (file_addmetadata(fp, MODINFOMD_ELFHDR, sizeof(*hdr), hdr) at line 183,
// file_addmetadata(fp, MODINFOMD_SHDR, shdrbytes, shdr) at line 361) and
// is the recipe followed here.

const std = @import("std");

/// MODTYPE_OBJ, sys/sys/linker.h:228. The kernel string-compares
/// MODINFO_TYPE against this and returns EFTYPE if it differs, so it is
/// not decorative.
pub const MODTYPE_OBJ = "elf obj module";

/// sys/sys/linker.h. The two metadata records the preload path needs.
pub const MODINFOMD_ELFHDR: u32 = 0x0002;
pub const MODINFOMD_SHDR: u32 = 0x0009;

pub const Elf64_Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

pub const Elf64_Shdr = extern struct {
    sh_name: u32,
    sh_type: u32,
    sh_flags: u64,
    sh_addr: u64,
    sh_offset: u64,
    sh_size: u64,
    sh_link: u32,
    sh_info: u32,
    sh_addralign: u64,
    sh_entsize: u64,
};

pub const ET_REL: u16 = 1;
pub const EM_X86_64: u16 = 62;

pub const ParseError = error{
    TooSmall,
    NotElf,
    NotElf64,
    NotLittleEndian,
    /// A .ko is a RELOCATABLE object, not an executable. link_elf_obj is
    /// the "elf obj module" class precisely because of this: if we hand
    /// the kernel an ET_EXEC it will take the wrong linker path.
    NotRelocatable,
    WrongMachine,
    /// The section-header table lies outside the file. A truncated or
    /// corrupt module must be caught HERE, in the loader, where we can
    /// still say so. On the bench a bad module is a blank screen.
    ShdrOutOfBounds,
    NoSections,
    /// The file's e_shentsize disagrees with our Elf64_Shdr. If this
    /// fires, our struct is wrong, and every section header we hand the
    /// kernel would be misaligned.
    BadShentsize,
};

/// What the loader needs to know about a module, extracted once.
///
/// The slices point INTO the module image, so the image must outlive
/// this. That is fine: the image is staged into memory that is handed to
/// the kernel and never freed.
pub const ModuleElf = struct {
    /// A copy of the ELF header, to pass as MODINFOMD_ELFHDR. The kernel
    /// reads this, not the header in the image.
    ehdr: Elf64_Ehdr,
    /// The section-header table, to pass as MODINFOMD_SHDR. Points into
    /// the image.
    shdr_bytes: []const u8,
    /// Number of section headers, for sanity checks and messages.
    shnum: u16,
};

/// Parse just enough of a .ko to describe it to the kernel.
///
/// Deliberately strict. Every check here is a failure the loader can
/// report; the same failure at boot is a blank screen on a machine with
/// no console.
pub fn parseModule(image: []const u8) ParseError!ModuleElf {
    if (image.len < @sizeOf(Elf64_Ehdr)) return error.TooSmall;

    // NO POINTER CAST. The image is a byte slice read off a FAT
    // filesystem into whatever buffer the firmware gave us; it carries no
    // alignment guarantee. Casting to *const Elf64_Ehdr and dereferencing
    // is undefined behaviour on a misaligned buffer, and the test caught
    // it doing exactly that.
    //
    // On the bench this would be worse than a panic: a UEFI loader has no
    // bounds checks and no console, so a misaligned read is either silent
    // corruption or a fault with nothing to show for it. Copy the header
    // out byte-wise instead. It is 64 bytes, once, at boot.
    var ehdr: Elf64_Ehdr = undefined;
    @memcpy(std.mem.asBytes(&ehdr), image[0..@sizeOf(Elf64_Ehdr)]);

    // e_ident checks, in the order the ELF spec defines them.
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7fELF")) return error.NotElf;
    if (ehdr.e_ident[4] != 2) return error.NotElf64; // EI_CLASS = ELFCLASS64
    if (ehdr.e_ident[5] != 1) return error.NotLittleEndian; // EI_DATA = ELFDATA2LSB

    // A .ko is ET_REL. This matters: link_elf_obj.c is the "elf obj
    // module" class BECAUSE the module is a relocatable object, and the
    // kernel relocates it. Handing it an ET_EXEC would send it down the
    // wrong linker path.
    if (ehdr.e_type != ET_REL) return error.NotRelocatable;
    if (ehdr.e_machine != EM_X86_64) return error.WrongMachine;

    if (ehdr.e_shnum == 0) return error.NoSections;

    // Our Elf64_Shdr must agree with the file's own idea of a section
    // header's size. If it does not, every section we hand the kernel is
    // misaligned and the module is garbage. Check it rather than assume
    // it: this is the single most likely silent bug in this file.
    if (ehdr.e_shentsize != @sizeOf(Elf64_Shdr)) return error.BadShentsize;

    // The section-header table must lie wholly inside the image. A
    // truncated module caught here is a clear error; caught at boot it
    // is a blank screen.
    const shdr_bytes: usize = @as(usize, ehdr.e_shnum) * @as(usize, ehdr.e_shentsize);
    const shoff: usize = @intCast(ehdr.e_shoff);
    if (shoff > image.len) return error.ShdrOutOfBounds;
    if (shdr_bytes > image.len - shoff) return error.ShdrOutOfBounds;

    return .{
        .ehdr = ehdr,
        .shdr_bytes = image[shoff .. shoff + shdr_bytes],
        .shnum = ehdr.e_shnum,
    };
}

// ---------------------------------------------------------------------
// Tests
//
// These run against a REAL ELF relocatable object, built by the test
// harness, because this is exactly the code that looks obvious until it
// is not. A parser that is subtly wrong here produces a module the
// kernel rejects with EINVAL, on a machine with no console, which is the
// most expensive possible place to find out.

const testing = std.testing;

test "parseModule: accepts a real ELF64 relocatable object" {
    // A real ELF64 REL object, the same class as a .ko. Validated during
    // development against one produced by `zig cc -c`, which caught an
    // alignment bug: the original parser did
    // @ptrCast(@alignCast(image.ptr)) on a byte slice read off FAT, which
    // is undefined behaviour on a misaligned buffer. In a UEFI loader
    // with no bounds checks and no console that is either silent
    // corruption or a fault with nothing to show for it. The parser now
    // copies the header out byte-wise.
    const image = @embedFile("testdata/mod.o");

    const m = try parseModule(image);

    // The kernel's link_elf_obj checks nothing about e_type itself, but
    // it walks the section headers assuming a relocatable object. If this
    // is not ET_REL the module is not a .ko.
    try testing.expectEqual(ET_REL, m.ehdr.e_type);
    try testing.expectEqual(EM_X86_64, m.ehdr.e_machine);

    // The section-header table must be exactly shnum * shentsize bytes,
    // and that is what we hand the kernel as MODINFOMD_SHDR.
    try testing.expect(m.shnum > 0);
    try testing.expectEqual(
        @as(usize, m.shnum) * @as(usize, m.ehdr.e_shentsize),
        m.shdr_bytes.len,
    );

    // Elf64_Shdr must be 64 bytes, or our struct disagrees with the
    // file's e_shentsize and every section we hand the kernel is
    // misaligned. This is the single most likely silent bug in this file.
    try testing.expectEqual(@as(u16, 64), m.ehdr.e_shentsize);
    try testing.expectEqual(@as(usize, 64), @sizeOf(Elf64_Shdr));
}

test "parseModule: the section headers we extract are actually parseable" {
    const image = @embedFile("testdata/mod.o");
    const m = try parseModule(image);

    // Walk the table we are going to hand the kernel and check it makes
    // sense. If our shdr_bytes slice is off by even one section, the
    // section types here will be garbage.
    var seen_null = false;
    var seen_progbits = false;
    var i: usize = 0;
    while (i < m.shnum) : (i += 1) {
        var sh: Elf64_Shdr = undefined;
        const off = i * @sizeOf(Elf64_Shdr);
        @memcpy(std.mem.asBytes(&sh), m.shdr_bytes[off .. off + @sizeOf(Elf64_Shdr)]);
        // Section 0 is always SHT_NULL by the ELF spec. If we are
        // misaligned, this will not hold.
        if (i == 0) {
            try testing.expectEqual(@as(u32, 0), sh.sh_type);
            seen_null = true;
        }
        if (sh.sh_type == 1) seen_progbits = true; // SHT_PROGBITS
    }
    try testing.expect(seen_null);
    // A module with code must have at least one PROGBITS section.
    try testing.expect(seen_progbits);
}

test "parseModule: rejects what is not a module" {
    try testing.expectError(error.TooSmall, parseModule("short"));
    try testing.expectError(error.NotElf, parseModule(&[_]u8{0} ** 128));

    // A well-formed ELF that is not a relocatable object must be
    // refused: handing the kernel an ET_EXEC as an "elf obj module"
    // sends it down the wrong linker path.
    var e: Elf64_Ehdr = std.mem.zeroes(Elf64_Ehdr);
    var buf: [@sizeOf(Elf64_Ehdr)]u8 = undefined;
    @memcpy(e.e_ident[0..4], "\x7fELF");
    e.e_ident[4] = 2; // ELFCLASS64
    e.e_ident[5] = 1; // little endian
    e.e_type = 2; // ET_EXEC
    e.e_machine = EM_X86_64;
    e.e_shnum = 1;
    e.e_shentsize = 64;
    @memcpy(&buf, std.mem.asBytes(&e));
    try testing.expectError(error.NotRelocatable, parseModule(&buf));

    // And a truncated section-header table, which is the corruption most
    // likely to survive a bad copy to the ESP.
    e.e_type = ET_REL;
    e.e_shoff = 0xffff_ffff;
    @memcpy(&buf, std.mem.asBytes(&e));
    try testing.expectError(error.ShdrOutOfBounds, parseModule(&buf));
}
