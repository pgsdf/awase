# AD-59 Part 3: Bootstrap Implementation Experiments

Status: IN PROGRESS (experiment log).

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
     invoked from local.lua. (pending)

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
