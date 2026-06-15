# Semadraw migration survey - Deliverable 3: migration sequence

Status: For ratification. Last survey-phase artifact; conversion begins only after
this is signed off. Derived entirely from the D2 census (removed-surface usage),
not from socket counts.
Date: 2026-06-15
Routes: all ratified - filesystem persistence/tooling split; kqueue/kevent ->
raw posix.system; std.io -> direct std.Io.Writer.fixed (no boundary).

## Baseline reality

Semadraw does not build under 0.16 today: it carries 41 fs.cwd, 38 compat.time
symbols, 15 socket verbs, and the rest of the census surface, all removed. There
is no green baseline to preserve, unlike a re-bench. The compiler stops at the
first error per compilation unit, and an exe links only when its whole closure is
converted. So the sequence is ordered to maximize *early, independent validation*
rather than to keep an already-green tree green:

- The five test targets (`zig build test`) root sdcs, simd, inputfs_translate,
  protocol, connection. Converting those files lets the test step validate them
  before any exe links.
- Isolated `zig test src/X.zig` validates a single file with tests.
- The exes (semadrawd, 31 tools, apps) link only once their full closure converts.

## Phase 0 - Module compat-wiring pass (build.zig, one reviewable change)

The semadraw-specific precondition D1 surfaced: compat is wired per-module, and
~15 modules plus one test target and one exe need it. An unused module import is
not an error, so all wiring lands in one build.zig change ahead of any conversion.
This phase does not make the tree build (removed surface is still present); it is
the structural precondition, ratified and benched as its own diff so a wiring
error is never entangled with a conversion error.

Modules to wire with compat (census shows compat.time/args/posix surface in their
file closure):

    semadraw (app.zig: time)            compositor (time+args)
    software (time)                     frame_scheduler (time)
    drm (time)                          events (time + std.io writer)
    drawfs (time)                       ipc_socket (sockets + fs.cwd)
    backend_process (time)              ipc_tcp (sockets)
    pty (args)                          ipc_shm (sockets + time)
    connection (sockets)                remote_connection (sockets)

Targets to wire with compat:

    client_connection_tests (test)  - connection.zig sockets; the D1 gap, fixed here
    sdcs_test_malformed (exe)       - fs.cwd, if routed through compat.fs

Files needing NO compat (raw-posix / std.Io only): inputfs_input (close, kqueue,
*Absolute -> posix.system), and any file whose only fs work routes to owned
raw-posix rather than compat.fs (settled per-file in Phase 3).

Bench: `zig build` must still fail only on removed surface, not on module
resolution. No "no module named compat" errors is the Phase 0 pass condition.

### Phase 0 verification artifact (permanent record)

After the wiring diff lands, a verification artifact is generated *from* the
post-wiring build.zig (parsed, not hand-written, so the record cannot drift from
the file): every module that now imports compat and every exe/test target that
wires compat, emitted as an observed list, plus the module-resolution bench
result. This makes the closing of the semasound-style wiring gap an intentional,
recorded act rather than an incidental side effect, and gives a later reader a
fixed point to check the wiring against. The bench for this phase is narrow by
design: it proves module resolution (no "no module named compat"), not
conversion, because no source has changed yet.

## Phase 1 - Shared-partition canaries (validated by `zig build test`)

Convert the two shared files that carry surface, so the test step exercises them
before any exe links:

- **connection.zig** (sockets x2) -> compat.posix. The highest-leverage file:
  shared, socket-bearing, both partitions. Green here in `zig build test` is the
  first signal both partitions advance together.
- **sdcs.zig** (fs.File x4) -> filesystem route. sdcs is the SDCS codec (format
  ownership) and shared, so its File usage goes on the **owned raw-posix route**,
  not compat.fs. Validated by the sdcs test target.

protocol, simd, inputfs_translate are clean (no conversion); they confirm the test
step builds.

## Phase 2 - Production-only modules, dependency order (leaves -> daemon)

Established-route surface (compat.time, compat.args, sockets except SCM_RIGHTS,
sigaction), converted leaf-first so each module benches in isolation where it has
tests before the daemon integrates them:

1. Leaf backends: software, drm (+*Absolute), drawfs, backend/process, app.zig.
   (compat.time; drm also two *Absolute on the owned route.)
2. Compositor: frame_scheduler (time+sleep), compositor (time+args), events
   (time + std.io writer).
3. IPC servers: socket_server (7 verbs + 2 fs.cwd), tcp_server (4 verbs).
4. Client: remote_connection (2 verbs). (connection already done in Phase 1.)
5. pty (args), term/main (milli x9; exe root already wired).
6. semadrawd LAST in this phase: it imports everything above, so it is the
   integration point. Convert its 2 nanoTimestamp + 1 getenv, and the **2
   sigaction sites** (handler_fn fn(c_int) -> fn(posix.SIG); the semasound
   signature class, checked per handler not assumed).

## Phase 3 - Filesystem surface on ratified routes

- **Owned raw-posix (persistence/format):** sdcs.zig (done Phase 1), encoder.zig
  (fs.File), socket_server fs.cwd, sdcs_fuzz (9 fs.cwd, fuzz corpus IO), and the
  format-writing tools.
- **Tooling/std.Io (diagnostic/asset generation):** the 26 sdcs_make_* tools each
  write one asset file (1 fs.cwd each) - a single near-identical pattern,
  converted as a scripted batch and spot-benched, not 26 hand edits. sdcs_dump,
  sdcs_replay (fs.File via its LimitedFileReader), graphics_demo, term/main.
- A per-file fs route table accompanies this phase (which files raw-posix vs
  std.Io), as promised in D2.

## Phase 4 - New-surface sites (bounded)

- **kqueue/kevent:** inputfs_input.zig only (3) -> posix.system.kqueue/kevent
  (Kevent type survives). One file, production-only, no compat dependency.
- **std.io writers:** events.zig (1), gesture_inspect.zig (2) ->
  std.Io.Writer.fixed(buf), getWritten -> buffered(). Three sites, mechanical.

## Phase 5 - shm.zig SCM_RIGHTS (LAST, by design)

shm.zig is sequenced last for three reasons:

1. **It is the most delicate compat.posix consumer.** Its 2 verbs are sendmsg/
   recvmsg carrying ancillary data (fd passing) over the surviving msghdr, with
   the CMSG arithmetic locally owned via @cImport. Leaving it last means the
   boundary's behavior is already proven on the simpler socket sites (connection,
   socket_server, tcp_server) before the fd-passing path is converted.
2. **It also carries timing surface** (1 nanoTimestamp), wired in Phase 0, so the
   final shm pass is purely the SCM_RIGHTS work, not mixed concerns.
3. **Validation-path honesty:** shm is reached only by semadrawd (production,
   build-path only) - it is NOT in the `zig build test` closure. So a green
   `zig build test` proves nothing about SCM_RIGHTS. The fd-passing path rests on
   `zig build` plus a runtime bench on bare metal (a client receiving a shared-
   memory fd from the daemon). D3 states this explicitly so the eventual green
   claim is honest about what each step proves: the test step covers connection/
   sdcs/protocol; the SCM_RIGHTS path is build-plus-runtime only.

## Phase 6 - Dual-green gate

Migration is complete only when both `zig build` and `zig build test` are green.
Per-phase, the defect-prone audit (D2 ledger 3) runs before each bench:

    grep -rnE 'posix\.system\.(close|unlink|rename|mkdir|shutdown|bind|listen|accept|kqueue|kevent)' src \
      | grep -vE '_ = posix\.system|defer _ = posix\.system|if \(posix\.system|= posix\.system|< 0'

Highest-density conversion sites (audit hardest): socket_server (7 verbs + 2
fs.cwd) and shm (SCM_RIGHTS). connection.zig and sdcs.zig remain the shared
canaries throughout: their green in `zig build test` is the running signal that
production and test partitions advance together.

## What conversion does NOT touch

Per the ratified unit and route decisions: the five opt-in backends (default-off
stubs active), the stray src/backend/semadraw-build.zig (hygiene, not migration),
the manually-run unwired tests (inputfs_input as a test, bsdinput), and the 12
already-green shared/semainput dependency files. If a bench reports removed surface
from any of these, the walk has drifted from the ratified unit and it is a survey
bug, not a finding.
