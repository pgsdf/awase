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
