# Awase daemon behaviour under dependency absence

Status: Stated, 2026-05-05. Updated 2026-06-05 for the post-F.6
stack: subjects are now `semasound`, `semadrawd`, and
`pgsd-sessiond`; the clock writer is the audiofs kernel module
(F.4, ADR 0018); restart is owned by s6 supervision (AD-20)
while rc.d retains boot ordering; semaaud and semainputd are
retired. The posture doctrine itself is unchanged.

This document states what Awase userspace daemons do when their
substrate dependencies are not yet present at startup. It applies
uniformly to `semasound`, `semadrawd`, `pgsd-sessiond`, and any
future Awase daemon that depends on substrate files, kernel
modules, or other Awase daemons. It does not apply to the kernel
itself, whose absence is an unrecoverable
configuration error, not a runtime condition.

This ADR was prompted by AD-12 (Service lifecycle) and specifically
by the symptom recorded in BACKLOG.md as "Bug 4": semadrawd reaching
"session 1 started" while doing no useful work because inputfs was
not actually delivering events. The symptom is the worst possible
behaviour under dependency absence and this ADR explicitly
disqualifies it.

## Context

Awase daemons exist in a dependency graph. The shape was captured in
the BACKLOG.md AD-12 entry; the relevant edges for this discussion:

```
inputfs.ko, audiofs.ko, drawfs.ko
                 (kernel modules, loaded by their rc.d
                  loader scripts; audiofs publishes
                  /var/run/sema/clock from the kernel, F.4)
   |
   v
semasound        (sole writer to /dev/audiofs0; mixing broker)
   |
   v
semadrawd        (reads the clock, accepts client connections,
   |              consumes inputfs events via shared region,
   v              presents via /dev/draw)
pgsd-sessiond    (semadraw client; graphical login)
```

Each daemon can start before its dependencies are ready in three
realistic scenarios:

1. **Boot-time race.** rc.d declares ordering with `REQUIRE:` lines
   but does not wait for a dependency to be functionally ready
   before starting the next service. inputfs's rc.d script returns
   success when the kernel module is loaded; the substrate's
   in-memory state is not yet populated when semadrawd starts.

2. **Operator-driven asymmetry.** An operator stops one daemon
   without stopping its dependents, then restarts the dependents.
   `service semadraw restart` after `service semasound stop` is a
   plausible diagnostic move that produces this state.

3. **Dependency crash and rc.d restart.** A dependency daemon
   crashes; rc.d may or may not restart it depending on
   configuration; meanwhile dependent daemons continue running
   without the dependency they were started against.

The substrate dependencies themselves are runtime-detectable: every
Awase substrate is a published file (state region, event ring, focus
region, clock region, surface registry). The dependent daemon can
check whether the file exists, whether it has the expected magic
bytes, and whether it is being updated. The question this ADR
resolves is what the daemon does after that check.

## Three possible postures

The BACKLOG.md AD-12.5 sub-stage entry names three options. This ADR
restates and evaluates them.

### Posture 1: Retry with backoff, indefinite

The daemon polls for the dependency at startup, sleeps if absent,
retries periodically. The daemon process stays alive throughout.
External observers see the process running but the daemon does not
accept clients or perform its primary function until the dependency
appears.

**Pros:**

- Single long-running process is friendly to monitoring tools that
  track PIDs.
- No restart loop, no rc.d work, no SIGCHLD churn.
- Once the dependency appears, transition to fully-operational is
  immediate; no process startup overhead.

**Cons:**

- An operator running `service X status` or `ps` sees the daemon
  as running. An operator running `pkill -USR1` to nudge it sees a
  reaction. None of those signals communicate "I am alive but
  waiting." The daemon looks like it is working.
- This is exactly the Bug 4 shape: the process is alive, the socket
  may be bound, clients can connect, and nothing useful happens
  because the substrate dependency is not actually serving data.
- Indefinite retry hides the underlying problem. If a dependency
  is permanently missing (operator forgot to start it, kernel module
  unload-and-not-reloaded), the daemon never escalates the
  condition; it just sits there forever.

### Posture 2: Exit cleanly, let supervision restart

The daemon checks dependencies at startup, exits with a specific
code (e.g. 75 = `EX_TEMPFAIL` from `sysexits.h`) if any dependency
is absent. rc.d's restart policy brings it back up later. The
process is short-lived during the dependency-absent window.

**Pros:**

- External observers see the daemon repeatedly start and exit. PID
  changes on every check. `service X status` correctly reports the
  daemon as not running between attempts.
- Each restart re-runs the full startup path, picking up changes
  to the dependency state immediately.
- Operators see a real signal in `dmesg` or `/var/log/messages`:
  "semadrawd: clock region not present, exiting (rc.d will retry)".
  The condition is visible and named.

**Cons:**

- rc.d's retry policy is not configurable per-service in a clean
  way on FreeBSD. The default behaviour after a clean exit is no
  retry at all; the operator must configure a respawn loop, which
  shifts complexity to rc.d configuration.
- Process churn is real. If the dependency is genuinely flapping,
  rapid restart loops can produce CPU and log pressure.
- Existing client connections are lost on every restart. For
  semadrawd in particular, this is operator-visible: the
  compositor surface goes away and comes back, semadraw-term
  loses its connection.

### Posture 3: Stay running in clearly-marked degraded mode

The daemon checks dependencies at startup. If any are absent, it
proceeds with reduced functionality, refuses operations that
require the missing dependency, and advertises its state.

**Pros:**

- Single long-running process; client connections that don't need
  the missing dependency continue working.
- The "advertise state" piece is what distinguishes this from
  Posture 1: external observers can tell the daemon is degraded by
  reading its substrate file (a header field, a status flag) or
  receiving an explicit error response when they request a
  feature that depends on the missing dependency.
- Allows the daemon to remain available for monitoring, status
  queries, and partial functionality.

**Cons:**

- Each daemon must implement degraded-mode logic and the operator-
  visible advertising. This is more code than Posture 1 or 2.
- The "feature available?" check must be threaded through every
  client-facing operation that could be affected. Easy to forget
  one and reproduce Bug 4 silently.
- Defining "degraded but functional" requires deciding which
  operations are independent of which dependencies. For semadrawd,
  this is non-trivial: most operations either need the clock or
  don't, but partial-clock degraded behaviour (e.g. clock present
  but stale) doesn't fit neatly into either category.

## The principle from architectural discipline

`AWASE_ARCHITECTURAL_DISCIPLINE.md` commits Awase to determinism and
stability as central guarantees. The daemons are part of the
guarantee path: a recording made when semadrawd was running against
inputfs should replay against a future inputfs and produce the
same result. Anything that produces silent variance in this is
hostile to the discipline.

Posture 1 (silent retry) produces the most variance. Whether the
daemon is functionally serving clients depends on whether its
dependency happened to be present at the moment the client
connected, and the client cannot reliably tell. This makes
recordings non-deterministic against future runs of the same
binaries. **Posture 1 is incompatible with the discipline for
the substrate-publishing daemons.**

Posture 2 (exit and restart) produces variance in process identity
across the dependency-absent window but produces deterministic
behaviour from each individual process incarnation: either the
process started with all dependencies present and worked, or it
exited before serving any client. Recordings against a successful
incarnation are reproducible. **Posture 2 is compatible with the
discipline but expensive on rc.d configuration and operator
experience.**

Posture 3 (degraded mode with advertising) produces deterministic
behaviour if and only if the advertising is correctly implemented:
clients query the daemon's state and either choose to proceed
against degraded functionality or wait. Recordings against the
degraded path can include the degraded-state response, making
them reproducible. **Posture 3 is compatible with the discipline
provided the advertising is rigorous.**

inputfs already implements Posture 3 for the compositor focus file:
the kthread retries reading `/var/run/sema/input/focus`,
publishes events with `session_id = 0` while the cache is invalid,
and starts publishing real session IDs once the focus file appears.
The behaviour is documented at `docs/FAILURE_MODES.md` "Focus file
absent (compositor not running)". This is functional Posture 3 done
correctly: the substrate continues working at reduced fidelity, the
reduced state is observable in the published events themselves, and
the recovery is automatic.

## Decision

Awase daemons implement **Posture 3 (degraded mode with rigorous
advertising)** as the primary policy, with **Posture 2 (exit and
restart)** reserved for unrecoverable configuration errors that an
operator must address.

The distinction:

- **Substrate dependency absent at startup, may become present**:
  Posture 3. The daemon starts, marks itself degraded, retries the
  dependency check, transitions to fully-operational when the
  dependency appears. Examples: semadrawd starting before inputfs
  has loaded, semadrawd starting before the audiofs module has
  published the clock.

- **Configuration error or hard platform failure**: Posture 2.
  The daemon logs the error, exits with `EX_TEMPFAIL`, lets s6
  supervision restart it (with the AD-20 flap protection bounding
  a persistent failure). Examples: `/dev/audiofs0` open fails for
  semasound (module not loaded and the run script's defensive
  kldload also failed), socket bind fails because another
  instance is running, the daemon's own configuration file is
  malformed.

The line between them is **whether the missing dependency is
expected to become present without operator action**. A substrate
dependency from a sibling Awase daemon is expected to appear soon
(rc.d will start it); a hard platform dependency is not.

### Required mechanism for Posture 3

Every Awase daemon implementing Posture 3 must:

1. **Check dependencies at startup**, before binding any sockets
   or accepting clients. Record whether each dependency is present
   and ready.

2. **Bind sockets and start serving regardless**. Clients can
   connect. Operations that do not require the missing dependency
   succeed normally.

3. **Reject operations that require the missing dependency** with
   a structured error response. The error must name the missing
   dependency by its substrate path (e.g. "clock region not
   present at /var/run/sema/clock"). Clients can decide whether to
   wait or proceed without the feature.

4. **Advertise the degraded state** in a place clients can read
   without making a request. For substrate-publishing daemons,
   this means a header field in the published file. For the
   compositor (semadrawd), this means an event broadcast to all
   connected clients on transition into and out of degraded mode.

5. **Retry the dependency check** on a fixed schedule (1 second,
   adjustable). When the dependency appears, transition to
   fully-operational, broadcast the state change, accept previously-
   rejected operations.

6. **Log every state transition** with a clearly-distinguishable
   message: `daemon: degraded mode entered, missing: clock region`,
   `daemon: degraded mode exited, all dependencies satisfied`. The
   log lines are how an operator running `dmesg` or `tail -f
   /var/log/messages` discovers the daemon's actual state.

7. **Document the degraded-mode behaviour** in
   `docs/FAILURE_MODES.md` with the standard four-section format
   (Trigger, Signal, Response, Recovery). The documentation closes
   the loop: an operator seeing the log line can find the
   documented response and recovery without reading source.

### What Posture 3 explicitly does NOT include

- **Silent retry without advertising**. This is Posture 1 and is
  forbidden. Bug 4 was Posture 1 done by accident; this ADR
  forbids it deliberately.

- **Indefinite retry with no escalation**. After a configurable
  threshold (default 60 seconds without dependency appearing), the
  daemon must log a warning at higher severity. This is operator
  discoverability, not behaviour change.

- **Lying about dependency state**. If a daemon advertises itself
  as fully-operational while in fact a dependency is absent, that
  is a bug regardless of whether anything ever notices. The
  primary defect Bug 4 surfaces is this kind of lie.

## Per-daemon application

The general policy translates to specific behaviours per Awase
daemon:

### semasound

Hard dependency: `/dev/audiofs0` (the audiofs kernel module).
Posture 2: exit if the device cannot be opened; s6 restarts with
flap protection. The AD-20 run script reduces the window by
defensively loading the module (`kldstat -q -n audiofs.ko ||
kldload audiofs`) before exec, and the audiofs rc.d loader
(REQUIRE: FILESYSTEMS) normally has it loaded long before
supervision starts.

No soft dependencies on other Awase daemons. semasound is at the
bottom of the userland stack; nothing it needs is produced by
semadrawd or pgsd-sessiond.

The audio clock is not semasound's concern: the audiofs kernel
module writes `/var/run/sema/clock` (F.4, ADR 0018) from the
interrupt path, and it publishes whether or not the broker is
running. A dead broker therefore stops mixing, not time.

(The OSS-era predecessor `semaaud`, whose `/dev/dsp` Posture 2
narrative this section replaced, was retired under F.6, ADR
0029; the historical narrative lives in git and the ADR record.)

### semadrawd

Soft dependencies:
- `/var/run/sema/clock` (written by the audiofs kernel module,
  F.4/ADR 0018), for chronofs-driven frame scheduling.
- inputfs substrate (`/var/run/sema/input/state`,
  `/var/run/sema/input/events`), for input event consumption.

Posture 3 for both. semadrawd should:
- Bind its socket regardless of dependency state.
- Accept client connections regardless.
- If clock region is absent: frame scheduling falls back to
  monotonic-clock-based timing. Clients can render and present.
  Recording fidelity is reduced (the chronofs determinism
  guarantee does not hold) and this MUST be advertised in the
  surface registry header.
- If inputfs substrate is absent: input events are not delivered
  to clients. Clients can render but cannot interact with their
  surfaces. The daemon advertises this in its `hello` response to
  new clients and broadcasts a state event to existing clients.

Hard dependency: socket bind. Posture 2. If the socket cannot be
bound (another instance running, permission denied), exit with a
clear error.

### semainputd (retired)

semainputd was retired by the AD-2a Phase 3 deletion sweep
(2026-05-08); its Posture 1 legacy behaviour is no longer present
in the tree. This section is retained as the pointer: the
retirement record is in `BACKLOG-history.md` and the semainput
ADRs.

### Future Awase daemons

Any future Awase daemon implementing soft substrate dependencies
applies Posture 3 by default. Hard platform dependencies apply
Posture 2 by default. Departures from these defaults must be
justified in a per-daemon ADR.

## Consequences

### Positive

- **Bug 4 cannot recur with this policy correctly implemented.** A
  daemon in degraded mode advertises that fact to its clients; a
  client that needs the missing functionality can either wait or
  surface the degraded state to the operator. Silent reach-into-
  but-do-nothing is structurally prevented.

- **Operator diagnostics improve.** Every state transition is
  logged. Every degraded mode is documented. The tooling to
  inspect daemon state (substrate file headers, `service status`,
  `dmesg`) all give consistent answers.

- **Recording determinism is preserved.** Recorded sessions
  include any degraded-state events, which clients respond to
  deterministically. Replay against a future system reproduces the
  degraded transitions and recovery as recorded.

- **rc.d configuration stays simple.** Daemons do not need
  respawn-on-clean-exit machinery for substrate dependency
  absence. Only the hard-failure path uses Posture 2, which rc.d
  already handles correctly.

### Negative

- **Each daemon must implement the advertising machinery.** The
  state header, the structured error responses, the broadcast
  events, the documented behaviours. This is real engineering
  work not currently present in any Awase daemon other than
  inputfs's focus-file retry.

- **The advertising must be threaded through every operation.**
  Forgetting to check "is the clock available?" before a frame-
  scheduling operation reproduces Bug 4 silently. Code review and
  testing must cover this. A general "feature availability" type
  in shared code is the right abstraction; per-daemon ad-hoc
  checks are not.

- **Some operations cannot be cleanly degraded.** A frame-
  scheduling call when the clock is absent could either fall back
  to monotonic time (loses determinism), reject the operation
  (forces the client to handle the rejection), or block until the
  clock appears (loses responsiveness). The choice is made per-
  operation in the daemon's design, not by this ADR. This ADR
  requires that whichever choice is made, it be documented and
  consistent.

- **The 60-second escalation threshold is a guess.** It may need
  per-daemon tuning. Operators running benchmarks or stress tests
  will see warnings during legitimate slow-startup paths. The
  threshold is configurable via daemon command-line flag; the
  default is just a default.

### Neutral

- **The boundary between "soft" and "hard" dependencies is
  judgemental.** `/dev/audiofs0` is hard for semasound because
  there is no fallback; if the operator wants audio, they need
  the audiofs module. inputfs is
  soft for semadrawd because rendering can proceed without input.
  Future daemons may have dependencies that don't fit cleanly into
  either category; the ADR provides a default and requires
  justification for departures.

## Implementation outlook

This ADR is a policy statement; it does not produce code on its
own. Implementation lands as part of AD-12.6 (bare-metal
verification), AD-2 Phase 3 (semainputd retirement), and any
future daemon work.

The first concrete implementation work this ADR enables:

1. **semadrawd degraded-mode advertising** for absent inputfs
   substrate. Adds a state field to the `hello` response and a
   broadcast event for state transitions. Client-side handling
   (in semadraw-term and any future Awase clients) prints a clear
   message: "semadrawd reports input substrate not available; key
   and pointer events will not arrive until inputfs is loaded."
   This closes the loop on Bug 4.

2. **chronofs degraded-mode handling** for an absent audio clock
   (written by the audiofs kernel module since F.4).
   Falls back to monotonic time, advertises the fallback in the
   surface registry, broadcasts the transition. Documented in
   `chronofs/docs/...` (location TBD).

3. **Reusable feature-availability type in `shared/`**. A small
   structured value `{name: []const u8, available: bool, reason:
   ?[]const u8}` that all daemons can use to advertise per-feature
   state in a uniform format. Enables generic client tooling to
   surface degraded modes without per-daemon parsing.

These are not commitments to date; they are sketches of where the
policy lands. Tracking happens in BACKLOG.md sub-stage entries when
work begins.

## References

- `docs/AWASE_ARCHITECTURAL_DISCIPLINE.md`, the principle this ADR
  derives from.
- `docs/FAILURE_MODES.md`, where per-daemon degraded behaviours
  are documented as they land.
- `BACKLOG.md` AD-12, the lifecycle work this ADR is part of.
- `BACKLOG.md` AD-12.5, the entry pointing at this ADR.
- `inputfs/docs/adr/0012-stage-d-scope.md`, inputfs's existing
  Posture 3 implementation for the focus file, the precedent for
  this ADR's general policy.
