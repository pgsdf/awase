# 0007 Bench test protocol

## Status

Proposed (2026-05-14).

## Context

ADRs 0001 through 0006 each include a "Bench testing" section
that specifies what to run and what to expect for the
component they describe. This ADR is procedural rather than
decisional: it specifies how the bench is set up, how tests
are run, how results are recorded, what counts as stage
completion, and how to recover when something goes wrong.

The audience is whoever runs the tests: Vic primarily, future
contributors secondarily. The tests are manual in v1; no
automated runner exists. A runner may follow in a later stage
but is out of scope here.

## Decision

### Bench machine requirements

A pgsd-sessiond bench must satisfy the following. The exact
hardware may vary across the three known UTF benches (5K iMac,
1024x768 sparrow laptop, dev workstation); the requirements
do not.

  - **OS**: FreeBSD 15.0-RELEASE or later. PGSD kernel
    installed (the AD-39 / AD-1 closure work from 2026-05-13
    and 2026-05-14 must be present).
  - **UTF substrate**: drawfs.ko loaded, inputfs.ko loaded,
    semadrawd running with `SEMADRAW_PRIVILEGED_UID` set to
    the `_pgsd_sessiond` uid (for stages that exercise the
    privileged-client protocol). For stages 1-4 (CLI-only),
    semadrawd need not be running.
  - **PAM**: `/etc/pam.d/system` is the stock FreeBSD 15 file
    (no operator customisations that could mask test
    behaviour). `/etc/pam.d/pgsd-sessiond` installed per ADR
    0002.
  - **Users**: at least two real users in `/etc/master.passwd`
    with valid shells and home directories. The test user
    `vic` is conventional but any name works. Each test user
    has a known password.
  - **Network**: SSH reachable from the dev workstation. This
    is the primary recovery path. The pre-flight in
    pgsd-kernel-build.sh's check phase already enforces this
    for kernel work; the same property is required for
    pgsd-sessiond work.
  - **Console**: physical console access (keyboard, monitor)
    available. Stage 9 specifically requires being able to
    look at the screen for the login UI. Earlier stages can
    proceed via SSH only.

A bench that doesn't meet a stage's specific requirements
fails that stage's pre-flight, not the test itself; verify
prerequisites are in place before counting a test outcome.

### Pre-flight verification

Before running any test, confirm the substrate state:

```
# 1. PGSD kernel is loaded.
kldstat | grep -E "(drawfs|inputfs)"
# expected: both .ko files listed.

# 2. semadrawd is running with the right configuration (for
#    stages that need it).
service semadrawd status
sockstat -l | grep semadraw.sock
# expected: running, socket exists at /var/run/semadraw.sock.

ps auxww | grep '[s]emadrawd'
# verify the process environment includes the privileged uid
# config (for stage 5+):
procstat -e $(pgrep semadrawd) | grep SEMADRAW_PRIVILEGED_UID

# 3. PAM stack is in place (for stages 1+).
test -f /etc/pam.d/pgsd-sessiond && echo "ok pgsd-sessiond pam stack"
pamtester pgsd-sessiond root acct_mgmt 2>&1 | head -3

# 4. Runtime directory parent exists with the right mode (for
#    stages 3+).
ls -ld /var/run/pgsd
# expected: drwxr-xr-x ... root wheel ... /var/run/pgsd
```

Stages 1-4 need only steps 1-3. Stage 5+ adds the semadrawd
checks. Stages 8+ add console access. Stage 9 adds boot-time
configuration.

If any pre-flight check fails, fix the prerequisite before
running tests. Recording a test as failed when the
prerequisite was not satisfied is misleading.

### Per-stage test reference

Each implementation stage has its bench tests specified in the
ADR that covers its functionality. This is the navigation map:

  - **Stage 1** (PAM scaffolding CLI): ADR 0002 §Bench testing.
  - **Stage 2** (user enumeration + attribute file): ADR 0003
    §Bench testing.
  - **Stage 3** (privilege drop + exec): ADR 0005 §Bench testing.
  - **Stage 4** (.session enumeration): ADR 0004 §Bench testing.
  - **Stage 5** (login UI minimal): ADR 0006 §Bench testing
    (the `--ui-only` portion).
  - **Stages 6-8** (UI password entry, session picker, shutdown
    buttons): no dedicated ADR; tests will land in the
    pgsd-sessiond-BACKLOG.md alongside the stage commits.
  - **Stage 9** (boot integration): ADR 0006 §Bench testing
    (the failure-mode portion) plus stage-9-specific tests
    that will land with the stage 9 commit.

Each "Bench testing" section in the referenced ADRs lists
concrete shell commands with expected outputs. The protocol is
to run them in order, observe each result, and record the
outcome.

### Recording results

Test outcomes are recorded in session memos at
`docs/sessions/YYYY-MM-DD.md`. Existing memos
(`2026-05-10.md`, `2026-05-11.md`) follow the convention this
ADR formalises:

  - **Heading per stage tested**: `### [x] Stage N: <name>` (or
    `[ ]` for in-progress, `[~]` for "fix applied, awaiting
    verification" per the project's existing marker convention).
  - **What was run**: the shell commands actually invoked,
    copy-pasted from the terminal where possible.
  - **What was observed**: the actual output. If the output
    matches the ADR's expected output, a short "matches
    expected" note is sufficient. If it differs, paste the
    actual output verbatim.
  - **Outcome**: pass, fail, or partial. Partial means some
    sub-tests passed and others didn't; list which.
  - **Follow-up**: for failures, the next investigative or
    fix step. For passes, nothing further needed.

When a stage's full test suite passes, the memo records
"Stage N complete, ready to commit stage N+1 work." When all
nine stages are complete, pgsd-sessiond v1 is shippable.

### Cleanup between tests

Many tests have side effects on the bench: created users,
edited `/etc/utf/users/<name>.conf`, installed `.session`
files, started/stopped daemons. Tests are not required to
clean up after themselves; the cleanup discipline is:

  - **Within a session**: tests in the same session that
    build on each other (e.g. stage 2 tests creating an
    attribute file that stage 3 then reads) leave artefacts
    in place by design.
  - **Between sessions**: artefacts that may interfere with
    future test runs should be removed before powering down,
    or noted in the session memo so the next session knows
    to clean them up. Examples: test users with weak
    passwords, attribute files referencing nonexistent
    sessions, `.session` files with deliberately broken
    content.
  - **At reboot**: artefacts in `/var/run/pgsd/` are cleared
    by tmpfs and don't need explicit cleanup. Artefacts in
    `/etc/utf/users/` and `/usr/local/share/pgsd/sessions/`
    persist and must be removed manually.

This is deliberately informal. Bench testing is exploratory;
strict before/after fixtures would slow it down without
catching meaningful issues. For tests where leftover state is
load-bearing (e.g. "verify the file from earlier still works
after I reboot"), the dependency is recorded in the session
memo.

### Stage completion criteria

A stage is complete when:

  1. All bench tests in the referenced ADR's "Bench testing"
     section pass on the target bench.
  2. The code is committed to the repository with the
     appropriate commit message (the convention is
     `pgsd-sessiond: implement stage N (<short description>)`,
     mirroring how kernel and substrate commits have been
     scoped today).
  3. The session memo records the test outcomes.
  4. Stage N's tests pass on a SECOND bench wherever feasible.
     The sparrow laptop is the secondary bench for tests that
     don't require iMac-specific resolution; the 5K iMac is
     the primary for full UI work.

Stage completion is Vic's call to make. The criteria above are
guideline, not gate. The two-bench requirement specifically is
relaxed for stages 1-3 (CLI-only) where bench variance doesn't
matter and is encouraged for stages 5-9 where it does.

### Failure recovery

#### Stage-level failure

A test fails. The fix path is:

  1. Capture the failure in the session memo.
  2. Investigate. Update the relevant ADR if the failure
     reveals a design gap. Implement the fix.
  3. Re-run the failed test plus any tests downstream of the
     code path being changed.
  4. Mark complete only after the failing test passes.

This is standard development discipline; recording it here so
new contributors know the rhythm.

#### Bench-bricked failure

Stage 9 specifically risks bricking the bench: pgsd-sessiond
gets in front of the login flow at boot. If pgsd-sessiond
crashes, refuses to display, or otherwise prevents login, the
operator needs a recovery path.

The recovery hierarchy, in order of preference:

  1. **SSH from another machine**. Disable pgsd-sessiond
    (`sysrc pgsd_sessiond_enable=NO`), reboot. This is why
    the bench requires SSH reachable from the dev
    workstation; it is the routine fix.
  2. **Single-user mode boot**. Select single-user from the
    FreeBSD boot menu. The pgsd-sessiond rc.d script is
    skipped at this runlevel. Edit `/etc/rc.conf` or the
    `pgsd-sessiond.session` file from single-user, reboot.
  3. **Rescue boot from installer USB**. Mount the bench's
    filesystem, fix the config, reboot. Last resort; assumes
    the operator has a FreeBSD installer USB on hand.
  4. **vt(4) console fallback**. The AD-39 work removed vt(4)
    from the kernel config, so this path is NOT available
    on PGSD systems built after 2026-05-13. The recovery
    hierarchy specifically does not depend on vt(4). This
    is the consequence of AD-39's "Consequence" section
    noting that recovery now requires SSH or rescue media.

Operators planning to test stage 9 should verify recovery
paths 1 and 2 work on their bench BEFORE running the stage 9
tests for the first time. Specifically:

```
# Verify path 1 (SSH).
ssh dev-workstation 'ssh bench-machine echo ok'
# Must succeed; if not, configure SSH before proceeding.

# Verify path 2 (single-user mode).
# Reboot, select single-user from the boot menu. Confirm
# the prompt appears. Type `exit` to continue normal boot.
# If single-user doesn't appear or hangs, fix it before
# proceeding with stage 9.
```

#### Catastrophic substrate failure

If semadrawd, drawfs, or inputfs themselves fail in a way
that locks up the framebuffer or denies input, the recovery
is the same as for a bench-bricked failure (paths 1-3).
pgsd-sessiond's stage 9 testing does not introduce new
substrate failure modes; it only exposes existing ones to
new code paths.

### Cross-bench portability notes

Tests that depend on display resolution are bench-specific:

  - **`Exec=exec semadraw-term --fullscreen --scale 3`** is
    appropriate for the 5K iMac. On the sparrow laptop
    (1024x768), `--scale 1` is correct. Tests that exercise
    the visual appearance of the login UI should record the
    bench they ran on so a divergent result on a different
    bench is interpretable.
  - **`PGSD_RUNTIME_DIR` and `/var/run/pgsd/<uid>/`** are
    bench-independent; tests for these run anywhere.
  - **PAM tests** are bench-independent provided
    `/etc/pam.d/system` is stock. If a bench has operator
    customisations to `system`, document them in the
    session memo.

When a test outcome differs between benches and the
difference is bench-related (not a regression), the ADR's
"Bench testing" section may grow a note. When it indicates a
genuine portability bug in pgsd-sessiond, it's a test failure
to fix.

## Bench testing

This ADR is itself procedural and has no implementation that
needs testing. The verification is meta: ADRs 0001-0006 each
follow the structure this ADR specifies, and future code
commits follow the recording convention.

## Consequences

### What this enables

  - A consistent way to verify pgsd-sessiond stage by stage,
    so "stage N complete" means the same thing across the
    nine stages.
  - A documented recovery path for when stage 9 testing goes
    wrong, so the bench isn't bricked irretrievably.
  - A clear separation between bench-specific values and
    universal protocol behaviour, so tests on one bench can
    be interpreted on another.
  - A session-memo convention for recording outcomes, so
    progress is visible in git history.

### What this forecloses

  - **Automated test running in v1.** Tests are manual. A
    future runner script can be added without ADR amendment;
    this ADR doesn't preclude it.
  - **CI integration of bench tests.** The tests exercise
    bare-metal FreeBSD hardware with specific framebuffer
    and HID devices; a CI runner would need bench-class
    hardware. Out of scope for v1.
  - **Cross-bench result aggregation.** Each session memo is
    its own record; there is no dashboard or summary view.
    If the project grows to need one, that's a separate work
    item.

### What this requires

  - The pre-flight commands listed above work on the target
    bench. They are standard FreeBSD utilities; no special
    install needed.
  - The recovery paths (SSH, single-user mode, rescue media)
    work on the target bench before stage 9 testing.
  - `docs/sessions/` directory exists for memos. It does
    today (memos from 2026-05-10 and 2026-05-11 are present).
  - `pamtester(1)` is installed from ports for the pre-flight
    PAM check. Optional; bench-level pgsd-sessiond binary
    can substitute once stages 1+ ship.
