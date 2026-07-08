# pgsd-boot

The AD-59 bootstrap recovery pipeline: loader-stage policy, written
in Lua, that runs inside FreeBSD's stock loader.efi and makes a
verified recovery boot environment reachable rather than merely
present. It selects the correct boot environment and transfers to it
without the operator needing memorized loader syntax under stress.

This directory is POLICY, not loader mechanism. It does not parse the
kernel, own the framebuffer, or replace loader.efi; it decides which
environment to boot and redirects to it from within the loader it runs
under. The fresh EFI loader that replaces loader.efi is a separate
component, `pgsd-loader/` (see Relationship below).

## What this component is

The four-responsibility recovery pipeline of AD-59 (Discover, Decide,
Bind, Transfer), each one transformation ignorant of the rest:

  - Discover observes the loader environment and returns a versioned
    Loader Observation Model (LOM v1) object, unavailable fields
    explicit rather than omitted.
  - Decide evaluates a separate policy artifact (Selection Policy v1)
    against the observation and selects a role; the Operational
    default emerges by fallthrough, not a special case.
  - Bind resolves an unresolved role to a concrete boot environment.
  - Transfer performs the boot redirect once, and only for a real
    transition (the driver's transition guard declines the
    no-transition case at zero risk).

## Contents

  - `lua/pgsd_bootstrap.lua`: the portable module (discover, decide,
    bind, resolve_destination, transfer, run). Loader-mechanism
    agnostic: only its observation producers are loader-specific.
  - `lua/local.lua.example`: the thin adapter the stock loader's
    try_include("local") hook runs pre-menu.
  - `lua/local.8b.lua.example`, `lua/local.p15.lua.example`: the
    Experiment 8b and Part 15 adapters.
  - `deploy-loader.sh`: deploys and verifies the module and adapter
    pair atomically.

## Status

Tracked as AD-59 in the repository BACKLOG.md. The pipeline is
validated end to end on bare-metal-test-bench (Experiments 5 through
9): observation, policy evaluation, role resolution, the transition
guard, and a live boot redirect. The operator_recovery_request
producer is real (Experiment 9: an operator can now invoke recovery).
The Recovery binding producer (the AD-58 promotion write path) and the
promotion_state and boot_generation producers remain.

## Naming

The directory is `pgsd-boot`, matching the `pgsd-` distribution
component family. The name predates the split between boot policy and
boot mechanism: an earlier plan expected the fresh loader to live here
too, which is why older revisions of this README described a loader.
That role moved to `pgsd-loader/`, and `pgsd-boot` settled into its
actual and narrower identity, the AD-59 recovery policy. The name is
kept (collision-free, descriptive, sibling to `pgsd-kernel`) rather
than churned.

## Relationship to pgsd-loader and the boot-path programs

Two directories carry boot-related work; they do not overlap:

  - `pgsd-boot/` (this component, AD-59): recovery POLICY in Lua,
    running today inside the stock loader.efi.
  - `pgsd-loader/` (AD-62, the AD-56 Phase 3 implementation): the
    fresh EFI loader in Zig that replaces loader.efi, owning the boot
    MECHANISM (kernel parse, memory map, framebuffer, kernel handoff).

They are one recovery architecture with two implementation mechanisms
over time: the AD-59 policy runs as a local.lua extension now, and is
written to migrate into the pgsd-loader loader later, at which point
only its loader-specific observation producers change. AD-59's
operator_recovery_request contract and pgsd-loader's eventual menu
ownership set the same loader variable by design.

The AD-56 boot-path-ownership program and its design documents
(BOOT-PATH-OWNERSHIP.md, the AD56-* phase documents) live at the
repository root under `docs/design/`, not in this directory.
