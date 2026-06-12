# 0020 F.5 (semasound) decomposition

## Status

Accepted, 2026-06-01 (ratified same day as proposed). This
ADR is to F.5 what ADR 0011 is to F.3: it names the
sub-milestones of semasound and their dependency map. It
does not scope their internals; each sub-milestone receives
its own ADR before implementation, per the discipline ADR
0011 set and the operator's structuring decision recorded
below. It does not reopen ADR 0004 (mixer location) or ADR
0007 (physics/semantics boundary); it inherits both as
binding constraints.

Per ADR 0011, F.5 is the userland half of AD-3 Stage F. It
depends on F.3.b-e (user-control surface, position, xrun,
format negotiation, all bench-verified `[x]`) and on F.4
(the audiofs-written clock, bench-verified `[x]`). Those
dependencies are now satisfied, so F.5 is unblocked.

## Context

semasound does not exist yet. semaaud, the OSS-based daemon,
is the feature reference but not a code base: its output
path is OSS (`oss_output.zig`), which AD-3 removes, so its
core is discarded. Its other modules (`control_server`,
`policy`/`policy_state`, `surfaces`, `state`,
`stream_worker`) map to semasound responsibilities and
inform later sub-milestone design without being inherited as
code.

ADR 0004 fixed the structural model: Option A, single-writer
broker. semasound is the sole writer to audiofs; client
applications connect to semasound over a Unix socket;
semasound mixes in userland and writes one mixed stream per
output device. sndio is the named reference architecture.

ADR 0007 fixed the boundary: audiofs is physics-only, so all
semantic behaviour concentrates in semasound. That is a
large surface, resampling, mixing, dithering, clipping,
xrun recovery, format election, routing, policy, which is
why F.5 is decomposed rather than built as one unit.

## Binding constraints (inherited by every F.5 sub-milestone)

These are not re-litigated in the per-sub-milestone ADRs;
they are the invariants each must satisfy.

  1. **Single-writer broker (ADR 0004).** semasound is the
     only writer to `/dev/audiofs0`. Clients never open
     audiofs directly; they reach it only through
     semasound's IPC.
  2. **All semantics in userland (ADR 0007 core rule).**
     Resampling, mixing, dithering, clipping, channel work,
     and xrun recovery are semasound's. audiofs stays
     physics-only; nothing in F.5 pushes semantic behaviour
     down into the kernel.
  3. **Format election through the one fenced control path
     (ADR 0007 stress case 2).** semasound elects the
     hardware format via the F.3.e `SET_FORMAT` ioctl. That
     is the only permitted downward path, and it carries
     mode selection only, never transformation logic.
  4. **Rate correction, not position correction (ADR 0007,
     normative).** semasound runs a free-running local
     playback model from its own buffer accounting and uses
     the F.4 clock to correct long-term drift *rate*, not to
     apply per-observation position jumps. An implementation
     that samples the clock and snaps to the reported sample
     satisfies a loose reading of ADR 0006 while violating
     this requirement.
  5. **Clock independence (ADR 0007 stress case 3).** Audio
     stops if semasound dies; that is acceptable. The
     chronofs clock must not. audiofs advances the clock from
     hardware progression regardless of semasound liveness,
     so semasound is never on the clock's critical path and
     must not be architected as if it were.
  6. **sndio is the reference (ADR 0004).** Small API,
     privilege separation, explicit timing model. Divergence
     from that shape needs a reason recorded in the relevant
     sub-milestone ADR.

## Decision

### Structure: decompose, one ADR each

F.5 is decomposed into the named sub-milestones below. Each
receives its own ADR before implementation, mirroring F.3
(ADR 0011 named the sub-milestones; ADRs 0014-0019 scoped
them one at a time). This is the operator's structuring
decision (2026-06-01): a subsystem this size gets the same
decompose-and-ADR-each discipline F.3 used, not a single
omnibus ADR and not a one-pass build.

### Sub-milestones

  - **F.5.a Mixer core and audiofs output.** The broker
    spine: a Unix-socket server accepting multiple
    concurrent clients at the canonical format (48 kHz /
    16-bit / stereo), a userland summing mixer, a single
    mixed write to `/dev/audiofs0`, a free-running local
    playback model with rate correction against the F.4
    clock, and xrun-event consumption with a userland
    recovery policy. Establishes the client IPC protocol.
    Clients present the canonical format in this
    sub-milestone; arbitrary-rate clients are F.5.b. This is
    the operator's chosen first deliverable: the mixer is in
    the spine from the start, not deferred behind a
    single-client passthrough.

  - **F.5.b Format adaptation.** Per-client resampling and
    format conversion so clients at arbitrary rates and
    formats mix correctly into the output, and output-format
    election via the F.3.e `SET_FORMAT` path (choosing the
    hardware rate that best serves the current client mix).
    All conversion lives here because audiofs is
    native-only.

  - **F.5.c Targets and routing.** The named-target topology
    and per-target routing (the `surfaces.zig` concern):
    addressable outputs, per-target stream assignment, the
    routing model a client uses to say where its audio goes.

  - **F.5.d Policy.** Preemption, fallback, priority/ducking,
    and durable policy persistence (the `policy.zig` /
    `policy_state.zig` concern). Policy acts on the targets
    and routing F.5.c establishes.

  - **F.5.e State publication and observability.** Per-stream
    and per-target state publication (the `state.zig`
    concern) for consumers and operators, plus a semasound
    inspect/dump tool in the pattern of audiofs's
    `clock_dump` / `audiofs_events_dump`.

  - **F.5.f Supervision and lifecycle.** s6 service
    integration and fresh-install enablement so semasound
    runs as the system audio daemon, the lifecycle work that
    makes F.6 (semaaud retirement) actionable once parity is
    reached.

### Dependency map

  - F.5.a is the spine; every other sub-milestone depends on
    it.
  - F.5.b depends on F.5.a (a mixer must exist to adapt
    formats into).
  - F.5.c depends on F.5.a and may proceed in parallel with
    F.5.b.
  - F.5.d depends on F.5.c (policy acts on targets/routing).
  - F.5.e depends on F.5.a and can land incrementally
    alongside F.5.b-d.
  - F.5.f depends on a usable functional core (F.5.a-d) and
    feeds F.6.
  - F.6 (semaaud retirement) depends on F.5 reaching feature
    parity across its sub-milestones, per ADR 0011.

### Codebase and location

semasound is greenfield (operator decision, 2026-06-01),
living in a new top-level `semasound/` component mirroring
`semaaud/`, `semainput/`, `semadraw/`. It is Zig, consistent
with the other userland daemons. semaaud is a feature
reference; its OSS output path is discarded and its other
modules inform design only.

F.5 ADRs continue the AD-3 Stage F series in
`audiofs/docs/adr/` (this ADR is 0020), since F.5 is
sequenced under ADR 0008 and named by ADR 0011 from that
series, keeping the Stage F decision record in one sequence.

## Rejected alternatives

**Single omnibus F.5 ADR, or a one-pass build.** Rejected by
the operator. A subsystem spanning mixing, resampling,
routing, policy, and supervision is not reviewable or
bench-verifiable as one change, and one-pass construction
would violate ADR-before-code at the sub-milestone grain,
the same reasoning ADR 0011 applied to F.3.

**Single-client passthrough as F.5.a, mixer deferred.**
Rejected by the operator in favour of the mixer in the
spine. A passthrough slice would be reworked the moment the
mixer lands; making F.5.a multi-client means the core data
path is load-bearing from the first sub-milestone. The cost
is a larger F.5.a, accepted.

**Fork semaaud as the semasound base.** Rejected in favour
of greenfield. semaaud's core is its OSS output path, which
AD-3 removes; the broker/mixer model and the audiofs output
path differ enough that adapting semaaud would carry more
legacy structure than it saves. semaaud remains a feature
reference.

## Consequences

  - F.5 has a named, dependency-ordered path from spine
    (F.5.a) to retirement-enabling lifecycle (F.5.f), each
    step independently ADR'd and bench-verified.
  - The binding constraints are stated once here rather than
    re-argued in six sub-milestone ADRs.
  - The first implementation work (F.5.a) is well-defined but
    substantial; its own ADR scopes the IPC protocol, the
    mixer's buffer/timing model, and the audiofs write path
    in detail.
  - F.5 verification host: the analog path on
    `pgsd-bare-metal` suffices for F.5.a-e (semasound is
    hardware-agnostic above audiofs). F.5.f's enablement is
    verified on the same target.

## Closure criteria

F.5 closes when F.5.a through F.5.f each close, each
bench-verified per its own ADR. F.6 may then begin.

This ADR closes (is ratified) when the operator accepts the
decomposition and dependency map; the first sub-milestone
ADR (F.5.a) follows.

## References

  - ADR 0004 (mixer location): single-writer broker, sndio
    reference.
  - ADR 0007 (physics/semantics boundary): the core rule and
    the four stress cases that bind every sub-milestone.
  - ADR 0011 (F-stage reconciliation): names F.5/F.6, sets
    the decompose-and-ADR-each discipline this ADR applies.
  - ADR 0018 (F.4 clock writer): the clock semasound
    rate-corrects against.
  - ADR 0019 (F.3.e format negotiation): the `SET_FORMAT`
    control path semasound elects format through.
  - `semaaud/src/`: the feature reference
    (`control_server`, `policy`, `surfaces`, `state`,
    `stream_worker`; `oss_output` is the discarded core).

## Revision history

  - 2026-06-01: first draft. Decomposition into F.5.a-f with
    dependency map; binding constraints from ADR 0004/0007
    consolidated; three operator structuring decisions
    recorded (decompose with per-sub-milestone ADRs;
    multi-client mixer as F.5.a; greenfield codebase).
