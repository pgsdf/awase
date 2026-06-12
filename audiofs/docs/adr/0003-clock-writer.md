# 0003 Clock writer

## Status

Accepted, 2026-05-11.

## Context

This ADR commits audiofs to writing the chronofs clock region
from kernel context, regardless of how the larger audiofs
architecture resolves. It is identified in
`audiofs/docs/audio-design-space.md` (the design-space
discovery document of 2026-05-11) as the only load-bearing
kernel-side requirement audiofs has: every other audiofs
question can in principle be answered with a userland design,
but the clock writer cannot.

The clock writer's role is documented in `shared/CLOCK.md`.
The region at `/var/run/sema/clock` carries a 20-byte
header-plus-counter layout, magic `SMCK` (0x534D434B), version
1, with `samples_written` (u64) the monotonically-increasing
field that other UTF daemons read to obtain the audio-derived
clock. `clock_source = 1` (audio) marks the region as
audio-driven; `clock_valid = 1` marks the region as live
(the producer has begun a stream).

`docs/Thoughts.md` commits chronofs to "audio as source of
truth": the global monotonic clock is driven by the audio
hardware's sample-position counter. The audiofs proposal
(`audiofs/docs/audiofs-proposal.md`, Stage F.4) plans for
audiofs to take over clock writing as part of its broader
substrate work. The discovery document surfaces that this
sub-decision is independent of the larger Q1-Q5 questions
about mixer location, data path, format model, and latency
targets, and can land before any of them.

This ADR pulls the clock writer out of the implicit framing
in the proposal and treats it as a separable commitment.
Three things motivate doing this first:

  - The decision is small enough to specify clearly without
    waiting on Q2 (mixer location) or Q1 (data path).
  - Landing it unblocks chronofs improvement work that is
    currently bounded by semaaud's "frames-written-to-OSS"
    approximation rather than the codec's actual position.
  - It validates the discovery document's recommended
    ADR sequence with the smallest possible commitment.

The decision below is straightforward; the load-bearing
content is the explicit choice of what semantic the
`samples_written` counter actually represents.

## Decision

### 1. The clock writer becomes a kernel-side facility of audiofs

audiofs reads the audio hardware's frame-position counter
through FreeBSD's `snd(4)` framework, on audio-interrupt
context, and writes it to `/var/run/sema/clock` from kernel
code. The userland audio daemon (semaaud today, semasound
under audiofs's broader proposal) is no longer the writer.

The wire format at `/var/run/sema/clock` does not change.
The 20-byte layout, magic, version, valid/source/pad bytes,
sample_rate, and samples_written fields all retain their
meaning per `shared/CLOCK.md`. `clock_source` continues to
read 1 (audio). Existing readers (chronofs, semadraw frame
scheduler, semainput) see no protocol change.

### 2. The semantic of `samples_written`

`samples_written` represents the count of frames the codec
has actually clocked out, as reported by FreeBSD's `snd(4)`
buffer-pointer mechanism (`xxxchannel_getptr()` and the
sndbuf accessor functions reachable from the pcm core's
`chn_intr()` path). It is not the count of frames the kernel
has handed to the codec, and not the count of frames userland
has written to a device file.

This is a precision improvement over semaaud's current
implementation. semaaud counts bytes returned by
`posix.write(audio_fd, ...)` divided by bytes-per-frame; that
value reflects what userland has handed to OSS, not what the
codec has clocked out. The two values differ by the codec
FIFO depth, which on typical HDA hardware is on the order of
10 to 50 milliseconds of audio. For chronofs's frame-
scheduling purposes (~16 ms intervals), the difference is
small but real.

The frames-actually-clocked-out semantic is the one
`docs/Thoughts.md` argues for ("audio as source of truth"
means the codec's actual position, not userland's
approximation of it). The audiofs proposal Stage F.4
description ("audiofs knows the actual hardware sample
position through `snd(4)`'s buffer-pointer reporting")
implies the same. This ADR makes the semantic explicit.

The wire format does not encode which semantic is in use.
Readers cannot distinguish a frames-clocked-out value from
a frames-handed-to-OSS value; they receive a u64 and act
on it. The semantic change is transparent in that sense.
Diagnostic tooling that wants to detect the change can read
`clock_source` (which remains 1 = audio) plus inspect which
process holds the file open, but in practice no current UTF
consumer needs to distinguish.

### 3. Update cadence

The clock writer updates `samples_written` on each audio
interrupt that reflects new frames clocked out. On HDA
hardware, this is typically every 1-10 ms depending on the
configured buffer block size; on USB audio, it is bounded by
the USB frame period (1 ms). The cadence is hardware-driven
and stable.

This is a meaningful improvement over semaaud's userland-
driven cadence, which is bounded by how often the userland
audio thread completes a `posix.write` and then calls
`ClockWriter.update()`. Under userland scheduling load, this
cadence becomes load-dependent; the kernel-side cadence is
not.

### 4. Lifecycle

audiofs initialises the clock region at module load:

  - `clock_valid = 0`, `clock_source = 1` (audio),
    `sample_rate = 0`, `samples_written = 0`.
  - The region is created if absent, truncated if present, in
    line with the existing `ClockWriter.init()` semantics in
    `shared/src/clock.zig`. Mode `0o600` per
    `inputfs/docs/adr/0013-publication-permissions.md`.

When the first audio stream begins (the codec's transfer
buffer becomes active for the first time):

  - `sample_rate` is written to the negotiated rate.
  - `clock_source` is confirmed as 1 (audio).
  - `clock_valid` is atomically stored as 1 (seq_cst).

When subsequent streams begin (after a stop-start cycle):

  - `samples_written` continues from where it left off (the
    counter is monotonic; this is the existing semaaud
    behaviour and is preserved).
  - If the new stream's rate differs from the prior stream's
    rate, `sample_rate` is updated. The discontinuity is
    reflected in the conversion from samples to nanoseconds
    that `shared/src/clock.zig`'s `toNanoseconds` performs;
    consumers that need rate-change observability obtain it
    through audiofs's event ring (a future ADR), not through
    the clock region.

When audiofs unloads:

  - The region remains on disk with its last value. This
    matches semaaud's current behaviour (the file persists
    across daemon restarts; the next start truncates and
    reinitialises).

### 5. semaaud's clock-writer code path becomes redundant

This ADR commits to the design but does not commit to the
removal of the existing semaaud code path. The redundancy
is recognised; the actual removal is part of Stage F.4
(Clock takeover) in the audiofs proposal, which depends on
the audiofs kernel module being landed and verified on the
target hardware.

In the interim (between this ADR being accepted and audiofs
being implemented), semaaud continues to write the clock
region from userland exactly as it does today. The behaviour
of `/var/run/sema/clock` is unchanged from any reader's
perspective. The ADR establishes the destination shape; the
code change happens later.

### 6. Independence from Q2 (mixer location)

The clock-writer ADR is independent of the substrate-vs-
broker question framed by Q2 in the discovery document. The
codec's frame-position counter is read regardless of whether
audiofs sees individual streams or a mixed output, regardless
of whether the userland audio component is structured as a
sole-writer or a broker. Whatever audiofs's data path turns
out to be, the kernel reads `xxxchannel_getptr()` on each
audio interrupt and writes the result to the clock region.

This independence is the reason this ADR can land before Q2.
The clock writer is one specifiable obligation; the data
path and mixer architecture are separate decisions.

### 7. Independence from OSS coexistence (Q3, ADR 0002)

ADR 0002 ("OSS coexistence") establishes that audiofs and OSS
coexist via per-device assignment during migration, with the
end-state being audiofs-exclusive ownership. The clock writer
follows the device assignment: audiofs only writes the clock
region for devices it owns. If OSS owns the default device
during migration, semaaud (running against OSS) writes the
clock region as it does today. If audiofs owns the default
device, audiofs writes it.

This is consistent with the "one writer, period" property
of the clock region. At any given time, exactly one of
{semaaud against OSS, audiofs in the kernel} writes the
counter. The handoff happens at the device-assignment level,
not at runtime within a single device.

### 8. snd(4) as an evolving guarantee-path dependency

**Posture superseded by ADR 0006 (2026-05-17).** This
section's posture - accept snd(4) as platform transport
under a per-FreeBSD-version semantic-drift gate - was
superseded by the decision to replace snd(4) in full,
including its hardware-driver layer. The analysis below is
retained unedited as the record of why conditional
acceptance was considered and why it was judged
insufficient: it bounds *correctness* drift in snd(4)'s
reported semantics but cannot bound *performance* drift in
the codec interrupt path, and that gap is the stated
rationale for ADR 0006. Read this section as the argument
that led to ADR 0006, not as the current posture. The F.7
semantic-drift gate specified here is subsumed by UTF owning
the hardware read path outright (no external semantic
remains to drift once UTF reads the position register
itself).

`docs/UTF_ARCHITECTURAL_DISCIPLINE.md` Operating Rule 1
requires that any ADR introducing a new guarantee-path
dependency on external code not already accepted as platform
transport must address whether that code is acceptable, with
reasoning, or scope a UTF replacement. This ADR introduces
exactly such a dependency and the analysis was previously
absent; this section supplies it.

**The dependency.** audiofs's clock writer depends on these
specific FreeBSD `snd(4)` internal surfaces: the channel
buffer-pointer accessor (`xxxchannel_getptr()`), the sndbuf
accessor functions reachable from the pcm core, the
`chn_intr()` interrupt path on which the counter is read,
and the device-claim mechanism audiofs uses to take a PCM
endpoint (the latter shared with ADR 0002). These are
in-kernel implementation surfaces, not a documented stable
ABI. FreeBSD makes far weaker compatibility promises about
the pcm core's internal interfaces than about syscall or
documented driver(9) boundaries.

**Why this is a discipline concern, not just a quality
concern.** The failure modes in this ADR (a buggy
`getptr()`, a bogus codec pointer) treat snd(4) as
*possibly wrong today*. The discipline doc's risk framing is
broader: external code is a risk because its authors have
"their own goals, constraints, and future plans." The
load-bearing risk is therefore not only that a snd(4) driver
is buggy now, but that upstream FreeBSD may change the pcm
core's interrupt path or the buffer-pointer semantics in a
future release, with no driver being "buggy" by its own
standard. The `samples_written` semantic this ADR makes
load-bearing (frames clocked out, not frames queued) is
exactly the kind of property an upstream pcm-core refactor
could alter without tripping the monotonicity guard: a
semantic drift, not a monotonicity violation, would leave
the clock advancing smoothly but meaning something subtly
different. UTF's entire timing model rests on this counter.

**Posture taken.** Of the discipline doc's three postures
(Replace; Accept as platform transport; the bounded third),
this ADR places the snd(4) clock-read surface under **Accept
as platform transport, with a verification gate** rather
than Replace. Replace would mean UTF-owned audio hardware
drivers, which is categorically out of scope and not
warranted by the risk. Plain Accept is insufficient because
snd(4) internals are live, weakly-contracted code, unlike a
frozen legacy ABI. The accepted posture is therefore
conditional acceptance: the dependency is permitted, but its
acceptability is treated as falsifiable per FreeBSD version
rather than assumed permanent.

**Mitigation (binds Stage F.7).** The Stage F.7 verification
protocol (`audiofs/docs/F_VERIFICATION.md`,
`audiofs/test/f/f-verify.sh`) must include a snd(4)
semantic-drift check, not only a correctness check: against
each FreeBSD version PGSDF ships, verify that
`xxxchannel_getptr()` reports frames-clocked-out (not
frames-queued or another semantic), that the value is
monotonic under the documented interrupt cadence, and that
the sample-to-nanosecond relationship matches the negotiated
rate within a stated tolerance. A FreeBSD version bump that
has not passed this gate is, for UTF's purposes, an
unverified platform: audiofs may run but the clock-source
guarantee is not asserted until the gate passes. This makes
the dependency's acceptability a checked precondition of a
release rather than a standing assumption, which is the
operational form "conditional acceptance" has to take to be
real.

**Acknowledged concession.** This is a deliberate relaxation
of the discipline's preference for Replace, recorded
explicitly in the manner ADR 0004 records its "semasound
becomes load-bearing" concession. UTF does not control
snd(4); audiofs reads the most authoritative signal snd(4)
exposes, validates it defensively (section on failure
modes), and gates releases on its semantics holding. It
cannot lift snd(4) to UTF's specifiability standard, and
this ADR does not claim it does. There is an irony worth
stating plainly: the audiofs proposal argues OSS is
unacceptable partly on specifiability grounds, while this
replacement rests on snd(4) internals that are *less*
contractually stable than OSS's frozen legacy API. The
justification is not that snd(4) is more stable than OSS;
it is that snd(4) exposes the hardware sample position
(which OSS's app-facing model hides) and that the
verification gate, not the dependency's inherent stability,
is what carries the guarantee.

## Consequences

### What this enables

  - **Precision improvement on the canonical clock.** Other
    chronofs-aware consumers see the codec's actual position
    rather than userland's approximation of it. The
    difference is small in absolute terms but meaningful for
    AV-sync diagnostics.
  - **Stability of the clock region under userland load.**
    The kernel-side update cadence is hardware-driven; it is
    not affected by userland scheduling decisions, semaaud
    process priority, or competing CPU work.
  - **Decoupling of chronofs improvement work from Q2.**
    Chronofs work that depends on accurate clock semantics
    can proceed once this ADR is implemented (Stage F.4),
    without waiting for the larger audiofs design to settle.

### What this does not address

  - **The audiofs data path** (Q1). How audio bytes move
    between userland producers and the kernel substrate is
    a separate decision.
  - **The mixer location** (Q2). Whether audiofs sees
    individual streams or mixed output is a separate
    decision.
  - **The format model** (Q4). What sample formats audiofs
    accepts and whether it does conversion is a separate
    decision.
  - **The audio data publication regions.**
    `/var/run/sema/audio/state` and
    `/var/run/sema/audio/events` are subject to their own
    ADR work and are not part of this ADR's scope.

### Implementation cost

Small. The kernel module needs to register a callback that
runs in audio-interrupt context, reads
`xxxchannel_getptr()` for the active channel, and writes the
result to the mmapped clock region. The mmap setup mirrors
what semaaud's `ClockWriter.init()` does today, adapted for
kernel context. The atomic-store discipline (seq_cst on
`clock_valid`, aligned u64 store on `samples_written`)
transfers directly.

The interrupt-context constraint is real but well-bounded:
the work per interrupt is one buffer-pointer read and one
u64 store, both nanosecond-level operations. The clock
region is mapped into kernel virtual address space at
module init; per-interrupt work is pure-store with no
allocation.

### Failure modes worth naming

**audiofs is loaded but no audio device is open.** The
clock region exists with `clock_valid = 0`. Readers'
`isValid()` returns false. Events carry
`ts_audio_samples = null`. This is the same posture as
semaaud-running-without-stream today.

**audiofs is loaded; the codec returns a bogus pointer.**
A driver bug in `xxxchannel_getptr()` could cause the
position to go non-monotonic or stop advancing. The clock
region's contract is that `samples_written` is monotonic;
audiofs must validate the codec's pointer (compare against
the previous value, refuse to write a smaller one) and
log a diagnostic if the codec violates monotonicity. The
clock region itself stays consistent because audiofs is
the writer; the failure surfaces as "clock stops
advancing" rather than as "clock goes backward."

**Sample rate changes mid-stream.** Some hardware supports
runtime sample-rate changes (USB audio, in particular).
audiofs reflects the new rate in `sample_rate` and continues
the monotonic `samples_written` counter from where it was;
the change in the conversion ratio between samples and
nanoseconds is the consumer's responsibility to handle. This
matches the existing semaaud behaviour and the
`shared/CLOCK.md` specification.

**Module unload while a stream is active.** audiofs
guarantees that `clock_valid = 0` is written before any
mappings are torn down. Readers that check
`clock_valid` first (the documented pattern) see a stopped
clock rather than a stale-but-valid-looking one.

**Upstream snd(4) semantic drift across a FreeBSD version.**
Distinct from the bogus-pointer mode above: no driver is
buggy by its own standard, but a future FreeBSD release
changes what `xxxchannel_getptr()` reports or when the
`chn_intr()` path fires. A monotonicity-preserving but
semantically-shifted counter (for example, frames queued
instead of frames clocked out) would pass the
refuse-to-go-backward guard yet make the clock subtly
wrong, and every chronofs consumer would inherit the error
silently. This mode is not defended by a runtime check
because it is not detectable at runtime from inside a single
version; it is defended by the Stage F.7 per-version
semantic-drift gate described in Decision section 8. The
operational consequence: a FreeBSD version that has not
passed that gate is an unverified platform for the
clock-source guarantee, even if audiofs loads and runs.

## What this document is not

  - **A specification of the kernel implementation.** No
    function names, no struct layouts beyond what
    `shared/CLOCK.md` already specifies, no driver-attach
    sequence. Those belong in a follow-on
    `audiofs/docs/CLOCK_WRITER.md` (analogous to
    `inputfs/docs/STATE.md`), produced when audiofs's
    Stage F.0 work begins.
  - **A removal plan for semaaud's clock writer.** The
    redundant userland code path stays in place until
    Stage F.4 (Clock takeover) lands. Removal is its own
    commit, with its own verification.
  - **A schedule.** Stage F follows AD-2 and AD-9 per the
    BACKLOG priority list. This ADR records a decision; it
    does not commit a start date.
  - **An obligation to use kernel-side mixing or to expose
    individual-stream sample positions through the clock
    region.** The clock region exposes one counter for the
    device. Per-stream sample positions, if they exist,
    live in the audiofs state region (`/var/run/sema/audio/state`)
    governed by separate ADRs.
