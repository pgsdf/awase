# 0020 Stage E completion: removal of the hw.inputfs.enable coexistence tunable

## Status

Proposed, 2026-05-19.

This ADR governs an irreversible, guarantee-path code change and
exists because Stage E's text mandates a removal that no prior
ADR or BACKLOG entry scoped. It is the ADR-before-code record for
deleting the `hw.inputfs.enable` sysctl and its publication-gating
machinery from the inputfs kernel module.

## Context

`inputfs/docs/inputfs-proposal.md`, Stage E, states three cutover
requirements beyond "semadrawd reads the inputfs path": the
`semainputd` evdev reader and `drawfs_inject.zig` are removed, and
"the `hw.inputfs.enable=0` tunable from Stage D is removed."

The first two are done. AD-2a Phase 1 moved semadrawd onto the
inputfs ring (2026-05-06, bare-metal verified); AD-2a Phase 3
removed the userspace evdev side (`semainputd`, `evdev.zig`,
`drawfs_inject.zig`, the rc.d shim, the service directory). AD-2
is marked done 2026-05-17.

The third requirement is not done and is tracked nowhere. The
tunable was introduced in Stage D as D.5 ("`hw.inputfs.enable`
tunable: gate publication"), a deliberate coexistence mechanism
for the period when both the inputfs path and the evdev-injected
path were live and tunable-switched. AD-2's Phase 3 deletion list
enumerates the userspace evdev removals but does not include this
kernel-side gate; it fell into the gap between the stage that
created it (D) and the entry that closed the userspace cutover
(AD-2 Phase 3). The source still carries it:

- `inputfs/sys/dev/inputfs/inputfs.c:185` `static int
  inputfs_enable = 1;`
- `:186-188` `SYSCTL_INT(_hw_inputfs, OID_AUTO, enable,
  CTLFLAG_RWTUN, ...)`
- `:2568` `int prev_enable, curr_enable;` in
  `inputfs_state_worker`
- `:2585-2587` the D.5 comment and `prev_enable = inputfs_enable
  ? 1 : 0;` initialisation
- `:2632-2664` the per-iteration edge-detection block that calls
  `inputfs_publish_valid(td, 0|1)` on a 1->0 or 0->1 transition
- `:2667-2674` the `if (curr_enable)` guard that suppresses
  `inputfs_state_sync_to_file` / `inputfs_events_sync_to_file`
  when gated off

Per Stage E's own rationale, this is not cleanup. While the gate
exists, an operator can set `hw.inputfs.enable=0` at runtime
(`CTLFLAG_RWTUN`) or in `loader.conf` and stop inputfs publishing
without unloading the module. Stage E's stated purpose is "UTF
runs on inputfs in production with no evdev fallback ... Either
inputfs works or UTF does not run on this code path." A live
disable path is a reachable state in which inputfs is loaded but
silent; whatever the operator expects to handle input in that
state is, by construction, the legacy path. The publication gate
is the last runtime-reachable seam by which non-inputfs input
behaviour re-enters the guarantee path. `docs/UTF_ARCHITECTURAL_
DISCIPLINE.md` places external code out of the guarantee path
including fallbacks; the gate is the mechanism that keeps a
fallback reachable.

### What is NOT in scope

There are two distinct `inputfs_enable` identifiers and only one
is removed by this ADR.

- **`hw.inputfs.enable` sysctl** (kernel module, `inputfs.c`):
  the D.5 runtime publication gate. **Removed by this ADR.**
- **`inputfs_enable` rc.conf rcvar** (`install.sh`, the generated
  `/usr/local/etc/rc.d/inputfs`): the standard FreeBSD service
  variable controlling whether `inputfs.ko` is `kldload`ed at
  boot. **Not touched.** This is normal service plumbing, not a
  coexistence fallback; removing it would mean the module could
  never be disabled as a service, a different and unwanted
  decision. The rc.d `REQUIRE`/`BEFORE` ordering and the
  install.sh AD-12.1 stop-and-restart sequence are likewise out
  of scope.

Conflating these two would be an error; this section exists so
the boundary is on the record before code is written.

## Decision

### 1. The hw.inputfs.enable sysctl and its gating logic are removed

The following are deleted from `inputfs/sys/dev/inputfs/
inputfs.c`:

- the `inputfs_enable` declaration and the `SYSCTL_INT`
  registration
- the `prev_enable, curr_enable` locals in
  `inputfs_state_worker`
- the D.5 initialisation comment and `prev_enable` seed
- the per-iteration edge-detection block (the 1->0 and 0->1
  arms, both `printf`s, the `inputfs_publish_valid` edge calls,
  the `prev_enable = curr_enable;` update)
- the `if (curr_enable)` guard around the state/events file
  syncs; the two `inputfs_*_sync_to_file` calls become
  unconditional

After removal the state worker publishes unconditionally whenever
work is dirty. This is the Stage E end state: publication is not
gateable at runtime; inputfs is either loaded and publishing or
not loaded.

### 2. inputfs_publish_valid is removed (corrected after pre-code grep)

This point originally proposed retaining `inputfs_publish_valid`
on the assumption it had module load/unload lifecycle callers.
The ADR-mandated pre-code grep falsified that assumption:

```
2513: * inputfs_publish_valid -- Stage D.5.   (comment)
2531: inputfs_publish_valid(struct thread *td, uint8_t valid)  (definition)
2648:   inputfs_publish_valid(td, 0);   (1->0 edge arm)
2658:   inputfs_publish_valid(td, 1);   (0->1 edge arm)
```

The only two call sites are the enable-edge arms being removed by
point 1. There is no attach/detach caller; the function header
comment itself marks it "Stage D.5", confirming it was introduced
solely for the coexistence gate. Removing the edge block
therefore orphans `inputfs_publish_valid` entirely.

Decision: `inputfs_publish_valid` (definition at :2531, its
preceding comment block at :2513 onward) is deleted along with
the gate. The publication files carry their valid flag through
the normal `inputfs_*_sync_to_file` path; the separate
edge-driven valid=0/1 writes existed only to make the gate
transition visible to readers and have no purpose once the gate
is gone.

This correction is itself the reason the discipline exists: the
ADR required verification before code, the verification
contradicted the draft decision, and the decision was changed on
paper before any edit, not after.

### 3. No deprecation period

The sysctl is removed outright, not deprecated. `CTLFLAG_RWTUN`
means a `loader.conf` entry could set it at boot; after this
change an `hw.inputfs.enable` line in `loader.conf` becomes an
unknown-oid no-op (a harmless boot warning, not a failure).
Stage E is a deliberate one-way commitment by design; a
deprecation window would itself be a coexistence period, which is
the thing Stage E removes. The operator-facing migration story is
section 4.

### 4. Operator migration

The supported way to stop input flow without unloading the module
is withdrawn. The replacement is the standard one Stage E
implies: stop or unload inputfs as a service
(`service inputfs stop` / `kldunload inputfs`), which the
AD-12.x rc.d plumbing already supports. An operator who today
relies on `hw.inputfs.enable=0` for the use cases named in the
source comment (debugging consumer races, isolating the
substrate, clean shutdown ordering) uses module unload instead.
[OWNER: this is the one genuinely operator-affecting consequence.
Confirm the rc.d stop path is an acceptable substitute for all
three named use cases, or record which lose tooling. The
debugging/race-isolation case in particular previously did not
require an unload; decide whether that capability is
intentionally dropped or needs a debug-only replacement outside
the guarantee path.]

### 5. What this ADR does not do

- It does not touch the `inputfs_enable` rc.conf rcvar or any
  install.sh / rc.d service wiring.
- It does not modify the interrupt path or the in-memory
  buffers. Those always tracked current state regardless of the
  gate; only file publication was gated. Behaviour after removal
  is identical to behaviour with `hw.inputfs.enable=1`, which is
  the default and the verified-on-bare-metal configuration.
- It does not retroactively edit the Stage D / D.5 record. D.5
  legitimately introduced the tunable for the coexistence
  period; this ADR closes that period. The inputfs proposal's
  Stage E text already mandates the removal and needs no
  amendment; this ADR is the missing tracking and decision
  record, not a scope change.
- It does not by itself reconcile the stale "Stage E pending"
  status in the integration README and BACKLOG. That is a
  separate documentation pass (see Consequences).

## Consequences

### What this resolves

- The last requirement of the inputfs proposal's Stage E is
  implemented. After this change there is no runtime-reachable
  state in which inputfs is loaded but not publishing, which is
  the architectural-discipline property Stage E exists to
  establish.
- A proposal-mandated removal that was tracked by no ADR or
  BACKLOG entry is now recorded, decided, and scoped before
  code, consistent with the project's ADR-before-code
  discipline.

### What this changes for operators

- `hw.inputfs.enable` ceases to exist. Runtime gating of
  publication is no longer possible. The substitute is service
  stop / module unload. This is the only externally observable
  behaviour change and is the subject of the OWNER confirmation
  in Decision section 4.

### Risk and verification

- The change is small and removes code rather than adding it;
  the post-removal worker is the `curr_enable == 1` path that
  has been the default and the bare-metal-verified configuration
  throughout AD-2. Risk is low but nonzero because the edits are
  inside the live publication thread.
- This ADR does not assert the change is correct; it requires
  bare-metal verification on `pgsd-bare-metal` after the code
  lands, on the same runbook basis as AD-2a Phase 2.5: input
  continues to flow end to end (keys, pointer, gestures) with
  the gate code gone, and `sysctl hw.inputfs.enable` reports
  the oid as unknown. The ADR moves to Accepted only after that
  verification, in the manner Stage E sub-items were closed.
- Pre-code grep, recorded here as the ADR required before
  edits:
  - `inputfs_publish_valid` call sites: only `:2648` and
    `:2658`, the two edge arms. No lifecycle caller. Function
    is orphaned by gate removal and is therefore deleted
    (Decision point 2, corrected).
  - Published valid-byte writers (`OFF_VALID` / `EV_OFF_VALID`
    at file offset 5): init writes valid=0 at `:1076` /
    `:1540`; steady-state writes valid=1 at `:4279` / `:4534`
    in the normal buffer path; plus the two writes inside
    `inputfs_publish_valid` itself. The normal sync path
    therefore carries the valid flag independently of the
    deleted function; readers still see valid=1 in steady
    state after removal. This was verified, not assumed; an
    earlier draft of this ADR asserted it without evidence and
    the grep was required to confirm it.

## What this document is not

- **A Stage D revision.** D.5 correctly introduced the tunable
  for the coexistence period. This closes that period; it does
  not claim D.5 was wrong.
- **An rc.conf / service change.** The `inputfs_enable` rcvar
  and all install.sh/rc.d wiring are explicitly out of scope.
- **A documentation reconciliation.** The stale "Stage E is the
  next intentional act" text in the integration README and the
  AD-2-vs-proposal status gap are real but are a separate pass;
  this ADR only notes them.
- **Self-asserting closure.** It is Proposed. It becomes
  Accepted only after the code lands and bare-metal
  verification passes, with the OWNER items in sections 2 and 4
  resolved.
