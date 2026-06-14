#!/bin/sh
# bootstrap.sh - fetch and vendor the pinned Zig toolchain for Awase.
#
# Downloads the pinned Zig release into sdk/zig/current so the project
# builds with a repository-local compiler and never depends on a
# system-installed Zig. Idempotent: a no-op when the toolchain is
# already present. Intended for FreeBSD; uses fetch(1) and tar(1).
#
# Upgrading Zig is a deliberate repository change: edit ZIG_VERSION
# (and ZIG_TARGET if the host changes) below, re-run this script, and
# commit the edit. Nothing else in the build references the version,
# every caller goes through sdk/zig/current.
set -eu

# Pinned toolchain identity.
ZIG_VERSION="0.16.0"
ZIG_TARGET="x86_64-freebsd"

# Resolve the repository root relative to this script's own location so
# the script behaves the same regardless of the caller's working
# directory. tools/ sits directly under the repository root.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

zig_dir="$repo_root/sdk/zig"
current="$zig_dir/current"

# Already vendored and runnable: nothing to do.
if [ -x "$current/zig" ]; then
    exit 0
fi

mkdir -p "$zig_dir"

archive="zig-${ZIG_TARGET}-${ZIG_VERSION}.tar.xz"
extracted="zig-${ZIG_TARGET}-${ZIG_VERSION}"
url="https://ziglang.org/download/${ZIG_VERSION}/${archive}"

# Temporary workspace, removed on any exit (success, error, or signal).
tmp=$(mktemp -d "${TMPDIR:-/tmp}/awase-zig.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

echo "bootstrap: fetching Zig ${ZIG_VERSION} (${ZIG_TARGET})" >&2
fetch -o "$tmp/$archive" "$url"

echo "bootstrap: extracting" >&2
tar -xf "$tmp/$archive" -C "$tmp"

if [ ! -x "$tmp/$extracted/zig" ]; then
    echo "bootstrap: archive did not yield an executable zig at $extracted/zig" >&2
    exit 1
fi

# Install into sdk/zig/current. Stage under a sibling temp name on the
# destination filesystem, then swap, so an interrupted run never leaves
# a half-populated current/.
staging="$zig_dir/.current.incoming"
rm -rf "$staging" "$current"
mv "$tmp/$extracted" "$staging"
mv "$staging" "$current"

echo "bootstrap: installed Zig $("$current/zig" version) at $current" >&2
