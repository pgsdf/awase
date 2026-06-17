#!/bin/sh
# UTF install script
# Builds all daemons and installs them to PREFIX (default: /usr/local).
#
# Usage:
#   sh install.sh                  # install to /usr/local (requires root)
#   sh install.sh --prefix ~/utf   # install to custom prefix
#   sh install.sh --check          # verify dependencies only
#   sh install.sh --uninstall      # remove installed files
#   sh install.sh --yes            # non-interactive; assume yes for prompts
#   sh install.sh --allow-semadraw-term  # proceed even if launched from semadraw-term
#
# Installed binaries:
#   $PREFIX/bin/semadrawd     : semantic rendering compositor
#   $PREFIX/bin/chrono_dump   : chronofs diagnostic tool
#   $PREFIX/bin/semasound     : audio mixing broker (AD-3)
#   $PREFIX/bin/semasound-tone : semasound test tone client
#   $PREFIX/bin/semasound-dump : semasound state surface inspector

set -eu

# ============================================================================
# Configuration
# ============================================================================

PREFIX="/usr/local"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNINSTALL=0
CHECK_ONLY=0
ASSUME_YES=0
ALLOW_SEMADRAW_TERM=0

# Detect OS early so all downstream messages and the drawfs build inherit
# UTF_OS and UTF_OS_VERSION via the environment.
. "$SCRIPT_DIR/scripts/detect-os.sh"
echo "Host OS: $UTF_OS $UTF_OS_VERSION"

BINARIES="semadrawd chrono_dump semadraw-term inputdump utf-log-cleanup pgsd-sessiond semasound semasound-tone semasound-dump"

# ============================================================================
# Argument parsing
# ============================================================================

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            PREFIX="$2"; shift 2 ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"; shift ;;
        --uninstall)
            UNINSTALL=1; shift ;;
        --check)
            CHECK_ONLY=1; shift ;;
        --yes|-y)
            ASSUME_YES=1; shift ;;
        --allow-semadraw-term)
            ALLOW_SEMADRAW_TERM=1; shift ;;
        --help|-h)
            sed -n '2,15p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ============================================================================
# AD-12.1 footgun guard: refuse when launched from inside semadraw-term
# ============================================================================
#
# The install (and uninstall) stops semadrawd to replace daemon binaries.
# semadraw-term draws through semadrawd, so when this script is launched from
# a semadraw-term the display freezes the instant semadrawd is stopped and
# only returns after the post-install restart. That looks exactly like a hang
# at "Installing to PREFIX/bin", and a mistaken Ctrl-C mid-install (semadrawd
# down, binaries half-swapped) is the real hazard. Detect the case and steer
# the operator to a session that does not depend on semadrawd, e.g. SSH.
#
# Detection is by process ancestry, not an environment variable. This script
# normally runs under sudo, which scrubs the environment by default, so a
# SEMADRAW_TERM marker exported to the child shell does not survive into this
# process. Walking the parent-pid chain from $$ does survive sudo, since
# sudo's parent is the operator's shell whose ancestor is the semadraw-term
# process. The SEMADRAW_TERM marker is honoured too as a cheap secondary
# signal for sudo -E or env_keep setups.
running_inside_semadraw_term() {
    [ -n "${SEMADRAW_TERM:-}" ] && return 0
    _pid=$$
    _hops=0
    while [ "${_pid:-0}" -gt 1 ] && [ "$_hops" -lt 24 ]; do
        _comm=$(ps -o comm= -p "$_pid" 2>/dev/null) || break
        case "$_comm" in
            *semadraw-term*) return 0 ;;
        esac
        _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
        [ -n "$_pid" ] || break
        _hops=$((_hops + 1))
    done
    return 1
}

if [ "$CHECK_ONLY" -eq 0 ] && [ "$ALLOW_SEMADRAW_TERM" -eq 0 ] \
   && running_inside_semadraw_term && pgrep -x semadrawd >/dev/null 2>&1; then
    echo "" >&2
    echo "ERROR: install.sh appears to be running inside a semadraw-term session" >&2
    echo "       while semadrawd is running." >&2
    echo "" >&2
    echo "       This install stops semadrawd to replace its binary. semadraw-term" >&2
    echo "       draws through semadrawd, so the display would freeze at" >&2
    echo "       \"Installing to $PREFIX/bin\" until semadrawd is restarted at the" >&2
    echo "       end of the install. It is not hung, but it looks like one, and a" >&2
    echo "       mistaken Ctrl-C mid-install is dangerous." >&2
    echo "" >&2
    echo "       Re-run from a session that does not depend on semadrawd, e.g. SSH:" >&2
    echo "         ssh <user>@<host>" >&2
    echo "         cd $SCRIPT_DIR && sudo sh install.sh" >&2
    echo "" >&2
    echo "       Or, if you understand the freeze and will wait it out:" >&2
    echo "         sudo sh install.sh --allow-semadraw-term" >&2
    echo "" >&2
    exit 1
fi

# ============================================================================
# Dependency check
# ============================================================================

check_dep() {
    if command -v "$1" >/dev/null 2>&1; then
        echo "  ok  $1 ($(command -v "$1"))"
        return 0
    else
        echo "  -- $1 not found"
        return 1
    fi
}

echo "=== Checking dependencies ==="

# MISSING_PKGS is populated with the package names that need to be
# installed before the build can proceed. Each binary check translates
# to a package name on FreeBSD/GhostBSD via pkg(8). The consent step
# offers to install everything in MISSING_PKGS; binaries already
# present get no entry.
MISSING_PKGS=""

# The Zig compiler is vendored at sdk/zig/current and invoked only through
# tools/zig (bootstrapped on first use); the build never uses a system Zig,
# so it is not a pkg dependency. Report the pinned toolchain version.
ZIG_VER=$("$SCRIPT_DIR/tools/zig" version 2>/dev/null | head -1)
echo "  ok  vendored zig $ZIG_VER (sdk/zig/current)"

# AD-20: s6 supervision suite. The s6 package provides all five
# binaries (svscan, svc, svstat, svok, log); a single pkg install
# brings them all in. Check one binary and treat its absence as
# the whole-package absence signal.
if ! check_dep s6-svscan; then
    MISSING_PKGS="$MISSING_PKGS s6"
fi

# rsync is required by drawfs/build.sh and inputfs/build.sh during
# kernel module deployment. Not in FreeBSD base; must come from pkg.
if ! check_dep rsync; then
    MISSING_PKGS="$MISSING_PKGS rsync"
fi

# Strip leading whitespace from MISSING_PKGS for cleaner display.
MISSING_PKGS="${MISSING_PKGS# }"

# --check is a read-only inspection: report and exit, without
# attempting any installation.
if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -z "$MISSING_PKGS" ]; then
        echo "All dependencies present."
        exit 0
    else
        echo ""
        echo "Missing packages: $MISSING_PKGS"
        echo "Install with: sudo pkg install -y $MISSING_PKGS"
        exit 1
    fi
fi

# ============================================================================
# Root check
# ============================================================================
#
# Operations from this point on modify system state (write to /etc/fstab,
# call pw useradd, install files under PREFIX, register rc.d scripts).
# All require root. Bail early with a clear message rather than letting
# individual operations fail downstream in confusing ways.

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: install.sh requires root for system-level installation." >&2
    echo "       re-run as: sudo sh install.sh" >&2
    echo "       or use --check to verify dependencies without installing." >&2
    exit 1
fi

# ============================================================================
# /var/run tmpfs prerequisite
# ============================================================================
#
# UTF publishes shared-memory regions under /var/run/sema/. The defaults
# on FreeBSD put /var/run on the same filesystem as /var, which makes
# shared-memory writes slower and leaves stale state files across reboots.
# UTF assumes tmpfs.
#
# Idempotent: only add the fstab entry if not already present, only mount
# if not already mounted as tmpfs. INSTALL.md Step 1 documents the manual
# version of these steps for operators who prefer to make the change
# themselves.

FSTAB_ENTRY="tmpfs   /var/run   tmpfs   rw,mode=755   0   0"

if ! grep -qE "^[[:space:]]*tmpfs[[:space:]]+/var/run[[:space:]]+tmpfs" /etc/fstab; then
    printf "%s\n" "$FSTAB_ENTRY" >> /etc/fstab
    echo "  added /var/run tmpfs entry to /etc/fstab"
else
    echo "  ok  /etc/fstab already has /var/run tmpfs entry"
fi

if ! mount | grep -qE "^tmpfs on /var/run "; then
    if mount /var/run 2>/dev/null; then
        echo "  mounted /var/run as tmpfs"
    else
        echo "ERROR: failed to mount /var/run as tmpfs" >&2
        echo "       check /etc/fstab and try: sudo mount /var/run" >&2
        exit 1
    fi
else
    echo "  ok  /var/run already mounted as tmpfs"
fi

# ============================================================================
# OS-specific source-tree packages
# ============================================================================
#
# Building the PGSD kernel and the drawfs/inputfs modules requires the
# OS source tree at /usr/src. On FreeBSD this comes from FreeBSD-src
# and FreeBSD-src-sys; on GhostBSD from GhostBSD-src and GhostBSD-src-sys.
# These are pkgbase package names. Add them to MISSING_PKGS only if not
# already installed.

check_pkg_installed() {
    pkg info -e "$1" >/dev/null 2>&1
}

case "$UTF_OS" in
    freebsd)
        for p in FreeBSD-src FreeBSD-src-sys; do
            if ! check_pkg_installed "$p"; then
                MISSING_PKGS="$MISSING_PKGS $p"
                echo "  -- $p not installed"
            else
                echo "  ok  $p installed"
            fi
        done
        ;;
    ghostbsd)
        for p in GhostBSD-src GhostBSD-src-sys; do
            if ! check_pkg_installed "$p"; then
                MISSING_PKGS="$MISSING_PKGS $p"
                echo "  -- $p not installed"
            else
                echo "  ok  $p installed"
            fi
        done
        ;;
    *)
        echo "  ?? unknown OS ($UTF_OS); skipping source-tree package check"
        ;;
esac

MISSING_PKGS="${MISSING_PKGS# }"

# ============================================================================
# Consent and package install
# ============================================================================
#
# If anything in MISSING_PKGS, offer to pkg-install. The consent step
# uses bsddialog when running interactively (TTY on stdin and stdout,
# --yes not passed). When non-interactive without --yes, bail with a
# clear message rather than silently modifying the system.
#
# pkg install failures are warned about, not fatal: the operator can
# install missing packages manually and re-run install.sh.

if [ -n "$MISSING_PKGS" ]; then
    INTERACTIVE=0
    if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
        INTERACTIVE=1
    fi

    if [ "$INTERACTIVE" -eq 1 ]; then
        # bsddialog must be available for the consent dialog.
        if ! command -v bsddialog >/dev/null 2>&1; then
            echo "ERROR: bsddialog not found; required for interactive consent." >&2
            echo "       install with: sudo pkg install -y bsddialog" >&2
            echo "       or re-run install.sh with --yes to skip the dialog." >&2
            exit 1
        fi

        # Build a human-readable summary for the dialog body.
        dialog_body="The following packages are not installed:

$(printf "    %s\n" $MISSING_PKGS)

Install them now via pkg(8)?

(Choose No to abort; install the packages manually and re-run.)"

        if ! bsddialog --title "UTF installer: package installation" \
                       --yesno "$dialog_body" 15 60; then
            echo "ABORTED: user declined package install" >&2
            exit 1
        fi
    elif [ "$ASSUME_YES" -eq 0 ]; then
        # Non-interactive without --yes: refuse to act.
        echo "ERROR: missing packages and not running interactively." >&2
        echo "       missing: $MISSING_PKGS" >&2
        echo "       re-run as: sudo sh install.sh --yes" >&2
        echo "       or install the packages first and re-run:" >&2
        echo "         sudo pkg install -y $MISSING_PKGS" >&2
        exit 1
    fi

    # Apply installations. Each pkg install runs independently and any
    # failure is warned, not fatal: the user may want to install a
    # subset manually and re-run.
    echo "=== Installing missing packages ==="
    INSTALL_FAILED=""
    for pkg_name in $MISSING_PKGS; do
        echo "  installing $pkg_name..."
        if pkg install -y "$pkg_name" 2>&1 | tail -3; then
            if check_pkg_installed "$pkg_name"; then
                echo "  ok  $pkg_name installed"
            else
                INSTALL_FAILED="$INSTALL_FAILED $pkg_name"
                echo "  WARN: $pkg_name install completed but pkg info -e disagrees"
            fi
        else
            INSTALL_FAILED="$INSTALL_FAILED $pkg_name"
            echo "  WARN: pkg install $pkg_name returned non-zero"
        fi
    done

    if [ -n "$INSTALL_FAILED" ]; then
        echo "" >&2
        echo "WARNING: the following packages did not install cleanly:" >&2
        echo "  $INSTALL_FAILED" >&2
        echo "  install them manually and re-run install.sh if the build fails." >&2
    fi
fi

# ============================================================================
# Uninstall
# ============================================================================

if [ "$UNINSTALL" -eq 1 ]; then
    # ADR 0030 Decision 4 (the takeover protocol, uninstall direction):
    # stop supervision BEFORE removing anything it owns. Removing the
    # scan tree or the daemon binaries while s6-svscan is running
    # orphans the supervise processes and the daemons; the next
    # install then has to SIGKILL the survivors.
    echo "=== Stopping supervision (ADR 0030 Decision 4) ==="
    if [ -f "$PREFIX/etc/rc.d/utf-supervisor" ] && service utf-supervisor status >/dev/null 2>&1; then
        service utf-supervisor stop >/dev/null 2>&1 \
            && echo "  stopped  utf-supervisor (supervision tree torn down)" \
            || echo "  WARNING: utf-supervisor stop reported failure; continuing"
    elif pgrep -f "s6-svscan /var/service/utf" >/dev/null 2>&1; then
        /usr/local/bin/s6-svscanctl -t /var/service/utf 2>/dev/null \
            && echo "  stopped  s6-svscan (direct)" \
            || echo "  WARNING: s6-svscanctl signal failed; continuing"
    else
        echo "  skip     supervision (not running)"
    fi
    sleep 1

    echo "=== Uninstalling from $PREFIX/bin/ ==="
    for bin in $BINARIES; do
        target="$PREFIX/bin/$bin"
        if [ -f "$target" ]; then
            rm -f "$target"
            echo "  removed  $target"
        else
            echo "  skip     $target (not found)"
        fi
    done

    RCDDIR="$PREFIX/etc/rc.d"
    for svc in inputfs audiofs utf-supervisor semaaud semadraw pgsd-sessiond semasound; do
        target="$RCDDIR/$svc"
        if [ -f "$target" ]; then
            rm -f "$target"
            echo "  removed  $target"
        else
            echo "  skip     $target (not found)"
        fi
    done

    # AD-32 / AD-25 Round 1 follow-up: remove the periodic daily
    # script. The directory itself ($PREFIX/etc/periodic/daily/) is
    # not removed since other ports may use it.
    PERIODIC_TARGET="$PREFIX/etc/periodic/daily/500.utf-log-cleanup"
    if [ -f "$PERIODIC_TARGET" ]; then
        rm -f "$PERIODIC_TARGET"
        echo "  removed  $PERIODIC_TARGET"
    else
        echo "  skip     $PERIODIC_TARGET (not found)"
    fi

    # Session files. Remove the default.session this script ships and the
    # sessions dir if it ends up empty; leave any operator-added .session
    # files (and the parent share/pgsd if other assets remain) in place.
    SESSIONS_DIR="$PREFIX/share/pgsd/sessions"
    DEFAULT_SESSION_TARGET="$SESSIONS_DIR/default.session"
    if [ -f "$DEFAULT_SESSION_TARGET" ]; then
        rm -f "$DEFAULT_SESSION_TARGET"
        echo "  removed  $DEFAULT_SESSION_TARGET"
    else
        echo "  skip     $DEFAULT_SESSION_TARGET (not found)"
    fi
    if [ -d "$SESSIONS_DIR" ]; then
        rmdir "$SESSIONS_DIR" 2>/dev/null && echo "  removed  $SESSIONS_DIR" || true
        rmdir "$PREFIX/share/pgsd" 2>/dev/null || true
    fi

    # AD-20: remove the s6 supervision tree at /var/service/utf/.
    # We do not remove /var/log/utf/; those logs may be useful for
    # postmortem inspection. Operators who want a clean slate should
    # rm -rf /var/log/utf/ themselves (documented in INSTALL.md
    # Uninstall section).
    SVC_ROOT="/var/service/utf"
    if [ -d "$SVC_ROOT" ]; then
        rm -rf "$SVC_ROOT"
        echo "  removed  $SVC_ROOT"
    else
        echo "  skip     $SVC_ROOT (not found)"
    fi

    echo ""
    echo "=== Disabling daemons in /etc/rc.conf ==="
    sysrc -x inputfs_enable 2>/dev/null        && echo "  removed  inputfs_enable"        || echo "  skip     inputfs_enable (not set)"
    sysrc -x utf_supervisor_enable 2>/dev/null && echo "  removed  utf_supervisor_enable" || echo "  skip     utf_supervisor_enable (not set)"
    sysrc -x semaaud_enable 2>/dev/null        && echo "  removed  semaaud_enable"        || echo "  skip     semaaud_enable (not set)"
    # F.6 (ADR 0029): semaaud is retired; remove a stale binary from any
    # pre-retirement install (its rc script and rc.conf key are handled by
    # the lists above, which retain semaaud as cleanup targets).
    rm -f "$PREFIX/bin/semaaud" 2>/dev/null && echo "  removed  $PREFIX/bin/semaaud (retired)" || true
    sysrc -x semainput_enable 2>/dev/null      && echo "  removed  semainput_enable"      || echo "  skip     semainput_enable (not set)"
    sysrc -x semadraw_enable 2>/dev/null       && echo "  removed  semadraw_enable"       || echo "  skip     semadraw_enable (not set)"
    sysrc -x pgsd_sessiond_enable 2>/dev/null  && echo "  removed  pgsd_sessiond_enable"  || echo "  skip     pgsd_sessiond_enable (not set)"
    sysrc -x audiofs_enable 2>/dev/null        && echo "  removed  audiofs_enable"        || echo "  skip     audiofs_enable (not set)"
    sysrc -x semasound_enable 2>/dev/null      && echo "  removed  semasound_enable"      || echo "  skip     semasound_enable (not set)"

    echo ""
    echo "=== Removing drawfs from /boot/loader.conf ==="
    if grep -q "drawfs_load" /boot/loader.conf 2>/dev/null; then
        sed -i '' '/drawfs_load/d' /boot/loader.conf
        echo "  removed  drawfs_load from /boot/loader.conf"
    else
        echo "  skip     drawfs_load (not found)"
    fi

    # Safety net: install.sh never adds inputfs_load to loader.conf
    # (the kernel module panics when loaded that early; see INSTALL.md
    # hazard 1). But a user may have added it by hand, hit the panic,
    # and reinstalled. Strip it on uninstall as a defensive cleanup so
    # any future install attempt starts from a clean state.
    if grep -q "inputfs_load" /boot/loader.conf 2>/dev/null; then
        sed -i '' '/inputfs_load/d' /boot/loader.conf
        echo "  removed  inputfs_load from /boot/loader.conf (defensive cleanup)"
    fi

    # AD-31.4 part A: remove utf_devices devfs ruleset.
    echo ""
    echo "=== Removing devfs rule for /dev/draw ==="
    DEVFS_RULES="/etc/devfs.rules"
    DEVFS_BEGIN="# BEGIN utf_devices managed by install.sh"
    DEVFS_END="# END utf_devices managed by install.sh"
    if [ -f "$DEVFS_RULES" ] && grep -qF "$DEVFS_BEGIN" "$DEVFS_RULES"; then
        sed -i '' "/^${DEVFS_BEGIN}$/,/^${DEVFS_END}$/d" "$DEVFS_RULES"
        echo "  removed  utf_devices block from $DEVFS_RULES"
    else
        echo "  skip     utf_devices block (not present)"
    fi
    # Only unset devfs_system_ruleset if it currently points at
    # utf_devices; leave alone if the operator pointed it elsewhere.
    if [ "$(sysrc -n devfs_system_ruleset 2>/dev/null)" = "utf_devices" ]; then
        sysrc -x devfs_system_ruleset >/dev/null 2>&1 \
            && echo "  removed  devfs_system_ruleset from /etc/rc.conf"
    else
        echo "  skip     devfs_system_ruleset (not set to utf_devices)"
    fi
    # Apply the change live so the running session reverts to
    # default devfs permissions.
    if service devfs restart >/dev/null 2>&1; then
        echo "  applied  devfs restart"
    else
        echo "  WARNING: service devfs restart failed during uninstall" >&2
    fi

    echo "=== Done ==="
    exit 0
fi

# ============================================================================
# Build
# ============================================================================

# AD-50 hardening: warn (not abort) if the s6 service sources in the
# working tree have uncommitted modifications. install deploys these
# files verbatim into /var/service; the AD-50 incident reached
# production by deploying a dirty, corrupted semasound/run. Warning
# (not error) keeps intentional local testing possible while making
# accidental dirt visible before it ships.
if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    s6_dirty=$(git -C "$SCRIPT_DIR" status --porcelain -- s6/ 2>/dev/null || true)
    if [ -n "$s6_dirty" ]; then
        echo "WARNING (AD-50): uncommitted changes in s6/ will be deployed verbatim:" >&2
        echo "$s6_dirty" | sed 's/^/    /' >&2
    fi
fi

echo "=== Building UTF (optimize=ReleaseSafe) ==="

# Read .config early so drawfs/build.sh sees DRAWFS_DRM via environment.
# Default is false: swap-only kernel build, zero drm-kmod dependency.
CONFIG="$SCRIPT_DIR/.config"
DRAWFS_DRM="${DRAWFS_DRM:-false}"
if [ -f "$CONFIG" ]; then
    echo "Reading configuration from $CONFIG"
    . "$CONFIG"
    DRAWFS_DRM="${DRAWFS_DRM:-false}"
fi
export DRAWFS_DRM
echo "drawfs DRM/KMS backend: ${DRAWFS_DRM}"

# Build drawfs kernel module first
echo ""
echo "--- Building drawfs kernel module ---"
if [ -f "$SCRIPT_DIR/drawfs/build.sh" ]; then
    sh "$SCRIPT_DIR/drawfs/build.sh" install
    sh "$SCRIPT_DIR/drawfs/build.sh" build
    sh "$SCRIPT_DIR/drawfs/build.sh" deploy
else
    echo "WARNING: drawfs/build.sh not found, skipping kernel module"
fi

# Build inputfs kernel module. Mirrors the drawfs pattern: install
# sources into /usr/src/sys/, build, deploy to /boot/modules/.
# Unlike drawfs, inputfs is NOT auto-loaded from /boot/loader.conf:
# the state kthread panics when loaded before /var/run is mounted.
# The deploy step explicitly does not add inputfs_load. See
# INSTALL.md hazard 1.
echo ""
echo "--- Building inputfs kernel module ---"
if [ -f "$SCRIPT_DIR/inputfs/build.sh" ]; then
    sh "$SCRIPT_DIR/inputfs/build.sh" install
    sh "$SCRIPT_DIR/inputfs/build.sh" build
    sh "$SCRIPT_DIR/inputfs/build.sh" deploy
else
    echo "WARNING: inputfs/build.sh not found, skipping kernel module"
fi

# F.5.f (ADR 0028): build the audiofs kernel module for semasound.
# Same install/build/deploy pattern as drawfs and inputfs. Like
# inputfs, audiofs is NOT auto-loaded from /boot/loader.conf: it
# publishes its event region under /var/run, so loading is deferred
# to the audiofs rc.d service (REQUIRE: FILESYSTEMS) below.
echo ""
echo "--- Building audiofs kernel module ---"
if [ -f "$SCRIPT_DIR/audiofs/build.sh" ]; then
    sh "$SCRIPT_DIR/audiofs/build.sh" install
    sh "$SCRIPT_DIR/audiofs/build.sh" build
    sh "$SCRIPT_DIR/audiofs/build.sh" deploy
else
    echo "WARNING: audiofs/build.sh not found, skipping kernel module"
fi

# Semadraw backend flags. DRAWFS_DRM was already consumed above for the kernel
# build; here we pick up the semadraw userspace backend selections.
SEMADRAW_FLAGS=""
if [ -f "$CONFIG" ]; then
    [ "${SEMADRAW_VULKAN:-false}"   = "true"  ] && SEMADRAW_FLAGS="$SEMADRAW_FLAGS -Dvulkan=true"
    [ "${SEMADRAW_VULKAN:-false}"   = "false" ] && SEMADRAW_FLAGS="$SEMADRAW_FLAGS -Dvulkan=false"
    [ "${SEMADRAW_X11:-false}"      = "true"  ] && SEMADRAW_FLAGS="$SEMADRAW_FLAGS -Dx11=true"
    [ "${SEMADRAW_WAYLAND:-false}"  = "true"  ] && SEMADRAW_FLAGS="$SEMADRAW_FLAGS -Dwayland=true"
    [ "${SEMADRAW_BSDINPUT:-false}" = "true"  ] && SEMADRAW_FLAGS="$SEMADRAW_FLAGS -Dbsdinput=true"
    [ "${SEMADRAW_BSDINPUT:-false}" = "false" ] && SEMADRAW_FLAGS="$SEMADRAW_FLAGS -Dbsdinput=false"
else
    echo "No .config found; using defaults (run sh configure.sh to configure)"
fi

build_sub() {
    name="$1"
    dir="$SCRIPT_DIR/$2"
    shift 2
    echo ""
    echo "--- Building $name ---"
    cd "$dir"
    "$SCRIPT_DIR/tools/zig" build -Doptimize=ReleaseSafe "$@"
    cd "$SCRIPT_DIR"
}

build_sub "semadraw"  "semadraw"  $SEMADRAW_FLAGS
build_sub "chronofs"  "chronofs"
build_sub "inputfs (userland)" "inputfs"
build_sub "pgsd-sessiond" "pgsd-sessiond"
build_sub "semasound" "semasound"

# ============================================================================
# Install
# ============================================================================

echo ""
echo "=== Installing to $PREFIX/bin/ ==="
mkdir -p "$PREFIX/bin"

# AD-12.1: Stop running daemons before replacing binaries.
#
# `cp` cannot replace a binary that is currently being executed (FreeBSD
# returns ETXTBSY, "Text file busy"). The pre-AD-12.1 behaviour was to
# bail out partway through the install with a confusing error, leaving
# the operator to manually stop services and re-run install.sh. This
# block records which services were running, stops them with
# confirmation, and the corresponding restart block at the end of the
# script brings them back. Services that were not running before the
# install are left stopped.
#
# rc.d's "stop" subcommand sends SIGTERM and trusts the daemon to die.
# We add a wait-with-timeout to confirm death; if a daemon does not
# exit within RESTART_TIMEOUT seconds, we SIGKILL it and warn.
#
# Determining "is running" via `service NAME status` works regardless
# of whether the operator started it via service or via direct
# invocation: pgrep on the binary name catches both.
SERVICES_TO_RESTART=""
INPUTFS_WAS_LOADED=0
DRAWFS_WAS_LOADED=0
UTF_SUPERVISOR_WAS_RUNNING=0
RESTART_TIMEOUT=5

# Note inputfs's load state before we touch anything. inputfs.ko is a
# kernel module, not a userland daemon: the file on disk can be replaced
# while it's loaded (the running module keeps using its in-memory image),
# so we don't need to unload it for the binary install. But if the
# operator has already started using inputfs and they're running this
# install.sh to upgrade userland, the post-install restart block should
# restart inputfs too; bumping it onto the new module file gives them
# the upgrade they probably wanted.
# Match the kld file (inputfs.ko) via -n, not the module name
# via -m. DRIVER_MODULE registers the module as 'hidbus/inputfs',
# so 'kldstat -q -m inputfs' is always false even when loaded;
# the old predicate meant INPUTFS_WAS_LOADED never got set and
# the post-install refresh block never ran, silently leaving the
# operator on the old module image after a userland upgrade.
if kldstat -q -n inputfs.ko 2>/dev/null; then
    INPUTFS_WAS_LOADED=1
fi

# Same for drawfs. drawfs.ko is auto-loaded from /boot/loader.conf
# (drawfs_load=YES), so on any system that's been booted with drawfs
# present it will be loaded. Without bumping it onto the new module
# file, every install.sh invocation would silently leave the operator
# running yesterday's drawfs in kernel memory while today's
# drawfs.ko sits on disk unused (the trap that hid the AD-18.1 panic
# fix during 2026-05-07 bench testing).
if kldstat -q -m drawfs 2>/dev/null; then
    DRAWFS_WAS_LOADED=1
fi

# AD-20: same for utf-supervisor (the s6-svscan launcher). Track its
# state so the post-install restart block knows to bring it up before
# the daemon shims (which require it).
if [ -f /var/run/utf-supervisor.pid ] && \
   kill -0 "$(cat /var/run/utf-supervisor.pid 2>/dev/null)" 2>/dev/null; then
    UTF_SUPERVISOR_WAS_RUNNING=1
fi

stop_service_if_running() {
    svc="$1"   # rc.d service name (semasound, semadraw)
    bin="$2"   # binary name as it appears in `ps` (semasound, semadrawd)
    if pgrep -x "$bin" >/dev/null 2>&1; then
        echo "  stopping  $svc (was running)"
        # Try the rc.d stop first; falls through to direct kill if rc.d
        # path is missing or fails.
        if [ -f "$PREFIX/etc/rc.d/$svc" ] || [ -f "/etc/rc.d/$svc" ]; then
            service "$svc" stop >/dev/null 2>&1 || true
        fi
        # Wait for the process to actually die.
        waited=0
        while pgrep -x "$bin" >/dev/null 2>&1; do
            if [ "$waited" -ge "$RESTART_TIMEOUT" ]; then
                echo "  WARNING: $bin did not exit within ${RESTART_TIMEOUT}s, sending SIGKILL" >&2
                pkill -9 -x "$bin" 2>/dev/null || true
                sleep 1
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done
        SERVICES_TO_RESTART="$SERVICES_TO_RESTART $svc"
    fi
}

stop_service_if_running semadraw  semadrawd

# SM-1.9: also stop pgsd-sessiond if it was running. Same pattern
# as semadraw above; the run script in /var/service/utf/pgsd-sessiond/
# is what s6-supervise execs, and we need to replace it.
stop_service_if_running pgsd-sessiond pgsd-sessiond

# F.5.f: same pattern for semasound; its run script under
# /var/service/utf/semasound/ is replaced by this install.
stop_service_if_running semasound semasound

# AD-20: also stop utf-supervisor itself if it was running. The
# stop_service_if_running calls above only stopped the *daemons*; the
# s6-svscan supervisor process is still alive. Stopping it now lets us
# replace the scan-directory tree at /var/service/utf/ without
# s6-supervise processes contending. The post-install restart block
# brings everything back up in the correct order.
if [ "$UTF_SUPERVISOR_WAS_RUNNING" -eq 1 ]; then
    echo "  stopping  utf-supervisor (was running)"
    if [ -f "$PREFIX/etc/rc.d/utf-supervisor" ] || [ -f "/etc/rc.d/utf-supervisor" ]; then
        service utf-supervisor stop >/dev/null 2>&1 || true
    fi
    # Wait for the supervisor pid to exit, with timeout.
    waited=0
    while [ -f /var/run/utf-supervisor.pid ] && \
          kill -0 "$(cat /var/run/utf-supervisor.pid 2>/dev/null)" 2>/dev/null; do
        if [ "$waited" -ge "$RESTART_TIMEOUT" ]; then
            echo "  WARNING: utf-supervisor did not exit within ${RESTART_TIMEOUT}s, sending SIGKILL" >&2
            pid=$(cat /var/run/utf-supervisor.pid 2>/dev/null)
            [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
            sleep 1
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    rm -f /var/run/utf-supervisor.pid
fi

# install_bin: copy a built binary into PREFIX/bin atomically.
#
# The copy goes to a sibling temp path (.NEW suffix), gets its mode
# set, then is renamed over the destination. rename(2) is atomic on
# the same filesystem, so the destination is either the old version
# (if anything before the rename failed) or the new version (if the
# rename succeeded). Avoids partial-replacement states on disk-full,
# operator interrupt, or other mid-copy failures.
install_bin() {
    src="$1"
    dst="$PREFIX/bin/$(basename "$src")"
    tmp="$dst.NEW.$$"
    if [ -f "$src" ]; then
        cp "$src" "$tmp" || {
            echo "  ERROR: cp $src $tmp failed" >&2
            rm -f "$tmp"
            return 1
        }
        chmod 755 "$tmp"
        mv "$tmp" "$dst" || {
            echo "  ERROR: mv $tmp $dst failed" >&2
            rm -f "$tmp"
            return 1
        }
        echo "  installed  $dst"
    else
        echo "  WARNING: $src not found - skipping" >&2
    fi
}

# AD-26.1 follow-up (2026-05-11): hard-fail variant of install_bin for
# binaries we know must be built. install_bin's WARNING-and-skip
# behaviour is acceptable for genuinely optional artifacts, but for
# the core UTF binaries a missing source means the build silently
# failed to produce the expected artifact and we should refuse to
# proceed rather than ship a stale /usr/local/bin/.
#
# This guards against the failure mode hit on 2026-05-11: the
# install printed "installed /usr/local/bin/semadraw-term" because
# the previous build's artifact still existed at the source path,
# even though the current build had not produced it. (In that
# specific case the source content had not changed and Zig's cache
# was a no-op; the WARNING path was not actually triggered. The
# concern remains valid for the broader class: any failure that
# leaves a stale zig-out/bin/semadraw-term will be silently shipped
# under the current install_bin behaviour.)
install_bin_required() {
    src="$1"
    if [ ! -f "$src" ]; then
        echo "" >&2
        echo "ERROR: required artifact $src not found." >&2
        echo "       The build for the corresponding subproject did not" >&2
        echo "       produce the expected binary. Refusing to install" >&2
        echo "       a partial set of UTF binaries; the running daemons" >&2
        echo "       would be a mix of old and new." >&2
        echo "" >&2
        echo "       Investigate the build output above for failures." >&2
        echo "       Try: sh clean.sh --force && sh install.sh" >&2
        exit 1
    fi
    install_bin "$src"
}

install_bin_required "$SCRIPT_DIR/semadraw/zig-out/bin/semadrawd"
install_bin_required "$SCRIPT_DIR/chronofs/zig-out/bin/chrono_dump"
install_bin_required "$SCRIPT_DIR/semadraw/zig-out/bin/semadraw-term"
install_bin_required "$SCRIPT_DIR/inputfs/zig-out/bin/inputdump"

# SM-1.9: pgsd-sessiond graphical login daemon. Installed
# alongside the other UTF binaries. Stage 9a wires it under s6
# supervision via the per-service files in s6/awase/pgsd-sessiond/
# and the rc.d wrapper generated below.
install_bin_required "$SCRIPT_DIR/pgsd-sessiond/zig-out/bin/pgsd-sessiond"
install_bin_required "$SCRIPT_DIR/semasound/zig-out/bin/semasound"
install_bin_required "$SCRIPT_DIR/semasound/zig-out/bin/semasound-tone"
install_bin_required "$SCRIPT_DIR/semasound/zig-out/bin/semasound-dump"

# AD-32 / AD-25 Round 1 follow-up: operator helper for compacting
# s6-log-managed log directories. Not a built binary; it is the
# shell script at scripts/utf-log-cleanup directly. install_bin
# copies it to /usr/local/bin/utf-log-cleanup (the basename in
# the repo has no .sh extension to match the deployed-tool
# convention, like semadraw-term and chrono_dump). See
# scripts/utf-log-cleanup for the script itself and the periodic
# section below for the daily wrapper.
install_bin_required "$SCRIPT_DIR/scripts/utf-log-cleanup"

# AD-2a Phase 3 step 2: semainputd was retired 2026-05-08. On systems
# upgraded from a pre-retirement install, /usr/local/bin/semainputd
# still exists from the prior install_bin call. Reap it here so the
# orphan binary doesn't linger. Same self-healing pattern as the
# $SVC_ROOT/semainputd and $LOG_ROOT/semainputd reapers below.
if [ -f "$PREFIX/bin/semainputd" ]; then
    rm -f "$PREFIX/bin/semainputd"
    echo "  removed    $PREFIX/bin/semainputd (retired)"
fi

# ============================================================================
# Session files (ADR 0004)
# ============================================================================
#
# pgsd-sessiond resolves the user's selected session id to
# $PREFIX/share/pgsd/sessions/<id>.session and FATALLY exits if the file is
# missing (EXIT_SESSION_NOT_FOUND). Under supervision that exit looks like a
# bounce: the operator types a correct password, the daemon dies, the
# supervisor respawns a fresh login screen, and no error survives the restart.
# The default picker choice (.terminal) maps to the id "default", so a working
# install must ship default.session. This was previously laid down only by the
# bench-only install-bench.sh, so production installs had no sessions dir.
#
# Installed if-absent: an operator who has customised default.session keeps
# their version across upgrades. Other .session files they add are untouched.

SESSIONS_DIR="$PREFIX/share/pgsd/sessions"
echo ""
echo "=== Installing session files to $SESSIONS_DIR/ ==="
mkdir -p "$SESSIONS_DIR"
DEFAULT_SESSION_SRC="$SCRIPT_DIR/pgsd-sessiond/share/sessions/default.session"
DEFAULT_SESSION_DST="$SESSIONS_DIR/default.session"
if [ -f "$DEFAULT_SESSION_DST" ]; then
    echo "  skip      $DEFAULT_SESSION_DST (exists; not overwriting)"
elif [ -f "$DEFAULT_SESSION_SRC" ]; then
    if cp "$DEFAULT_SESSION_SRC" "$DEFAULT_SESSION_DST"; then
        chmod 0644 "$DEFAULT_SESSION_DST"
        echo "  installed $DEFAULT_SESSION_DST"
    else
        echo "  WARNING: failed to install $DEFAULT_SESSION_DST" >&2
    fi
else
    echo "  WARNING: $DEFAULT_SESSION_SRC missing from source tree; skipping" >&2
fi

# ============================================================================
# rc.d scripts (FreeBSD service integration)
# ============================================================================

RCDDIR="$PREFIX/etc/rc.d"
if [ -d /etc/rc.d ] || [ -d "$RCDDIR" ]; then
    echo ""
    echo "=== Installing rc.d service scripts to $RCDDIR/ ==="
    mkdir -p "$RCDDIR"

    # AD-2a Phase 3 step 2: semainputd was retired 2026-05-08. On
    # systems upgraded from a pre-retirement install, the rc.d shim
    # at $RCDDIR/semainput is left from the prior heredoc-generation
    # block. Reap it so an orphan rc.d file doesn't linger. Same
    # self-healing pattern as the $SVC_ROOT/$LOG_ROOT reapers.
    if [ -f "$RCDDIR/semainput" ]; then
        rm -f "$RCDDIR/semainput"
        echo "  removed    $RCDDIR/semainput (retired)"
    fi

    cat > "$RCDDIR/inputfs" << RCEOF
#!/bin/sh
# PROVIDE: inputfs inputfs_loaded
# REQUIRE: FILESYSTEMS
# KEYWORD: shutdown

# AD-12.3: rc.d service for inputfs.
#
# inputfs cannot be loaded via /boot/loader.conf because the module's
# kthread starts publishing state files before /var before /var/run is
# mounted, panicking on AT_FDCWD. INSTALL.md Hazard 1 documents this.
# This rc.d service deferred load to userland-startup time avoids the
# bug: REQUIRE: FILESYSTEMS guarantees /var/run is mounted before
# kldload runs.
#
# AD-12.2: PROVIDE: 'inputfs_loaded' is the abstract capability name
# that consumer daemons express dependency on (REQUIRE: inputfs_loaded).
# 'inputfs' is the service name; 'inputfs_loaded' future-proofs the
# rcorder graph so a future implementation could provide the same
# capability without consumer rc.d edits. Replaces the previous
# 'BEFORE: semadraw semainput' line, which expressed the inverse
# relationship (provider declaring consumer dependency); consumers
# now express their own dependency via REQUIRE:.

. /etc/rc.subr
name="inputfs"
rcvar="inputfs_enable"
: \${inputfs_enable:="NO"}

start_cmd="inputfs_start"
stop_cmd="inputfs_stop"
status_cmd="inputfs_status"

inputfs_start() {
    # Match the kld FILE (inputfs.ko) via -n, not the module
    # name via -m. DRIVER_MODULE(inputfs, hidbus, ...) registers
    # the module as 'hidbus/inputfs', so 'kldstat -q -m inputfs'
    # never matches even when inputfs.ko is loaded (analogous to
    # siis.ko containing siis/siisch + pci/siis). The old -m
    # predicate made this guard always false: inputfs_start would
    # kldload unconditionally and inputfs_status would always
    # report "not loaded". See kldstat(8): -n filename, -m modname.
    if kldstat -q -n inputfs.ko; then
        echo "\${name} already loaded."
        return 0
    fi
    echo "Loading \${name}."
    kldload inputfs
}

inputfs_stop() {
    if ! kldstat -q -n inputfs.ko; then
        echo "\${name} not loaded."
        return 0
    fi
    echo "Unloading \${name}."
    kldunload inputfs
}

inputfs_status() {
    if kldstat -q -n inputfs.ko; then
        echo "\${name} is loaded."
    else
        echo "\${name} is not loaded."
        return 1
    fi
}

load_rc_config \$name
run_rc_command "\$1"
RCEOF
    chmod 555 "$RCDDIR/inputfs"
    echo "  installed  $RCDDIR/inputfs"

    cat > "$RCDDIR/audiofs" << RCEOF
#!/bin/sh
# PROVIDE: audiofs audiofs_loaded utf_clock
# REQUIRE: FILESYSTEMS
# KEYWORD: shutdown

# F.6 (ADR 0029 Decision 2): this service PROVIDEs utf_clock. Loading
# the audiofs module starts the kernel writer of /var/run/sema/clock
# (F.4, ADR 0018), so the module-load service is the capability's
# provider. The AD-12.2 convention works as designed: semadraw's
# REQUIRE: utf_clock is unchanged and now orders against audiofs.

# F.5.f (ADR 0028): rc.d service for the audiofs kernel module.
# Same shape and rationale as inputfs above: the module publishes
# its event region under /var/run, so loading is deferred to
# userland-startup time (REQUIRE: FILESYSTEMS), never loader.conf.
# 'audiofs_loaded' is the abstract capability consumers REQUIRE
# (semasound's shim does), per the AD-12.2 naming convention.

. /etc/rc.subr
name="audiofs"
rcvar="audiofs_enable"
: \${audiofs_enable:="NO"}

start_cmd="audiofs_start"
stop_cmd="audiofs_stop"
status_cmd="audiofs_status"

audiofs_start() {
    # Match the kld FILE via -n (see the inputfs note above on -m).
    if kldstat -q -n audiofs.ko; then
        echo "\${name} already loaded."
        return 0
    fi
    echo "Loading \${name}."
    kldload audiofs
}

audiofs_stop() {
    if ! kldstat -q -n audiofs.ko; then
        echo "\${name} not loaded."
        return 0
    fi
    echo "Unloading \${name}."
    kldunload audiofs
}

audiofs_status() {
    if kldstat -q -n audiofs.ko; then
        echo "\${name} is loaded."
    else
        echo "\${name} is not loaded."
        return 1
    fi
}

load_rc_config \$name
run_rc_command "\$1"
RCEOF
    chmod 555 "$RCDDIR/audiofs"
    echo "  installed  $RCDDIR/audiofs"

    # ========================================================================
    # AD-20: utf-supervisor rc.d entry, launches s6-svscan against the
    # UTF scan directory at /var/service/utf/. This is the single
    # supervision-tree entry point for UTF; the three daemon rc.d files
    # below are thin shims that translate to s6-svc commands against
    # the running tree.
    #
    # Uses standard rc.subr with command=daemon(8). On SIGTERM, daemon(8)
    # forwards to s6-svscan, which gracefully tears down the tree (per
    # skarnet.org/software/s6/s6-svscan.html: SIGTERM stops all
    # supervised services, waits for the tree to drain, execs into
    # .s6-svscan/finish or exits 0).
    #
    # No -r flag on daemon(8): if s6-svscan itself exits abnormally,
    # something is seriously broken; operator intervention rather than
    # silent restart is the right response.
    # ========================================================================

    cat > "$RCDDIR/utf-supervisor" << RCEOF
#!/bin/sh
# PROVIDE: utf_supervisor
# REQUIRE: FILESYSTEMS
# KEYWORD: shutdown

# AD-20: starts s6-svscan against /var/service/utf. The two UTF
# daemon rc.d files (semasound, semadraw) REQUIRE: this so
# rcorder(8) brings it up first. Without it, s6-supervise processes
# don't exist for the daemon shims to talk to.

. /etc/rc.subr

name="utf_supervisor"
rcvar="utf_supervisor_enable"
: \${utf_supervisor_enable:="NO"}

# AD-20.3: ensure /usr/local/bin is in PATH for s6-svscan's children.
#
# Empirically diagnosed on bare metal 2026-05-06: when launched via
# rc.d, s6-svscan starts but cannot spawn s6-supervise children. Its
# stderr (captured at /var/log/utf/svscan.log) prints repeated:
#
#   s6-svscan: warning: unable to spawn s6-supervise for <name>:
#     No such file or directory
#
# Root cause: the FreeBSD port of s6 (sysutils/s6, 2.14.0.1) compiles
# s6-svscan with S6_EXTBINPREFIX as the empty string. s6-svscan calls
# cspawn("s6-supervise", ...) which delegates to posix_spawnp, which
# does PATH lookup. rc.subr's default PATH on FreeBSD is
# /sbin:/bin:/usr/sbin:/usr/bin; it does NOT include /usr/local/bin
# where s6-supervise actually lives. The lookup fails with ENOENT.
#
# Manual sudo invocations of the same daemon(8) command work because
# the operator shell's PATH includes /usr/local/bin. Direct
# invocation of s6-supervise by absolute path also works. Only the
# rc.d-launched path is broken, and only because of PATH inheritance.
#
# The fix: prepend /usr/local/bin to PATH here. daemon(8) inherits
# this PATH and propagates it to s6-svscan, which then finds
# s6-supervise via posix_spawnp.
PATH="/usr/local/bin:\${PATH}"
export PATH

scan_dir="/var/service/utf"
pidfile="/var/run/utf-supervisor.pid"

# AD-20.3: -o /var/log/utf/svscan.log captures s6-svscan's own
# stderr (informational messages and warnings about failed spawns).
# Per-service logs still flow through s6-log into
# /var/log/utf/<name>/current as designed. We do not pass -f to
# daemon(8): operationally either choice would work, but -o needs
# valid stdio fds at exec time and we want s6-svscan's diagnostic
# output to survive (precisely how this AD-20.3 PATH bug got
# diagnosed).
command="/usr/sbin/daemon"
command_args="-P \${pidfile} -o /var/log/utf/svscan.log /usr/local/bin/s6-svscan \${scan_dir}"

start_precmd="utf_supervisor_precmd"
status_cmd="utf_supervisor_status"

utf_supervisor_precmd() {
    if [ ! -d "\${scan_dir}" ]; then
        echo "ERROR: scan directory \${scan_dir} does not exist." >&2
        echo "Re-run install.sh to create it." >&2
        return 1
    fi
    return 0
}

utf_supervisor_status() {
    if [ -r "\${pidfile}" ] && \\
       kill -0 "\$(cat "\${pidfile}" 2>/dev/null)" 2>/dev/null; then
        echo "utf-supervisor is running as pid \$(cat \${pidfile})."
        echo "scan dir: \${scan_dir}"
        if [ -d "\${scan_dir}" ]; then
            echo "supervised services:"
            for svc in "\${scan_dir}"/*/; do
                [ -d "\$svc" ] || continue
                svc_name=\$(basename "\$svc")
                case "\$svc_name" in .*) continue ;; esac
                printf "  %-15s " "\$svc_name"
                /usr/local/bin/s6-svstat "\$svc" 2>/dev/null || echo "(svstat failed)"
            done
        fi
    else
        echo "utf-supervisor is not running."
        return 1
    fi
}

load_rc_config \$name
run_rc_command "\$1"
RCEOF
    chmod 555 "$RCDDIR/utf-supervisor"
    echo "  installed  $RCDDIR/utf-supervisor"

    # ========================================================================
    # AD-20: thin shim rc.d wrappers for the three UTF daemons.
    # Each translates `service <name> {start|stop|restart|status}` to
    # the corresponding s6-svc command against /var/service/utf/<name>.
    # The shims preserve the existing operator interface; the actual
    # supervision is done by s6.
    # ========================================================================


    cat > "$RCDDIR/semasound" << RCEOF
#!/bin/sh
# PROVIDE: semasound
# REQUIRE: utf_supervisor audiofs_loaded

# F.5.f (ADR 0028): thin shim for semasound, the AD-3 audio mixing
# broker. Predecessor retired under F.6 (ADR 0029). It does not
# provide utf_clock: that capability belongs to the audiofs rc
# service (the module load starts the kernel clock writer, ADR
# 0018/0029); semasound is a clock consumer like every other daemon.

. /etc/rc.subr

name="semasound"
rcvar="semasound_enable"
: \${semasound_enable:="NO"}

PATH="/usr/local/bin:\${PATH}"
export PATH

svc_dir="/var/service/utf/semasound"

start_cmd="semasound_start"
stop_cmd="semasound_stop"
status_cmd="semasound_status"
restart_cmd="semasound_restart"

semasound_start() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        echo "ERROR: s6-supervise not running on \${svc_dir}." >&2
        echo "Run 'service utf-supervisor start' first." >&2
        return 1
    fi
    echo "Starting \${name} via s6-svc -uwu (timeout 5s)..."
    /usr/local/bin/s6-svc -uwu -T 5000 "\${svc_dir}"
}

semasound_stop() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        if [ "\$(id -u)" -ne 0 ] && [ ! -r "\${svc_dir}/supervise" ]; then
            echo "\${name}: supervise state unreadable (mode 0700); run with sudo." >&2
            return 1
        fi
        echo "\${name} not under supervision."
        return 0
    fi
    echo "Stopping \${name} via s6-svc -dwd (timeout 5s)..."
    /usr/local/bin/s6-svc -dwd -T 5000 "\${svc_dir}"
}

semasound_restart() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        echo "ERROR: s6-supervise not running on \${svc_dir}." >&2
        return 1
    fi
    /usr/local/bin/s6-svc -r "\${svc_dir}"
}

semasound_status() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        if [ "\$(id -u)" -ne 0 ] && [ ! -r "\${svc_dir}/supervise" ]; then
            echo "\${name}: supervise state unreadable (mode 0700); run with sudo." >&2
            return 1
        fi
        echo "\${name} not under supervision."
        return 1
    fi
    /usr/local/bin/s6-svstat "\${svc_dir}"
}

load_rc_config \$name
run_rc_command "\$1"
RCEOF
    chmod 555 "$RCDDIR/semasound"
    echo "  installed  $RCDDIR/semasound"

    cat > "$RCDDIR/semadraw" << RCEOF
#!/bin/sh
# PROVIDE: semadraw
# REQUIRE: utf_supervisor utf_clock inputfs_loaded

# AD-20: thin shim for semadrawd. Same shape as the shims above.
# Note that the framebuffer-resolution detection that previously
# lived in this rc.d script (semadraw_detect_resolution under
# AD-15.1 / AD-17) now lives in /var/service/utf/semadrawd/run.
# The detection substrate is unchanged (sysctl
# hw.drawfs.efifb.{width,height}); only the location moved.

. /etc/rc.subr

name="semadraw"
rcvar="semadraw_enable"
: \${semadraw_enable:="NO"}

# AD-20.3: PATH fix; same reasoning as the shims above.
PATH="/usr/local/bin:\${PATH}"
export PATH

svc_dir="/var/service/utf/semadrawd"

start_cmd="semadraw_start"
stop_cmd="semadraw_stop"
status_cmd="semadraw_status"
restart_cmd="semadraw_restart"

semadraw_start() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        echo "ERROR: s6-supervise not running on \${svc_dir}." >&2
        echo "Run 'service utf-supervisor start' first." >&2
        return 1
    fi
    echo "Starting \${name} via s6-svc -uwu (timeout 5s)..."
    /usr/local/bin/s6-svc -uwu -T 5000 "\${svc_dir}"
}

semadraw_stop() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        if [ "\$(id -u)" -ne 0 ] && [ ! -r "\${svc_dir}/supervise" ]; then
            echo "\${name}: supervise state unreadable (mode 0700); run with sudo." >&2
            return 1
        fi
        echo "\${name} not under supervision."
        return 0
    fi
    echo "Stopping \${name} via s6-svc -dwd (timeout 5s)..."
    /usr/local/bin/s6-svc -dwd -T 5000 "\${svc_dir}"
}

semadraw_restart() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        echo "ERROR: s6-supervise not running on \${svc_dir}." >&2
        return 1
    fi
    /usr/local/bin/s6-svc -r "\${svc_dir}"
}

semadraw_status() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        if [ "\$(id -u)" -ne 0 ] && [ ! -r "\${svc_dir}/supervise" ]; then
            echo "\${name}: supervise state unreadable (mode 0700); run with sudo." >&2
            return 1
        fi
        echo "\${name} not under supervision."
        return 1
    fi
    /usr/local/bin/s6-svstat "\${svc_dir}"
}

load_rc_config \$name
run_rc_command "\$1"
RCEOF
    chmod 555 "$RCDDIR/semadraw"
    echo "  installed  $RCDDIR/semadraw"

    # ========================================================================
    # SM-1.9: rc.d wrapper for pgsd-sessiond. Thin shim same shape
    # as semadraw above. REQUIRE chain depends on semadraw because
    # pgsd-sessiond is a semadraw client; without semadrawd up, the
    # connection to /var/run/sema-draw fails and pgsd-sessiond
    # bails out immediately. s6-supervise would then flap-protect
    # us and give up.
    # ========================================================================

    cat > "$RCDDIR/pgsd-sessiond" << RCEOF
#!/bin/sh
# PROVIDE: pgsd-sessiond
# REQUIRE: semadraw

# SM-1.9: thin shim for pgsd-sessiond under s6 supervision. Same
# shape as the semadraw wrapper above; the run script at
# /var/service/utf/pgsd-sessiond/run execs the daemon directly.

. /etc/rc.subr

name="pgsd_sessiond"
rcvar="pgsd_sessiond_enable"
: \${pgsd_sessiond_enable:="NO"}

# PATH fix; same reasoning as the semasound and semadraw shims.
PATH="/usr/local/bin:\${PATH}"
export PATH

svc_dir="/var/service/utf/pgsd-sessiond"

start_cmd="pgsd_sessiond_start"
stop_cmd="pgsd_sessiond_stop"
status_cmd="pgsd_sessiond_status"
restart_cmd="pgsd_sessiond_restart"

pgsd_sessiond_start() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        echo "ERROR: s6-supervise not running on \${svc_dir}." >&2
        echo "Run 'service utf-supervisor start' first." >&2
        return 1
    fi
    echo "Starting \${name} via s6-svc -uwu (timeout 5s)..."
    /usr/local/bin/s6-svc -uwu -T 5000 "\${svc_dir}"
}

pgsd_sessiond_stop() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        if [ "\$(id -u)" -ne 0 ] && [ ! -r "\${svc_dir}/supervise" ]; then
            echo "\${name}: supervise state unreadable (mode 0700); run with sudo." >&2
            return 1
        fi
        echo "\${name} not under supervision."
        return 0
    fi
    echo "Stopping \${name} via s6-svc -dwd (timeout 5s)..."
    /usr/local/bin/s6-svc -dwd -T 5000 "\${svc_dir}"
}

pgsd_sessiond_restart() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        echo "ERROR: s6-supervise not running on \${svc_dir}." >&2
        return 1
    fi
    /usr/local/bin/s6-svc -r "\${svc_dir}"
}

pgsd_sessiond_status() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        if [ "\$(id -u)" -ne 0 ] && [ ! -r "\${svc_dir}/supervise" ]; then
            echo "\${name}: supervise state unreadable (mode 0700); run with sudo." >&2
            return 1
        fi
        echo "\${name} not under supervision."
        return 1
    fi
    /usr/local/bin/s6-svstat "\${svc_dir}"
}

load_rc_config \$name
run_rc_command "\$1"
RCEOF
    chmod 555 "$RCDDIR/pgsd-sessiond"
    echo "  installed  $RCDDIR/pgsd-sessiond"

    # ========================================================================
    # AD-32 / AD-25 Round 1 follow-up: install the periodic(8) daily
    # wrapper for utf-log-cleanup. FreeBSD's periodic(8) runs every
    # script in /usr/local/etc/periodic/daily/ once per day at the
    # time configured by /etc/periodic.conf (default: 03:00 via cron).
    # The 500. prefix orders this within the daily batch (100-499 is
    # FreeBSD baseline; 500+ is the conventional ports/local range).
    #
    # The wrapper itself just calls /usr/local/bin/utf-log-cleanup
    # --trim, which deletes archived @*.s files in every s6-log-
    # shaped directory under /var/log/. current files are preserved.
    # ========================================================================

    PERIODIC_SRC="$SCRIPT_DIR/scripts/periodic/daily/500.utf-log-cleanup"
    PERIODIC_DST_DIR="$PREFIX/etc/periodic/daily"
    PERIODIC_DST="$PERIODIC_DST_DIR/500.utf-log-cleanup"

    if [ -f "$PERIODIC_SRC" ]; then
        echo ""
        echo "=== Installing periodic daily script to $PERIODIC_DST_DIR/ ==="
        mkdir -p "$PERIODIC_DST_DIR"
        cp "$PERIODIC_SRC" "$PERIODIC_DST"
        chmod 555 "$PERIODIC_DST"
        echo "  installed  $PERIODIC_DST"
    else
        echo "  WARNING: $PERIODIC_SRC not found; periodic wrapper not installed" >&2
    fi

    # ========================================================================
    # AD-20: install the s6 scan directory tree to /var/service/utf/
    # and create per-daemon log directories under /var/log/utf/.
    # ========================================================================

    SVC_ROOT="/var/service/utf"
    LOG_ROOT="/var/log/utf"
    S6_SRC="$SCRIPT_DIR/s6/awase"

    if [ ! -d "$S6_SRC" ]; then
        echo "ERROR: s6 source tree not found at $S6_SRC" >&2
        echo "The repository checkout looks incomplete; aborting." >&2
        exit 1
    fi

    echo ""
    echo "=== Installing s6 supervision tree to $SVC_ROOT ==="

    # Strategy: create the destination directories (mkdir -p is
    # idempotent and preserves any existing supervise/ runtime state),
    # then install the static files (run, finish, log/run). We do not
    # touch <svcdir>/supervise/ which is owned by s6-supervise.
    mkdir -p "$SVC_ROOT/.s6-svscan"
    cp "$S6_SRC/.s6-svscan/finish" "$SVC_ROOT/.s6-svscan/finish"
    chmod 755 "$SVC_ROOT/.s6-svscan/finish"
    echo "  installed  $SVC_ROOT/.s6-svscan/finish"

    # AD-2a Phase 3 step 2: semainputd was retired 2026-05-08. On
    # systems upgraded from a pre-retirement install, the
    # /var/service/utf/semainputd directory still exists with its
    # supervise/ runtime state. Reap it explicitly: ask s6-supervise
    # to exit cleanly first (s6-svc -dx with a short timeout, falling
    # through if s6-supervise isn't actually running on it), then
    # remove the directory tree. install.sh below only writes the
    # services it knows about; without this block the stale
    # semainputd directory would linger and s6-svscan would keep
    # restarting a service whose binary no longer exists.
    if [ -d "$SVC_ROOT/semainputd" ]; then
        if /usr/local/bin/s6-svok "$SVC_ROOT/semainputd" 2>/dev/null; then
            /usr/local/bin/s6-svc -dx -T 2000 "$SVC_ROOT/semainputd" 2>/dev/null || true
        fi
        rm -rf "$SVC_ROOT/semainputd"
        echo "  removed    $SVC_ROOT/semainputd (retired)"
    fi

    for svc_name in semadrawd pgsd-sessiond semasound; do
        svc_dst="$SVC_ROOT/$svc_name"
        svc_src="$S6_SRC/$svc_name"
        mkdir -p "$svc_dst/log"
        cp "$svc_src/run"        "$svc_dst/run"
        cp "$svc_src/finish"     "$svc_dst/finish"
        cp "$svc_src/log/run"    "$svc_dst/log/run"
        chmod 755 "$svc_dst/run" "$svc_dst/finish" "$svc_dst/log/run"
        echo "  installed  $svc_dst/{run,finish,log/run}"
    done

    # AD-50 hardening: verify each deployed run script execs the
    # binary its slot is named for. The AD-50 incident deployed
    # semadrawd's run into the semasound slot (an ambiguous
    # sema<TAB>); the mismatch stayed invisible until the slot
    # spawned the wrong daemon and crash-looped to a flap giveup.
    # A slot named X must exec PREFIX/bin/X.
    for svc_name in semadrawd pgsd-sessiond semasound; do
        if ! grep -q "^exec $PREFIX/bin/$svc_name" "$SVC_ROOT/$svc_name/run"; then
            echo "  ERROR: $SVC_ROOT/$svc_name/run does not exec $PREFIX/bin/$svc_name" >&2
            echo "         slot/binary mismatch (see AD-50); aborting before any service starts." >&2
            exit 1
        fi
    done
    echo "  verified   each slot execs its own binary (AD-50 guard)"

    # F.6 (ADR 0029 Decision 3): semaaud is retired. On systems upgraded
    # from a pre-retirement install, the /var/service/utf/semaaud
    # directory still exists with its supervise/ runtime state (and on
    # most, the AD-42.1 down marker). Reap it with the semainputd
    # pattern: ask s6-supervise to exit cleanly first, then remove the
    # tree; also remove the retired log directory, binary, rc.d script,
    # and rc.conf key. Idempotent: every step no-ops when absent.
    if [ -d "$SVC_ROOT/semaaud" ]; then
        if /usr/local/bin/s6-svok "$SVC_ROOT/semaaud" 2>/dev/null; then
            /usr/local/bin/s6-svc -dx -T 2000 "$SVC_ROOT/semaaud" 2>/dev/null || true
        fi
        rm -rf "$SVC_ROOT/semaaud"
        echo "  removed    $SVC_ROOT/semaaud (retired, ADR 0029)"
    fi
    if [ -d "$LOG_ROOT/semaaud" ]; then
        rm -rf "$LOG_ROOT/semaaud"
        echo "  removed    $LOG_ROOT/semaaud (retired)"
    fi
    if [ -f "$PREFIX/bin/semaaud" ]; then
        rm -f "$PREFIX/bin/semaaud"
        echo "  removed    $PREFIX/bin/semaaud (retired)"
    fi
    if [ -f "$PREFIX/etc/rc.d/semaaud" ]; then
        rm -f "$PREFIX/etc/rc.d/semaaud"
        echo "  removed    $PREFIX/etc/rc.d/semaaud (retired)"
    fi
    if sysrc -n semaaud_enable >/dev/null 2>&1; then
        sysrc -x semaaud_enable
        echo "  removed    semaaud_enable from rc.conf (retired)"
    fi

    echo ""
    echo "=== Creating log directories under $LOG_ROOT ==="
    # AD-20.3: create $LOG_ROOT explicitly. Per-daemon subdirs come
    # next via the for loop. We need $LOG_ROOT itself because
    # /usr/local/etc/rc.d/utf-supervisor passes
    # -o /var/log/utf/svscan.log to daemon(8), and daemon(8) creates
    # the file (with mode 0600) on first start but won't create the
    # parent directory.
    mkdir -p "$LOG_ROOT"
    for svc_name in semadrawd pgsd-sessiond semasound; do
        mkdir -p "$LOG_ROOT/$svc_name"
        echo "  created    $LOG_ROOT/$svc_name"
    done
    # AD-2a Phase 3 step 2: stale log dir from retired semainputd.
    if [ -d "$LOG_ROOT/semainputd" ]; then
        rm -rf "$LOG_ROOT/semainputd"
        echo "  removed    $LOG_ROOT/semainputd (retired)"
    fi

    echo ""
    echo "=== Enabling daemons in /etc/rc.conf ==="
    sysrc inputfs_enable="YES"
    sysrc audiofs_enable="YES"
    sysrc utf_supervisor_enable="YES"
    # F.5.f: semasound is the AD-3 successor broker; enabled by default.
    sysrc semasound_enable="YES"
    # AD-2a Phase 3 step 2: semainputd retired; no semainput_enable.
    # The uninstall sysrc -x above clears any pre-retirement value.
    sysrc semadraw_enable="YES"
    # SM-1.9: pgsd-sessiond enabled by default after install. This
    # is the line that makes "boot to graphical login" actually
    # happen. Set to NO to disable boot-launch without uninstalling.
    sysrc pgsd_sessiond_enable="YES"
fi

# ============================================================================
# loader.conf: load drawfs at boot
# ============================================================================

LOADER_CONF="/boot/loader.conf"
echo ""
echo "=== Configuring /boot/loader.conf ==="
if grep -q "drawfs_load" "$LOADER_CONF" 2>/dev/null; then
    echo "  already set  drawfs_load=\"YES\""
else
    echo "drawfs_load=\"YES\"" >> "$LOADER_CONF"
    echo "  added  drawfs_load=\"YES\" to $LOADER_CONF"
fi

# ============================================================================
# AD-31.1: _semadraw system user
# ============================================================================
# semadrawd drops privileges from root to a dedicated system user before
# entering its accept loop (see semadraw/docs/adr/0006-multi-user-refactor.md).
# Idempotent: skip if the group / user already exist. The s6 run script
# discovers the uid/gid at startup via id(1) and exports
# SEMADRAW_RUN_UID / SEMADRAW_RUN_GID before exec'ing semadrawd.
#
# UID and GID are not pinned to specific numbers: pw useradd picks the
# next available value in the system-account range. FreeBSD's
# /usr/share/examples/etc/master.passwd reserves 50-99 for installed
# system users; pw -E (system) chooses from there if present, else
# uses the first available unused id.

echo ""
echo "=== Configuring _semadraw system user ==="
if pw groupshow _semadraw >/dev/null 2>&1; then
    echo "  already exists  group _semadraw (gid $(pw groupshow _semadraw | cut -d: -f3))"
else
    pw groupadd _semadraw
    echo "  created  group _semadraw (gid $(pw groupshow _semadraw | cut -d: -f3))"
fi

if pw usershow _semadraw >/dev/null 2>&1; then
    echo "  already exists  user _semadraw (uid $(pw usershow _semadraw | cut -d: -f3))"
else
    pw useradd _semadraw \
        -g _semadraw \
        -d /nonexistent \
        -s /usr/sbin/nologin \
        -c "semadrawd unprivileged runtime user" \
        -w no
    echo "  created  user _semadraw (uid $(pw usershow _semadraw | cut -d: -f3))"
fi

# ============================================================================
# Restart services that were running before the install
# ============================================================================
# AD-12.1 and AD-12.3 counterpart to the stop_service_if_running block
# earlier. Services not previously running are deliberately not started:
# install.sh is an upgrade-preserving-state tool, not a "start everything"
# tool.

if [ "$DRAWFS_WAS_LOADED" -eq 1 ] || [ "$INPUTFS_WAS_LOADED" -eq 1 ] || [ "$UTF_SUPERVISOR_WAS_RUNNING" -eq 1 ] || [ -n "$SERVICES_TO_RESTART" ]; then
    echo ""
    echo "=== Restarting previously-running services ==="

    # AD-18.1 lesson: restart drawfs first if it was loaded before.
    # The deploy step writes /boot/modules/drawfs.ko but does not
    # refresh the module already in kernel memory. Without this
    # bump-the-module step, every install.sh invocation would
    # silently leave the operator running yesterday's drawfs while
    # today's drawfs.ko sits on disk unused, exactly the trap that
    # made the AD-18.1 panic-fix appear not to work during
    # 2026-05-07 bench testing. Reloading is kldunload-then-kldload;
    # the AD-12.1 stop block already stopped userland daemons that
    # might have /dev/draw open, so unload should succeed. We sequence
    # drawfs before inputfs since semadrawd (which opens /dev/draw)
    # also opens inputfs's /var/run/sema/input/* files; bringing the
    # lower-layer device back first matches the daemon-startup order.
    #
    # 2026-05-24 lesson: also load drawfs when it was NOT previously
    # loaded but the supervisor was running. This happens when the
    # operator did `start.sh --stop` (which unloads drawfs) and then
    # ran `install.sh`. Without this clause, install.sh would
    # complete and the supervised semadrawd would crash on
    # `/dev/draw` not existing, exactly the failure observed on the
    # 2026-05-24 bench session that motivated this clause.
    if [ "$DRAWFS_WAS_LOADED" -eq 1 ]; then
        if kldstat -q -m drawfs 2>/dev/null; then
            kldunload drawfs 2>/dev/null && echo "  unloaded  drawfs (for refresh)" \
                || echo "  WARNING: kldunload drawfs failed; module may still be in use, REBOOT REQUIRED to pick up new drawfs.ko" >&2
        fi
        if kldload drawfs 2>/dev/null; then
            echo "  loaded    drawfs"
        else
            echo "  WARNING: kldload drawfs failed" >&2
        fi
    elif [ "$UTF_SUPERVISOR_WAS_RUNNING" -eq 1 ]; then
        # drawfs wasn't loaded but the supervisor was running. Load
        # drawfs now so the supervised daemons can open /dev/draw
        # when they come back up below.
        if ! kldstat -q -m drawfs 2>/dev/null; then
            if kldload drawfs 2>/dev/null; then
                echo "  loaded    drawfs (was unloaded; supervisor restart needs it)"
            else
                echo "  WARNING: kldload drawfs failed; supervised semadrawd will crash on /dev/draw absence" >&2
            fi
        fi
    fi

    # AD-12.3: restart inputfs first if it was loaded before. inputfs
    # publishes /var/run/sema/input/{state,events}; semadrawd's drawfs
    # backend opens those files at init. Restarting inputfs after
    # semadrawd would leave semadrawd holding a stale ring view.
    # Bump-the-module-onto-the-new-image is a kldunload-then-kldload,
    # since we need the userland daemons stopped first (they have the
    # event ring mmapped); the AD-12.1 stop block already stopped them
    # if they were running.
    if [ "$INPUTFS_WAS_LOADED" -eq 1 ]; then
        if kldstat -q -n inputfs.ko 2>/dev/null; then
            kldunload inputfs 2>/dev/null && echo "  unloaded  inputfs (for refresh)" \
                || echo "  WARNING: kldunload inputfs failed; module may still be in use" >&2
        fi
        if kldload inputfs 2>/dev/null; then
            echo "  loaded    inputfs"
        else
            echo "  WARNING: kldload inputfs failed" >&2
        fi
    fi

    # AD-31.1 follow-up: ensure inputfs publication files are readable
    # by the _semadraw user that semadrawd drops to.
    #
    # Per ADR 0013, inputfs creates /var/run/sema/input/{state,events,focus}
    # at module-load time with uid:gid:mode from sysctl tunables
    # hw.inputfs.dev_* (defaults root:wheel:0600). semadrawd post-AD-31.1
    # runs as _semadraw and pumpCursorPosition lazy-opens the state file
    # post-drop; that open fails as _semadraw on the default permissions.
    # See semadraw/docs/adr/0006-multi-user-refactor.md §1 implementation
    # status.
    #
    # We:
    #   1. Write loader.conf entries so future module loads pick the
    #      right attributes automatically.
    #   2. Set the running module's sysctl values to match (no-op for
    #      already-created files, but matters if a future event
    #      causes inputfs to recreate them).
    #   3. chgrp + chmod the existing files so the current session
    #      works without requiring a reboot.
    #
    # Mode 0640 makes the files group-readable. Group _semadraw is the
    # only group with that membership by default; other system users
    # cannot read. The root user retains access via uid=0.
    SEMADRAW_GID="$(pw groupshow _semadraw 2>/dev/null | cut -d: -f3)"
    if [ -z "$SEMADRAW_GID" ]; then
        echo "  WARNING: cannot resolve _semadraw gid; skipping inputfs perm fix" >&2
    else
        # 1. loader.conf entries (idempotent).
        for tunable in "hw.inputfs.dev_gid=$SEMADRAW_GID" "hw.inputfs.dev_mode=0640"; do
            key="${tunable%%=*}"
            if grep -q "^${key}=" "$LOADER_CONF" 2>/dev/null; then
                sed -i '' "/^${key}=/d" "$LOADER_CONF"
                echo "${tunable}" >> "$LOADER_CONF"
                echo "  updated  ${tunable} in $LOADER_CONF"
            else
                echo "${tunable}" >> "$LOADER_CONF"
                echo "  added    ${tunable} to $LOADER_CONF"
            fi
        done

        # 2. Live sysctl (only matters if inputfs subsequently recreates
        # the files; harmless otherwise).
        sysctl "hw.inputfs.dev_gid=$SEMADRAW_GID" >/dev/null 2>&1 || true
        sysctl "hw.inputfs.dev_mode=0640" >/dev/null 2>&1 || true

        # 3. Apply attributes to currently-existing files so this
        # session works without a reboot. The files may not all exist
        # (focus is written by semadrawd and may be absent until it
        # runs); skip any that are missing.
        for f in /var/run/sema/input/state /var/run/sema/input/events /var/run/sema/input/focus; do
            if [ -e "$f" ]; then
                chgrp _semadraw "$f" 2>/dev/null && chmod 0640 "$f" 2>/dev/null \
                    && echo "  fixed perms on $f (gid=$SEMADRAW_GID mode=0640)" \
                    || echo "  WARNING: failed to fix perms on $f" >&2
            fi
        done
    fi

    # AD-31.4 part A: devfs rule for /dev/draw.
    #
    # Per ADR 0006 §5, /dev/draw is the gatekeeper character device
    # for the framebuffer: only semadrawd should be able to open it
    # so that clients are forced through semadrawd's IPC. The
    # default devfs permissions (root:wheel:0600) match this in
    # principle but rely on semadrawd-as-root for the open. After
    # AD-31.1, semadrawd opens /dev/draw at startup (still root)
    # then drops to _semadraw; the open survives the drop. But
    # without an explicit devfs rule, the device disappears and
    # reappears with default permissions on every kldload of
    # drawfs (e.g., on a refresh install or a reboot), and there
    # is no devfs-level guarantee that the gid is _semadraw.
    #
    # We install a UTF-owned ruleset (ruleset 10, name utf_devices)
    # that asserts:
    #
    #   add path 'draw' mode 0660 group _semadraw
    #
    # Mode 0660 means _semadraw can rw, _semadraw group members
    # can rw, others cannot open. Combined with AD-31.3's
    # surface-modify checks, this closes the "any user can bypass
    # semadrawd via direct /dev/draw access" hole. Group access
    # via _semadraw rather than a wide group keeps the operator
    # account from inheriting framebuffer-driver privileges by
    # default; operators who need direct access can be added to
    # _semadraw explicitly.
    #
    # The ruleset is registered as the system default in
    # /etc/rc.conf via devfs_system_ruleset, and applied live via
    # service devfs restart so this session works without a reboot.
    echo ""
    echo "=== Configuring devfs rules ==="

    SEMADRAW_GID="$(pw groupshow _semadraw 2>/dev/null | cut -d: -f3)"
    if [ -z "$SEMADRAW_GID" ]; then
        echo "  WARNING: cannot resolve _semadraw gid; skipping devfs rule" >&2
    else
        DEVFS_RULES="/etc/devfs.rules"
        DEVFS_BEGIN="# BEGIN utf_devices managed by install.sh"
        DEVFS_END="# END utf_devices managed by install.sh"

        # Make sure the file exists; FreeBSD ships an empty default.
        [ -f "$DEVFS_RULES" ] || touch "$DEVFS_RULES"

        # Idempotent: if the markered region exists, remove it
        # first, then re-append with current content. This keeps
        # the install reproducible without depending on what was
        # previously there.
        if grep -qF "$DEVFS_BEGIN" "$DEVFS_RULES"; then
            sed -i '' "/^${DEVFS_BEGIN}$/,/^${DEVFS_END}$/d" "$DEVFS_RULES"
            echo "  removed  previous utf_devices block from $DEVFS_RULES"
        fi

        cat >> "$DEVFS_RULES" <<EOF
$DEVFS_BEGIN
[utf_devices=10]
add path 'draw' mode 0660 group _semadraw
$DEVFS_END
EOF
        echo "  installed  utf_devices ruleset in $DEVFS_RULES"

        # Register the ruleset as the system default in rc.conf,
        # gracefully:
        #
        #   - If devfs_system_ruleset is unset, set it to
        #     utf_devices and live-apply.
        #   - If devfs_system_ruleset is already utf_devices,
        #     no-op (idempotent re-install).
        #   - If devfs_system_ruleset points to something else
        #     (an operator's existing ruleset, common on
        #     GhostBSD-style desktops where devfsrules_common
        #     is preconfigured), refuse to override. Leave
        #     the operator's setting alone and skip the
        #     live-apply. Warn loudly with instructions for
        #     manual integration.
        #
        # The markered utf_devices block has been written to
        # /etc/devfs.rules regardless, so an operator who
        # later decides to merge the rule into their existing
        # ruleset has the canonical text on hand.
        CURRENT_RULESET="$(sysrc -n devfs_system_ruleset 2>/dev/null || true)"
        APPLY_LIVE=0
        case "$CURRENT_RULESET" in
            "")
                sysrc "devfs_system_ruleset=utf_devices" >/dev/null
                echo "  set      devfs_system_ruleset=utf_devices in /etc/rc.conf"
                APPLY_LIVE=1
                ;;
            utf_devices)
                echo "  already set  devfs_system_ruleset=utf_devices in /etc/rc.conf"
                APPLY_LIVE=1
                ;;
            *)
                echo ""
                echo "  NOTICE: devfs_system_ruleset is set to '$CURRENT_RULESET'."
                echo "          UTF does not override an existing ruleset choice."
                echo "          The utf_devices block has still been written to"
                echo "          /etc/devfs.rules for reference, but it is NOT"
                echo "          the active ruleset. /dev/draw will keep its"
                echo "          default permissions (root:wheel:0600) unless you"
                echo "          take one of the following steps:"
                echo ""
                echo "          1. Merge the line"
                echo "                add path 'draw' mode 0660 group _semadraw"
                echo "             into your existing [$CURRENT_RULESET=...] block"
                echo "             in /etc/devfs.rules, then run:"
                echo "                service devfs restart"
                echo ""
                echo "          2. Or switch to utf_devices as the system ruleset:"
                echo "                sysrc devfs_system_ruleset=utf_devices"
                echo "                service devfs restart"
                echo "             (note: this replaces your current ruleset's"
                echo "             effect on /dev permissions; review the"
                echo "             utf_devices block before switching.)"
                echo ""
                echo "          UTF will still function without this rule. The"
                echo "          /dev/draw default permissions (root:wheel:0600)"
                echo "          already restrict open to root, and semadrawd"
                echo "          opens /dev/draw before dropping privileges."
                echo "          The devfs rule is defence in depth, not a"
                echo "          load-bearing requirement."
                echo ""
                ;;
        esac

        # Live-apply: only when we actually changed the active
        # ruleset choice. Skipping live-apply in the
        # operator-has-existing-ruleset case avoids a confusing
        # "applied" message that didn't apply UTF's ruleset.
        if [ "$APPLY_LIVE" -eq 1 ]; then
            if service devfs restart >/dev/null 2>&1; then
                echo "  applied  utf_devices ruleset to /dev"
            else
                echo "  WARNING: service devfs restart failed; reboot required to pick up new ruleset" >&2
            fi

            # Sanity check: /dev/draw should now be _semadraw:0660.
            # Report what actually happened rather than asserting (the
            # state file is informational; failure here doesn't block
            # the install).
            if [ -c /dev/draw ]; then
                DRAW_PERMS="$(stat -f '%Sp %Su:%Sg' /dev/draw 2>/dev/null)"
                echo "  /dev/draw: $DRAW_PERMS"
            fi
        fi
    fi

    # AD-20: bring the s6 supervision tree up before the daemon shims.
    # The shims fail with "s6-supervise not running" if utf-supervisor
    # isn't up. We start utf-supervisor whenever it was running before
    # OR there are daemons to restart (since they need the supervisor
    # regardless of whether utf-supervisor was running pre-install; a
    # first-time install doesn't have utf-supervisor running yet, but
    # if the operator just had daemons running directly via start.sh
    # we still want them resumed under supervision after the install).
    if [ "$UTF_SUPERVISOR_WAS_RUNNING" -eq 1 ] || [ -n "$SERVICES_TO_RESTART" ]; then
        if service utf-supervisor start >/dev/null 2>&1; then
            echo "  started   utf-supervisor"
            # Give s6-svscan a moment to spawn the per-service
            # s6-supervise processes. Without this, the immediate
            # service <name> start below races and gets
            # "s6-supervise not running on /var/service/utf/<name>".
            sleep 2
        else
            echo "  WARNING: service utf-supervisor start failed" >&2
        fi
    fi

    # AD-12.1: dependency order for userland daemons. utf_clock is
    # provided by the audiofs rc service (module load starts the kernel
    # clock writer, ADR 0018/0029); audiofs was handled in the module
    # refresh above, so the daemon order here is semasound, then
    # semadraw, then pgsd-sessiond (SM-1.9: semadraw client).
    for svc in semasound semadraw pgsd-sessiond; do
        case " $SERVICES_TO_RESTART " in
            *" $svc "*)
                if service "$svc" start >/dev/null 2>&1; then
                    echo "  started   $svc"
                else
                    echo "  WARNING: service $svc start failed" >&2
                fi
                ;;
        esac
    done
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=== UTF installation complete ==="
echo ""
echo "Installed binaries:"
for bin in $BINARIES; do
    target="$PREFIX/bin/$bin"
    if [ -f "$target" ]; then
        echo "  $target"
    fi
done
echo ""
echo "drawfs will load automatically at next boot (loader.conf)."
echo "inputfs and the daemons will start automatically at next boot (rc.conf)."
echo ""
echo "SM-1.9: After this reboot, the system boots directly to the"
echo "        pgsd-sessiond graphical login screen. To disable boot-"
echo "        launch without uninstalling: sysrc pgsd_sessiond_enable=NO"
echo ""
echo "To start now without rebooting:"
echo "  kldload drawfs"
echo "  service inputfs start"
echo "  service audiofs start"
echo "  service semasound start"
echo "  service semadraw start"
echo "  service pgsd-sessiond start"
echo ""
echo "To remove:  sh install.sh --uninstall --prefix $PREFIX"
