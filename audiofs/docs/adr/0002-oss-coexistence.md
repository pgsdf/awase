# 0002 OSS coexistence

## Status

Accepted, 2026-04-30.

## Context

This ADR resolves question Q3 from
`audiofs/docs/audiofs-proposal.md`'s "Open architectural
questions" section: what is the relationship between audiofs
and OSS for PCM hardware ownership and use?

The proposal frames three plausible postures:

> **Exclusive.** audiofs and OSS cannot coexist on the same
> device; loading audiofs detaches the device from OSS.
> Cleanest semantically, hardest for migration: legacy
> applications break the moment audiofs loads.
>
> **Cooperative.** audiofs attaches to specific devices, OSS
> keeps the others. Operators choose which devices belong to
> which substrate via sysctl or configuration. Allows mixed
> deployment but requires per-device attach/detach machinery.
>
> **Layered.** audiofs sits on top of OSS, opening
> `/dev/dsp` itself and exposing its own substrate to UTF
> consumers. Easiest to implement (audiofs is just a kernel
> process that uses OSS the same way semaaud does today) but
> gives up the "kernel-side device ownership" property that
> motivates the substrate in the first place. Probably wrong
> for that reason, but worth having on the list.

The architectural discipline at
`docs/UTF_ARCHITECTURAL_DISCIPLINE.md` says external code
stays out of the guarantee path. Stage E of the inputfs
proposal applies this principle to evdev: keeping evdev as a
standby would keep it in the guarantee path, since a bug or
change in evdev could affect UTF whenever the fallback
activated or whenever its presence changed timing. The same
logic applies to OSS once audiofs is operational: a fallback
path through OSS is still OSS in the path.

The end-state intent is clear: UTF should not depend on OSS
for anything in the long run. OSS is in the same position
relative to audiofs that evdev is relative to inputfs.

The migration question is separate from the end-state
question. Audio output is end-user-visible: a bug in audiofs
during migration produces immediate, audible failure (silence
or distortion) and disrupts work in progress. Cutting over to
audiofs in one step on a system the operator depends on for
audio is high-risk relative to what the architectural
discipline gains during the transition window itself. The
risk profile during migration argues for a path where audiofs
can come up on a subset of devices while OSS continues
serving the rest, so the operator can verify audiofs works on
their hardware before committing to it for everything.

## Decision

**Layered is rejected.** A layered audiofs that calls into
OSS keeps OSS permanently in UTF's guarantee path. That
contradicts the architectural discipline and would make the
substrate's "kernel-side device ownership" property
permanently aspirational. The proposal already calls this
"probably wrong for that reason"; this ADR makes the
rejection explicit.

**End-state is Exclusive.** Once audiofs is verified on the
hardware UTF runs on, OSS is unloaded. Each PCM device UTF
claims is owned by audiofs alone. Legacy applications that
expect `/dev/dsp` either run against a separate OSS-loaded
host or migrate to semasound. UTF on its target hardware
runs without any OSS module loaded.

**Migration uses a Cooperative-shaped per-device assignment.**
During the migration window between audiofs landing and
OSS unloading, operators control per-device substrate
assignment via a sysctl. The default at audiofs first-load
keeps every PCM device under OSS; the operator opts each
device into audiofs explicitly. Once every UTF-relevant
device is under audiofs and verified, the operator unloads
the OSS modules entirely; from that point on the system is
in the Exclusive end-state.

The sysctl shape is sketched here, not specified normatively:

- `dev.audiofs.devices.<unit>.attach` (read-write integer):
  0 = device is owned by OSS (the default at audiofs load),
  1 = device is owned by audiofs. Writing 1 detaches the
  device from OSS and attaches it to audiofs; writing 0
  reverses.
- `dev.audiofs.devices.<unit>.status` (read-only string):
  reports which substrate currently owns the device, plus
  any error state from the most recent attach/detach
  attempt.

The detailed sysctl tree, including how it interacts with
hot-plug, lives in the audiofs F.1 (skeleton) ADR or its
implementation notes. This ADR commits to the shape, not the
field-level specification.

The migration window is bounded but not time-limited at the
ADR level. The criterion that closes the window is
operator-driven: when every PCM device the operator wants
under audiofs is verified working, OSS is unloaded. There is
no automatic "OSS unloads itself" mechanism; the unload is an
explicit operator action. Stage F.6 of the proposal
("semaaud retirement") names the same shape: semaaud retires
once semasound is verified end-to-end.

## Consequences

- audiofs's attach/detach machinery is per-device. The
  implementation must coordinate with FreeBSD's `snd(4)`
  framework's device claim mechanism so that a device under
  audiofs is genuinely unavailable to OSS-using code while
  the assignment holds. The Stage F.1 (skeleton) work owns
  this; it is mentioned here because the per-device approach
  is what makes the consequence concrete.
- Legacy applications using `/dev/dsp` continue working until
  the operator unloads OSS. Applications that have not
  migrated to semasound by the unload moment stop working.
  This is not graceful degradation; it is deliberate. The
  audiofs proposal's framing ("Either audiofs works or UTF
  does not run on this code path") inherits the same posture
  Stage E's evdev removal takes for input.
- The per-device sysctl is the only operator-facing
  migration control. There is no "force audiofs everywhere
  at load" boot-time tunable; coming up with audiofs owning
  every PCM device by default would amount to Exclusive at
  first load and would lose the per-device verification
  property that motivated Cooperative as the migration
  shape.
- Hot-plug interaction needs explicit specification. When a
  PCM device arrives during runtime, what does its default
  substrate ownership look like? The conservative default
  (owned by OSS at arrival, operator opts in to audiofs) is
  consistent with first-load behaviour but means new devices
  do not automatically benefit from audiofs. The opposite
  default (owned by audiofs at arrival if audiofs is loaded)
  is operator-friendly but reverses the "operator opts in"
  property. This is left to the F.1 ADR's implementation
  notes.
- An operator action is required for the migration to
  complete. If the operator never unloads OSS, the system
  stays in the migration window indefinitely. This is
  acceptable for a UTF-style operator-driven system; the
  discipline does not pretend to make migration automatic.
  The end-state is reachable, not enforced.
- This decision does not specify what happens on a system
  where audiofs is unavailable (build configuration, missing
  hardware support, deliberate operator choice not to load
  it). The natural answer is: such a system uses OSS only
  and is not running UTF's audio substrate. UTF's audio
  surfaces (`/var/run/sema/audio/`) simply do not exist on
  that system. Whether semasound starts, refuses to start,
  or starts in a degraded mode without an audiofs to talk
  to is a semasound concern, not an audiofs one.

## What this document is not

This ADR does not specify the audiofs data path, the mixer
location, the format model, the latency targets, the
serialization format for semasound's userland surfaces, or
the implementation details of per-device attach/detach. Those
decisions live in their own ADRs.

This ADR also does not specify when OSS is unloaded on a
specific system. That is an operator decision driven by their
own verification of audiofs on their hardware. The ADR commits
only to the architectural shape: Cooperative during migration,
Exclusive at end-state, Layered rejected.
