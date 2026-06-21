# AD-56 Phase 0.5: ABI instrumentation design (DRAFT)

Status: DRAFT for ratification. A PGSD kernel change; specified before
code per discipline. Gated behind the five Phase 0 exit criteria.

## Purpose

Turn the source-read compatibility bridge (AD56-ABI-BRIDGE.md) into a
MEASURED load-bearing subset. Source inspection and runtime behavior
diverge: dead branches, arch-conditional paths, and present-but-never-
dereferenced fields make a static reading larger than the actual runtime
dependency. Phase 0.5 measures what the kernel actually consumes, so the
Phase 3a minimal handoff and the eventual Awase-native contract carry
only what is load-bearing, not everything the loader emits.

## What to measure (the four-way distinction, made runtime)

For each metadata record type, across multiple successful boots:
  - requested: was preload_search_info called for it?
  - caller: which site (so consumption maps to subsystem).
  - found: did the loader actually provide it (non-NULL return)?
  - dereferenced: was the returned pointer actually read, or fetched and
    discarded?

The "dereferenced" axis is the subtle one and the whole point. A record
that is searched and found but whose pointer is never read is
EMITTED-BUT-IGNORED, exactly the dead weight a fresh loader should not
reproduce. Search-and-found alone does not prove load-bearing.

## Design: an accounting layer around preload_search_info, not per-access logging

Do NOT printf every metadata access (a boot-time flood, and it perturbs
timing). Instead, a small accounting table inside subr_module.c:

  - A static array indexed by (or keyed on) the requested `inf` value
    (MODINFO_* or MODINFO_METADATA|MODINFOMD_*). Each entry accumulates:
    request count, found count, a small set of distinct caller return
    addresses (__builtin_return_address(0)), and a dereferenced flag.
  - preload_search_info records request + found + caller on each call.
  - A single post-boot report (a SYSINIT at SI_SUB_LAST, or a sysctl
    handler dumped on demand) walks the table and prints one inventory:
    per record type, requested/found/deref and the caller sites.

This yields a usage INVENTORY, one report, instead of a message per
access.

## The "dereferenced" problem and how to handle it honestly

preload_search_info returns a pointer; whether the CALLER dereferences
it cannot be seen from inside preload_search_info. Three options, in
increasing fidelity and cost:

  1. Proxy: treat found+returned-non-NULL as "consumed". Cheapest;
     overcounts (cannot distinguish fetched-and-used from
     fetched-and-discarded). Honest label: this measures REQUESTED-AND-
     PROVIDED, not dereferenced. Still strictly better than source
     reading because it captures arch/runtime-conditional requests.
  2. Caller audit: from the recorded caller sites, read each one in
     source ONCE and classify whether it dereferences. Combines the
     runtime request inventory (which sites actually ran on this bench)
     with a targeted source read of only those sites. Good fidelity,
     low code risk, no kernel-internal dereference tracking. Recommended
     starting point.
  3. Full taint: wrap returns so a later read is detectable. High cost,
     intrusive, not justified yet.

Recommendation: option 2. The accounting layer gives the runtime request
set (the hard-to-infer part: which records were actually requested, by
which sites, and were they present); a one-time source audit of just the
recorded caller sites resolves dereferenced-vs-discarded. This avoids the
"search-and-found means used" overclaim that option 1 alone would make.

## Output and how it feeds the contract

After several clean boots (capture variation: with/without display, the
recovery profile, etc.), the inventory plus the caller audit yields, per
record type, a measured verdict: REQUIRED (boot fails without; tested by
the panic case and by absence experiments later), CONSUMED-AND-DEREF,
REQUESTED-BUT-IGNORED, NEVER-REQUESTED on this bench.

That table is the boundary between:
  - the bridge ABI (everything the source path can touch),
  - the measured ABI (what this bench's kernel actually consumes),
  - the Awase-native ABI (the minimal contract Phase 3/4 defines and the
    PGSD kernel and Awase loader jointly own).

When that boundary is drawn from measurement, the fresh loader stops
being a reverse-engineering project and becomes an OS design project:
the contract is chosen, not inherited.

## Scope and safety

  - A PGSD-DEBUG-only change initially (instrument the debug kernel,
    keep PGSD production clean), so the accounting has zero cost in the
    shipped kernel.
  - subr_module.c is MI code; the change must be guarded
    (#ifdef or a tunable) so it compiles out entirely when not measuring.
  - Read-only with respect to boot behavior: the accounting only
    observes; it must not alter what preload_search_info returns.
  - Gated behind Phase 0's five exit criteria, including tested
    media-free recovery, because it modifies and reboots the kernel.

## Decisions to ratify before code

  - option 1 vs 2 for the dereference question (recommended: 2).
  - report mechanism: boot-time SYSINIT dump vs on-demand sysctl
    (sysctl is non-perturbing and re-readable; likely better).
  - PGSD-DEBUG-only vs a tunable on PGSD.
  - how many boots and which boot variations constitute a sufficient
    measurement before drawing the minimal-handoff line.
