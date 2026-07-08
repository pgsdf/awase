# KERNEL-HANDOFF: the amd64 EFI kernel handoff contract

L3a.1 deliverable (ADR 0004 Decision 1). The contract an
implementation must satisfy to start a FreeBSD amd64 kernel from
UEFI. Organized by the kernel's required contracts, with source
as evidence for each; the source is not the outline.

Status: draft 1, 2026-07-08. Corroborated against FreeBSD main
branch sources (stand/efi/loader/bootinfo.c read in full;
stand/efi/loader/arch/amd64/elf64_freebsd.c and amd64_tramp.S
via their defining commits, notably f75caed644a5). The anchor of
record is the bench /usr/src (15.1-RELEASE n283562, matching the
running kernel); a verification pass against it is listed at the
end and is required before L3a.2 review uses this document.

Every claim is tagged:
- REQUIRED: the kernel depends on it; omission breaks boot or
  corrupts state.
- OBSERVED: what stock loader.efi does; may be incidental. An
  implementation may differ if the REQUIRED items still hold.
- VERIFY: believed true, confirmed only by the bench pass or an
  L3a.2 experiment.

## 1. Kernel image contract

1.1 REQUIRED. The kernel is ELF64 (EM_X86_64, ET_EXEC), loaded
by PT_LOAD program headers: each segment's file bytes placed at
its p_paddr-derived physical location within the staging region,
p_memsz zero-fill beyond p_filesz. Evidence:
stand/common/load_elf.c (__elfN(loadimage)); the stock loader
uses the shared ELF loader for the kernel file.

1.2 REQUIRED. No relocation processing is performed on the
kernel executable itself: the amd64 kernel links at its virtual
address (KERNBASE region) and physical placement is handled by
paging, not relocation. Evidence: elf64_exec builds page tables
mapping the kernel's linked VA to the staging PA (contract 5)
rather than relocating.

1.3 REQUIRED (placement, version-dependent). Two regimes exist,
selected by copy_staging (stand/efi/loader/copy.c,
COPY_STAGING_AUTO default in main):
- copy regime: kernel staged anywhere below 1 GiB, and the
  trampoline copies the staging area to physical 2 MiB before
  entry; the kernel assumes it runs from 2 MiB.
- no-copy regime: kernels whose ELF exports symbol "kernphys"
  of size 8 (is_kernphys_relocatable(), stand/common/load_elf.c)
  are physically relocatable; staging stays below 4 GiB and no
  copy occurs; page tables map KERNBASE to the actual staging
  base.
VERIFY on bench: 15.1's default and the running kernel's
kernphys presence (nm /boot/kernel/kernel | grep kernphys). The
PGSD loader must implement at least one regime correctly and
must detect which the target kernel supports (REQUIRED); which
to prefer is an L3a.2 decision informed by the bench.

1.4 REQUIRED. The entry point is ehdr->e_entry, a virtual
address in the kernel's linked range; control transfer is
through the trampoline with paging already mapping it
(contract 5).

## 2. Boot metadata contract

The kernel locates everything through one physical pointer,
modulep, using sys/sys/linker.h preload conventions
(preload_search_by_type and friends, consumed by
sys/amd64/amd64/machdep.c hammer_time and getmemsize).

2.1 REQUIRED. The metadata block is a MODINFO chain: for each
preloaded file, records of {uint32 type, uint32 size, payload}
with payloads rounded up to 8 bytes (sizeof u_long). Per file,
MODINFO_NAME must come first (bi_copymodules comment: "This must
come first"), then MODINFO_TYPE; MODINFO_ARGS if present;
MODINFO_ADDR (u64 load address); MODINFO_SIZE (u64);
then each MODINFO_METADATA | MODINFOMD_* record. The chain ends
with MODINFO_END (type MODINFO_END, size 0). The kernel file's
type string is "elf kernel" (OBSERVED in main after commit
707136024fcc removed "elf64 kernel"; 15.1 accepts either,
VERIFY which bi_load emits on 15.1).

2.2 REQUIRED metadata on the kernel file entry (evidence:
bi_load, stand/efi/loader/bootinfo.c; consumption:
machdep.c/pmap.c):
- MODINFOMD_HOWTO (int): boothowto flags. Constructed from
  kernel args, boot_env_to_howto(), and console variables
  (OBSERVED construction; the int itself REQUIRED).
- MODINFOMD_ENVP (u64): physical address of the environment
  block, "name=value\\0"... terminated by an empty string
  (double NUL). The kernel's static environment comes from
  here (init_static_kenv).
- MODINFOMD_KERNEND (u64): physical end of everything preloaded
  including the metadata itself, page-rounded; hammer_time's
  physfree derives from it. bi_load computes it by a sizing
  pass (bi_copymodules with addr 0), then patches the value
  into the already-added metadata record before the real copy.
  An implementation must reproduce this two-pass or otherwise
  self-consistent behavior: the chain contains its own end
  address (REQUIRED).
- MODINFOMD_FW_HANDLE (u64): the EFI system table pointer. The
  kernel discovers ACPI, SMBIOS, and runtime services through
  it on EFI boots (REQUIRED on EFI).
- MODINFOMD_EFI_MAP: struct efi_map_header {memory_size,
  descriptor_size, descriptor_version} padded to 16 bytes,
  followed by the raw descriptor array (contract 3; REQUIRED:
  getmemsize builds physmap from it on EFI).
- MODINFOMD_EFI_FB (struct efi_fb): framebuffer address, size,
  geometry, masks from GOP. REQUIRED for vt(4) efifb console
  and for drawfs's display expectations; boot succeeds without
  it on serial (VERIFY the degraded path is acceptable for RE).
- MODINFOMD_ELFHDR, MODINFOMD_SSYM/MODINFOMD_ESYM: kernel ELF
  header and symbol range. OBSERVED; required only for
  ddb/symbol resolution, not for boot (VERIFY).

2.3 REQUIRED for modules (L3a.3): each .ko is a further chain
entry, type "elf module" (VERIFY exact string on 15.1, from
load_elf.c), with ADDR/SIZE and its own MODINFOMD_* as the
shared loader emits. The kernel's linker preload path
(link_elf.c) consumes them; drawfs arrives this way.

2.4 OBSERVED layout (bi_load): files first (kernel then
modules, at their staged addresses), then the environment block
page-aligned after the highest file end, then the metadata
chain page-aligned after that; modulep points at the chain and
kernend rounds up past it. The kernel requires the pointers to
be consistent, not this particular order (the order is
incidental; the pointer relationships are REQUIRED).

## 3. Memory contract

3.1 REQUIRED. The EFI memory map delivered in MODINFOMD_EFI_MAP
is THE map: the one whose map_key succeeded at
ExitBootServices. The kernel derives usable physical memory
from it; a stale map corrupts memory the firmware still owns.

3.2 REQUIRED sequencing (bi_load_efi_data): allocate a buffer
sized by a GetMemoryMap probe plus slack (OBSERVED: +10
descriptors per retry, because AllocatePages itself splits
regions); GetMemoryMap; ExitBootServices(map_key); if it fails
because the map changed, re-GetMemoryMap and retry (OBSERVED:
bounded retry of 2, motivated in-source by firmware allocating
in callbacks; the bound is incidental, the retry REQUIRED in
practice).

3.3 REQUIRED. All allocations the handed-off state lives in
(staging, trampoline, page tables, the bootinfo pages) are
firmware allocations (AllocatePages, EfiLoaderData/Code) made
BEFORE the final GetMemoryMap, so the map accounts for them and
the kernel will not treat them as free.

3.4 OBSERVED. After ExitBootServices succeeds, the stock loader
calls RS->SetVirtualAddressMap with a 1:1 map (VirtualStart =
PhysicalStart) of the RUNTIME-attributed entries unless
efi_disable_vmap is set (efi_do_vmap). VERIFY against 15.1
sys/dev/efidev/efirt.c expectations: whether the kernel's
runtime-services support assumes the loader performed this.
Treat as REQUIRED until the bench pass proves otherwise.

## 4. Firmware exit contract

4.1 REQUIRED. Before ExitBootServices: all device and protocol
use finished. OBSERVED in main (commit d1f0ee548c73):
dev_cleanup() is called BEFORE bi_load precisely because network
cleanup cannot run after exit; efi_time_fini() likewise. The
PGSD loader's equivalents: close any opened protocols, stop
using ConOut.
4.2 REQUIRED. After ExitBootServices: no boot-services calls of
any kind, no console output through firmware, no memory
allocation. Only the trampoline and the jump remain. (The
stable/12 PR 209821 fix inlined the staging copy into the
trampoline because even calling a function residing in memory
being overwritten during the copy crashed: the post-exit world
is exactly the bytes you placed, nothing else.)
4.3 REQUIRED. ExitBootServices uses the map_key from the final
GetMemoryMap (contract 3.2). Success means firmware boot
services are gone; failure twice is a hard error and the loader
must not proceed.

## 5. Transfer contract

5.1 REQUIRED. Paging at entry: the kernel's linked virtual
range must be mapped when control reaches e_entry. Stock
constructions (elf64_exec, both OBSERVED and sufficient;
alternatives satisfying 5.1 are permitted):
- copy regime: 3 pages of tables (PT4/PT3/PT2), all PML4 slots
  aliasing one PDP, all PDP slots one PD, PD as 512 x 2 MiB
  identity (PG_V|PG_RW|PG_PS): every VA maps to PA modulo 1 GiB,
  which simultaneously satisfies identity execution of the
  trampoline and KERNBASE execution of the kernel copied to
  2 MiB.
- no-copy regime: 9 pages; PML4[0] to a lower PT3 giving 1:1 of
  the low 4 GiB (four PDs); PML4[511] to an upper PT3 whose top
  two slots map the kernel's 2 GiB-below-top linked range onto
  the staging area (PT2_u0[0] compat to phys 0, then 2 MiB
  entries walking the staging base).
5.2 REQUIRED. The trampoline runs identity-mapped, switches
%cr3 to the constructed PT4, performs the staging copy in the
copy regime (inlined, 4.2), establishes the entry stack, and
jumps to e_entry.
5.3 REQUIRED (entry state consumed by locore btext /
hammer_time): 64-bit long mode, interrupts off, %cr3 = the 5.1
tables; the kernel entry receives modulep and kernend. OBSERVED
call shape: trampoline(trampstack, copy_finish, kernend,
modulep, PT4, e_entry) with amd64_tramp arranging the stack so
btext finds its arguments; VERIFY the exact register/stack
convention against bench sys/amd64/amd64/locore.S and
stand/efi/loader/arch/amd64/amd64_tramp.S before L3a.2 codes
it. This is the single most transcription-sensitive item in the
contract.
5.4 OBSERVED. GDT: long-mode code segment already in effect
from UEFI; the EFI amd64 path historically relies on the
firmware GDT remaining valid through the jump (the i386-loading-
amd64 path builds its own). VERIFY on bench source whether
15.1's amd64 trampoline loads a GDT; if it does, that is
REQUIRED.

## 6. Observable invariants

6.1 The booted system is indistinguishable from a stock-loader
boot for everything downstream of entry: same dmesg attach
flow, same audiofs/inputfs behavior, chime plays (the ADR 0032
probe extends its certification through this path).
6.2 Properties the loader must preserve: everything REQUIRED
above; the metadata chain self-consistency (2.2 KERNEND); map
finality (3.1).
6.3 Behavior intentionally unchanged from loader.efi: none by
imitation. Conformance is to this contract; where the stock
loader's behavior is incidental (tagged OBSERVED), the PGSD
implementation may differ and the L3a.2 review judges it
against this document, not against resemblance (ADR 0004
Decision 1 discipline).
6.4 Out of contract entirely: loader.conf, lua, LoaderEnv,
rootdev inference from fstab (OBSERVED conveniences of the
stock environment). The RE slot supplies its environment
explicitly via the 2.2 ENVP block (vfs.root.mountfrom and
kin as the slot manifest defines); parity is a non-goal (ADR
0004 Decision 6).

## Bench verification pass (required before L3a.2 review)

Against /usr/src at n283562, confirm and record in this
document's revision history:
1. bi_load signature (bool exit_bs parameter present?) and the
   kernel type string emitted: stand/efi/loader/bootinfo.c.
2. copy_staging default and kernphys handling:
   stand/efi/loader/copy.c, stand/common/load_elf.c; nm
   /boot/kernel/kernel | grep kernphys.
3. amd64_tramp argument order and GDT behavior:
   stand/efi/loader/arch/amd64/amd64_tramp.S, elf64_freebsd.c.
4. btext entry expectations: sys/amd64/amd64/locore.S,
   hammer_time in sys/amd64/amd64/machdep.c.
5. efirt's assumption about SetVirtualAddressMap:
   sys/dev/efidev/efirt.c.
6. The MODINFOMD_* numeric values and struct efi_map_header /
   efi_fb layouts: sys/x86/include/metadata.h (padding of the
   map header to 16 bytes especially).

## Revision history

- Draft 1, 2026-07-08: written from main-branch sources and
  defining commits; bench verification pass pending, items
  enumerated above.
