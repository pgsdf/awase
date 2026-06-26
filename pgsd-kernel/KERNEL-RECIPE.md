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

On the bench:

    # Clone the fork at the pinned commit into /usr/src (or elsewhere and
    # point SRC_DIR at it).
    git clone https://github.com/pgsdf/freebsd-src /usr/src
    git -C /usr/src checkout <delta_commit from FREEBSD-PIN>

    # Confirm the tree satisfies the pin (also run automatically by the
    # build check below).
    git -C /usr/src rev-parse HEAD     # must equal delta_commit

## Build the PGSD kernel

    sudo install -m 0644 pgsd-kernel/PGSD /usr/src/sys/amd64/conf/PGSD
    sh pgsd-kernel/pgsd-kernel-build.sh check     # verifies the pin
    sudo sh pgsd-kernel/pgsd-kernel-build.sh build --clean
    sudo sh pgsd-kernel/pgsd-kernel-build.sh install

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
