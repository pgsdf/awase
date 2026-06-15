# Semadraw migration survey - Deliverable 2: stdlib census and ledgers

Status: For ratification. Promotes boundary-exposure and risk-class to
authoritative (every member checked against the vendored stdlib, not a
known-removed list). Carries the D1 reachability / validation-path / compat-wiring
tags forward.
Date: 2026-06-15
Scope: 74 semadraw-owned files in the default unit. The 12 shared/semainput
dependency files (compat/*, input, clock, session, posix_safe, libsemainput) are
already benched green in prior milestones and are census-exempt.

## Family census (verified against vendored stdlib)

Driven by actual usage (every `std.X.Y` token across the unit was tallied, then
each checked against sdk/zig/current/lib/std), not a preconceived list.

### Removed or relocated (migration work)

    Symbol                       Uses  Status / route
    std.fs.cwd                    41   removed -> std.Io.Dir / compat.fs / raw-posix (route TBD)
    std.fs.File                   13   removed from fs.zig -> std.Io.File (Io.zig:45) (route TBD)
    std.fs.openFileAbsolute        2   removed -> raw-posix or compat.fs
    std.fs.createFileAbsolute      1   removed -> raw-posix or compat.fs
    std.time.nanoTimestamp        20   removed -> compat.time.nowMonotonic
    std.time.milliTimestamp       11   removed -> compat.time (ms)
    std.Thread.sleep               7   removed -> compat.time.sleep
    std.posix socket verbs        15   removed -> compat.posix (per ADR 0003)
    std.posix.getenv               4   removed -> compat.args.getenv (ADR 0001 amendment)
    std.posix.close                3   removed -> posix.system.close
    std.posix.kqueue               1   removed (Kevent TYPE survives) -> posix.system.kqueue  [NEW]
    std.posix.kevent               2   removed -> posix.system.kevent                          [NEW]
    std.io.fixedBufferStream       3   removed -> std.Io.Writer.fixed (RESOLVED below)          [NEW]
    std.io.limitedReader           0   comment-only in sdcs_replay; no real call site
    std.meta.intToEnum             2   removed -> std.enums.fromInt (orelse, not catch)        [BENCH-FOUND]
    ArrayList(T){} init            4   Class G -> .empty (encoder 1, sdcs_replay 3)            [BENCH-FOUND]

### Signature change (same symbol, changed shape)

    sigaction (semadrawd.zig, 2 sites)  handler_fn fn(c_int) -> fn(posix.SIG) callconv(.c)
    The semasound Sigaction class. Must be checked per handler, not assumed.

### Verified already-correct (no work)

    std.heap.DebugAllocator   34   GeneralPurposeAllocator removed; semadraw already on
                                   the 0.16 DebugAllocator form (heap.zig:20).
    std.process.Init          33   live 0.16 entrypoint.
    std.process.exit          13   survives (process.zig:854).
    std.c.setsid/execve/environ/_errno   survive as libc externs (c.zig).
    std.posix POLL/fd_t/uid_t/winsize/timeval/timespec/Kevent/pollfd   types/constants survive.
    std.posix.read / poll     survive.
    std.mem.* / std.math.* / std.fmt.* / std.testing.* / std.log.* / std.debug.* /
    std.unicode.* / std.meta.* / std.atomic.* / std.mem.splitScalar   stable.

The two families a Class D (socket-only) inventory would have missed: kqueue/kevent
and the std.io reader overhaul. Both are bounded (see ledger 1).

### Census methodology correction (Phase 0 bench feedback)

The Phase 0 bench found two surfaces this census missed, both from token-extraction
blind spots, recorded so the same gaps are not repeated:

1. **Construction forms are invisible to a `std.X.Y` token grep.** `ArrayList(T){}`
   has no `.member` after the type, so the Class G init change was never tallied.
   Fix: the census must grep container construction forms explicitly
   (`ArrayList(...)\{\}`, `(...).init`, `= .\{\}`) alongside the member tokens.
2. **Do not rubber-stamp a family as stable.** std.meta.* was assumed stable;
   std.meta.intToEnum is removed (-> std.enums.fromInt). Every member found must be
   checked against the vendored stdlib, including families that "look stable."

A third lesson, from verifying the above: a `pub fn NAME` grep returns false
"MISSING" for `pub inline fn` and `pub const` re-export forms. readInt/writeInt
(pub inline fn) and parseFloat (pub const re-export) briefly looked removed and are
not. A "MISSING" result is verified by checking declaration form before it is
believed, the same bench-is-authority discipline applied to absence as to presence.

## Per-file census (boundary-exposed files; carry-forward tags)

Reach = production-only (P) / shared (S). Val = build (b) / both (B). Wiring =
does the file's MODULE wire compat today (modules, not exes, are the unit of
wiring in semadraw; see D1).

    File                          Reach Val  Removed surface (counts)              Module wiring
    client/connection.zig          S    B    sockets(2)                            connection: MISSING
    sdcs.zig                       S    B    fs.File(4)                            sdcs: MISSING (route TBD)
    ipc/socket_server.zig          P    b    fs.cwd(2) sockets(7)                  socket_server: MISSING
    ipc/tcp_server.zig             P    b    sockets(4)                            tcp_server: MISSING
    ipc/shm.zig                    P    b    nano(1) sockets(2,SCM_RIGHTS)         shm: MISSING
    client/remote_connection.zig   P    b    sockets(2)                            remote_connection: MISSING
    daemon/semadrawd.zig           P    b    nano(2) getenv(1) sigaction(2)        semadrawd EXE: wired
    compositor/compositor.zig      P    b    nano(3) getenv(2)                     compositor: MISSING
    compositor/frame_scheduler.zig P    b    nano(5) sleep(4)                      frame_scheduler: MISSING
    daemon/events.zig              P    b    nano(1) fs.File(2) io.reader(1)       events: MISSING
    backend/drawfs.zig             P    b    nano(2)                               drawfs: MISSING
    backend/drm.zig                P    b    nano(2) *Absolute(2)                  drm: MISSING
    backend/software.zig           P    b    nano(2)                               software: MISSING
    backend/process.zig            P    b    milli(2) sleep(1)                     backend_process: MISSING
    backend/inputfs_input.zig      P    b    close(3) kqueue/kevent(3) *Abs(1)     (raw-posix; no compat needed)
    app.zig                        P    b    nano(2) sleep(1)                      semadraw: MISSING
    apps/term/main.zig             P    b    milli(9) fs.File(1)                   semadraw_term EXE: wired
    apps/term/pty.zig              P    b    getenv(1)                             pty: MISSING
    encoder.zig                    P    b    fs.File(1)                            semadraw: MISSING (route TBD)
    tools/sdcs_replay.zig          P    b    fs.cwd(2) fs.File(2)                  sdcs_replay EXE: wired
    tools/gesture_inspect.zig      P    b    io.reader(2)                          gesture_inspect EXE: wired
    tools/idle_probe.zig           P    b    sleep(1)                              idle_probe EXE: wired
    tools/sdcs_dump.zig            P    b    fs.cwd(1)                             sdcs_dump EXE: wired
    tools/sdcs_fuzz.zig            P    b    fs.cwd(9)                             sdcs_fuzz EXE: wired
    tools/sdcs_test_malformed.zig  P    b    fs.cwd(2)                             sdcs_test_malformed EXE: MISSING
    tools/sdcs_make_*.zig (26)     P    b    fs.cwd(1 each)                        each EXE: wired
    apps/graphics_demo/main.zig    P    b    fs.File(1)                            semadraw_demo EXE: wired

simd.zig and backend/inputfs_translate.zig (shared) carry no removed surface.
ipc/protocol.zig (shared) was wrongly listed clean in the first census pass; the
Phase 0 bench found 2 std.meta.intToEnum sites in it. The shared partition
therefore has THREE files with work: connection.zig (sockets), sdcs.zig (fs.File),
protocol.zig (meta.intToEnum). All three gate `zig build test`.

## The three ledgers

### Ledger 1 - Removed APIs (route to boundary or owned raw-posix)

- **Sockets (15 verbs, ADR 0003 established):** socket_server(7), tcp_server(4),
  shm(2), connection(2), remote_connection(2). Route compat.posix. shm.zig is
  SCM_RIGHTS (sendmsg/recvmsg over surviving msghdr); sequenced LAST.
- **compat.time (38):** nanoTimestamp(20) + milliTimestamp(11) + Thread.sleep(7),
  across app, backends, compositor, frame_scheduler, events, semadrawd, process,
  idle_probe. Established route.
- **compat.args.getenv (4):** pty, compositor(2), semadrawd. Established route
  (ADR 0001 amendment).
- **posix.system.close (3):** inputfs_input. Established.
- **Filesystem (57): fs.cwd(41) + fs.File(13) + *Absolute(3).** The dominant
  surface. fs.cwd is concentrated in the sdcs_make_* tools (1 each, near-identical
  write-a-file pattern: scriptable batch) plus sdcs_fuzz(9). fs.File spans sdcs
  (shared), encoder, events, sdcs_replay, term/main, graphics_demo. ROUTE DECISION
  below.
- **kqueue/kevent (3), inputfs_input only [NEW]:** Kevent type survives; verbs
  removed. ROUTE DECISION below.
- **std.io writers (3) [NEW]:** events(1), gesture_inspect(2). In-memory
  fixed-buffer writers for string formatting; no OS surface. sdcs_replay's two
  apparent hits are comment-only (its real surface is fs.File). ROUTE RESOLVED below.

### Ledger 2 - Signature changes

- **sigaction in semadrawd.zig (2):** the handler_fn fn(c_int) -> fn(posix.SIG)
  change. Same fix as semasound handleSignal. Shadowed behind sockets until
  semadrawd compiles through; check both sites.

### Ledger 3 - Defect-prone sites (pre-conversion audit, prepared now)

After conversion, status-returning raw calls must discard/bind their return (the
semasound close()-return defect class). Standing grep, run per file before each
bench:

    grep -rnE 'posix\.system\.(close|unlink|rename|mkdir|shutdown|bind|listen|accept|kqueue|kevent)' src \
      | grep -vE '_ = posix\.system|defer _ = posix\.system|if \(posix\.system|= posix\.system|< 0'

Highest-density conversion sites (most raw calls introduced at once) are
socket_server (7 verbs + 2 cwd) and shm (SCM_RIGHTS); audit those hardest.

## Three route decisions for ratification (new surfaces)

1. **Filesystem (fs.cwd / fs.File / *Absolute).** Recommend the semasound rule:
   persistence and file-format paths -> owned raw-posix (openReadOnly/
   openCreateRdwr idioms); tooling/diagnostic traversal -> std.Io / compat.fs.
   Open sub-question: **sdcs.zig fs.File** is the SDCS codec (format ownership) and
   is shared (both partitions). It reads/writes SDCS files, so it likely belongs on
   the owned raw-posix route, not compat.fs. The sdcs_make_* tools write asset
   files (tooling) and could go either way; raw-posix keeps them off a compat
   dependency, std.Io keeps the helper-duplication down. I will bring a per-file
   fs route table in Deliverable 3; the principle to ratify now is the
   persistence-vs-tooling split.

2. **kqueue/kevent.** Recommend raw posix.system.kqueue/kevent (the Kevent type
   survives at posix.*), Class-F-shaped, file-local in inputfs_input.zig. One file,
   production-only, no compat dependency. Not architectural; same character as the
   other removed-verb-to-posix.system ports.

3. **std.io overhaul (fixedBufferStream) - RESOLVED, ratified 2026-06-15.**
   Researched against the vendored std.Io: the three real sites (events,
   gesture_inspect x2) are in-memory fixed-buffer writers for string formatting,
   touching no OS surface. Route: direct `std.Io.Writer.fixed(buf)`, with
   `w.buffered()` replacing the old `stream.getWritten()`; `w.writeAll`/`w.print`
   are unchanged. No compat boundary: the boundary absorbs churning OS surface, and
   these are pure in-memory adapters; the new Reader/Writer is the going-forward std
   API, embraced directly per the same principle as the dump's std.Io.Dir. The
   sdcs_replay limitedReader references are comment-only; no limitedReader route is
   needed.

## Sequencing (proposed, for Deliverable 3 detail)

1. Establish per-module compat wiring (build.zig). ~15 modules need compat added:
   semadraw, software, drm, drawfs, backend_process, compositor, frame_scheduler,
   events, ipc_socket, ipc_tcp, ipc_shm, connection, remote_connection, pty, plus
   the client_connection_tests test target and the sdcs_test_malformed exe. This is
   the wiring work D1 surfaced; do it as one reviewable build.zig pass.
2. Convert the established-route surface (compat.time, compat.args, sockets except
   SCM_RIGHTS, close, sigaction) module by module in dependency order: leaf backends
   and compositor, then ipc socket/tcp servers, then client connection/remote, then
   semadrawd.
3. Convert the filesystem surface on the ratified fs routes (tools batch is
   scriptable).
4. Convert kqueue/kevent (inputfs_input) and the std.io reader sites on their
   ratified routes.
5. shm.zig SCM_RIGHTS last.
6. Drive both `zig build` and `zig build test` green. connection.zig (shared) and
   sdcs.zig (shared) are the canaries: green in both steps means both partitions
   advance together.
