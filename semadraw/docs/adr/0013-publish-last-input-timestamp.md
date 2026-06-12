# ADR 0013: Publish last_input_ts_ns for idle detection (D-11)

## Status

Accepted 2026-06-09 (operator-ratified in session). This ADR is D-11.
It exposes the idle signal that SM-2 (pgsd-sessiond ADR 0010 D5) and
SM-3 (ADR 0009) consume: the per-session policy agent computes idle from
it and drives the blank-and-lock and suspend timeline. Small and
independent of D-10. The publication mechanism (D1, request/reply rather
than a shared region, on the AD-34 grounds) and the deferred opcode
assignments (D5) are ratified.

## Context

semadrawd already maintains `last_input_ts_ns` (semadrawd.zig:219): the
chronofs-ns timestamp of the most recent input event, updated on every
raw inputfs event in the main loop (semadrawd.zig:1144). It is not
exposed to clients today, so no idle agent can read it.

Two facts constrain the design:

  - The consumer is the per-session idle agent, which may run unprivileged
    (ADR 0010 leaves it as a thin per-session daemon or folded into
    pgsd-sessiond). The inputfs state-region mmap is stale for non-root
    readers (the AD-34 bug; semadrawd.zig:264, events.zig:319), so the
    idle value must not be published through that mmap path.
  - semadrawd already serves request/reply queries (`hello_reply`,
    `output_info_reply`) over the client socket. A socket round-trip is
    always fresh and privilege-independent.

## Decision

### D1: publish by request/reply, not by a shared region

Add an `idle_query` client message and an `idle_reply`, mirroring the
existing `output_info_reply` pattern. semadrawd answers from the
`last_input_ts_ns` it already holds in memory. This deliberately avoids
a shared/mmap region: the consumer may be non-root, and the inputfs
state-region mmap exhibits the AD-34 staleness bug for non-root readers,
whereas a socket reply is served fresh by the daemon regardless of the
caller's uid. `idle_reply` returns the daemon's current value of
`last_input_ts_ns` at the time the query is processed; no caching is
performed. Expected consumers poll infrequently, on the order of
seconds, making the request/reply overhead negligible and leaving the
daemon no extra work between polls; higher-rate polling is permitted,
merely unnecessary.

### D2: payload and clock domain

The `idle_reply` payload consists solely of `last_input_ts_ns`, a u64 in
chronofs ns, the same domain inputfs stamps events in. The consumer reads chronofs now
itself and computes `idle = chronofs_now - last_input_ts_ns`. Because
chronofs is the same clock service inputfs stamped the event from, the
subtraction is valid; chronofs is also the clock the consumer uses for
its own idle timeline, so no second clock source is introduced. The daemon does not return its own now, which would require
adding a chronofs reader to semadrawd; keeping the value to what
semadrawd already holds keeps D-11 small. Neither path touches the
AD-34-affected inputfs state mmap: the timestamp comes over the socket,
the now comes from chronofs.

### D3: the zero sentinel stays in the consumer

`last_input_ts_ns` is 0 until the first input (its init at
semadrawd.zig:415). A reply value of 0 is therefore a defined part of
the contract: it indicates that no input has been observed since
semadrawd startup. The consumer treats 0 as that case and measures idle
from session start, which the per-session agent knows, rather than
subtracting from 0. semadrawd's init is unchanged.
(Alternative considered: initialize to chronofs now at startup to remove
the sentinel; deferred, as it would add a clock read to semadrawd for no
consumer-visible benefit.)

### D4: coverage, all input classes already count

The D-11 requirement is that the timestamp update on every input class,
not only the gesture path. It already does: `drain()` appends every raw
inputfs event to the side-channel before typed dispatch, with no class
filter (inputfs_input.zig:274-287), and the main loop updates
`last_input_ts_ns` from each such event (semadrawd.zig:1143-1144). The
update is driven by the raw stream, so keyboard, pointer, touch, and pen
all advance it; its place in the code next to the gesture forwarder is
incidental. No code change is needed for coverage; the bench confirms it
on hardware.

Scope: the signal reflects local inputfs-sourced input, which is the
correct presence signal for a local lock. Remote or injected input that
does not pass through the inputfs drain is out of scope and would need
separate handling if it ever exists. A raw zero-delta motion event also
counts as activity (any device report is activity); revisit only if
spurious events prove a problem in practice.

### D5: protocol additions

New client message `idle_query`, new reply `idle_reply` (in the reply
range alongside `hello_reply` and `output_info_reply`). Numeric
assignments are generated via the protocol pipeline
(`shared/protocol_constants.json`, regenerated into `protocol.zig`),
after the D-7 and D-10 reservations. An invalid or malformed `idle_query` message is answered with
`error_reply`. The query is unrestricted: the idle timestamp is
low-sensitivity, so no authorization gate is imposed; it can be
restricted later if a reason emerges. The value is the single global
last-input timestamp; per-session idle is a future refinement if
multi-session support ever lands.

## Alternatives considered

  - Publishing `last_input_ts_ns` directly from inputfs, the component
    that originates the signal, rather than from semadrawd. Rejected for
    D-11: inputfs's published state lives in the AD-34-affected mmap
    region, which is exactly the non-root staleness this ADR avoids, and
    D-11 is intentionally minimal. The consequence is that semadrawd
    becomes the canonical idle-information service despite not
    originating the signal. If further consumers appear later (session
    manager, power daemon, diagnostics tools), relocating the
    authoritative publication to inputfs behind a fresh, non-mmap
    interface is a reasonable future refinement; it is out of scope here
    and would not change this query/reply contract for existing
    consumers.
  - Returning `(last_input_ts_ns, now)` so the consumer needs no clock
    access of its own. Rejected to keep semadrawd free of a chronofs
    reader (D2); the consumer already reads chronofs for its
    timeline.
  - Initializing `last_input_ts_ns` to chronofs now at startup to remove
    the zero sentinel. Deferred (D3); it adds a clock read to semadrawd
    for no consumer-visible benefit.

## Implementation (under D-11, after ratification)

  - add `idle_query` and `idle_reply` to `shared/protocol_constants.json`
    and regenerate.
  - semadrawd: handle `idle_query` by replying with `last_input_ts_ns`,
    mirroring the `output_info_reply` handler.
  - bench (pgsd-bare-metal): confirm a freshly started daemon returns 0
    from `idle_query` before any input is observed, exercising the D3
    sentinel contract directly; then issue `idle_query` repeatedly and
    confirm the returned value advances after keyboard input, after
    pointer motion and clicks, and after touch input (each class
    independently); confirm the derived idle grows while idle and resets
    on any input; confirm a non-root caller receives fresh values (no
    AD-34 staleness), which is the reason for the socket mechanism.

## Consequences

  - SM-2 and SM-3 gain the idle signal they depend on, computed without
    touching the AD-34-affected mmap.
  - D-11 stays small: one query handler, one reply message, no new
    region, no new clock reader in semadrawd, no change to input
    handling.
  - The consumer owns the clock read and the zero-sentinel handling,
    which it is already positioned to do.

## Risks

  - An input source that bypassed the inputfs drain would not advance the
    timestamp. None exists today; noted and scoped out (D4).
  - The consumer must read chronofs in the same domain; since chronofs is
    the clock inputfs stamped from, this holds, but a consumer that read
    a different clock would miscompute idle. The contract names chronofs
    explicitly (D2).
  - A single global timestamp does not distinguish sessions; acceptable
    for the current single-session bare-metal target, deferred otherwise
    (D5).
