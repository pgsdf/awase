# PGSD kernel recipe (AD-57)

How to reconstruct the exact kernel the PGSD distribution is defined
against. This implements the AD-57 recipe model under the 2026-06-26
Git-backed representation amendment: the canonical kernel is a pinned
commit in a maintained fork of FreeBSD source, plus the PGSD kernel
config, built reproducibly.

## What defines the kernel

The canonical definition is the pin file, pgsd-kernel/FREEBSD-PIN. It is
authoritative; the fork branch is only a convenient pointer. Identity is
the immutable delta_commit, so a branch rename or rebase does not change
the definition.

  - base_repository: the maintained fork (https://github.com/pgsdf/freebsd-src).
  - base_commit: the upstream point the fork derives from (provenance).
  - delta_commit: the fork commit carrying the project deltas. This is
    the kernel source PGSD builds. With no base-source deltas yet, it
    equals the pristine upstream tree at the pinned release.
  - freebsd_release / freebsd_version_k: human-readable release identity,
    cross-checkable on any running system (uname -K, freebsd-version -k).

The awase repository embeds no FreeBSD source; it references the fork.
This preserves "derive, do not embed" while giving commit-level
provenance.

## Reconstruct the source tree

The simplest way is to let the installer provision it. `sh install.sh`
reads FREEBSD-PIN, clones the fork on its `base_branch` (`releng/15.1`),
checks out the pinned `delta_commit`, and chowns `/usr/src` to you. Do
this by hand only if you want to see the steps or place the tree
somewhere other than `/usr/src`.

By hand, on the bench (values from FREEBSD-PIN; substitute the current
ones rather than copying these):

    # Clone the fork on the pinned branch, then pin to the exact commit.
    # The branch (base_branch, releng/15.1) selects the starting point;
    # the commit (delta_commit) fixes identity and is what the pin check
    # enforces. Do not use --single-branch: a future delta_commit may
    # live on a differently named fork branch, and a full clone keeps the
    # commit checkout working regardless.
    git clone --branch releng/15.1 https://github.com/pgsdf/freebsd-src /usr/src
    git -C /usr/src checkout 96841ea08dcfa84b954a32dc5ae1a26c28966cf4
    sudo chown -R "$(id -u):$(id -g)" /usr/src
    git config --global --add safe.directory /usr/src

    # Confirm the tree satisfies the pin (also run automatically by the
    # build check below).
    git -C /usr/src rev-parse HEAD       # must equal delta_commit
    git -C /usr/src describe --tags      # release/15.1.0 (provenance)
    uname -K                             # 1501000, matches freebsd_version_k

A pkgbase release tree (`pkg install src`) or a plain
`git.freebsd.org` checkout is release-level source, not the pinned
fork; it satisfies the release cross-check but fails the AD-57 commit
pin. Build against it only with PGSD_ALLOW_UNPINNED=1, accepting
release-level reproducibility.

## Build the PGSD kernel

This recipe is the sole kernel path: `install.sh` detects and reports
the kernel state but never builds or installs one (ADR 0002
milestone 1). Run the `install` phase only after `sh install.sh` has
deployed the userland; the AD-8 closure check refuses to install the
kernel until `/boot/modules/drawfs.ko` is on disk.

    sh pgsd-kernel/pgsd-kernel-build.sh check     # verifies the pin
    sudo sh pgsd-kernel/pgsd-kernel-build.sh build --clean
    sudo sh pgsd-kernel/pgsd-kernel-build.sh install

The PGSD config is an Awase artifact and stays in `pgsd-kernel/`; the
build reads it in place via `make`'s `KERNCONFDIR`, so `/usr/src` is
never modified and remains a faithful checkout of the pinned revision.
Do NOT copy the config into `/usr/src/sys/amd64/conf/`: that mutates
the tree and, being untracked in the fork, shows up as pin drift that
the check then rejects. If an older build left a stale
`/usr/src/sys/amd64/conf/PGSD`, remove it (`sudo rm -f
/usr/src/sys/amd64/conf/PGSD`); the check flags it.

The check phase enforces the pin (AD-57): it fails if /usr/src does not
match the recorded commit, unless PGSD_ALLOW_UNPINNED=1 is set for
deliberate, non-reproducible investigation.

## Deltas

Base-source modifications (patches to FreeBSD's own kernel source, as
opposed to Awase's self-contained out-of-tree modules under
inputfs/sys, drawfs/sys, audiofs/sys) live as commits in the fork, not
in the awase repository. Today there are none: PGSD is a config plus
module suppression and adds no base-source changes. The pgsd-kernel/patches/
directory exists as the documented home for any base-source delta that is
NOT carried in the fork (for example a one-off patch under review before
it lands in the fork); the canonical mechanism is fork commits.

Deltas are classified (AD-57 section 3):

  - definitional: part of what PGSD is, permanent.
  - investigational: transient research artifacts (for example AD-56
    Phase 0.5 instrumentation), removable once the investigation
    concludes. An investigational delta advances delta_commit on a
    clearly named branch (for example awase/ad56-phase05-instrumentation)
    and is recorded by the investigation that used it, so its kernel is
    reproducible from the pin alone.

## Advancing the pin

Advancing to a newer FreeBSD base (security, new release) is OPERATIONAL
practice, not architectural (AD-57): update the fork to the new upstream
point, record the new commit in FREEBSD-PIN. How the fork is kept current
(merge, rebase, fast-forward, recreate) is not prescribed.
