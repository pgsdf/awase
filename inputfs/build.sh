#!/bin/sh
#
# inputfs build helper
#
# Goals:
#   - Make repo -> /usr/src installation reproducible
#   - Avoid "stale /usr/src tree" issues during iteration
#
# inputfs has no optional build features. The kernel module is built
# unconditionally from sys/dev/inputfs/inputfs.c plus inputfs_parser.c,
# both copied into /usr/src/sys/dev/inputfs/ via the install verb.
#
# This script is the parallel of drawfs/build.sh. Same verbs, same
# structure, adapted for inputfs's test layout (test/<stage>/*.sh
# rather than tests/test_*.py).
#
# IMPORTANT: do not add `inputfs_load="YES"` to /boot/loader.conf.
# inputfs's state kthread starts before /var/run is mounted when
# loaded that early, and panics. Use `kldload inputfs` post-boot
# instead. See INSTALL.md hazard 1 for the full recovery story.
#
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# OS detection — prefer env-inherited values from the parent build.sh /
# install.sh, fall back to local detection when run standalone.
if [ -z "${UTF_OS:-}" ]; then
    . "$REPO_ROOT/../scripts/detect-os.sh"
fi

SRCROOT=${SRCROOT:-/usr/src}

DEVDEST="$SRCROOT/sys/dev/inputfs"
MODDEST="$SRCROOT/sys/modules/inputfs"
KMODDIR="$MODDEST"

BANNER="[inputfs kernel module] [${UTF_OS:-unknown}]"

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
  sudo ./build.sh test b5            # run B.5 verification
  sudo ./build.sh test c             # run C verification
  sudo ./build.sh test d             # run D verification
  sudo ./build.sh test fuzz          # run AD-9 fuzzing
  sudo ./build.sh all
  ./build.sh verify
  ./build.sh help

Commands:
  install  Copy inputfs sources into /usr/src kernel tree
  build    Compile inputfs.ko from kernel sources
  deploy   Install inputfs.ko to /boot/modules/ (run after build)
  load     Load inputfs.ko from build directory (for testing)
  unload   Unload inputfs kernel module
  test     Run a stage verification protocol; argument selects stage
  all      install + build + deploy + load
  verify   Check source and build state without changing anything

Environment:
  SRCROOT=/usr/src   Root of FreeBSD source tree (default: /usr/src)

Loading inputfs at boot:
  Do NOT add `inputfs_load="YES"` to /boot/loader.conf — the state
  kthread panics when loaded before /var/run is mounted. Use
  /etc/rc.local to load after rootfs is up:
      kldload inputfs
  See INSTALL.md hazard 1 for details.
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
    echo "Installing inputfs sources into $SRCROOT"
    echo "$BANNER"
    mkdir -p "$DEVDEST" "$MODDEST"
    rsync -a --delete "$REPO_ROOT/sys/dev/inputfs/" "$DEVDEST/"
    rsync -a --delete "$REPO_ROOT/sys/modules/inputfs/" "$MODDEST/"
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
    KO="$OBJDIR/inputfs.ko"
    if [ ! -f "$KO" ]; then
      echo "ERROR: missing $KO"
      echo "Run: sudo ./build.sh build"
      exit 1
    fi
    echo "Loading $KO"
    kldunload inputfs 2>/dev/null || true
    kldload "$KO"
    echo "OK: load"
    ;;

  deploy)
    need_root "$cmd"
    echo "Installing inputfs.ko to /boot/modules/"
    echo "$BANNER"

    KO=""

    # Try make install first (cleanest approach)
    if ( cd "$KMODDIR" && make install ) 2>/dev/null; then
        echo "OK: deploy (via make install)"
        kldxref /boot/modules
        echo ""
        if [ -f /usr/local/etc/rc.d/inputfs ]; then
            echo "To load now:           service inputfs start"
            echo "Loaded automatically at boot via rc.d (installed by install.sh)."
        else
            echo "To load now (manual): kldload inputfs"
            echo "WARNING: do NOT add inputfs_load=\"YES\" to /boot/loader.conf;"
            echo "         see INSTALL.md hazard 1."
            echo ""
            echo "Run install.sh to set up the rc.d service so inputfs starts"
            echo "automatically at boot (REQUIRE: FILESYSTEMS, AD-12.3)."
        fi
        exit 0
    fi

    # Fall back to locating the .ko manually
    OBJDIR=$(make -C "$KMODDIR" -V .OBJDIR 2>/dev/null || echo "")
    if [ -n "$OBJDIR" ] && [ -f "$OBJDIR/inputfs.ko" ]; then
        KO="$OBJDIR/inputfs.ko"
    fi

    # Last resort: search common FreeBSD obj tree locations
    if [ -z "$KO" ]; then
        for candidate in \
            /usr/obj/usr/src/amd64.amd64/sys/modules/inputfs/inputfs.ko \
            /usr/obj/usr/src/arm64.aarch64/sys/modules/inputfs/inputfs.ko \
            /usr/obj/usr/src/sys/modules/inputfs/inputfs.ko
        do
            if [ -f "$candidate" ]; then
                KO="$candidate"
                break
            fi
        done
    fi

    # Search anywhere under /usr/obj as a final fallback
    if [ -z "$KO" ]; then
        KO=$(find /usr/obj -name "inputfs.ko" 2>/dev/null | head -1)
    fi

    if [ -z "$KO" ] || [ ! -f "$KO" ]; then
        echo "ERROR: inputfs.ko not found — run: sudo ./build.sh build"
        exit 1
    fi

    echo "Found: $KO"
    cp "$KO" /boot/modules/inputfs.ko
    kldxref /boot/modules
    echo "OK: deploy"
    echo ""
    if [ -f /usr/local/etc/rc.d/inputfs ]; then
        echo "To load now:           service inputfs start"
        echo "Loaded automatically at boot via rc.d (installed by install.sh)."
    else
        echo "To load now (manual): kldload inputfs"
        echo "WARNING: do NOT add inputfs_load=\"YES\" to /boot/loader.conf;"
        echo "         see INSTALL.md hazard 1."
        echo ""
        echo "Run install.sh to set up the rc.d service so inputfs starts"
        echo "automatically at boot (REQUIRE: FILESYSTEMS, AD-12.3)."
    fi
    ;;

  unload)
    need_root "$cmd"
    kldunload inputfs 2>/dev/null || true
    echo "OK: unload"
    ;;

  test)
    # Stage-keyed verification. Each stage has its own protocol under
    # test/<stage>/. The argument is the stage name; default "d" runs
    # the most recent (Stage D) verification, which exercises the
    # full substrate.
    need_root "$cmd"
    stage=${1:-d}
    case "$stage" in
      b5)
        # B.5 has bare-metal and VM variants. The bare-metal script is
        # the authoritative one; the VM variant exists for development
        # without hardware. Default to bare-metal here.
        SCRIPT="$REPO_ROOT/test/b5/b5-verify-baremetal.sh"
        ;;
      c)
        SCRIPT="$REPO_ROOT/test/c/c-verify.sh"
        ;;
      d)
        SCRIPT="$REPO_ROOT/test/d/d-verify.sh"
        ;;
      fuzz)
        SCRIPT="$REPO_ROOT/test/fuzz/fuzz-verify.sh"
        ;;
      *)
        echo "ERROR: unknown stage: $stage"
        echo "       valid stages: b5, c, d, fuzz"
        exit 1
        ;;
    esac
    if [ ! -f "$SCRIPT" ]; then
      echo "ERROR: verification script not found: $SCRIPT"
      exit 1
    fi
    echo "--- Running $stage verification ($SCRIPT) ---"
    sh "$SCRIPT"
    echo "OK: test $stage"
    ;;

  all)
    # install + build + deploy + load. Does NOT run tests because the
    # "all" verb in CI/install contexts wants a deterministic, fast
    # path; tests are stage-specific and need explicit invocation.
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
    echo "Repo dev inputfs.c:"
    ls -l "$REPO_ROOT/sys/dev/inputfs/inputfs.c" 2>/dev/null || echo "  not found"
    echo "Installed dev inputfs.c:"
    ls -l "$DEVDEST/inputfs.c" 2>/dev/null || echo "  not found"
    echo
    echo "Module OBJDIR:"
    OBJDIR=$(make -C "$KMODDIR" -V .OBJDIR 2>/dev/null || echo "unknown")
    echo "  $OBJDIR"
    echo "Built module:"
    ls -l "$OBJDIR/inputfs.ko" 2>/dev/null || echo "  not found — run: sudo ./build.sh build"
    echo "/boot/modules/inputfs.ko:"
    ls -l /boot/modules/inputfs.ko 2>/dev/null || echo "  not found — run: sudo ./build.sh deploy"
    echo "Loaded:"
    kldstat 2>/dev/null | grep inputfs || echo "  not loaded"
    echo
    echo "loader.conf check (should NOT contain inputfs_load):"
    if grep -q "inputfs_load" /boot/loader.conf 2>/dev/null; then
      echo "  WARNING: inputfs_load found in /boot/loader.conf — REMOVE IT"
      echo "  see INSTALL.md hazard 1"
    else
      echo "  ok  no inputfs_load in /boot/loader.conf"
    fi
    ;;

  *)
    echo "Unknown command: $cmd"
    echo
    usage
    exit 2
    ;;
esac
