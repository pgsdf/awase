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

## Increment 1 metal run

PENDING: order-head cycle per F1's method. Expected console:
selector gen and slot, manifest identity verified, both
artifacts verified (the 28.7 MB kernel hashed on real hardware),
active slot VERIFIED, five second dwell, then a normal boot with
the chime. BootCurrent after: the test entry.
