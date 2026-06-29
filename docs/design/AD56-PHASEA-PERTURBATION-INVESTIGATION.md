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

## Phase A1: experimental isolation (beginning)

Experiments are chosen from the dependency graph, not from prior
hypothesis. Given A0 (the flag is mechanically inert outside
subr_module.c, so testing the full AD-56 change effectively isolates the
instrumentation code), the first experiment is:

  A1-E1: does the AD-56 instrumentation reproduce the perturbation?
    Build the full original AD-56 change (instrumentation plus its
    enabling flag, which A0 shows is inert elsewhere), boot with the
    proven fallback armed, observe.
      - reproduces  -> the perturbation is in the AD-56 change; since the
                       flag is inert elsewhere, the instrumentation code
                       is the mechanism. Then reduce within the
                       instrumentation to the minimal perturbing element.
      - does NOT     -> the original perturbation had a cause other than
        reproduce       the AD-56 change as currently understood (for
                        example a build-state artifact); a major finding
                        that redirects the investigation.

Safety: A1 deliberately reintroduces the perturbation. The fallback BE
known-good-generic (drawfs load disabled, boot-verified) is the recovery
path; the verified BE awase-verified-pgsd-clean preserves the working
system. A1 must not proceed without the fallback reachable at the loader.

Results recorded below as experiments are run.
