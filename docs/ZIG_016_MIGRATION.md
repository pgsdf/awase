# Zig 0.15.2 to 0.16.0 Migration

Status: in progress. chronofs is green under the vendored 0.16.0 toolchain (exe
and full test suite), the first subproject carried all the way through, and the
reference implementation for the boundary architecture below.
Type: working notebook. It records per-class breaking-change detail and
per-component port status under the architecture the migration surfaced
(ADR shared 0001 and ADR shared 0002); it is not itself an architectural
decision record.

## Purpose

Awase pins a project-local Zig 0.16.0 toolchain (tools/bootstrap.sh, tools/zig,
sdk/zig/current). This notebook records the breaking changes encountered moving
the source tree from 0.15.2 to 0.16.0, the confirmed before/after for each, and
the per-component port status.

The toolchain upgrade itself was mechanical. The resulting breakage exposed a
recurring pattern of standard-library volatility (a stable local interface over a
volatile std surface), which led to the compatibility-boundary architecture
captured in ADR shared 0001. The concurrency and timing surface, where the
volatile replacement would inject an Io dependency rather than only change shape,
led to ADR shared 0002. The migration exposed those boundaries; it did not invent
them.

## Milestone: chronofs (reference implementation)

Chronofs is the first complete subproject migrated and benched under the vendored
Zig 0.16.0 toolchain. It serves as the reference implementation of ADR shared
0001 and ADR shared 0002. The migration validated the compatibility-boundary
approach: subsequent failures surfaced only in unconverted standard-library
surfaces and not within the converted boundary modules themselves. That is
architectural evidence, not merely project status.

## Methodology (read this first)

Lesson learned, the hard way, more than twice:

    Do not infer Zig 0.16 APIs from Awase source code.
    Do not infer Zig 0.16 APIs from Zig master or from web migration notes.
    The vendored stdlib (sdk/zig/current/lib/std) is the authoritative
    specification.

Surviving 0.15 code is not evidence of a 0.16 API (it is often 0.15 code whose
error was masked earlier in the same compilation unit), and online examples are
polluted by master snapshots and intermediate-snapshot posts. The workflow that
produced every correct fix in this migration, validated end to end by chronofs:

1. Build against the authoritative vendored toolchain.
2. Observe the actual failure (do not predict it).
3. Read the vendored stdlib for the real 0.16 shape.
4. Adjust the Awase-owned boundary, not the call sites scattered across the tree.
5. Repeat. Each cleared error tends to uncover the next, because the compiler
   stops at the first error per compilation unit.

chronofs validated this directly: after its first successful build, every
subsequent failure surfaced in an untouched std surface (a deeper file, a test
path, a transitive module), never inside a boundary abstraction that had already
been converted. That is the behaviour a working compatibility boundary should
produce, and the strongest evidence the architecture holds.

## Toolchain (landed)

- Vendored compiler: sdk/zig/current/zig (0.16.0, x86_64-freebsd), out of git,
  fetched by tools/bootstrap.sh, invoked via tools/zig. See commit 164060e.
- Root build.zig: a comptime guard rejects any compiler whose minor != 16, and
  routes all sub-build invocations through b.graph.zig_exe so no sub-build
  escapes to a system Zig.
- install.sh build_sub uses the vendored ./tools/zig, not a PATH-resolved zig.
  The dependency check reports the vendored toolchain rather than requiring a
  system zig. (The original symptom, "process has no member named Init", was
  install.sh building with the system zig that lacks the 0.16 process API.)
- Rule: no build step invokes bare `zig`; everything flows through ./tools/zig or
  b.graph.zig_exe. Never `sudo ./tools/zig build` (it poisons ~/.cache/zig
  ownership).

## The compatibility boundary (where the volatility is absorbed)

Awase code depends on Awase-owned interfaces; those depend on the volatile std
surfaces; never the reverse (ADR shared 0001). The modules that now own each
surface, all under shared/src/, aggregated by shared/src/compat.zig:

    compat.args    process arguments (Init.Minimal entrypoint, owned argv)
    compat.io      construction and lifetime of a local blocking std.Io context
    compat.fs      filesystem interaction, plus stdout/stderr console streams
    compat.sync    Mutex (atomic-backed, no Io handle)              [ADR 0002]
    compat.time    Duration and sleep (posix-backed, no Io handle)  [ADR 0002]
    posix_safe     raw posix read/write/sleep syscall surface       [AD-6]

shared/src/clock.zig is intentionally not behind compat.fs: it is a raw
descriptor and mmap subsystem (it owns posix.mmap/munmap directly), so it adapts
to the surviving posix.system primitives rather than taking on std.Io and an Io
handle. ClockReader.init and ClockWriter.init keep their signatures, so audiofs
and the other consumers are unaffected (ADR shared 0001/0002, posix route).

## Authoritative error inventory (0.16.0)

The first full build surfaced four classes (A through D). Clearing them, and then
carrying chronofs to green, uncovered three more (E, F, G) plus the concurrency
and timing rework and a set of smaller sub-surfaces, each of which had been
masked behind an earlier error. The complete picture:

Counts in the classes below are snapshots from the last full inventory pass and
are used for sizing only. Bench results take precedence over inventory counts;
treat any number as historical unless it has been re-grepped after the chronofs
work.

### Class A: std.heap.GeneralPurposeAllocator removed   [DONE, bench-confirmed]

GeneralPurposeAllocator was renamed to DebugAllocator in 0.14 (kept as a
deprecated alias), and the alias was removed in 0.16. The API is identical; the
variable name `gpa` is conventional and kept.

    Before: var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    After:  var gpa = std.heap.DebugAllocator(.{}){};

Applied as a tree-wide identifier rename.

### Class B: std.process argument API removed   [DONE]

argsAlloc/argsFree/argsWithAllocator are all removed in 0.16. The confirmed
replacement is the "juicy main" model (case 3 of the original three): start.zig
dispatches arguments to a tool whose entrypoint is

    pub fn main(init: std.process.Init.Minimal) !void

and the tool acquires its argv slice through the boundary,
`compat.args.alloc(gpa, init.args)`, rather than from a removed std function.
compat.args owns argv collection and exposes a random-access slice and a forward
iterator. 38 sites converted (36 argsAlloc/argsFree, 2 argsWithAllocator); the
two known-bad semasound mechanical-pass conversions were redone in this form.
The entrypoint stays Init.Minimal (not the full std.process.Init) so startup
infrastructure is not threaded through application code (ADR 0001, Decision 2,
Option B).

### Class C: Compile-step linking methods moved to the module   [DONE, bench-confirmed]

In 0.16, linkSystemLibrary and libc linkage live on the Module, not the Compile
step.

    Before: exe.linkSystemLibrary("pam");
    After:  exe.root_module.linkSystemLibrary("pam", .{});

    Before: exe.linkLibC();
    After:  exe.root_module.link_libc = true;

Sites: pgsd-sessiond/build.zig (13 conversions). semadraw/build.zig was already
0.16-correct.

### Class D: std.posix socket layer removed   [DIRECTION DECIDED, implementation pending]

The medium-level std.posix socket functions (socket, bind, listen, accept,
connect, shutdown, recv, sendmsg/recvmsg, socketpair) are removed; setsockopt and
poll survive, and the types survive (fd_t, socket_t, sockaddr, msghdr, iovec,
pollfd). cmsghdr is not top-level and is reached through posix.system for
SCM_RIGHTS in shm.zig.

Tree-wide exposure (counts taken before clearing A/B/C): posix.socket 34,
posix.connect 4, posix.listen 3, posix.bind 3, posix.accept 3, posix.shutdown 1,
posix.recv 1. Files: semadraw (client/connection, remote_connection, ipc/shm,
ipc/socket_server, ipc/tcp_server), semasound (main, tone_client).

Direction, now decided (it was the open question in the prior revision): an
Awase-owned socket shim, compat.posix, over the raw posix.system.* surface,
consistent with the boundary discipline and AD-6 (option 3). This is the
principal remaining closure criterion of ADR 0001 (criterion 3: socket boundary
implemented and all current socket consumers migrated). chronofs has no sockets,
so implementation waits for the socket-bearing subprojects (semadraw, semasound);
shm.zig SCM_RIGHTS is the hardest site.

### Class E: filesystem and I/O relocated under std.Io   [DONE for shared and chronofs; dominant surface]

The 0.16 "Writergate" rework removed std.fs.cwd/File/Dir and routed filesystem
and stream I/O through a std.Io handle. ~51 files tree-wide. Absorbed by two
boundary modules: compat.io owns construction of a local blocking std.Io
(std.Io.Threaded) from the tool's own allocator, and compat.fs owns the
filesystem verbs (createFile, openFile, writeAll, read, readToEndAlloc, getPos,
seekTo, close, Dir.access) plus stdout/stderr console streams. Console output
routes through posix_safe rather than the std.Io writer path, so the simplest
operation does not depend on the most volatile subsystem (ADR 0001, route A).
chrono_dump and shared/clock are converted; the remaining files convert per
subproject.

### Class F: std.posix.write removed   [DONE via posix_safe]

posix.write is removed (posix.read survives). Routed through posix_safe (AD-6),
which already shimmed safeRead/safeWrite over posix.system and now also backs
console output and sleep. No new module.

### Class G: std.ArrayList initialization change   [in-place idiom fix]

std.ArrayList is unmanaged in 0.16: `std.ArrayList(T){}` becomes `.empty`, and
deinit/append take an allocator. An in-place idiom correction, not a boundary
concern. Known sites: semadraw encoder.zig, sdcs_replay.zig.

### Concurrency and timing: std.Thread synchronization removed   [DONE for chronofs; ADR shared 0002]

std.Thread.Mutex, std.Thread.sleep, and std.Thread.Condition are removed; their
replacements (std.Io.Mutex, std.Io.sleep) take an Io handle. Awase does not
accept std.Io as the ownership model for synchronization and timing (a mutex is
not I/O), so these are owned by compat.sync (atomic-backed Mutex) and compat.time
(Duration plus sleep over posix nanosleep), both Io-free (ADR shared 0002).
std.Thread.spawn and join survive unchanged and are used directly; thread
lifecycle is not part of the boundary. Surface: Mutex 4 files, sleep 14 files,
Condition 0 (the one apparent match is a comment in semasound/src/ring.zig).
chronofs (stream.zig ring lock, chrono_dump and stream poll loops) is converted.

## Sub-surfaces discovered during chronofs (record so they are not rediscovered)

Smaller 0.16 changes that each surfaced only after a higher-level error cleared.
All confirmed against the vendored stdlib:

- std.fs.*Absolute removed: openFileAbsolute, createFileAbsolute,
  makeDirAbsolute. Use posix.system.open / posix.system.mkdir (clock.zig) or
  compat.fs.
- std.posix fd wrappers removed: open, close, ftruncate, fstat, mkdir, lseek all
  dropped from std.posix; only posix.system.* survives. posix.mmap and
  posix.munmap survive as wrappers (memory ops, not fd I/O), so clock.zig keeps
  them unchanged.
- Variadic open: posix.system.open is C-variadic, so a comptime_int mode literal
  is rejected ("must be casted to a fixed-size number type"). Pass
  @as(posix.mode_t, 0). A typed mode parameter passes fine.
- PROT is a packed struct(u32) of bool fields in 0.16, not a namespace of
  constants. Use struct literals: mmap prot is .{ .READ = true } or
  .{ .READ = true, .WRITE = true }, not posix.PROT.READ. MAP flags
  (.{ .TYPE = .SHARED }) were already in this form. SEEK remains a constants
  namespace (posix.SEEK.END).
- Dir.realpath became realPath(io, out_buffer) !usize: it takes an Io handle,
  resolves the dir itself (no sub_path), and returns the path length. In tests,
  build a local std.Io.Threaded for the handle and slice the buffer by the
  returned length.
- std.fs.max_path_bytes survives (re-export of std.Io.Dir.max_path_bytes), and
  std.fs.path.dirname survives (a string utility, not I/O). Both used unchanged.
- The two-clock.zig hazard: shared/src/clock.zig (defines ClockReader and
  ClockWriter) and chronofs/src/clock.zig (the Clock/MockClock wrapper that
  consumes them) are distinct and not interchangeable. They were once crossed
  during file application, which is why deliveries name them distinctly.

## Execution plan

1. Vendor toolchain, version guard, sub-build routing.                  [DONE]
2. Authoritative build and error inventory.                            [DONE]
3. Classes A, B, C.                                                     [DONE]
4. Compatibility-boundary architecture (ADR 0001) and the concurrency
   and timing boundary (ADR 0002).                                     [DONE, ratified]
5. Prove the boundary end to end on the smallest socket-free subproject:
   chronofs (compat.args, io, fs, sync, time, plus shared/clock).      [DONE, green]
6. Reconcile this notebook to the proven state.                        [this revision]
7. Migrate the remaining socket-free Zig units, smallest transitive closure
   first (the chronofs lesson: the useful unit is the smallest closure under the
   vendored toolchain, not the fewest files), each benched green before the next:
   a. semainput (libsemainput): self-contained (imports only std), surface is the
      Class G ArrayList idiom across four lists, validated by 11 unit tests. The
      cleanest remaining target. [DONE, green 2026-06-15]
   b. inputfs (inputdump): Class F (4 posix.write) and concurrency (3 sleep) in
      the tool itself, plus its transitive dependency shared/src/input.zig, which
      carries a large removed-surface count and converts with it.
      [DONE, production green 2026-06-15; input.zig test scaffolding is Phase 2,
      gated by shared's input_tests step]
   c. pgsd-sessiond.
8. Implement the Class D socket boundary (compat.posix over posix.system.*),
   closing ADR shared 0001 criterion 3. Inventory the real socket-bearing closure
   first; the hard case is descriptor passing (SCM_RIGHTS in shm.zig) and
   ancillary data, not basic socket creation. Do not begin this until the
   socket-free units above are exhausted.
9. Migrate the socket-bearing subprojects through compat.posix: semadraw (the
   largest remaining surface: Class D sockets, the encoder seek and backfill path,
   sdcs.zig validation, Class E breadth, Class G) and semasound.
10. Aggregate verification: full ./tools/zig build green plus subsystem benches.

Survey result (2026-06-15): audiofs is a C kernel module and associated C
tooling. It is not a Zig migration target and therefore has no Zig 0.16 stdlib
surface. Its relationship to the migration is limited to validation of the shared
clock-file format consumed by shared/src/clock.zig: the magic, version, and size
constants agree on both sides (the C side AUDIOFS_CLOCK_* in audiofs.c, the Zig
side CLOCK_* in shared/src/clock.zig), duplicated rather than generated, which is
AD-55 gen_constants territory. audiofs was removed from the migration sequence
and reclassified as a format-interop concern, beside the migration rather than
inside it. The F.4 clock-writer feature work is C and is not gated by this
migration.

Deferred refactor (post-migration, ratified 2026-06-15): the raw-posix file
helpers openCreateRdwr / openReadOnly / fileSize (and the readAllInto /
writeAllFrom loops in session.zig) are now file-local in shared/src/clock.zig,
shared/src/input.zig, and shared/src/session.zig, with small test fixtures over
them duplicated across the same test files. This duplication is deliberate: do
not mix migration work with refactoring. Once every consumer is converted and
green, lift these into a single shared module (working name shared/src/posixfile)
as a pure refactor with no semantic change, re-point the green consumers, and
re-bench. Defer until discovery is finished (audio.zig and any other consumers
may yet appear, and compat.posix may subsume part of the surface).

## Component status

The authoritative signal is a bench result, not a grep result. States:

    State        Meaning
    Green        Builds and benches successfully under vendored 0.16.0
    Converted    Migration changes applied but not yet re-benched
    Pending      Not yet migrated
    Blocked      Waiting on another class or an architectural decision

chronofs, semainput, and inputfs have been benched green. chronofs is the
end-to-end reference (compat.args, io, fs, sync, time, plus shared/clock);
semainput (libsemainput, benched green 2026-06-15, 11/11) is the second
independent validation, and a notably cheap one: its append and deinit sites were
already on the 0.16 unmanaged ArrayList form from the earlier gesture work, so
only the four .empty inits remained. inputfs (production, benched green
2026-06-15) is the third: shared/src/input.zig converted via the clock.zig
raw-posix route at scale (eight regions), and inputdump cleared a three-break
cascade (console writes to compat.fs.stdout/stderr, arg-slice param types to
const, and the removed std.time.nanoTimestamp to compat.time.nowMonotonic). No
new boundary category appeared in any of the three; the only ADR activity was a
scope clarification to 0002 (nowMonotonic). That is a useful signal that some
remaining subprojects may be closer to 0.16 than their raw surface counts
suggest. shared is now benched green end to end: cd shared && ../tools/zig build
test passes all targets (compat, clock, input, session). This closes Phase 2,
which began with the discovery that shared's test step had never been green:
chronofs imports clock and input as modules and skips their test blocks, so the
0.16 breaks in the test scaffolding (and, for session.zig, in production too)
went unseen until the test targets were built directly. The test scaffolding was
converted on the raw-posix idiom (file-local fixtures over openCreateRdwr /
openReadOnly / fileSize, with realPath(io) the lone std.Io call retained).
session.zig was a full conversion: its readToken / writeToken / mkdir ran on the
removed std.fs.*Absolute and std.Io.File paths, and its token generator on the
removed std.crypto.random (now FreeBSD arc4random_buf); nothing had caught it
because pgsd-sessiond, its production consumer, is still pending. audiofs is
absent from this table by design: it is C, not a Zig migration target (see the
survey note under the execution plan).

    Component        A alloc     B args      C link      E fs/io     F write     G list      concurrency   D sockets
    shared (compat)  n/a         n/a         n/a         Green       Green       n/a         Green         Pending
    shared/clock     n/a         n/a         n/a         Green       Green       n/a         Green         n/a
    shared/input     n/a         n/a         n/a         Green       n/a         n/a         n/a           n/a
    shared/session   n/a         n/a         n/a         Green       Green       n/a         n/a           n/a
    chronofs         Green       Green       n/a         Green       Green       n/a         Green         n/a
    semainput (lib)  n/a         n/a         n/a         n/a         n/a         Green       n/a           n/a
    inputfs tools    Green       Green       n/a         n/a         Green       n/a         Green         n/a
    semasound        n/a         Converted   n/a         Pending     Pending     n/a         Pending       Blocked
    semadraw         Converted   Converted   Converted   Pending     Pending     Pending     Pending       Blocked
    pgsd-sessiond    Converted   Converted   Converted   Pending     Pending     n/a         Pending       n/a

"n/a" means the component has no site in that class. The shared/* rows
(compat, clock, input, session) are now all green under cd shared &&
../tools/zig build test. semainput (libsemainput) is a pure-logic
library: its only 0.16 surface is the Class G ArrayList idiom, so every other
class is n/a. inputfs's tool (inputdump) has no std.fs of its own (E is n/a); its
Class E weight lived in the shared/input dependency, now converted.
"Blocked" in the D column means the subproject cannot reach green until the
compat.posix socket boundary is written (the direction is decided; only the
implementation, sequenced under these subprojects, remains). semadraw C was
0.16-correct before this pass and is marked Converted on that basis; it has not
been re-benched as a green subproject.
