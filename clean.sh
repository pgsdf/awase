#!/bin/sh
# UTF cleanup script — remove Zig build artifacts and root build logs.
#
# Usage:
#   sh clean.sh              # list candidates, prompt y/N, remove on confirm
#   sh clean.sh --dry-run    # list candidates, do not remove
#   sh clean.sh --force      # remove without prompting (for CI / scripts)
#   sh clean.sh --help       # show this help
#
# Removes:
#   - every  .zig-cache/  directory under the UTF root
#   - every  zig-out/     directory under the UTF root
#   - root-level build logs: build-*.log and the build-latest.log symlink
#
# Does NOT touch:
#   - anything under .git/
#   - /usr/src, /boot, /usr/obj or anything outside the UTF checkout
#   - .config, configure.sh output, or any source file
#   - the drawfs kernel-module build (that's under /usr/src — use
#     `drawfs/build.sh` for that if you need to clean it)
#
# The script refuses to run if it cannot verify it is inside a
# UTF-shaped tree (presence of build.zig + shared/ + drawfs/).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=0
FORCE=0

# ============================================================================
# Argument parsing
# ============================================================================

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1   ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "unknown argument: $arg" >&2
            echo "try: sh clean.sh --help" >&2
            exit 2 ;;
    esac
done

# ============================================================================
# Sanity check: are we inside a UTF checkout?
#
# This guards against a configuration accident (e.g. SCRIPT_DIR resolving to
# somewhere surprising) wiping things we shouldn't touch. All three markers
# must be present before we do anything.
# ============================================================================

if [ ! -f "$SCRIPT_DIR/build.zig" ] \
   || [ ! -d "$SCRIPT_DIR/shared" ] \
   || [ ! -d "$SCRIPT_DIR/drawfs" ]; then
    echo "ERROR: $SCRIPT_DIR does not look like a UTF checkout." >&2
    echo "       Refusing to clean anything." >&2
    exit 1
fi

cd "$SCRIPT_DIR"

# ============================================================================
# Discover candidates.
#
# -prune keeps find(1) from descending into .git or into an already-matched
# cache directory (cheaper, and avoids listing nested zig-out/.zig-cache/).
# ============================================================================

# Use a tmpfile rather than a shell variable so we preserve newlines cleanly
# across /bin/sh implementations and so the listing can be re-read twice
# (once for display, once for deletion).
TMPLIST=$(mktemp -t utf-clean.XXXXXX)
trap 'rm -f "$TMPLIST"' EXIT

find . \
    -name .git -type d -prune -o \
    \( -name .zig-cache -o -name zig-out \) -type d -print -prune \
    > "$TMPLIST"

# Root-level build artifacts. Symlinks are matched by -maxdepth 1 and the
# explicit -name pattern; both regular files and the dangling/live
# build-latest.log symlink are captured.
find . -maxdepth 1 \( -name 'build-*.log' -o -name 'build-latest.log' \) \
    \( -type f -o -type l \) -print >> "$TMPLIST"

# Sort and de-dup for stable output. Also strip leading "./" for readability.
sort -u "$TMPLIST" | sed 's|^\./||' > "$TMPLIST.sorted"
mv "$TMPLIST.sorted" "$TMPLIST"

if [ ! -s "$TMPLIST" ]; then
    echo "Nothing to clean. The tree is already pristine."
    exit 0
fi

# ============================================================================
# Report, with a size total. du is best-effort — failures are silent because
# some platforms complain about vanished files or symlinks mid-walk.
# ============================================================================

COUNT=$(wc -l < "$TMPLIST" | tr -d ' ')
TOTAL=$(xargs du -sch < "$TMPLIST" 2>/dev/null | awk 'END{print $1}')
TOTAL=${TOTAL:-unknown}

echo "UTF cleanup — $COUNT item(s), approximately $TOTAL:"
echo ""
# Prefix each line with a marker for visual clarity.
sed 's/^/  /' "$TMPLIST"
echo ""

# ============================================================================
# Dry run: list only, exit success without touching anything.
# ============================================================================

if [ "$DRY_RUN" -eq 1 ]; then
    echo "(dry run — nothing removed)"
    exit 0
fi

# ============================================================================
# Confirm unless --force. Read from /dev/tty so piped input can't silently
# auto-confirm; if there is no tty (e.g. running under a supervisor without
# --force), refuse rather than guess.
# ============================================================================

if [ "$FORCE" -ne 1 ]; then
    # Choose a source for the answer. We actually attempt to open /dev/tty
    # rather than trusting [ -r /dev/tty ], because on some systems (notably
    # containers without a controlling terminal) the test reports readable
    # but the open at read(1) time fails. Attempting to read a single
    # throwaway byte is the only reliable probe.
    TTY_OK=0
    if (: < /dev/tty) 2>/dev/null; then
        TTY_OK=1
    fi

    if [ "$TTY_OK" -eq 0 ] && [ ! -t 0 ] && [ ! -p /dev/stdin ]; then
        echo "ERROR: no tty or stdin available for confirmation." >&2
        echo "       Re-run with --force if this is intentional." >&2
        exit 1
    fi

    printf "Remove these? [y/N]: "
    if [ "$TTY_OK" -eq 1 ]; then
        read -r ANSWER < /dev/tty
    else
        read -r ANSWER
    fi
    case "$ANSWER" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# ============================================================================
# Do the work. rm -rf for directories, rm -f for files/symlinks. xargs -0
# would be tidier but we don't have NUL-delimited output from find here;
# these paths never contain whitespace in a UTF checkout (build-YYYYMMDD-…).
# ============================================================================

REMOVED=0
FAILED=0
while IFS= read -r path; do
    [ -z "$path" ] && continue
    if rm -rf -- "$path" 2>/dev/null; then
        echo "  removed  $path"
        REMOVED=$((REMOVED + 1))
    else
        echo "  FAILED   $path" >&2
        FAILED=$((FAILED + 1))
    fi
done < "$TMPLIST"

echo ""
echo "Done. Removed $REMOVED item(s)."
if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED item(s) could not be removed (see errors above)." >&2
    exit 1
fi
exit 0
