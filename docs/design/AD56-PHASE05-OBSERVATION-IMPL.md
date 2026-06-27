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
  - first_caller: the return address of the first caller (optional
    caller identification, cheap: __builtin_return_address(0)). A symbol
    name is NOT resolved in-kernel; the raw address is exported and
    resolved offline against the kernel image.

The table is fixed-size (a small MAXTYPES, e.g. 64) and append-on-
first-sight, so the instrumentation allocates nothing at call time and
adds only a bounded linear scan plus a couple of increments per call.
That keeps it non-perturbing (the success criterion forbids altering
boot behavior beyond minimal accounting overhead).

## How it is read (decision 1: sysctl, re-readable, post-boot)

A read-only sysctl, debug.ad56.preload_inventory, whose handler formats
the table as text (one line per type: type, requests, found,
first_caller). Re-readable any number of times after boot without
perturbing the measured boot. No SYSINIT dump.

## Hook design (CERTAIN parts vs bench-VERIFY parts)

CERTAIN from the ABI bridge (documented from source):
  - preload_search_info(caddr_t, int) is the single chokepoint; its
    return value distinguishes found (non-NULL) from absent (NULL).
  - the type argument is the record discriminator to key the table on.
  - MD_FETCH routes through the same function, so typed small-record
    reads (HOWTO, ENVP) are captured too.

MUST be verified against the real subr_module.c at the pinned commit
(this draft infers them; the source is the authority):
  - the exact function body and where to place the accounting calls
    (record the type on entry, record found/not-found on the return
    path). The patch shows the intended shape; adjust to the real body.
  - lock / early-boot context: preload_search_info runs very early. The
    accounting table must be plain static storage touched without any
    lock that is not yet initialized at first call. A simple static
    array with no dynamic allocation and no mutex is the safe choice;
    confirm nothing in the real call path makes even that unsafe.
  - KERNEND timing: MODINFOMD_KERNEND is read in early locore/pmap
    bootstrap, possibly before this C function is first callable for
    accounting. If KERNEND does not appear in the inventory, that is a
    FINDING (its read site is earlier than preload_search_info
    accounting can see), not a bug. Note it; do not force it.

## Success criterion (and only this)

Boot a PGSD-DEBUG kernel built from the pinned source plus this delta,
then read debug.ad56.preload_inventory and obtain a complete inventory
of every metadata type requested during boot, with request/found counts
and first-caller addresses. Nothing is suppressed; nothing is
classified beyond what observation can assign (never-requested -> DEAD;
requested -> UNCLASSIFIED, for Delta 2 analysis).

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
