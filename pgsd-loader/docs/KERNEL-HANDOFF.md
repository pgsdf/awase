# KERNEL-HANDOFF: the amd64 EFI kernel handoff contract

L3a.1 deliverable (ADR 0004 Decision 1). The contract an
implementation must satisfy to start a FreeBSD amd64 kernel from
UEFI. Organized by the kernel's required contracts, with source
as evidence for each; the source is not the outline.

Status: draft 3, 2026-07-08, no open VERIFY items.
Previously draft 2: Draft 1 was corroborated against
FreeBSD main branch sources; the bench verification pass against
/usr/src (15.1, tip commit 4f09e9082493, the operator's own
AD-56 instrumentation atop n283562, matching the running kernel)
was executed the same day and its evidence file is
kernel-handoff-evidence-20260708-122517.txt. All draft 1 VERIFY
items are resolved below except one, explicitly retained. This
document is fit for L3a.2 review use.

Every claim is tagged:
- REQUIRED: the kernel depends on it; omission breaks boot or
  corrupts state.
- OBSERVED: what stock loader.efi does; may be incidental. An
  implementation may differ if the REQUIRED items still hold.
- VERIFY: believed true, confirmed only by the bench pass or an
  L3a.2 experiment.

## 0. Coordinate systems

Three address spaces run through every contract below; the
distinctions are the document's skeleton, stated once here.

- Staging space: real physical RAM, the loader's allocation
  (staging_base through staging_end), where bytes actually live
  while the loader runs. Never exported to the kernel.
- Dest-space: the contract's coordinate system. Anchored at the
  kernel image base (stock: the first write's destination, the
  first PT_LOAD p_paddr; load-relative offsets for a
  kernphys-relocatable kernel). Every value the kernel receives,
  ADDR entries, ENVP, modulep, kernend, lives here. Translation
  to staging space is a single signed offset (stage_offset =
  staging minus dest), applied at write time and never exported.
- Kernel virtual space: the KERNBASE-mapped range the kernel
  executes in. The transfer contract's page tables connect it to
  wherever the bytes are: in the copy regime by first making
  dest-space physically true (copying staging onto the dest
  addresses), in the no-copy regime by mapping KERNBASE plus
  offset onto the staging base.

An implementation may choose any internal representation,
provided the values it emits are dest-space and its page tables
realize the connection. The regimes are two realizations of one
contract, not two contracts.

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

1.3a REQUIRED. The staging area is 2 MiB aligned
(EFI_STAGING_2M_ALIGN, copy.c efi_copy_init): the kernel builds
its early page table from its own load address using 1 or 2 MiB
pages, so misalignment breaks pmap bootstrap.

1.3b REQUIRED. Space beyond kernend is kernel property: the
amd64 kernel carves very early allocations out of memory after
kernend (efi_check_space comment), so the loader must leave slop
(stock: EFI_STAGING_SLOP) between kernend and the end of usable
staging, inside the memory-map accounting.

1.3c REQUIRED ordering. The stock staging area can MOVE during
load (efi_check_space expands after or before the allocation,
memmoving content and re-deriving stage_offset), so page tables
and any captured staging address are valid only after bi_load
returns; the stock construction order (bi_load, then page
tables, then trampoline) is contractual for any implementation
whose staging can move, and remains the safe order for one whose
staging cannot.

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
VERIFIED on bench: copy_staging defaults to AUTO (copy.c line
205); 15.1's is_kernphys_relocatable is the symbol lookup alone,
no size check, and multiboot also qualifies (load_elf.c lines
215 to 223, 488); the running kernel exports kernphys
(ffffffff81a87570 B). On this bench AUTO therefore resolves to
the no-copy regime. The PGSD loader must detect kernphys and
must not assume it (REQUIRED); implementing the no-copy regime
first, with copy as follow-on if a target ever lacks kernphys,
is the L3a.2 recommendation this evidence supports.

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
  ddb/symbol resolution, not for boot (VERIFY by an L3a.2
  omission experiment if desired; not load-bearing for the
  contract).
- MODINFOMD_MODULEP (0x1006): the metadata block's own physical
  address, added as a self-reference (bootinfo.c line 464).
  VERIFIED present on 15.1; treat as REQUIRED for parity until
  an omission experiment says otherwise.
- MODINFOMD_EFI_ARCH (0x1008): MACHINE_ARCH string (line 471).
  VERIFIED present on 15.1; same treatment.
- Numeric constants VERIFIED against sys/sys/linker.h and
  sys/x86/include/metadata.h: MODINFO_NAME 0x0001 through
  MODINFO_ARGS 0x0006, MODINFO_METADATA 0x8000, MODINFOMD_ENVP
  0x0006, HOWTO 0x0007, KERNEND 0x0008, FW_HANDLE 0x000c,
  EFI_MAP 0x1004, EFI_FB 0x1005, and MODINFOMD_NOCOPY 0x8000 as
  the do-not-copy flag. struct efi_fb has nine fields ending
  fb_mask_reserved; struct efi_map_header is padded to 16 bytes
  before descriptors (efisz = (sizeof + 0xf) & ~0xf, line 228).
- 15.1 metadata order on the kernel entry, OBSERVED (lines 452
  to 471, then bi_load_efi_data): HOWTO, ENVP, [DTBP], KERNEND,
  MODULEP, FW_HANDLE, EFI_ARCH, then EFI_FB and EFI_MAP added
  during the exit sequence. Order remains incidental; the set is
  the contract.
- The kernel file is located by file_findfile(NULL, md_kerntype)
  (line 444), the type string indirected through metadata.c
  rather than a literal; an implementation using the shared
  loader infrastructure inherits this, one building its own
  chain must emit the type string the kernel linker expects
  (VERIFIED mechanism; exact string value inherited from the
  shared code path).

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

3.4 RESOLVED: required for efirt, not for boot. The stock
loader calls RS->SetVirtualAddressMap 1:1 after exit unless
efi_disable_vmap=YES (bootinfo.c lines 222 to 226, 306 to 313).
The kernel side (efirt.c lines 240 to 250, VERIFIED) explicitly
accommodates "an old loader.efi" that did not: it checks whether
RS->GetTime lies within the delivered EFI map and fails efirt
attach if not, while boot proceeds. Contract consequence: a
loader omitting the vmap boots a working system without EFI
runtime services (no efi time of day, no efibootmgr from the
booted OS). For an RE slot that trade may be acceptable; L3a.2
decides it consciously and records which. Performing the vmap is
the parity-preserving default.

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
5.3 VERIFIED, verbatim from the bench sources, and it earned
its transcription-sensitive flag. amd64_tramp(stack %rdi,
copy_finish %rsi, kernend %rdx, modulep %rcx, pagetable %r8,
entry %r9): cli; %rsp = %rdi (a scratch stack, stock allocates
the trampoline page and uses page_top minus 8); stash args; call
*%rsi (efi_copy_finish in the copy regime, efi_copy_finish_nop
in no-copy); then build the handoff stack: push kernend;
salq $32, modulep; push it; push entry; mov pagetable to %cr3;
ret. The ret pops entry as the jump target, leaving %rsp at two
qwords: [modulep shifted into the high half][kernend].

btext's consumption (locore.S line 61, VERIFIED): it distrusts
rflags (pushes PSL_KERNEL and popfq), saves the handoff %rsp to
%rbp, switches to its own bootstack, then reads
movl 4(%rbp) into %edi (modulep) and movl 8(%rbp) into %esi
(kernend) and calls hammer_time. The salq exists exactly so a
32-bit modulep lands at byte offset 4 of the little-endian
qword. Consequences, both REQUIRED:
- modulep and kernend are consumed as 32-bit values: the
  metadata block and the preloaded set must lie below 4 GiB.
  This is the deep reason for the no-copy regime's 4 GiB
  staging ceiling.
- The handoff stack need only survive those two reads; btext
  abandons it immediately. Interrupts stay off through the
  transfer regardless.

hammer_time semantics (machdep.c line 1293, VERIFIED):
kernphys = amd64_loadaddr(); physfree += kernphys, so the
kernend the loader passes is interpreted relative to the
kernel's physical load base; parse_preload_data(modulep)
consumes the chain; efi_boot is detected by the presence of
MODINFOMD_EFI_MAP, nothing else.

The address-value convention, VERIFIED (copy.c lines 428 to
528): stage_offset = staging minus dest, set by the FIRST
copyin/readin, so the kernel's first PT_LOAD p_paddr anchors the
coordinate system, and every loader-side address (ADDR entries,
ENVP, modulep, kernend) lives in that dest-space; real memory is
touched only through the offset (efi_translate). For a
kernphys-relocatable kernel dest-space is load-relative offset
space. The two regimes then make the same handoff numbers valid
by opposite mechanisms: the copy regime physicalizes dest-space,
efi_copy_finish copying staging to staging minus stage_offset,
literally the dest addresses; the no-copy regime virtualizes it,
the upper page tables walking the staging base so KERNBASE plus
offset resolves, parse_preload_data adding KERNBASE to modulep,
and physfree += kernphys re-basing kernend. REQUIRED
consequences for an implementation: pick and hold one coordinate
anchor (the stock anchor is the first write; an implementation
controlling all writes may fix offset space at the kernel image
base deliberately); pass dest-space values, never
staging-absolute ones; and in the no-copy regime the upper
mapping must walk the actual staging base.
5.4 RESOLVED: no GDT handling exists anywhere in 15.1's amd64
EFI exec path (grep VERIFIED empty). The firmware GDT persists
through the transfer; hammer_time builds the kernel's own GDT
immediately (its locals include the descriptor table, VERIFIED).
REQUIRED consequence for an implementation: do not tear down or
replace the firmware GDT before the jump; preserve CS validity
through the trampoline.

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

## Bench verification pass: EXECUTED 2026-07-08

All six items collected by collect-kernel-handoff-evidence.sh
into kernel-handoff-evidence-20260708-122517.txt and folded into
the sections above: (1) bi_load carries exit_bs; the kernel file
is found via the md_kerntype indirection. (2) copy_staging AUTO;
kernphys present in the running kernel; no-copy regime governs
this bench. (3) amd64_tramp captured verbatim including the
salq $32 modulep shift; no GDT handling on the amd64 EFI path.
(4) btext reads modulep and kernend as 32-bit values at stack
offsets 4 and 8, imposing the below-4-GiB requirement;
hammer_time treats kernend as load-base-relative and detects EFI
boots by EFI_MAP presence. (5) the vmap is required for efirt
attach, not for boot. (6) all metadata constants and struct
layouts confirmed, plus two records draft 1 lacked, MODULEP and
EFI_ARCH. The final VERIFY, the address-value
convention, was closed the same day by the copy.c reading
(stage_offset anchor, dest-space, the two regimes' opposite
realizations) which also produced requirements 1.3a through
1.3c. No VERIFY items remain; the contract is fully
source-anchored.

## Revision history

- Draft 1, 2026-07-08: written from main-branch sources and
  defining commits; bench verification pass pending.
- Draft 2, 2026-07-08: bench verification pass executed and
  folded in. Five of six VERIFY items resolved (kernphys and
  regime selection; the trampoline and btext convention with the
  salq $32 discovery and the below-4-GiB consequence; no-GDT;
  efirt-conditional vmap; constants and the MODULEP and EFI_ARCH
  additions). One VERIFY retained by design: the loader-side
  address-value convention through efi_copy, held for L3a.2.
  L3a.1's deliverable is complete.
- Draft 3, 2026-07-08: the retained VERIFY closed from the
  bench copy.c reading. The address-value convention recorded in
  5.3 (dest-space anchored by the first write, translated by
  stage_offset, physicalized by the copy regime and virtualized
  by the no-copy regime's upper mapping); three new REQUIRED
  items 1.3a through 1.3c (2 MiB staging alignment, slop after
  kernend as kernel property, staging motion making post-bi_load
  ordering contractual). The document carries no open VERIFY;
  L3a.2 implementation may proceed against it.
- Draft 3 amendment, 2026-07-08, operator review: coordinate
  systems elevated to an introductory section 0, the model
  stated once before the contracts that depend on it.
