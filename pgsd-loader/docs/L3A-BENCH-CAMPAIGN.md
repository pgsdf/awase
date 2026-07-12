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

#### F7 step 2 bench status (2026-07-10): harness blocked before the launcher path

Serial capture is functioning (approximately 25 KB captured from a
foreground bench run). The log shows pgsd-loader 0.1.0,
CHAINLOAD TARGET REACHED, and chainloaded loader returned: success
before OVMF retries boot and enters the Boot Manager. This
demonstrates that the L0 chainload path executes successfully on the
current bench configuration.

The remaining launcher-driven smoke passes (3 onward, including the
pass 8 contract check and the pass 9 real-kernel run) have not yet
been exercised on the bench, because the bench OVMF appears to boot
via its existing Boot0002 "UEFI QEMU HARDDISK" path instead of
entering the launcher-controlled flow the smoke harness expects. The
scripted run reported all passes failing with an empty captured log;
the foreground run shows why: the firmware auto-booted BOOTX64.EFI
(the L0 chainload scenario) rather than letting the launcher start a
nested loader binary, so passes that depend on the launcher never
received their setup.

Scope of what is and is not shown:

- Observed on the bench: the L0 chainload path executes
  (pgsd-loader runs, reaches the chainload target, receives a
  successful return); serial capture works.
- Observed in the development sandbox only (Ubuntu OVMF under QEMU),
  not yet reproduced under the bench edk2-qemu firmware: smoke pass
  8 returns HOK, the handoff contract check. Because the firmware is
  the variable now in question, this result does not yet transfer to
  the bench.
- Not yet exercised anywhere on the bench: the launcher-driven
  passes, and therefore pass 9 (the real pinned kernel). The current
  evidence does not implicate the F7 transfer mechanism, because the
  launcher path has not been exercised on this bench; F7 step 2
  remains open, now blocked on harness/firmware boot selection rather
  than on any observed loader or mechanism defect.

Working hypothesis: this is a bench-specific harness/OVMF
interaction affecting initial boot selection, not a loader or F7
mechanism defect.

Next work, in order:

1. Run the pass 3 ESP in the foreground and capture complete serial
   output (does the option-launcher start at all under this
   firmware).
2. Determine how the bench edk2-qemu OVMF selects its initial boot
   target, and why BOOTX64.EFI auto-boots ahead of the launcher
   flow (candidates: virtual-FAT boot priority, a shadowing
   "UEFI QEMU HARDDISK" entry, -boot options).
3. Adjust the QEMU invocation or ESP presentation so the
   launcher-controlled path executes; reproduce pass 8 (HOK) on the
   bench firmware as the gate, then resume the pass 9 investigation.

#### F7 step 2 result (2026-07-10): fault isolated past ExitBootServices

The transfer-armed pass 9 (boot-launcher -> pgsd-loader-boot.efi)
ran against the real pinned kernel (/boot/kernel/kernel, 28699776
bytes) under QEMU/OVMF. No FreeBSD banner, but the post-HO NVRAM
markers give the verdict:

    BOOT_ATTEMPT entry=0xffffffff80383000 pml4=0xe335000
                 tramp=0xe299fa0 rsp=0xe334f00
    MARK_MAP_CAPTURED
    MARK_CHAIN_REBUILT
    MARK_EXITED_BOOTSERVICES

Every loader stage succeeded, including ExitBootServices. The
fail-closed rebuild did not fire; the map-key retry did not exhaust;
the 5824-byte real-kernel chain rebuilt cleanly. The last marker is
MARK_EXITED_BOOTSERVICES, written in physical mode immediately after
EBS returned and before the cr3 load. Nothing follows it because
nothing can: after the cr3 switch there is no NVRAM. The banner
never appeared.

Per ADR 0005 Decision 4, this partitions the fault unambiguously:
the failure is in the trampoline or the kernel's first instructions,
after a fully successful ExitBootServices. Everything the loader is
responsible for (verify, load, map, walk, capture, rebuild, exit) is
now positively demonstrated correct against the real kernel, and the
pass 8 HOK result already showed the handoff state is coherent
through the kernel MMU. The remaining band is the instructions from
post-EBS through the cr3 load, the trampoline jump, and btext's
first instructions.

Consequences:

- F7 reproduces in emulation. The metal signature (clean to the
  logo, then silent) and this QEMU run match: clean through EBS,
  silent after. F7 is no longer Apple-firmware-specific and no
  longer needs the bench to diagnose.
- The next experiment is a gdb-attached QEMU run (-s -S): break at
  tramp, single-step the cr3 load and the jump, and observe where
  the fault occurs. Candidates narrowed by the evidence: the low 1:1
  mapping's coverage of the trampoline's own execution address after
  the cr3 switch, or btext's first instructions against the handoff
  (the handoff contents themselves are HOK-validated).
- Metal (ADR 0005 step 3) is not required to make progress and
  should wait until the emulation fault is understood and a fix is
  in hand, then confirm on the bench under Decision 4 discipline.

#### F7 resolved at the handoff (2026-07-10): the real kernel executes through the transfer

A gdb single-step of the transfer-armed real pinned kernel
(/boot/kernel/kernel) under QEMU, breaking at the labelled cli of the
trampoline, shows the handoff is correct end to end:

    cli
    mov -> cr3   : cr3 changes 0xf801000 -> 0xe335000 (= HO pml4),
                   the next instruction fetch succeeds (rip advances),
                   so the trampoline stays mapped across the switch
    mov -> rsp   : rsp = 0xe334f00
    jmp  *rcx    : rip = 0xffffffff80383000, the real kernel entry

The real kernel's own first instructions then execute:

    0xffffffff80383000: push $0x2 ; popf      (set RFLAGS = 0x2)
                        mov %rsp,%rbp
                        mov $0xffffffff81970000,%rsp   (kernel stack)

and rip climbs 0x383000 -> 0x38300d with rsp switching to the
kernel's own bootstrap stack. This is FreeBSD amd64 locore running.

This eliminates every loader-side F7 hypothesis by direct
observation: not image-high, not trampoline-unmapped, not a register
spill across the stack switch, not an incoherent handoff. The
pinned-register trampoline hands control to the real kernel, which
takes its own stack and proceeds. The mechanism half of F7 is
closed.

What remains: pass 9 still shows no Copyright banner, but the step
proves the kernel is executing past the handoff, so any remaining
stop is later in kernel bring-up (before cninit, which is where the
banner originates), not at the transfer. The step harness detaches
and kills QEMU four instructions in, so it never let the kernel run
free to cninit. The next experiment is gdb-transfer.sh run: boot the
real kernel and let it run without freezing, serial captured, to see
whether the banner appears or where bring-up stops. That is a kernel
bring-up question, downstream of everything the loader owns.

#### F7 reproduces in emulation and is a kernel early-boot fault (2026-07-10)

trace mode (free-run + interrupt sampling) showed rip pinned at the
kernel entry 0xffffffff80383000 across every sample, while step mode
had single-stepped cleanly past the entry. The reconciliation: free
execution faults a few instructions into the kernel, triple-faults,
and the machine resets; the reset re-runs firmware, boot-launcher,
and the loader, which re-enters the kernel at the same entry, so each
interrupt samples a fresh iteration of a reset loop. This is the
metal F7 signature reproduced in QEMU, with full visibility, and now
located: not the transfer (proven correct instruction by
instruction), but a few instructions into the kernel's own early
boot.

Source review against FreeBSD releng/15.1 (the pinned tree),
sys/amd64/amd64/locore.S btext and machdep.c hammer_time /
native_parse_preload_data / amd64_loadaddr:

- btext reads modulep from 4(%rbp) and kernend from 8(%rbp), the
  stack the loader hands over. buildHandoffStack writes modulep<<32
  at s and kernend at s+8, so 4(s)=modulep and 8(s)=kernend. Layout
  correct.
- native_parse_preload_data sets preload_metadata = modulep +
  KERNBASE and envp += KERNBASE, dereferenced through the upper
  mapping. The loader's modulep and envp are KERNBASE-relative and
  the WALK readback confirms KERNBASE+modulep and KERNBASE+envp
  resolve. Metadata and env contracts satisfied.
- amd64_loadaddr walks the loader page tables' PDE for KERNSTART
  (KERNBASE + 2M) and returns its physical frame as kernphys. With
  the loader's upper map pd_u0[k] = staging + k*2M - base_paddr and
  base_paddr = KERNLOAD = 0x200000, KERNSTART (k=1) resolves to
  staging = 0xc000000, so kernphys = 0xc000000, exactly the staging
  base. The vmparam.h contract (2M hole at KERNBASE, kernel at
  KERNSTART, contiguous phys below 4G, 1:1 low-4G map for page-table
  access) is therefore satisfied by the loader: kernphys is correct,
  the staging block is contiguous, the tables are below 4G and
  1:1-mapped. This hypothesis is cleared.

So the metadata, env, and load-address/physfree contracts are all
satisfied. The fault is later in hammer_time, still within the first
instructions before console init. Remaining candidates to check
against source next session: the GDT/IDT/TSS setup in hammer_time
(a bad descriptor load faults with no handler), the EFI map handoff
(MODINFOMD_EFI_MAP contents and efi_boot detection), and the early
pmap bootstrap create_pagetables. The next instrument is deepstep
(single-step 60 instructions from entry) plus, on a synchronous
fault, reading the faulting instruction against locore.S; on a clean
deepstep with a resetting free-run, the trigger is asynchronous (an
interrupt/NMI through an IDT not yet installed), which points at the
early exception setup rather than a bad memory access.

#### F7 resolved: not a transfer fault, an ACPI RSDP handoff gap (2026-07-10)

With the console bound (hw.uart.console), f7probe captured the
kernel's own panic. F7 was never a crash in the transfer or early
boot: the kernel boots correctly through the loader handoff, runs
amd64_loadaddr, hammer_time, parse_preload_data, getmemsize,
init_param1, cninit, and mi_startup, then panics:

    Firmware Error (ACPI): A valid RSDP was not found
    panic: running without device atpic requires a local APIC

and calls kern_reboot (the clean "exit" seen before the console
worked). The kernel cannot find the local APIC because it cannot find
the ACPI tables, because it has no RSDP.

Root cause, confirmed against FreeBSD source
(sys/x86/acpica/OsdEnvironment.c, stand/efi/loader/main.c): a UEFI
kernel finds the ACPI RSDP from the acpi.rsdp kenv tunable, which the
loader must set. The legacy fallback (AcpiFindRootPointer scanning
the BIOS EBDA region) does not work on UEFI, where the RSDP lives
only in the EFI system table's configuration tables. FreeBSD's
loader.efi walks those tables for the ACPI 2.0 GUID (falling back to
1.0) and does setenv("acpi.rsdp", <phys>, 1). pgsd-loader does not
yet pass acpi.rsdp, so the UEFI kernel has no RSDP and panics.

This reframes F7 entirely. The transfer, page tables, handoff stack,
metadata chain, env relocation, and early kernel bring-up are all
proven correct against the real pinned kernel. What remained after
all of that is a boot-information gap: the loader must publish the
ACPI RSDP the way it already publishes modulep, kernend, the EFI map,
and the firmware handle. The next increment (call it L3a.2 increment
2, or its own AD line) is: discover the RSDP from the EFI
configuration tables in the loader and add acpi.rsdp (and
optionally acpi.revision) to the boot env, per the loader.efi recipe.

Scope note: the QEMU/OVMF run also printed "A valid RSDP was not
found" from the firmware, so the emulator's ACPI may be atypical in
this configuration; the fix is nonetheless correct and required for
the bench, where ACPI tables are present in the EFI configuration
tables. Whether the emulator then boots to mountroot is a separate
question the fix will answer.

#### F7 CLOSED: the kernel boots (2026-07-10)

With acpi.rsdp published, f7probe shows the pinned PGSD kernel booting
to completion under the loader. The serial carries the full boot:

    Copyright (c) 1992-2025 The FreeBSD Project.
    FreeBSD 15.1-RELEASE n283562-96841ea08dcf PGSD amd64
    ... CPU, ACPI, PCI, AHCI, uart0 console (115200,n,8,1) ...
    Trying to mount root from zfs:zroot/ROOT/awase-verified-pgsd-clean
    mountroot>

Every landmark is reached through start_init and vfs_mountroot. The
ACPI RSDP fix resolved the earlier panic: the local APIC comes up
(LAPIC event timer, ioapic0, ACPI APIC Table present), and the kernel
runs all the way to root mounting. The probe's 90s timeout fires not
on a hang but on the kernel sitting healthily at the mountroot
prompt.

Where it stops is expected and not a loader fault: the emulator has
no ZFS pool zroot/ROOT/awase-verified-pgsd-clean (only the QEMU
scratch disk), so root mount fails with "unknown file system" and the
kernel drops to the mountroot prompt, exactly the behavior of any
FreeBSD kernel whose named root is absent. On the bench, where that
pool exists, this path continues to userland.

F7 is closed. The two-week-old reset-at-the-Apple-logo failure was,
end to end: a correct transfer (proven instruction by instruction), a
correct handoff (stack, metadata, env, load address all verified
against source), and a correct early boot, blocked only by two
missing boot-env data the loader had not yet published, the serial
console binding (hw.uart.console) and the ACPI RSDP (acpi.rsdp). Both
are now published from facts the loader discovers (the UART port and
the EFI configuration tables), consistent with the publish-not-infer
discipline. The transfer that once required a bench reinstall now
boots the pinned kernel to the mountroot prompt in emulation.

Remaining, as separate non-F7 work: the EFI runtime module load
(MOD_LOAD efirt error 6) if EFI runtime services are ever wanted, and
a real-hardware boot on the bench where the ZFS root is present, under
the ADR 0005 Decision 4 metal discipline.

### F8: metal transfer does not boot though emulation does; a sequencing divergence from loader.efi is the leading hypothesis

**Status: open (hypothesis, emulation-testable, metal retired).**

#### What was observed on metal (2026-07-11)

The transfer that boots the pinned kernel to the mountroot prompt in
emulation (F7, closed above) was armed on the bench twice under the
ADR 0005 Decision 4 one-cycle protocol. The second attempt was
validated against a mock efibootmgr and checkpoint-confirmed
armed-active-at-order-head before the single reboot. Both attempts
failed to boot: the first power-cycled, the second blanked the
display with no kernel text, and both required a FreeBSD reinstall to
recover. The armed loader launched from the firmware picker also
blanked. This reproduces the original F7 signature (reset/blank at
the Apple firmware, no kernel text) on hardware, twice, against a
transfer that is correct in emulation.

Per ADR 0005 Decision 6 (2026-07-11) metal arming is retired: the
QEMU-boots / metal-does-not split is now the established finding, and
the bench is not to be armed again to re-confirm it. The remaining
question, why the handoff differs on this firmware, is pursued in
emulation and against the FreeBSD source, never on the bench.

#### The divergence from the reference implementation

FreeBSD's own EFI loader boots this same Apple hardware (it is what
the bench boots today), so its kernel handoff is a working reference
for this firmware. Comparing our exit sequence against it:

- Observed (reference): FreeBSD builds all boot metadata first, then
  enters a tight retry loop that does GetMemoryMap immediately
  followed by ExitBootServices with nothing in between.
  stand/efi/loader/bootinfo.c bi_load_efi_data(): bi_load()
  constructs the module chain and boot info, and only afterward the
  for (retry = 2 ...) loop calls BS->GetMemoryMap(&...&efi_mapkey...)
  and then efi_exit_boot_services(efi_mapkey) with no intervening
  work. The loop, and its comment crediting Matthew Garrett with
  observing a system that changes the memory map during
  ExitBootServices, is explicit firmware-quirk handling: the map key
  must still be current when ExitBootServices is called, and the
  retry re-reads the map if it is not.

- Observed (ours): pgsd-loader/src/main.zig performs additional work
  between acquiring the map key and calling ExitBootServices. Inside
  the retry loop it captures the map (handoff.captureMemoryMap, which
  yields fmap.key), then rebuilds the metadata chain with the final
  map (metadata.buildChainFull) and memcpy's it into the staging
  area, and only then calls bsp.exitBootServices(handle, fmap.key).
  The metadata rebuild sits between the key acquisition and the exit,
  and it is repeated on every retry.

- Verified (ours): buildChainFull and its callees (file_addmetadata,
  record, ChainWriter.init) invoke no EFI Boot Services and perform
  no allocations; they write into caller-provided buffers, and the
  only memory-state change between capture and exit is the memcpy of
  the rebuilt chain into the already-reserved staging region. So the
  divergence is a sequencing difference, not a known allocation or
  boot-services callback between GetMemoryMap and ExitBootServices.

#### Hypothesis, and what would support or falsify it

Hypothesis: on strict firmware, any work performed between
GetMemoryMap and ExitBootServices raises the chance that the map key
is no longer current when ExitBootServices is called, which the
firmware reports by failing the exit. FreeBSD's reference structure
avoids this by construction (nothing between the two calls) and by
re-reading the map on failure. Ours does not: it interposes the chain
rebuild and memcpy, and because each retry repeats that same
interposed work, a retry does not converge if the interposed work is
what perturbs the map.

Not established: that the memcpy (or any specific interposed
operation) actually invalidates the key on this firmware. buildChainFull
does not allocate, so there is no obvious mechanism; whether a large
write into an already-reserved staging region perturbs the map on
Apple firmware is unknown. The claim this finding stands behind is
the narrower one: our sequence differs from the working reference in
a way that the reference's own comments identify as firmware-sensitive.

Supporting evidence would be: restructuring the handoff so all
metadata construction precedes a tight GetMemoryMap/ExitBootServices
loop (mirroring bi_load) changes the ExitBootServices outcome. This
is testable in emulation for regression (the kernel must still reach
the mountroot prompt) but its effect on the metal failure cannot be
tested without a bench arming, which is retired; a future metal test
would require an explicit ADR 0005 amendment per Decision 6, and this
restructuring is exactly the kind of specific, source-grounded change
that could justify proposing one.

Falsifying evidence would be: the restructured loader still fails
ExitBootServices in an environment that reproduces the strictness, or
analysis showing the map key is captured and used correctly across
the interposed work (in which case the divergence is cosmetic and the
metal failure lies elsewhere, e.g. the EFI runtime mapping thread,
MOD_LOAD efirt error 6, or SetVirtualAddressMap handling).

#### Proposed follow-on (not yet done)

1. This finding (recorded).
2. Refactor the handoff so all metadata construction occurs before a
   tight GetMemoryMap/ExitBootServices loop, matching FreeBSD's
   structure. Touches the ADR 0005 Decision 3 fail-closed rebuild
   timing, so it needs an ADR note.
3. Validate in emulation via f7probe that the kernel still reaches
   the mountroot prompt (no regression).
4. Leave the physical-hardware question open unless a future explicit
   decision, under ADR 0005 Decision 6, authorizes another bench test.

### F9: pgsd-loader never calls SetVirtualAddressMap, and the kernel says so

**Status: open. Strongest F7 lead to date. Source-grounded, emulation-testable.**

Recorded 2026-07-12, while re-reading the reference loader to plan F8.
It supersedes F8's priority: F8 remains a real sequencing divergence,
but F9 is a missing call, not a reordering, and the kernel already told
us about it.

#### The evidence chain

**1. We never call it.** A search of `pgsd-loader/src/` for
`SetVirtualAddressMap` returns nothing. The loader exits boot services
and jumps to the kernel without ever setting the EFI virtual address
map.

**2. The reference loader does, and AFTER ExitBootServices.**
`stand/efi/loader/bootinfo.c`:

- `efi_do_vmap()` (line 143) walks the memory map and, for every
  descriptor carrying `EFI_MEMORY_RUNTIME`, sets
  `VirtualStart = PhysicalStart` (an identity map), then calls
  `RS->SetVirtualAddressMap(nset * mmsz, mmsz, mmver, vmap)` (line 166).
- `bi_load_efi_data()` calls it at line 313, which is AFTER the
  `ExitBootServices` retry loop (~line 294). This is legal and
  deliberate: SetVirtualAddressMap is a RUNTIME service, not a boot
  service, so it survives the exit.

So the reference sequence is: build metadata, tight
GetMemoryMap/ExitBootServices loop, THEN SetVirtualAddressMap, then
jump. We do the first two (modulo F8's sequencing) and omit the third
entirely.

**3. The kernel detects the omission, and the error code matches what
we saw.** `sys/dev/efidev/efirt.c` (line ~238) says it outright:

  "Some UEFI implementations have multiple implementations of the
  RS->GetTime function. They switch from one we can only use early in
  the boot process to one valid as a RunTime service only when we call
  RS->SetVirtualAddressMap. As this is not always the case, e.g. with
  an old loader.efi, check if the RS->GetTime function is within the
  EFI map, and fail to attach if not."

It then returns `ENXIO`, which is errno **6**.

That is exactly the `MOD_LOAD efirt error 6` observed in the emulation
runs and dismissed at the time as cosmetic. It was not cosmetic. It was
the kernel reporting, precisely, that this loader never called
SetVirtualAddressMap.

#### Why this fits the metal-versus-QEMU split

The kernel comment describes firmware that KEEPS TWO IMPLEMENTATIONS of
its runtime services and switches to the real one only when
SetVirtualAddressMap is called. OVMF (QEMU) does not do this: its
runtime pointers are valid without the call, so omitting it costs
nothing but a failed efirt attach, which is what we saw and shrugged
off. Apple firmware is exactly the class of implementation the comment
is warning about.

This is a hypothesis about the mechanism, not an established cause. What
IS established: we omit a call the reference makes, the kernel detects
the omission, and it reports it with the error code we observed and
ignored.

#### What would support or falsify it

Support: implementing efi_do_vmap's identity-mapping walk and calling
SetVirtualAddressMap after ExitBootServices makes the `MOD_LOAD efirt
error 6` disappear in emulation. That is directly testable, costs
nothing, and is the immediate next step.

Falsify: the error persists after the call is added correctly, meaning
the runtime pointer still is not in the map and something else is wrong.

Neither outcome proves anything about metal on its own. But a loader
that no longer omits a call the working reference makes, and that no
longer draws an error from the kernel saying so, is a materially
different artifact from the one that failed twice.

#### Relationship to ADR 0005 Decision 6

Decision 6 retired metal arming and requires, for any reversal, an
amendment that first states WHAT ABOUT THE METAL HANDOFF HAS CHANGED.

F9 is a candidate answer to that question, and F8 is a second. Neither
is sufficient yet: they are changes to make and verify in emulation.
The bar Decision 6 sets is not "we have a new idea", it is "we have
corrected a specific, source-identified defect in the handoff, and the
correction is verified". F9 is the first defect that meets the
"specific and source-identified" half.

Metal arming remains retired until the corrections are made, verified in
emulation, and an amendment is written.

#### Ownership context

F7 is not a curiosity. It is the difference between disabling FreeBSD's
boot chrome via loader.conf and OWNING the boot path: pgsd-loader
carries no Forth, no Lua, no beastie, and no menu, because none of it
was ever written into it. That is the architecturally correct answer to
"remove the FreeBSD boot UI", and it is what completing F7 buys.

#### F9 erratum: the ordering rule is real; the regression it was blamed for was not

Two things happened here and they must not be conflated, because the
ledger briefly recorded the second as fact when it was not.

**The ordering rule is real and the code is correct.**
`recordVerdict()` is `rs.setVariable()`, a RUNTIME service. The first
cut of F9 recorded its outcome AFTER the vmap call:

    ExitBootServices
    recordVerdict("MARK_EXITED_BOOTSERVICES")   legal
    SetVirtualAddressMap                        runtime services relocate
    recordVerdict("MARK_VMAP_SET")              ILLEGAL: stale pointer
    transferToKernel

The UEFI spec requires that after SetVirtualAddressMap, runtime services
be invoked through the NEW virtual mapping. The loader still holds the
old `system_table.runtime_services` pointer, so calling through it is
undefined. The reference does not do this: after efi_do_vmap
(bootinfo.c:313) it writes only MEMORY (file_addmetadata) and jumps,
making no further firmware call.

The rule, for whoever touches this next:

  Between SetVirtualAddressMap and the kernel jump, the loader may
  touch memory and nothing else. No NVRAM write, no console output, no
  runtime service of any kind.

The marker is therefore written BEFORE the call
(`MARK_VMAP_ATTEMPT`), recording intent rather than outcome. That
change stands on the spec and on the reference, independently of any
observation.

**The "regression" it was blamed for did not exist.** An earlier
revision of this section claimed the post-vmap marker had broken the
transfer, citing an f7probe run in which every kernel landmark was
absent. That run was invalid: `gdb` was not installed on the machine,
so the probe could not attach a debugger and reported every landmark as
not-reached. The all-absent column was an artifact of a missing tool,
not evidence of a fault. A second run, with the same defect, was read
the same way.

With gdb present, the probe reports the transfer intact and unchanged
by F9: cr3 switched, next fetch OK, entry reached, and the kernel runs
through cninit, mi_startup, vfs_mountroot and start_init to the
mountroot prompt with the FreeBSD banner on serial. SetVirtualAddressMap
breaks nothing.

The lesson is the one this campaign keeps teaching and which was
ignored here: read the evidence before explaining it. A causal story
was constructed for an observation that was never real, and it was
written into this ledger as fact. The correction is recorded rather
than quietly removed, because a ledger that hides its own errors is
worth less than one that does not.


#### F9 status after the first valid probe run (2026-07-12)

With gdb installed and the probe therefore able to attach:

    Transfer:     cr3 switched, next fetch OK, entry reached
    Bring-up:     amd64_loadaddr, native_parse_preload_data, getmemsize,
                  init_param1, cninit, mi_startup, vfs_mountroot,
                  start_init all reached
    Serial:       FreeBSD copyright banner present; reaches the
                  mountroot> prompt
    NVRAM:        MARK_MAP_CAPTURED, MARK_CHAIN_REBUILT,
                  MARK_EXITED_BOOTSERVICES, MARK_VMAP_ATTEMPT

Established: F9 does not break the transfer. SetVirtualAddressMap is
called, the loader jumps, and the kernel boots exactly as it did before
F9. The regression scare was a tooling artifact (see the erratum above).

Not yet established, and the reason F9 exists: whether
`MOD_LOAD efirt error 6` is gone from the serial log. That is F9's
entire claim, and it is a single grep away. Until it is checked, F9 is
implemented and harmless but unproven.

    grep -i efirt /tmp/f7probe-serial.log

If the error is gone, the efirt.c reading was right and a real defect in
the handoff has been corrected: the first of the two ADR 0005 Decision 6
requires. If it persists, F9's mechanism is wrong, the hypothesis dies
cheaply, and the correction cost nothing but a rebuild.

#### F9 falsified as stated; the error-6 path was never identified

The probe with F9 in place: SetVirtualAddressMap is called, the
firmware accepts it, the transfer is unharmed, the kernel boots to the
mountroot prompt, and:

    module_register_init: MOD_LOAD (efirt, 0xffffffff8060b9b0, 0) error 6

The error persists. F9 as stated is FALSIFIED, which is what emulation
is for and which cost a rebuild.

The reason it could be falsified so cheaply, and the reason it should
not have been asserted so confidently, are the same. `efi_init()` in
sys/dev/efidev/efirt.c has SIXTEEN ENXIO returns. Two of them can
produce this, and they say entirely different things:

    efirt.c:234  "EFI runtime services table is not present"
                 efi_systbl->st_rt == 0. The system table we handed the
                 kernel has a NULL runtime-services pointer.

    efirt.c:254  "EFI runtime services table has an invalid pointer"
                 The GetTime pointer is not inside the EFI map. This is
                 the one F9 addressed, by calling
                 SetVirtualAddressMap.

F9 was built on the assumption that the second was firing. That
assumption was never checked. It could not have been checked from the
evidence we had, because BOTH messages are gated behind `bootverbose`,
and every probe run to date has shown a bare "error 6" with no message
at all.

So the honest position is not "F9 was wrong". It is: we do not know
which defect we have, we never did, and F9 addressed one of two
candidates on a guess.

Next step, and it is one line: the loader now sets `boot_verbose=1` in
the kernel environment, alongside the console binding and acpi.rsdp it
already publishes. With bootverbose on, the kernel names the failing
check. One probe run distinguishes:

  - "not present" => the systbl->st_rt we pass is null, which is a
    metadata defect in our handoff and has nothing to do with the
    virtual map. F9 is then irrelevant to error 6 (though its ordering
    rule and the vmap call itself remain correct, and the reference
    makes both).

  - "invalid pointer" => the GetTime pointer is outside the EFI map
    even after a successful SetVirtualAddressMap, which means F9's
    mechanism is right in principle and wrong in execution: most likely
    the EFI map we pass the kernel (MODINFOMD_EFI_MAP) is the map we
    captured BEFORE the vmap, and therefore describes the pre-relocation
    layout rather than the post-relocation one the kernel checks
    against.

That second possibility is worth stating plainly, because it is the
obvious next hypothesis and it is testable: we capture the map, prepare
the vmap, exit, call SetVirtualAddressMap, and hand the kernel the map
we captured. The reference does the same, so this may be a false lead,
but it is the first thing to check if the message says "invalid
pointer".

Ask the kernel. Stop guessing.
