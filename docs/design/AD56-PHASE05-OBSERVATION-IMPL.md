# AD-56 Phase 0.5 Delta 1: observation instrumentation (implementation)

Implements the OBSERVATION stage of the ratified Phase 0.5 design
(docs/design/AD56-PHASE05-INSTRUMENTATION.md) as the first AD-57
investigational delta against the pinned kernel
(96841ea08dcfa84b954a32dc5ae1a26c28966cf4, FreeBSD 15.1.0).

Per the three-delta workflow (observe, understand, modify), this is
Delta 1 ONLY: observation. It adds zero behavioral change, zero
suppression, zero tunables. Reduction is a later, separately-ratified
delta gated on the analysis of what this produces.

## Where this code lives

This is a modification to FreeBSD base source (sys/kern/subr_module.c),
so per AD-57 (Git-backed representation) it lives as a commit on a fork
branch (awase/ad56-phase05-observation) in
https://github.com/pgsdf/freebsd-src, NOT in the awase repository and NOT
in pgsd-kernel/patches/. The commit advances delta_commit for the
investigation that uses it. This awase document is the design record and
points back to that fork commit once it exists.

It is compiled into PGSD-DEBUG only (decision 2): guarded so the
production PGSD kernel carries no measurement machinery.

## The instrumentation target: one chokepoint

Every boot metadata record the kernel reads (EFI_FB, EFI_MAP, HOWTO,
ENVP, KERNEND, SMAP, the module records) is fetched through a single
function:

    caddr_t preload_search_info(caddr_t mod, int type);

It returns the record's data pointer, or NULL if the record is absent.
MD_FETCH is a typed wrapper over the same walk. Instrumenting this one
function therefore captures the ENTIRE candidate set without touching
each call site. This is why observation is a small, localized change.

## What it records (decision 1: a re-readable inventory, not a printf flood)

A fixed-size accounting table, one row per distinct `type` value seen:

  - type: the int type argument (MODINFO_METADATA | MODINFOMD_* etc).
  - requests: how many times preload_search_info was called for it.
  - found: how many of those returned non-NULL (record present).
  - not_found: how many returned NULL (record absent). Recorded
    EXPLICITLY rather than derived as requests - found, so the exported
    data is self-describing and an accounting bug is visible: the
    invariant found + not_found == requests must hold per row, and a
    violation is a finding about the instrumentation, not something the
    analysis must assume away. This matters if the real function grows
    additional return paths or early exits.
  - first_caller: the return address of the FIRST observed caller only
    (cheap: __builtin_return_address(0)). Only the first is retained
    because the objective is to identify the originating subsystem, not
    to reconstruct the full call graph. A symbol name is NOT resolved
    in-kernel; the raw address is exported and resolved offline against
    the kernel image.

The table is fixed-size (a small MAXTYPES, e.g. 64) and append-on-
first-sight, so the instrumentation allocates nothing at call time and
adds only a bounded linear scan plus a few increments per call.

Saturation: if more than MAXTYPES distinct types appear, increment a
single overflow counter (ad56_overflow) and discard further NEW type
registrations while continuing to count requests/found/not_found for
types already in the table. Later observations of KNOWN types are never
lost; only new-type registration stops, and the overflow counter makes
that visible. Table saturation must never alter kernel behavior (see
invariants).

## Instrumentation invariants (what non-perturbing means)

The instrumentation is a pure observer. These invariants define the
measurement contract and must hold for the inventory to be trustworthy:

  - preload_search_info returns EXACTLY the value it would return without
    instrumentation. The return value and control flow are never altered.
  - No allocation, sleeping, blocking, or locking is introduced. The
    table is static storage touched with plain reads and increments.
  - No metadata record or traversal state is modified or even retained
    by reference; only the type, counts, and one caller address are
    copied out.
  - Failure of the accounting itself (table saturation, an unexpected
    type) must not alter kernel behavior: it degrades to counting less,
    never to changing the boot.
  - The instrumentation never re-enters preload_search_info (directly or
    via the sysctl handler), so it cannot recurse or perturb its own
    measurement.

SMP assumption: Phase 0.5 assumes all relevant metadata lookups occur
during early, effectively single-threaded boot, before secondary CPUs
start. Lock-free accounting is therefore sufficient and no atomics are
used. If observation shows lookups occurring after SMP start (a finding),
synchronization becomes a future revision; it is not added speculatively.

## How it is read (decision 1: sysctl, re-readable, post-boot)

A read-only sysctl, debug.ad56.preload_inventory, whose handler formats
the table as text (one line per type: type, requests, found,
first_caller). Re-readable any number of times after boot without
perturbing the measured boot. No SYSINIT dump.

## Hook design, by epistemic status

GUARANTEED BY RATIFIED DESIGN (AD-56 Phase 0.5, AD56-ABI-BRIDGE.md):
  - observation is read-only and non-perturbing; it classifies only
    never-requested -> DEAD, leaving touched records for Delta 2.
  - the sysctl/inventory mechanism and PGSD-DEBUG-only scoping.

ASSUMED FROM PRIOR SOURCE ANALYSIS (the bridge doc, read from source
earlier; high confidence but not re-checked against the pinned tree):
  - preload_search_info(caddr_t, int) is the single chokepoint; its
    return value distinguishes found (non-NULL) from absent (NULL).
  - the type argument is the record discriminator to key the table on.
  - MD_FETCH routes through the same function, so typed small-record
    reads (HOWTO, ENVP) are captured too.

REQUIRES VERIFICATION AGAINST PINNED SOURCE (subr_module.c at
96841ea08dcfa84b954a32dc5ae1a26c28966cf4; the source is the authority,
this draft infers them):
  - the exact function body and where to place the accounting calls
    (record the type on entry, record found/not-found on the return
    path). The patch shows the intended shape; adjust to the real body.
  - lock / early-boot context: preload_search_info runs very early. The
    accounting table must be plain static storage touched without any
    lock that is not yet initialized at first call. A simple static
    array with no dynamic allocation and no mutex is the safe choice;
    confirm nothing in the real call path makes even that unsafe.
  - KERNEND timing, as a specific case of a general rule: MODINFOMD_KERNEND
    is read in early locore/pmap bootstrap, possibly before this C
    function is first callable for accounting.

GENERAL RULE for Delta 2 analysis (not just KERNEND): a type ABSENT from
the inventory means "not observable by this technique," NOT "never
requested." Any metadata read before the instrumentation becomes active
(early locore/asm paths, or reads that do not route through
preload_search_info) is invisible here. Delta 2 must treat an absent type
as UNOBSERVABLE, and only a type that IS in the inventory with found == 0
as genuinely requested-but-absent. Promoting "not in the inventory" to
"DEAD" would be a false terminal classification, the same read-equals-
required error inverted. Note absences as findings about observability;
do not force a record to appear and do not classify it DEAD on absence
alone.

## Success criterion (measurable)

Boot a PGSD-DEBUG kernel built from the pinned source plus this delta,
then read debug.ad56.preload_inventory. Success is:

  - the sysctl exists and returns a table with one row per metadata type
    observed during boot, each carrying requests, found, not_found, and
    first_caller;
  - found + not_found == requests holds for every row (accounting
    integrity);
  - REPEATED reads after boot has quiesced produce IDENTICAL values,
    demonstrating the inventory is stable and reproducible (it measures
    boot-time lookups, not ongoing activity);
  - the production PGSD kernel built from the same source does NOT expose
    the sysctl (instrumentation absent outside PGSD-DEBUG).

Nothing is suppressed; nothing is classified beyond what observation can
assign (a type present with found == 0 is requested-but-absent; a type
absent from the table is UNOBSERVABLE per the general rule above, not
DEAD; Delta 2 does the rest).

## Failure criteria (the experiment has failed, or is untrustworthy, if)

  - the kernel panics, fails to boot, or boots with any behavior
    different from an uninstrumented PGSD-DEBUG kernel;
  - preload_search_info returns a different value than it would
    uninstrumented (detectable as a functional regression);
  - the instrumentation re-enters preload_search_info (recursion);
  - found + not_found != requests for any row (accounting bug);
  - repeated post-quiescence reads disagree (non-stable inventory);
  - the sysctl appears in a production PGSD build (guard leaked).

Any of these invalidates the inventory for Delta 2 and must be fixed
before the measurement is trusted. The known-good BE recovery path is
available if a build fails to boot, though observation should never
reach that state.

## Explicitly NOT in this delta

  - no suppression / NULL-return-on-purpose (Delta 3),
  - no boot tunables (Delta 3),
  - no malform (deferred entirely, decision 4),
  - no classification of touched records (Delta 2 analysis),
  - no production-kernel presence (PGSD-DEBUG only).

## After this delta

Delta 2 (analysis, not kernel work): read the inventory, answer which
types are referenced / never requested / requested-but-absent / by which
callers, and whether the candidate set matches AD-56. Output is a project
document tied to this delta's fork commit. Only after that inventory is
ratified does Delta 3 (reduction) begin.
