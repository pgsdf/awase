# AD-56 kernel-entry ABI bridge document (in progress)

The compatibility bridge specification: what the loader passes and what
the PGSD kernel and drawfs actually consume, read from source on the
bench (/usr/src/sys). This is the BRIDGE (step 1 of the AD-56
Objective), to be measured down to its load-bearing subset by Phase 0.5
instrumentation and then replaced by an Awase-native contract. It is not
a contract to reproduce forever.

Status: the compatibility bridge is DOCUMENTED FROM SOURCE. Sections 1
(display), 2 (memory map), 3 (MI records), and 4 (preload blob format)
are read from code on the bench. This is NOT the same as the load-bearing
contract: source inspection and runtime behavior diverge (dead branches,
arch-specific paths, present-but-never-dereferenced fields). The actual
load-bearing subset remains to be MEASURED by Phase 0.5. Criterion 3 is
therefore "source reading complete"; the measured ABI is Phase 0.5's
output, and the minimal-handoff target (Phase 3a) derives from the
measured subset, not from this source reading.

## Metadata namespace structure (a fresh loader must produce both halves)

The handoff is not one flat list. It is two namespaces:

  - Machine-independent tags in sys/sys/linker.h (0x0001 to 0x0010):
    AOUTEXEC, ELFHDR, SSYM, ESYM, DYNAMIC, MB2HDR, ENVP (0x0006),
    HOWTO (0x0007), KERNEND (0x0008), SHDR, CTORS_ADDR/SIZE, FW_HANDLE,
    KEYBUF, FONT, SPLASH, SHTDWNSPLASH, plus the NOCOPY (0x8000) and
    DEPLIST flags.
  - Machine-dependent amd64 tags in sys/x86/include/metadata.h
    (0x1000+): SMAP (0x1001), SMAP_XATTR (0x1002), DTBP (0x1003),
    EFI_MAP (0x1004), EFI_FB (0x1005), MODULEP (0x1006), VBE_FB
    (0x1007), EFI_ARCH (0x1008).

The display handoff (EFI_FB) and the memory map (EFI_MAP) live in the
machine-dependent set. A fresh loader reproduces MI tags from linker.h
and MD tags from the arch metadata.h.

## Section 1: display / framebuffer handoff (COMPLETE from source)

Source: consumer is sys/dev/drawfs/drawfs_efifb.c (drawfs_efifb_init);
struct is sys/x86/include/metadata.h. This is the AD-4 seam: exactly
where Awase consumes the loader-provided GOP metadata today.

### The record the loader must populate

MODINFOMD_EFI_FB (0x1005), carrying struct efi_fb:

    struct efi_fb {
        uint64_t fb_addr;          /* physical base of the GOP linear fb */
        uint64_t fb_size;          /* total bytes (see note: NOT used by drawfs) */
        uint32_t fb_height;
        uint32_t fb_width;
        uint32_t fb_stride;        /* PIXELS per scanline (see note) */
        uint32_t fb_mask_red;
        uint32_t fb_mask_green;
        uint32_t fb_mask_blue;
        uint32_t fb_mask_reserved;
    };

### What drawfs actually consumes (the load-bearing subset)

drawfs_efifb_init reads, from the record:
  - fb_addr   -> the physical framebuffer base (mapped write-combining)
  - fb_width  -> geometry
  - fb_height -> geometry
  - fb_stride -> scanline length, treated as PIXELS
  - fb_mask_red, fb_mask_green, fb_mask_blue, fb_mask_reserved -> used
    only to DERIVE depth: depth = roundup(fls(red|green|blue|reserved),
    8), default 32 if zero.

drawfs does NOT read fb_size from the record; it COMPUTES size as
fb_height * (byte stride). So the loader-supplied fields drawfs depends
on are nine: fb_addr, fb_width, fb_height, fb_stride, and the four
masks. fb_size in the struct is dead as far as drawfs is concerned
(other consumers may read it; Phase 0.5 confirms).

### Critical unit convention (a fresh-loader landmine)

drawfs treats efi_fb.fb_stride as PIXELS per scanline and converts to
bytes itself: fb_stride_bytes = efi_fb.fb_stride * (depth / 8). A fresh
loader MUST populate fb_stride in pixels, not bytes. Bytes here would
shear every scanline (diagonal corruption), the classic framebuffer
handoff bug.

### How the record is found (format constraint)

drawfs locates it via:
    kmdp = preload_search_by_type("elf kernel")   /* or "elf64 kernel" */
    efifb = preload_search_info(kmdp,
                MODINFO_METADATA | MODINFOMD_EFI_FB)

So the fresh loader must produce a preload metadata blob walkable by the
kernel's preload_search_* (Section 4), containing a kernel module typed
"elf kernel" with an EFI_FB metadata record attached.

### The display contract, stated minimally

A fresh loader makes drawfs work by producing: a preload blob the kernel
can walk, a kernel module record typed "elf kernel", and one EFI_FB
record with fb_addr (phys base), fb_width, fb_height, fb_stride (in
PIXELS), and the four channel masks. Nine values. The same data drives
the memory map and the rest of the kernel separately (Sections 2 to 4).

## Section 2: memory map handoff (COMPLETE from source)

Source: sys/amd64/amd64/machdep.c, native_parse_memmap (the fetch) and
add_efi_map_entries at line 725 (the walk). This is the
highest-criticality handoff after the kernel image: get it wrong and the
kernel panics before init.

### The record the loader must populate

MODINFOMD_EFI_MAP (0x1004), carrying struct efi_map_header followed by
the raw UEFI memory descriptors:

    struct efi_map_header {
        uint64_t memory_size;       /* total bytes of descriptors that follow */
        uint64_t descriptor_size;   /* size of each EFI_MEMORY_DESCRIPTOR */
        uint32_t descriptor_version;/* currently 1 */
    };
    /* immediately followed, at 16-byte alignment, by the descriptor
       array: the verbatim output of UEFI GetMemoryMap. */

### How the kernel consumes it

native_parse_memmap fetches the record the same way drawfs fetches
EFI_FB:
    efihdr = preload_search_info(preload_kmdp,
                 MODINFO_METADATA | MODINFOMD_EFI_MAP)
    smap   = preload_search_info(preload_kmdp,
                 MODINFO_METADATA | MODINFOMD_SMAP)

add_efi_map_entries then:
  - computes the descriptor array start as
    (header + ((sizeof(header) + 0xf) & ~0xf)), i.e. 16-byte aligned
    after the header,
  - computes count as memory_size / descriptor_size,
  - strides with descriptor_size (NOT sizeof(struct efi_md)), so the
    loader's stated descriptor_size is authoritative and tolerates UEFI
    revisions that extend the descriptor,
  - admits into physmap only descriptors of type LoaderCode/LoaderData
    (CODE/DATA), ConventionalMemory (FREE), and reclaimable
    BootServices code/data; everything else (reserved, MMIO, ACPI,
    runtime services) is skipped.

So the loader hands over UEFI's GetMemoryMap output VERBATIM, correctly
framed by the header; the kernel filters. The loader does not curate the
map.

### THE hard floor of the entire handoff

native_parse_memmap:
    if (efihdr == NULL && smap == NULL)
        panic("No BIOS smap or EFI map info from loader!");

If a fresh loader provides neither an EFI_MAP nor a legacy SMAP record,
the kernel panics in early init. This is the single most important
record to get right. Section 1 (display) wrong = sheared screen,
recoverable. Section 2 (memory map) wrong or absent = panic before init,
unbootable bench. This is why the design's Phase 3a gate is "minimal
handoff reaches init": reaching init IS getting the memory map right.

## Section 3: machine-independent records (COMPLETE from source)

Source: sys/amd64/amd64/machdep.c hammer_time, lines 1151-1152.

The small MI records are read with the MD_FETCH macro, a TYPED wrapper
over the same preload_search_info walk that returns and dereferences the
record as a given type:

    boothowto = MD_FETCH(preload_kmdp, MODINFOMD_HOWTO, int);
    envp      = MD_FETCH(preload_kmdp, MODINFOMD_ENVP, char *);

So, distinct from EFI_FB / EFI_MAP (which are fetched as POINTERS to
structs the loader laid down):
  - MODINFOMD_HOWTO (0x0007) is fetched as an int: the boothowto flags
    (single/multi user, verbose, etc.). The loader emits it as an
    int-sized record.
  - MODINFOMD_ENVP (0x0006) is fetched as a char *: a pointer to the
    kernel environment string block the loader also loaded. The loader
    emits it as a pointer record into that block.

MODINFOMD_KERNEND (0x0008) is required but is NOT read in hammer_time's
main C body; it is consumed earlier in the early-boot path (locore /
pmap bootstrap) because it bounds the kernel image itself. Its exact
read site is a Phase 0.5 instrumentation target rather than a source
read here; for the bridge it is a required MI record the loader must
emit (end-of-kernel address).

The grep also confirmed every other handoff (EFI_MAP at 832/1674, SMAP
at 1643, EFI_ARCH at 1691, EFI boot record at 1312) flows through the
same preload_search_info walk: the entire ABI is one uniform mechanism.

## Section 4: preload blob format (COMPLETE from source)

Source: sys/kern/subr_module.c. preload_search_by_type (97),
preload_search_info (174), preload_fetch_addr/size (268/279).

The blob is a flat, contiguous sequence of length-prefixed records. Each
record is:
    uint32_t hdr[0]   /* type tag */
    uint32_t hdr[1]   /* size of the data that follows */
    data...           /* hdr[1] bytes, then advanced to the next record
                         (aligned) */

The walk matches hdr[0] against the tag constants:
  - MODINFO_NAME delimits the start of each module's records.
  - MODINFO_TYPE identifies the module (the "elf kernel" / "elf64
    kernel" string drawfs and the kernel match on).
  - MODINFO_ADDR, MODINFO_SIZE give the module load address and size
    (preload_fetch_addr/size read these).
  - MODINFO_METADATA | <subtype> carries a metadata record; the subtype
    is an MI tag (linker.h) or an MD tag (metadata.h) such as
    MODINFOMD_EFI_FB or MODINFOMD_EFI_MAP. preload_search_info walks a
    given module's records and returns the data pointer for a requested
    (MODINFO_METADATA | subtype).

So a fresh loader emits: a contiguous blob of (type, size, data)
records; one module section per loaded object delimited by MODINFO_NAME,
the kernel typed via MODINFO_TYPE = "elf kernel", with MODINFO_ADDR /
MODINFO_SIZE and the MODINFO_METADATA records (EFI_MAP, EFI_FB, ENVP,
HOWTO, KERNEND, ...) attached. The kernel and drawfs find everything
through this one uniform walk. subr_module.c around 420 (the
sbuf_cat switch, including the MODINFOMD_EFI_FB case) is only the
name-printing for kldstat -v, not consumption.

## Record classification (source reading; measurement pending)

The four-way distinction that matters for Phase 3a. These columns are
NOT the same question, and the document keeps them separate:

  - REQUIRED: boot fails (panics or wedges) without it.
  - OPTIONAL: boot reaches init without it; a subsystem may degrade.
  - CONSUMED: the kernel or a driver reads it at least once.
  - EMITTED-BUT-IGNORED: the loader provides it; nothing dereferences it.

Source-reading verdicts (PROVISIONAL until Phase 0.5 measures them):

  - MODINFOMD_EFI_MAP / SMAP: REQUIRED and CONSUMED. native_parse_memmap
    panics if both are absent. The mandatory record.
  - the "elf kernel" module record (MODINFO_TYPE/ADDR/SIZE): REQUIRED.
    Without the kernel image record there is nothing to run.
  - MODINFOMD_ENVP, MODINFOMD_HOWTO: CONSUMED (hammer_time, MD_FETCH).
    Required-vs-optional UNVERIFIED: the kernel likely tolerates empty
    env / zero howto, so probably OPTIONAL-but-consumed. Phase 0.5
    confirms.
  - MODINFOMD_KERNEND: CONSUMED (early boot, outside hammer_time main
    body). Required-vs-optional UNVERIFIED.
  - MODINFOMD_EFI_FB: CONSUMED BY DRAWFS, and almost certainly OPTIONAL
    for boot-to-init: drawfs_efifb_init returns ENODEV when it is
    absent, it does not panic; the kernel reaches init without a
    display. If Phase 0.5 confirms EFI_FB is optional-for-init, the
    Phase 3a minimal handoff does NOT need it, and the first bootable
    fresh loader is dramatically smaller than the full bridge.
  - within EFI_FB, fb_size is EMITTED-BUT-IGNORED by drawfs (computed,
    not read); fb_mask_reserved is read only into the depth fls union.
    Other consumers may differ; Phase 0.5 measures.
  - MODINFOMD_VBE_FB, MODINFOMD_EFI_ARCH, DTBP, SMAP_XATTR: present in
    the vocabulary, consumption on this bench UNVERIFIED; likely
    EMITTED-BUT-IGNORED or arch/platform-conditional.

The point of the table: a faithful bridge reproduces everything EMITTED.
The Phase 3a minimal handoff needs only what is REQUIRED. Phase 0.5
turns the PROVISIONAL verdicts above into measured ones, and the gap
between "REQUIRED" and "EMITTED" is how much smaller the minimal handoff
(and ultimately the Awase-native contract) can be.

## What a fresh loader emits to cross the full bridge

(The conservative superset, before measurement narrows it.)

  - a preload blob of (type, size, data) records (Section 4),
  - one module typed "elf kernel" with MODINFO_ADDR / MODINFO_SIZE,
  - MODINFOMD_EFI_MAP: struct efi_map_header + verbatim UEFI descriptors
    (Section 2) -- REQUIRED,
  - MODINFOMD_EFI_FB: struct efi_fb, fb_stride in PIXELS (Section 1) --
    consumed by drawfs, provisionally optional for init,
  - MODINFOMD_HOWTO (int), MODINFOMD_ENVP (char *), MODINFOMD_KERNEND
    (Section 3) -- consumed; required-vs-optional pending measurement.

The loader-side producer (stand/efi, stand/common bi_load*) can be read
to cross-check the emit side, but that is optional confirmation, not a
gate.

## Note for Phase 0.5

Section 1 already shows the value of measuring over assuming: drawfs
ignores fb_size and derives bpp rather than reading a bpp field, so a
faithful reproduction of "everything the loader emits" would carry dead
data. Phase 0.5 instrumentation confirms, per record, parsed-and-used
versus present-but-dead, and the Awase-native contract carries only the
load-bearing subset.
