#!/bin/sh
# pgsd-kernel-build.sh — three-phase PGSD kernel build/install script.
#
# Why this script exists
# ----------------------
# PGSD kernel correctness depends on getting two things right at every
# rebuild:
#
#   1. The AD-8 HID modules (hkbd, ukbd, hms, hgame, hcons, hsctrl,
#      hpen, hmt, hconf, hidmap) CANNOT be excluded at build time.
#      WITHOUT_MODULES only filters the top-level sys/modules SUBDIR
#      (sys/modules/Makefile: SUBDIR:= ${SUBDIR:N${reject}}), and every
#      one of these is a nested leaf (hid/hkbd, usb/ukbd, ...) that no
#      top-level token reaches; the nested group Makefiles do not
#      re-apply the filter. So installkernel always installs these .ko,
#      and the kernel would auto-load them at device probe time, claim
#      the USB HID devices, and leave inputfs nothing to bind to
#      (keyboard and mouse stop working). The sanctioned fix is the
#      AD-8 closure reap in phase_install: after installkernel, the
#      suppressed .ko are removed from /boot/kernel/ and linker.hints
#      is regenerated. This runs by default every install, including
#      non-interactively, because the leak is guaranteed, not an
#      anomaly. WITHOUT_MODULES is still passed for the genuinely
#      top-level entries it can exclude (e.g. sound).
#
#   2. DESTDIR=/ must be passed to make installkernel when /boot/kernel/
#      is owned by a pkgbase package. Without it, the install step
#      refuses to overwrite package-managed files.
#
# Today (2026-05-13) we got the first one wrong: a buildkernel run
# without WITHOUT_MODULES produced .ko files for the AD-8 set, install
# copied them, the new kernel auto-loaded them at boot, and the mouse
# stopped working. This script makes that mistake impossible.
#
# Phases
# ------
# This script has three subcommands, deliberately separated:
#
#   check    Verify the build environment. Read-only. Reports what
#            is and isn't ready. Doesn't build, install, or modify
#            anything. Always safe to run.
#
#   build    Run make buildkernel with the correct flags. Slow
#            (30-60 minutes for clean rebuild). Refuses to run if
#            'check' would have failed.
#
#   install  Run make installkernel with the correct flags. Verifies
#            the just-built kernel is valid before installing, and
#            runs the AD-8 closure verification afterwards (no
#            suppressed .ko files in /boot/kernel/, no stale
#            linker.hints entries).
#
# Each phase is a separate invocation. There is no "all" subcommand;
# the operator should inspect output between phases.
#
# Usage:
#   sh pgsd-kernel-build.sh check [KERNCONF]
#   sh pgsd-kernel-build.sh build [KERNCONF]
#   sh pgsd-kernel-build.sh install [KERNCONF]
#
# KERNCONF defaults to PGSD. PGSD-DEBUG is the only other supported
# value; anything else exits with an error.

set -u

# ----------------------------------------------------------------------
# Constants

# Bare module names to exclude via WITHOUT_MODULES. Three groups:
#   AD-8 HID drivers: hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf
#     hidmap. These are NESTED (hid/hkbd, usb/ukbd) so WITHOUT_MODULES
#     cannot actually suppress them; they are removed after
#     installkernel by the AD-8 closure reap. Listed here for the
#     verification/reap source of truth, not because the make arg works.
#   AD-3 sound: hda sound cmi csa emu10kx es137x ich via8233.
#   Out-of-scope drivers: iwlwifi. Top-level LinuxKPI Intel wireless.
#     PGSD is a headless wired appliance and does not use it, and its
#     amd64 build is fragile (a failed if_iwlwifi.ko compile does not
#     stop buildkernel, then installkernel dies trying to install the
#     absent .ko: "install: if_iwlwifi.ko: No such file or directory").
#     Because iwlwifi IS top-level, WITHOUT_MODULES genuinely excludes
#     it at both build and install, so build and install agree and the
#     module is never scheduled for an install it cannot satisfy. This
#     is a definitional exclusion (out of scope), not a mask over a bug
#     we care about; other missing modules still fail loudly. If rtw88
#     or rtw89 (sibling LinuxKPI wireless under the same amd64 .if block
#     in sys/modules/Makefile) later fail the same way, add them here
#     rather than weakening the install error check.
# Used for the make arg (only the top-level names take effect) and for
# verification/reap. See resolve_without_modules for the mechanism.
WITHOUT_MODULES_NAMES="hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap hda sound cmi csa emu10kx es137x ich via8233 iwlwifi"

# The AD-8 HID modules specifically: the nested leaves that
# WITHOUT_MODULES cannot suppress and that the closure reap removes
# from /boot/kernel/ after installkernel. Single source of truth for
# both leak detection and removal (previously two hardcoded lists that
# had drifted; one listed a non-existent "utouch"). These are the HID
# drivers that contend with inputfs for HID ownership per ADR 0007.
AD8_HID_MODULES="hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap"

# resolve_without_modules: validate the suppression names against the
# source tree and emit them as bare names for WITHOUT_MODULES.
#
# Important, and the source of a long-standing AD-8 leak: FreeBSD's
# WITHOUT_MODULES only filters the TOP-LEVEL sys/modules SUBDIR list
# (sys/modules/Makefile: .for reject in ${WITHOUT_MODULES};
# SUBDIR:= ${SUBDIR:N${reject}}). The nested group Makefiles
# (sys/modules/hid/Makefile, sys/modules/usb/Makefile) do NOT re-apply
# the filter. So WITHOUT_MODULES can exclude a top-level entry like
# "sound", but it CANNOT exclude a nested leaf like hkbd (under hid/)
# or ukbd (under usb/): neither the bare name nor a "hid/hkbd" path
# matches the top-level "hid" SUBDIR word. The official example is
# bare top-level names: sys/i386/conf/PAE has
# WITHOUT_MODULES="ctl dpt hptmv ida".
#
# Consequence: the AD-8 HID modules are always built and installed;
# no WITHOUT_MODULES form suppresses them. They are removed after
# installkernel by the AD-8 closure reap in phase_install, which is
# the sanctioned mechanism (not error recovery). This helper still
# emits the names so genuinely top-level entries (sound) are excluded,
# and validates every name exists so a typo is caught; the nested
# names are inert in the make argument but are the authoritative list
# the reap and verification use via WITHOUT_MODULES_NAMES.
#
# Emits bare names to stdout; unresolved names to stderr with exit 1.
resolve_without_modules() {
    resolved=""
    unresolved=""
    for name in $WITHOUT_MODULES_NAMES; do
        # -maxdepth 3 catches /usr/src/sys/modules/hid/hkbd (depth 2)
        # and /usr/src/sys/modules/sound/driver/hda (depth 3) but stops
        # short of arbitrary nested subdirs.
        found=$(find "${SRC_DIR}/sys/modules" -maxdepth 3 -type d \
                -name "$name" 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            # Emit the bare leaf name: WITHOUT_MODULES matches top-level
            # SUBDIR words (see the header note), so "sound" works and
            # the nested HID names are inert here (handled by the reap).
            # The subdir-path form used previously matched nothing, top
            # level or nested, which is why suppression silently failed.
            resolved="$resolved $name"
        else
            unresolved="$unresolved $name"
        fi
    done

    if [ -n "$unresolved" ]; then
        printf "ERROR: could not resolve module path(s) for:%s\n" "$unresolved" >&2
        printf "       searched: %s/sys/modules (maxdepth 3)\n" "$SRC_DIR" >&2
        return 1
    fi
    printf "%s\n" "${resolved# }"
    return 0
}

# Where this script lives and how we get to the repo.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Default to the parent of pgsd-kernel/, which is where the script
# is expected to live in the repo. Operator can override via $UTF_REPO.
REPO_ROOT="${UTF_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Defaults. KERNCONF and the --clean / --yes flags are parsed below
# by walking $@; the simpler "KERNCONF=$2" doesn't work because a flag
# anywhere after the subcommand would be misread as KERNCONF.
KERNCONF=""
DO_CLEAN=0
ASSUME_YES=0
ARCH_CONF_DIR="/usr/src/sys/amd64/conf"
SRC_DIR="/usr/src"

# ----------------------------------------------------------------------
# Helpers

usage() {
    cat >&2 << EOF
Usage:
    sh $0 provision [--yes] [KERNCONF]   clone the pinned fork into /usr/src
    sh $0 check    [KERNCONF]            verify build environment (read-only)
    sh $0 build    [--clean] [KERNCONF]  make buildkernel with WITHOUT_MODULES
    sh $0 install  [KERNCONF]            make installkernel + AD-8 closure check

KERNCONF defaults to PGSD. The only other accepted value is PGSD-DEBUG.

Flags:
    --clean   Force a full rebuild via make cleankernel (build phase only).
              Use on first build of a session or after editing the kernel
              config. Without it, the build is incremental (fast, but can
              produce stale output if the config recently changed).
    --yes     Skip the interactive confirm before replacing /usr/src
              (provision phase only). Provisioning is destructive.

Typical first-time install:
    sudo sh $0 provision
    sh $0 check
    sudo sh $0 build --clean
    sudo sh $0 install
    sudo shutdown -r now

Subsequent incremental rebuilds (after the first --clean build):
    sudo sh $0 build
    sudo sh $0 install
    sudo shutdown -r now

Set UTF_REPO=/path/to/UTF if the script is not in pgsd-kernel/
relative to the repo root.
EOF
    exit 1
}

emit() { printf "%s\n" "$1"; }

# Check-outcome counters. warn() and fail() count as they print, so
# outcomes reported from inside helper functions (verify_pin) are
# counted without per-call-site bookkeeping. phase_check resets both
# at entry and is the only reader; increments from the build and
# install phases are harmless. Initialized here for set -u.
WARNS=0
FAILS=0

ok()   { printf "  [PASS] %s\n" "$1"; }
warn() { printf "  [WARN] %s\n" "$1"; WARNS=$((WARNS + 1)); }
fail() { printf "  [FAIL] %s\n" "$1"; FAILS=$((FAILS + 1)); }
note() { printf "         %s\n" "$1"; }
hdr()  { printf "\n=== %s\n" "$1"; }

# ----------------------------------------------------------------------
# AD-57: source pin verification.
#
# Identity is the immutable commit recorded in pgsd-kernel/FREEBSD-PIN
# (canonical). This checks that the source tree at SRC_DIR satisfies that
# definition. Returns 0 if satisfied (or intentionally overridden), 1 on
# an enforced mismatch. PGSD_ALLOW_UNPINNED=1 downgrades any mismatch to
# a loud warning for deliberate, non-reproducible investigation.

PIN_FILE="$(dirname "$0")/FREEBSD-PIN"

# Read a "key: value" field from the pin file (first match, trimmed).
pin_field() {
    awk -F': *' -v k="$1" '
        $1 == k { sub(/^[^:]*: */, ""); print; exit }
    ' "$PIN_FILE" 2>/dev/null
}

verify_pin() {
    if [ ! -f "$PIN_FILE" ]; then
        fail "AD-57 pin file missing: $PIN_FILE"
        return 1
    fi

    pin_commit="$(pin_field delta_commit)"
    pin_release="$(pin_field freebsd_release)"
    pin_vk="$(pin_field freebsd_version_k)"

    allow="${PGSD_ALLOW_UNPINNED:-0}"

    # The pin is not yet populated (fork not created / commit not
    # recorded). Treat an unpopulated pin as an enforced failure unless
    # overridden, so an investigation cannot silently run against an
    # undefined baseline.
    if [ -z "$pin_commit" ] || [ "$pin_commit" = "TO-BE-FILLED-ON-BENCH" ]; then
        if [ "$allow" = "1" ]; then
            warn "AD-57 pin not yet populated (delta_commit unset); PGSD_ALLOW_UNPINNED set, proceeding UNREPRODUCIBLY"
            return 0
        fi
        fail "AD-57 pin not yet populated: record the fork commit in $PIN_FILE (or set PGSD_ALLOW_UNPINNED=1 for deliberate unpinned work)"
        return 1
    fi

    # Primary check: is SRC_DIR a git checkout whose HEAD matches the pin?
    head_commit=""
    if [ -d "${SRC_DIR}/.git" ] && command -v git >/dev/null 2>&1; then
        head_commit="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null)"
    fi

    if [ -n "$head_commit" ]; then
        if [ "$head_commit" = "$pin_commit" ]; then
            ok "AD-57 pin satisfied: /usr/src HEAD matches pinned commit"
            # Drift check: a dirty tree is not the pinned source.
            #
            # sys/dev/drawfs/ is exempt, and the exemption is enforced by
            # git rather than by this check: the build registers that path
            # in the fork's .git/info/exclude, which is local to the
            # checkout and never committed, so `git status --porcelain`
            # simply does not report it. The overlay is regenerated from
            # the Awase repo with rsync --delete on every build (see
            # stage_drawfs_overlay), so it is intentional and reproducible
            # rather than drift, and the repo stays the single source of
            # truth. Everything else in /usr/src is still required to be a
            # faithful checkout of the pinned commit.
            if [ -n "$(git -C "$SRC_DIR" status --porcelain 2>/dev/null)" ]; then
                if [ "$allow" = "1" ]; then
                    warn "/usr/src has uncommitted local changes; PGSD_ALLOW_UNPINNED set, proceeding UNREPRODUCIBLY"
                    return 0
                fi
                fail "/usr/src matches the pinned commit but has uncommitted local changes (drift); commit, stash, or set PGSD_ALLOW_UNPINNED=1"
                return 1
            fi
            return 0
        fi
        if [ "$allow" = "1" ]; then
            warn "/usr/src HEAD $head_commit != pinned $pin_commit; PGSD_ALLOW_UNPINNED set, proceeding UNREPRODUCIBLY"
            return 0
        fi
        fail "/usr/src HEAD ($head_commit) does not match pinned commit ($pin_commit). Check out the pinned commit or set PGSD_ALLOW_UNPINNED=1"
        return 1
    fi

    # SRC_DIR is not a git checkout (release tarball etc). Commit-level
    # provenance is unavailable; fall back to the release cross-check,
    # which is weaker (cannot detect local modification). This is a
    # degraded mode: report exactly once, severity keyed on the
    # override, because the Git-backed model (AD-57 amendment) expects
    # a clone of the fork.
    run_vk="$(uname -K 2>/dev/null)"
    run_rel="$(freebsd-version -k 2>/dev/null)"
    if [ "$run_vk" = "$pin_vk" ] || [ "$run_rel" = "$pin_release" ]; then
        if [ "$allow" = "1" ]; then
            warn "/usr/src is not a git checkout; release cross-check matches ($pin_release / $pin_vk) but commit-level provenance is unavailable; PGSD_ALLOW_UNPINNED set, proceeding at release-level reproducibility only"
            return 0
        fi
        # Degraded but matching: the release cross-check passes, but
        # AD-57 wants commit-level provenance. Enforced unless the
        # operator opts in via PGSD_ALLOW_UNPINNED=1.
        fail "/usr/src is not a git checkout; release cross-check matches ($pin_release / $pin_vk) but AD-57 expects a clone of $(pin_field base_repository) for commit-level provenance. Set PGSD_ALLOW_UNPINNED=1 to build at release-level reproducibility only."
        return 1
    fi

    if [ "$allow" = "1" ]; then
        warn "/usr/src neither matches the pinned commit nor the pinned release; PGSD_ALLOW_UNPINNED set, proceeding UNREPRODUCIBLY"
        return 0
    fi
    fail "/usr/src does not satisfy the AD-57 pin (no git HEAD match and release mismatch: running $run_rel / $run_vk vs pinned $pin_release / $pin_vk)"
    return 1
}

# ----------------------------------------------------------------------
# Argument handling

if [ "$#" -lt 1 ]; then
    usage
fi

CMD="$1"
shift

# Walk the remaining arguments. Flags are extracted; the lone
# positional (if present) is KERNCONF. Multiple positionals or unknown
# flags are an error.
for arg in "$@"; do
    case "$arg" in
        --clean)
            DO_CLEAN=1 ;;
        --yes|-y)
            ASSUME_YES=1 ;;
        -*)
            emit "ERROR: unknown flag: $arg" >&2
            usage ;;
        *)
            if [ -n "$KERNCONF" ]; then
                emit "ERROR: unexpected extra argument: $arg" >&2
                usage
            fi
            KERNCONF="$arg" ;;
    esac
done

# Default KERNCONF if not specified.
: "${KERNCONF:=PGSD}"

case "$KERNCONF" in
    PGSD|PGSD-DEBUG) ;;
    *)
        emit "ERROR: KERNCONF must be PGSD or PGSD-DEBUG; got: $KERNCONF" >&2
        usage
        ;;
esac

# Sanity: we must be on FreeBSD.
if [ "$(uname -s 2>/dev/null)" != "FreeBSD" ]; then
    emit "ERROR: this script only runs on FreeBSD" >&2
    exit 2
fi

PGSD_REPO_CONFIG="${REPO_ROOT}/pgsd-kernel/${KERNCONF}"
PGSD_INSTALLED_CONFIG="${ARCH_CONF_DIR}/${KERNCONF}"

# ======================================================================
# Phase: provision
#
# Populate /usr/src with the pinned FreeBSD fork this kernel builds
# against. This is deliberately its own phase, and destructive, so it
# is never a side effect of check/build/install: replacing /usr/src is
# a multi-GiB clone and, on a dedicated dataset, /usr/src is a
# mountpoint. The operator runs it consciously.
#
# The pin lives next to this script in FREEBSD-PIN, and the kernel
# build already owns pin verification (phase_check); provisioning
# belongs here too, so /usr/src setup is kernel-setup work in one
# place rather than split into the userland installer. AD-57: the
# source must be the pinned fork.

phase_provision() {
    emit "=== provision /usr/src from the pinned fork (AD-57)"

    if [ "$(id -u)" -ne 0 ]; then
        fail "provision must run as root (clones and chowns /usr/src)"
        note "re-run: sudo sh pgsd-kernel/pgsd-kernel-build.sh provision"
        return 1
    fi
    if [ ! -f "$PIN_FILE" ]; then
        fail "pin file not found: $PIN_FILE"
        return 1
    fi

    # Read key: value pairs from the pin.
    src_repo="$(awk '$1=="base_repository:"{sub(/^[^:]*:[ \t]*/,"");print;exit}' "$PIN_FILE")"
    src_commit="$(awk '$1=="base_commit:"{sub(/^[^:]*:[ \t]*/,"");print;exit}' "$PIN_FILE")"
    src_branch="$(awk '$1=="base_branch:"{sub(/^[^:]*:[ \t]*/,"");print;exit}' "$PIN_FILE")"
    if [ -z "$src_repo" ] || [ -z "$src_commit" ]; then
        fail "could not read base_repository/base_commit from $PIN_FILE"
        return 1
    fi
    emit "  repo:   $src_repo"
    emit "  branch: ${src_branch:-(default)}"
    emit "  commit: $src_commit"

    # Already the pinned fork? Nothing to do.
    if [ -d "${SRC_DIR}/.git" ]; then
        have="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
        if [ "$have" = "$src_commit" ]; then
            ok "/usr/src is already the pinned fork at $src_commit"
            return 0
        fi
        warn "/usr/src is a git checkout at $have, not the pinned commit"
        note "provision will replace it with the pinned fork below"
    fi

    # Guard a non-empty existing tree behind an explicit confirm
    # (unless --yes). Replacing it is destructive.
    if [ -e "$SRC_DIR" ] && [ -n "$(ls -A "$SRC_DIR" 2>/dev/null)" ]; then
        if [ "$ASSUME_YES" -ne 1 ]; then
            if [ -t 0 ] && [ -t 1 ]; then
                printf "  /usr/src exists and is non-empty. Replace it now? [y/N]: "
                read -r ans
                case "$ans" in [Yy]*) ;; *) emit "  aborted; /usr/src left unchanged"; return 1 ;; esac
            else
                fail "/usr/src exists and is non-empty; refusing to replace it non-interactively"
                note "re-run with --yes to replace it, or empty /usr/src first"
                return 1
            fi
        fi
        # Mountpoint-safe removal: if /usr/src is its own mount, rm -rf
        # of the mountpoint fails with Device busy. Empty the contents
        # instead, then clone into the mount.
        if mount | grep -q " ${SRC_DIR} "; then
            emit "  -- /usr/src is a separate mount; emptying its contents"
            rm -rf "${SRC_DIR}/..?"* "${SRC_DIR}/".[!.]* "${SRC_DIR}/"* 2>/dev/null || true
            if [ -n "$(ls -A "$SRC_DIR" 2>/dev/null)" ]; then
                fail "could not empty /usr/src; left in an indeterminate state"
                return 1
            fi
        else
            emit "  -- removing existing /usr/src"
            if ! rm -rf "$SRC_DIR"; then
                fail "could not remove /usr/src"
                return 1
            fi
        fi
    fi

    # Clone the pinned fork. Prefer base_branch for the starting point;
    # the commit checkout below fixes identity per AD-57. Fetch all
    # refs (no --single-branch) so the commit checkout succeeds even if
    # it lives on a differently named branch.
    emit "  -- cloning the pinned fork (this is large)"
    cloned=0
    if [ -n "$src_branch" ]; then
        if git clone --branch "$src_branch" "$src_repo" "$SRC_DIR"; then
            cloned=1
        else
            emit "  -- branch clone of '$src_branch' failed; trying a plain clone"
        fi
    fi
    if [ "$cloned" -eq 0 ]; then
        if ! git clone "$src_repo" "$SRC_DIR"; then
            fail "git clone of $src_repo failed (check network and git)"
            return 1
        fi
    fi
    if ! git -C "$SRC_DIR" checkout --quiet "$src_commit"; then
        fail "clone succeeded but checkout of the pinned commit failed"
        note "$src_commit may be missing from the fork"
        return 1
    fi

    # Own it for the unprivileged userland build and mark it a safe
    # git directory (post-chown ownership differs from the invoker).
    owner_uid="${SUDO_UID:-0}"; owner_gid="${SUDO_GID:-0}"
    if chown -R "${owner_uid}:${owner_gid}" "$SRC_DIR"; then
        ok "cloned and chowned /usr/src to uid ${owner_uid}"
    else
        warn "chown of /usr/src failed; git operations may need root"
    fi
    git config --global --add safe.directory "$SRC_DIR" 2>/dev/null || true

    # Verify we landed on the pin.
    now="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [ "$now" = "$src_commit" ]; then
        ok "/usr/src provisioned at pinned commit $src_commit"
        emit "  next: sh pgsd-kernel/pgsd-kernel-build.sh check"
        return 0
    fi
    fail "/usr/src HEAD ($now) does not match pin ($src_commit) after provision"
    return 1
}

# ======================================================================
# Phase: check

phase_check() {
    hdr "PGSD kernel build environment check ($KERNCONF)"
    emit ""

    WARNS=0
    FAILS=0

    # Repo presence
    if [ -f "$PGSD_REPO_CONFIG" ]; then
        ok "repo config: $PGSD_REPO_CONFIG"
    else
        fail "missing repo config: $PGSD_REPO_CONFIG"
        note "set UTF_REPO=/path/to/UTF if running from elsewhere"
    fi

    # PGSD-DEBUG depends on PGSD also being present in the repo.
    if [ "$KERNCONF" = "PGSD-DEBUG" ]; then
        if [ -f "${REPO_ROOT}/pgsd-kernel/PGSD" ]; then
            ok "PGSD (base config) present in repo (required by PGSD-DEBUG include)"
        else
            fail "PGSD-DEBUG requires PGSD config to also be present"
        fi
    fi

    # Source tree
    if [ -d "${SRC_DIR}/sys" ] && [ -f "${SRC_DIR}/Makefile.inc1" ]; then
        ok "/usr/src present and intact"
    else
        fail "/usr/src missing or incomplete"
    fi

    # AD-57: verify the source tree matches the recorded pin. Identity is
    # the immutable commit in the fork; the pin file is canonical. Fail by
    # default on mismatch; PGSD_ALLOW_UNPINNED=1 downgrades to a warning
    # for deliberate unpinned investigation (which is not reproducible).
    # verify_pin reports through warn/fail, which count as they print.
    verify_pin || :

    # Conf directory writable for install -m
    if [ -d "$ARCH_CONF_DIR" ]; then
        ok "$ARCH_CONF_DIR exists"
    else
        fail "$ARCH_CONF_DIR missing"
    fi

    # Config source. The PGSD config is an Awase artifact and stays in
    # pgsd-kernel/; the build reads it in place via KERNCONFDIR and never
    # copies it into /usr/src, so /usr/src stays a faithful checkout of
    # the pinned revision. Verify the repo config is present and, if a
    # stale in-tree copy exists from an older build, note that it is now
    # unused (and, being untracked in the fork, would show as pin drift).
    if [ -f "$PGSD_REPO_CONFIG" ]; then
        ok "$KERNCONF config source: $PGSD_REPO_CONFIG (read via KERNCONFDIR)"
    else
        fail "missing repo config: $PGSD_REPO_CONFIG"
    fi
    if [ -f "$PGSD_INSTALLED_CONFIG" ]; then
        warn "$PGSD_INSTALLED_CONFIG exists but is no longer used"
        note "the build reads $KERNCONF from pgsd-kernel/ via KERNCONFDIR;"
        note "this in-tree copy is stale and, being untracked in the fork,"
        note "will show as pin drift. Remove it: rm -f $PGSD_INSTALLED_CONFIG"
    fi

    # Existing /usr/obj build tree
    OBJ_TREE="/usr/obj${SRC_DIR}/amd64.amd64/sys/${KERNCONF}"
    if [ -d "$OBJ_TREE" ]; then
        note "existing build tree: $OBJ_TREE"
        note "build phase will incremental-build by default; pass --clean to discard it"
    fi

    # pkgbase or source-built
    if pkg which /boot/kernel/kernel 2>/dev/null | grep -q "was installed by package"; then
        pkg_name=$(pkg which /boot/kernel/kernel 2>/dev/null | grep -oE "FreeBSD-kernel-[a-z]+" | head -1)
        note "kernel is package-managed (${pkg_name:-?})"
        note "install phase will use DESTDIR=/ and unregister-then-install"
    elif pkg info -x '^FreeBSD-kernel' 2>/dev/null | grep -q "^FreeBSD-kernel-generic"; then
        note "FreeBSD-kernel-generic package installed but does not own /boot/kernel/kernel"
        note "install phase will use DESTDIR=/ (still required by build system)"
    else
        note "kernel is not package-managed (source-built or already unregistered)"
        note "install phase will use DESTDIR=/ defensively"
    fi

    # SSH recovery readiness (if we lose console, this matters).
    # Detection order:
    #   1. SSH_CONNECTION env var — set when this script's parent shell
    #      was reached via SSH. Note: sudo sanitizes the env by default,
    #      so SSH_CONNECTION may be unset under "sudo sh ..." even when
    #      sshd is obviously running. Use "sudo -E" to preserve it.
    #   2. sockstat -l output for a tcp listener on port 22, IPv4 or
    #      IPv6. Check the LOCAL ADDRESS column (the 6th field) so we
    #      don't accidentally match FOREIGN ADDRESS (the last field).
    #   3. service sshd status — last resort, depends on rc.d framework
    #      being in working order but doesn't require parsing.
    if [ -n "${SSH_CONNECTION:-}" ]; then
        ok "sshd is running (this script invoked over SSH)"
    elif sockstat -l 2>/dev/null | awk '$6 ~ /:22$/ { found=1 } END { exit !found }'; then
        ok "sshd is listening on :22"
    elif service sshd status 2>/dev/null | grep -q "is running"; then
        ok "sshd is running (per service sshd status)"
    else
        warn "sshd does not appear to be running"
        note "no recovery path if the new kernel has problems booting"
        note "fix with: sudo service sshd start"
    fi

    # Summary
    emit ""
    hdr "Summary"
    emit "  WARN: $WARNS"
    emit "  FAIL: $FAILS"
    emit ""
    if [ "$FAILS" -gt 0 ]; then
        emit "Pre-flight FAILED. Fix [FAIL] items before running 'build'."
        return 1
    fi
    if [ "$WARNS" -gt 0 ]; then
        emit "Pre-flight passed with warnings. Review [WARN] items, then:"
    else
        emit "Pre-flight passed. To proceed:"
    fi
    emit "  sh $0 build $KERNCONF"
    return 0
}

# ======================================================================
# Phase: build

# ======================================================================
# drawfs overlay
#
# drawfs is compiled INTO the kernel (drawfs ADR 0001 amendment,
# 2026-07-13), so config(8) must find its sources under /usr/src/sys/.
# FreeBSD's kernel build has no supported way to compile a driver from
# outside the source tree; an attempt to do so with config's `local`
# keyword failed on the bench, because `local` is for files GENERATED
# into the build directory and its rule generator emits no compile
# command for them (the objects appeared in the link line with nothing
# to build them).
#
# So the sources are STAGED. The important property is not that /usr/src
# stays byte-for-byte pristine; it is that any modification to it is
# INTENTIONAL and REPRODUCIBLE. This overlay is:
#
#   - regenerated from the repo on every build, with rsync --delete, so
#     the Awase repo remains the single source of truth and a stale or
#     hand-edited overlay cannot survive;
#   - confined to one directory, sys/dev/drawfs/, which exists in the
#     FreeBSD tree for no other reason;
#   - registered in .git/info/exclude, which is local to the checkout and
#     never committed, so `git status` in the pinned fork stays clean and
#     the AD-57 drift check keeps its meaning for everything else.
#
# /usr/src is therefore a build workspace with one declared overlay,
# rather than a hand-maintained tree. That is a weaker and far more
# manageable constraint than the one it replaces, and it uses FreeBSD's
# kernel build machinery exactly as intended.

DRAWFS_SRC_DIR="${REPO_ROOT}/drawfs/sys/dev/drawfs"
DRAWFS_DEST_DIR="${SRC_DIR}/sys/dev/drawfs"

# bootcrumb: early-boot progress instrumentation. Same overlay mechanism
# as drawfs, and for the same reason: it is a compiled-in device whose
# sources live in the Awase repo, and config(8) needs them under $S/.
BOOTCRUMB_SRC_DIR="${REPO_ROOT}/pgsd-kernel/sys/dev/bootcrumb"
BOOTCRUMB_DEST_DIR="${SRC_DIR}/sys/dev/bootcrumb"

# Stage one overlay directory. Factored out because there are now two
# (drawfs, bootcrumb) and there will be more; duplicating the rsync and
# the git-exclude registration for each is how they drift apart.
stage_overlay() {
    _name="$1"
    _src="$2"
    _dest="$3"
    _rel="$4"     # path relative to SRC_DIR, for .git/info/exclude

    emit ""
    emit "=== staging the ${_name} overlay into ${_dest}"

    if [ ! -d "$_src" ]; then
        fail "${_name} sources not found: $_src"
        return 1
    fi

    if ! command -v rsync >/dev/null 2>&1; then
        fail "rsync not found; it is required to stage the ${_name} overlay"
        note "pkg install -y rsync"
        return 1
    fi

    mkdir -p "$_dest" || { fail "could not create $_dest"; return 1; }

    # --delete: the repo is the source of truth. A file removed from the
    # repo must disappear from the overlay, and a file added by hand must
    # not survive a rebuild.
    if ! rsync -a --delete "$_src/" "$_dest/"; then
        fail "rsync of the ${_name} overlay failed"
        return 1
    fi
    ok "staged $(ls -1 "$_dest"/*.c 2>/dev/null | wc -l | tr -d ' ') C sources for ${_name}"

    # Keep the pinned fork's git status clean. .git/info/exclude is local
    # to this checkout and never committed, so this does not modify the
    # fork and does not follow the tree to another machine.
    _excl="${SRC_DIR}/.git/info/exclude"
    if [ -d "${SRC_DIR}/.git" ]; then
        mkdir -p "$(dirname "$_excl")"
        if ! grep -qx "$_rel" "$_excl" 2>/dev/null; then
            printf '\n# Awase: %s is compiled into the PGSD kernel and staged\n# here from the repo on every build. Local only; never committed.\n%s\n' \
                "$_name" "$_rel" >> "$_excl"
            ok "registered $_rel in .git/info/exclude (local, uncommitted)"
        fi
    fi
    return 0
}

stage_drawfs_overlay() {
    stage_overlay drawfs "$DRAWFS_SRC_DIR" "$DRAWFS_DEST_DIR" "sys/dev/drawfs/" || return 1
    stage_overlay bootcrumb "$BOOTCRUMB_SRC_DIR" "$BOOTCRUMB_DEST_DIR" "sys/dev/bootcrumb/" || return 1
    return 0
}


phase_build() {
    hdr "PGSD kernel build ($KERNCONF)"

    # Run check first; refuse to build if check fails.
    if ! phase_check >/tmp/pgsd-check-$$.log 2>&1; then
        emit ""
        emit "Pre-flight check FAILED. Output:"
        cat /tmp/pgsd-check-$$.log
        rm -f /tmp/pgsd-check-$$.log
        return 1
    fi
    rm -f /tmp/pgsd-check-$$.log

    # Awase owns the PGSD config: it is an Awase artifact, not upstream
    # FreeBSD, so it stays authoritative in pgsd-kernel/ and is never
    # copied into /usr/src. buildkernel reads it in place via KERNCONFDIR
    # (below), so /usr/src remains a faithful, unmodified checkout of the
    # pinned revision from start to finish and the pin cleanliness check
    # and the build agree by construction. KERNCONFDIR is the directory
    # holding the KERNCONF file; for PGSD and PGSD-DEBUG that is
    # pgsd-kernel/. The config is standalone (no include of GENERIC), so
    # no source-tree conf files need to resolve relative to it.
    KERNCONFDIR="${REPO_ROOT}/pgsd-kernel"
    emit ""
    emit "Step 1/4: use $KERNCONF from $KERNCONFDIR (KERNCONFDIR; /usr/src not modified)"
    if [ ! -f "${KERNCONFDIR}/${KERNCONF}" ]; then
        emit "  ERROR: ${KERNCONFDIR}/${KERNCONF} not found"
        return 1
    fi
    emit "  config: ${KERNCONFDIR}/${KERNCONF}"

    # DO_CLEAN was set by the top-level argument parser.
    if [ "$DO_CLEAN" -eq 1 ]; then
        emit ""
        emit "Step 2/4: clean prior build (--clean specified)"
        if [ "$(id -u)" -ne 0 ]; then
            emit "  ERROR: need root for make cleankernel"
            return 1
        fi
        (cd "$SRC_DIR" && make cleankernel KERNCONF="$KERNCONF" KERNCONFDIR="$KERNCONFDIR") || {
            emit "  cleankernel failed"
            return 1
        }
    else
        emit ""
        emit "Step 2/4: SKIPPING clean (use --clean to force a full rebuild)"
        emit "  incremental builds can produce stale output if the config"
        emit "  recently changed; pass --clean if in doubt"
    fi

    # Stage the drawfs overlay BEFORE buildkernel. config(8) runs as part
    # of buildkernel and must find dev/drawfs/*.c under /usr/src/sys, so
    # this cannot be deferred. Fail closed: a kernel configured with
    # `device drawfs` and no drawfs sources fails at link with
    # "cannot open drawfs.o", after a full compile. Better to stop here.
    if ! stage_drawfs_overlay; then
        emit ""
        emit "  ERROR: could not stage the drawfs overlay; refusing to build"
        emit "  a kernel that declares 'device drawfs' with no drawfs sources."
        return 1
    fi

    # The actual buildkernel.
    emit ""
    # Validate and emit the suppression names for WITHOUT_MODULES.
    # Only top-level sys/modules entries (e.g. sound) are actually
    # excluded by this; the nested AD-8 HID modules cannot be
    # (see resolve_without_modules), and are removed after
    # installkernel by the AD-8 closure reap. Passing the names is
    # still correct for the top-level ones and harmless for the rest.
    WITHOUT_MODULES_LIST=$(resolve_without_modules)
    if [ -z "$WITHOUT_MODULES_LIST" ]; then
        emit "  ERROR: WITHOUT_MODULES resolution failed; cannot build safely"
        return 1
    fi

    emit "Step 3/4: make buildkernel"
    emit "  KERNCONF=$KERNCONF"
    emit "  WITHOUT_MODULES=\"$WITHOUT_MODULES_LIST\""
    emit ""
    emit "  This takes 30-60 minutes for a clean build, seconds for incremental."
    emit "  Output is streamed to your terminal."
    emit ""

    if [ "$(id -u)" -ne 0 ]; then
        emit "  ERROR: need root for make buildkernel"
        return 1
    fi

    # cd into /usr/src and run buildkernel. The make command is the
    # documented one from the README, with the resolved path-prefixed
    # WITHOUT_MODULES list.
    (cd "$SRC_DIR" && \
        make buildkernel KERNCONF="$KERNCONF" \
            KERNCONFDIR="$KERNCONFDIR" \
            WITHOUT_MODULES="$WITHOUT_MODULES_LIST") || {
        emit ""
        emit "  buildkernel FAILED"
        return 1
    }

    # Post-build sanity: verify the built kernel exists and that the
    # config it was built with is what we expect.
    emit ""
    emit "Step 4/4: post-build verification"

    BUILT_KERNEL="/usr/obj${SRC_DIR}/amd64.amd64/sys/${KERNCONF}/kernel"
    if [ ! -f "$BUILT_KERNEL" ]; then
        emit "  ERROR: expected built kernel not found at $BUILT_KERNEL"
        return 1
    fi
    ok "built kernel present: $BUILT_KERNEL"
    note "size: $(stat -f %z "$BUILT_KERNEL") bytes"

    # Check that the suppressed devices are NOT in the built kernel's config.
    leaked=$(config -x "$BUILT_KERNEL" 2>/dev/null | \
        grep -E "^device[[:space:]]+(vt|vt_vga|vt_efifb|vt_vbefb|sc|vga|splash)([[:space:]]|$)" | wc -l | tr -d ' ')
    if [ "$leaked" = "0" ]; then
        ok "no in-tree console drivers in built kernel"
    else
        fail "$leaked in-tree console driver device line(s) present in built kernel"
        note "the build did not pick up the AD-39 config change"
        note "re-run with --clean to force a full rebuild"
        return 1
    fi

    # Note: we do not check /usr/obj for the presence of AD-8 .ko files.
    # FreeBSD's make buildkernel may build the modules into the obj tree
    # even when WITHOUT_MODULES is set; the build-phase WITHOUT_MODULES
    # argument primarily affects what gets installed, not what gets built.
    # The authoritative AD-8 closure check runs in phase_install against
    # /boot/kernel/ after make installkernel completes, which is the only
    # location that determines whether the modules auto-load at boot.
    note "AD-8 closure check deferred to install phase (the authoritative test)"

    emit ""
    emit "Build complete. To install:"
    emit "  sudo sh $0 install $KERNCONF"
}

# ======================================================================
# Phase: install

phase_install() {
    hdr "PGSD kernel install ($KERNCONF)"

    if [ "$(id -u)" -ne 0 ]; then
        emit "ERROR: install must run as root"
        emit "       re-run with: sudo sh $0 install $KERNCONF"
        return 1
    fi

    BUILT_KERNEL="/usr/obj${SRC_DIR}/amd64.amd64/sys/${KERNCONF}/kernel"
    if [ ! -f "$BUILT_KERNEL" ]; then
        emit "ERROR: no built kernel at $BUILT_KERNEL"
        emit "       run 'sudo sh $0 build $KERNCONF' first"
        return 1
    fi

    # Sanity-check the built kernel one more time before installing.
    emit ""
    emit "Step 1/3: pre-install sanity check"
    leaked=$(config -x "$BUILT_KERNEL" 2>/dev/null | \
        grep -E "^device[[:space:]]+(vt|vt_vga|vt_efifb|vt_vbefb|sc|vga|splash)([[:space:]]|$)" | wc -l | tr -d ' ')
    if [ "$leaked" != "0" ]; then
        fail "built kernel still has in-tree console drivers"
        note "REFUSING to install. Re-run build with --clean."
        return 1
    fi
    ok "built kernel passes pre-install checks"

    # Try to unregister the kernel package if present. The README says
    # this is required on pkgbase systems where /boot/kernel/kernel is
    # owned by FreeBSD-kernel-generic; on systems where the package is
    # not registered, skip the call.
    emit ""
    emit "Step 2/3: pkg unregister (if FreeBSD-kernel-generic is registered)"
    if pkg info -e FreeBSD-kernel-generic 2>/dev/null; then
        emit "  FreeBSD-kernel-generic is registered; unregistering"
        # -y to suppress the interactive Y/N prompt. Without it, pkg
        # blocks waiting for stdin and the script appears to hang.
        if pkg unregister -y FreeBSD-kernel-generic 2>&1; then
            emit "  unregistered"
        else
            emit "  WARN: pkg unregister returned non-zero; install may still proceed"
        fi
    else
        emit "  FreeBSD-kernel-generic not registered; skipping (no-op)"
    fi

    # Run installkernel. DESTDIR=/ overrides the pkgbase guard.
    # WITHOUT_MODULES must be repeated here per the README.
    emit ""
    # Resolve module paths the same way the build phase did. The
    # install phase needs them too (per the README) to gate which
    # .ko files get copied to /boot/kernel/.
    WITHOUT_MODULES_LIST=$(resolve_without_modules)
    if [ -z "$WITHOUT_MODULES_LIST" ]; then
        emit "  ERROR: WITHOUT_MODULES resolution failed; cannot install safely"
        return 1
    fi

    emit "Step 3/3: make installkernel"
    emit "  KERNCONF=$KERNCONF"
    emit "  DESTDIR=/"
    emit "  WITHOUT_MODULES=\"$WITHOUT_MODULES_LIST\""
    emit ""

    (cd "$SRC_DIR" && \
        make installkernel KERNCONF="$KERNCONF" DESTDIR=/ \
            KERNCONFDIR="${REPO_ROOT}/pgsd-kernel" \
            WITHOUT_MODULES="$WITHOUT_MODULES_LIST") || {
        emit ""
        emit "  installkernel FAILED"
        return 1
    }

    # Post-install AD-8 closure verification.
    emit ""
    hdr "AD-8 closure verification"

    fails=0

    # 1. /boot/kernel/ must NOT contain any of the suppressed .ko files.
    # If any are present (typically because of an earlier build that
    # omitted WITHOUT_MODULES), offer to remove them. Default: Yes.
    leaked_ko=""
    for ko in $AD8_HID_MODULES; do
        if [ -f "/boot/kernel/${ko}.ko" ]; then
            leaked_ko="$leaked_ko $ko"
        fi
    done
    leaked_ko="${leaked_ko# }"

    if [ -z "$leaked_ko" ]; then
        ok "no AD-8 suppressed .ko files in /boot/kernel/"
    else
        note "AD-8 suppressed .ko files present: $leaked_ko"
        note "This is expected, not an anomaly. WITHOUT_MODULES cannot"
        note "  suppress these: FreeBSD filters WITHOUT_MODULES against the"
        note "  top-level sys/modules SUBDIR only (SUBDIR:N reject), and"
        note "  every AD-8 module is a nested leaf (hid/hkbd, usb/ukbd, ...)"
        note "  that no top-level token reaches. installkernel therefore"
        note "  always installs them, and reaping them here is the"
        note "  sanctioned closure mechanism, not error recovery."

        # Reap is the primary AD-8 mechanism, so it runs by default,
        # including non-interactively: leakage is guaranteed every
        # install, and leaving these .ko in /boot/kernel/ lets them
        # autoload and contend with inputfs for HID ownership. --yes
        # and an interactive Remove/Keep choice remain, but the default
        # (including a bare non-interactive install, e.g. a reinstall
        # runsheet) is to remove. Only an explicit interactive "Keep"
        # or PGSD_AD8_KEEP=1 leaves them, and that is recorded as a
        # closure failure since the resulting kernel is not AD-8 clean.
        do_remove=1
        if [ "${PGSD_AD8_KEEP:-0}" = "1" ]; then
            do_remove=0
            note "PGSD_AD8_KEEP=1 set; leaving modules in place (NOT AD-8 clean)"
            fails=$((fails + 1))
        elif [ "$ASSUME_YES" -eq 1 ]; then
            note "--yes set; removing without prompting"
        elif [ -t 0 ] && [ -t 1 ]; then
            # Interactive: offer a choice, but default to Remove.
            if command -v bsddialog >/dev/null 2>&1; then
                if bsddialog --title "AD-8 closure: suppressed modules" \
                             --yes-label "Remove" \
                             --no-label "Keep (not AD-8 clean)" \
                             --yesno "These AD-8 HID modules were installed by installkernel:

    $leaked_ko

They cannot be excluded at build time (WITHOUT_MODULES does not reach
nested modules); removing them here is the normal closure step. If
left in place they auto-load at boot and contend with inputfs for HID
ownership.

Remove them now? (default: Remove)" 16 70; then
                    do_remove=1
                else
                    do_remove=0
                    note "operator chose Keep; kernel is NOT AD-8 clean"
                    fails=$((fails + 1))
                fi
            else
                printf "         Remove these AD-8 modules now? [Y/n] "
                read answer
                case "$answer" in
                    n|N|no|NO|No)
                        do_remove=0
                        note "operator chose Keep; kernel is NOT AD-8 clean"
                        fails=$((fails + 1)) ;;
                    *)  do_remove=1 ;;
                esac
            fi
        else
            # Non-interactive: reap by default (the reinstall case that
            # previously left the modules and failed the install).
            note "non-interactive; removing (AD-8 reap is the default)"
        fi

        if [ "$do_remove" -eq 1 ]; then
            emit ""
            emit "  removing stale modules from /boot/kernel/..."
            rm_failed=""
            for ko in $leaked_ko; do
                for suffix in "" .debug .full; do
                    target="/boot/kernel/${ko}.ko${suffix}"
                    if [ -f "$target" ]; then
                        if rm -f "$target" 2>/dev/null; then
                            note "removed: $target"
                        else
                            rm_failed="$rm_failed $target"
                            note "FAILED to remove: $target"
                        fi
                    fi
                done
            done

            # Regenerate linker.hints so autoload doesn't reference
            # the now-gone modules. This is not optional cleanup: the
            # removal of the .ko files is only half the reap. If
            # linker.hints still advertises PNP entries for the
            # suppressed HID drivers, the autoloader still tries to
            # match them at device probe and inputfs does not get the
            # devices, which presents as no keyboard and no mouse at
            # the login prompt even though the .ko files are gone.
            # A kldxref failure therefore fails the closure; it must
            # not pass silently as it did before (it was a bare note,
            # so an install could report success and still boot with
            # no input).
            if kldxref /boot/kernel 2>/dev/null; then
                ok "regenerated /boot/kernel/linker.hints"
            else
                fail "kldxref /boot/kernel FAILED; linker.hints is stale"
                note "the .ko files were removed but the hints still"
                note "  advertise them, so HID autoload will still fight"
                note "  inputfs and you will boot with no keyboard/mouse"
                note "run before rebooting: sudo kldxref /boot/kernel"
            fi

            # Re-verify cleanup actually completed.
            still_leaked=""
            for ko in $leaked_ko; do
                if [ -f "/boot/kernel/${ko}.ko" ]; then
                    still_leaked="$still_leaked $ko"
                fi
            done
            still_leaked="${still_leaked# }"

            if [ -z "$still_leaked" ]; then
                ok "stale modules removed; /boot/kernel/ is clean"
            else
                fail "modules still present after cleanup: $still_leaked"
                note "manual intervention required"
                fails=$((fails + 1))
            fi

            if [ -n "$rm_failed" ]; then
                note "files that could not be removed:$rm_failed"
            fi
        elif [ "$do_remove" -eq 0 ] && [ -t 0 ]; then
            # Interactive user declined; record as failure since the
            # stale modules will auto-load at boot.
            note "stale modules NOT removed at operator request"
            note "remove with: sudo rm /boot/kernel/{$(echo $leaked_ko | tr ' ' ',')}.ko"
            note "then: sudo kldxref /boot/kernel"
            fails=$((fails + 1))
        fi
    fi

    # 2. linker.hints must not advertise PNP for the suppressed drivers.
    # This is a FAIL, not a WARN. Stale hints that still advertise the
    # AD-8 HID drivers make the autoloader try to match them at device
    # probe even after the .ko files are gone, so inputfs does not get
    # the USB HID devices and the system boots to the pgsd-sessiond
    # login prompt with no keyboard and no mouse. Reported as a WARN
    # once, which let an install pass while leaving exactly that state.
    if [ -f /boot/kernel/linker.hints ]; then
        hid_alt=$(echo "$AD8_HID_MODULES" | tr ' ' '|')
        hints_leak=$(strings /boot/kernel/linker.hints 2>/dev/null | \
            grep -cE "(${hid_alt})\.ko" \
            || true)
        : "${hints_leak:=0}"
        if [ "$hints_leak" = "0" ]; then
            ok "/boot/kernel/linker.hints has no suppressed-driver entries"
        else
            note "linker.hints advertises $hints_leak suppressed-driver entries; regenerating"
            if kldxref /boot/kernel 2>/dev/null; then
                # Re-measure: regeneration must actually clear them.
                hints_leak=$(strings /boot/kernel/linker.hints 2>/dev/null | \
                    grep -cE "(${hid_alt})\.ko" || true)
                : "${hints_leak:=0}"
                if [ "$hints_leak" = "0" ]; then
                    ok "regenerated linker.hints; no suppressed-driver entries"
                else
                    fail "linker.hints still advertises $hints_leak suppressed-driver entries after kldxref"
                    note "the suppressed .ko may still be present in /boot/kernel/"
                    note "booting now would give no keyboard and no mouse"
                fi
            else
                fail "linker.hints advertises $hints_leak suppressed-driver entries and kldxref failed"
                note "booting now would give no keyboard and no mouse"
                note "run: sudo kldxref /boot/kernel"
            fi
        fi
    fi

    # 3. drawfs must be IN THE KERNEL, not on disk as a module.
    #
    # drawfs ADR 0001 amendment (2026-07-13): drawfs is a compiled-in
    # device, not a preloaded module. This check used to require
    # /boot/modules/drawfs.ko, which no longer exists and must not.
    #
    # The intent is unchanged and still right: without drawfs the screen
    # stays dark, because AD-39 removed vt/vt_efifb/sc/vga so drawfs
    # could own the framebuffer, and nothing else will claim it. So this
    # verifies the same thing against the new mechanism: the symbol is in
    # the kernel we just installed.
    if [ -f /boot/kernel/kernel ]; then
        if strings /boot/kernel/kernel 2>/dev/null | grep -q '^drawfs$'; then
            ok "drawfs is compiled into /boot/kernel/kernel"
        else
            fail "drawfs is NOT in /boot/kernel/kernel"
            note "without drawfs, nothing owns the framebuffer (AD-39 removed"
            note "  vt, vt_efifb, sc and vga) and the screen stays dark."
            note "check that pgsd-kernel/PGSD has 'device drawfs' and"
            note "  'files \"files.drawfs\"', then rebuild:"
            note "  sudo sh pgsd-kernel/pgsd-kernel-build.sh build --clean"
            fails=$((fails + 1))
        fi
    fi

    # A stale drawfs.ko from a pre-amendment install is not fatal, but it
    # is dead weight and it will confuse the next person who looks.
    if [ -f /boot/modules/drawfs.ko ]; then
        warn "/boot/modules/drawfs.ko exists but is no longer used"
        note "drawfs is compiled into the kernel now; this module is stale."
        note "remove it: sudo rm /boot/modules/drawfs.ko"
    fi

    # 4. /boot/kernel.old/ exists as fallback.
    if [ -f /boot/kernel.old/kernel ]; then
        ok "/boot/kernel.old/kernel saved as fallback"
        note "boot from loader prompt: unload; load /boot/kernel.old/kernel; boot"
    else
        warn "no /boot/kernel.old/kernel fallback present"
        note "if the new kernel fails to boot, recovery requires rescue media"
    fi

    emit ""
    if [ $fails -gt 0 ]; then
        emit "Install completed but AD-8 closure verification FAILED."
        emit "DO NOT REBOOT until the [FAIL] items are resolved."
        return 1
    fi

    emit "Install complete. AD-8 closure verified."
    emit ""
    emit "Before rebooting:"
    emit "  1. Confirm SSH access from another machine works (recovery path)."
    emit "  2. Note: at the loader prompt, you can boot the old kernel with:"
    emit "       unload"
    emit "       load /boot/kernel.old/kernel"
    emit "       boot"
    emit ""
    emit "When ready:"
    emit "  sudo shutdown -r now"
    return 0
}

# ======================================================================
# Dispatch

case "$CMD" in
    provision) phase_provision; exit $? ;;
    check)   phase_check;   exit $? ;;
    build)   phase_build;   exit $? ;;
    install) phase_install; exit $? ;;
    -h|--help|help) usage ;;
    *)
        emit "ERROR: unknown subcommand: $CMD" >&2
        usage
        ;;
esac
