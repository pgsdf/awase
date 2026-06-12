# 0015 Per-user pointer smoothing via compositor-published parameters

## Status

Proposed.

## Context

Stage D landed pointer coordinate transform (D.3) and focus-driven
routing (D.4) in inputfs. Pointer events that reach userspace
consumers carry display-space coordinates derived directly from
HID device deltas via the transform path. There is no smoothing:
device motion translates one-to-one into pointer position, and
every consumer reading from the inputfs event ring sees the same
unsmoothed values.

AD-2 retires semainputd. Two of the responsibilities semainputd
holds today move out cleanly: classification and aggregation are
already owned by inputfs (Stages B and C); gesture recognition
becomes a userland library (`libsemainput`, AD-2a) consumed by
clients and by the compositor. Pointer smoothing
(`semainput/src/smoother.zig`) does not move out cleanly. It is
the one piece that resists straightforward relocation.

The reason is structural. Smoothing must produce the same
pointer position for every consumer, because the kernel's
surface-under-cursor routing in D.4 depends on pointer position
and clients' visual cursor depends on pointer position, and
disagreement between them is exactly the bug class
(device-accumulated coordinates, the original D-6) that AD-1
was created to eliminate. Per-consumer smoothing in a library
cannot satisfy this — Firefox at α=0.3 and the terminal at
α=0.7 would disagree about cursor position, routing would
target one surface while the visual indicates another.

Smoothing must therefore be applied at a single point upstream
of, or coincident with, routing. Two candidate points exist:

1. **Userland (semadrawd).** semadrawd consumes inputfs events,
   smooths, performs routing against its internal focus state,
   and publishes a per-session event stream that clients
   consume in place of the inputfs ring.

2. **Kernel (inputfs).** inputfs applies smoothing in the
   interrupt path between coordinate transform (D.3) and
   routing (D.4), using parameters published by semadrawd in
   a new shared-memory region.

Path 1 is more consistent with the substrate/policy boundary
stated in `docs/UTF_ARCHITECTURAL_DISCIPLINE.md`: the kernel
publishes hardware truth, userland applies user-visible policy.
It implies moving D.4 routing out of the kernel. It also reopens
landed Stage D work, requires designing a new compositor-to-client
event publication channel, and delays AD-2 closure.

Path 2 keeps Stage D as it landed, scopes smoothing as a small
addition to the existing kernel substrate, and unblocks AD-2
immediately. It places policy data inside the substrate's
application path: parameters are chosen in userland but applied
by the kernel, with the kernel reading the parameters the same
way it reads the focus region today.

This ADR resolves the choice in favour of path 2 for the
specific case of pointer smoothing, accepts the resulting
small impurity in the substrate/policy boundary, and specifies
the publication mechanism in detail.

## Decision

### 1. Smoothing is applied in the kernel from compositor-published parameters

inputfs applies pointer smoothing in the interrupt path. The
smoothed coordinates replace the D.3 transformed coordinates as
the values used for D.4 routing and as the values stamped into
pointer events published to the event ring. There is exactly
one smoothing application per pointer event, performed at a
single point in inputfs's pipeline; consumers do not smooth.

Smoothing parameters are published by semadrawd in a new
compositor-to-kernel shared-memory region:
`/var/run/sema/input/smoothing`. semadrawd is the sole writer.
inputfs is the sole reader. The pattern matches the existing
focus region (ADR 0003): semadrawd holds policy state derived
from per-user configuration, publishes that state to a region,
and inputfs reads the region to apply the policy on the
substrate's hot path.

This is the second compositor-published region inputfs reads.
The pattern of "userland publishes parameters; kernel applies
them on the substrate path" is now precedent rather than
exception. The discipline implication is acknowledged in §6.

### 2. Fixed-point arithmetic only

The kernel applies smoothing using fixed-point arithmetic.
There is no FPU use in inputfs's interrupt path, including for
smoothing. `fpu_kern_enter` / `fpu_kern_leave` is rejected on
the grounds that introducing FPU state to inputfs's interrupt
path makes a property someone reading the code in three years
must understand, in service of a precision win that is
imperceptible at pointer resolutions.

The fixed-point representation is Q16.16 (signed 32-bit, 16
fractional bits). Pointer coordinates fit comfortably (display
sizes through 32K pixels are representable), and 1/65536 of a
pixel is finer than any real input device produces. Algorithm
parameters are encoded in Q16.16 in the published region.

The consequence is that UTF's smoothing algorithms are
specified by UTF, not by external reference. UTF's One-Euro is
*inspired by* the One-Euro paper but is normatively defined by
this specification and the implementation in inputfs. A
recording made on UTF replays identically against UTF; it is
not expected to replay identically against other One-Euro
implementations.

### 3. Algorithm set

Three algorithms are supported in v1:

- **`SMOOTHING_NONE` (0):** identity. The smoothed coordinate
  equals the transformed coordinate. Fast path: no
  multiplication, no state.

- **`SMOOTHING_EMA` (1):** exponential moving average.
  `out = α × in + (1 - α) × prev_out`, with α in Q16.16.
  Default α = 0x4CCC (≈ 0.30). State per axis: previous
  smoothed coordinate (i32 in Q16.16).

- **`SMOOTHING_ONE_EURO` (2):** UTF One-Euro variant. Adaptive
  cutoff with derivative term, all fixed-point. Parameters:
  `min_cutoff` (Q16.16, default 0x10000 = 1.0), `beta`
  (Q16.16, default 0x01CB ≈ 0.007), `d_cutoff` (Q16.16,
  default 0x10000 = 1.0). State per axis: previous smoothed
  coordinate, previous derivative, previous tick. The exact
  fixed-point computation is specified in
  `shared/INPUT_SMOOTHING.md` and the canonical implementation
  is `inputfs_smooth.c` (to be written).

Future algorithms add additional enum values and require a
region version bump. The version field accommodates this.

### 4. Region layout (summary)

The byte-level layout is specified in `shared/INPUT_SMOOTHING.md`.
The header structure mirrors the focus region (ADR 0003):

```
offset 0:  magic = 'INSM' (0x494E534D, big-endian mnemonic per CLOCK.md convention)
offset 4:  version (u8)               # 1 in v1
offset 5:  algorithm (u8)             # 0=none, 1=ema, 2=one_euro
offset 6:  smoothing_valid (u8)       # 0 = compositor initialising
offset 7:  _pad (u8)
offset 8:  seqlock (u32)
offset 12: params[20] (u8[20])        # algorithm-specific, fixed size
offset 32: end
```

Total region size: 32 bytes. The fixed 20-byte parameter block
holds the largest algorithm's parameters (One-Euro: three
Q16.16 values = 12 bytes, plus 8 bytes reserved for v2
algorithms). EMA uses the first 4 bytes (α). `none` uses zero
bytes.

The seqlock follows the same writer-increments-twice protocol
as the state region. The kernel's reader retries on observed
mid-update and applies parameters atomically per event.

### 5. semadrawd as publisher

semadrawd reads two configuration files at session activation:

- `/etc/inputfs/smoothing.conf` — system-wide defaults.
- `~/.config/semainput/smoothing.conf` — per-user override,
  read for the user owning the activating session.

Both are simple key-value text. semadrawd parses them, converts
to fixed-point, and writes the smoothing region under
`SmoothingWriter` in `shared/src/input.zig` (parallel to
`FocusWriter`).

Resolution on session switch: when focus moves to a session
owned by a different user, semadrawd re-reads that user's
config and republishes the region. The transition is atomic
(seqlock). There is no transition smoothing: a hard switch on
session activation matches focus behaviour and is simpler than
hysteresis.

Boot-time and pre-login state: at semadrawd startup before any
user session exists, the system defaults from
`/etc/inputfs/smoothing.conf` are published. If no config files
exist, semadrawd publishes `SMOOTHING_NONE` and logs that
default.

### 6. Discipline implication

This decision places policy data inside the substrate's hot
path. The kernel applies smoothing the kernel did not choose,
using parameters from a region the kernel did not author. This
is a small but real impurity in the substrate/policy boundary
stated in `docs/UTF_ARCHITECTURAL_DISCIPLINE.md`.

The alternative — moving routing to userland alongside
smoothing — was considered and rejected for this iteration on
schedule grounds (it reopens landed Stage D work, delays
AD-2, and forces an immediate decision on the
compositor-to-client event publication channel that has not
been designed). The reversal remains available as a future
move if the precedent established here begins generating
more cases that erode the boundary.

A short addendum to `docs/UTF_ARCHITECTURAL_DISCIPLINE.md`
acknowledges policy-data-applied-by-substrate as the chosen
pattern for cross-consumer-consistent input policy, and names
the consistency-vs-purity tradeoff explicitly. The addendum is
a separate commit accompanying this ADR.

### 7. Validity gating

The smoothing region carries `smoothing_valid` analogous to
the focus region's `focus_valid`. inputfs reads the region on
each pointer event (via the same kthread refresh path that
serves focus); if `smoothing_valid == 0` or the file is
absent, inputfs falls back to `SMOOTHING_NONE`. This makes
smoothing strictly additive: inputfs without semadrawd
running, or before semadrawd has initialised the region,
behaves exactly as today (no smoothing).

This also defines the `hw.inputfs.enable=0` semantics for
smoothing: the existing tunable continues to gate publication
as a whole, and smoothing is part of what is gated. When
publication is off, smoothing is moot.

## Consequences

**Kernel changes.** A new file `inputfs_smooth.c` implements
the three algorithms in fixed-point. The smoothing region
reader extends the existing kthread refresh path (which
currently serves focus only) to also refresh smoothing
parameters. The interrupt path acquires a new step between D.3
transform and D.4 routing: read current parameters via the
seqlock-protected snapshot, apply smoothing, use the smoothed
value for routing and event publication. Per-axis smoothing
state lives in the softc.

**Userland changes.** semadrawd grows a config reader and a
`SmoothingWriter`. Type definitions and the writer/reader pair
land in `shared/src/input.zig`. `semainput/src/smoother.zig`
is deleted as part of the AD-2a/AD-2b sequence (its
responsibility has moved into inputfs).

**Diagnostic tooling.** A new CLI `smoothing-inspect` reads
the region and reports current parameters plus a live raw-vs-
smoothed comparison for development and user-facing config
debugging. Parallels `inputdump` and `chrono_dump`.

**Verification.** A new section in
`inputfs/docs/D_VERIFICATION.md` (or a new `SMOOTHING_VERIFICATION.md`)
covers: region presence and validity transitions; algorithm
selection produces expected output for canonical inputs;
fast-path `none` behaviour matches identity; seqlock retry on
mid-update; fallback to `none` when the region is absent or
invalid.

**Determinism.** Recordings made under UTF replay identically
against UTF given the same smoothing region contents. Captures
should record the smoothing region state alongside the event
stream. This is a small extension to existing capture tooling
rather than a new capability.

**Latency.** One additional snapshot read and one fixed-point
EMA or One-Euro update per pointer event. The snapshot read
shares the kthread refresh with focus and adds no new wakeups.
Per-event cost is dominated by existing transform and routing
arithmetic; smoothing adds one multiply-add per axis (EMA) or
several (One-Euro). Negligible against the surrounding
interrupt-handling work.

**Compatibility with AD-2a.** AD-2a (libsemainput, gesture
library reshape, semainputd retirement) is unaffected by this
ADR. The gesture library reads the inputfs event ring, which
will carry smoothed coordinates after AD-2b lands. No gesture
recognition logic depends on the coordinates being unsmoothed.
AD-2a may proceed in parallel with or ahead of the AD-2b
implementation.

**No raw-stream escape hatch.** Clients cannot opt out of
smoothing. The inputfs event ring is the kernel substrate's
output and carries smoothed coordinates by definition. Tools
that need raw device data (diagnostics, profiling, integration
tests) read via `inputdump` and similar tools that have a
substrate-diagnostic role; this is not a client-facing
capability. The position is documented to forestall future
proposals for opt-out modes that would re-introduce the
consistency-disagreement bug.

## Notes

- The next ADR number for the discipline-doc addendum is a
  top-level UTF concern, not an inputfs ADR. The addendum
  lands directly in `docs/UTF_ARCHITECTURAL_DISCIPLINE.md`.
- The byte-level spec in `shared/INPUT_SMOOTHING.md` lands
  in the same change set as this ADR, before any code that
  reads or writes the region is written.
- The version field allows clean evolution: v2 may extend
  the parameter block, add algorithms, or change semantics
  with explicit kernel-side compatibility logic. v1 is
  frozen by this ADR.
