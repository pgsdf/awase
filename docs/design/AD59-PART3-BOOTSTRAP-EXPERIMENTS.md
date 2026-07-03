# AD-59 Part 3: Bootstrap Implementation Experiments

Status: IN PROGRESS (experiment log). Research phase complete after
Experiment 4; design phase not yet begun.

Part 3 is the implementation phase of the AD-59 bootstrap architecture. It
proceeds by experiment: before building any bootstrap logic, establish the
facts about the FreeBSD loader that the architecture depends on, each with
the cheapest experiment that answers exactly one architectural question.

Method (carried from the AD-56 investigation and the AD series generally):
each experiment answers ONE question; the observation is the minimum needed
to answer it; observation is recorded separately from interpretation, so no
conclusion is stronger than its observations support; and the containment
mechanism for risk is boot-environment isolation, not code defensiveness.
Experiments run in a dedicated INSTRUMENTATION boot environment
(bootstrap-poc): measurement code only, never policy or implementation. The
verified boot environment (awase-verified-pgsd-clean) is treated as sacred
and is never modified. Temporary activation (bectl activate -t) is used so
that any single experimental boot reverts to the verified default on the
next boot without intervention.

The planned experiment progression (each stops at its exit criterion):

  1. Restore the verified BE as the persistent default (risk reduction, not
     research). DONE.
  2. Create the instrumentation BE. DONE (bootstrap-poc, cloned from the
     verified system so it is known-bootable before instrumentation).
  3. Determine when local.lua executes in the loader lifecycle. (below)
  4. Demonstrate BE redirection using the unmodified bootenvSet sequence
     invoked from local.lua. DONE.

After Experiment 4, STOP: document the established facts, then design the
bootstrap architecture atop demonstrated capability rather than from
speculation. Roles, policy, triggers, and recovery logic are not built
until the capability is proven.

## Substrate facts established by reconnaissance (read-only)

The stock FreeBSD Lua loader provides every mechanic the architecture
needs; Awase must own only bootstrap policy, not boot mechanics:

  - Pre-menu extension hook: loader.lua calls try_include("local"), which
    loads /boot/lua/local.lua if present, before the menu decision. This is
    a sanctioned extension point requiring no modification of stock files.
  - BE enumeration: core.bootenvList() (core.lua).
  - Current default BE: core.bootenvDefault() reads zfs_be_active.
  - Select and boot a BE: bootenvSet(env) (menu.lua), which sets
    vfs.root.mountfrom and currdev (env .. ":"), reloads config, and
    unloads any already-loaded kernel.
  - Read a keypress: io.getchar().
  - Skip the menu for direct boot: beastie_disable=YES / core.isMenuSkipped().
  - /boot is BE-local (each BE is its own root dataset), so a local.lua in
    one BE affects only that BE. This bounds experiment blast radius to the
    instrumentation BE.

## Experiment 3: loader lifecycle position of local.lua

### Question

At what point in the loader lifecycle is local.lua executed relative to the
boot menu and kernel loading?

### Observation

  - local.lua executed before the FreeBSD loader menu was displayed.
  - Execution was paused inside local.lua (via io.getchar()); no menu
    appeared until execution continued. After a keypress, the menu was
    displayed.
  - At execution time the loader variables were:
      currdev            = zfs:zroot/ROOT/bootstrap-poc:
      vfs.root.mountfrom = nil
      kernelname         = nil

### Conclusion

local.lua executes before the loader menu is displayed and before the
kernel has been loaded.

### What this establishes

The loader provides an execution point prior to kernel loading and prior to
menu presentation.

### What this does not establish

This experiment does not demonstrate that changes made by local.lua
influence the eventual boot environment. Whether the observed variable state
(currdev set, vfs.root.mountfrom nil, no kernel loaded, menu not yet shown)
means selection is in progress, provisional, or already complete but
represented differently is interpretation the observation does not settle.
Both questions remain the subject of Experiment 4.

### Method notes

  - Evidence: the primary evidence was the ordering of screen output (the
    banner halted with no menu present; the menu appeared only after the
    pause continued). The loader variables are supporting context and were
    interpreted cautiously, since defaults may be present before any real
    commitment.
  - Isolation held: the instrumentation lived only in bootstrap-poc; the
    verified BE was untouched. The temporary activation reverted the
    persistent default to the verified BE after the single experimental
    boot.

## Experiment 4: BE redirection from local.lua

### Question

Can local.lua redirect the boot to a different boot environment by
performing the same state changes that the loader's own bootenvSet()
performs?

### Method

bootenvSet() is a private (local) function in menu.lua and cannot be called
by name from local.lua. Its operation, however, is entirely a sequence of
public loader primitives, and the menu handler that selects a BE does
nothing but call bootenvSet(). local.lua therefore invoked the identical
primitive sequence, in the identical order, targeting a different
boot environment than the one activated:

    loader.setenv("vfs.root.mountfrom", target)
    loader.setenv("currdev", target .. ":")
    require("config").reload()
    if loader.getenv("kernelname") ~= nil then
        loader.perform("unload")
    end

with target = zfs:zroot/ROOT/known-good-generic. The instrumentation lived
only in the bootstrap-poc BE. bootstrap-poc was activated for a single boot
(bectl activate -t), so the persistent default remained the verified BE.

### Observation (core)

  - Activated BE (bectl activate -t): bootstrap-poc
  - Running BE after boot (bectl list): known-good-generic

The boot environment that booted was not the one activated. The redirect
initiated from local.lua determined the booted BE.

### Ancillary observations (corroborative, not essential)

Consistent with having landed in known-good-generic (the drawfs-disabled
fallback), and not part of the proof:

  - The graphical pgsd-sessiond login did not display (expected: drawfs is
    not loaded in known-good-generic, so the graphical login cannot map the
    framebuffer).
  - An audible beep was heard.
  - An SSH session to the machine succeeded, confirming the system booted
    and was functional.

These are consistent with known-good-generic's design but the core
observation (activated vs. running BE) alone proves the redirect.

### Conclusion

A local.lua hook can successfully redirect the boot to another boot
environment by invoking the same loader primitives used by bootenvSet().

This is stated at the level of demonstrated capability, not architecture.
The architectural conclusion is drawn separately (below), by synthesis with
Experiment 3, rather than asserted from this experiment alone.

### What this establishes

The loader honors a boot-environment redirection initiated from local.lua,
using the loader's own selection primitives. The loader's BE-selection
mechanism is reusable from the local.lua hook.

### Remaining unknowns

This experiment does not establish:

  - how a bootstrap policy decides which BE to select;
  - how recovery is requested or triggered;
  - how retries or rollback should work;
  - how roles are represented or discovered;
  - how persistent state should be stored.

Those are architectural questions that remain intentionally unanswered
here. They belong to the design phase, built atop the demonstrated
capability, not to this experiment.

## Synthesis: what Experiments 3 and 4 together establish

The two experiments compose into an architectural conclusion, drawn here
explicitly rather than claimed by either experiment alone:

  - Experiment 3 established that local.lua executes before menu
    presentation and before kernel loading.
  - Experiment 4 established that the loader honors a BE redirection
    initiated from local.lua, using the loader's own primitives.
  - Therefore local.lua satisfies the technical prerequisites for serving
    as the bootstrap insertion point of the AD-59 Part 2 architecture.

The progression is observation -> capability -> architectural conclusion.
The design is no longer speculative; it has empirical support, without
overclaiming what the individual experiments proved. This closes the Part 3
research phase. The next phase revisits the Part 2 architecture in light of
this evidence; it does not begin by writing bootstrap code.

## Experiment 5: discover() exercised at loader stage

### Question

Does the discover() implementation, run at loader stage in the instrumentation
BE, produce the LOM v1 observation object its contract and the concrete LOM
require?

### Method

The bootstrap module (pgsd_bootstrap.lua) and a thin pausing adapter
(local.lua) were deployed into the bootstrap-poc instrumentation BE only. The
adapter requires the module, calls discover(), prints the observation object,
and pauses. bootstrap-poc was booted under a single-boot temporary activation
(bectl activate -t). No redirect and no policy; observation only.

### Observation

At loader stage, discover() produced:

  lom_version                 = 1
  selected_boot_environment   = zfs:zroot/ROOT/awase-verified-pgsd-clean
  available_boot_environments = 4 entries
    [1] zfs:zroot/ROOT/awase-verified-pgsd-clean
    [2] zfs:zroot/ROOT/bootstrap-poc
    [3] zfs:zroot/ROOT/known-good-generic
    [4] zfs:zroot/ROOT/default
  operator_recovery_request   = unavailable
  promotion_state             = unavailable
  boot_generation             = unavailable

The system then booted normally into bootstrap-poc.

### Conclusion

discover() runs at loader stage and produces the LOM v1 observation object.
The two Available fields carry values from their loader producers; the three
Unavailable fields carry the explicit sentinel. The object carries its LOM
version.

### What this establishes

The first bootstrap responsibility (Discover) is implemented and exercised.
Its Available producers (zfs_be_active, core.bootenvList) work at loader
stage; its Unavailable fields are represented explicitly; and the module runs
without disturbing boot (it booted normally afterward, consistent with the
no-side-effects obligation).

### Ancillary observation (not a defect)

selected_boot_environment reported awase-verified-pgsd-clean while the booted
BE was bootstrap-poc. This is because zfs_be_active reflects the persistent
default, which the temporary activation (-t) left as
awase-verified-pgsd-clean, not the temporarily activated BE. discover()
faithfully reports the loader variable's value; whether "selected" should mean
the persistent default or this boot's environment is an interpretation
question for Decide, not for Discover. discover() correctly reports the raw
value and leaves interpretation to Decide, consistent with the
observation/conclusion boundary.

### What this does not establish

Nothing about Decide, Bind, or Transfer, which are not yet implemented.
Nothing about the Unavailable observations' eventual producers. The exercise
was observational; it does not exercise any redirect (that arrives with
Transfer).

## Experiment 6: decide() exercised at loader stage (DONE)

### Question

Does decide(), evaluating the ratified Selection Policy v1 (Part 12) under
the Part 11 semantics over discover()'s live observation object, produce the
Operational Role at loader stage today?

The Operational result is the expected one because the policy's only
positive rule tests operator_recovery_request, whose producer is unbuilt;
by E1 the rule must fail against the unavailable sentinel and the terminal
rule must select the Operational Role. The experiment therefore exercises,
in one boot: the evaluator, the policy-as-data separation, and E1 against a
real unavailable observation.

### Method

Same deployment as Experiment 5: pgsd_bootstrap.lua (now containing
decide() and the Selection Policy v1 table) and the extended pausing
adapter (local.lua) into the bootstrap-poc instrumentation BE only, booted
under a single-boot temporary activation (bectl activate -t bootstrap-poc).
The adapter calls discover(), prints the observation object, calls
decide(obs, SELECTION_POLICY_V1), prints the selected role, and pauses. No
binding and no redirect: the role is observed, not acted on (Bind and
Transfer are not implemented).

Before the bench run, the evaluator was exercised off-loader as a pure
function over synthetic observation objects (Part 11 independent
testability): E1 against the sentinel, present -> Recovery, absent ->
Operational, determinism, input non-modification, and policy-agnosticism
under a synthetic alternate policy. All passed. The off-loader exercise is
supporting evidence only; the bench run is the acceptance.

### Exit criterion

The printed role is the Operational Role, with the observation object
matching Experiment 5's shape, and the system booting normally afterward.

### Observation

Run on bare-metal-test-bench 2026-07-02, with bootstrap-poc as the
persistent default (bectl activate, not -t; see the note below). The
adapter ran at loader stage before the menu and printed the full LOM v1
observation object followed by the selected role:

    selected_boot_environment   = zfs:zroot/ROOT/bootstrap-poc
    available_boot_environments = 4 entries
        [1] zfs:zroot/ROOT/bootstrap-poc
        [2] zfs:zroot/ROOT/awase-verified-pgsd-clean
        [3] zfs:zroot/ROOT/known-good-generic
        [4] zfs:zroot/ROOT/default
    operator_recovery_request   = unavailable
    promotion_state             = unavailable
    boot_generation             = unavailable

    Selection Policy v1 over LOM v1
    selected role               = operational-role

The system then continued the boot normally to a login.

Two points of note. First, selected_boot_environment reported the
actually-booted BE (bootstrap-poc) this time, differing from Experiment
5, where the temporary -t activation left zfs_be_active reporting the
persistent default rather than the booted BE. Here bootstrap-poc was the
persistent default, so the observation and the booted BE agree. Neither
value is wrong: Discover reports what the loader environment holds, and
what it holds depends on how the BE was activated. Policy v1 does not
read this field, so the difference did not affect the decision.

Second, the result was observable only after adding a pause to the
adapter. On the first attempts the output printed and the boot continued
before it could be read; loader console output cannot be scrolled back.
An io.getchar() pause at the end of the adapter (Experiment 3 established
it works at loader stage) held the block on screen. The earlier "no LOM
block seen" was an observability failure, not an execution failure: the
adapter had been running correctly all along.

### Conclusion

decide() evaluated Selection Policy v1 over the live LOM at loader stage
and produced the Operational Role, satisfying the exit criterion. The
mechanism observed matches the design exactly: operator_recovery_request
was unavailable (no producer built), so R1's predicate
(operator_recovery_request == present) was false by E1 (Part 11), and
evaluation fell through to the terminal rule, which selects the
Operational Role (Part 12). The Operational default emerged from rule
order with no special case, as specified.

This is the bench acceptance for the second bootstrap responsibility.
Discover (Experiment 5) and Decide (this experiment) are both proven at
loader stage. The evaluator, the policy-as-data separation, and E1
against a real unavailable observation all behaved as designed on the
first boot where the output was actually read.

### Discipline note

Loader-stage experiments must build in a pause. The loader console
cannot be scrolled back and the loader proceeds the instant the adapter
returns, so any output without a pause is effectively unreadable. This
cost most of an investigation session that repeatedly misdiagnosed the
flashing output as a deployment, BE-selection, or Lua-environment fault
before it was recognized as pure observability. The pause is now part of
the adapter example. The general rule, alongside the audiofs lesson that
hardware-shaped sub-stages need a register-level spec re-read: loader-
stage sub-stages need a built-in pause and a plan to read the output
before the boot continues.

## Experiment 7: bind() and the driver dispatch at loader stage (DONE)

### Question

Does the driver dispatch (Part 13), run at loader stage over discover()'s
live observations and decide()'s role, resolve the Operational Role to the
selected boot environment by carrying it forward, without consulting the
binding?

The expected result is that resolve_destination() returns
selected_boot_environment for the Operational Role. operator_recovery_request
is unavailable (no producer), so decide() returns the Operational Role, and
the Operational Role is not a role requiring resolution (Part 13): its
implementation is the already-selected boot environment. The dispatch must
therefore carry that boot environment forward and not call bind(). This
exercises, in one boot, the dispatch's Operational branch on real loader
state. The Recovery branch (which would call bind()) cannot be exercised
until the recovery producer exists; it is covered off-loader.

### Method

Same deployment as Experiments 5 and 6: pgsd_bootstrap.lua (now containing
bind() and resolve_destination()) and the extended pausing adapter
(local.lua) into bootstrap-poc's /boot/lua. bootstrap-poc was the persistent
default (NR), so the loader read this BE's /boot/lua. The adapter calls
discover(), decide(), then resolve_destination(role, obs, ROLE_BINDING_V1),
prints the resolved destination, and pauses (io.getchar). No transfer: the
destination is observed, not acted on.

Before the bench run, bind() and the dispatch were exercised off-loader as
pure functions (10 checks): Operational carries the selected boot
environment forward and ignores the binding (even an empty one); the
Recovery Role surfaces a resolution failure today rather than inventing a
boot environment (Part 7 N3); both bind() and the dispatch resolve
correctly once a producer value is supplied. All passed. The off-loader
exercise is supporting evidence; the bench run is the acceptance for the
Operational branch.

A deployment note, recorded because it cost two boot cycles: the loader
adapter is not deployed by install.sh (it is loader-stage experiment
scaffolding, not part of the installed product), so it must be copied into
the target BE's /boot/lua by hand. Twice the copy was missed or half
completed (a dropped newline left the module current and the adapter stale),
producing a stale-code boot that was first misread as an execution failure.
A deploy script now performs both copies and verifies them, retiring this
failure mode.

### Exit criterion

The printed resolved destination equals selected_boot_environment (the
Operational Role carried forward), with the observation object and role
matching Experiment 6, and the system booting normally afterward.

### Observation

Run on bare-metal-test-bench 2026-07-02, bootstrap-poc as persistent
default. The adapter ran at loader stage and printed, after the LOM block
and selected role = operational-role:

    AD-59 Bind/dispatch (Part 13)
    resolved destination        = zfs:zroot/ROOT/bootstrap-poc
    (Decide and resolve only: no transfer)

The resolved destination equals selected_boot_environment
(zfs:zroot/ROOT/bootstrap-poc). The system then continued the boot normally
to a login.

### Conclusion

The driver dispatch resolved the Operational Role to the selected boot
environment at loader stage, satisfying the exit criterion. The mechanism
matches Part 13 exactly: decide() returned the Operational Role (the
operator signal being unavailable), and because the Operational Role's
implementation is already determined by discovered state, the dispatch
carried selected_boot_environment forward and did not consult the binding.
The destination equalling the selected boot environment is the observable
proof of that: no Operational binding was looked up because none exists.

This is the bench acceptance for the Operational branch of Bind and the
dispatch, the third bootstrap responsibility. Discover (Experiment 5),
Decide (Experiment 6), and the Operational dispatch (this experiment) are
proven at loader stage. The Recovery branch, where the role requires
resolution and bind() is invoked, awaits the recovery binding's producer
and is covered off-loader until then. Only Transfer (Part 8) remains
unimplemented.

## Experiment 8a: Transfer dry-run and the transition guard at loader stage (DONE)

### Question

Does the complete pipeline, run at loader stage over discover()'s live
observations, resolve a destination and then correctly apply the driver's
transition guard (Part 14) to determine whether transfer() would be
invoked, without invoking the transfer primitive?

The expected result, on the current bench, is that the pipeline resolves to
the Operational Role and the guard reports no transition. operator_recovery_
request is unavailable (no producer), so decide() returns the Operational
Role; the dispatch carries selected_boot_environment forward without
bind() (Part 13); and the destination therefore equals the currently
selected boot environment, so the driver would continue normal loader
execution and would NOT call transfer() (Part 14, Option A). The transfer
primitive is not invoked in the dry-run, so there is no boot risk: the boot
continues as in Experiment 7. This exercises, on real loader state, the
driver-to-Transfer hand-off and the transition guard's no-transition branch.
The transition branch (would transfer) requires a resolution-path
destination and is covered off-loader and by Stage 8b.

### Method

Same deployment path as Experiments 5 through 7, via the deploy-loader.sh
script (which copies pgsd_bootstrap.lua and the adapter atomically and
verifies them byte-identical, retiring the hand-copy staleness failure). A
staleness note, recorded because it was caught before the run: the bench
working tree was one commit behind (at the Part 14 ratification, bd6db07,
before transfer() and the 8a adapter landed at ae77fa1), so the first deploy
copied the Experiment 7 adapter. git fetch advanced the stale origin/master
reference, git reset --hard moved to ae77fa1, the re-deploy copied the
correct adapter, and grep -c 'DRY RUN' /boot/lua/local.lua returned 2,
confirming the deployed file was the 8a adapter before rebooting. The grep on
the deployed file is the decisive check, independent of git state.

bootstrap-poc was the persistent default (NR), so the loader read this BE's
/boot/lua. The adapter runs discover(), decide(), resolve_destination(), then
reports the Transfer dry-run: whether the driver would transfer, without
invoking the primitive. It pauses (io.getchar).

Before the bench run, transfer() and the driver were exercised off-loader
with a stubbed loader global (18 checks): transfer() transfers to a given
boot environment once and surfaces a nil as a failure; the driver continues
without transfer() when the destination equals the selection, and transfers
only when it differs. The off-loader exercise is supporting evidence; the
bench run is the acceptance for the no-transition branch on real state.

### Exit criterion

The dry-run reports "would NOT transfer, destination is selected BE" and
"driver would continue normal loader execution," with the observation
object, role, and resolved destination matching Experiments 5 through 7, the
transfer primitive not invoked, and the system booting normally afterward.

### Observation

Run on bare-metal-test-bench 2026-07-02, bootstrap-poc as persistent
default. The adapter ran at loader stage and printed, after the LOM block:

    selected role               = operational-role
    AD-59 Bind/dispatch (Part 13)
    resolved destination        = zfs:zroot/ROOT/bootstrap-poc
    AD-59 Transfer (Part 14) DRY RUN
    would NOT transfer          = destination is selected BE
    driver would continue normal loader execution

selected_boot_environment, resolved destination, and the guard comparison
all referenced the same boot environment (bootstrap-poc, the persistent
default that zfs_be_active reflects), so the guard correctly concluded no
transition. The transfer primitive was not invoked; the system booted
normally after the keypress.

### Conclusion

The complete discover, decide, resolve-destination pipeline runs at loader
stage over live observations, and the driver's transition guard (Part 14)
correctly identifies the Operational no-transition case and would decline to
call transfer(). The driver-to-Transfer hand-off and the guard are proven on
hardware with zero boot risk (the primitive was not invoked).

### What this does not establish

The live transfer: the transfer primitive was not invoked, so control was
not actually redirected. The transition branch (would transfer) was not
exercised on the bench, because the current observations resolve to
Operational (no transition); it is covered off-loader and is the subject of
Stage 8b, which drives a resolution-path destination to a known-good boot
environment under single-boot activation, invoking transfer() live.
