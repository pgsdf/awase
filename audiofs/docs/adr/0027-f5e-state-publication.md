# 0027 F.5.e: state publication and observability

## Status

Accepted, 2026-06-04 (ratified same day as proposed, with
four operator amendments recorded inline: a hard constraint
on the audio-thread ring append (O(1) uncontended, no
allocation, no syscalls, no logging, no indirect calls); an
explicit per-target monotonic non-resetting seq guarantee
with detectable overflow; a liveness signal published every
cycle regardless of change; and the single-snapshot
projection rule making no surface independently
authoritative. Three further operator notes recorded:
`clients` is authoritative and any future "current stream"
is only ever a derived projection; any future control plane
must be strictly decoupled from state publication and must
not reuse the events ring for command acknowledgment; the
dump tool is strictly read-only, permanently).

Fifth sub-milestone of F.5 (semasound), scoped under ADR
0020. Depends on F.5.a (ADR 0021); lands after F.5.b-d (ADRs
0024-0026, all closed), whose surfaces and invariants it
extends: the policy surface tree begun in F.5.d grows here
into the full per-target and per-stream observability layout.

## Context

ADR 0020 scopes F.5.e as: per-stream and per-target state
publication (the `state.zig` concern) for consumers and
operators, plus a semasound inspect/dump tool in the pattern
of audiofs's `clock_dump` / `audiofs_events_dump`.

The parity reference is semaaud's surface tree under
`/tmp/draw/audio/<target>/`: identity, version, backend,
device, the four policy files (already realized in F.5.d
under `/var/run/sema/audio/<target>/`), capabilities, state,
control, control-capabilities, last-event, stream/current,
and stream/events. semaaud's events carry a sequence number,
a wall-clock timestamp, an audio-sample position, and a
session token read from the shared semadraw session file;
its `control` is a command socket (stop/flush/preempt) with
descriptive files alongside; its `stream/current` describes
THE active stream, a single-stream concept.

Three translation facts shape this design. First, a mixing
target has N streams, so `stream/current` has no faithful
meaning. Second, `control` is a command plane, not state, and
F.5.e's scope is state publication. Third, and load-bearing:
semasound's audio threads (the device output loop and the
null pacer) must never perform filesystem IO, a blocking
write on the mix path is an xrun generator, so the publication
mechanism must be structured around that prohibition rather
than bolted onto the loops that know the state.

## Decisions

### 1. Layout: the F.5.d tree grows; filenames are parity where meaning survives

Each target's directory `/var/run/sema/audio/<target>/`
gains: `identity`, `version`, `backend`, `device`,
`capabilities` (static, written once at startup), and
`state`, `clients`, `events`, `last-event` (dynamic). All
writes are atomic (write-temp-then-rename), the F.5.d
mechanism reused. Formats are line-oriented `key=value` (one
concern per line), matching the tree's existing texture.

  - `identity`: `semasound <target>`
  - `version`: the semasound version string (a new
    `SEMASOUND_VERSION` constant; this ADR sets it to
    `F.5.e`)
  - `backend`: `audiofs` | `discard`
  - `device`: `/dev/audiofs0` | `none`
  - `capabilities`: `rates=8000-48000`, `format=s16le`,
    `channels=1,2`, `mixing=true`, `election=true|false`
  - `state`: `status=idle|playing`, `clients=N`,
    `hw_rate=N`, `frames_written=N`, `duck=off|engaged`,
    `publish_seq=N`, `publish_ts=NS` (the liveness signal,
    rewritten every publisher cycle)
  - `clients`: one line per active client:
    `id=N label=L class=C rate=R target_rate=R2
    mode=passthrough|resampling override=0|1`
  - `events`, `last-event`: Decision 3.

Rationale. Filenames carry the parity; formats stay greppable
and tool-friendly. Static facts are written once; dynamic
facts have a single writer each (Decision 2).

Tradeoff. None of substance; JSON everywhere was rejected as
heavier than the consumers (grep, cat, the dump tool) need,
with `policy-state` remaining the one JSON surface (F.5.d
precedent).

### 2. `clients` replaces `stream/current`: the mixing divergence, recorded

`stream/current` is not written. A mixing target's streams
are enumerated in `clients`, one line per
admitted-and-not-reaped connection (the same "active"
definition election and group evaluation use). semaaud's
per-stream identity fields (label, class) appear per line;
uid/gid/origin/authenticated do not exist in semasound's
declaration-based identity (ADR 0026 Decision 1) and are
omitted until credential binding lands.

Rationale. Publishing a "current stream" on a mixer would be
a lie whenever N != 1. The honest translation enumerates.

Tradeoff. A recorded parity divergence; semaaud watchers that
read `stream/current` must read `clients` instead. The F.6
audit decides whether a single-client convenience alias is
worth providing (deferred, not built).

### 3. Events: in-memory rings, audio threads never touch the filesystem

Each target owns a fixed-capacity in-memory event ring
(latest 128 events) guarded by a short mutex. Producers
append in memory only: the accept thread records `admitted`,
`denied`, `preempted`, `fallback`, and `election` events; the
output threads record `reaped` (and nothing else) under the
same bounded-critical-section discipline as the existing
`snapshotActive` mutex. Each event carries `seq=` (per-target
monotonic), `ts=` (wall-clock ns), `frames=` (the target's
frames_written at event time, the audio-position parity
field), `kind=`, and a detail tail.

Audio-thread append constraint (operator amendment, HARD):
the ring append performed on an audio thread is O(1) under an
uncontended mutex with NO allocation, NO syscalls, NO
logging, and NO indirect calls; the event payload is copied
into a preallocated slot. Future edits may not expand this
critical section; if richer producer-side work is ever
needed, the sanctioned path is migration to an SPSC ring per
producer or per-thread preallocated slot buffers, not growth
of the locked region.

Seq guarantee (operator amendment): `seq` is monotonic
PER-TARGET and never resets across publisher cycles within a
runtime instance (it restarts only with the broker process).
The ring keeps the latest 128 events; on overflow the oldest
are dropped and the published `events` file therefore shows a
seq GAP, which is the defined, downstream-detectable overflow
signal: a consumer that sees nonconsecutive seq knows exactly
how many events it lost.

A dedicated PUBLISHER thread, one per broker, wakes at 1 Hz,
and each cycle takes ONE in-memory snapshot per target and
derives every dynamic surface from it: it drains new ring
entries into `events` (rewritten atomically, latest 128
lines), rewrites `last-event`, and rewrites `clients`,
skipping a write when that surface's content is unchanged,
EXCEPT `state`, which is rewritten EVERY cycle and carries
the liveness signal (operator amendment): `publish_seq=`
(incremented per cycle) and `publish_ts=` (wall-clock ns), so
a long-lived observer can always distinguish "no change" from
"publisher stalled" from "broker gone". The single-snapshot
rule (operator amendment) is normative: ALL surfaces are
projections of that one snapshot; no surface is authoritative
independently, and `clients` is the authoritative enumeration
of streams, any future "current stream" being only a derived
projection of it. The accept thread's existing policy-surface
writes are unchanged (an accept-thread file write delays at
most an admission, never audio). AUDIO THREADS PERFORM NO
FILESYSTEM IO, by construction: their only contribution is
the constrained in-memory ring append.

Rationale. This is the physics/semantics separation applied
to observability: the threads that pace audio donate
nanoseconds (a mutex-guarded append), and a thread that paces
nothing donates milliseconds (file IO). The 1 Hz cadence
bounds staleness at a second, which is observability-grade;
admission-path policy surfaces remain immediate as in F.5.d.

Tradeoff. State can lag reality by up to a second, and a
crash loses unflushed ring entries (acceptable: surfaces are
observability, not a journal). The session-token field of
semaaud's events is OMITTED, a recorded deferral: semasound
runs standalone today, and semadraw session integration is an
F.6-audit question, not a state-publication one.

### 4. `control` and `control-capabilities` are out of scope, recorded

Neither is written, and no control socket is built. semaaud's
control plane (stop/flush/preempt commands) existed to manage
single-stream contention from outside; in semasound,
preemption is policy (ADR 0026), admission is the socket
protocol, stop is process lifecycle (F.5.f supervision), and
flush has no mixing meaning. If F.6's parity audit finds a
consumer that needs a command plane, it gets its own decision
then.

Rationale. F.5.e is state publication; porting a command
plane under its flag would be scope creep wearing a parity
costume.

Tradeoff. A recorded parity gap until F.6 rules on it.

### 5. The dump tool: `semasound-dump`

A new executable in the semasound build: walks
`/var/run/sema/audio/`, prints every target's surfaces in a
readable block, and with `-f` polls `events` and streams new
lines (by seq) until interrupted. Read-only, no broker
dependency, works on a dead broker's last-published state
(itself diagnostic).

Rationale. The clock_dump / audiofs_events_dump pattern, as
scoped by ADR 0020; operators get one command instead of a
tree walk. The tool is strictly READ-ONLY, permanently
(operator note): it must never modify any surface, lest it
become a hidden secondary control plane.

### 6. Code shape and scope fences

`state.zig` owns the event ring type, the snapshot formatter,
and the publisher thread body; `target.zig` gains the ring
and static-surface descriptors; `policy_state.zig`'s atomic
writer is generalized and shared; `main.zig` records
admission-path events and spawns the publisher;
`output.zig`'s loops gain only the reap-event ring append;
`tools` gain semasound-dump (a Zig exe in build.zig, not a C
tool). NOT in scope: control plane (Decision 4), session
tokens (Decision 3), supervision integration (F.5.f), kqueue
or inotify-style push notification (consumers poll; the
events file's seq field makes polling cheap and exact).

## Closure criteria

  1. Startup creates each target's directory and writes the
     static surfaces (identity, version, backend, device,
     capabilities) with the specified contents.
  2. `state` and `clients` track reality within the
     publication cadence: a client admitted or reaped is
     reflected within 2 s, with correct label/class/mode
     fields and the active-set count matching the accept log.
  3. `events` records admitted/denied/preempted/fallback/
     election/reaped with per-target monotonic seq, wall-clock
     ts, and frames position; `last-event` equals the final
     `events` line.
  4. Event parity content spot-checks: a policy denial
     produces a `denied` event carrying label and class; an
     election produces an `election` event carrying the rate
     transition; a group preemption produces `preempted`
     events for each terminated client.
  5. Atomicity under churn: a tight cat loop on `state`,
     `clients`, and `events` during a connect/disconnect storm
     never observes an empty or torn file.
  6. Audio inertness: the full f5b_election, f5c_targets, and
     f5d_policy suites pass unchanged with the publisher
     running (counts identical, no new SET_FORMATs, no
     underflow regression in the playing lines).
  7. The 2-hour F.5.b soak criterion is spot-checked at
     reduced duration (15 min) with publication active: trim
     std and fill remain in the verified envelope (the
     publisher steals no audio-thread time).
  8. semasound-dump prints all targets' surfaces; `-f`
     follows events live across an admission and a denial.
  9. No fd/memory leak across publication cycles (the
     publisher's atomic writes leak nothing over a sustained
     churn run).
 10. Operator marks F.5.e `[x]`.
     VERIFIED 2026-06-04: operator marked PASS, noting that
     criterion 7's measured result supports the audio-thread
     prohibition rather than merely exercising it: publication
     was operationally inert from the audio perspective.

## References

  - ADR 0020: scope (state.zig concern; dump tool).
  - ADR 0026: the surface tree, atomic writer, and
    declaration-based identity this extends.
  - ADR 0007: the physics/semantics separation Decision 3
    applies to observability.
  - semaaud `surfaces.zig`, `state.zig`: the parity layout
    and event-metadata shape.

## Revision history

  - 2026-06-04: proposed. Six decisions: the F.5.d tree grows
    with parity filenames where meaning survives; `clients`
    replaces `stream/current` (mixing divergence, recorded);
    in-memory event rings with a 1 Hz publisher thread and an
    absolute prohibition on audio-thread filesystem IO;
    control plane out of scope (recorded gap for the F.6
    audit); semasound-dump; code shape and fences.
  - 2026-06-04: ratified with four operator amendments and
    three operator notes, recorded inline: the hard
    audio-thread append constraint (O(1) uncontended mutex,
    no allocation/syscalls/logging/indirect calls, no future
    critical-section growth; SPSC migration is the sanctioned
    path if richer producer work is ever needed); the
    per-target monotonic non-resetting seq guarantee with seq
    gaps as the defined detectable overflow signal; the
    every-cycle liveness signal in `state`
    (publish_seq/publish_ts) so observers distinguish
    quiescence from stall from death; the single-snapshot
    projection rule (no surface independently authoritative,
    `clients` the authoritative enumeration); control-plane
    decoupling constraint; dump tool read-only permanently.
  - 2026-06-04: implementation landed; criteria 1-9 bench-
    verified. f5e_state harness, all scripted cases: static
    surfaces exact for both targets; state/clients tracked an
    admission and a reap within 2 s with correct identity and
    mode fields; events carried admitted/reaped with strictly
    monotonic seq and last-event equal to the events tail;
    parity event content exact (denied with label+class, the
    election transition from=48000 to=44100, preempted on the
    peer target with the group); zero torn or empty reads in
    50 attempts against a connect storm; publish_seq advanced
    while idle (the liveness heartbeat); semasound-dump printed
    both targets' surfaces and followed a live admission with
    -f; fd count and RSS exactly stable. Criterion 6 (audio
    inertness): the full f5b_election, f5c_targets, and
    f5d_policy suites passed unchanged with the publisher
    running, every count identical. Criterion 7: a 15-minute
    drift soak under active publication held the verified
    F.5.b envelope (steady-state mean trim 995-1095 ppm onto
    the injected +1000, trim std 151-189 against the ~155
    reference, fill bounded 39-57%, no cross-bucket trend),
    the measured form of the audio-thread prohibition. One
    fix during verification: the Client identity accessors
    were initially placed between container fields (Zig
    forbids declarations there); relocated after all fields.
    One finding during verification, recorded for the
    operator's ruling: the soak harness initially produced NO
    TRACE because a lone 44.1k client is now elected natively
    under Stage 2 (passthrough, no resampler, estimator
    correctly idle), exposing the structural fact that
    bit-exact passthrough and rate correction are mutually
    exclusive; the soak was repaired with a 48k anchor opener
    so the drift client joins as a resampled overlap client
    (the originally verified configuration). The
    passthrough-drift tradeoff itself awaits the operator's
    documentation ruling. Remaining: criterion 10.
  - 2026-06-04: criterion 10 confirmed by the operator;
    F.5.e closed. The passthrough-drift ruling is recorded in
    ADR 0024's revision history (intentionally uncorrected;
    telemetry-only fill-trend reporting a potential future
    enhancement; automatic resampler insertion rejected).
    Remaining: F.5.f (supervision), then F.6 (semaaud
    retirement).
