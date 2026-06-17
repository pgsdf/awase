# Awase Zig stdlib boundary

This document describes Awase's relationship to the Zig standard
library. The library is accepted as platform transport (per the
discipline doc's accepted-dependency list), but the discipline
also says: at determinism boundaries, Awase verifies stdlib
behaviour rather than assuming it. AD-6 makes that boundary
explicit.

## What's in scope, what isn't

Awase is roughly 30,000 lines of Zig across 100-odd files. A
wholesale audit of every stdlib call would not be productive,
most calls are in non-boundary code (build helpers, tool I/O,
config loaders) where stdlib's exact error semantics or version
behaviour does not affect Awase's guarantees.

The audit targets **determinism boundaries**: code paths where
Awase's correctness or its guarantees of timing, delivery, or
publication consistency depend on what stdlib does. These
boundaries are concentrated in five areas:

1. **Kernel cdev I/O.** `read`/`write`/`ioctl`/`mmap` against
   Awase's own kernel modules (drawfs, inputfs) and against
   Awase's own kernel cdevs in the guarantee path (`/dev/audiofs0`
   for semasound's audio output).

2. **Inter-daemon socket and ring I/O.** semadrawd ↔ clients,
   semasound ↔ clients, chronofs ingestion pipes.

3. **Shared-memory publication.** mmap of `/var/run/sema/*`,
   atomic loads/stores into the publication regions, page-level
   coherence between kernel writers and userland readers.

4. **Wire-format parsing.** Protocol message decoding (drawfs
   protocol, the semasound Hello protocol, JSON ingestion in
   chronofs, inputfs event-ring decoders).

5. **Time-sensitive scheduling.** chronofs frame scheduler,
   semasound's mixer pacing against device backpressure,
   inputfs's
   coordinate normalisation against the audio clock.

Out of scope: build scripts, error formatting, log emission,
test harness, dump-and-print tools, anything in the `tests/`
trees of any subsystem.

## What Awase requires of the stdlib

The required surface is small because Awase deliberately uses a
narrow subset. The ones we depend on the *behaviour* of, not just
the existence of:

### `std.posix`: system call wrappers

Awase uses `std.posix.read`, `std.posix.write`, `std.posix.poll`,
`std.posix.mmap`, `std.posix.munmap`, `std.posix.open`,
`std.posix.close`, and `std.posix.fd_t`.

**Required behaviour** at the boundary:

- `read` and `write` must propagate errors as Zig errors that the
  caller can match on, not panic via `unexpectedErrno`.
- `poll` must return `0` on timeout and the count of ready fds
  on success, with errors propagated.
- `mmap` of regular files must produce a slice usable for both
  load and store at the requested protections, with the caller
  responsible for matching `munmap`.
- `fd_t` is `c_int` on FreeBSD; this is checked at compile time
  by the existing Awase code.

**Boundary risk: `unexpectedErrno` panic on errnos outside the
stdlib's "known" list.**

This is the most concrete boundary issue Awase has hit. `std.posix.read`
ships with a hand-maintained list of expected errno values for
`read(2)`. Any errno outside that list flows through
`unexpectedErrno`, which dumps a stack trace and propagates a
panic-style error.

Awase's kernel cdevs (drawfs, inputfs) return errnos that fall
outside the stdlib's known set:
- drawfs returns `ENXIO` (errno 6 on FreeBSD) when a session is
  in its closing state.
- inputfs returns custom errnos defined in
  `inputfs/sys/dev/inputfs/inputfs.c` for ring-overrun cases.
- audiofs returns `EBUSY` for its exclusive-open contract and
  device-specific errnos for stream failure modes (semasound is
  the sole opener of `/dev/audiofs0`).

These are legitimate errnos for the Awase semantics involved, but
stdlib treats them as "this should never happen" and panics.

**Mitigation**: Awase uses a `safeRead` wrapper at one site
(`semadraw/src/backend/drawfs.zig`, line 171) that calls
`posix.system.read` directly (the un-wrapped syscall layer)
and treats every error uniformly as `error.ReadFailed`. The
audit recommends extending this pattern to all five boundary
areas; AD-6 closes by adding the helper to `shared/src/posix_safe.zig`
and applying it to chronofs ingestion. Other sites are reviewed
and either confirmed safe (sockets, where errno set is bounded)
or queued for future application.

### `std.fs`: filesystem operations

Awase uses `std.fs.openFileAbsolute`, `std.fs.createFileAbsolute`,
`std.fs.makeDirAbsolute`, and `std.fs.path.dirname`.

**Required behaviour**: the same as POSIX. `openFileAbsolute` must
produce a `File` whose `.handle` is a `posix.fd_t`. `makeDirAbsolute`
must return `error.PathAlreadyExists` (or the equivalent) when the
directory exists, allowing Awase's "ensure directory" patterns to
work.

**Boundary risk: API shape changes across Zig versions.**

Zig 0.14 → 0.15 changed:
- `std.fs.makeDirAbsolute` error set membership (handled in the
  shared helper at `shared/src/input.zig:81`).
- `std.posix.system.read` signature went through several shapes;
  the current wrapper at `drawfs.zig:172` uses the post-0.15
  shape with `@bitCast` of `usize` to `isize` to detect errors.

Awase's policy for stdlib-API drift: pin a Zig version in
`build.zig`, audit the API surface at version-pin update time,
and update the `safeRead`/`safeWrite` shims as needed.

### `std.io`: formatted I/O

Awase uses `std.io.Writer` minimally, primarily for diagnostic
output in tools and tests. The compositor's hot-path output
goes through the kernel cdev (drawfs publication) and never
touches `std.io.Writer`.

**Required behaviour**: stable enough that the existing
diagnostic prints continue to compile across Zig minor releases.

**Boundary risk: low.** Awase's correctness does not depend on
formatted I/O. Format-string changes (e.g. `{any}` semantics)
affect only diagnostic appearance.

### `std.mem`: memory utilities

Awase uses `std.mem.readInt`, `std.mem.writeInt`, `std.mem.eql`,
`std.mem.indexOfScalar`, `std.mem.indexOfScalarPos`,
`std.mem.sliceTo`.

**Required behaviour**:
- `readInt` and `writeInt` must respect the explicit endianness
  argument (`.little` or `.big`) regardless of host endianness.
  All Awase wire formats are little-endian; host is amd64 (also
  little-endian) but the explicit endianness in the call sites
  is intentional documentation.

**Boundary risk: low.** These are pure functions with stable
behaviour. The endianness arguments document intent and are not
sensitive to platform changes.

### `std.atomic` and `@atomicLoad` / `@atomicStore`

Awase uses Zig built-in atomic operations exclusively in the
publication-region writers and readers. The choice between
`std.atomic.Value` (a wrapper struct) and the bare `@atomicLoad`/
`@atomicStore` builtins varies by call site.

**Required behaviour**:
- `seq_cst` memory ordering on publication-marker stores must be
  observable to other threads/processes after the store returns.
- `monotonic` ordering is acceptable on hot-path counters where
  total ordering is not required (e.g. the frame counters on
  semasound's mixer path and audiofs's clock writer).

**Boundary risk: very low.** Builtins are part of the language
specification, not the standard library. The atomic ordering
arguments are version-stable. The choice of which atomic type
or builtin to use is a per-site decision, but the semantics are
not in question.

### `std.fmt.parseInt` and JSON parsers

Awase uses `parseInt` in protocol decoders and JSON ingestion
paths. `std.json` is used by chronofs ingestion (the historical
semaaud/semainput line formats, retained unwired per ADR 0029
Decision 6, and the semadraw line-format reader).

**Required behaviour**:
- `parseInt` returns `error.InvalidCharacter` and
  `error.Overflow` as Zig errors, not panic.
- `std.json.parseFromSlice` returns errors for malformed input
  rather than panicking.

**Boundary risk: medium.** JSON parsing is the surface where
adversarial or unexpectedly-formatted input is most likely to
appear. Awase's response to parse errors is explicit: log once,
ignore the line, continue. The chronofs ingestion path
(`chronofs/src/resolver.zig`) demonstrates this pattern.

## What Awase deliberately does not use

The boundary cuts cleanly here too. The discipline says Awase
accepts the stdlib; that does not mean every stdlib facility is
appropriate for Awase code:

- **`std.heap.GeneralPurposeAllocator`** in the kernel-adjacent
  guarantee path. Awase uses `std.heap.page_allocator` or the
  caller-supplied allocator at boundaries; GPA's allocation
  traces and double-free detection are useful in tests but add
  variance to hot paths.

- **`std.Thread.Pool`** for compositor scheduling. Awase spawns
  worker threads explicitly via `std.Thread.spawn` and manages
  lifetimes via condition variables. The Pool abstraction's
  scheduling decisions are not deterministic enough for
  audio-clock-driven work.

- **`std.io.tty`** for terminal detection. Awase's terminals
  (semadraw-term) are full-screen apps with their own input
  handling; auto-detecting "is this a tty" would interfere.

- **`std.process.Child`** for subprocess management in
  guarantee-path daemons. The compositor and audio daemon do
  not spawn subprocesses; that pattern lives in tools and
  tests, not in production code.

- **`std.log` configuration through `std.Options`.** Awase's
  daemons use `std.log.scoped` directly with per-daemon scope
  tags rather than relying on the global log level dispatch,
  which has changed shape across Zig versions.

## Mitigations applied under AD-6

This commit (besides the doc itself) lands one shared helper:

**`shared/src/posix_safe.zig`**, a small module with `safeRead`
and `safeWrite` that wrap `posix.system.read`/`posix.system.write`
and convert any error to `error.ReadFailed` / `error.WriteFailed`.
Mirrors the existing inline `safeRead` in
`semadraw/src/backend/drawfs.zig` and exposes it for reuse.

The chronofs ingestion thread
(`chronofs/src/resolver.zig:258`) is updated to use
`posix_safe.safeRead`. The previous `std.posix.read` call would
have panicked on any non-stdlib-known errno (a rare but
documented possibility under SIGINT during shutdown).

Other sites reviewed:
- Sockets in semasound, semadrawd, semadraw-term: use stdlib
  posix.read/write against socket fds. Socket errno set is
  small and well-known to stdlib (EAGAIN, ECONNRESET, EPIPE,
  EBADF). No safe-wrapper needed.
- inputfs ring reads: use mmap, not read; not affected by this
  class of issue.
- semasound device writes: blocking writes against
  `/dev/audiofs0`, whose backpressure paces the mixer (ADR
  0021). The errno set is audiofs's own; `EBUSY` from a
  contested open is acceptable
  to surface as a Zig error rather than a panic. Not migrated.

## What changes in stdlib would notice us

### Changes that would break Awase

- **Renaming or removing any of `std.posix.{read,write,poll,mmap,
  munmap,open,close,fd_t}`.** These are surface-level changes
  that surface as compile errors. Bounded port work to update
  the call sites or the safe wrappers.

- **Changing `posix.system.read`'s signature again.** The current
  wrapper assumes the post-0.15 form. A future Zig version that
  changes it again requires updating the `safeRead`/`safeWrite`
  helpers. Bounded by the small number of call sites.

- **Changing `mmap` slice protection semantics.** Awase assumes
  that `posix.mmap(..., PROT.READ | PROT.WRITE, ...)` produces
  a slice that supports both reads and writes via standard Zig
  pointer access. A future version that requires explicit
  re-protection would need code changes.

- **Removing `seq_cst` as a memory ordering choice.** Hypothetical;
  no signal of such a change. Would force re-evaluation of
  publication-marker semantics across the board.

### Changes that would silently affect Awase

- **`unexpectedErrno`'s known-errno list shrinking.** A Zig
  version that pulled errnos out of the "known" list would make
  more code paths panic where they previously returned a known
  Zig error. Awase's exposure here is limited because the
  safe-wrappers bypass `unexpectedErrno` entirely; non-wrapped
  call sites are at risk.

- **`std.json` parser strictness changes.** chronofs ingestion
  tolerates malformed JSON; if `std.json` becomes stricter (e.g.
  rejects trailing commas where it previously accepted them),
  some lines that previously parsed would now fail. Operationally
  visible as "ingestion drops lines"; the once-per-error log
  suppression catches it.

### Changes Awase will not notice

- **`std.heap` allocator implementation changes.** Awase code does
  not depend on allocation tracking metadata or specific
  fragmentation behaviour.

- **`std.Thread` scheduling internals.** Awase threads communicate
  via shared-memory publication with explicit atomic ordering;
  thread-pool scheduling is not in our path.

- **Format-string syntax changes in `std.fmt`.** Diagnostic
  output appearance may change; Awase correctness does not depend
  on it.

## Why this layering matters

Two practical consequences:

1. **The work to update Awase for a Zig version bump is bounded.**
   Most of Awase compiles cleanly across Zig minor versions; the
   sites at risk are enumerated above and are concentrated in
   `shared/src/posix_safe.zig` and the `safeRead`/`safeWrite`
   call sites. A future major-version Zig bump (say 0.16 → 1.0)
   may surface more changes, but the shape is known.

2. **The discipline's "verify rather than assume" rule has a
   concrete instantiation.** Before AD-6, the rule was a
   guideline; after AD-6, "verify rather than assume" means
   "use `posix_safe.safeRead`/`safeWrite` at kernel-cdev
   boundaries; document the assumption explicitly at every
   other stdlib boundary site." Code review has a checklist.

## References

- `docs/AWASE_ARCHITECTURAL_DISCIPLINE.md`, accepted-dependency
  list and operating rules. The "Language and toolchain" entry
  references this document.
- `docs/AWASE_STORAGE_DEPENDENCY.md`, sibling boundary doc, same
  shape, storage instead of stdlib.
- `docs/AWASE_USB_HID_BOUNDARY.md`, sibling boundary doc, USB/HID
  instead of stdlib.
- `shared/src/posix_safe.zig`, the safe-wrapper module landed
  by this commit.
- `semadraw/src/backend/drawfs.zig`, original site of `safeRead`,
  preserved as inline; future work could route this through the
  shared helper.
- `chronofs/src/resolver.zig`, updated to use `posix_safe.safeRead`.
- BACKLOG.md AD-6, the work item this document closes.
