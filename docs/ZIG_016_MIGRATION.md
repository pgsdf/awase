# Zig 0.15.2 to 0.16.0 Migration

Status: in progress, nearly complete. chronofs, semainput, inputfs, semasound,
all of shared, the semadraw daemon, and pgsd-sessiond are benched green under the
vendored 0.16.0 toolchain. The only remaining work is the semadraw standalone
tools and the two example apps (mechanical Class E/F/G), off the daemon's
critical path. chronofs was the first subproject carried all the way through and
remains the reference implementation for the boundary architecture below.
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

### Survey completeness: enumerate the removed family, not the symbol in focus

semasound re-taught this three times in one subproject. A hand-maintained
removed-surface inventory missed symbols that were not part of the original
migration classes, and each surfaced only after a deeper blocker cleared:

- std.time.milliTimestamp, removed alongside nanoTimestamp; the survey grepped
  only nanoTimestamp. Route: compat.time.nowMonotonic divided to milliseconds.
- std.posix.getenv, removed and not a named class. Route: compat.args.getenv
  (ADR 0001 amendment, process-input ownership).
- std.mem.trimRight, renamed to std.mem.trimEnd; not a posix/Thread/fs symbol
  at all.

The discipline: a removed-surface survey must enumerate the whole family a
symbol belongs to (every *Timestamp, the whole trim/split/tokenize rename set,
all environment access), checked against the vendored stdlib, not the one member
that happened to fall inside the migration's named classes. A file carrying only
an un-surveyed symbol shows zero hits under a too-narrow grep and is skipped
silently until the bench exposes it: estimator.zig and predictor.zig carried
only getenv and were not in the converted set until the bench named them.

### Shadowed breaks are not always removed surface; some are signature changes

Once a boundary compiles through, the compiler advances into deeper analysis and
can expose a pre-existing 0.16 incompatibility the earlier error hid. The
FreeBSD Sigaction handler is the clean example: handler_fn changed from
fn (c_int) to fn (posix.SIG) callconv(.c) void in 0.16. semasound's handleSignal
was fn (c_int); it compiled under 0.15 and sat shadowed behind the socket
errors, surfacing only after the socket boundary compiled. Not introduced by the
migration and not a removed symbol: a silent signature change, caught only by
the bench.

### Conversion mistakes are a separate failure category from churn

Adapting a removed wrapper to its raw form can introduce errors the compiler
reports one at a time per compilation unit. semasound converted five
posix.close(conn) (void) to posix.system.close(conn) (returns c_int) and dropped
the return on all five; the compiler reported only the first. Standing guard, run
per file before benching:

    grep -rnE 'posix\.system\.(close|unlink|rename|mkdir|shutdown|bind|listen)' src/*.zig \
      | grep -vE '_ = posix\.system|defer _ = posix\.system|if \(posix\.system|= posix\.system|< 0'

Anything printed is a status-returning raw call whose result is not discarded,
bound, or tested.

### A cross build that aborts early masks the very errors you are hunting

Recorded 2026-06-16, the hard way again. The bench is the authoritative signal,
and a cross-compile to -target x86_64-freebsd is not the bench. The trap is
specific: an exe build resolves system libraries before it finishes analyzing
the root module's body, so when the link needs a library the cross host does not
have (-lpam, -lutil), the build can fail at library resolution while the root's
own 0.16 breaks are still unanalyzed. A grep of that output for ".zig: error:"
then comes back empty, and concluding "zero compile errors" from it is wrong:
the compiler never reached the code. pgsd-sessiond's main.zig had a Sigaction
handler still typed fn(c_int) and an entire runUiOnly frame-loop still on
std.time.nanoTimestamp / milliTimestamp / Thread.sleep; the cross build hid both
behind the missing libpam, and only the native bench surfaced them. Rules that
follow: trust only the native ../tools/zig build / build test for a green claim;
treat a cross result that stops at library resolution as "did not compile," not
"compiled clean"; and when a specific construct must be checked off-host, prove
it in an isolated unit that does not drag in the unresolvable system library
(e.g. a standalone test of the Sigaction handler plus the compat.time idioms
against the vendored stdlib), never by inferring from a truncated full build.

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

### Class D: std.posix socket layer removed   [compat.posix LANDED green; semasound, semadraw daemon, pgsd-sessiond all benched green]

The medium-level std.posix socket functions (socket, bind, listen, accept,
connect, shutdown, recv, sendmsg/recvmsg, socketpair) are removed; setsockopt and
poll survive, and the types survive (fd_t, socket_t, sockaddr, msghdr, iovec,
pollfd). cmsghdr is not top-level and is reached through posix.system for
SCM_RIGHTS in shm.zig.

Tree-wide exposure (counts taken before clearing A/B/C): posix.socket 34,
posix.connect 4, posix.listen 3, posix.bind 3, posix.accept 3, posix.shutdown 1,
posix.recv 1. Files: semadraw (client/connection, remote_connection, ipc/shm,
ipc/socket_server, ipc/tcp_server), semasound (main, tone_client).

Direction, now ratified as shared ADR 0003 (socket boundary, compat.posix,
Accepted 2026-06-15): an Awase-owned socket shim over the raw posix.system.*
surface, consistent with the boundary discipline and AD-6. A 2026-06-15 graph
survey produced the authoritative inventory the ADR carries: the socket closure
is concentrated in seven files (semadraw client/connection, client/
remote_connection, ipc/socket_server, ipc/tcp_server, ipc/shm; semasound main,
tone_client), nearly the whole verb family is removed (socket, socketpair, bind,
listen, accept, connect, shutdown, sendmsg, recvmsg, send; only setsockopt
survives and stays outside the boundary by the 0001 scope rule), and the
supporting types survive at posix.* (sockaddr with un/in, AF, SOCK, SO, SCM, MSG,
msghdr/msghdr_const, iovec/iovec_const). cmsghdr left posix.* but shm.zig sources
it from a local @cImport, so SCM_RIGHTS reduces to the two removed verbs sendmsg
and recvmsg over a surviving msghdr, with the CMSG arithmetic already locally
owned. The ADR fixes verb ownership (not transport abstraction), an AD-6
Awase-owned error contract, the accept4 owned form, the socket_t handle
convention, and the seven-file migration order. This closes the principal
remaining closure criterion of ADR 0001 (criterion 3). chronofs and all of shared
have no sockets, so implementation begins with compat.posix itself, then proves
on the smallest consumer (semasound tone_client) before the rest; shm.zig
SCM_RIGHTS is the last and most careful site.

Status 2026-06-15: compat.posix is implemented and benched green (its own
surface test plus a socketpair round-trip), closing ADR 0001 criterion 3.
semasound is fully migrated as one unit and benched green on both steps
(../tools/zig build for the three exes, ../tools/zig build test for the unit
modules). Its socket sites (main, tone_client) route through compat.posix; its
non-socket surface cleared the established boundaries (compat.sync, compat.time,
the owned raw-posix Class E/F idioms, std.Io.Dir for the dump's traversal). The
sweep also exposed and resolved three under-surveyed symbols (milliTimestamp,
getenv, trimRight; see Methodology), the Sigaction handler signature change, and
five conversion-mistake close() returns. Environment access is now owned by
compat.args.getenv under the ADR 0001 process-input amendment.

Status 2026-06-16: Class D is closed. The seven socket files were already on the
compat.posix boundary when the semadraw pass began (a 2026-06-16 bench found
connection, remote_connection, socket_server, tcp_server, and shm all compiling
under the vendored toolchain, shm.zig's SCM_RIGHTS path included), so the
"five socket files remaining" estimate above was stale. The semadraw daemon,
which links socket_server / tcp_server / shm / the client, benches green; and
pgsd-sessiond, whose only D exposure was the transitive client connect path,
benches green once that client links. No socket verb remains on a removed
std.posix symbol anywhere in the tree.

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
- @cImport bintime translate-c trip (surfaced 2026-06-16 on the pgsd-sessiond
  bench, not a std-surface change): FreeBSD's <sys/time.h> defines a static
  inline bintime_shift whose body shifts by an int (_bt->frac <<= _exp). Zig
  0.16's translate-c renders that as @intCast(@bitCast(@as(c_long, _exp))) with
  no result type and fails the whole @cImport ("@bitCast must have a known
  result type"). It is reproducible in isolation with the vendored toolchain's
  bundled FreeBSD headers (zig build-obj -target x86_64-freebsd over a one-line
  @cInclude of sys/time.h), so it is a translate-c limitation, not an Awase bug.
  It fires only when a header pulls sys/time.h transitively: sysinfo.zig hit it
  through net/if.h, launch.zig through sys/stat.h (combination-dependent, only in
  concert with the other includes in the block). The block is the failure unit,
  so a single bad transitive include poisons the whole @cImport. Route: drop the
  offending @cInclude and declare only the symbols that file actually used from
  it. sysinfo needed two interface-flag constants (IFF_UP, IFF_LOOPBACK, declared
  against the stable ABI); launch needed mkdir and chmod (routed to std.c, with
  RUNTIME_DIR_BASE retyped [:0]const u8 so its .ptr meets the sentinel
  parameter). Globally disabling __BSD_VISIBLE would suppress the inline but also
  remove getifaddrs/login_cap and the rest of the BSD surface these files need,
  so the narrow per-include drop is the correct fix. There is no finer guard on
  the bintime block to exploit via @cDefine.

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
      [DONE, production and test green 2026-06-15; shared input_tests now green,
      see Phase 2 in the component-status prose]
   c. shared completion: shared/src/audio.zig is the last unconverted file in
      shared/src. It is socket-free and self-contained (imports only std and
      builtin), its surface is Class E only (two std.fs.openFileAbsolute, eleven
      posix.close) on the established raw-posix idiom, and it carries ten of its
      own test blocks, so it is standalone-benchable via
      ../tools/zig test src/audio.zig without needing a shared/build.zig target.
      Converting and benching it is what makes shared genuinely green, rather than
      green only for the four module targets (compat, clock, input, session) that
      the shared test step happens to build. It is hidden from cd shared &&
      ../tools/zig build test because shared/build.zig has no audio target and no
      other unit currently imports it. [DONE, green 2026-06-15, 10/10 via
      ../tools/zig test src/audio.zig; conversion was production-only (both
      readers to the raw-posix idiom), tests are in-memory and were untouched]
   (pgsd-sessiond is no longer in this step. The 2026-06-15 graph survey
   established that its executable imports the semadraw client, whose connect path
   uses posix.socket / posix.connect / posix.close / posix.write, all removed in
   0.16 and owned by the compat.posix boundary. It owns no sockets itself and does
   not import shared/session.zig, but its exe closure is not socket-free, so it is
   Blocked and moves to step 9.)
8. Implement the Class D socket boundary, compat.posix over posix.system.*, per
   shared ADR 0003 (Accepted 2026-06-15), closing ADR shared 0001 criterion 3.
   [DONE, green. (a) compat.posix landed 2026-06-15, 2/2; (b)-(e) the seven
   consumer files (semasound tone_client and main; semadraw connection,
   remote_connection, socket_server, tcp_server, shm with SCM_RIGHTS) are all on
   the boundary and compile under the vendored toolchain. The 2026-06-16 semadraw
   bench found the semadraw five already converted before that pass began, so the
   per-file sequencing below was carried out earlier than this notebook recorded;
   the ShutdownHow / posix.SHUT adjustment was the only bench change.]
   Implementation order per the ADR was: (a) land compat.posix itself (the verb
   wrappers, no consumer yet); (b) prove it on the smallest closure,
   semasound/src/tone_client.zig (socket + connect); (c) the other clients
   (semadraw client/connection, client/remote_connection); (d) the servers
   (semadraw ipc/socket_server, ipc/tcp_server; semasound main); (e) ipc/shm.zig
   last, the SCM_RIGHTS path (sendmsg/recvmsg over surviving msghdr, ancillary
   machinery unchanged). The error contract is AD-6 Awase-owned, so each file
   carries an error-handling pass, not a pure verb substitution.
9. The socket-bearing subprojects build green in dependency order. [DONE for the
   daemon path.] semasound: green 2026-06-15. semadraw daemon: green 2026-06-16
   (cd semadraw && ../tools/zig build builds semadrawd; the blocker was never the
   sockets but the non-socket surface across the daemon closure, credential
   family / Class E/F/G / PROT / time / backend raw-syscall, see the component
   status prose). pgsd-sessiond: green 2026-06-16 on build and build test, the
   transitive client gate having cleared. Remaining: the semadraw standalone
   tools (sdcs_make_* family, sdcs_dump, sdcs_replay, gesture_inspect,
   idle_probe) and the semadraw-term / semadraw-demo apps, all mechanical Class
   E/F/G off the daemon path (step 11).
10. Aggregate verification: full ./tools/zig build green plus subsystem benches.
11. semadraw tools and apps sweep: the last Pending population. Class E
    std.fs.cwd -> compat.fs/io across the sdcs_make_* family and sdcs_dump;
    Class G ArrayList .empty in sdcs_replay; Class F posix.write plus std.io and
    Thread.sleep in gesture_inspect and idle_probe; std.fs.File in the term and
    demo apps. Mechanical, repetitive, and isolated from the daemon; benched per
    exe under cd semadraw && ../tools/zig build.

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

chronofs, semainput, inputfs, semasound, the semadraw daemon, and pgsd-sessiond
have been benched green. chronofs is the
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
because no green subproject imported it. The 2026-06-15 graph survey corrected a
standing assumption here: pgsd-sessiond, long treated as session.zig's first
production consumer, does not import shared/session.zig at all. It has its own
src/session_file.zig, an independent implementation, so the two no longer move
together. The last unconverted file in shared/src was audio.zig (Class E only,
socket-free, ten in-memory test blocks); it was converted on the raw-posix idiom
and benched green 2026-06-15 (10/10 via ../tools/zig test src/audio.zig), since
shared/build.zig has no audio target to reach it under the aggregate test step.
With that, shared is complete in the literal sense: every file in shared/src is
converted and benched, not green only for the four module targets the test step
happens to build. audiofs is absent from this table by design: it is C, not a Zig
migration target (see the survey note under the execution plan).

    Component        A alloc     B args      C link      E fs/io     F write     G list      concurrency   D sockets
    shared (compat)  n/a         n/a         n/a         Green       Green       n/a         Green         Green
    shared/clock     n/a         n/a         n/a         Green       Green       n/a         Green         n/a
    shared/input     n/a         n/a         n/a         Green       n/a         n/a         n/a           n/a
    shared/session   n/a         n/a         n/a         Green       Green       n/a         n/a           n/a
    shared/audio     n/a         n/a         n/a         Green       n/a         n/a         n/a           n/a
    chronofs         Green       Green       n/a         Green       Green       n/a         Green         n/a
    semainput (lib)  n/a         n/a         n/a         n/a         n/a         Green       n/a           n/a
    inputfs tools    Green       Green       n/a         n/a         Green       n/a         Green         n/a
    semasound        n/a         Green       n/a         Green       Green       n/a         Green         Green
    semadraw daemon  Green       Green       Green       Green       Green       Green       Green         Green
    semadraw tools   n/a         Green       Green       Pending     Pending     Pending     Pending       n/a
    pgsd-sessiond    Green       Green       Green       Green       Green       n/a         Green         Green*

"n/a" means the component has no site in that class. The shared module rows
(compat, clock, input, session) are all green under cd shared && ../tools/zig
build test; shared/audio is converted and benched green on its own
(../tools/zig test src/audio.zig, 10/10), even though that file is socket-free
and not built by the aggregate test step (no audio target in shared/build.zig).
Every file in shared/src is now green. semainput (libsemainput) is a pure-logic
library: its only 0.16 surface is the Class G ArrayList idiom, so every other
class is n/a. inputfs's tool (inputdump) has no std.fs of its own (E is n/a); its
Class E weight lived in the shared/input dependency, now converted.
The D column for the socket-bearing subprojects (semasound, semadraw) read
Blocked until the compat.posix boundary was written; it landed green on
2026-06-15 (the shared (compat) D cell is now Green). semasound is now fully
green: it was migrated as one unit and benched on both steps (../tools/zig build
for the three exes, ../tools/zig build test for the unit modules), so its B, E,
F, concurrency, and D cells are all Green. Its B cell also covers the ADR 0001
process-input amendment (compat.args.getenv), and the sweep folded in the
Sigaction handler signature fix and the milliTimestamp/getenv/trimRight
under-survey symbols recorded in Methodology.

The semadraw row is split into two because the subproject benches as two
distinct populations. The semadraw daemon (semadrawd and its whole import
closure: client, ipc/socket_server, ipc/tcp_server, ipc/shm, client_session,
surface_registry, compositor, the damage and backend modules) is benched green
2026-06-16 under cd semadraw && ../tools/zig build, which builds semadrawd
without error. The first finding that re-ordered the work: the Class D socket
boundary was already applied across all seven socket files before this pass
began (connection, remote_connection, socket_server, tcp_server, shm all compile
against the vendored toolchain, shm.zig's SCM_RIGHTS included), so the doc's
earlier "semadraw Pending on D" was stale. The real semadraw blocker was the
non-socket surface: the credential-syscall family in semadrawd (getuid /
geteuid / setuid / setgid, all removed from std.posix, routed to posix.system.*
with the setuid/setgid error contract converted to a return-code check per
AD-6), getenv to compat.args, the Class G .empty idiom (poll_fds, damage,
surface_registry, client_session), the PROT packed-struct literal (drawfs, drm,
surface_registry), AcceptError sourced from compat.posix (socket_server,
tcp_server), app.zig's nanoTimestamp/Thread.sleep to compat.time, and the
backend raw-syscall paths (inputfs_input's kqueue/kevent wake bridge, drm's
clipboard file I/O). semadraw tools is the remaining Pending population: the
standalone sdcs_make_* family (Class E std.fs.cwd -> compat.fs/io), sdcs_dump,
sdcs_replay (Class G), gesture_inspect and idle_probe (Class F posix.write,
std.io, Thread.sleep), and the semadraw-term / semadraw-demo apps (std.fs.File).
These are separate executables off the daemon's critical path; semadraw's C link
and B args are Green (their build wiring and the arg model were already correct),
so only E/F/G/concurrency remain, all mechanical.

pgsd-sessiond is benched green 2026-06-16 on both ../tools/zig build and
../tools/zig build test (nine test modules). Its prior "Blocked*" was a
transitive block on the semadraw client connect path; with the daemon-side
socket files green the client links, so the gate cleared and the cell now reads
Green* (transitively resolved and benched; the asterisk records that
pgsd-sessiond owns no D sites of its own). Its own surface was a routine pass:
main.zig's console I/O to compat.fs, stdin to posix.read on STDIN_FILENO, the
PAM-service existence check to raw posix.system.access, the runUiOnly frame-loop
clock to compat.time, and the Sigaction handler signature (fn(c_int) ->
fn(posix.SIG) callconv(.c) void, the same change recorded for semasound,
recurring here in installSignalHandlers). Two findings from this subproject are
recorded under Methodology and Sub-surfaces respectively: the cross-compile
masking trap (a cross build that aborts at -lpam library resolution before
analyzing the exe root masks the root's body errors, so only the native bench is
authoritative) and the <sys/time.h> bintime_shift translate-c trip in two
@cImport blocks (sysinfo.zig via net/if.h, launch.zig via sys/stat.h).
semadraw C was 0.16-correct before this pass and is marked Converted on that
basis; it has not been re-benched as a green subproject.
