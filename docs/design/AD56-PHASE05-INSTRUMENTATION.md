# AD-56 Phase 0.5: ABI measurement design

Status: RATIFIED 2026-06-24 (operator). A PGSD kernel change plus
controlled boot experiments; the five decisions below are settled.
Observation and reduction may be implemented under them.

## Purpose and scope discipline

Turn the source-read compatibility bridge (AD56-ABI-BRIDGE.md) into a
MEASURED load-bearing subset, so the Awase-native boot contract and the
Phase 3 minimal handoff carry only what is required, not everything the
loader can emit.

This is NOT a general boot-telemetry framework around
preload_search_info. It answers one specific question about one small,
already-enumerated set of records. The bridge document gives the
candidate set:

  - EFI_MAP, EFI_FB, HOWTO, ENVP, KERNEND,
  - the per-module records (MODINFO_NAME/TYPE/ADDR/SIZE),
  - the kernel record (the "elf kernel" module).

Roughly seven things. The whole of Phase 0.5 is to classify those seven.
If the design grows beyond classifying this set, it has overreached.

## Two stages answer two different questions

Observation and reduction are not interchangeable:

  - Observation: "What does the system TOUCH?"
  - Reduction: "What can the system LIVE WITHOUT?"

A record can be touched and still not be load-bearing. Observation alone
cannot tell required from merely-read; promoting "observed" to "required"
is the exact read-equals-required error the bridge document warns
against, and it must not reappear at the measurement layer.

### Stage 1: Observation (bounds the candidate set from above)

A small accounting layer around preload_search_info records, per
requested record type: request count, found (non-NULL) count, and the
distinct caller return addresses. One post-boot inventory (a sysctl
handler, non-perturbing and re-readable; not a per-access printf flood).

What observation establishes, and ONLY this:

  - NEVER TOUCHED -> classifiable immediately as DEAD. This is the only
    terminal classification observation can assign.
  - TOUCHED -> remains UNCLASSIFIED. Suspect, not proven required.
    Reduction must test it.

Observation's real job is to VALIDATE THE CANDIDATE SET: confirm the
boot consumes nothing the bridge document missed (no surprise record
type requested), and confirm each candidate is actually requested on
this bench. It bounds from above (what is safely dead) and checks the
list is complete. It does not classify the touched records.

### Stage 2: Reduction (the experiment; assigns mandatory vs optional)

For each candidate record believed live, suppress or malform exactly
that one record in the handoff, boot, and observe. This is the only
thing that produces a REQUIRED verdict, because the justification for
dropping a record from the Awase-native contract is not "it was read
once" but "the system boots without it."

Classification (the table reduction fills):

  - DEAD: never consumed. Assigned by observation alone.
  - MANDATORY: boot FAILS when the record is absent or malformed.
    Reduction required to assign.
  - OPTIONAL: boot SUCCEEDS when the record is absent or malformed, but
    functionality degrades (e.g. EFI_FB absent: kernel reaches init,
    drawfs has no display). Reduction required to assign.

## Reduction must be staged by risk (recovery odds first)

Order the reduction experiments so early experiments bank simplification
while recovery is most certain, and the experiment expected to fail runs
last:

  1. Records believed NON-CRITICAL (provisional-dead or clearly
     peripheral): test first; cheap simplification, low failure risk.
  2. Records believed OPTIONAL (e.g. EFI_FB, HOWTO, ENVP): expected to
     boot-without; confirms the degrade-not-fail prediction.
  3. Records SUSPECTED MANDATORY (KERNEND, the module/kernel records):
     higher failure probability.
  4. EFI_MAP LAST: native_parse_memmap panics without it, so this
     experiment is already EXPECTED to fail. There is no value in
     discovering that first; run it after the recovery path has been
     exercised repeatedly and is trusted.

This is "build the mitigation immediately before the risk" applied to
experiment ordering.

## Hard prerequisite for reduction (not a Phase 0 item)

Reduction DELIBERATELY makes the system unbootable to find the mandatory
records. It therefore requires a proven recovery path. Before reduction
begins:

  - The ZFS boot-environment recovery must be proven END TO END: boot
    into the known-good BE on real hardware once, not merely switch-test
    the activate/revert (which Phase 0 already did). This is a
    prerequisite OF REDUCTION, not an unfinished Phase 0 deliverable;
    Phase 0's recovery posture is complete, and this proof is consumed
    by the work that needs it.
  - Reduction experiments operate on a DISPOSABLE / instrumented boot
    path (the PGSD-DEBUG kernel and a throwaway handoff), never the
    production handoff, so a failed experiment recovers by booting the
    known-good BE and the production path is never the thing broken.

## Output and how it feeds the contract

After observation validates the candidate set and reduction classifies
each record DEAD / MANDATORY / OPTIONAL, the result is the measured ABI:
the boundary between the bridge ABI (everything source can touch), the
measured ABI (what this bench actually requires), and the Awase-native
ABI (the minimal contract Phase 3 implements). Phase 3 implements only
what the measured subset requires.

## The dereference caveat (carried from the earlier draft)

preload_search_info cannot see whether its CALLER dereferences the
returned pointer, so observation's "found" is "requested-and-provided,"
not "used." This is fine under the two-stage model: observation is not
trusted to prove use; reduction proves required. The earlier worry about
overcounting dissolves because reduction, not observation, assigns the
load-bearing verdict.

## Ratified decisions (2026-06-24)

  1. OBSERVATION MECHANISM: a sysctl handler, not a boot-time SYSINIT
     dump. Observation must be repeatable, non-destructive, and available
     after boot; a SYSINIT dump is an event, a sysctl is an interface
     that allows repeated inspection without changing the boot being
     observed.

  2. AVAILABILITY: PGSD-DEBUG only, not a tunable on production PGSD. The
     instrumentation is investigational scaffolding (an AD-57
     investigational delta), not part of the kernel's definition;
     production PGSD stays free of measurement machinery, and the debug
     kernel hosts the temporary mechanism.

  3. REDUCTION MECHANISM: kernel-side suppression in the PGSD-DEBUG
     kernel's metadata lookup path, NOT loader-side modification.
     Phase 0.5 asks "does the kernel require this record," which is a
     consumer question: if the kernel behaves identically when
     preload_search_info returns NULL for a record type, the kernel does
     not require it. Loader-side suppression would test both the record's
     absence AND the correctness of a modified loader, conflating two
     variables; loader fidelity belongs to Phase 3, not reduction.
     Reduction experiments SHALL be performed by controlled suppression
     within the debug kernel's lookup path, not by modifying the loader
     handoff.

  4. MALFORMED-RECORD SUPPORT: deferred. Phase 0.5 SHALL implement
     SUPPRESSION ONLY (NULL return). Malformed-record experiments are
     future work, added only if reduction results show a genuinely
     ambiguous record that needs the further discrimination. Suppression
     alone is terminal in both directions: if it proves a record
     unnecessary the work is done, and if it proves a record required the
     work is done. Malform answers a different question (is the kernel
     sensitive to record VALIDITY or merely PRESENCE), which is not the
     primary reduction question. Keeping Phase 0.5 suppress-only keeps the
     implementation small, the interpretation straightforward, and the
     recovery path simple.

  5. BE REBOOT PREREQUISITE: satisfied and confirmed. The end-to-end
     known-good BE reboot proof was done on hardware 2026-06-24 (manual
     loader selection of the non-active BE, confirmed root, restored to
     default). Reduction may proceed under the established recovery
     procedure.

### Implementation scope that follows from these decisions

  - Observation: a sysctl handler in the PGSD-DEBUG kernel exposing the
    preload_search_info accounting inventory (per requested record type:
    request count, found count, distinct caller sites), re-readable after
    boot.
  - Reduction: a debug-kernel mechanism (for example a boot tunable
    naming a record type) that makes preload_search_info return NULL for
    that one type, so each experiment is set-tunable / reboot / observe /
    recover-via-BE. Suppress-only.
  - Neither ships in production PGSD.

The remaining concerns stay open as implementation, not decisions: the
exact sysctl name and inventory format, the exact tunable/suppression
mechanism, and the per-record experiment ordering (already specified by
risk in the Reduction section: non-critical first, EFI_MAP last).
