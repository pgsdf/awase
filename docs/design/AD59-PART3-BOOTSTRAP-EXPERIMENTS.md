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
