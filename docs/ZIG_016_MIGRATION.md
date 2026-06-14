# Zig 0.15.2 to 0.16.0 Migration

Status: in progress
Type: working notebook (not an ADR; this is a mechanical toolchain migration)

## Purpose

Awase pins a project-local Zig 0.16.0 toolchain (tools/bootstrap.sh, tools/zig,
sdk/zig/current). This notebook records the breaking changes encountered when moving the
source tree from 0.15.2 to 0.16.0, the confirmed before/after for each, and the per-component
port status.

It is a notebook, not an architectural decision record: the language upgrade itself was
ratified separately and most changes are mechanical. The one exception is the std.posix
socket-layer removal (class D below), which is a real porting effort with a strategy choice
and may warrant its own ADR.

## Methodology (read this first)

Lesson learned, the hard way, twice:

    Do not infer Zig 0.16 APIs from Awase source code.
    Do not infer Zig 0.16 APIs from Zig master or from web migration notes.
    The vendored stdlib (sdk/zig/current/lib/std) is the authoritative specification.

The 0.16 cycle reworked exactly the areas this migration touches: process startup, I/O, the
Reader/Writer interface, std.posix, and the main entrypoint. Two failure modes bit us:

1. argsAlloc looked valid because the tree used it. It did not survive 0.16; the call was
   0.15.2 code whose error was masked by the GeneralPurposeAllocator error earlier in the
   same compilation unit (the compiler stops at the first error per unit).
2. Socket APIs looked predictable because older std.posix exposed them. Most were removed.

Surviving 0.15 code is not evidence of a 0.16 API, and online examples are polluted by master
snapshots and intermediate-snapshot blog posts. Before converting any std call, confirm its
0.16 shape by reading the vendored stdlib directly. Treat each newly exposed error class as
discovery work first, then migration.

## Toolchain (landed)

- Vendored compiler: sdk/zig/current/zig (0.16.0, x86_64-freebsd), out of git, fetched by
  tools/bootstrap.sh, invoked via tools/zig. See commit 164060e.
- Root build.zig: a comptime guard rejects any compiler whose minor != 16, and routes all
  sub-build invocations through b.graph.zig_exe so no sub-build escapes to a system Zig.
- Rule: no build step invokes bare `zig`; everything flows through ./tools/zig or
  b.graph.zig_exe. Never `sudo ./tools/zig build` (it poisons ~/.cache/zig ownership).

## Authoritative error inventory (0.16.0, post-routing)

The first full build under the vendored 0.16.0 surfaced four breaking-change classes.
Classes A and C are mechanical and now bench-confirmed (they no longer appear in the build).
Class B was reopened: clearing A uncovered that the tree-wide argsAlloc usage is also removed
in 0.16, so the original "convert two sites" framing was wrong. Class D is the substantive
migration and is still only partially visible: each compilation unit stops at its first
error, so the full posix/io surface appears only after A, B, C clear.

### Class A: std.heap.GeneralPurposeAllocator removed   [DONE, bench-confirmed]

GeneralPurposeAllocator was renamed to DebugAllocator in 0.14 (kept as a deprecated alias),
and the alias was removed in 0.16. The API is identical; the variable name `gpa` is
conventional and kept.

    Before: var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    After:  var gpa = std.heap.DebugAllocator(.{}){};

deinit() and allocator() are unchanged. Sites: 37 files across chronofs, inputfs, semadraw
(tools, apps, daemon), and pgsd-sessiond. Applied as a tree-wide identifier rename.

### Class B: std.process argument API removed   [REOPENED, pending stdlib read]

Both std.process.args() and std.process.argsAlloc()/argsFree() are rejected by the vendored
0.16.0 ("struct 'process' has no member named 'argsAlloc'"). The original framing (convert
two semasound sites from args() to the dominant argsAlloc form) was wrong on two counts: the
tree's 36 argsAlloc sites were 0.15.2 code masked by the GeneralPurposeAllocator error, not
0.16-correct code; and converting the two semasound tools to argsAlloc moved them toward a
removed function. The two semasound conversions in the mechanical-pass commit are therefore
known-bad and must be redone.

Full surface: 36 files use argsAlloc/argsFree, 2 use argsWithAllocator (idle_probe,
gesture_inspect), 38 total.

The 0.16 replacement is unconfirmed and must be read from sdk/zig/current/lib/std/process.zig
and start.zig before any conversion. Three materially different cases:

1. argsWithAllocator (or equivalent iterator) survives. Migration is mechanical: 36 sites
   move to the iterator form, the 2 existing argsWithAllocator sites are already correct.
2. Only ArgIterator.initWithAllocator() survives. Still mechanical, different call shape.
3. Arguments arrive through startup plumbing (the 0.16 "juicy main" model,
   pub fn main(init: std.process.Init, args: ...) !void). This is a structural migration of
   every tool's main signature, not a search and replace.

No conversion until the case is known.

### Class C: Compile-step linking methods moved to the module   [DONE, bench-confirmed]

In 0.16, linkSystemLibrary and libc linkage live on the Module, not the Compile step.
addExecutable / addTest already used the 0.16 `.root_module = b.createModule(...)` form, so
only the post-creation linking calls needed routing. semadraw/build.zig was already correct
(mod.link_libc / mod.linkSystemLibrary(name, .{})); only pgsd-sessiond/build.zig used the
old Compile-step form.

    Before: exe.linkSystemLibrary("pam");
    After:  exe.root_module.linkSystemLibrary("pam", .{});

    Before: exe.linkLibC();
    After:  exe.root_module.link_libc = true;

Sites: pgsd-sessiond/build.zig, 5 linkSystemLibrary plus 8 linkLibC, 13 conversions total.

### Class D: std.posix medium-level layer removed   [PENDING, strategy decision needed]

This is the real migration. The 0.16 release notes state that most std.posix and
std.os.windows functions sat at an awkward medium-level abstraction and were removed.
Confirmed-removed functions that Awase uses include posix.socket, posix.bind, posix.listen,
posix.accept, posix.shutdown (with writev/pipe2/getrandom removed elsewhere). Lower-level
calls (read, write, close, connect) may survive; the authoritative list for this exact build
is sdk/zig/current/lib/std/posix.zig on the bench and must be read directly rather than
assumed.

Tree-wide exposure, occurrence counts taken before clearing A/B/C:

    posix.socket 34, posix.connect 4, posix.listen 3, posix.bind 3, posix.accept 3,
    posix.shutdown 1, posix.recv 1.

Only two posix.socket sites appear in the current build log because each compilation unit
stops at its first error. The full surface (every socket and IPC path in semasound,
semadrawd, chronofs) will appear on the next bench once A/B/C land.

Replacement directions (decision required before touching socket code):

1. Raw syscalls via std.posix.system.* (the FreeBSD thin layer) or std.os.<platform>.
   Keeps Awase at the syscall level it already targets. Verbose errno handling, no io
   threading. Most consistent with the project's low-level, FreeBSD-native posture.
2. The new std.Io / std.Io.net interface (Stream, Server, UnixAddress) threaded as an
   `io: std.Io` parameter through call sites. Higher-level, but a larger architectural
   change and a new dependency on the still-evolving Io abstraction.
3. An Awase-owned thin socket shim wrapping option 1, consistent with the
   depend-only-on-owned-code discipline: one place to absorb future std.posix churn.

Recommendation pending. This choice is architectural and may deserve its own ADR rather
than living only in this notebook.

## Execution plan

1. Vendor toolchain, version guard, sub-build routing.                  [DONE]
2. Authoritative build and error inventory.                            [DONE]
3. Mechanical pass classes A and C.                                    [DONE, bench-confirmed]
4. Discovery: read the vendored stdlib for the class-B args API and the class-D posix
   survivors (process.zig, start.zig, posix.zig) before any further conversion.
5. Redo class B tree-wide (38 sites) in the confirmed 0.16 shape, then bench.
6. Decide the class-D direction (raw syscalls, std.Io, or owned shim) from the posix.zig read.
7. Per-component posix/io port in dependency order, each benched:
   shared → chronofs → semasound / semadraw / semainput → pgsd-sessiond.
8. Aggregate verification: full ./tools/zig build green plus subsystem benches.

## Component status

    Component        A alloc   B args        C link    D posix/io
    shared           n/a       n/a           n/a       pending survey
    chronofs         done      reopened      n/a       pending
    inputfs tools    done      reopened      n/a       pending
    semasound        n/a       reopened/bad  n/a       pending (socket/bind/listen/accept)
    semadraw         done      reopened      already   pending
    semainput        n/a       n/a           n/a       pending survey
    pgsd-sessiond    done      reopened      done      pending

"n/a" means the component had no site in that class. "already" means it was 0.16-correct
before this pass. "reopened" means the class-B args calls there are removed in 0.16 and await
the confirmed replacement; "bad" means the mechanical-pass commit shipped a known-wrong
conversion there (semasound) that must be redone. Class D status is provisional until the
post-mechanical bench reveals the full surface.
