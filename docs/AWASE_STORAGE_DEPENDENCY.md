# Awase storage dependency

This document describes Awase's dependency on durable storage and
the filesystem layer beneath it. It exists to make explicit what
Awase requires of storage and which of those requirements are
inherited from being delivered as part of PGSD.

## The two-layer answer

Awase and PGSD have different storage dependencies. The substrate
inherits the distribution's commitments, not the other way round.

**Awase the substrate** (this repository) makes minimal demands on
storage. It needs POSIX file I/O via VFS, `mmap` of regular files,
atomic rename within a directory, and `tmpfs` for the runtime
publication surface under `/var/run/sema/`. Any FreeBSD filesystem
providing these primitives is sufficient. Awase's tests run on UFS
and on ZFS interchangeably; Awase's code path branches nowhere on
filesystem type.

**PGSD the distribution** (separate concern) requires ZFS. The
distribution's value propositions, boot environments via
`bectl(8)` for safe kernel/userland updates, the Axiom package
manager (ZFS-native, manipulates datasets directly for atomic
package installation), and the `sysrebase` boot-environment
utility, all require ZFS. PGSD does not support installation on
UFS root.

Therefore Awase inherits ZFS as a runtime dependency *only when
delivered as PGSD*. A developer running Awase on stock FreeBSD with
UFS root has working Awase; a PGSD user has working Awase on ZFS
because PGSD requires ZFS for its own reasons. The dependency
chain is: Awase needs VFS → PGSD provides ZFS → ZFS provides VFS.
The middle link is what this document records.

## What Awase actually does with storage

Awase's storage-touching surfaces, all VFS-level:

- **`/var/run/sema/*` publications.** inputfs, audiofs, semadrawd, semasound,
  and chronofs publish shared-memory regions as regular files
  under `/var/run/sema/`. Clients `mmap` them; producers update
  them in place. The expected backing is `tmpfs` per `INSTALL.md`
  Step 1; the regions are runtime state, not persistent. The
  filesystem must support `mmap` of regular files and concurrent
  reader/writer access without tearing at the page level.

- **Daemon configuration files.** semasound reads per-target
  policy from `/usr/local/etc/semasound/<target>.policy` and
  writes derived state (`policy-state`, `policy-valid`,
  `policy-errors`) under `/var/run/sema/audio/<target>/` using
  the write-temp-then-rename pattern for atomic update
  visibility (ADR 0026/0027).
  semadrawd reads `/etc/semadrawd/config.json` if present.
  All require POSIX `open`/`read`/`write`/`rename` with standard
  semantics; nothing filesystem-specific.

- **rc.d service state.** Service PID files under `/var/run/`,
  log files under `/var/log/`, and the standard FreeBSD rc(8)
  conventions. Awase inherits whatever the platform `rc.d` system
  uses; this is not a Awase-specific requirement.

- **Source tree and build artifacts.** Awase's build (Zig + shell)
  reads source under the repo root and writes build artifacts to
  `zig-out/`. POSIX file I/O only. Build is identical on UFS and
  on ZFS.

What Awase does *not* use:

- ZFS-specific APIs (`libzfs`, channel programs, `zfs send`/`recv`,
  property lists, dataset mounts, snapshots, clones).
- ACL extensions beyond standard POSIX `chmod`/`chown`.
- Extended attributes.
- File-level compression hints, encryption hints, or any
  ZFS feature flag.

There is no Awase code that compiles `-lzfs`, includes `libzfs.h`, or
calls into the ZFS userland library. Searching the tree confirms
this; the substrate is filesystem-agnostic at the source level.

## What Awase does if storage fails

The behaviours below describe Awase's response when its required
storage primitives become unavailable. These are testable failure
modes that any conforming filesystem (ZFS or UFS) can produce.

**`/var/run` not writable** (e.g. read-only filesystem): inputfs
fails to publish at attach time and logs the failure once via the
AD-13.2 suppression flag. The userland daemons follow
the same pattern. Daemons continue running but produce no
publication; clients see "ring at /var/run/sema/... unavailable"
on read.

**`/var/run` full** (no space, tmpfs at limit): the same once-per
log-suppression path applies. Existing `mmap` regions remain
valid; new regions cannot be created. Operationally degraded but
not fatal.

**Configuration file unreadable**: daemons fall back to compiled
defaults, log the read failure once, and continue. The
`AWASE_DAEMON_DEPENDENCY_ABSENCE.md` ADR codifies this as Posture 3
(degrade, don't fail).

**`fsync`-class durability failure** (filesystem returns ENOSPC or
EIO during `rename`): the AD-13.2 hot-path suppression flags
prevent log spam; the affected publication remains at its
previous content; the producer retries on the next write cycle.
No Awase state requires synchronous fsync to be correct; we
tolerate the observed-write window.

These behaviours are deliberately filesystem-agnostic. None of
them invoke ZFS-specific recovery, none use `zpool status`, none
rely on `bectl` rollback. PGSD users have additional recovery
options at the *distribution* layer (boot environments, Axiom
rollback) but Awase the substrate does not assume those exist.

## Why this layering matters

The discipline doc names ZFS as accepted platform transport. The
acceptance is correct but the layer was previously implicit. Two
practical consequences of making it explicit:

1. **Awase stays portable across BSDs and across filesystems.** A
   future port to OpenBSD or NetBSD does not require porting ZFS
   along with it. Awase runs on whatever the host platform provides
   for VFS. The PGSD-on-FreeBSD distribution path is one
   deployment, not the substrate's only deployment.

2. **PGSD's ZFS requirements are tracked at the distribution
   level, not in Awase.** AD-8 (omit competing HID drivers from
   PGSD's kernel), the Axiom package manager, and `sysrebase` are
   PGSD-distribution work that happens to be coordinated with Awase
   development but does not belong in Awase's source tree.
   Conversely, Awase's substrate work does not require ZFS-specific
   testing.

The discipline doc's ZFS line should read accordingly: PGSD
requires ZFS; Awase accepts whatever filesystem PGSD provides; the
substrate has no ZFS-specific code.

## References

- `docs/AWASE_ARCHITECTURAL_DISCIPLINE.md`, accepted-dependency
  list. The "File persistence" entry references this document for
  the layering.
- `docs/FREEBSD_SUBSYSTEMS.md`, subsystem-by-subsystem accept /
  fence / replace classification. ZFS row references this
  document.
- `docs/AWASE_DAEMON_DEPENDENCY_ABSENCE.md`, daemon behaviour under
  storage failure (Posture 3 degradation pattern).
- `INSTALL.md` Step 1, `/var/run` tmpfs requirement.
- PGSD distribution: ZFS-required deployment context; tracked
  outside this repository (Axiom at github.com/pgsdf/axiom,
  sysrebase, PGSD installer).
- BACKLOG.md AD-5, the work item this document closes.
