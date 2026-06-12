# 0025 F.5.c: targets and routing

## Status

Accepted, 2026-06-04 (ratified same day as proposed, with two
operator amendments: election isolation elevated to an
explicit invariant under Decision 5; immutable routing
recorded under Decision 3 as an intentional constraint on
future fallback design, with transparent stream migration
explicitly not permitted). Closed, 2026-06-04: all ten
closure criteria verified on pgsd-bare-metal and the operator
marked F.5.c complete.

Third sub-milestone of F.5 (semasound), scoped under ADR
0020. Depends on F.5.a (ADR 0021, closed); proceeds after
F.5.b (ADR 0024, closed). F.5.d (policy) acts on the topology
and routing established here.

## Context

ADR 0020 scopes F.5.c as: the named-target topology and
per-target routing (the `surfaces.zig` concern): addressable
outputs, per-target stream assignment, the routing model a
client uses to say where its audio goes.

The parity reference is semaaud (retired by F.6 once F.5
reaches parity): a two-named-target topology (`default`,
`alt`), each target backed by its own OSS device fd, with
single-stream-per-target semantics, a policy engine that
preempts and falls back across targets, and a filesystem
state tree per target (`/tmp/draw/audio/<target>/...`).
semasound differs in one fundamental: it MIXES (ADR 0004), so
a target is not a single-stream slot but a mixing domain.
The filesystem state tree is F.5.e's concern, not F.5.c's;
what F.5.c owes is the topology and the routing semantics
underneath it.

Hardware reality: exactly one audiofs device exists today
(`/dev/audiofs0`, the internal DAC on pgsd-bare-metal). HDMI
(F.3.f) is deferred. semaaud's two-target topology rested on
two real OSS devices; F.5.c cannot.

The F.5.a/b spine being generalized: one client set, one
mixer/output thread writing one device fd, one elected rate
with the F.5.b session-opener election, one drift estimator,
one xrun consumer.

## Decisions

### 1. A target is a named, isolated mixing domain

A target owns a full instance of the F.5.a/b spine: a name,
a backing sink, its own client set, its own mixer and output
pacing, its own elected hardware rate and 0-to-1 election,
its own drift estimation, and its own xrun consumption. A
client belongs to exactly one target for the lifetime of its
connection. Nothing is shared between targets except the
process.

Rationale. Mixing domains are the mixer-architecture
translation of semaaud's per-target stream assignment, and
full isolation is what makes per-target reasoning (election,
drift, xruns, and later policy) identical to the
single-target reasoning F.5.a/b already verified, instance
by instance, rather than a new cross-coupled system.

Tradeoff. Per-target threads and state cost memory and one
more level of indirection in the broker. The rejected
alternative, one global mixer with per-target output fan-out,
is smaller but couples every target's pacing, election, and
failure behavior together, exactly what ADR 0007's reasoning
fences apart.

### 2. v1 topology: static, two targets, `default` and `null`

The topology is fixed at startup: `default`, backed by
`/dev/audiofs0` with the full F.5.b election and drift
machinery; and `null`, a timer-paced discard sink, fixed at
the canonical 48 kHz, no device, no election, no clock, no
xruns. Mixed frames routed to `null` are consumed at nominal
cadence and discarded.

Rationale. Routing, per-target assignment, per-target
isolation, and all of F.5.d (preemption, fallback routing
BETWEEN targets) need at least two targets to be exercised
at all. The second real device (HDMI, F.3.f) is deferred and
must not block F.5.c/d. A paced discard sink is the smallest
honest second target: it exercises every broker-side code
path (routing, admission, independent mixing, isolation)
while inventing no fake hardware. It also restores parity
with semaaud's two-named-target shape. When a second real
device lands, it slots into this topology as a third named
target (or replaces `null` in the configuration) with no
model change.

Tradeoff. The null sink is machinery that serves testing and
F.5.d rather than audio. The rejected alternative, a
one-target topology until HDMI exists, makes F.5.c
unverifiable beyond renaming the status quo and blocks F.5.d
entirely. Static configuration (no runtime target
add/remove) is deliberate: dynamic topology is a hotplug
concern, out of scope until a hotpluggable device exists.

### 3. Routing model: Hello v2 names the target; immutable per connection

The Hello header is extended (HELLO_VERSION 2) with a
NUL-padded 16-byte target name. An empty name routes to
`default`. An unknown name is rejected with STATUS_REJECTED
and a clear error line, broker surviving. A client's target
binding is immutable for the lifetime of the connection;
re-routing is a reconnect.

Rationale. Naming the target in the Hello keeps routing on
the existing versioned admission path (one place where a
connection's full disposition is decided: format, rate,
channels, target, election) and immutability extends the
F.5.b invariant, no live client observes a topology or rate
change, to routing. sndio's shape (binding constraint 6) is
the same: the target is named at open, not re-negotiated.

Tradeoff. Immutability means F.5.d's fallback routing (a
stream MOVING between targets on device failure or policy)
cannot be expressed as silent in-place re-binding; F.5.d
must define its mechanism against this invariant (e.g.
broker-initiated disconnect with a status the client can
react to, or policy-level admission redirection). That is
F.5.d's ADR to resolve; F.5.c deliberately does not
pre-build a stream-migration mechanism.

### 4. Hello v1 is rejected

Version 1 Hellos are rejected with the standard status and
error line. The tone client moves to v2.

Rationale. No deployed clients exist outside this tree;
carrying two admission shapes buys nothing and doubles the
admission-path test surface. The header was versioned
exactly so this bump is cheap.

Tradeoff. Nominal compatibility break, zero actual cost
today. If external clients ever exist, version acceptance
windows become a real decision; not now.

### 5. Per-target election, F.5.b semantics unchanged

The `default` target carries F.5.b's session-opener election
verbatim: active set, 0-to-1 transitions, and SET_FORMAT are
all per-target. The `null` target is exempt (fixed 48 kHz,
resample-on-admission for non-48k clients, no SET_FORMAT
path).

Rationale. Election is a property of a device-backed mixing
domain, and F.5.b verified it for exactly the spine a target
instantiates. Scoping the active set per target is the only
change, and it is forced by Decision 1's isolation.

Tradeoff. None of substance; a global active set would
couple election across targets, which is wrong on its face.

Invariant (operator amendment, 2026-06-04): election on any
target is a function of that target's client set alone. A
client routed to one target must never trigger, suppress, or
otherwise influence another target's election or SET_FORMAT
behavior. Criterion 8 verifies this directly.

### 6. Code shape

A `target.zig` owning the per-target spine (name, sink,
client set, mixer/output thread, election state, estimator
wiring); `main.zig` resolves the Hello's target name to a
target and admits into it; `protocol.zig` carries Hello v2.
The null sink is a sink variant inside target.zig, not a
parallel subsystem. No filesystem publication (F.5.e), no
policy hooks (F.5.d).

## Closure criteria

  1. Startup instantiates the static topology and logs it:
     `default` on /dev/audiofs0, `null` paced discard.
  2. A v2 client naming `default` (and one naming nothing)
     plays audibly; F.5.b behavior on `default` is unchanged,
     spot-checked: a lone 44.1k opener still elects 44100
     natively with bit-exact passthrough.
  3. A v2 client naming `null` is accepted, streams to
     completion at paced cadence (no premature EOF, no
     blocking stall), and nothing is audible.
  4. An unknown target name is rejected with a clear status;
     the broker survives.
  5. A v1 Hello is rejected cleanly.
  6. Concurrent clients on `default` and `null` mix in
     independent domains: `default` audio is clean while
     `null` streams, with no cross-target interference
     observable in audio or per-target counters.
  7. Stall and disconnect isolation hold across targets: a
     stalled or vanishing `null` client never perturbs
     `default` audio.
  8. Election independence: a `null` client held active
     across `default` session boundaries neither triggers
     nor suppresses any `default` SET_FORMAT (the F.5.b
     election harness passes unchanged with a persistent
     null-routed client in the background).
  9. No fd/memory leak across connect/disconnect and routing
     cycles spread over both targets.
 10. Operator marks F.5.c `[x]`.
     VERIFIED 2026-06-04: operator confirmed, including the
     aural components of criteria 2, 6, and 7 (default audible
     and correct; nothing audible from a null-routed client
     streaming concurrently, confirmed over a 180 s null
     stream under the full election suite; default continuous
     under a gapping null client).

## References

  - ADR 0020 (F.5 decomposition): scope and binding
    constraints, inherited not re-litigated.
  - ADR 0021 (F.5.a): the spine a target instantiates.
  - ADR 0024 (F.5.b): election and lifecycle invariants
    carried per-target; the immutability precedent Decision 3
    extends.
  - ADR 0004 / 0007: single-writer broker; semantics in
    userland; sndio as reference shape.
  - semaaud `surfaces.zig` and Roadmap: the parity reference
    for the named-target topology.

## Revision history

  - 2026-06-04: proposed. Six decisions: target as isolated
    mixing domain; static two-target topology (`default`,
    `null` paced discard); Hello v2 target naming with
    per-connection immutability; v1 rejected; per-target
    F.5.b election; target.zig code shape with F.5.d/e scope
    fences.
  - 2026-06-04: ratified with two operator amendments,
    recorded inline: the election-isolation property is an
    explicit invariant (Decision 5), and immutable routing is
    an intentional constraint on future fallback design with
    transparent stream migration not permitted (Decision 3).
    Implementation proceeds: topology first, fallback
    semantics later, no speculative migration machinery.
  - 2026-06-04: implementation landed and bench-verified
    (f5c_targets harness, all scripted cases): topology logged
    (default -> /dev/audiofs0, null -> paced discard); routing
    by name and by default both play, with the F.5.b spot-check
    unchanged (lone 44.1k opener elected natively, hw=44100
    passthrough); null routing accepted, timer-paced (a 3 s
    client takes wall time, not zero), silent, and SET_FORMAT-
    free; unknown target and v1 hello both rejected cleanly
    with broker survival; concurrent default+null mixed in
    independent domains (one client each per domain counters);
    broker survived a gapping null client during default
    playback; fd count and RSS exactly stable across mixed-
    target cycles. The Decision 5 election-isolation INVARIANT
    was verified in both forms: scripted (two default session
    boundaries under a persistent null client produced exactly
    the baseline two SET_FORMATs) and strong (the full F.5.b
    election suite passed unchanged, every case and count
    identical, with a 180 s null-routed client held alive
    across every session boundary). Aural components of
    criteria 2, 6, and 7 (default tone audible, only the
    default tone audible during concurrent null streaming,
    default tone continuous under a gapping null client) are
    subject to operator confirmation at the criterion 10 mark.
  - 2026-06-04: criterion 10 confirmed by the operator,
    including the aural components of criteria 2, 6, and 7.
    F.5.c closed. Next: F.5.d (policy), which acts on this
    topology under the Decision 3 constraint (no transparent
    stream migration) and the Decision 5 invariant.
  - 2026-06-04: cross-reference. The Stage 2 native election
    means a lone hardware-rate client is passthrough and
    therefore intentionally uncorrected for clock drift; the
    operator ruling and full tradeoff text are recorded in
    ADR 0024's revision history. Automatic resampler
    insertion remains rejected under this ADR's immutability
    invariant.
