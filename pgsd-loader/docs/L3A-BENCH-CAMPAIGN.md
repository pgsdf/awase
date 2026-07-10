# L3a bench campaign

Closure evidence for ADR 0004 (stage L3a), gathered on
bare-metal-test-bench under the L0 ledger methodology:
observations and dispositions recorded explicitly, evidence
separate from acceptance, stopping rules operator-ratified. The
two campaigns proper (publication, hypotheses H1 through H4; and
boot) open when their increments are implemented; pre-campaign
findings from increment scaffolding are recorded here so they
are decided rather than forgotten.

## Pre-campaign findings

### F1: bench firmware does not honor BootNext (closed: method changed)

During the increment 1 metal probe run, BootNext was set to the
armed test entry (efibootmgr -n -b 0003, confirmed set in the
command output), the machine was power cycled, and the boot went
to Boot0001, the normal order head; the variable was consumed
without being honored. Consistent with this platform's
nonstandard boot-variable handling, and retroactively consistent
with L0's F6 hypothesis space. Disposition: one-shot testing on
this bench uses order-head arming instead, the test entry
created (efibootmgr -c prepends it to BootOrder) and left at the
head for exactly one cycle, then the order restored and the
entry reaped. Safety note recorded with the method: the armed
binary chainloads after its verdict, and a failed load falls
through to the normal entries, so the invariant every L0 drill
exercised covers the order-head cycle too.

### F2: entries are created inactive; inactive head sent firmware to 0000 (closed: activation step adopted; anomaly on watch)

Two observations from one failed cycle. First, efibootmgr -c
creates entries without the active flag (every listing showed
Boot0003 without the asterisk its siblings carry), and firmware
skips inactive entries; deploy.sh has always activated after
creating, and the manual runsheet omitted the step. Adopted:
every manual entry creation is followed by -a -b. Second, with
the inactive test entry at the order head, the skip landed on
Boot0000, not the next active entry 0001: consistent with this
firmware abandoning the order walk on an unusable head and
selecting an internal default, rather than continuing. Single
occurrence, cause not claimed; recorded on watch, and the
avoid-inactive-entries discipline makes it unreachable in normal
operation.

### F3: the console verdict is unobservable on this platform (closed: verdict variable)

The corrected cycle booted through the armed entry (BootCurrent
0003, the safety property demonstrated on metal: verify, then
chainload, then a fully normal boot with the chime) but the
verdict was unreadable despite the five second dwell. Either the
stall silently failed or, more consistent with the record,
SimpleTextOutput does not render on this panel at all, which
would also explain why no L0 banner was ever observed: not
speed, invisibility. Disposed by making the verdict independent
of the console: the armed path records PASS with generation and
slot, or FAIL with the error name, in a UEFI variable
(PgsdBasVerdict, vendor GUID
50475344-6261-4c33-8a01-706773646261, NV plus BS plus RT), and
the booted OS reads it back with efivar(8). This is the deferred
boot-evidence variable proposal from the L0 campaign, adopted in
armed-only form now that it has a concrete consumer; extending
it to the default path remains ADR-gated.

## Increment 1 metal run

Cycle 1 (BootNext): armed binary never ran; produced F1.
Cycle 2 (inactive order head): armed binary never ran; produced
F2.
Cycle 3 (active order head): BOOTED THROUGH THE ARMED ENTRY,
BootCurrent 0003, normal boot and chime after: the safety
property holds on metal. Verdict unobserved, producing F3.
Cycle 4, 2026-07-08: CLOSED with PASS. Armed binary
f2ee3fcad529... at the activated order head; BootCurrent 0003
after a normal boot with the chime; the verdict variable read
back PASS gen=1 slot=1. The loader verified the real slot on
real msdosfs, kernel and drawfs.ko hashed clean, and attested it
from inside the boot.

### Increment 2 metal run: CLOSED, 2026-07-08

Binary 222f4c01... at the activated order head; the verdict
variable read back:

  PASS gen=1 slot=1 elf=loaded entry=0xffffffff80383000
  base=0x200000 end=0x1c00000

The loader parsed the real slot kernel's ELF64 and loaded every
PT_LOAD segment into 2 MiB aligned staging below 4 GiB on real
hardware, attested from inside the boot, then chainloaded to a
normal boot (the verify-only safety property). Three facts
recorded as evidence for the increments ahead:

  - base=0x200000 confirms KERNEL-HANDOFF.md contract 0 on
    metal: dest-space anchors at the minimum PT_LOAD p_paddr, and
    the real kernel's minimum p_paddr is 0x200000 as the contract
    predicted, not merely the fake kernel's.
  - entry=0xffffffff80383000 is the real kernel's virtual entry,
    0x183000 above the load base; the increment 4 trampoline
    transfers here.
  - end=0x1c00000 is the loaded image's dest-space extent, span
    0x1a00000 (26 MiB) from base, comfortably below the 4 GiB
    ceiling the salq handoff convention requires. KERNEND (the
    metadata chain, increment 3) derives from this end rounded
    up past the environment and the chain itself.

### Increment 3 metal run: CLOSED, 2026-07-08

Binary 40062e3c... at the activated order head; the verdict
variable read back:

  PASS gen=1 slot=1 elf=loaded entry=0xffffffff80383000
  base=0x200000 modulep=0x1c01000 kernend=0x1c02000

The MODINFO chain built in dest-space above the real loaded
kernel, attested from inside the boot, then chainloaded normally.
The geometry confirms the page-alignment discipline on real
addresses: the image ended at 0x1c00000 (increment 2), the
environment block page-aligned there, the chain landed at
modulep=0x1c01000, and kernend=0x1c02000 rounds one page past
the 144-byte chain. KERNEND is self-consistent, its value written
into a record the chain itself contains. These are the exact
modulep and kernend the increment 4 trampoline hands the kernel;
both are far below the 4 GiB ceiling the salq handoff convention
requires.

### Increment 4a metal run: CLOSED, 2026-07-08

Binary at the activated order head; the verdict variable read
back:

  PASS gen=1 slot=1 elf=loaded base=0x200000 modulep=0x1c01000
  kernend=0x1c02000 ho=prepared pml4=0x7e5c9000 ptok=true fb=true

Every piece of handoff state short of ExitBootServices is now
proven on hardware. The nine-page no-copy tables built at
pml4=0x7e5c9000 (below 4 GiB), the coherence check passing on the
real staging base (PML4[0] and PML4[511] correct, the upper
mapping walking staging with the page-size bit), and the Apple
panel's framebuffer detected through GOP. The pml4 address
differs from emulation (0xdfc3000) because the real firmware's
free-memory layout differs, as expected; the coherence is
invariant, the address is not.

One finding on the way, F4: the first 4a cycle recorded the
fallback note elf=loaded meta=built ho=built because the elf_note
buffer was 96 bytes and the real detail string is 106, so
bufPrint returned NoSpaceLeft and the catch default was written.
The work was correct; only the report truncated. Disposed by
widening the buffers. Recorded because it is the attestation
checkpoint proving its worth: a formatting fault caught while
still chainloading, not past the point of no console.

### Increment 4b preflight metal run: CLOSED, 2026-07-08

Binary 48a26d0f... at the activated order head; the verdict
variable read back:

  PASS gen=1 slot=1 elf=loaded base=0x200000 modulep=0x1a01000
  kernend=0x1a02000 ho=prepared pml4=0x7e5c8000 ptok=true fb=true
  rb=true

rb=true is the coordinate convention proven on hardware: the
preflight read the physical location the kernel's page walk
resolves for modulep and found the MODINFO chain's first record,
and read envp and found the environment terminator, on the real
kernel through the real page tables. Every precondition for the
handoff is now attested; only the trampoline and ExitBootServices
remain.

The relative values confirm the F5 fix on real addresses:
modulep=0x1a01000 and kernend=0x1a02000 are image-base relative
(the real kernel spans 0x1a00000 from base), down exactly
0x200000 from the pre-fix 4a values, the base_paddr the bug had
double-counted.

### F5: increment 3 metadata used a coordinate anchor inconsistent with the segments and page tables (closed by the 4b preflight)

The metadata chain passed modulep, envp, and kernend as raw
dest addresses anchored at 0, while elf_load places segments at
image-base-relative offsets and the no-copy page tables map
KERNBASE at the image base. The kernel reads KERNBASE+modulep,
the upper tables resolve that to staging+modulep, which is
base_paddr (0x200000) past where the chain was actually written.
On metal this would have been a dark screen with no console.
Found by the 4b preflight readback (readback=false in emulation)
before the trampoline existed, the clearest vindication so far of
verify-then-chainload: a latent handoff bug caught at an
attestation checkpoint rather than past the point of no console.
Disposed by working in image-base-relative offsets throughout, one
anchor shared by segments, page tables, and metadata; the kernel
ADDR entry becomes 0 with SIZE the image span.

### Increment 4b-records metal run: CLOSED, 2026-07-08

Binary 989084cf... at the activated order head; the verdict
variable read back:

  PASS gen=1 slot=1 elf=loaded base=0x200000 modulep=0x1a01000
  kernend=0x1a02000 ho=prepared pml4=0x7e5c6000 ptok=true fb=true
  rb=true clen=2512 ndesc=47

The full metadata chain including the EFI records is built and
readback-verified on hardware. rb=true confirms NAME first, the
environment terminator, and the EFI_MAP record all present at the
address the kernel's page walk resolves. The chain-size question
the first records run raised is answered with data: the real
machine has 47 memory descriptors (Apple firmware is far simpler
than OVMF's ~132), so the chain is 2512 bytes; at chain base
0x1a01000 that ends at 0x1a019d0 and page-rounds to 0x1a02000,
exactly the reported kernend. The value that looked unchanged was
correct, and is now explained rather than inferred. clen and
ndesc were added to the verdict specifically to close this before
4b-final crosses ExitBootServices on the chain.

Every precondition for the handoff is attested on hardware with no
inferred value remaining: slot, kernel image, metadata chain with
self-consistent KERNEND, EFI records from the real map, coherent
page tables, framebuffer, and the coordinate convention. Only
4b-final remains: the final map capture whose key
ExitBootServices consumes, the exit itself, and the salq
trampoline.

### Increment 4b page-walk metal run: CLOSED, 2026-07-08

Binary 2b30a016... at the activated order head; the verdict
variable read back:

  PASS gen=1 slot=1 elf=loaded base=0x200000 modulep=0x1c01000
  kernend=0x1c02000 ho=prepared pml4=0x7e5c5000 ptok=true fb=true
  rb=true clen=2512 ndesc=47

modulep=0x1c01000 is the KVO value, exactly 0x200000 above the
pre-F6 0x1a01000, the signature of the design A anchor fix; the
smoke page walk modulep and page walk entry checks both pass on
the real kernel's addresses. The software MMU walk confirmed that
KERNBASE+modulep resolves to the chain and the entry vaddr
resolves to where elf_load placed the entry segment. Every handoff
precondition is now verified along the kernel's real access path,
not merely at the staging offset.

### F6: page tables mapped the kernel range without the base_paddr offset (closed by the page-walk preflight)

The page tables mapped KERNBASE+KVO to staging+KVO, while
elf_load places segments at staging + (p_paddr - base_paddr), so
the kernel would have jumped to its entry and executed 0x200000
past its own code, a dark screen with no console. Worse than F5
and invisible to every prior check: the rb=true readback read
staging+modulep directly and never exercised the page tables. A
software page walk of the real access path returned mod=false
entry=false immediately. Fixed by design A, matching the stock
anchor: the upper tables map KERNBASE+KVO to
staging + KVO - base_paddr, kernel-visible offsets are
KVO = rel + base_paddr with ADDR = base_paddr, physical writes
stay at staging + rel. The walk then returns mod=true entry=true.
The lesson generalized: a check that does not exercise the path
the kernel uses can pass while the path is broken; the walk now
supersedes the staging read as the authoritative mapping check.

### F7: metal transfer reset at the Apple logo; transfer reverted pending diagnosis

The first real metal boot attempt (loader deployed as -boot.efi,
armed at the boot-order head, binary a95e050a) power-cycled the
bench at the Apple logo with no kernel text ever appearing, and
the machine could not be returned to a bootable state; the
operator chose to reinstall FreeBSD to recover the environment.

What is known: the transfer mechanism is proven correct in
emulation (the KOK serial proof: cr3 switch, handoff stack, and
jump all execute and reach the kernel entry), and every handoff
precondition was verified on this hardware along the kernel's real
access path (elf load, metadata chain, EFI records from the real
map, page tables walked for both modulep and entry, the root env,
all rb=true mod=true entry=true on metal). The reset therefore
occurs at or immediately after the transfer, not in the attested
preparation.

What is NOT known: the exact fault location. The BOOT_ATTEMPT
breadcrumb written to the verdict variable before ExitBootServices
was never read back, because the machine could not be brought up
to read it; so whether the reset is inside the trampoline (a cr3
triple-fault) or in the kernel's first instructions is
unconfirmed. The reset-at-logo-no-text signature is consistent
with a triple-fault during or just after the cr3 load, which would
mean a page-table detail correct in OVMF but wrong on this
firmware (for example the low 1:1 not covering the loader's
execution address, or the image loaded at or above 4 GiB despite
the check).

Disposition: the transfer (4b-final) and the root env are reverted
so the loader returns to the walk-verified attest-and-chainload
state, which is safe: it never crosses ExitBootServices. The
transfer work remains in history and is re-introducible once the
metal fault is diagnosed. Before any re-attempt: recover the
BOOT_ATTEMPT breadcrumb from a boot that survives long enough to
read the variable, or add pre-exit instrumentation that survives a
reset (for example writing progress markers to the verdict
variable at each step of the trampoline setup, or attempting the
transfer first under a serial-console configuration if the
hardware can expose one). A copy-regime trampoline, or a review of
the low 1:1 mapping against the actual loader image base on this
firmware, are the leading hypotheses to check.

INCREMENT 1 METAL RUN: CLOSED, 2026-07-08, four cycles, findings
F1 through F3 produced and disposed. The read side of
BOOT-ARTIFACT-STORE 0.3 is proven on the bench through all three
integrity layers, with the safety property (verify, then
chainload regardless) demonstrated under both a running verdict
and, in emulation, a refusing one.

Scaffolding note for the campaigns: PgsdBasVerdict records the
most recent armed run only; unarmed boots leave it stale.
Adequate for scaffolding where the operator controls the cycle;
any campaign automation that reads it must pair the read with
the cycle that wrote it, and a timestamp or nonce field is the
upgrade if that pairing ever gets fragile.

#### F7 step 1 evidence (ADR 0005 Decision 1.1): the breadcrumb survived

Read back 2026-07-10 on the reinstalled bench, fourteen days and one
FreeBSD reinstall after the fatal attempt (NVRAM is not disk):

    BOOT_ATTEMPT entry=0xffffffff80383000 pml4=0x7e5c4000
                 tramp=0x7e5f7ed0 rsp=0x7e5c3f00

Consequences for the F7 hypothesis list:

- Both address hypotheses named at F7 are eliminated by the fatal
  attempt's own values: the transfer code ran from 0x7e5f7ed0,
  below 4 GiB and covered by the low 1:1 (the image was not loaded
  high on this firmware), and pml4 and rsp are likewise below
  4 GiB, 4 KiB aligned (no stray cr3 low bits), with the stack page
  adjacent to the table pages exactly as allocated.
- The remaining fault space is therefore: the unreported region
  between the breadcrumb write and the jump (final map capture,
  chain rebuild, the ExitBootServices retry loop), and the kernel's
  first instructions, which have never executed through this
  transfer anywhere (the KOK proof used the fake kernel by design).
  Both are exercised by ADR 0005 step 2, the real-kernel emulation
  run, which proceeds next.
- The variable still holding BOOT_ATTEMPT also shows the safe
  loader has not run since the reinstall: pgsd-loader is not in the
  bench boot path. Step 3 deployment, when reached, is a deliberate
  deploy.sh act under ADR 0005 Decision 4, not a leftover arming.

#### F7 step 2 emulation (ADR 0005 Decision 1.2): the handoff contract holds

The transfer was re-landed with the 4c fail-closed rebuild and the
reset-surviving markers, and smoke pass 8 (the contract kernel) was
run under QEMU/OVMF. Result: HOK.

The contract kernel's entry reads modulep from the handoff stack the
way btext does, forms KERNBASE+modulep, dereferences it through the
kernel's own upper page tables, and emits HOK only when the leading
metadata record is MODINFO_NAME. HOK therefore proves the loader's
whole side of the handoff is coherent through the kernel MMU: the
stack layout btext reads, the modulep value, and the upper mapping
that resolves KERNBASE+modulep to the chain. The serial also shows
WALK mod=true entry=true and readback=true from the pre-exit
attestation, consistent with the transfer path. A control run with
the default (KOK) kernel emits KOK and not HOK, confirming HOK is
contract-gated rather than incidental.

What this closes and what it does not: the mechanism half of F7's
fault band (already narrowed by step 1's address evidence) is now
positively demonstrated to hand over a coherent state, not merely to
reach the entry. What remains unproven in emulation is the real
FreeBSD kernel's own early code against this handoff, which is smoke
pass 9 (PGSD_REAL_KERNEL), authoritative only on the bench per ADR
0001 Decision 7. A pass 9 success would reach the FreeBSD banner and
isolate any remaining fault to platform-specific behavior or
firmware-dependent assumptions; a failure now reproduces in an
environment with serial and QEMU diagnostics rather than blind on
metal. Step 3 (metal) follows pass 9 under ADR 0005 Decision 4.
