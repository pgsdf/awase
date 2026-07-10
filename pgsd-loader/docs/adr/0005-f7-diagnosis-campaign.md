# 0005: increment 4c, the F7 diagnosis campaign and the transfer re-introduction conditions

## Status

Ratified, 2026-07-10 (operator, in session; the experimental order,
the interpretation bound on emulation results, and the fail-closed
rebuild condition were each ratified explicitly). Stage ADR under
ADR 0004, governing the diagnosis of ledger finding F7 and the
conditions under which the reverted transfer (4b-final) may be
re-introduced. ADR-before-code: no 4c code exists at ratification.

## Context

F7 (L3A-BENCH-CAMPAIGN.md): the first armed metal boot power-cycled
at the Apple logo with no kernel text, the bench required a FreeBSD
reinstall to recover, and the transfer (4b-final) plus the root env
were reverted, returning the loader to the walk-verified
attest-and-chainload state that never crosses ExitBootServices.

A code audit of the reverted 4b-final (conducted 2026-07-10 against
commit 9b3cd82) narrowed the fault space. Eliminated, with the
evidence for each:

- Staging misalignment under the 2 MiB PS mapping: the metal
  preflight's walk arithmetic returns want minus delta, where delta
  is the misalignment of (staging - base_paddr); rb=true on metal
  therefore proves delta was zero in the fatal attempt.
- Transfer-critical allocations above 4 GiB: the page tables, the
  handoff stack, and staging are all allocated with max_address
  below 4 GiB; the in-place transfer code is gated by an explicit
  below-4-GiB check that aborts to chainload.
- Page-table construction and interrupt state: PS and permission
  bits are emulation-proven; cli is the first trampoline
  instruction.
- Final-map chain overrun: buildChainFull bound-checks against its
  16 KiB buffer and staging carries 8 MiB of slop; the worst case is
  a silently stale chain (see Decision 3), not a corrupted image.

The confirmed gap: the 4b-final emulation proof (the KOK serial
run) validated the transfer mechanism against a fake kernel by
design ("the transfer mechanism proven independently of a real
kernel", 4b-final commit message). No real FreeBSD kernel has ever
executed its first instruction through this transfer, in emulation
or on metal. The fatal attempt therefore conflated two hypotheses
that were never separated:

1. The transfer mechanism is wrong on this platform.
2. The transfer mechanism is correct, but the kernel's early
   execution contract is not satisfied.

F7's fault band, "at or just after the transfer", spans both, and
emulation only ever covered the mechanism half.

## Decisions

**Decision 1: experimental order.** Diagnosis proceeds in strictly
increasing cost and risk, and no metal transfer re-attempt happens
before step 2 has been run to a conclusion:

1. Read the existing NVRAM evidence: PgsdBasVerdict
   (50475344-6261-4c33-8a01-706773646261) may still hold F7's
   BOOT_ATTEMPT breadcrumb with the fatal attempt's entry, pml4,
   tramp, and rsp values, since the variable is non-volatile and is
   only overwritten by pgsd-loader itself. Effectively free; may
   narrow the search without introducing any new variable.

2. Exercise the real kernel under emulation: the pinned FreeBSD
   kernel (the AD-57 96841ea build, the same artifact the bench
   runs) placed in the BAS slot under QEMU/OVMF, the full armed
   transfer executed, serial as the observable. Success criterion:
   the FreeBSD copyright banner on serial. This changes exactly one
   variable relative to the KOK proof (real kernel for fake) while
   keeping the observable environment (serial, QEMU diagnostics,
   the gdb stub).

3. Metal re-attempt, only after step 2 concludes, under Decision 4.

**Decision 2: interpretation bound on the emulation result.** A
step 2 failure reproduces F7 in an observable environment and the
kernel handoff contract is debugged there. A step 2 success
isolates the remaining investigation to platform-specific behavior
or firmware-dependent assumptions (for example memory-map size and
layout differences, image placement, NVRAM semantics); it does not
conclusively attribute the fault to Apple firmware, and the ADR
records no such attribution in advance of metal evidence.

**Decision 3: the transfer fails closed.** A condition of
re-introducing 4b-final: if the final-map chain rebuild fails, the
loader records the condition and aborts to chainload. The reverted
code proceeded to ExitBootServices with a stale chain (the silent
error branch on buildChainFull); a loader that has just failed to
construct the map the kernel will receive does not transfer. This
decision stands on its own, whatever the F7 diagnosis turns out to
be.

**Decision 4: metal re-attempt discipline.** When step 3 is
reached:

- The armed loader is never placed at the boot-order head. It runs
  as a manually selected boot entry, one attempt per selection, so
  a failure strands the bench at the firmware picker rather than in
  a power-cycle loop.
- Per-step NVRAM markers are written through the pre-exit sequence,
  plus one write immediately after ExitBootServices returns and
  before the cr3 load. A failed post-exit write is recorded
  behavior, not a step to retry: NVRAM writes after exit are
  themselves platform-dependent, and the marker protocol treats
  their failure as information.
- The breadcrumb and markers are read back after every attempt,
  before any next attempt is armed.

**Decision 5: emulation uses the pinned artifact.** The kernel
exercised in step 2 is the AD-57 pinned build, not a convenience
kernel, so a step 2 success speaks for the exact bytes the bench
boots and a failure is reproducible against a fixed identity.

## Closure criteria

1. Step 1 executed and its outcome (breadcrumb recovered,
   overwritten, or absent) recorded in the campaign ledger.
2. Step 2 executed to a conclusion: either the real kernel boots
   through the transfer under emulation (banner on serial), or the
   failure is reproduced and diagnosed there; the ledger records
   which, with the serial evidence.
3. The Decision 3 fail-closed change present in any re-introduced
   transfer code.
4. A metal attempt under Decision 4 whose outcome is recorded with
   its markers; F7 closes when a metal transfer reaches kernel text
   or when the fault is identified and fixed with the evidence
   chain written down.

## References

- L3A-BENCH-CAMPAIGN.md, finding F7.
- 4b-final (9b3cd82) and its reversion (c98fe07, 4ec5e6c,
  2350721).
- KERNEL-HANDOFF.md, contracts 5.1 through 5.3.
- ADR 0004 (stage L3a), project ADR 0001 (deployment
  architecture and emulation-for-iteration, Decision 7).

## Revision history

- 2026-07-10: ratified at initial revision.
