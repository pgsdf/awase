#!/bin/sh
# Awase install script
# Builds all daemons and installs them to PREFIX (default: /usr/local).
#
# Usage:
#   sh install.sh                  # install to /usr/local (run as a regular user; elevates via mdo)
#   sh install.sh --prefix ~/awase   # install to custom prefix
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

BINARIES="semadrawd chrono_dump semadraw-term inputdump awase-log-cleanup pgsd-sessiond semasound semasound-tone semasound-dump"

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

# ADR shared 0005: when re-executed into the deploy phase, the parsed flags
# arrive through the environment, since the re-exec carries no argv.
PREFIX="${AWASE_PREFIX:-$PREFIX}"
ASSUME_YES="${AWASE_ASSUME_YES:-$ASSUME_YES}"
ALLOW_SEMADRAW_TERM="${AWASE_ALLOW_SEMADRAW_TERM:-$ALLOW_SEMADRAW_TERM}"

# ============================================================================
# Privilege model (ADR shared 0005: unprivileged-first installation)
# ============================================================================
#
# install.sh runs as a regular user. Privileged operations elevate through
# $PRIV: mac_do (mdo) by default, sudo supported via PRIV=sudo. AWASE_PHASE
# drives a two-phase re-execution: the build phase (default) runs the userland
# Zig builds as the invoking user so they never leave root-owned files in the
# checkout, then re-execs into the deploy phase as root for kernel components,
# installation, configuration, and service activation.

PRIV="${PRIV:-mdo}"
priv() { "$PRIV" "$@"; }
AWASE_PHASE="${AWASE_PHASE:-build}"

# ============================================================================
# Elevation preflight (ADR shared 0005, resolves Open Question 2)
# ============================================================================
#
# Verify $PRIV can actually become root before any privileged step runs. The
# installer never provisions mac_do itself: provisioning needs root, and mac_do
# is the very path the unprivileged installer would use to get root, so it is a
# chicken-and-egg the script cannot resolve from inside. When elevation does not
# work, show the operator the exact commands and re-check after they apply them
# in a root shell. The probe is functional (it actually tries to elevate),
# which is the ground truth for mac_do and sudo alike.

priv_works() {
    "$PRIV" true >/dev/null 2>&1
}

# Provisioning guidance, plain text with real newlines. Deliberately contains
# no backslash-n: bsddialog collapses real newlines to spaces as soon as a
# literal \n escape appears in the text, so the persist line uses echo (which
# adds its own newline) rather than printf '...\n'. Commands are left-aligned
# because bsddialog dropped --no-collapse and will not preserve indentation.
priv_recipe() {
    if [ "$PRIV" = mdo ]; then
        cat <<EOF
$PRIV cannot elevate to root yet. Provision mac_do once, as root.

In a root shell (su -, or the system console), run:

kldload mac_do
sysrc -f /boot/loader.conf mac_do_load=YES
sysctl security.mac.do.rules='gid=0>uid=0,gid=*,+gid=*'
echo 'security.mac.do.rules=gid=0>uid=0,gid=*,+gid=*' >> /etc/sysctl.conf

If "id" does not show the wheel group, also run (then re-login):

pw groupmod wheel -m $(id -un)

Or re-run the installer with PRIV=sudo to use sudo instead.
EOF
    else
        cat <<EOF
$PRIV cannot elevate to root.

Ensure $PRIV lets your user run commands as root (for sudo, a sudoers
entry), or re-run the installer with PRIV=mdo to use mac_do.
EOF
    fi
}

ensure_elevation() {
    if priv_works; then
        return 0
    fi

    # Non-interactive (--yes, or no controlling terminal): cannot guide a fix,
    # so fail fast with the recipe rather than hang waiting for input.
    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ] || [ ! -t 1 ]; then
        echo "ERROR: cannot elevate via \$PRIV ($PRIV)." >&2
        priv_recipe >&2
        exit 1
    fi

    echo "NOTICE: $PRIV cannot elevate yet; opening provisioning guidance." >&2
    while ! priv_works; do
        if command -v bsddialog >/dev/null 2>&1; then
            # --cr-wrap so bsddialog honours the real newlines as line breaks.
            if ! bsddialog --cr-wrap --title "Awase installer: privilege setup" \
                           --ok-label "Re-check" --cancel-label "Abort" \
                           --yesno "$(priv_recipe)

Apply the commands in a root shell, then choose Re-check. Abort exits." 0 0; then
                echo "ABORTED: elevation not provisioned." >&2
                exit 1
            fi
        else
            priv_recipe >&2
            printf "\nApply the changes as root, then press Enter to re-check (Ctrl-C aborts): " >&2
            if [ -r /dev/tty ]; then read -r _ans < /dev/tty || true; else read -r _ans || true; fi
        fi
    done
    echo "  ok  elevation via $PRIV verified"
}

# Run the preflight whenever a privileged step will follow: not for --check
# (read-only) and not when already root (the deploy re-exec and a root-invoked
# uninstall both re-enter as root and have nothing to provision).
if [ "$CHECK_ONLY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    ensure_elevation
fi

# ============================================================================
# Uninstall (privileged terminal path)
# ============================================================================
#
# Uninstall is entirely privileged and neither builds nor installs packages,
# so it is handled before the build/deploy phases. When not already root it
# elevates once through $PRIV and re-runs.

if [ "$UNINSTALL" -eq 1 ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "=== Elevating for uninstall ($PRIV) ==="
        exec env \
            HOME=/root \
            PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin \
            AWASE_PREFIX="$PREFIX" \
            "$PRIV" /bin/sh "$SCRIPT_DIR/$(basename "$0")"
        echo "ERROR: could not elevate via $PRIV (use PRIV=sudo if no mac_do)." >&2
        exit 1
    fi
    # ADR 0030 Decision 4 (the takeover protocol, uninstall direction):
    # stop supervision BEFORE removing anything it owns. Removing the
    # scan tree or the daemon binaries while s6-svscan is running
    # orphans the supervise processes and the daemons; the next
    # install then has to SIGKILL the survivors.
    echo "=== Stopping supervision (ADR 0030 Decision 4) ==="
    if [ -f "$PREFIX/etc/rc.d/awase-supervisor" ] && service awase-supervisor status >/dev/null 2>&1; then
        service awase-supervisor stop >/dev/null 2>&1 \
            && echo "  stopped  awase-supervisor (supervision tree torn down)" \
            || echo "  WARNING: awase-supervisor stop reported failure; continuing"
    elif pgrep -f "s6-svscan /var/service/awase" >/dev/null 2>&1; then
        /usr/local/bin/s6-svscanctl -t /var/service/awase 2>/dev/null \
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
    for svc in inputfs audiofs awase-supervisor semaaud semadraw pgsd-sessiond semasound; do
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
    PERIODIC_TARGET="$PREFIX/etc/periodic/daily/500.awase-log-cleanup"
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

    # AD-20: remove the s6 supervision tree at /var/service/awase/.
    # We do not remove /var/log/awase/; those logs may be useful for
    # postmortem inspection. Operators who want a clean slate should
    # rm -rf /var/log/awase/ themselves (documented in INSTALL.md
    # Uninstall section).
    SVC_ROOT="/var/service/awase"
    if [ -d "$SVC_ROOT" ]; then
        rm -rf "$SVC_ROOT"
        echo "  removed  $SVC_ROOT"
    else
        echo "  skip     $SVC_ROOT (not found)"
    fi

    echo ""
    echo "=== Disabling daemons in /etc/rc.conf ==="
    sysrc -x inputfs_enable 2>/dev/null        && echo "  removed  inputfs_enable"        || echo "  skip     inputfs_enable (not set)"
    sysrc -x awase_supervisor_enable 2>/dev/null && echo "  removed  awase_supervisor_enable" || echo "  skip     awase_supervisor_enable (not set)"
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

    # AD-31.4 part A: remove awase_devices devfs ruleset.
    echo ""
    echo "=== Removing devfs rule for /dev/draw ==="
    DEVFS_RULES="/etc/devfs.rules"
    DEVFS_BEGIN="# BEGIN awase_devices managed by install.sh"
    DEVFS_END="# END awase_devices managed by install.sh"
    if [ -f "$DEVFS_RULES" ] && grep -qF "$DEVFS_BEGIN" "$DEVFS_RULES"; then
        sed -i '' "/^${DEVFS_BEGIN}$/,/^${DEVFS_END}$/d" "$DEVFS_RULES"
        echo "  removed  awase_devices block from $DEVFS_RULES"
    else
        echo "  skip     awase_devices block (not present)"
    fi
    # Only unset devfs_system_ruleset if it currently points at
    # awase_devices; leave alone if the operator pointed it elsewhere.
    if [ "$(sysrc -n devfs_system_ruleset 2>/dev/null)" = "awase_devices" ]; then
        sysrc -x devfs_system_ruleset >/dev/null 2>&1 \
            && echo "  removed  devfs_system_ruleset from /etc/rc.conf"
    else
        echo "  skip     devfs_system_ruleset (not set to awase_devices)"
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
# Phase 1: unprivileged build (runs as the invoking user). ADR 0005 D1, D2.
# ============================================================================

if [ "$AWASE_PHASE" = build ]; then
    if [ "$(id -u)" -eq 0 ]; then
        echo "ERROR: run install.sh as a regular user, not root (ADR 0005)." >&2
        echo "       It builds the userland as you and elevates the rest through" >&2
        echo "       \$PRIV ($PRIV); do not use sudo, the script elevates itself." >&2
        exit 1
    fi

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
# Detection is by process ancestry, not an environment variable. Under the
# ADR 0005 model this runs in the unprivileged phase as the invoking user, so
# an exported SEMADRAW_TERM marker would survive; but ancestry is the robust
# signal regardless, since it also holds across the deploy-phase re-exec.
# Walking the parent-pid chain from $$ reaches the operator's shell whose
# ancestor is the semadraw-term process. The SEMADRAW_TERM marker is honoured
# too as a cheap secondary signal.
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
    echo "         cd $SCRIPT_DIR && sh install.sh" >&2
    echo "" >&2
    echo "       Or, if you understand the freeze and will wait it out:" >&2
    echo "         sh install.sh --allow-semadraw-term" >&2
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

# The unprivileged userland build writes into the checkout: the bootstrapped
# toolchain at sdk/ and each subproject's zig-out/ and .zig-cache/. ADR 0005
# assumes the checkout is operator-owned. If it is not (for example it was
# cloned under sudo, so the tree is root-owned), the zig bootstrap below fails
# with a confusing "mkdir: .../sdk: Permission denied" deep in the build, after
# a misleading "ok vendored zig". Fail here instead, with the exact repair.
if [ ! -w "$SCRIPT_DIR" ]; then
    echo "ERROR: the checkout at $SCRIPT_DIR is not writable by $(id -un)." >&2
    echo "       The unprivileged userland build (ADR 0005) needs the source" >&2
    echo "       tree owned by you; it looks root-owned, most likely cloned" >&2
    echo "       under sudo or as root. install.sh does not change the tree's" >&2
    echo "       ownership. Repair it and re-run:" >&2
    echo "         $PRIV chown -R $(id -un):$(id -gn) $SCRIPT_DIR" >&2
    echo "         sh install.sh" >&2
    exit 1
fi

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

        if ! bsddialog --title "Awase installer: package installation" \
                       --yesno "$dialog_body" 15 60; then
            echo "ABORTED: user declined package install" >&2
            exit 1
        fi
    elif [ "$ASSUME_YES" -eq 0 ]; then
        # Non-interactive without --yes: refuse to act.
        echo "ERROR: missing packages and not running interactively." >&2
        echo "       missing: $MISSING_PKGS" >&2
        echo "       re-run as: sh install.sh --yes" >&2
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
        if priv pkg install -y "$pkg_name" 2>&1 | tail -3; then
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

echo ""
echo "=== Cleaning stale build artifacts (clean.sh --force) ==="
# Prior installs that ran the whole script under sudo left root-owned
# .zig-cache/ and zig-out/ directories in the checkout. The unprivileged
# userland build below cannot write into a root-owned cache (zig fails with
# AccessDenied), so wipe the artifacts first. clean.sh is elevated because
# those leftovers are root-owned; it only removes build outputs inside the
# checkout (never /usr/src, /boot, .git, .config, or sources). On an
# already-clean tree it is a no-op. This is what breaks the ownership ratchet
# on the first unprivileged run after an old sudo-built tree.
priv sh "$SCRIPT_DIR/clean.sh" --force

# Repair a toolchain dir left root-owned by a pre-ADR-0005 sudo bootstrap.
# tools/zig bootstraps sdk/zig/current; if that ran under the old all-root
# installer, sdk/ is root-owned and a later toolchain swap (which writes into
# sdk/zig/) would fail for the unprivileged build. clean.sh deliberately does
# not touch sdk/, so repair it here. No-op once owned correctly.
if [ -d "$SCRIPT_DIR/sdk" ] && \
   [ -n "$(find "$SCRIPT_DIR/sdk" -user root -print -quit 2>/dev/null)" ]; then
    echo "  repairing root-owned sdk/ toolchain ownership"
    priv chown -R "$(id -u):$(id -g)" "$SCRIPT_DIR/sdk"
fi

echo "=== Building Awase userland (optimize=ReleaseSafe) ==="
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

    echo ""
    echo "=== Userland build complete; elevating to install ($PRIV) ==="
    exec env \
        HOME=/root \
        PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin \
        AWASE_PHASE=deploy \
        AWASE_PREFIX="$PREFIX" \
        AWASE_ASSUME_YES="$ASSUME_YES" \
        AWASE_KERNCONF="${AWASE_KERNCONF:-PGSD}" \
        AWASE_ALLOW_SEMADRAW_TERM="$ALLOW_SEMADRAW_TERM" \
        "$PRIV" /bin/sh "$SCRIPT_DIR/$(basename "$0")"
    echo "ERROR: could not elevate via $PRIV. Is mac_do loaded (or use PRIV=sudo)?" >&2
    exit 1
fi

# ============================================================================
# Phase 2: privileged deploy (runs as root via the $PRIV re-exec). ADR 0005.
# ============================================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: the deploy phase is not running as root." >&2
    echo "       Elevation through $PRIV did not yield root. Ensure mac_do is" >&2
    echo "       loaded and a wheel->root rule is set, for example:" >&2
    echo "         security.mac.do.rules='gid=0>uid=0,gid=*,+gid=*'" >&2
    echo "       Or re-run with PRIV=sudo if mac_do is unavailable." >&2
    exit 1
fi

# ============================================================================
# /var/run tmpfs prerequisite
# ============================================================================
#
# Awase publishes shared-memory regions under /var/run/sema/. The defaults
# on FreeBSD put /var/run on the same filesystem as /var, which makes
# shared-memory writes slower and leaves stale state files across reboots.
# Awase assumes tmpfs.
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

# Ensure the tmpfs kernel module is available before mounting. -n is a no-op
# when tmpfs is already loaded or built into the kernel; the mount below is the
# real test, so a kldload failure here is non-fatal.
kldload -n tmpfs 2>/dev/null || true

if ! mount | grep -qE "^tmpfs on /var/run "; then
    if mount /var/run 2>/dev/null; then
        echo "  mounted /var/run as tmpfs"
    else
        echo "ERROR: failed to mount /var/run as tmpfs" >&2
        echo "       check /etc/fstab and try (as root): mount /var/run" >&2
        exit 1
    fi
else
    echo "  ok  /var/run already mounted as tmpfs"
fi

# Rebuild the runtime linker hints after the tmpfs mount. The hints file lives
# at /var/run/ld-elf.so.hints, so mounting tmpfs over /var/run shadows it and
# the dynamic linker loses the /usr/local/lib search entries. Newly pkg-
# installed libraries there then resolve as "not found": drawfs/build.sh runs
# rsync below, which needs libiconv.so.2, and would die with
# 'Shared object "libiconv.so.2" not found, required by "rsync"'. ldconfig is a
# base binary that needs no hints to run, so rebuilding here is safe, and it is
# idempotent. This runs after the dependency pkg install and after the tmpfs
# mount, so the hints reflect the current /usr/local/lib on the live tmpfs.
if service ldconfig restart >/dev/null 2>&1; then
    echo "  ok  rebuilt runtime linker hints (ld-elf.so.hints on tmpfs)"
else
    echo "  WARNING: could not rebuild linker hints. If the build below fails" >&2
    echo "           with 'libiconv.so.2 not found', run: service ldconfig restart" >&2
fi


echo "=== Building Awase kernel modules (optimize=ReleaseSafe) ==="
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
# ============================================================================
# Install
# ============================================================================

# ----------------------------------------------------------------------------
# ADR 0004 B3b: migrate an existing UTF-named install forward to Awase.
#
# Idempotent and safe to re-run: every step checks current state and is a
# no-op on a fresh system or one already migrated. Runs after the build and
# before the Awase state is laid down, so the old supervisor is stopped and
# the old entry points removed before the new ones are written. UTF names
# appear ONLY here, as the old state to detect and retire; the rest of
# install.sh is Awase-only. The UTF aliases are removed by a follow-up ADR.
# ----------------------------------------------------------------------------
migrate_from_utf() {
    _mig=0
    _devfs_rules="/etc/devfs.rules"

    # 1. Stop the old UTF supervisor without blocking (ADR 0030 Decision 4:
    #    stop supervision before removing what it owns). We deliberately do NOT
    #    call `service utf-supervisor stop`: its rc.d stop drains the s6 tree
    #    synchronously, and if a supervised daemon is slow to exit on SIGTERM
    #    that drain blocks the upgrade indefinitely. Instead signal s6-svscan to
    #    terminate (returns at once), then wait for the supervisor pid to clear
    #    with a timeout and SIGKILL on expiry, the same shape as the Awase
    #    restart block below. The Awase supervisor started at the end
    #    re-supervises the daemons, so no service is left running unsupervised.
    _utf_pid="$(cat /var/run/utf-supervisor.pid 2>/dev/null || true)"
    if [ -d /var/service/utf ] || [ -n "$_utf_pid" ] \
       || pgrep -f "s6-svscan /var/service/utf" >/dev/null 2>&1; then
        if pgrep -f "s6-svscan /var/service/utf" >/dev/null 2>&1; then
            echo "  migrate  stopping old utf-supervisor"
            /usr/local/bin/s6-svscanctl -t /var/service/utf 2>/dev/null || true
        fi
        _waited=0
        while [ -n "$_utf_pid" ] && kill -0 "$_utf_pid" 2>/dev/null; do
            if [ "$_waited" -ge "${RESTART_TIMEOUT:-15}" ]; then
                echo "  WARNING: utf-supervisor did not exit in ${RESTART_TIMEOUT:-15}s; sending SIGKILL" >&2
                kill -9 "$_utf_pid" 2>/dev/null || true
                pkill -f "s6-svscan /var/service/utf" 2>/dev/null || true
                sleep 1
                break
            fi
            sleep 1
            _waited=$((_waited + 1))
            _utf_pid="$(cat /var/run/utf-supervisor.pid 2>/dev/null || true)"
        done
        _mig=1
    fi

    # 2. rc.conf enable knob: carry the operator's value to the Awase key,
    #    then drop the old key. If the Awase key is already set, leave it.
    _old_enable="$(sysrc -n utf_supervisor_enable 2>/dev/null || true)"
    if [ -n "$_old_enable" ]; then
        if [ -z "$(sysrc -n awase_supervisor_enable 2>/dev/null || true)" ]; then
            sysrc "awase_supervisor_enable=$_old_enable" >/dev/null \
                && echo "  migrate  awase_supervisor_enable=$_old_enable (from utf_supervisor_enable)"
        fi
        sysrc -x utf_supervisor_enable >/dev/null 2>&1 \
            && echo "  migrate  removed utf_supervisor_enable" || true
        _mig=1
    fi

    # 3. devfs_system_ruleset: migrate only if it still points at the old
    #    ruleset (an operator who repointed it is left alone). Then strip the
    #    old managed block; the Awase devfs stage rewrites the block fresh.
    if [ "$(sysrc -n devfs_system_ruleset 2>/dev/null)" = "utf_devices" ]; then
        sysrc "devfs_system_ruleset=awase_devices" >/dev/null \
            && echo "  migrate  devfs_system_ruleset=awase_devices (from utf_devices)"
        _mig=1
    fi
    if [ -f "$_devfs_rules" ] && grep -qF "# BEGIN utf_devices managed by install.sh" "$_devfs_rules"; then
        sed -i '' '/^# BEGIN utf_devices managed by install.sh$/,/^# END utf_devices managed by install.sh$/d' "$_devfs_rules" \
            && echo "  migrate  removed old utf_devices devfs block"
        _mig=1
    fi

    # 4. Per-user attribute directory: move it to the Awase path if the old
    #    exists and the new does not. The daemon already reads either via the
    #    B1 alias; this makes the canonical path authoritative.
    if [ -d /etc/utf/users ] && [ ! -d /etc/awase/users ]; then
        mkdir -p /etc/awase \
            && mv /etc/utf/users /etc/awase/users \
            && echo "  migrate  /etc/utf/users -> /etc/awase/users"
        rmdir /etc/utf 2>/dev/null || true
        _mig=1
    fi

    # 5. Remove the old supervision tree and the old entry points. The Awase
    #    tree, rc.d files, and tools are installed fresh below.
    if [ -d /var/service/utf ]; then
        rm -rf /var/service/utf && echo "  migrate  removed /var/service/utf"
        _mig=1
    fi
    for _p in \
        "$PREFIX/etc/rc.d/utf-supervisor" "/etc/rc.d/utf-supervisor" \
        "$PREFIX/etc/rc.d/utf-log-cleanup" "/etc/rc.d/utf-log-cleanup" \
        "$PREFIX/bin/utf-log-cleanup" \
        "$PREFIX/etc/periodic/daily/500.utf-log-cleanup" \
        "/var/run/utf-supervisor.pid"; do
        if [ -e "$_p" ]; then rm -f "$_p" && echo "  migrate  removed $_p"; _mig=1; fi
    done

    # 6. Logs are intentionally NOT migrated (ADR 0004 D4): existing logs stay
    #    at /var/log/utf for postmortem; new logs go to /var/log/awase.
    if [ "$_mig" = 1 ] && [ -d /var/log/utf ]; then
        echo "  migrate  note: old logs left in /var/log/utf (not moved); new logs use /var/log/awase"
    fi

    if [ "$_mig" = 1 ]; then
        echo "--- Migrated existing UTF install to Awase (ADR 0004) ---"
    fi
}

echo ""
echo "=== Migrating any existing UTF install (ADR 0004 D4) ==="
migrate_from_utf

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

# AD-20: same for awase-supervisor (the s6-svscan launcher). Track its
# state so the post-install restart block knows to bring it up before
# the daemon shims (which require it).
if [ -f /var/run/awase-supervisor.pid ] && \
   kill -0 "$(cat /var/run/awase-supervisor.pid 2>/dev/null)" 2>/dev/null; then
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
# as semadraw above; the run script in /var/service/awase/pgsd-sessiond/
# is what s6-supervise execs, and we need to replace it.
stop_service_if_running pgsd-sessiond pgsd-sessiond

# F.5.f: same pattern for semasound; its run script under
# /var/service/awase/semasound/ is replaced by this install.
stop_service_if_running semasound semasound

# AD-20: also stop awase-supervisor itself if it was running. The
# stop_service_if_running calls above only stopped the *daemons*; the
# s6-svscan supervisor process is still alive. Stopping it now lets us
# replace the scan-directory tree at /var/service/awase/ without
# s6-supervise processes contending. The post-install restart block
# brings everything back up in the correct order.
if [ "$UTF_SUPERVISOR_WAS_RUNNING" -eq 1 ]; then
    echo "  stopping  awase-supervisor (was running)"
    if [ -f "$PREFIX/etc/rc.d/awase-supervisor" ] || [ -f "/etc/rc.d/awase-supervisor" ]; then
        service awase-supervisor stop >/dev/null 2>&1 || true
    fi
    # Wait for the supervisor pid to exit, with timeout.
    waited=0
    while [ -f /var/run/awase-supervisor.pid ] && \
          kill -0 "$(cat /var/run/awase-supervisor.pid 2>/dev/null)" 2>/dev/null; do
        if [ "$waited" -ge "$RESTART_TIMEOUT" ]; then
            echo "  WARNING: awase-supervisor did not exit within ${RESTART_TIMEOUT}s, sending SIGKILL" >&2
            pid=$(cat /var/run/awase-supervisor.pid 2>/dev/null)
            [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
            sleep 1
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    rm -f /var/run/awase-supervisor.pid
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
# the core Awase binaries a missing source means the build silently
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
        echo "       a partial set of Awase binaries; the running daemons" >&2
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
# alongside the other Awase binaries. Stage 9a wires it under s6
# supervision via the per-service files in s6/awase/pgsd-sessiond/
# and the rc.d wrapper generated below.
install_bin_required "$SCRIPT_DIR/pgsd-sessiond/zig-out/bin/pgsd-sessiond"
install_bin_required "$SCRIPT_DIR/semasound/zig-out/bin/semasound"
install_bin_required "$SCRIPT_DIR/semasound/zig-out/bin/semasound-tone"
install_bin_required "$SCRIPT_DIR/semasound/zig-out/bin/semasound-dump"

# AD-32 / AD-25 Round 1 follow-up: operator helper for compacting
# s6-log-managed log directories. Not a built binary; it is the
# shell script at scripts/awase-log-cleanup directly. install_bin
# copies it to /usr/local/bin/awase-log-cleanup (the basename in
# the repo has no .sh extension to match the deployed-tool
# convention, like semadraw-term and chrono_dump). See
# scripts/awase-log-cleanup for the script itself and the periodic
# section below for the daily wrapper.
install_bin_required "$SCRIPT_DIR/scripts/awase-log-cleanup"

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
# PROVIDE: audiofs audiofs_loaded awase_clock
# REQUIRE: FILESYSTEMS
# KEYWORD: shutdown

# F.6 (ADR 0029 Decision 2): this service PROVIDEs awase_clock. Loading
# the audiofs module starts the kernel writer of /var/run/sema/clock
# (F.4, ADR 0018), so the module-load service is the capability's
# provider. The AD-12.2 convention works as designed: semadraw's
# REQUIRE: awase_clock is unchanged and now orders against audiofs.

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
    # AD-20: awase-supervisor rc.d entry, launches s6-svscan against the
    # Awase scan directory at /var/service/awase/. This is the single
    # supervision-tree entry point for Awase; the three daemon rc.d files
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

    cat > "$RCDDIR/awase-supervisor" << RCEOF
#!/bin/sh
# PROVIDE: awase_supervisor
# REQUIRE: FILESYSTEMS
# KEYWORD: shutdown

# AD-20: starts s6-svscan against /var/service/awase. The two Awase
# daemon rc.d files (semasound, semadraw) REQUIRE: this so
# rcorder(8) brings it up first. Without it, s6-supervise processes
# don't exist for the daemon shims to talk to.

. /etc/rc.subr

name="awase_supervisor"
rcvar="awase_supervisor_enable"
: \${awase_supervisor_enable:="NO"}

# AD-20.3: ensure /usr/local/bin is in PATH for s6-svscan's children.
#
# Empirically diagnosed on bare metal 2026-05-06: when launched via
# rc.d, s6-svscan starts but cannot spawn s6-supervise children. Its
# stderr (captured at /var/log/awase/svscan.log) prints repeated:
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

scan_dir="/var/service/awase"
pidfile="/var/run/awase-supervisor.pid"

# AD-20.3: -o /var/log/awase/svscan.log captures s6-svscan's own
# stderr (informational messages and warnings about failed spawns).
# Per-service logs still flow through s6-log into
# /var/log/awase/<name>/current as designed. We do not pass -f to
# daemon(8): operationally either choice would work, but -o needs
# valid stdio fds at exec time and we want s6-svscan's diagnostic
# output to survive (precisely how this AD-20.3 PATH bug got
# diagnosed).
command="/usr/sbin/daemon"
command_args="-P \${pidfile} -o /var/log/awase/svscan.log /usr/local/bin/s6-svscan \${scan_dir}"

start_precmd="awase_supervisor_precmd"
status_cmd="awase_supervisor_status"

awase_supervisor_precmd() {
    if [ ! -d "\${scan_dir}" ]; then
        echo "ERROR: scan directory \${scan_dir} does not exist." >&2
        echo "Re-run install.sh to create it." >&2
        return 1
    fi
    return 0
}

awase_supervisor_status() {
    if [ -r "\${pidfile}" ] && \\
       kill -0 "\$(cat "\${pidfile}" 2>/dev/null)" 2>/dev/null; then
        echo "awase-supervisor is running as pid \$(cat \${pidfile})."
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
        echo "awase-supervisor is not running."
        return 1
    fi
}

load_rc_config \$name
run_rc_command "\$1"
RCEOF
    chmod 555 "$RCDDIR/awase-supervisor"
    echo "  installed  $RCDDIR/awase-supervisor"

    # ========================================================================
    # AD-20: thin shim rc.d wrappers for the three Awase daemons.
    # Each translates `service <name> {start|stop|restart|status}` to
    # the corresponding s6-svc command against /var/service/awase/<name>.
    # The shims preserve the existing operator interface; the actual
    # supervision is done by s6.
    # ========================================================================


    cat > "$RCDDIR/semasound" << RCEOF
#!/bin/sh
# PROVIDE: semasound
# REQUIRE: awase_supervisor audiofs_loaded

# F.5.f (ADR 0028): thin shim for semasound, the AD-3 audio mixing
# broker. Predecessor retired under F.6 (ADR 0029). It does not
# provide awase_clock: that capability belongs to the audiofs rc
# service (the module load starts the kernel clock writer, ADR
# 0018/0029); semasound is a clock consumer like every other daemon.

. /etc/rc.subr

name="semasound"
rcvar="semasound_enable"
: \${semasound_enable:="NO"}

PATH="/usr/local/bin:\${PATH}"
export PATH

svc_dir="/var/service/awase/semasound"

start_cmd="semasound_start"
stop_cmd="semasound_stop"
status_cmd="semasound_status"
restart_cmd="semasound_restart"

semasound_start() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        echo "ERROR: s6-supervise not running on \${svc_dir}." >&2
        echo "Run 'service awase-supervisor start' first." >&2
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
# REQUIRE: awase_supervisor awase_clock inputfs_loaded

# AD-20: thin shim for semadrawd. Same shape as the shims above.
# Note that the framebuffer-resolution detection that previously
# lived in this rc.d script (semadraw_detect_resolution under
# AD-15.1 / AD-17) now lives in /var/service/awase/semadrawd/run.
# The detection substrate is unchanged (sysctl
# hw.drawfs.efifb.{width,height}); only the location moved.

. /etc/rc.subr

name="semadraw"
rcvar="semadraw_enable"
: \${semadraw_enable:="NO"}

# AD-20.3: PATH fix; same reasoning as the shims above.
PATH="/usr/local/bin:\${PATH}"
export PATH

svc_dir="/var/service/awase/semadrawd"

start_cmd="semadraw_start"
stop_cmd="semadraw_stop"
status_cmd="semadraw_status"
restart_cmd="semadraw_restart"

semadraw_start() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        echo "ERROR: s6-supervise not running on \${svc_dir}." >&2
        echo "Run 'service awase-supervisor start' first." >&2
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
# /var/service/awase/pgsd-sessiond/run execs the daemon directly.

. /etc/rc.subr

name="pgsd_sessiond"
rcvar="pgsd_sessiond_enable"
: \${pgsd_sessiond_enable:="NO"}

# PATH fix; same reasoning as the semasound and semadraw shims.
PATH="/usr/local/bin:\${PATH}"
export PATH

svc_dir="/var/service/awase/pgsd-sessiond"

start_cmd="pgsd_sessiond_start"
stop_cmd="pgsd_sessiond_stop"
status_cmd="pgsd_sessiond_status"
restart_cmd="pgsd_sessiond_restart"

pgsd_sessiond_start() {
    if ! /usr/local/bin/s6-svok "\${svc_dir}" 2>/dev/null; then
        echo "ERROR: s6-supervise not running on \${svc_dir}." >&2
        echo "Run 'service awase-supervisor start' first." >&2
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
    # wrapper for awase-log-cleanup. FreeBSD's periodic(8) runs every
    # script in /usr/local/etc/periodic/daily/ once per day at the
    # time configured by /etc/periodic.conf (default: 03:00 via cron).
    # The 500. prefix orders this within the daily batch (100-499 is
    # FreeBSD baseline; 500+ is the conventional ports/local range).
    #
    # The wrapper itself just calls /usr/local/bin/awase-log-cleanup
    # --trim, which deletes archived @*.s files in every s6-log-
    # shaped directory under /var/log/. current files are preserved.
    # ========================================================================

    PERIODIC_SRC="$SCRIPT_DIR/scripts/periodic/daily/500.awase-log-cleanup"
    PERIODIC_DST_DIR="$PREFIX/etc/periodic/daily"
    PERIODIC_DST="$PERIODIC_DST_DIR/500.awase-log-cleanup"

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
    # AD-20: install the s6 scan directory tree to /var/service/awase/
    # and create per-daemon log directories under /var/log/awase/.
    # ========================================================================

    SVC_ROOT="/var/service/awase"
    LOG_ROOT="/var/log/awase"
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
    # /var/service/awase/semainputd directory still exists with its
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
    # from a pre-retirement install, the /var/service/awase/semaaud
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
    # /usr/local/etc/rc.d/awase-supervisor passes
    # -o /var/log/awase/svscan.log to daemon(8), and daemon(8) creates
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
    sysrc awase_supervisor_enable="YES"
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
    # We install an Awase-owned ruleset (ruleset 10, name awase_devices)
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
        DEVFS_BEGIN="# BEGIN awase_devices managed by install.sh"
        DEVFS_END="# END awase_devices managed by install.sh"

        # Make sure the file exists; FreeBSD ships an empty default.
        [ -f "$DEVFS_RULES" ] || touch "$DEVFS_RULES"

        # Idempotent: if the markered region exists, remove it
        # first, then re-append with current content. This keeps
        # the install reproducible without depending on what was
        # previously there.
        if grep -qF "$DEVFS_BEGIN" "$DEVFS_RULES"; then
            sed -i '' "/^${DEVFS_BEGIN}$/,/^${DEVFS_END}$/d" "$DEVFS_RULES"
            echo "  removed  previous awase_devices block from $DEVFS_RULES"
        fi

        cat >> "$DEVFS_RULES" <<EOF
$DEVFS_BEGIN
[awase_devices=10]
add path 'draw' mode 0660 group _semadraw
$DEVFS_END
EOF
        echo "  installed  awase_devices ruleset in $DEVFS_RULES"

        # Register the ruleset as the system default in rc.conf,
        # gracefully:
        #
        #   - If devfs_system_ruleset is unset, set it to
        #     awase_devices and live-apply.
        #   - If devfs_system_ruleset is already awase_devices,
        #     no-op (idempotent re-install).
        #   - If devfs_system_ruleset points to something else
        #     (an operator's existing ruleset, common on
        #     GhostBSD-style desktops where devfsrules_common
        #     is preconfigured), refuse to override. Leave
        #     the operator's setting alone and skip the
        #     live-apply. Warn loudly with instructions for
        #     manual integration.
        #
        # The markered awase_devices block has been written to
        # /etc/devfs.rules regardless, so an operator who
        # later decides to merge the rule into their existing
        # ruleset has the canonical text on hand.
        CURRENT_RULESET="$(sysrc -n devfs_system_ruleset 2>/dev/null || true)"
        APPLY_LIVE=0
        case "$CURRENT_RULESET" in
            "")
                sysrc "devfs_system_ruleset=awase_devices" >/dev/null
                echo "  set      devfs_system_ruleset=awase_devices in /etc/rc.conf"
                APPLY_LIVE=1
                ;;
            awase_devices)
                echo "  already set  devfs_system_ruleset=awase_devices in /etc/rc.conf"
                APPLY_LIVE=1
                ;;
            *)
                echo ""
                echo "  NOTICE: devfs_system_ruleset is set to '$CURRENT_RULESET'."
                echo "          Awase does not override an existing ruleset choice."
                echo "          The awase_devices block has still been written to"
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
                echo "          2. Or switch to awase_devices as the system ruleset:"
                echo "                sysrc devfs_system_ruleset=awase_devices"
                echo "                service devfs restart"
                echo "             (note: this replaces your current ruleset's"
                echo "             effect on /dev permissions; review the"
                echo "             awase_devices block before switching.)"
                echo ""
                echo "          Awase will still function without this rule. The"
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
        # "applied" message that didn't apply Awase's ruleset.
        if [ "$APPLY_LIVE" -eq 1 ]; then
            if service devfs restart >/dev/null 2>&1; then
                echo "  applied  awase_devices ruleset to /dev"
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
    # The shims fail with "s6-supervise not running" if awase-supervisor
    # isn't up. We start awase-supervisor whenever it was running before
    # OR there are daemons to restart (since they need the supervisor
    # regardless of whether awase-supervisor was running pre-install; a
    # first-time install doesn't have awase-supervisor running yet, but
    # if the operator just had daemons running directly via start.sh
    # we still want them resumed under supervision after the install).
    if [ "$UTF_SUPERVISOR_WAS_RUNNING" -eq 1 ] || [ -n "$SERVICES_TO_RESTART" ]; then
        if service awase-supervisor start >/dev/null 2>&1; then
            echo "  started   awase-supervisor"
            # Give s6-svscan a moment to spawn the per-service
            # s6-supervise processes. Without this, the immediate
            # service <name> start below races and gets
            # "s6-supervise not running on /var/service/awase/<name>".
            sleep 2
        else
            echo "  WARNING: service awase-supervisor start failed" >&2
        fi
    fi

    # AD-12.1: dependency order for userland daemons. awase_clock is
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
# PGSD kernel: offer a checkpointed build as the final install activity
# ============================================================================
#
# Runs last, after the full deploy above (drawfs.ko, drawfs_load, inputfs,
# binaries, services). The PGSD kernel (KERNCONF ident PGSD/PGSD-DEBUG) removes
# the HID and console drivers that contend with inputfs and drawfs; GENERIC
# works but input may be limited and the framebuffer contended (INSTALL.md
# Step 5.5).
#
# The offer is placed here, at the end, for a hard reason: the PGSD kernel drops
# the in-tree framebuffer console, so a machine that boots it with no drawfs.ko
# present comes up dark. pgsd-kernel-build.sh's AD-8 closure check enforces that
# invariant and refuses to install the kernel until drawfs.ko is deployed.
# Deploying everything first, then building the kernel, satisfies the invariant
# and lets the operator reboot straight into a ready system with no second
# install pass (ADR 0005 kernel-offer amendment, 2026-06-18).
#
# install.sh delegates entirely to pgsd-kernel-build.sh, the single source of
# truth for source-tree validation, AD-8 closure, recovery checks, and build
# flags, and preserves its check/build/install checkpoints, so a check warning
# or a failed world/kernel build stops for inspection. It never compiles a
# kernel in non-interactive mode. This phase already runs as root (the $PRIV
# re-exec), so the build delegates directly without a further priv hop.

# yes/no prompt: bsddialog when available (real newlines, --cr-wrap), else a
# plain read. Returns 0 for yes.
kernel_prompt_yesno() {
    if command -v bsddialog >/dev/null 2>&1; then
        if bsddialog --cr-wrap --title "$1" --yes-label "Yes" --no-label "No" \
                     --yesno "$2" 0 0; then
            return 0
        fi
        return 1
    fi
    printf '%s\n\n' "$2" >&2
    printf "Proceed? [y/N]: " >&2
    if [ -r /dev/tty ]; then read -r _kp < /dev/tty || _kp=""; else read -r _kp || _kp=""; fi
    case "$_kp" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# Inline confirmation that preserves the terminal output above it for the
# operator to inspect (the whole point of the per-phase checkpoints). Default
# No; requires an explicit yes. Returns 0 for yes.
kernel_confirm() {
    printf '%s [y/N]: ' "$1" >&2
    if [ -r /dev/tty ]; then read -r _kc < /dev/tty || _kc=""; else read -r _kc || _kc=""; fi
    case "$_kc" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

case "$(uname -i 2>/dev/null)" in
    PGSD|PGSD-DEBUG) have_pgsd_kernel=1 ;;
    *)               have_pgsd_kernel=0 ;;
esac

if [ "$have_pgsd_kernel" -eq 0 ]; then
    KERNCONF="${AWASE_KERNCONF:-PGSD}"
    KBUILD="$SCRIPT_DIR/pgsd-kernel/pgsd-kernel-build.sh"

    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ] || [ ! -t 1 ]; then
        # Non-interactive: never start a kernel build; note it and continue.
        echo ""
        echo "Running GENERIC kernel."
        echo "PGSD kernel build skipped in non-interactive mode."
    elif [ ! -f "$KBUILD" ]; then
        echo ""
        echo "Running GENERIC kernel; $KBUILD not found, skipping kernel build."
    elif kernel_prompt_yesno "Awase installer: PGSD kernel" "Awase is installed. You are running the GENERIC kernel.

The PGSD kernel is recommended for full Awase support: it removes the HID and
console drivers that otherwise claim the devices inputfs and drawfs need.
Building it now:

  - takes roughly 30 to 60 minutes
  - happens after this completed install, so drawfs.ko is already in place and
    the kernel's AD-8 closure check will pass
  - requires a reboot afterwards, straight into a ready system; no second
    install pass is needed

Build and install the PGSD kernel now? Choosing No leaves you on GENERIC."; then
        echo ""
        echo "=== PGSD kernel: environment check ($KERNCONF) ==="
        sh "$KBUILD" check "$KERNCONF" || true
        echo ""
        if kernel_confirm "Check complete; review the output above. Proceed to BUILD ($KERNCONF)?"; then
            echo ""
            echo "=== PGSD kernel: build ($KERNCONF) - this takes 30-60 minutes ==="
            if ! sh "$KBUILD" build --clean "$KERNCONF"; then
                echo "ERROR: PGSD kernel build failed (see output above)." >&2
                echo "       Awase itself is installed and runs on GENERIC; resolve" >&2
                echo "       the build and rebuild the kernel later." >&2
                exit 1
            fi
            echo ""
            if kernel_confirm "Build complete; review the output above. Proceed to INSTALL ($KERNCONF)?"; then
                echo ""
                echo "=== PGSD kernel: install ($KERNCONF) ==="
                if ! sh "$KBUILD" install "$KERNCONF"; then
                    echo "ERROR: PGSD kernel install failed (see output above)." >&2
                    echo "       Do NOT reboot into PGSD until resolved; GENERIC still" >&2
                    echo "       boots. See pgsd-kernel/README.md." >&2
                    exit 1
                fi
                echo ""
                echo "============================================================"
                echo "Awase installation complete, and the PGSD kernel is installed."
                echo ""
                echo "Reboot into the new kernel:"
                echo "  shutdown -r now"
                echo ""
                echo "drawfs loads at boot (loader.conf); inputfs and the daemons"
                echo "start at boot (rc.conf); the system comes up at the"
                echo "pgsd-sessiond graphical login."
                echo "============================================================"
                exit 0
            else
                echo "Install phase skipped; the built kernel is staged but not active."
                echo "Leaving you on GENERIC; install the kernel and reboot later for PGSD."
            fi
        else
            echo "Kernel build not started. Leaving you on GENERIC."
        fi
    else
        echo ""
        echo "Continuing on GENERIC kernel (PGSD recommended; see pgsd-kernel/README.md)."
    fi
fi


# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=== Awase installation complete ==="
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
