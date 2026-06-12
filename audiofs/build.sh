#!/bin/sh
#
# audiofs build helper
#
# Goals:
#   - Make repo -> /usr/src installation reproducible
#   - Avoid "stale /usr/src tree" issues during iteration
#
# audiofs has no optional build features. The kernel module is built
# unconditionally from sys/dev/audiofs/audiofs.c, copied into
# /usr/src/sys/dev/audiofs/ via the install verb.
#
# This script is the parallel of inputfs/build.sh and drawfs/build.sh:
# same verbs, same structure, adapted for audiofs.
#
# IMPORTANT: do not add `audiofs_load="YES"` to /boot/loader.conf
# during commit-1-through-commit-N substrate-bring-up. The driver
# is still EXPERIMENTAL per ADR 0008 / AD-3, and a regressive
# revision in boot autoload would force a single-user-mode recovery.
# Use `kldload audiofs` post-boot via this script's `load` verb
# instead. This precaution may be relaxed in a future commit once
# audiofs is audit-cleared and ratified.
#
# Precondition: the PGSD kernel must be built without snd_hda.
# See pgsd-kernel/PGSD and pgsd-kernel/pgsd-kernel-build.sh; the
# `device snd_hda` line is removed from the kernel config and
# `hda` is in WITHOUT_MODULES_NAMES so the .ko file is also
# suppressed. With snd_hda present, the HDA controllers are
# claimed by hdac and audiofs's PCI probe never runs.
#
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# OS detection - prefer env-inherited values from the parent build.sh /
# install.sh, fall back to local detection when run standalone.
if [ -z "${UTF_OS:-}" ]; then
    . "$REPO_ROOT/../scripts/detect-os.sh"
fi

SRCROOT=${SRCROOT:-/usr/src}

DEVDEST="$SRCROOT/sys/dev/audiofs"
MODDEST="$SRCROOT/sys/modules/audiofs"
KMODDIR="$MODDEST"

BANNER="[audiofs kernel module] [${UTF_OS:-unknown}]"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root."
    echo "Try: sudo $0 $*"
    exit 1
  fi
}

usage() {
  cat <<'USAGE'
Usage:
  sudo ./build.sh install
  sudo ./build.sh build
  sudo ./build.sh deploy
  sudo ./build.sh load
  sudo ./build.sh unload
  sudo ./build.sh all
  ./build.sh verify
  ./build.sh help

Commands:
  install  Copy audiofs sources into /usr/src kernel tree
  build    Compile audiofs.ko from kernel sources
  deploy   Install audiofs.ko to /boot/modules/ (run after build)
  load     Load audiofs.ko from build directory (for testing)
  unload   Unload audiofs kernel module
  all      install + build + deploy + load
  verify   Check source and build state without changing anything

Environment:
  SRCROOT=/usr/src   Root of FreeBSD source tree (default: /usr/src)

Loading audiofs at boot:
  Do NOT add `audiofs_load="YES"` to /boot/loader.conf while audiofs
  remains experimental (AD-3, ADR 0008). Use this script's `load`
  verb post-boot, or `kldload audiofs` manually.
USAGE
}

cmd=${1:-help}
shift || true

case "$cmd" in
  help|-h|--help)
    usage
    ;;

  install)
    need_root "$cmd"
    echo "Installing audiofs sources into $SRCROOT"
    echo "$BANNER"
    mkdir -p "$DEVDEST" "$MODDEST"
    rsync -a --delete "$REPO_ROOT/sys/dev/audiofs/" "$DEVDEST/"
    rsync -a --delete "$REPO_ROOT/sys/modules/audiofs/" "$MODDEST/"
    echo "OK: install"
    ;;

  build)
    need_root "$cmd"
    echo "Building kernel module in $KMODDIR"
    echo "$BANNER"
    ( cd "$KMODDIR" && make clean && make )
    echo "OK: build"
    ;;

  load)
    need_root "$cmd"
    OBJDIR=$(make -C "$KMODDIR" -V .OBJDIR)
    KO="$OBJDIR/audiofs.ko"
    if [ ! -f "$KO" ]; then
      echo "ERROR: missing $KO"
      echo "Run: sudo ./build.sh build"
      exit 1
    fi
    echo "Loading $KO"
    kldunload audiofs 2>/dev/null || true
    kldload "$KO"
    echo "OK: load"
    ;;

  deploy)
    need_root "$cmd"
    echo "Installing audiofs.ko to /boot/modules/"
    echo "$BANNER"

    KO=""

    # Try make install first (cleanest approach)
    if ( cd "$KMODDIR" && make install ) 2>/dev/null; then
        echo "OK: deploy (via make install)"
        kldxref /boot/modules
        echo ""
        echo "To load now (manual): kldload audiofs"
        echo "WARNING: do NOT add audiofs_load=\"YES\" to /boot/loader.conf"
        echo "         while audiofs remains experimental (AD-3)."
        exit 0
    fi

    # Fall back to locating the .ko manually
    OBJDIR=$(make -C "$KMODDIR" -V .OBJDIR 2>/dev/null || echo "")
    if [ -n "$OBJDIR" ] && [ -f "$OBJDIR/audiofs.ko" ]; then
        KO="$OBJDIR/audiofs.ko"
    fi

    # Last resort: search common FreeBSD obj tree locations
    if [ -z "$KO" ]; then
        for candidate in \
            /usr/obj/usr/src/amd64.amd64/sys/modules/audiofs/audiofs.ko \
            /usr/obj/usr/src/arm64.aarch64/sys/modules/audiofs/audiofs.ko \
            /usr/obj/usr/src/sys/modules/audiofs/audiofs.ko
        do
            if [ -f "$candidate" ]; then
                KO="$candidate"
                break
            fi
        done
    fi

    # Search anywhere under /usr/obj as a final fallback
    if [ -z "$KO" ]; then
        KO=$(find /usr/obj -name "audiofs.ko" 2>/dev/null | head -1)
    fi

    if [ -z "$KO" ] || [ ! -f "$KO" ]; then
        echo "ERROR: audiofs.ko not found - run: sudo ./build.sh build"
        exit 1
    fi

    echo "Found: $KO"
    cp "$KO" /boot/modules/audiofs.ko
    kldxref /boot/modules
    echo "OK: deploy"
    echo ""
    echo "To load now (manual): kldload audiofs"
    echo "WARNING: do NOT add audiofs_load=\"YES\" to /boot/loader.conf"
    echo "         while audiofs remains experimental (AD-3)."
    ;;

  unload)
    need_root "$cmd"
    kldunload audiofs 2>/dev/null || true
    echo "OK: unload"
    ;;

  all)
    # install + build + deploy + load. Does NOT run tests because
    # audiofs has no test suite yet (the verify step is the only
    # post-load check available pre-commit-4).
    need_root "$cmd"
    "$0" install
    "$0" build
    "$0" deploy
    "$0" load
    ;;

  verify)
    echo "Repo root: $REPO_ROOT"
    echo "SRCROOT:   $SRCROOT"
    echo "Host OS:   ${UTF_OS:-unknown} ${UTF_OS_VERSION:-}"
    echo "$BANNER"
    echo
    echo "Repo dev audiofs.c:"
    ls -l "$REPO_ROOT/sys/dev/audiofs/audiofs.c" 2>/dev/null || echo "  not found"
    echo "Installed dev audiofs.c:"
    ls -l "$DEVDEST/audiofs.c" 2>/dev/null || echo "  not found"
    echo
    echo "Module OBJDIR:"
    OBJDIR=$(make -C "$KMODDIR" -V .OBJDIR 2>/dev/null || echo "unknown")
    echo "  $OBJDIR"
    echo "Built module:"
    ls -l "$OBJDIR/audiofs.ko" 2>/dev/null || echo "  not found - run: sudo ./build.sh build"
    echo "/boot/modules/audiofs.ko:"
    ls -l /boot/modules/audiofs.ko 2>/dev/null || echo "  not found - run: sudo ./build.sh deploy"
    echo "Loaded:"
    kldstat 2>/dev/null | grep audiofs || echo "  not loaded"
    echo
    echo "loader.conf check (should NOT contain audiofs_load while experimental):"
    if grep -q "audiofs_load" /boot/loader.conf 2>/dev/null; then
      echo "  WARNING: audiofs_load found in /boot/loader.conf - REMOVE IT"
      echo "  audiofs is experimental (AD-3); autoload at boot is not safe"
    else
      echo "  ok  no audiofs_load in /boot/loader.conf"
    fi
    echo
    echo "PGSD kernel snd_hda check (snd_hda MUST be absent for audiofs to bind):"
    if kldstat | grep -q snd_hda; then
      echo "  WARNING: snd_hda is loaded; audiofs will not bind to HDA"
      echo "  controllers while snd_hda owns them. Either kldunload snd_hda"
      echo "  or rebuild the PGSD kernel without snd_hda (pgsd-kernel/)."
    else
      echo "  ok  no snd_hda module loaded"
    fi
    ;;

  *)
    echo "Unknown command: $cmd"
    echo
    usage
    exit 2
    ;;
esac
