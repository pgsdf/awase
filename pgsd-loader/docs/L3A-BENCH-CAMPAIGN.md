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

#### Erratum: boot_verbose is not an environment variable

The `boot_verbose=1` kernel-environment entry added in the previous
increment does nothing. The kernel does not read such a variable.

`bootverbose` is set from a BIT in the boothowto word:
sys/kern/init_main.c does `if (boothowto & RB_VERBOSE)`, and
sys/sys/reboot.h defines `RB_VERBOSE` as 0x800. boothowto reaches the
kernel as `MODINFOMD_HOWTO` (0x0007) metadata, which our loader does
pass, with `RB_SERIAL` set so the console comes up. `RB_VERBOSE` was
simply never set.

So the probe run after that change was uninformative by construction:
error 6 with no message, exactly as before, because the kernel still
had bootverbose off and its two distinguishing messages are both
printed only `if (bootverbose)`.

Corrected: the howto word now carries `RB_SERIAL | RB_VERBOSE`, and the
bogus env entry is removed.

This is the third time in this finding that a conclusion was drawn
before the mechanism was checked (the gdb-absent probe read as a
regression; the efirt error attributed to one of two paths on a guess;
bootverbose set through the wrong interface). The pattern is the same
each time: a plausible story reached for before the source was read.
The source has the answer in every case, and reading it first is
cheaper than every one of these detours has been.

#### F9 root cause, found: virtual_start was never written to the map the kernel receives

With RB_VERBOSE finally set, the kernel named the failing check:

    EFI runtime services table has an invalid pointer
    module_register_init: MOD_LOAD (efirt, ...) error 6

That is efirt.c:254, not efirt.c:234. So `efi_systbl->st_rt` is
NON-null: the system table pointer we pass is good, and this was never
a missing-metadata problem. The failure is that the kernel cannot find
the GetTime pointer inside the EFI map.

Reading what the kernel actually checks makes the bug exact.
sys/dev/efidev/efirt.c efi_is_in_map():

    if ((p->md_attr & EFI_MD_ATTR_RT) == 0)
            continue;
    if (addr >= p->md_virt &&
        addr < p->md_virt + p->md_pages * EFI_PAGE_SIZE)
            return (true);

It tests the GetTime address against `p->md_virt`, the descriptor's
VIRTUAL start. Not its physical start.

And the reference fills that field in, on the very buffer it hands the
kernel. stand/efi/loader/bootinfo.c efi_do_vmap():

    if ((desc->Attribute & EFI_MEMORY_RUNTIME) != 0) {
            ++nset;
            desc->VirtualStart = desc->PhysicalStart;   <-- mutates mm
            *viter = *desc;                             <-- then copies

`desc` walks `mm`, and `mm` is what bi_load_efi_data later passes to
file_addmetadata as MODINFOMD_EFI_MAP. The mutation looks incidental
and is not: it is the entire mechanism by which the kernel can locate
the runtime services.

Two defects, both now fixed:

1. prepareVirtualMap built the identity map into a SEPARATE buffer and
   left the original untouched, so every virtual_start in the map handed
   to the kernel was still zero. It now writes virtual_start into the
   original map in place, as the reference does, and copies the mapped
   descriptor into the compacted buffer the firmware call takes. The
   firmware wants the runtime subset; the kernel wants the whole map
   with virtual_start filled in. Both are now satisfied from one walk.

2. ORDER. prepareVirtualMap ran AFTER buildChainFull, so even the
   in-place fix would have been too late: the chain had already copied
   the map into the kernel's staging area. It now runs immediately after
   captureMemoryMap and before the chain is built. The reference has no
   such bug because efi_do_vmap mutates the same buffer it later hands
   to file_addmetadata, and it runs first.

So F9's mechanism was right and its execution was wrong in two places,
which is what the falsification said and what the kernel, once asked
properly, confirmed. The firmware call always succeeded. The metadata
was wrong.

The test now asserts the thing that matters: after prepareVirtualMap,
the ORIGINAL map carries virtual_start == physical_start for every
runtime descriptor, and non-runtime descriptors are left alone.

#### F9 VERIFIED (2026-07-12)

    efirtc0: <EFI Realtime Clock>
    efirtc0: registered as a time-of-day clock, resolution 1.000000s

No "invalid pointer". No MOD_LOAD error 6. efirt does not merely stop
failing: it ATTACHES and registers a working device, which means the
kernel is successfully calling into EFI runtime services through the
virtual map the loader now sets. That is positive proof of the whole
chain, and a stronger result than the absence of an error.

The transfer is unharmed: cr3 switched, next fetch OK, entry reached,
and the kernel runs through cninit, mi_startup, vfs_mountroot and
start_init to the mountroot prompt. (The prompt is expected: QEMU has
no zroot pool. It is where this probe has always stopped and is not a
fault.)

**F9 is closed.** The loader now does what the reference does at the
EFI handoff:

  - identity-maps the runtime descriptors in the map it hands the
    kernel (virtual_start = physical_start), which is what
    efi_is_in_map() checks;
  - does that BEFORE building the module chain, so the mapped
    descriptors are what reach MODINFOMD_EFI_MAP;
  - calls SetVirtualAddressMap after ExitBootServices, with the
    compacted runtime subset;
  - makes no firmware call between that and the kernel jump.

#### What F9 cost, and what it teaches

Four wrong turns, each the same mistake: a conclusion reached before the
mechanism was checked.

  1. A probe run with every landmark absent was read as a transfer
     regression. gdb was not installed. The evidence column was an
     artifact of a missing tool.
  2. Error 6 was attributed to efirt.c:254 on a guess. efi_init() has
     sixteen ENXIO returns and two could produce it, saying entirely
     different things.
  3. bootverbose was set through a kernel environment variable. It is a
     boothowto BIT (RB_VERBOSE), and the env entry did nothing, so the
     run that was supposed to settle (2) could not.
  4. The vmap was built into a separate buffer, on the assumption that
     the firmware call was the point. The point was the METADATA: the
     reference's `desc->VirtualStart = desc->PhysicalStart` mutates the
     buffer it later hands the kernel, and that line, which looks
     incidental, is the entire mechanism.

Every one of these was answerable from the FreeBSD source, and in every
case the source was skimmed until something plausible was found rather
than read until the mechanism was understood.

The rule this finding earns:

  When the kernel reports an error, make the kernel say WHICH error
  before theorising about WHY. It knows. Ask it.

#### Standing on F9

Two of the three known F7-era defects in the EFI handoff are now
corrected and verified in emulation: the console binding and ACPI RSDP
(F7 itself), and the EFI runtime map (F9). One remains: F8, the
sequencing divergence, where the reference builds all metadata before a
tight GetMemoryMap/ExitBootServices loop and this loader interposes the
chain rebuild between the map capture and the exit.

ADR 0005 Decision 6 (metal arming retired) requires, for any reversal,
an amendment stating what about the metal handoff has CHANGED. F9 is now
a real, source-identified, verified correction to that handoff, and it
is the first thing this campaign has produced that meets that bar. It is
not sufficient on its own: F8 remains, and the amendment should be
written against a handoff with both corrected, not one.

#### F8 root cause and fix: the exit window had two firmware calls in it

F8 was recorded as "a sequencing divergence": the reference builds all
metadata before a tight GetMemoryMap/ExitBootServices loop and this
loader interposes the chain rebuild. Reading bi_load() properly makes it
exact, and worse than recorded.

**The reference exits boot services BEFORE serializing the chain.**
stand/efi/loader/bootinfo.c bi_load():

    file_addmetadata(HOWTO, ENVP, KERNEND, MODULEP, FW_HANDLE, ...)
    bi_load_efi_data(kfp, exit_bs)   <- captures map, EXITS, does vmap
    md_copymodules(0, is64)          <- THEN copies the chain into
                                        kernel memory

Everything before the exit is file_addmetadata, which appends records to
a list in the loader's OWN heap. No firmware call. No allocation from
the firmware. The bytes only reach kernel memory afterwards, when boot
services are gone and nothing can move the map.

And inside bi_load_efi_data, the window is empty by construction. The
inner `for (;;)` grows the buffer and re-fetches the map, so the final
successful GetMemoryMap has no allocation after it; the outer
`for (retry = 2; ...)` re-runs the whole thing if ExitBootServices fails
on a stale key. That structure exists for a reason the comment states:
Matthew Garrett observed firmware changing the memory map during
ExitBootServices, "probably because callbacks are allocating memory".

**We were doing five things in that window, two of them firmware
calls:**

    recordVerdict("MARK_MAP_CAPTURED")     <- SetVariable
    prepareVirtualMap(fmap)
    buildChainFull(...)
    memcpy(kernel staging, chain)
    recordVerdict("MARK_CHAIN_REBUILT")    <- SetVariable

SetVariable is exactly the class of call the retry loop is defending
against. We were making it twice, inside the window the defence
protects, and then copying into kernel staging as well.

**Fixed.** The chain is now built into a LOCAL buffer before the exit
(memory only, the analogue of file_addmetadata), the window between
captureMemoryMap and exitBootServices contains no firmware call at all,
and the copy into kernel staging happens AFTER the exit, as
md_copymodules does. The success path is now:

    captureMemoryMap        (allocates, then fetches: key valid after)
    prepareVirtualMap       (memory: writes virtual_start in place)
    buildChainFull          (memory: into a local buffer)
    ---- exitBootServices ----   nothing between it and the capture
    MARK_EXITED_BOOTSERVICES
    memcpy -> kernel staging     (memory, boot services gone)
    MARK_VMAP_ATTEMPT
    SetVirtualAddressMap         (last firmware call)
    transferToKernel

ADR 0005 Decision 3 (fail closed) is preserved: the chain is still built
from the FINAL map, and a rebuild failure still aborts to chainload
rather than exiting boot services on a stale one. The marker on that
path is legal because boot services are still live there. Only the
success path changed, and only in where the bytes land and when.

The MARK_MAP_CAPTURED and MARK_CHAIN_REBUILT breadcrumbs are gone.
They were diagnostics, and they were being written in the one window
where a firmware call is least defensible. The evidence they carried is
now covered by MARK_EXITED_BOOTSERVICES (which partitions the fault
either side of the exit) and by the fail-closed abort marker.

#### F8 VERIFIED, and all three defects hold together (2026-07-12)

Markers:

    BOOT_ATTEMPT ...
    MARK_EXITED_BOOTSERVICES
    MARK_VMAP_ATTEMPT

MARK_MAP_CAPTURED and MARK_CHAIN_REBUILT are gone: the two SetVariable
calls are out of the exit window. The transfer is intact (cr3 switched,
entry reached, kernel to the mountroot prompt), and:

    efirtc0: <EFI Realtime Clock>
    efirtc0: registered as a time-of-day clock, resolution 1.000000s

F9 still holds after the F8 restructure. That was the check worth
making: the F9 fix depends on prepareVirtualMap running before
buildChainFull reads the map, and F8 moved both. They compose.

**All three known EFI-handoff defects are now corrected and verified in
emulation:**

    F7  boot environment (console binding, ACPI RSDP)
    F9  EFI runtime map (virtual_start, SetVirtualAddressMap)
    F8  exit window (no firmware calls between GetMemoryMap and exit)

Each identified against FreeBSD's own loader.efi, the reference that
boots this bench today. None guessed.

**ADR 0005 Decision 7 (2026-07-12)** records this as the amendment
Decision 6 required, and unblocks metal arming under the Decision 4
one-cycle protocol. It is deliberately not a recommendation: emulation
success does not imply metal success (Decision 2), and F8's fix repairs
a hazard OVMF does not exercise at all, so its value cannot be
demonstrated in emulation. A third reinstall remains a possible outcome
and the operator should accept that before arming.

If the transfer fails on metal again with all three defects corrected,
that is a significant finding in itself, and the campaign should not
retry a fourth time without a new, specific, source-identified defect.
The standard does not relax because we have run out of ideas.

#### deploy.sh re-exercised against the mock harness (2026-07-12)

ADR 0005 Decision 7's first precondition: deploy.sh had been edited
since it was deprecated (the header, the guard) but never RUN. That is
precisely the condition that bricked the bench the first time: code
carefully written and never executed.

Four tests against a mock efibootmgr maintaining fake BootOrder and
entry state. All pass.

1. **The Decision 7 guard refuses.** arm-once without
   PGSD_DEPLOY_ACK=i-have-read-adr-0005-decision-7 exits non-zero and
   explains why, naming the three corrected defects and the reinstall
   risk.

2. **arm-once arms correctly.** With acknowledgement: the prior
   BootOrder is saved, a new entry is created ACTIVE, and it lands at
   the ORDER HEAD (0004,0000,0003,...). Both properties matter: this
   bench's firmware ignores BootNext (finding F1) and skips inactive
   entries (F2), so an armed entry must be both active and first.

3. **recover restores exactly.** The saved order is restored byte for
   byte, the armed entry is reaped, and the saved-order file is removed.
   No PGSD entry survives.

4. **The crash-safe trap holds under injected failure.** With
   head-placement made to fail mid-arm, which is the EXACT scenario that
   bricked the bench, deploy.sh detected it, fired its EXIT trap,
   disarmed, restored the order, reaped the entry, and exited non-zero
   with nothing armed. The failure that cost a reinstall now
   self-recovers.

deploy.sh is therefore exercised, not merely reviewed. The other two
Decision 7 preconditions (a tested recovery path, and the operator
accepting the reinstall risk before arming) are the operator's, not the
tooling's.

#### F10: stage armed the ESP's firmware-fallback path and recover never restored it

Found while checking the bench's recovery margin before arming under
Decision 7. It is the most consequential safety defect the campaign has
produced, and it probably explains why the second brick was
unrecoverable.

`stage` overwrites `\EFI\BOOT\BOOTX64.EFI` with the armed
boot-launcher. That path is the UEFI removable-media fallback: it is
what firmware boots when it has no valid NVRAM entry to use.

`recover` only ever touched NVRAM. It restored the BootOrder and reaped
the armed entry, and left BOOTX64.EFI overwritten. So after a
"successful" recover the ESP was STILL ARMED, and more importantly:

  An NVRAM reset did not recover the machine. It re-armed it.

Clear the boot variables, and the firmware falls back to
\EFI\BOOT\BOOTX64.EFI, which was the armed launcher, and runs the
transfer that just failed. That is almost certainly what happened on the
second brick: Option-Cmd-P-R was tried, "did not help", and the machine
was declared unrecoverable. It was not unrecoverable. The reset was
booting the armed loader.

`status` reported only NVRAM, which is how this survived two bricks
without anyone noticing.

Fixed:

  - stage backs up the original BOOTX64.EFI to
    EFI/BOOT/BOOTX64.EFI.pgsd-orig BEFORE overwriting it, and refuses to
    stage if the backup fails. It never overwrites an existing backup,
    because a second stage would otherwise save the ARMED launcher as
    the "original" and destroy the real one. If there was no BOOTX64.EFI
    at all, it records that so recover removes ours rather than
    restoring something that never existed.
  - recover restores it, and says so. If the restore fails it says
    loudly that the ESP is still armed and an NVRAM reset would boot the
    transfer.
  - the crash-safe EXIT trap in arm-once calls recover, so a mid-arm
    failure now disarms BOTH NVRAM and the ESP.
  - status reports the ESP fallback path separately from NVRAM, because
    they arm and disarm independently and this is the one that decides
    whether an NVRAM reset saves the machine.

The backup lives on the ESP, not the root filesystem, deliberately: if
the machine will not boot, the ESP is reachable from a USB installer
with a FAT mount, and a ZFS root may not be. Recovery data belongs where
recovery happens.

Verified against the mock harness: stage backs up and status reports
ARMED; recover restores the stock loader and clears the backup; and an
injected mid-arm failure disarms both NVRAM and the ESP.

**This materially changes the risk of arming.** Before it, an NVRAM
reset was not an escape hatch, it was a trap. After it, Option-Cmd-P-R
boots the stock FreeBSD loader.

### F11: the Option-key picker boots the ESP fallback, not the NVRAM entry

**Status: established. This bench has never had a working recovery path
while the ESP was staged.**

Discovered 2026-07-12 by a free test proposed before arming under
Decision 7: with the ESP STAGED but NVRAM NOT ARMED, reboot, hold
Option, select the disk, and confirm it boots. It did not. Blank screen.
The operator recovered by power-cycling.

#### What that proves

NVRAM at the time of the test:

    BootCurrent: 0000
    BootOrder  : 0000
    +Boot0000* FreeBSD ... \efi\freebsd\loader.efi
    (no PGSD entry, no pending recovery)

The only thing staged was the ESP: `\EFI\BOOT\BOOTX64.EFI` was the pgsd
boot-launcher (F10 backup in place).

The picker booted to a blank screen. With no armed NVRAM entry, the only
thing that can produce the transfer's signature is
`\EFI\BOOT\BOOTX64.EFI`. So:

  This firmware's Option-key picker boots the ESP's removable-media
  fallback path, NOT the NVRAM boot entry.

#### Why this matters more than anything else in the campaign

**It explains the second brick.** We armed, the transfer failed, we held
Option, selected the single entry, got a blank screen, tried an NVRAM
reset, got nothing, and declared the machine unrecoverable. Every one of
those recovery routes went through `\EFI\BOOT\BOOTX64.EFI`, which was
armed. The machine was never broken. The recovery paths were.

**The arming protocol has never had a working escape hatch.** ADR 0005
Decision 4's one-cycle discipline rests on "recovery path always
reachable". It was not reachable. Both metal attempts were made with a
recovery story that could not have worked, and we did not know because
`status` reported only NVRAM (F10) and because the picker was never
tested against a staged-but-unarmed ESP.

**It also weakens the F7 evidence.** Both metal failures were read as
"the transfer does not boot on Apple firmware". That may still be true.
But the blank screens we used as evidence could equally have been the
Option picker and the NVRAM reset booting the armed fallback path, which
is a different fault with a different cause. F7's metal reproduction is
now less certain than it was, not more.

#### Consequence for Decision 7

Metal arming must not proceed on this protocol. Not because the handoff
is unfixed (F7, F8, F9 are corrected and verified), but because
**arming a machine whose only recovery route runs through the armed
artifact is not a one-cycle experiment, it is a coin flip.**

Before any metal attempt, the protocol needs a recovery path that does
not pass through the ESP:

  - A FreeBSD USB installer, TESTED to boot on this bench, from which
    the ESP can be restored by hand (mount FAT, copy
    BOOTX64.EFI.pgsd-orig back over BOOTX64.EFI). This is now the ONLY
    known-good route, and it must be verified BEFORE arming, not after
    a failure.
  - Or: do not stage BOOTX64.EFI at all. If the armed entry can be
    launched from a distinct ESP path that the fallback does not use,
    the fallback stays stock and the picker recovers the machine. This
    is the better fix and it should be investigated: it removes the
    hazard rather than adding a rescue for it.

The second option is the right one. deploy.sh overwrites BOOTX64.EFI
because boot-launcher is what starts the armed `-boot.efi` name; if the
NVRAM entry can point directly at a pgsd path under `\EFI\pgsd\`,
BOOTX64.EFI never needs touching and the machine keeps a stock recovery
path throughout.

#### F11 fixed: stop staging BOOTX64.EFI; arm the pgsd path directly

The hazard is removed rather than rescued.

**BOOTX64.EFI was never necessary.** pgsd-loader triggers its armed path
from its own FILENAME: `bas_boot.bootArmed()` matches
"pgsd-loader-boot.efi". It does not read load options. boot-launcher
exists only to pass an option string that FreeBSD's efibootmgr cannot
attach to a boot entry, and its own header says what it is:

    "emulation-only harness ... Never deployed to hardware."

It was being deployed to hardware, as the firmware fallback, on every
stage.

**Fixed.** stage no longer touches \EFI\BOOT\BOOTX64.EFI. The armed
loader already lived at \EFI\pgsd\pgsd-loader-boot.efi, so arm-once now
points the NVRAM entry straight at it. No launcher, no options, no
fallback hijack.

The consequence is the one that matters:

    The Option-key picker now boots the stock FreeBSD loader.
    An NVRAM reset now boots the stock FreeBSD loader.

Both were armed before. Both are recovery routes again.

recover keeps its BOOTX64 restore, reframed as legacy cleanup: it fires
only on a machine staged by an older tree, which is exactly when it is
most needed, because such a machine has no working recovery path until
the fallback is put back. status reports the fallback as "stock" now,
and says loudly if it ever finds it armed.

Verified against the mock: stage leaves BOOTX64.EFI byte-identical and
creates no backup (nothing to back up); arm-once points the boot entry
at the pgsd path.

**This, not the handoff fixes, is what makes a metal attempt
defensible.** F7, F8 and F9 made the transfer more likely to work. F10
and F11 made a failure survivable. The second was missing for both
previous attempts.

#### F11 fix VERIFIED on hardware (2026-07-12)

The same test that exposed F11, repeated with the fix in place: ESP
STAGED, NVRAM NOT ARMED, reboot, hold Option, select the disk.

Before the fix: blank screen. The picker was booting the armed
BOOTX64.EFI.

After the fix: **the FreeBSD boot menu appeared.** The picker reaches
the stock loader.

status at the time:

    BootOrder  : 0000
    armed entry: (none)
    ESP firmware-fallback: not armed

So with the ESP staged, the firmware fallback is stock and the Option
picker is a working recovery route. That state has not existed before
in this campaign.

**All Decision 7 preconditions are now satisfied, and one of them was
not satisfiable before today:**

  - deploy.sh exercised end-to-end against the mock harness, including
    the injected mid-arm failure that bricked the bench (verified).
  - A recovery path that does not pass through the armed artifact
    (verified ON HARDWARE, above). This is the one that was missing for
    both previous metal attempts, and nobody knew.
  - The operator accepts the reinstall risk.

The metal attempt may proceed.

### F12: the loader completes on metal; the fault is after the jump

**Third metal attempt, 2026-07-12. Bench recovered. No reinstall.**

Armed under Decision 7 with F7, F8, F9 corrected and F10/F11 giving a
recovery path for the first time. Result: blank screen. Power-cycled,
held Option, got the stock FreeBSD loader, booted, ran recover. Clean.

The bench surviving is itself the result that four hours of work bought,
and it is why this attempt produced evidence instead of a reinstall.

#### The evidence

    PgsdBasVerdict = "MARK_VMAP_ATTEMPT"

recordVerdict() uses SetVariable, which OVERWRITES, so the variable
holds the LAST marker written. MARK_VMAP_ATTEMPT is the final marker
before transferToKernel. Its presence means, in order:

    BOOT_ATTEMPT              written, then overwritten
    ExitBootServices          RETURNED SUCCESSFULLY on Apple firmware
    MARK_EXITED_BOOTSERVICES  written, then overwritten
    chain copied to staging
    MARK_VMAP_ATTEMPT         written  <- survives
    SetVirtualAddressMap
    transferToKernel          the jump was taken

**The loader executed its entire sequence on real Apple hardware and
jumped to the kernel.**

#### What this relocates

F7 has been characterised for weeks as "the transfer does not boot on
Apple firmware", with the loader's handoff under suspicion. That is now
false in its most important part:

  - ExitBootServices returns. It does not reset the machine.
  - The exit window (F8) survives on metal.
  - The loader reaches and takes the jump.

The fault is AFTER the jump: the kernel does not come up, or comes up
with no console. That is a different problem in a different place, and
for the first time it is bounded.

Two immediate candidates, both testable:

1. **No console.** The kernel may be running and simply not talking.
   Emulation proved the serial binding works, but this bench's serial
   path may differ (the console=comconsole / hw.uart.console=io:0x3f8
   binding assumes a legacy UART at a fixed port; an Apple machine may
   not have one). A kernel booting silently would present exactly as
   this does.

2. **Early kernel fault before console init.** The kernel may be
   faulting between entry and cninit, which in emulation is where
   amd64_loadaddr, hammer_time and native_parse_preload_data run. Those
   read the page tables and metadata the loader built, and the loader's
   page tables are the one thing emulation cannot fully validate against
   Apple's memory layout.

The first is much cheaper to test and should go first: give the kernel a
console it can definitely use on this hardware, or an early marker path
that does not depend on one.

#### Standing

The campaign now has, for the first time, a metal attempt that produced
evidence rather than a reinstall, and a fault localized to a specific
region. Decision 7's protocol worked exactly as designed: one cycle,
recovery reachable, evidence recovered.

### F13: the loader was mounting a root that has not existed for three reinstalls

**This is F7's actual cause. Everything else was real, and none of it
was this.**

The loader hardcoded:

    vfs.root.mountfrom=zfs:zroot/ROOT/awase-verified-pgsd-clean

The bench has one boot environment:

    zroot/ROOT/default

`awase-verified-pgsd-clean` was created during an install THREE
reinstalls ago. It has not existed for weeks.

#### The presentation, end to end

1. The loader hands off correctly. Proven on metal: the third attempt
   left MARK_VMAP_ATTEMPT in NVRAM, so ExitBootServices returned, the
   chain was staged, the vmap was attempted, and the jump was taken
   (F12).
2. The kernel boots, initialises, probes devices.
3. It tries to mount a root that does not exist.
4. It drops to the `mountroot>` prompt and waits for input.
5. That prompt is INVISIBLE. AD-39 removes vt, vt_efifb, sc and vga so
   that drawfs can own the framebuffer, leaving `device uart` as the
   only console. We bind it with hw.uart.console=io:0x3f8, a legacy ISA
   port that an Apple machine does not have.
6. A kernel waiting forever at an invisible prompt is a blank screen.

Every step of that is correct behaviour. The kernel did exactly what it
was told. It was told to mount a filesystem that was not there.

#### f7probe was showing us this the whole time

Every emulation run ended at `mountroot>`. It was explained away, in
this ledger and repeatedly in conversation, as "QEMU has no zroot pool,
which is expected and not a loader fault".

The bench HAS a zroot pool. It failed anyway. The name was wrong in both
places, so the same failure was appearing in both and being read as two
different things: an expected artifact in emulation, and a mysterious
brick on metal.

The tool was correct. The interpretation was not.

#### Fixed

    vfs.root.mountfrom=zfs:zroot/ROOT/default

#### The design flaw that caused it, which the fix does not address

The loader HARDCODES the root. The stock loader DERIVES it: stand/common
/boot.c builds `<fstype>:<device>` from the pool it actually booted from
and sets vfs.root.mountfrom (line 382-384), reading the pool's bootfs
property. A hardcoded root is a landmine that goes off on the next
reinstall, and it went off on this one.

Two follow-ups, neither done:

  - Derive the root rather than hardcode it, as the reference does. This
    is the real fix and it is a substantial piece of work (the loader
    would need enough ZFS to read the pool's bootfs property).
  - Make the failure LOUD. A wrong root currently produces an invisible
    prompt and an infinite hang. The kernel can be told to time out
    rather than prompt (vfs.mountroot.timeout), which would at least
    turn a silent hang into a reboot, leaving the NVRAM breadcrumb
    intact and the failure legible.

The second is cheap and should be done regardless. A console-less kernel
must never be allowed to wait for input it cannot ask for.

### F14: pgsd-loader does not load modules, so drawfs never comes up

Fourth metal attempt, with F13 (the stale root) fixed. Still a blank
screen. Bench recovered via the Option key and the stock loader, as
before. `PgsdBasVerdict = MARK_VMAP_ATTEMPT`, unchanged: the loader
still completes and jumps.

F13 was real and was not sufficient.

#### The gap

`pgsd-loader` builds a module chain with exactly ONE entry:

    metadata.buildChainFull(..., .{ .name = "kernel", ... })

It never reads `/boot/loader.conf`. It has no concept of a `.ko` file.
It loads the kernel and nothing else.

But drawfs is a PRELOADED module. install.sh writes `drawfs_load="YES"`
to `/boot/loader.conf`, and the STOCK loader reads that file and places
drawfs.ko in memory before the kernel starts. install.sh says so
directly: "drawfs.ko is auto-loaded from /boot/loader.conf".

So on an armed boot:

  - The kernel boots and (since F13) mounts zroot/ROOT/default.
  - drawfs.ko is never loaded, because the loader never preloaded it and
    never read loader.conf.
  - Nothing owns the framebuffer, because AD-39 removed vt/vt_efifb/sc/
    vga precisely so that drawfs could own it.
  - Nothing draws.

The kernel is very likely running correctly, with no console and no
drawfs, painting nothing. A blank screen.

#### The cheap experiment that settles it

Arm, boot, and see whether the bench answers on the network. If it does,
the kernel is booting fine and this is purely a "nothing is drawing"
problem, which localizes the fault to module loading and nothing else.
One reboot, no code.

#### Two ways forward, and they are not equivalent

**A. Compile drawfs into the kernel.** It comes up with the kernel, no
loader involvement. Simple, and it guarantees drawfs is present before
anything can touch the framebuffer. But it welds a cleanly separable
subsystem into the kernel image, costs the ability to kldunload during
development, and does nothing for inputfs and audiofs, which have the
same dependency on being loaded.

**B. Teach pgsd-loader to preload modules.** This is what a loader is
FOR, and it is what the stock loader does: read the .ko, place it in
memory, and add an entry to the module chain with its metadata. Real
work, and it makes pgsd-loader an actual loader rather than a
kernel-jumper.

A is the right near-term move and B is the right end state. A loader
that cannot load modules will hit this again with inputfs and audiofs,
and "compile everything into the kernel" is not a strategy, it is a
workaround that scales badly.

### F15: the kernel cannot mount a ZFS root, because pgsd-loader cannot preload zfs.ko

Fifth metal attempt, with drawfs compiled into the kernel. Still blank.
`MARK_VMAP_ATTEMPT` unchanged: the loader still completes and jumps.

Compiling drawfs in was correct and necessary and did not help, because
the kernel never gets far enough for drawfs to matter.

#### The evidence

`/boot/loader.conf` on the bench:

    kern.geom.label.disk_ident.enable="0"
    kern.geom.label.gptid.enable="0"
    zfs_load="YES"
    mac_do_load="YES"
    drawfs_load="YES"
    hw.inputfs.dev_gid=1002
    hw.inputfs.dev_mode=0640

**`zfs_load="YES"`.** ZFS is a MODULE. It is not compiled into the PGSD
kernel, and it is not compiled into GENERIC either: FreeBSD ships it as
a module and the loader preloads it.

pgsd-loader builds a module chain with exactly one entry, the kernel. So
on an armed boot:

  1. The loader jumps (MARK_VMAP_ATTEMPT).
  2. The kernel boots, initialises, probes devices.
  3. It tries to mount zfs:zroot/ROOT/default (correct, since F13).
  4. **The kernel has no ZFS support.** zfs.ko was never loaded.
  5. It cannot mount root, and drops to mountroot>.
  6. No console (AD-39). Blank screen.

Same presentation as F13, different cause. The root path is now right and
the kernel still cannot mount it, because it does not know what ZFS is.

#### This forces the architecture

**pgsd-loader must be able to preload modules. This is no longer
optional.**

It is not a convenience for inputfs and audiofs, which load from rc.d
after root and never needed the loader. It is required TO BOOT AT ALL,
because the root filesystem depends on a module that must be in memory
before the kernel looks for root. There is no kldload path out of it:
the module has to be there first.

F14 observed that "a loader that cannot load modules is a kernel-jumper,
not a loader". F15 is the bill for that.

#### The alternatives, honestly

**A. Teach pgsd-loader to preload modules.** The real fix. Read zfs.ko
from the ESP, place it in memory, add a second entry to the module chain
with the correct MODINFOMD_* metadata (name, type, addr, size), and
extend kernend past it. This is what a loader is. Substantial work, and
it is now on the critical path rather than beside it.

**B. Compile ZFS into the kernel.** It would work and it sidesteps A.
But it means building OpenZFS into every PGSD kernel, and the same trap
waits for the next thing the loader needs to preload. It converts a
missing capability into a growing list of exceptions.

**C. UFS root.** Sidesteps ZFS. Fights the rest of the stack (boot
environments, snapshots, the reinstall runsheet) and solves nothing
general.

A. The others are ways of not writing a loader.

#### The observation that would have found this in one reboot

We have inferred the entire post-jump world from a blank screen and one
NVRAM marker, for five attempts. The bench has a network. A single ping
during an armed boot would have said, immediately, whether the kernel
was reaching userspace at all. It is not: it dies at mountroot, before
init, before rc, before drawfs could matter, which makes every userspace
theory we entertained (chronofs timing, audiofs clock, semadrawd
blocking) beside the point.

Ping the bench on the next armed boot. It costs nothing and it bounds
the fault immediately.

### F16: the loader must LAY OUT a module's sections, not just copy its bytes

Sixth metal attempt, with zfs.ko preloaded. No screen, no ping. But this
time there was evidence, because PgsdModules records the module outcome
to NVRAM and survives the reboot:

    zfs.ko OK size=5889984 addr=0x1c01000 shnum=33

So the loader read the module from the attested slot, parsed it, found 33
section headers, placed it at 0x1c01000, and described it to the kernel.
READ_FAILED and PARSE_FAILED are both eliminated. The loader did exactly
what ADR 0006 told it to do.

**ADR 0006 was wrong.** Its central claim is that "the loader places the
raw .ko bytes in memory and describes them" and that the kernel does the
rest. The second half is true and the first is not.

#### What the kernel actually expects

sys/kern/link_elf_obj.c link_elf_link_preload(), after reading the six
records:

    /* XXX, relocate the sh_addr fields saved by the loader. */
    off = 0;
    for (i = 0; i < hdr->e_shnum; i++) {
            if (shdr[i].sh_addr != 0 && (off == 0 || shdr[i].sh_addr < off))
                    off = shdr[i].sh_addr;
    }
    for (i = 0; i < hdr->e_shnum; i++) {
            if (shdr[i].sh_addr != 0)
                    shdr[i].sh_addr = shdr[i].sh_addr - off +
                        (Elf_Addr)ef->address;
    }

The comment says it: "the sh_addr fields SAVED BY THE LOADER". The kernel
takes the lowest non-zero sh_addr as a base and rebases every section
onto MODINFO_ADDR. It does not assign addresses; it RELOCATES addresses
the loader already assigned.

A .ko off disk is ET_REL. Every sh_addr in it is ZERO, because
relocatable objects have no assigned addresses. So with the raw table we
passed: off stays 0, the rebase loop never fires, every section keeps
sh_addr == 0, and the kernel's own checks (link_elf_obj.c lines 66, 79,
84: `if (shdr[i].sh_addr == 0)`) reject them.

#### What the reference does, which we do not

stand/common/load_elf_obj.c:

    for (i = 0; i < hdr->e_shnum; i++)
            shdr[i].sh_addr = 0;
    for (i = 0; i < hdr->e_shnum; i++) {
            if (shdr[i].sh_size == 0)
                    continue;
            switch (shdr[i].sh_type) {
            case SHT_PROGBITS:
            case SHT_NOBITS:
            case SHT_X86_64_UNWIND:
            case SHT_INIT_ARRAY:
            case SHT_FINI_ARRAY:
                    if ((shdr[i].sh_flags & SHF_ALLOC) == 0)
                            break;
                    lastaddr = roundup(lastaddr, shdr[i].sh_addralign);
                    shdr[i].sh_addr = (Elf_Addr)lastaddr;
                    lastaddr += shdr[i].sh_size;
                    break;
            }
    }

The loader LAYS OUT the allocatable sections in memory, honouring each
one's alignment, assigns each an address, and writes that address into
sh_addr. It then copies each PROGBITS section's bytes to its assigned
address and zeroes the NOBITS (BSS) sections.

So MODINFO_ADDR is not "where the file is". It is the base of a
laid-out section image that the loader must CONSTRUCT. The file image on
disk and the loaded image are different things, and we were passing the
former while telling the kernel it was the latter.

#### Consequence

ADR 0006 needs an amendment and the implementation needs the layout pass.
The work is larger than the ADR estimated, though still bounded: walk the
sections, lay out the SHF_ALLOC ones with alignment, copy PROGBITS,
zero NOBITS, write sh_addr, and pass the MODIFIED section table as
MODINFOMD_SHDR.

The operator's question, "ZFS has an offset, could that be the issue",
was the right one and pointed straight at this.

## F7 CLOSED: the armed transfer boots to the login (2026-07-13)

Seventh metal attempt. pgsd-loader booted the PGSD kernel on the bench,
the kernel mounted its ZFS root, drawfs took the framebuffer, the
supervision tree started, and pgsd-sessiond drew the login screen.

**The operator owns the boot path.** No FreeBSD loader is involved. There
is no Forth, no Lua, no beastie and no boot menu, because none of it was
ever written into pgsd-loader.

### What it took

Nine findings, in the order they were needed:

    F7   the boot environment was incomplete: no serial console binding,
         no ACPI RSDP. The kernel ran cninit with no UART and panicked
         with "A valid RSDP was not found".
    F8   the exit window contained two SetVariable calls. The reference
         keeps that window empty by construction, because firmware has
         been observed changing the memory map during ExitBootServices.
    F9   the EFI runtime map was never given to the kernel: virtual_start
         was zero in the map we passed, so the kernel could not locate the
         runtime services. efirtc0 now attaches.
    F10  recover restored NVRAM and left \EFI\BOOT\BOOTX64.EFI armed, so
         an NVRAM reset did not recover the machine, it RE-ARMED it.
    F11  this bench's Option-key picker boots the ESP fallback, not the
         NVRAM entry. Both previous "bricks" were machines whose every
         recovery route ran through the armed artifact. The machine was
         never broken.
    F12  with recovery working, the third attempt produced EVIDENCE
         instead of a reinstall: MARK_VMAP_ATTEMPT proved the loader
         completes and jumps on Apple firmware.
    F13  the loader mounted zfs:zroot/ROOT/awase-verified-pgsd-clean, a
         boot environment from three reinstalls ago.
    F14  pgsd-loader could not preload modules at all, so drawfs never
         loaded. Fixed by compiling drawfs into the kernel, which is
         correct anyway: the framebuffer owner is a bootstrap dependency.
    F15  the kernel could not mount a ZFS root, because zfs.ko is a
         MODULE and pgsd-loader could not preload it. This forced module
         preloading (ADR 0006) onto the critical path.
    F16  the loader must LAY OUT a module's sections, not just copy its
         bytes. The kernel rebases the sh_addr fields "saved by the
         loader"; a .ko off disk has them all zero.

### The lesson, stated plainly

Every hour lost in this campaign came from reasoning ahead of the
evidence. Every real finding came from reading the FreeBSD source until
the mechanism was understood, rather than skimming it until something
plausible appeared.

The specific instances are worth keeping, because the pattern repeated:

  - A probe with every landmark absent was read as a transfer regression.
    gdb was not installed.
  - MOD_LOAD error 6 was attributed to one of sixteen ENXIO returns on a
    guess, and could not have been checked, because bootverbose was off.
  - bootverbose was then set through a kernel environment variable. It is
    a boothowto BIT.
  - The vmap was built into a separate buffer, on the assumption that the
    firmware call was the point. The point was the metadata.
  - ADR 0006 was written on the belief that the kernel places module
    sections. It rebases sections the loader places, and says so in a
    comment that had been read twice and skimmed past.

The counter-discipline that worked: make the machine tell you. gdb.
bootverbose. PgsdModules in NVRAM. Every one of those turned a week of
guessing into one observation.

### The closing datum

From the successful boot:

    PgsdBasVerdict = MARK_VMAP_ATTEMPT
    PgsdModules    = zfs.ko LAID_OUT file=5889984 img=6427360
                            addr=0x1c01000 shnum=33

**The laid-out image is LARGER than the file**, 6,427,360 against
5,889,984, and that is the layout working rather than a fault. It was
predicted to be smaller, on the reasoning that the layout drops the debug
and non-allocatable sections. It does. But NOBITS sections occupy no
bytes in the file and do occupy memory, ZFS has a great deal of BSS, and
it more than makes up the difference.

So the extra 537,376 bytes are ZFS's zero-initialised data, allocated and
zeroed by the layout exactly as the reference does
(`kern_bzero(firstaddr, lastaddr - firstaddr)` before the copy). The
number confirms the layout rather than merely failing to contradict it.

`BootCurrent: 0006` on the recovered system: the armed entry is what
booted. The transfer ran.
