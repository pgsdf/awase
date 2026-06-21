# AD-56 Phase 0.5: ABI measurement design (DRAFT)

Status: DRAFT for ratification. A PGSD kernel change plus controlled
boot experiments; specified before code per discipline.

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

## Decisions to ratify before code

  - report mechanism for observation: sysctl handler (recommended,
    non-perturbing, re-readable) vs boot-time SYSINIT dump.
  - PGSD-DEBUG-only instrumentation (recommended; zero cost in the
    shipped kernel) vs a tunable on PGSD.
  - the suppress/malform mechanism for reduction: how one record is
    removed or corrupted in the handoff on the disposable path.
  - confirmation that the end-to-end BE reboot proof is done before
    reduction starts.
