# pgsd-kernel/patches

Home for base FreeBSD source patches (modifications to FreeBSD's own
kernel source) that are NOT yet carried as commits in the fork
(https://github.com/pgsdf/freebsd-src), for example a one-off patch under
review. The CANONICAL delta mechanism under AD-57 (Git-backed amendment)
is fork commits; this directory is a staging area and is empty by design
when all deltas live in the fork.

This is NOT for Awase's own kernel modules (inputfs/sys, drawfs/sys,
audiofs/sys): those are self-contained project source, not deltas against
FreeBSD, and are version-controlled in this repository directly.

Patches here are ordered and classified (definitional vs investigational)
per AD-57. See pgsd-kernel/KERNEL-RECIPE.md.
