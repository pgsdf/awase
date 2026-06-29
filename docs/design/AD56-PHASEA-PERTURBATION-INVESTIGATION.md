# AD-56 Phase A: perturbation mechanism investigation

Status: IN PROGRESS. Phase A0 (artifact audit) complete; Phase A1
(experimental isolation) beginning.

Governing objective (from the Phase 0 acceptance criteria contract):
identify the smallest change sufficient to reproduce the perturbation.
Reduction precedes explanation. Verified evidence is distinguished from
hypothesis throughout. The leading hypothesis is named "leading", not
"strong", to keep the investigation open to being wrong.

## Phase A0: artifact audit (complete, no bench)

Rationale: runtime behavior is the most expensive evidence (rebuild plus
reboot, and a reboot deliberately reintroduces the perturbation). The
patch and configuration already exist and are free to read. Extract all
evidence available from existing artifacts before spending a build.

### The enabling mechanism (established)

The instrumentation lives in one stock file, sys/kern/subr_module.c, in
the fork, guarded by #ifdef PGSD_AD56_OBSERVE. For that guard to compile
in, the symbol must be defined to the C compiler. The configuration form
that achieves this (the one used for the build that perturbed the system)
is a single line in the PGSD-DEBUG kernel config:

    makeoptions    CONF_CFLAGS+=-DPGSD_AD56_OBSERVE

CONF_CFLAGS is appended to the C compiler flags of EVERY kernel
translation unit, so this defines PGSD_AD56_OBSERVE kernel-wide. (Two
other config forms were tried during the original work and did not reach
the compiler: makeoptions PGSD_AD56_OBSERVE sets an empty make variable;
options PGSD_AD56_OBSERVE emits a define into opt_pgsd_ad56_observe.h,
which subr_module.c does not include. Only the CONF_CFLAGS form worked.)

### Dependency graph (established)

    makeoptions CONF_CFLAGS+=-DPGSD_AD56_OBSERVE
            |
            +--> applies -DPGSD_AD56_OBSERVE to EVERY kernel .c compile
            |       but the symbol is read in NO other file
            |       => inert outside subr_module.c (no conditional
            |          compilation effect anywhere else)
            |
            +--> activates #ifdef PGSD_AD56_OBSERVE in subr_module.c only
                    => the instrumentation code (a fixed-size lock-free
                       table, first-caller capture via
                       __builtin_return_address, per-type accounting)
                       is the remaining candidate perturbation source

### Separability finding (established)

As written, the instrumentation is activated ONLY by the global flag: the
#ifdef in subr_module.c reads PGSD_AD56_OBSERVE, and the only mechanism
wired to define it is CONF_CFLAGS, which is intrinsically global.
Therefore "instrument one file without a kernel-wide define" is NOT a
realizable configuration with the current mechanism; producing it would
itself require a code change (for example a per-file CFLAGS rule for
subr_module.c instead of global CONF_CFLAGS). This was determined before
designing experiments, so no build cycle is spent discovering it.

### Key evidence: the symbol is read in exactly one file (established)

A search of the kernel source tree:

    grep -rn 'PGSD_AD56_OBSERVE' /usr/src/sys/ | grep -v subr_module.c

returned nothing. PGSD_AD56_OBSERVE is referenced nowhere except the
instrumented file.

Implication: a -D define that no other file tests is a no-op in
preprocessing for those files. Globally defining PGSD_AD56_OBSERVE cannot
change conditional compilation, code path selection, or struct layout
anywhere outside subr_module.c, because nothing outside it tests the
symbol.

### Hypothesis shift (the A0 result)

Going in, the leading hypothesis was that the compile-wide define
perturbed other code (for example the display subsystem). A0 weakens that
to near-refutation on the mechanical question: there is nothing for the
define to collide with, since the symbol is inert outside the one
instrumented file. Suspicion is therefore concentrated on the
instrumentation CODE inside subr_module.c, not the global define's reach.

This is the value of auditing before experimenting: the cheap evidence
shifted the leading hypothesis before any expensive build was spent
testing the old one.

### What A0 does NOT establish (kept open per AC-5, AC-8)

  - Whether the instrumentation code itself perturbs early-boot behavior,
    timing, or state. The grep speaks to the symbol's reach, not to
    whether the code is benign.
  - Whether adding -D<anything> to CONF_CFLAGS perturbs the BUILD (not the
    runtime) in some way. Unlikely, not addressed by the grep.
  - Anything the grep cannot see (symbols constructed dynamically, or
    tested via build-system mechanisms rather than source #ifdef).
    Unlikely given usage, but the grep covers literal source occurrences
    in /usr/src/sys/ only.

### Architectural finding (independent of the mechanism)

The enabling mechanism already violates the Phase 0 acceptance criteria,
regardless of whether it mechanically perturbed anything:

  - AC-1 (explicit scope): the global compile-time effect was unintended;
    the intent was one function in one file.
  - AC-3 (locality): broad scope (kernel-wide CONF_CFLAGS) was adopted by
    convenience, not as a justified architectural requirement.

So the replacement design (Phase B) must change the enabling mechanism to
a local one even if the global flag turns out to be mechanically inert,
because the scope itself is the violation.

## A0 addendum: inspection of the instrumentation code (complete)

The instrumentation inside subr_module.c was read in full. It is
structurally conservative: a fixed-size (64-entry) static-BSS table, a
linear scan, counter increments, and capture of
__builtin_return_address(0). No allocation, no locking, no sleeping, no
re-entry, and no alteration of the return value or control flow of
preload_search_info (every original return path is preserved; the
instrumentation only increments counters alongside). The inventory sysctl
runs only on post-boot read, so it cannot affect boot.

The careful conclusion, stated to respect AC-5 and AC-8:

  Inspection revealed NO OBVIOUS failure mode in either candidate
  mechanism. This is NOT the same as "both mechanisms failed inspection"
  or "the code is innocent". Reading source can eliminate classes of
  explanation but cannot establish that code is non-perturbing. Apparently
  innocuous changes can alter timing, code generation, inlining, register
  allocation, stack layout, cache locality, or initialization ordering in
  ways invisible to source inspection. Those are exactly the mechanisms
  inspection cannot see, and exactly why AC-5 and AC-8 require evidence
  over inspection.

What inspection HAS established: the preprocessor symbol is localized to
subr_module.c; the instrumentation is structurally conservative; no
obvious perturbation mechanism is apparent; the original hypothesis is
therefore weakened. What it has NOT established: that the instrumentation
is non-perturbing.

The milestone is about the investigation itself: inspection has exhausted
its explanatory power. The next bit of information cannot be obtained by
reading. That is precisely when experimentation becomes justified, and it
is the trigger for Phase A1.

## Phase A1: experimental isolation (beginning)

Objective (revised). The goal of A1 is NOT to find the bug. It is to
determine whether the original observation is reproducible under fully
characterized conditions. This objective does not presuppose that the
instrumentation is even involved; both outcomes advance the investigation
without committing to a favored explanation beforehand.

Experiments are chosen from the dependency graph and from what inspection
could not decide, and each experiment answers exactly one question.

  A1.1: reproduce boot behavior.
    Question: from a characterized baseline (clean build, instrumentation
    confirmed compiled in before boot), does the original perturbation
    reproduce? Observations are only: did it build, did it boot, and if
    not, where did it fail. The inventory sysctl is deliberately NOT an
    observation here, to avoid conflating "does the instrumentation
    perturb boot" with "does the instrumentation record correctly".
      - reproduces  -> proceed to A1.3 (reduce to the minimal perturbing
                       change). Recover via known-good-generic.
      - does NOT     -> pivot: identify which aspect of the original build
        reproduce       or environment state was necessary for the
                        original failure (the environmental-artifact
                        branch, made live by A0 and the code inspection).

  A1.2: verify instrumentation functionality (only after A1.1 boots).
    Question: does the instrumentation record correctly (the inventory
    sysctl works, per-row found + not_found == requests)? This is a
    separate question from A1.1 and only matters if the instrumentation
    proves non-perturbing.

  A1.3: reduce to the minimal perturbing change (only if A1.1 reproduces).
    Question: what is the smallest element of the change sufficient to
    reproduce the perturbation? This is the governing objective of the
    Phase 0 contract applied within the instrumentation.

Safety: A1 deliberately reintroduces the perturbation. The fallback BE
known-good-generic (drawfs load disabled, boot-verified) is the recovery
path; the verified BE awase-verified-pgsd-clean preserves the working
system. A1 must not proceed without the fallback reachable at the loader.

Results recorded below as experiments are run.

## Methodology note (captured, not a separate design effort)

This investigation followed a pattern worth preserving, recorded here
rather than promoted to a separate artifact, to keep one active
architectural uncertainty at a time:

  eliminate what artifacts can eliminate (cheap evidence first)
        -> formulate the residual hypotheses
        -> design experiments only for what artifacts cannot decide
        -> let each experiment answer exactly one question

The shift is from "observed failure -> likely cause" to "observed failure
-> candidate mechanisms -> artifact elimination -> residual hypotheses ->
experiment". The pattern generalizes beyond this incident; whether it
deserves its own statement is left for after this AD-56 work, consistent
with the discipline of not opening a second front.
