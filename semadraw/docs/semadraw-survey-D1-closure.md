# Semadraw migration survey - Deliverable 1: closure partition and wiring map

Status: For ratification. No conversion begins until this artifact is signed off.
Date: 2026-06-15
Basis: the ratified survey spec (unit = union of `zig build` and `zig build test`
closures, default options; every file tagged reachability / boundary exposure /
risk class / validation path).

This deliverable populates **reachability** and **validation path** authoritatively
(from the build graph and file imports, walked mechanically and validated against
the actual files), and the **compat-wiring map** authoritatively (from build.zig).
**Boundary exposure** and **risk class** are deferred to Deliverable 2 (the
stdlib-usage census) and are NOT claimed here, to avoid presenting a grep pass as
a finished census, the error semasound made three times.

## Method

The closure was computed by a walker that encodes the build.zig module graph
(module name to root file plus named imports) and every exe/test/lib target with
its named-module wiring, then walks `@import("*.zig")` file edges and named-module
edges transitively from each root set. It was validated against the real files:
the five test roots resolve exactly (sdcs/simd/inputfs_translate/protocol import
only std; connection imports protocol), and semadraw.zig / semadrawd.zig edges
match build.zig. Default backend options (x11/wayland/vulkan/bsdinput = false)
mean the stub backends are active; the real backends are out-of-unit (below).

## The unit (default options)

    Production closure (zig build):       86 files
    Test closure (zig build test):         5 files
    Partition:  production-only 81 | shared 5 | test-only 0

### Shared closure (production AND test) - 5 files

These are exercised by **both** `build` and `build test`. A conversion error here
breaks both steps, so they are the highest-stakes files for the dual-green
requirement and should be converted with the most care.

    src/sdcs.zig                      (test root: tests)
    src/simd.zig                      (test root: simd_tests)
    src/backend/inputfs_translate.zig (test root: inputfs_translate_tests)
    src/ipc/protocol.zig              (test root: ipc_protocol_tests)
    src/client/connection.zig         (test root: client_connection_tests; SOCKET file)

The last one is the crux: connection.zig carries socket verbs (2) and is reached
by the production client library AND the connection test target. Both wire only
`protocol`, neither wires `compat` (see wiring map). Routing it through
compat.posix forces a wiring change in two places at once.

### Test-only closure - 0 files

Every test root is also production-reached (all five are production source files
compiled standalone as tests). There is no test-only code in the default unit.
Two test files exist on disk but are deliberately **not** wired into `zig build
test` (run manually, per build.zig comments): src/backend/inputfs_input.zig and
src/backend/bsdinput.zig. They are outside the unit by definition; flagged here so
"no test-only files" is not mistaken for "no unwired test code."

**Proof that the test-only set is empty by traversal, not by failure to traverse.**
"0 test-only files" is a stronger claim than "the test roots are production
files," so it was established by walking each test root's full edge set, not by
inspecting the roots alone. Four of the five roots (sdcs, simd, inputfs_translate,
protocol) import only `std`: they are leaves with no edges to follow, so the empty
result is genuine, not an unwalked graph. The fifth, connection.zig, has exactly
one non-std edge, `@import("protocol")`; protocol.zig is itself a `std`-only leaf,
so that closure terminates at {connection, protocol}. The transitive test closure
is therefore exactly those five files, and each is independently confirmed present
in the production closure. No fixture, mock transport, or test-support module is
reachable only from test builds, because the test roots have no edge that leaves
the production-reached set.

### Production-only closure - 81 files

The bulk: the daemon (semadrawd + ipc + daemon/ + compositor/ + backend/), the
client library beyond connection.zig, the 31 tools, the term and demo apps, and
the shared/semainput dependencies pulled in (compat/*, input, clock, session,
libsemainput). Full list in the walker output; not reproduced here to keep the
ratification artifact readable. Notable members: src/app.zig and src/encoder.zig
(file-imported by semadraw.zig), src/backend/inputfs_input.zig (file-imported by
drawfs.zig, which is why it is reachable though not a module).

## Compat-wiring map (authoritative, from build.zig)

The structural difference from semasound: semasound file-imported its sources into
one exe module that wired compat once, so the sources inherited it. **Semadraw
splits its IPC and client code into standalone `createModule` instances that do
not wire compat.** Routing any of them through compat.posix requires adding compat
to that module's build.zig wiring, not just to an exe.

### Socket-bearing modules that will need compat added (provisional on census)

    Module             Root file                         posix socket verbs
    socket_server      src/ipc/socket_server.zig         8
    tcp_server         src/ipc/tcp_server.zig            5
    shm                src/ipc/shm.zig                   2   (sendmsg/recvmsg, SCM_RIGHTS)
    connection         src/client/connection.zig         2
    remote_connection  src/client/remote_connection.zig  2

None of these five modules wires compat today. semadrawd wires compat at the exe
level, but it imports socket_server/tcp_server/shm as named modules, and a named
module does not inherit the importer's compat wiring. So the wiring work is
per-module, on all five, plus the test target that roots connection.zig.

### Targets not wiring compat (gap risk if their closure routes through compat.*)

    [prod] lib                     root src/semadraw.zig
    [prod] client_lib              root src/client/client.zig      (pulls connection.zig)
    [prod] hello                   root src/apps/hello/main.zig
    [prod] sdcs_test_malformed     root src/tools/sdcs_test_malformed.zig
    [test] tests(sdcs)             root src/sdcs.zig
    [test] simd_tests              root src/simd.zig
    [test] inputfs_translate_tests root src/backend/inputfs_translate.zig
    [test] ipc_protocol_tests      root src/ipc/protocol.zig
    [test] client_connection_tests root src/client/connection.zig  (SOCKET; needs compat post-migration)

client_lib and client_connection_tests both reach connection.zig without compat
wired: the semasound test-wiring gap, present in both partitions and predictable
now rather than after the production build is green.

## Out-of-unit / conditional surface (not migrated with the default unit)

- **Opt-in backends** (real implementations, default-off; stubs used instead):
  src/backend/x11.zig, vulkan.zig, wayland.zig, bsdinput.zig, vulkan_console.zig.
  Built only with -Dx11 / -Dvulkan / -Dwayland / -Dbsdinput, which the PGSD
  bare-metal target does not set, and which pull libX11/libvulkan/etc. Treated
  like audiofs format-interop: a separate conditional surface, surveyed and
  migrated only if those backends are enabled. Flagged, not folded in.
- **Stray file:** src/backend/semadraw-build.zig is an 807-line copy of a
  build.zig sitting in the backend source directory, reached by nothing. Almost
  certainly misplaced; recommend removal in a hygiene pass, outside this
  migration.
- **Manually-run tests** (not in `zig build test`): inputfs_input.zig,
  bsdinput.zig. Outside the unit by build.zig design.

## What this fixes versus semasound

The partition names every in-scope file and says why it is in scope (which target
reaches it, via which step). estimator.zig/predictor.zig had no analogue here that
a too-narrow grep could hide, because scope is computed from the build graph, not
from a symbol list. The wiring map surfaces the connection.zig / test-target gap
before conversion, not after a green production build.

## Next (Deliverable 2, after ratification)

Stdlib-usage census across all three partitions, grouped by family (std.time.*,
std.mem.*, std.fs.*, std.Io.*, std.posix.*, std.Thread.*, std.process.*,
std.heap.*, ArrayList init, std.c.* externs), each member checked against the
vendored stdlib for removed/renamed/signature-changed status. That promotes the
boundary-exposure and risk-class columns to authoritative, produces the three
ledgers (removed APIs / signature changes / defect-prone sites), each tagged with
the reachability and validation-path context from this partition, and sequences
the conversion with shm.zig SCM_RIGHTS last.
