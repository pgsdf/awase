# ADR 0006: Module preloading

## Status

**Accepted. Ratified 2026-07-13 (operator).** Implementation in
progress.

Ratified with one addition from the operator: **zfs.ko is part of the
attested BAS slot, not a side file.** The reasoning is that once the
loader is responsible for preloading a module, there is no meaningful
distinction between the kernel image and the module: both execute with
kernel privilege before the system is up, and attesting one but not the
other weakens the trust model for almost no gain. deploy.sh therefore
constructs a complete boot slot (kernel, zfs.ko, manifest, hashes
covering both) and the loader consumes a complete boot slot. There are
no external dependencies and no special cases.

## 1. Context

pgsd-loader cannot load modules. It builds a module chain containing
exactly one entry, the kernel, and has no concept of a `.ko` file. This
was recorded as a gap (campaign finding F14) and then became the
blocker.

**F15: the bench cannot boot.** `/boot/loader.conf` carries
`zfs_load="YES"`. ZFS is a module: it is not compiled into the PGSD
kernel, and it is not compiled into GENERIC either. FreeBSD ships it as
a module and the stock loader preloads it. So on an armed boot the
kernel starts, probes devices, tries to mount `zfs:zroot/ROOT/default`,
has no ZFS support at all, cannot mount root, and drops to the
`mountroot>` prompt. With no console (AD-39 removed vt, vt_efifb, sc and
vga so drawfs could own the framebuffer), that prompt is invisible and
the machine shows a blank screen.

There is no way around this from userspace. The module must be in memory
BEFORE the kernel looks for root; you cannot kldload your way to a root
filesystem you cannot mount.

So module preloading is not a convenience. It is the difference between
a loader and a kernel-jumper, and it is on the critical path.

## 2. What the kernel actually requires

This is smaller than it looks, and the size is the reason this ADR
recommends doing it rather than working around it.

**The kernel links preloaded modules itself.** `kern_linker.c`
`linker_preload()` walks the preloaded files and calls
`LINKER_LINK_PRELOAD`, and `link_elf_obj.c` `link_elf_link_preload()`
does the ELF work: section placement, symbol resolution, relocation. The
loader does NOT relocate anything. It places the raw `.ko` bytes in
memory and describes them.

`link_elf_link_preload()` states the contract exactly:

    modptr  = preload_search_by_name(filename);
    type    = preload_search_info(modptr, MODINFO_TYPE);
    baseptr = preload_search_info(modptr, MODINFO_ADDR);
    sizeptr = preload_search_info(modptr, MODINFO_SIZE);
    hdr     = preload_search_info(modptr, MODINFO_METADATA|MODINFOMD_ELFHDR);
    shdr    = preload_search_info(modptr, MODINFO_METADATA|MODINFOMD_SHDR);
    if (type == NULL || strcmp(type, preload_modtype_obj) != 0)
            return (EFTYPE);
    if (baseptr == NULL || sizeptr == NULL || hdr == NULL || shdr == NULL)
            return (EINVAL);

So each preloaded module needs six records:

    MODINFO_NAME      0x0001   the module name, e.g. "zfs.ko"
    MODINFO_TYPE      0x0002   "elf obj module"  (sys/sys/linker.h:
                               MODTYPE_OBJ; subr_module.c defines
                               preload_modtype_obj from it)
    MODINFO_ADDR      0x0003   where the .ko bytes are, physical
    MODINFO_SIZE      0x0004   how many bytes
    MODINFOMD_ELFHDR  0x8002   a COPY of the Elf64_Ehdr
    MODINFOMD_SHDR    0x8009   a COPY of the section-header table

The two metadata records are the part that is easy to miss. The kernel
does not re-read the ELF header out of the module image; it reads the
copies the loader passed. `stand/common/load_elf_obj.c` does exactly
this (`file_addmetadata(fp, MODINFOMD_ELFHDR, sizeof(*hdr), hdr)` and
`file_addmetadata(fp, MODINFOMD_SHDR, shdrbytes, shdr)`), and it is the
recipe to follow.

## 3. Decision

pgsd-loader preloads modules.

**Which modules.** Only what the boot requires, named explicitly. NOT a
loader.conf parser.

    zfs.ko      required: the root filesystem is ZFS.

That is the whole list today, and the list should stay short by
construction. inputfs and audiofs do NOT belong here: both load from
rc.d after root mounts, and inputfs positively must not be preloaded
(install.sh: "the state kthread panics when loaded before /var/run is
mounted"). drawfs no longer belongs here either: it is compiled into the
kernel (drawfs ADR 0001 amendment), because the framebuffer owner is a
bootstrap dependency.

**Where the modules come from.** The ESP, staged by `deploy.sh` beside
the kernel, exactly as the kernel image already is. The loader can read
the ESP; it cannot read a ZFS root, which is the whole problem, so the
module cannot live there.

**What the loader does.**

  1. Read `zfs.ko` from the ESP into memory below 4GiB (the trampoline
     and staging constraints already in force).
  2. Parse just enough ELF to copy out the `Elf64_Ehdr` and the
     section-header table. No relocation, no symbol work: the kernel
     does that.
  3. Append a second module entry to the chain after the kernel, with
     the six records above.
  4. Extend `kernend` past the module image and its metadata, so the
     kernel does not allocate over it.

**What the loader does NOT do.**

  - It does not parse `/boot/loader.conf`. It cannot read the root
    filesystem, and a config parser is a second source of truth about
    what the boot needs. The module list is compiled in, and adding to
    it is a deliberate act.
  - It does not relocate or link. The kernel does that, and doing it in
    the loader would duplicate `link_elf_obj.c` for no benefit.
  - It does not load modules that rc.d can load. If a module can wait
    for root, it waits for root.

## 4. Alternatives rejected

**Compile ZFS into the kernel.** It would work. But it means building
OpenZFS into every PGSD kernel, and the same trap waits for the next
thing that needs a preload: the answer becomes a growing list of
exceptions rather than a capability. It is a way of not writing a
loader.

**A UFS root.** Sidesteps ZFS and fights the rest of the stack (boot
environments, snapshots, the reinstall runsheet). Solves nothing
general.

## 5. Consequences

  - pgsd-loader becomes a loader. This is the point.
  - `deploy.sh stage` copies `zfs.ko` to the ESP alongside the kernel.
  - The module chain gains a second entry, so `buildChainFull` becomes
    `buildChain(kernel, modules[])`.
  - `kernend` computation changes: it must account for every preloaded
    module image and its metadata, not just the kernel.
  - A new failure mode exists and must fail loudly: a module named in
    the list but missing from the ESP. Fail closed at stage time, not at
    boot, because a boot-time failure is a blank screen.

## 6. Bench requirements

1. The armed transfer boots to a login. The kernel mounts
   `zfs:zroot/ROOT/default`, so zfs.ko was preloaded and linked.
2. `kldstat` on the booted system shows `zfs.ko` loaded.
3. The bench answers on the network during and after the armed boot.
   This is stated as a requirement because five metal attempts were
   diagnosed from a blank screen and one NVRAM marker, and a single ping
   would have bounded the fault immediately each time. A console-less
   machine must be observable by some means, and the network is the
   means available.
4. `stage` refuses, loudly, if a required module is missing from the
   build.
