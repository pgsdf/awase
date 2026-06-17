# shared 0001: Awase compatibility boundary

## Status

Accepted 2026-06-15 (operator), with review revisions: the principle restated
as an explicit layering rule (Decision 1), AD-6 classified as the first concrete
instance rather than subsumed (Decision 1), the I/O boundary described
independently of the current Zig I/O implementation (Decision 3), closure
criterion 3 strengthened from existence to usage, and an explicit non-goal added
to scope (Decision 4). The first ADR in the shared series, opened during the Zig
0.15.2 to 0.16.0 migration. It generalizes the boundary principle that AD-6
(`shared/src/posix_safe.zig`, documented in `docs/AWASE_ZIG_STDLIB_BOUNDARY.md`)
first instantiated for read/write, and it governs how the rest of the tree
absorbs the 0.16 standard-library churn. It authorizes the compatibility-layer
architecture and the `compat.io` module; the per-class source sweeps that follow
are mechanical applications recorded in the working notebook
(`docs/ZIG_016_MIGRATION.md`), each landing under the normal forward-only,
operator-ratified flow. Per ADR-before-code, no boundary module landed before
this ratification; `compat.io` lands next under it. The closure gate is the tree
building and benching green under the vendored 0.16.0 toolchain.

## Context

The 0.16.0 upgrade was ratified separately as a mechanical toolchain change,
and the working notebook treated each breaking change as an isolated port. The
first full build under the vendored compiler did not behave like a set of
isolated fixes. Clearing one error class uncovered the next, and the surface
kept widening: process arguments (Class B), then the filesystem and I/O
reorganization under `std.Io` (Class E, 51 files), the removal of the
`std.posix` write path (Class F), the `std.ArrayList` initialization change
(Class G), and the `std.posix` socket-wrapper removal (Class D). Class E alone
is the dominant migration surface.

What looked like five unrelated breakages is one observation: the 0.16 cycle
reworked precisely the std surfaces Awase leans on (startup, args, the
Reader/Writer interface, filesystem, posix), and it did so all at once. Four of
the classes (args, fs/Io, posix write, sockets) resolve to the same shape. Awase
code does not need the volatile std abstraction directly; it needs a stable
local interface that the std abstraction happens to back today.

This is the same move AD-6 already made for read/write at the determinism
boundary, where the concern was stdlib behaviour (error propagation, not
panicking via `unexpectedErrno`). The 0.16 churn extends the same need from
behaviour to structure: the std surface is volatile in shape, not only in
semantics. Rather than chase each removal with a bespoke workaround, Awase
absorbs the volatility once, at a boundary it owns, and keeps the rest of the
tree stable. The args helper (`compat.args`) is the first instance landed under
this principle and is bench-confirmed through the chronofs path; fs/Io is the
second; posix write and sockets are the third and fourth. The pattern is no
longer speculative. The migration is demonstrating the boundary, not
anticipating it.

## Decisions

### 1. The principle

Awase code depends on Awase-owned compatibility interfaces. Compatibility
interfaces depend on external toolchains, libraries, and volatile
standard-library surfaces. When a std surface that Awase relies on is volatile,
in behaviour or in shape, the volatility is absorbed once behind an Awase-owned
interface, and callers depend on that interface, not on the std surface. Stated
as a layering rule for future reviews: dependence flows downward only, from
Awase code to compatibility interface to external surface, and never directly
from Awase code to a volatile external surface.

This is a standing architectural rule, not a migration-only expedient. It does
not replace AD-6. AD-6 remains the decision that established the determinism
boundary and the rationale for `posix_safe`. This ADR generalizes that pattern
and classifies `posix_safe` as the first concrete instance of the broader
compatibility-boundary architecture, now serving both its original
determinism-behaviour role and, since the posix write wrapper was removed in
0.16, the shape-insulation role. The chain of reasoning is preserved rather than
overwritten: AD-6, then `posix_safe`, then the shared compatibility pattern,
then this ADR.

### 2. Resource ownership stays with the tool (Option B)

Tools and subsystems keep ownership of their own allocator, argument handling,
and I/O context. The compatibility layer absorbs the std shape change without
threading std startup infrastructure through application code.

Concretely for the 0.16 migration: `main` keeps the `std.process.Init.Minimal`
signature established by the args sweep. It does not move to the full
`std.process.Init` merely because `std.Io` now requires an `Io` handle for file
operations. Where a tool needs an `Io`, it constructs one locally from its own
allocator through the boundary (`compat.io`), the same way it obtains its argv
slice through `compat.args`. The alternative (full `Init` everywhere, so start.zig
supplies `io` and `gpa`) was rejected: it would thread startup infrastructure
through dozens of tools because the stdlib was reorganized, inverting the
direction of dependence the principle establishes.

### 3. Boundary module layout

The boundary lives under `shared/src/compat/`, with `shared/src/compat.zig` as
the aggregator that re-exports each submodule. Each submodule is a thin,
single-purpose interface over one volatile std surface:

    tool                tool                tool
      |                   |                   |
    compat.args         compat.io          compat.posix
      |                   |                   |
    Zig process args    Zig I/O facilities  Zig posix syscalls

- `compat.args` (landed): owns argv collection over the removed
  `argsAlloc`/`argsWithAllocator`, exposing a random-access slice and a
  forward iterator.
- `compat.io` (this ADR authorizes): owns construction of a local blocking `Io`
  implementation over the currently supported Zig I/O facilities, so callers
  reach the relocated filesystem and I/O operations through a stable Awase
  interface. This is the vehicle for the Class E sweep.
- `posix_safe` / `compat.posix`: owns the posix system-call surface. It already
  covers read/write (AD-6); it extends to the removed socket wrappers (Class D)
  over the raw posix syscall surface, designed as a later step once Class E
  clears and the pure socket surface is fully visible.

Class F (callers of the removed `std.posix.write`) routes through the existing
`posix_safe` write path rather than a new module. Class G (the
`std.ArrayList(T){}` to `.empty` initialization change) is an in-place std
idiom correction, not a boundary concern, and is noted here only to keep the
class inventory complete.

### 4. Scope of the boundary

The boundary covers std surfaces Awase depends on whose volatility, behavioural
or structural, would otherwise propagate into application or subsystem code. It
is deliberately narrow. It is not a wholesale wrapper around the standard
library, and it does not relitigate the determinism-boundary audit in
`docs/AWASE_ZIG_STDLIB_BOUNDARY.md`; that document continues to govern which
behaviours are verified at correctness-critical paths. This ADR adds the
shape-insulation concern and unifies both under one ownership principle. Stable
std surfaces (slices, math, formatting, comptime facilities) are used directly.

The boundary is not intended to abstract operating-system semantics, provide
cross-platform portability, or replace direct use of stable standard-library
facilities. It exists to absorb volatility in surfaces Awase already depends on,
and nothing wider.

### 5. Record-keeping and closure

The per-class before/after detail, the authoritative error inventory, and the
per-component port status remain in the working notebook
(`docs/ZIG_016_MIGRATION.md`); this ADR does not restate individual API
changes. The notebook is updated to add Classes E, F, and G alongside the
existing A through D, and to reference this ADR as the architectural decision
the migration surfaced.

Closure criteria:

1. This ADR is ratified and `compat.io` lands behind it.
2. Classes E, F, and G are swept and the userland subprojects build under the
   vendored 0.16.0 toolchain.
3. The socket boundary is implemented and all current socket consumers are
   migrated to it, at which point the migration is structurally complete and the
   boundary has its fourth concrete instance.

## Errata

### E1. compat.fs directory-operations surface (P3 migration)

The filesystem surface scoped under Decision 4 proved slightly too small once
real 0.16 migration reached the pgsd-sessiond filesystem sites. The session-file
enumerator and its test scaffolding require directory traversal, directory
creation, and recursive deletion, and the session-file reader checks file size
before reading; none of these fell inside the original create-or-open, read,
write, position, close scope.

compat.fs is therefore extended, within Decision 3 (filesystem helpers live only
in compat.fs) and without introducing a second filesystem layer, by these thin
wrappers over std.Io.Dir and std.Io.File:

- Dir.openDir (with an iterate flag)
- Dir.iterate, plus an Iterator that carries the Io handle so next() takes no
  io argument
- Dir.makeDir (wrapping 0.16's renamed createDir with the platform default
  directory permissions)
- Dir.deleteTree
- Dir.close (for handles obtained from openDir)
- File.stat

Each wrapper carries the Io handle inside Dir, File, or Iterator, so call sites
still never thread io or reference std.Io types, preserving the Decision 2 and 3
boundary properties.

File.stat is added solely to preserve externally visible behaviour: the
session-file reader surfaces FileTooLarge from a pre-read size check (ADR 0004)
rather than letting an allocator-limit error replace it. It is not a
general-purpose metadata surface, and new callers should not reach for it absent
that specific need.

This errata records that the originally scoped surface was an underestimate
discovered during migration, not a change of architectural direction; the
ownership principle and boundary layout (Decisions 1 through 3) are unchanged.

### E2. compat.fs absolute-path surface (P3 migration, semadraw)

The semadraw daemon closure reached two regular-file operations not covered by
the original scope or by E1: two backends persist or read a regular file at a
fixed absolute path (drm and vulkan_console clipboard and debug-dump files).

compat.fs is therefore extended, within Decision 3 (filesystem helpers live only
in compat.fs) and without introducing a second filesystem layer, by these thin
wrappers over std.Io.Dir:

- openFileAbsolute (open a regular file by absolute path, no owning Dir handle)
- createFileAbsolute (create or truncate a regular file by absolute path)

Both carry the Io handle inside the returned File, so call sites still never
thread io or reference std.Io types, preserving the Decision 2 and 3 boundary
properties.

Three boundary points are recorded with this errata. Each draws the same line:
compat.fs is for regular-file access; sockets and device descriptors stay in the
raw-posix lineage.

- Socket-path lifecycle stays raw posix, not compat.fs. The unix-socket file is
  created by bind(), chmod-ed by raw posix.system.fchmodat (WT1), and removed by
  raw posix.system.unlink (this tranche, P3-T2a). Routing only the removal
  through compat.fs would split a coherent lifecycle across two layers and, since
  SocketServer.bind and deinit carry no allocator, would force an io/Threaded
  bootstrap with no natural allocator to draw on. A Dir.deleteFile wrapper was
  considered for this and is deliberately NOT added: its only candidate consumer
  is this socket-path delete, which is raw, so the wrapper would be unused surface
  (grow-only-what-is-needed, Decision 5).
- Device-descriptor acquisition does NOT route through compat.fs. The inputfs
  notify cdev (inputfs_input) was opened with std.fs.openFileAbsolute purely to
  obtain its file descriptor for the kqueue bridge; it performs no file I/O. That
  site moves to raw posix.openat, staying in the raw-fd lineage alongside the
  WT2b device opens.
- deleteFileAbsolute is deliberately NOT added. No daemon-closure site deletes by
  absolute path. It can be added if and when a consumer appears.

As with E1, this records that the scoped surface was an underestimate discovered
during migration, not a change of architectural direction; Decisions 1 through 3
are unchanged.
