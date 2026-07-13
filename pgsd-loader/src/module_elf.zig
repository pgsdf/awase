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

// ---------------------------------------------------------------------
// F16: laying out a module's sections.
//
// The first cut of ADR 0006 believed the loader could copy a .ko's raw
// file bytes into memory, hand the kernel the file's own section table,
// and let the kernel do the rest. That is wrong, and it cost a metal
// attempt to find out.
//
// link_elf_obj.c link_elf_link_preload() says so in its own comment:
//
//     /* XXX, relocate the sh_addr fields saved by the loader. */
//     off = 0;
//     for (i = 0; i < hdr->e_shnum; i++)
//             if (shdr[i].sh_addr != 0 && (off == 0 || shdr[i].sh_addr < off))
//                     off = shdr[i].sh_addr;
//     for (i = 0; i < hdr->e_shnum; i++)
//             if (shdr[i].sh_addr != 0)
//                     shdr[i].sh_addr = shdr[i].sh_addr - off + (Elf_Addr)ef->address;
//
// "SAVED BY THE LOADER". The kernel takes the lowest non-zero sh_addr as
// a base and REBASES the sections onto MODINFO_ADDR. It does not assign
// addresses. It relocates addresses the loader already assigned.
//
// A .ko off disk is ET_REL, and every sh_addr in it is ZERO, because
// relocatable objects have no assigned addresses. So passing the raw
// table means: off stays 0, the rebase loop never fires, every section
// keeps sh_addr == 0, and the kernel's own checks (link_elf_obj.c:
// `if (shdr[i].sh_addr == 0)`) reject them.
//
// So MODINFO_ADDR is not "where the file is". It is the base of a
// LAID-OUT SECTION IMAGE that the loader must construct. The file image
// and the loaded image are different things.
//
// This mirrors stand/common/load_elf_obj.c, which lays out in five
// passes and then copies. The order matters: it determines the addresses,
// and the kernel rebases relative to the LOWEST of them.

pub const SHT_PROGBITS: u32 = 1;
pub const SHT_SYMTAB: u32 = 2;
pub const SHT_STRTAB: u32 = 3;
pub const SHT_RELA: u32 = 4;
pub const SHT_NOBITS: u32 = 8;
pub const SHT_REL: u32 = 9;
pub const SHT_INIT_ARRAY: u32 = 14;
pub const SHT_FINI_ARRAY: u32 = 15;
/// SHT_X86_64_UNWIND. The reference lays this out with the other
/// allocatable sections on amd64, so we must too.
pub const SHT_X86_64_UNWIND: u32 = 0x7000_0001;

pub const SHF_ALLOC: u64 = 0x2;

pub const LayoutError = ParseError || error{
    /// The reference refuses a module without exactly one SHT_SYMTAB:
    /// "file has no valid symbol table". So do we.
    NoSymbolTable,
    /// symtab's sh_link must point at a SHT_STRTAB.
    BadSymbolStrings,
    /// e_shstrndx must point at a SHT_STRTAB.
    NoSectionNames,
    /// A section's bytes lie outside the file.
    SectionOutOfBounds,
    /// The laid-out image does not fit the destination.
    LayoutTooLarge,
};

pub const LaidOut = struct {
    /// The ELF header, to pass as MODINFOMD_ELFHDR.
    ehdr: Elf64_Ehdr,
    /// The MODIFIED section table, with sh_addr filled in. This is what
    /// goes to the kernel as MODINFOMD_SHDR, and it is the whole point:
    /// the file's own table has sh_addr == 0 everywhere.
    shdr_bytes: []u8,
    /// Total bytes of the laid-out image, from the load address.
    size: usize,
    shnum: u16,
};

/// Lay out a module's sections into `dest`, at load address `load_addr`,
/// and produce the modified section table.
///
/// `dest` is where the bytes go NOW (in staging). `load_addr` is the
/// address the kernel will see them at (the destination address space).
/// They differ, and conflating them is how the sections end up pointing
/// at the wrong memory.
///
/// `shdr_out` receives the modified section table. It must outlive the
/// chain, since the chain records point at it.
pub fn layoutModule(
    image: []const u8,
    dest: []u8,
    load_addr: u64,
    shdr_out: []u8,
) LayoutError!LaidOut {
    const parsed = try parseModule(image);
    const shnum: usize = parsed.shnum;
    const shsize = @sizeOf(Elf64_Shdr);

    if (shdr_out.len < shnum * shsize) return error.LayoutTooLarge;

    // Work on a COPY of the section table. The file's table is const and
    // its sh_addr fields are all zero; we are producing a new one.
    @memcpy(shdr_out[0 .. shnum * shsize], parsed.shdr_bytes);

    const sh = struct {
        fn get(buf: []u8, i: usize) Elf64_Shdr {
            var out: Elf64_Shdr = undefined;
            @memcpy(std.mem.asBytes(&out), buf[i * @sizeOf(Elf64_Shdr) ..][0..@sizeOf(Elf64_Shdr)]);
            return out;
        }
        fn set(buf: []u8, i: usize, v: Elf64_Shdr) void {
            @memcpy(buf[i * @sizeOf(Elf64_Shdr) ..][0..@sizeOf(Elf64_Shdr)], std.mem.asBytes(&v));
        }
    };

    // Pass 0: zero every sh_addr. The reference does this explicitly, and
    // it matters: a nonzero sh_addr on a section we do NOT lay out would
    // be rebased by the kernel into nonsense.
    var i: usize = 0;
    while (i < shnum) : (i += 1) {
        var s = sh.get(shdr_out, i);
        s.sh_addr = 0;
        sh.set(shdr_out, i, s);
    }

    // The layout starts AT the load address. sh_addr values are absolute
    // addresses, not offsets: "We store the load address as a non-zero
    // sh_addr value" (load_elf_obj.c).
    var lastaddr: u64 = load_addr;

    // Pass 1: code, data, bss. The allocatable sections, in section
    // order, each rounded up to its own alignment.
    i = 0;
    while (i < shnum) : (i += 1) {
        var s = sh.get(shdr_out, i);
        if (s.sh_size == 0) continue;
        switch (s.sh_type) {
            SHT_PROGBITS, SHT_NOBITS, SHT_X86_64_UNWIND, SHT_INIT_ARRAY, SHT_FINI_ARRAY => {
                if ((s.sh_flags & SHF_ALLOC) == 0) continue;
                lastaddr = std.mem.alignForward(u64, lastaddr, @max(1, s.sh_addralign));
                s.sh_addr = lastaddr;
                lastaddr += s.sh_size;
                sh.set(shdr_out, i, s);
            },
            else => {},
        }
    }

    // Pass 2: the symbol table. The reference requires EXACTLY one and
    // refuses the module otherwise ("file has no valid symbol table"),
    // because link_elf_obj needs it to resolve symbols.
    var symtabindex: ?usize = null;
    i = 0;
    while (i < shnum) : (i += 1) {
        if (sh.get(shdr_out, i).sh_type == SHT_SYMTAB) {
            if (symtabindex != null) return error.NoSymbolTable; // more than one
            symtabindex = i;
        }
    }
    const symtab = symtabindex orelse return error.NoSymbolTable;
    {
        var s = sh.get(shdr_out, symtab);
        lastaddr = std.mem.alignForward(u64, lastaddr, @max(1, s.sh_addralign));
        s.sh_addr = lastaddr;
        lastaddr += s.sh_size;
        sh.set(shdr_out, symtab, s);
    }

    // Pass 3: the symbol strings, which are symtab's sh_link.
    const symstr: usize = sh.get(shdr_out, symtab).sh_link;
    if (symstr == 0 or symstr >= shnum or
        sh.get(shdr_out, symstr).sh_type != SHT_STRTAB) return error.BadSymbolStrings;
    {
        var s = sh.get(shdr_out, symstr);
        lastaddr = std.mem.alignForward(u64, lastaddr, @max(1, s.sh_addralign));
        s.sh_addr = lastaddr;
        lastaddr += s.sh_size;
        sh.set(shdr_out, symstr, s);
    }

    // Pass 4: the section names.
    const shstr: usize = parsed.ehdr.e_shstrndx;
    if (shstr == 0 or shstr >= shnum or
        sh.get(shdr_out, shstr).sh_type != SHT_STRTAB) return error.NoSectionNames;
    {
        var s = sh.get(shdr_out, shstr);
        lastaddr = std.mem.alignForward(u64, lastaddr, @max(1, s.sh_addralign));
        s.sh_addr = lastaddr;
        lastaddr += s.sh_size;
        sh.set(shdr_out, shstr, s);
    }

    // Pass 5: the relocation tables, but ONLY those whose target section
    // is allocatable. The kernel needs them to relocate the module, and
    // a reloc table for a non-allocated section relocates nothing.
    i = 0;
    while (i < shnum) : (i += 1) {
        var s = sh.get(shdr_out, i);
        switch (s.sh_type) {
            SHT_REL, SHT_RELA => {
                if (s.sh_info >= shnum) continue;
                if ((sh.get(shdr_out, s.sh_info).sh_flags & SHF_ALLOC) == 0) continue;
                lastaddr = std.mem.alignForward(u64, lastaddr, @max(1, s.sh_addralign));
                s.sh_addr = lastaddr;
                lastaddr += s.sh_size;
                sh.set(shdr_out, i, s);
            },
            else => {},
        }
    }

    const total: usize = @intCast(lastaddr - load_addr);
    if (total > dest.len) return error.LayoutTooLarge;

    // Clear the whole area, INCLUDING the bss regions. The reference does
    // this in one bzero before copying, which is why NOBITS sections need
    // no further work: they are laid out, and they are already zero.
    @memset(dest[0..total], 0);

    // Copy every section that has an address and actually has bytes in the
    // file. NOBITS has no file content; it is bss and stays zeroed.
    i = 0;
    while (i < shnum) : (i += 1) {
        const s = sh.get(shdr_out, i);
        if (s.sh_addr == 0) continue;
        if (s.sh_type == SHT_NOBITS) continue;
        if (s.sh_size == 0) continue;

        const off: usize = @intCast(s.sh_offset);
        const sz: usize = @intCast(s.sh_size);
        if (off > image.len or sz > image.len - off) return error.SectionOutOfBounds;

        const dst_off: usize = @intCast(s.sh_addr - load_addr);
        @memcpy(dest[dst_off .. dst_off + sz], image[off .. off + sz]);
    }

    return .{
        .ehdr = parsed.ehdr,
        .shdr_bytes = shdr_out[0 .. shnum * shsize],
        .size = total,
        .shnum = parsed.shnum,
    };
}

test "layoutModule: assigns sh_addr, copies PROGBITS, zeroes NOBITS" {
    const image = @embedFile("testdata/mod.o");

    var dest: [64 * 1024]u8 = undefined;
    var shdr_out: [64 * 64]u8 = undefined;
    const load_addr: u64 = 0x1c01000;

    const lo = try layoutModule(image, &dest, load_addr, &shdr_out);

    try testing.expect(lo.size > 0);
    try testing.expectEqual(@as(u16, 21), lo.shnum); // known for this object

    // THE ASSERTION THAT MATTERS. At least one section must have a
    // nonzero sh_addr, or the kernel's rebase loop never fires and every
    // section stays at address zero, which is exactly the bug F16 found.
    var nonzero: usize = 0;
    var lowest: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < lo.shnum) : (i += 1) {
        var s: Elf64_Shdr = undefined;
        @memcpy(std.mem.asBytes(&s), lo.shdr_bytes[i * @sizeOf(Elf64_Shdr) ..][0..@sizeOf(Elf64_Shdr)]);
        if (s.sh_addr != 0) {
            nonzero += 1;
            if (s.sh_addr < lowest) lowest = s.sh_addr;
            // Every assigned address is within the laid-out image.
            try testing.expect(s.sh_addr >= load_addr);
            try testing.expect(s.sh_addr + s.sh_size <= load_addr + lo.size);
            // And honours the section's own alignment.
            if (s.sh_addralign > 1) {
                try testing.expectEqual(@as(u64, 0), s.sh_addr % s.sh_addralign);
            }
        }
    }
    try testing.expect(nonzero > 0);

    // The kernel rebases relative to the LOWEST nonzero sh_addr, so that
    // must be the load address itself, or every section shifts.
    try testing.expectEqual(load_addr, lowest);
}

test "layoutModule: a module with no symbol table is refused" {
    // The reference refuses this outright ("file has no valid symbol
    // table"), because link_elf_obj cannot resolve symbols without one.
    // Better to refuse in the loader, where there is still a console.
    var buf: [@sizeOf(Elf64_Ehdr) + 2 * @sizeOf(Elf64_Shdr)]u8 = undefined;
    var e: Elf64_Ehdr = std.mem.zeroes(Elf64_Ehdr);
    @memcpy(e.e_ident[0..4], "\x7fELF");
    e.e_ident[4] = 2;
    e.e_ident[5] = 1;
    e.e_type = ET_REL;
    e.e_machine = EM_X86_64;
    e.e_shoff = @sizeOf(Elf64_Ehdr);
    e.e_shnum = 2;
    e.e_shentsize = @sizeOf(Elf64_Shdr);
    e.e_shstrndx = 1;
    @memcpy(buf[0..@sizeOf(Elf64_Ehdr)], std.mem.asBytes(&e));
    @memset(buf[@sizeOf(Elf64_Ehdr)..], 0);

    var dest: [4096]u8 = undefined;
    var shdr_out: [2 * 64]u8 = undefined;
    try testing.expectError(
        error.NoSymbolTable,
        layoutModule(&buf, &dest, 0x1000, &shdr_out),
    );
}
