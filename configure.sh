#!/bin/sh
# UTF backend configuration — interactive backend selection using bsddialog.
#
# Usage:
#   sh configure.sh          # interactive selection, then build
#   sh configure.sh --build  # build immediately after selection
#   sh configure.sh --show   # show current configuration without building
#
# Writes selected options to .config in the UTF root directory.
# build.sh and install.sh read .config automatically if present.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/.config"
BUILD=0
SHOW=0

# Detect OS family. Sets UTF_OS and UTF_OS_VERSION. See scripts/detect-os.sh
# for rationale — we detect, record, and message, but do not branch build
# behavior on the result unless there is a concrete reason.
. "$SCRIPT_DIR/scripts/detect-os.sh"

# ============================================================================
# Argument parsing
# ============================================================================

for arg in "$@"; do
    case "$arg" in
        --build) BUILD=1 ;;
        --show)  SHOW=1  ;;
        --help|-h)
            sed -n '2,10p' "$0" | sed 's/^# \?//'
            exit 0 ;;
    esac
done

# ============================================================================
# Show current config
# ============================================================================

if [ "$SHOW" -eq 1 ]; then
    if [ -f "$CONFIG" ]; then
        echo "Current configuration ($CONFIG):"
        cat "$CONFIG"
    else
        echo "No configuration file found. Run: sh configure.sh"
    fi
    exit 0
fi

# ============================================================================
# Check for bsddialog
#
# The fallback plain-text path is a superset of the bsddialog path: both must
# produce the same set of variables (VULKAN, X11, WAYLAND, BSDINPUT, DRAWFS_DRM)
# because the single `cat > $CONFIG` block at the bottom consumes them.
# ============================================================================

if ! command -v bsddialog >/dev/null 2>&1; then
    echo "bsddialog not found — falling back to plain text menu."
    echo ""
    echo "Select backends to enable (y/n):"
    printf "  Vulkan (requires vulkan-headers, vulkan-loader) [y/N]: "; read -r WANT_VULKAN
    printf "  X11 (requires libX11) [y/N]: "; read -r WANT_X11
    printf "  Wayland (requires libwayland-client) [y/N]: "; read -r WANT_WAYLAND
    printf "  bsdinput / libinput (requires libinput, libudev-devd) [y/N]: "; read -r WANT_BSDINPUT
    # DRM/KMS for drawfs is OPTIONAL and off by default. The DRM-less swap
    # path is the unbreakable default; DRM requires drm-kmod headers to build.
    printf "  drawfs DRM/KMS backend (optional, requires drm-kmod) [y/N]: "; read -r WANT_DRM

    case "$WANT_VULKAN"   in [yY]) VULKAN=true   ;; *) VULKAN=false   ;; esac
    case "$WANT_X11"      in [yY]) X11=true      ;; *) X11=false      ;; esac
    case "$WANT_WAYLAND"  in [yY]) WAYLAND=true  ;; *) WAYLAND=false  ;; esac
    case "$WANT_BSDINPUT" in [yY]) BSDINPUT=true ;; *) BSDINPUT=false ;; esac
    case "$WANT_DRM"      in [yY]) DRAWFS_DRM=true ;; *) DRAWFS_DRM=false ;; esac
else

# ============================================================================
# bsddialog checklist
# ============================================================================

TMPFILE=$(mktemp /tmp/utf-config.XXXXXX)
trap 'rm -f $TMPFILE' EXIT

bsddialog \
    --title "UTF Backend Configuration" \
    --checklist "Select optional backends to enable.\n\nThe software and drawfs (swap-backed /dev/draw) backends are\nalways included — they are the DRM-less default path.\n\nVulkan, X11, Wayland, and bsdinput are semadraw userspace backends.\nThe drawfs DRM/KMS backend is a kernel-side option that requires\ndrm-kmod headers; if unchecked (default), drawfs.ko is built with\nzero DRM references and uses the swap-backed path exclusively.\n\nUse SPACE to toggle, ENTER to confirm." \
    0 0 0 \
    "vulkan"     "Vulkan (requires vulkan-headers, vulkan-loader)"  off \
    "x11"        "X11 (requires libX11)"                            off \
    "wayland"    "Wayland (requires libwayland-client)"             off \
    "bsdinput"   "bsdinput (requires libinput, libudev-devd)"       off \
    "drawfs_drm" "drawfs DRM/KMS backend (requires drm-kmod)"       off \
    2>"$TMPFILE" || {
        echo "Cancelled."
        exit 0
    }

SELECTED=$(cat "$TMPFILE")

VULKAN=false; X11=false; WAYLAND=false; BSDINPUT=false; DRAWFS_DRM=false

for item in $SELECTED; do
    case "$item" in
        vulkan)     VULKAN=true     ;;
        x11)        X11=true        ;;
        wayland)    WAYLAND=true    ;;
        bsdinput)   BSDINPUT=true   ;;
        drawfs_drm) DRAWFS_DRM=true ;;
    esac
done

fi # end bsddialog block

# ============================================================================
# Warn loudly when DRM is selected. The user is opting into a build
# that requires headers we do not otherwise require. On FreeBSD 15.0
# the FreeBSD-ports-kmods repo may need to be disabled to avoid a
# version mismatch with the base drm-kmod port.
# ============================================================================

if [ "$DRAWFS_DRM" = "true" ]; then
    echo ""
    echo "NOTE: drawfs DRM/KMS backend enabled."
    echo "      This requires the drm-kmod port/package:"
    echo "          pkg install drm-kmod"
    case "$UTF_OS" in
    freebsd)
        echo "      Detected FreeBSD $UTF_OS_VERSION. On 15.0-RELEASE the"
        echo "      FreeBSD-ports-kmods repo may need to be disabled to avoid"
        echo "      a version mismatch with FreeBSD-ports."
        ;;
    *)
        echo "      Host OS: $UTF_OS $UTF_OS_VERSION"
        ;;
    esac
    echo "      drawfs.ko will still prefer the swap backend at runtime"
    echo "      unless you set: sysctl hw.drawfs.backend=drm"
    echo "      DRM init failure at module load falls back to swap."
    echo ""
fi

# ============================================================================
# Write config
# ============================================================================

cat > "$CONFIG" << EOF
# UTF build configuration — generated by configure.sh on $(date)
# Edit manually or re-run: sh configure.sh
#
# Host OS detected at configure time. build.sh re-detects at build time
# and warns if this record is stale (e.g. .config was copied between hosts).
UTF_OS=$UTF_OS
UTF_OS_VERSION=$UTF_OS_VERSION
SEMADRAW_VULKAN=$VULKAN
SEMADRAW_X11=$X11
SEMADRAW_WAYLAND=$WAYLAND
SEMADRAW_BSDINPUT=$BSDINPUT
# drawfs kernel module options.
# DRAWFS_DRM is OFF by default. When false, drawfs.ko is built purely
# swap-backed with zero DRM references (no drm-kmod dependency).
# When true, drawfs_drm.c is compiled in and -DDRAWFS_DRM_ENABLED is set;
# the runtime default is still "swap" via hw.drawfs.backend.
DRAWFS_DRM=$DRAWFS_DRM
EOF

echo ""
echo "Configuration saved to $CONFIG:"
cat "$CONFIG"
echo ""

# ============================================================================
# Optionally build
# ============================================================================

if [ "$BUILD" -eq 1 ]; then
    sh "$SCRIPT_DIR/build.sh"
fi

echo "To build:   sh build.sh"
echo "To install: sh install.sh"
