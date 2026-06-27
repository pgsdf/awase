# AD-56 Phase 0.5 Delta 2: boot metadata inventory analysis

Analysis of the observation inventory produced by Delta 1
(debug.ad56.preload_inventory) on bare-metal-test-bench. This is Delta 2
of the three-delta workflow (observe, understand, modify): a project
record, not kernel work. It interprets the raw inventory against the
AD-56 candidate set and gates Delta 3 (reduction).

## Provenance

  - Instrumentation: fork commit 4f09e9082493ed46896f6bb8e0470316de2954b4
    (branch awase/ad56-phase05-observation), built into PGSD-DEBUG against
    the pinned base 96841ea08dcfa84b954a32dc5ae1a26c28966cf4 (FreeBSD
    15.1.0).
  - Boot type: EFI (decisive for interpretation; see SMAP below).
  - Accounting integrity: every row satisfies found + not_found ==
    requests; overflow == 0 (table held all types; inventory complete).
  - Type identities resolved from sys/sys/linker.h (MODINFO*,
    MODINFOMD_AOUTEXEC..SPLASH) and sys/x86/include/metadata.h (the
    0x100x x86 subtypes: SMAP, SMAP_XATTR, DTBP, VBE_FB, EFI_ARCH).
    MODINFO_METADATA = 0x8000; an x86 subtype 0x100x appears as 0x900x.

## The inventory, decoded

Boot-metadata records (the AD-56 domain):

  type    name                 req found not_found  status
  0x8007  MODINFOMD_HOWTO       1    1      0        present, consumed
  0x8006  MODINFOMD_ENVP        1    1      0        present, consumed
  0x9004  MODINFOMD_EFI_MAP     3    3      0        present, consumed
  0x9005  MODINFOMD_EFI_FB      1    1      0        present, consumed
  0x9001  MODINFOMD_SMAP        2    0      2        REQUESTED, ABSENT
  0x800c  MODINFOMD_FW_HANDLE   1    1      0        present
  0x800d  MODINFOMD_KEYBUF      1    1      0        present

Structural module/linker records (NOT boot-environment; per-module
lookups during kernel and module linking; out of AD-56 scope):

  type    name                 req found not_found
  0x0001  MODINFO_NAME         15   15     0
  0x0002  MODINFO_TYPE         39   39     0
  0x0003  MODINFO_ADDR         14   14     0
  0x0004  MODINFO_SIZE         14   14     0
  0x8002  MODINFOMD_ELFHDR      7    4      3
  0x8003  MODINFOMD_SSYM        3    3      0
  0x8004  MODINFOMD_ESYM        3    3      0
  0x8005  MODINFOMD_DYNAMIC     4    1      3
  0x8009  MODINFOMD_SHDR        7    4      3
  0x800a  MODINFOMD_CTORS_ADDR  1    0      1   (requested, absent: benign)
  0x800b  MODINFOMD_CTORS_SIZE  1    0      1   (requested, absent: benign)

## Findings

### F1. The AD-56 graphics/memory candidates that appear are present and consumed

EFI_MAP (3/3) and EFI_FB (1/1) are both present and found. EFI_MAP's
three all-found requests are consistent with its REQUIRED-and-CONSUMED
status (native_parse_memmap). EFI_FB present is consistent with drawfs
consumption. HOWTO and ENVP are present and found (1/1 each), matching
hammer_time's MD_FETCH reads.

### F2. SMAP is requested but ABSENT, and that is correct for an EFI boot

MODINFOMD_SMAP (0x9001) was requested twice and found zero times. Its
caller is machdep.c:834 (memory-map setup). This CORRECTS a claim in
AD56-ABI-BRIDGE.md that grouped SMAP with EFI_MAP as REQUIRED. On an EFI
boot the legacy BIOS SMAP memory map is not provided; the kernel probes
for it, does not find it, and uses EFI_MAP instead (which IS present).
So SMAP is requested-but-absent by design on this platform, not a
problem. Consequence for AD-56: SMAP is NOT a reduction candidate to
"remove"; it is already absent and the kernel handles its absence. Any
reduction logic must not assume SMAP presence.

### F3. KERNEND is absent from the inventory: unobservable, as predicted

MODINFOMD_KERNEND (0x8008) does not appear at all. Per the observation
design's general rule, an absent type is UNOBSERVABLE by this technique,
NOT "never requested." AD56-ABI-BRIDGE.md predicted exactly this: KERNEND
is read in early locore/pmap bootstrap, before preload_search_info
accounting is reachable. This is a confirmed prediction, not a surprise,
and it validates the unobservable category with a concrete case. KERNEND
remains CONSUMED and MANDATORY; the inventory simply cannot see its read.
Consequence: KERNEND must be treated as mandatory-present in any
reduction; its invisibility here is not evidence it is unused.

### F4. The other x86 candidate records were never requested this boot

Absent from the inventory, hence unobservable-or-unrequested:
SMAP_XATTR (0x9002), DTBP (0x9003), VBE_FB (0x9007), EFI_ARCH (0x9008).
For an amd64 EFI boot this is expected: VBE_FB is the legacy BIOS
framebuffer (superseded by EFI_FB, which is present); DTBP is device-tree
(not used on amd64); SMAP_XATTR and EFI_ARCH were not requested. By the
rule, absence is not proof they are never requested under other
configurations; it means this boot did not request them. They are NOT
reduction candidates on the strength of this single boot.

### F5. The requested-but-absent structural records are benign

CTORS_ADDR/CTORS_SIZE (0x800a/0x800b), callers link_elf.c:500/504, are
the linker reading constructor-array metadata for a module that lacks it.
Requested once, absent. Benign: not every module carries .ctors. These
are structural, per-module, and out of AD-56 boot-metadata scope.

### F6. Most of the inventory is structural module metadata, not boot records

NAME/TYPE/ADDR/SIZE and ELFHDR/SSYM/ESYM/DYNAMIC/SHDR are the per-module
fields read while linking the kernel and its preloaded modules. High
counts (TYPE 39, NAME 15) reflect walking many module blobs. The
partial-presence rows (ELFHDR 4/7, DYNAMIC 1/4, SHDR 4/7) mean the field
is present for some modules and absent for others, as expected for
heterogeneous modules. None of these are AD-56 boot-environment reduction
candidates; per the design's distinguish-by-type rule, they are
structural.

## Candidate set reconciliation (against AD-56)

AD-56 named these boot-metadata candidates: EFI_MAP, EFI_FB, HOWTO, ENVP,
KERNEND, SMAP. Status from this boot:

  EFI_MAP   present, consumed, REQUIRED      -> keep (mandatory)
  KERNEND   unobservable here, MANDATORY     -> keep (mandatory)
  HOWTO     present, consumed                -> keep (consumed)
  ENVP      present, consumed                -> keep (consumed)
  EFI_FB    present, consumed by drawfs      -> candidate OPTIONAL (drawfs
                                                only; kernel boots without)
  SMAP      requested, ABSENT (EFI boot)     -> already absent; not a
                                                removal candidate

Observation assigned no DEAD classifications: every candidate is either
consumed, mandatory, or already absent. The only genuinely OPTIONAL
boot-metadata record this boot supports reducing is EFI_FB, and only
because the kernel reaches userspace without it (drawfs consumes it, but
drawfs is not boot-critical). That matches AD-56's prior expectation that
EFI_FB is the safe first reduction target.

## What this gates (Delta 3)

The inventory does NOT license broad suppression. It supports exactly one
narrow, well-understood reduction experiment as the Delta 3 starting
point:

  - EFI_FB (0x9005): the single OPTIONAL boot-metadata record confirmed
    consumed-but-not-boot-critical. Reduction would suppress EFI_FB and
    verify the kernel still reaches userspace (drawfs loses its
    framebuffer, which is the expected, recoverable degradation).

Everything else is keep: EFI_MAP/KERNEND/HOWTO/ENVP are consumed or
mandatory; SMAP is already absent; the structural records are out of
scope; the never-requested x86 records (VBE_FB, DTBP, SMAP_XATTR,
EFI_ARCH) cannot be reduction candidates on one boot's absence.

Open item before Delta 3: confirm EFI_FB's consumer path (drawfs) treats
absence gracefully, and that EFI_FB suppression is recovery-gated (the
known-good BE remains the fallback). EFI_MAP stays LAST and untouched
(native_parse_memmap panics without it).
