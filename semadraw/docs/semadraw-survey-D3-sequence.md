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

The shared closure is the only place where both closures advance simultaneously,
so it is converted FIRST, before any production-only work, to prove the dual-green
model is functioning before the bulk begins (operator refinement, 2026-06-15).
Three shared files carry surface (the Phase 0 bench corrected the earlier
"protocol is clean" claim):

- **protocol.zig** (meta.intToEnum x2) -> std.enums.fromInt (orelse, not catch).
  Smallest of the three; a clean first canary.
- **connection.zig** (sockets x2) -> compat.posix. The highest-leverage file:
  shared, socket-bearing, both partitions.
- **sdcs.zig** (fs.File x4) -> **owned raw-posix route**. sdcs is the SDCS codec
  (format ownership), so its File usage is owned, not compat.fs.

Green across all three in `zig build test` is the first evidence both partitions
advance together. simd and inputfs_translate are clean (no conversion); they
confirm the test step builds.

**Milestone M1 - first `zig build test` advance (named, in its own right).**
protocol.zig and connection.zig are each rooted by a dedicated test target
(`ipc_protocol_tests`, `client_connection_tests`), so they are validatable BEFORE
any production-only file is touched. The earliest point the test step advances is
therefore the moment those two targets compile and their tests run green - this is
the first concrete demonstration of the union-of-closures rule and is treated as a
milestone, not merely a step. It is reached with zero production-only conversion.
sdcs.zig then completes the shared partition: when its test target is green, the
entire shared closure is migrated and `zig build test` is fully green on shared
surface while `zig build` (production exes) is still red - the expected,
intended intermediate state that proves the two closures are genuinely independent.

## Phase 2 - Production-only modules, dependency order (leaves -> daemon)

Established-route surface (compat.time, compat.args, sockets except SCM_RIGHTS,
sigaction, and the alias-corrected Class F write/open/close from the D2 canonical
table), converted leaf-first so each module benches in isolation where it has
tests before the daemon integrates them. Counts below reference the D2 canonical
per-file table (alias-corrected); they are not restated here to avoid drift:

1. Leaf backends: software, drm (+*Absolute, open, close), drawfs (write, open,
   close), backend/process (write x4, close x12 - the heaviest Class F file),
   evdev (open, close), app.zig. (compat.time throughout; drm *Absolute owned.)
2. Compositor: frame_scheduler (time+sleep), compositor (time+args), events
   (time + std.Io writer + stdout/pipe fd writes, close).
3. IPC servers: socket_server (sockets + 2 fs.cwd + write x2, close x5),
   tcp_server (sockets + write x2, close x11), surface_registry (close).
4. Client: remote_connection (sockets + write x2, close x2). (connection done in
   Phase 1.)
5. pty (args + write, open, close x4), term/main (milli x9; exe root already wired).
6. semadrawd LAST in this phase: it imports everything above, so it is the
   integration point. Convert its 2 nanoTimestamp + 1 getenv + 2 close, and the **2
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
  std.Io), as promised in D2. **Constraint (operator ruling):** do not force
  tooling onto the raw-posix route merely for consistency. Format owners (sdcs.zig,
  likely encoder.zig) are owned; the sdcs_* utilities are decided per-file with the
  actual open patterns in hand, and std.Io is the default where it reduces
  complexity and does not touch a persistence path.

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

   **Acceptance gate (operator ruling, 2026-06-15):** because shm.zig is
   production-only, SCM_RIGHTS is NOT accepted on compilation. Acceptance requires
   runtime validation that a descriptor actually transfers: a client receiving a
   live shared-memory fd from the daemon over the unix socket and using it. A green
   `zig build` is necessary but not sufficient. This is an acceptance criterion,
   not a caveat, and carries to the notebook as such.

**Phase 5 has two named steps, not one:**

- **5a - build conversion.** Convert shm.zig's sendmsg/recvmsg SCM_RIGHTS path on
  compat.posix and the owned CMSG arithmetic; reach green `zig build`.
- **5b - runtime fd-transfer validation (required, named).** On bare metal, start
  semadrawd, connect a client, and confirm a shared-memory descriptor passes from
  daemon to client and is usable (a mapping the client did not itself open). 5b is
  a distinct step with its own pass condition; SCM_RIGHTS is not accepted until 5b
  passes. If 5b is deferred, Phase 5 is INCOMPLETE regardless of `zig build` color.

## Phase 6 - Dual-green gate (plus the one thing green does not cover)

Migration compilation is complete only when both `zig build` and `zig build test`
are green. But dual-green does NOT validate fd-passing: shm.zig is outside the test
closure, so neither step exercises SCM_RIGHTS at runtime. The gate is therefore
stated as two distinct conditions, not one:

- **M2 - dual-green:** `zig build` and `zig build test` both green. Proves every
  compilation unit migrated and every test target passes.
- **M3 - SCM_RIGHTS runtime (Phase 5b):** the bare-metal fd-transfer bench passes.
  This is separate from M2 and is NOT implied by it. The migration is accepted only
  when BOTH M2 and M3 hold. A report of "semadraw green" that has not reached M3 is
  understating what remains, exactly the validation-honesty failure D1 warned about.

Per-phase, the defect-prone audit (D2 ledger 3) runs before each bench:

    grep -rnE 'posix\.system\.(close|unlink|rename|mkdir|shutdown|bind|listen|accept|kqueue|kevent)' src \
      | grep -vE '_ = posix\.system|defer _ = posix\.system|if \(posix\.system|= posix\.system|< 0'

Highest-density conversion sites (audit hardest): backend/process (write x4, close
x12), tcp_server (close x11), socket_server (sockets + write + close), and shm
(SCM_RIGHTS). connection.zig, protocol.zig, and sdcs.zig remain the shared canaries
throughout: their green in `zig build test` is the running signal that production
and test partitions advance together.

## What conversion does NOT touch

Per the ratified unit and route decisions: the five opt-in backends (default-off
stubs active), the stray src/backend/semadraw-build.zig (hygiene, not migration),
the manually-run unwired tests (inputfs_input as a test, bsdinput), and the 12
already-green shared/semainput dependency files. If a bench reports removed surface
from any of these, the walk has drifted from the ratified unit and it is a survey
bug, not a finding.

## Appendix A - Filesystem route table (file-by-file, reviewable before conversion)

Applies the ratified split: persistence and SDCS-format ownership -> owned
raw-posix idioms; tooling, diagnostics, and non-format output -> std.Io / compat.fs
where it reduces duplication. Classification is by the NATURE of each I/O site, not
by whether the enclosing program is a "tool": reading or writing the SDCS format is
ownership even inside a diagnostic tool. fd-level writes to stdout/pipes are owned
(the writeAllFd idiom already exists). Sites confirmed against the actual open
patterns in the tree.

    file                         site / purpose                     route
    sdcs.zig                     SDCS read/seek/stat/write (codec)   OWNED raw-posix (fd API)
    encoder.zig                  SDCS header/stream write            OWNED raw-posix
    tools/sdcs_make_*.zig (26)   createFile -> SDCS output artifact  OWNED (openCreateRdwr)
    tools/sdcs_dump.zig          openFile -> read SDCS to dump       OWNED (openReadOnly)
    tools/sdcs_test_malformed    open SDCS test inputs               OWNED (openReadOnly)
    tools/sdcs_fuzz.zig          SDCS corpus read/write              OWNED (raw-posix)
    tools/sdcs_replay.zig :1595  openFile in_path (.sdcs read)       OWNED (openReadOnly)
    tools/sdcs_replay.zig :2555  createFile out_path (.ppm write)    std.Io (non-format output)
    daemon/events.zig            File.stdout() + pipe fd write       OWNED (writeAllFd to fd)
    apps/graphics_demo/main.zig  STDOUT_FILENO fd write              OWNED (writeAllFd to fd)
    apps/term/main.zig :408      STDOUT_FILENO fd write (--help)     OWNED (writeAllFd to fd)

The single persistence-versus-tooling split inside one file is sdcs_replay: it reads
the SDCS input on the owned route and writes its PPM image output on the std.Io
route. This is exactly the per-file decision the operator reserved for "the actual
open patterns in front of you": the .sdcs read is format ownership, the .ppm write
is tool output, and they take different routes within the same tool. No other file
in the unit mixes the two. The sdcs_make_* createFile sites are owned because the
file they create IS the SDCS artifact; their internal mechanism (hand the fd to
encoder/writeHeader vs. write encoder bytes) is confirmed per-file at conversion but
does not change the route.
