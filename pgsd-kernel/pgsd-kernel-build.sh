#!/bin/sh
# pgsd-kernel-build.sh — three-phase PGSD kernel build/install script.
#
# Why this script exists
# ----------------------
# PGSD kernel correctness depends on getting two things right at every
# rebuild:
#
#   1. WITHOUT_MODULES must be passed to BOTH make buildkernel AND make
#      installkernel. AD-8 explains why: without it, the .ko files for
#      the suppressed HID drivers (hkbd, ukbd, hms, hgame, hcons, hsctrl,
#      utouch, hpen, hmt, hconf, hidmap) get built and installed, and
#      the kernel auto-loads them at device probe time. They then claim
#      ownership of the USB HID devices, and inputfs has nothing to bind
#      to. The result: keyboard and mouse stop working.
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

# Bare module names: what humans understand and what AD-3 and
# AD-8 actually mean. AD-8 covers the HID drivers (hkbd ukbd hms
# hgame hcons hsctrl hpen hmt hconf hidmap); AD-3 covers the snd
# entries (hda sound cmi csa emu10kx es137x ich via8233).
# Used for verification (looking for .ko files in /boot/kernel/) and for
# user-facing log lines. NOT passed directly to make: see resolve_without_modules.
WITHOUT_MODULES_NAMES="hkbd ukbd hms hgame hcons hsctrl hpen hmt hconf hidmap hda sound cmi csa emu10kx es137x ich via8233"

# resolve_without_modules: convert bare module names into the
# path-prefixed form make buildkernel actually understands.
#
# FreeBSD kernel modules live under /usr/src/sys/modules/<group>/<name>/.
# The "group" is usually "hid" (most HID drivers) but some modules live
# elsewhere -- ukbd is under usb/ukbd, for example. Passing a bare name
# like "ukbd" to make's WITHOUT_MODULES does NOT match usb/ukbd, which
# is why our earlier builds failed to suppress the modules.
#
# This helper walks /usr/src/sys/modules looking for each name and
# returns the path-prefixed form (e.g. "hid/hkbd usb/ukbd hid/hms ...").
# Echoes the resolved list to stdout. Any name not found in the source
# tree is echoed to stderr; exit code 1 means "one or more names did
# not resolve". The caller decides whether to proceed.
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
            # Strip the leading /usr/src/sys/modules/ to get hid/hkbd or usb/ukbd.
            path="${found#${SRC_DIR}/sys/modules/}"
            resolved="$resolved $path"
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
    sh $0 check    [KERNCONF]            verify build environment (read-only)
    sh $0 build    [--clean] [KERNCONF]  make buildkernel with WITHOUT_MODULES
    sh $0 install  [KERNCONF]            make installkernel + AD-8 closure check

KERNCONF defaults to PGSD. The only other accepted value is PGSD-DEBUG.

Flags:
    --clean   Force a full rebuild via make cleankernel (build phase only).
              Use on first build of a session or after editing the kernel
              config. Without it, the build is incremental (fast, but can
              produce stale output if the config recently changed).

Typical first-time install:
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

ok()   { printf "  [PASS] %s\n" "$1"; }
warn() { printf "  [WARN] %s\n" "$1"; }
fail() { printf "  [FAIL] %s\n" "$1"; }
note() { printf "         %s\n" "$1"; }
hdr()  { printf "\n=== %s\n" "$1"; }

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
# Phase: check

phase_check() {
    hdr "PGSD kernel build environment check ($KERNCONF)"
    emit ""

    fails=0
    warns=0

    # Repo presence
    if [ -f "$PGSD_REPO_CONFIG" ]; then
        ok "repo config: $PGSD_REPO_CONFIG"
    else
        fail "missing repo config: $PGSD_REPO_CONFIG"
        note "set UTF_REPO=/path/to/UTF if running from elsewhere"
        fails=$((fails + 1))
    fi

    # PGSD-DEBUG depends on PGSD also being present in the repo.
    if [ "$KERNCONF" = "PGSD-DEBUG" ]; then
        if [ -f "${REPO_ROOT}/pgsd-kernel/PGSD" ]; then
            ok "PGSD (base config) present in repo (required by PGSD-DEBUG include)"
        else
            fail "PGSD-DEBUG requires PGSD config to also be present"
            fails=$((fails + 1))
        fi
    fi

    # Source tree
    if [ -d "${SRC_DIR}/sys" ] && [ -f "${SRC_DIR}/Makefile.inc1" ]; then
        ok "/usr/src present and intact"
    else
        fail "/usr/src missing or incomplete"
        fails=$((fails + 1))
    fi

    # Conf directory writable for install -m
    if [ -d "$ARCH_CONF_DIR" ]; then
        ok "$ARCH_CONF_DIR exists"
    else
        fail "$ARCH_CONF_DIR missing"
        fails=$((fails + 1))
    fi

    # Installed config matches repo
    if [ -f "$PGSD_INSTALLED_CONFIG" ] && [ -f "$PGSD_REPO_CONFIG" ]; then
        if cmp -s "$PGSD_REPO_CONFIG" "$PGSD_INSTALLED_CONFIG"; then
            ok "installed $KERNCONF matches repo"
        else
            warn "installed $KERNCONF differs from repo"
            note "build phase will sync it before running buildkernel"
            warns=$((warns + 1))
        fi
    elif [ ! -f "$PGSD_INSTALLED_CONFIG" ]; then
        warn "$PGSD_INSTALLED_CONFIG does not exist yet"
        note "build phase will install it"
        warns=$((warns + 1))
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
        warns=$((warns + 1))
    fi

    # Summary
    emit ""
    hdr "Summary"
    emit "  WARN: $warns"
    emit "  FAIL: $fails"
    emit ""
    if [ $fails -gt 0 ]; then
        emit "Pre-flight FAILED. Fix [FAIL] items before running 'build'."
        return 1
    fi
    if [ $warns -gt 0 ]; then
        emit "Pre-flight passed with warnings. Review [WARN] items, then:"
    else
        emit "Pre-flight passed. To proceed:"
    fi
    emit "  sh $0 build $KERNCONF"
    return 0
}

# ======================================================================
# Phase: build

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

    # Sync the repo config into /usr/src/sys/amd64/conf/. The install
    # below copies the dev-side config into the source tree.
    emit ""
    emit "Step 1/4: sync $KERNCONF config into source tree"
    if ! cmp -s "$PGSD_REPO_CONFIG" "$PGSD_INSTALLED_CONFIG" 2>/dev/null; then
        if [ "$(id -u)" -ne 0 ]; then
            emit "  ERROR: need root to write $PGSD_INSTALLED_CONFIG"
            emit "         re-run with: sudo sh $0 build $KERNCONF"
            return 1
        fi
        install -m 0644 "$PGSD_REPO_CONFIG" "$PGSD_INSTALLED_CONFIG"
        emit "  installed: $PGSD_REPO_CONFIG -> $PGSD_INSTALLED_CONFIG"
    else
        emit "  already in sync; nothing to do"
    fi

    # PGSD-DEBUG also needs the base PGSD config in the conf directory.
    if [ "$KERNCONF" = "PGSD-DEBUG" ]; then
        if ! cmp -s "${REPO_ROOT}/pgsd-kernel/PGSD" "${ARCH_CONF_DIR}/PGSD" 2>/dev/null; then
            install -m 0644 "${REPO_ROOT}/pgsd-kernel/PGSD" "${ARCH_CONF_DIR}/PGSD"
            emit "  installed: PGSD (base) -> ${ARCH_CONF_DIR}/PGSD"
        fi
    fi

    # DO_CLEAN was set by the top-level argument parser.
    if [ "$DO_CLEAN" -eq 1 ]; then
        emit ""
        emit "Step 2/4: clean prior build (--clean specified)"
        if [ "$(id -u)" -ne 0 ]; then
            emit "  ERROR: need root for make cleankernel"
            return 1
        fi
        (cd "$SRC_DIR" && make cleankernel KERNCONF="$KERNCONF") || {
            emit "  cleankernel failed"
            return 1
        }
    else
        emit ""
        emit "Step 2/4: SKIPPING clean (use --clean to force a full rebuild)"
        emit "  incremental builds can produce stale output if the config"
        emit "  recently changed; pass --clean if in doubt"
    fi

    # The actual buildkernel.
    emit ""
    # Resolve bare module names to their source-tree paths. make
    # buildkernel matches WITHOUT_MODULES entries against the directory
    # structure under sys/modules/, so we must pass "hid/hkbd usb/ukbd"
    # rather than the bare "hkbd ukbd" — passing bare names silently
    # fails to match modules whose source isn't directly under sys/modules/.
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
    for ko in hkbd ukbd hms hgame hcons hsctrl utouch hpen hmt hconf hidmap; do
        if [ -f "/boot/kernel/${ko}.ko" ]; then
            leaked_ko="$leaked_ko $ko"
        fi
    done
    leaked_ko="${leaked_ko# }"

    if [ -z "$leaked_ko" ]; then
        ok "no AD-8 suppressed .ko files in /boot/kernel/"
    else
        fail "AD-8 suppressed .ko files installed: $leaked_ko"
        note "WITHOUT_MODULES did not take effect on installkernel"
        note "  (most often: an earlier buildkernel ran without WITHOUT_MODULES)"

        # Decide whether to offer removal.
        do_remove=0
        if [ "$ASSUME_YES" -eq 1 ]; then
            do_remove=1
            note "--yes set; removing without prompting"
        elif [ -t 0 ] && [ -t 1 ]; then
            # Interactive: bsddialog if available; plain prompt otherwise.
            if command -v bsddialog >/dev/null 2>&1; then
                if bsddialog --title "AD-8 closure: stale modules" \
                             --yes-label "Remove" \
                             --no-label "Keep (abort)" \
                             --yesno "The following stale AD-8 modules were found in /boot/kernel/:

    $leaked_ko

These must be removed; if left in place they auto-load at boot and
contend with inputfs for HID ownership.

Remove them now? (default: Remove)" 15 70; then
                    do_remove=1
                fi
            else
                # Plain prompt. Default Yes; pressing Enter accepts.
                printf "         Remove these files now? [Y/n] "
                read answer
                case "$answer" in
                    n|N|no|NO|No) do_remove=0 ;;
                    *)            do_remove=1 ;;
                esac
            fi
        else
            # Non-interactive without --yes: do not modify silently.
            note "non-interactive without --yes; not removing automatically"
            note "remove with: sudo rm /boot/kernel/{$(echo $leaked_ko | tr ' ' ',')}.ko"
            note "then: sudo kldxref /boot/kernel"
            fails=$((fails + 1))
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
            # the now-gone modules.
            if kldxref /boot/kernel 2>/dev/null; then
                note "ran: kldxref /boot/kernel"
            else
                note "WARN: kldxref /boot/kernel failed; rerun manually"
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
    if [ -f /boot/kernel/linker.hints ]; then
        hints_leak=$(strings /boot/kernel/linker.hints 2>/dev/null | \
            grep -cE "(hkbd|ukbd|hms|hgame|hcons|hsctrl|utouch|hpen|hmt|hconf|hidmap)\.ko" \
            || true)
        : "${hints_leak:=0}"
        if [ "$hints_leak" = "0" ]; then
            ok "/boot/kernel/linker.hints has no suppressed-driver entries"
        else
            warn "/boot/kernel/linker.hints advertises $hints_leak suppressed-driver entries"
            note "rerun: sudo kldxref /boot/kernel"
        fi
    fi

    # 3. drawfs.ko must be present at /boot/modules/.
    if [ -f /boot/modules/drawfs.ko ]; then
        ok "/boot/modules/drawfs.ko present"
    else
        fail "/boot/modules/drawfs.ko missing"
        note "without drawfs.ko, the screen will stay dark after reboot"
        note "rerun: cd $REPO_ROOT && sh install.sh"
        fails=$((fails + 1))
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
    check)   phase_check;   exit $? ;;
    build)   phase_build;   exit $? ;;
    install) phase_install; exit $? ;;
    -h|--help|help) usage ;;
    *)
        emit "ERROR: unknown subcommand: $CMD" >&2
        usage
        ;;
esac
