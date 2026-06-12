#!/bin/sh
# UTF OS detection helper. Sourced, not executed.
#
# UTF targets PGSD, a distribution founded on FreeBSD. This script
# distinguishes a FreeBSD host from anything else, primarily so that
# build banners and configure messages can name the running system
# accurately. The detection is intentionally minimal; UTF does not
# branch build behavior on OS variants.
#
# Usage:
#   . "$(dirname "$0")/scripts/detect-os.sh"
#   echo "$UTF_OS"             # "freebsd" | "ghostbsd" | "unknown"
#   echo "$UTF_OS_VERSION"     # e.g. "15.0-RELEASE"
#
# This script only sets variables. It does not print, exit, or
# side-effect.
#
# GhostBSD reports uname -s = FreeBSD (it is FreeBSD-derived), so
# the uname check alone cannot distinguish the two. GhostBSD ships
# a ghostbsd-version(1) helper analogous to freebsd-version(1);
# stock FreeBSD does not. Probing for that binary is the canonical
# distinguishing test.

if [ "$(uname -s 2>/dev/null)" = "FreeBSD" ]; then
    if command -v ghostbsd-version >/dev/null 2>&1; then
        UTF_OS="ghostbsd"
        UTF_OS_VERSION="$(ghostbsd-version 2>/dev/null || uname -r)"
    else
        UTF_OS="freebsd"
        UTF_OS_VERSION="$(freebsd-version 2>/dev/null || uname -r)"
    fi
else
    UTF_OS="unknown"
    UTF_OS_VERSION="$(uname -sr 2>/dev/null || echo unknown)"
fi

export UTF_OS UTF_OS_VERSION
