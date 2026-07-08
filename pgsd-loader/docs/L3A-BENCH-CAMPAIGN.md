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
