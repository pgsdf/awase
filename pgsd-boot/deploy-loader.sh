#!/bin/sh
#
# deploy-loader.sh -- deploy the AD-59 loader adapter into a boot
# environment's /boot/lua for loader-stage experiments.
#
# The loader adapter (local.lua) and the bootstrap module
# (pgsd_bootstrap.lua) are NOT installed by install.sh: they are
# loader-stage experiment scaffolding, not part of the installed Awase
# product. They must be copied into the target boot environment's
# /boot/lua by hand, and doing that by hand has twice half-deployed (a
# missed or newline-split copy left the module current and the adapter
# stale, producing a confusing stale-code boot). This script does both
# copies as one step and verifies the result, so the deploy is atomic and
# self-checking.
#
# Usage:
#   deploy-loader.sh                 deploy into the running BE's /boot/lua
#   deploy-loader.sh <mountpoint>    deploy into an already-mounted BE
#
# Deploying into the running BE requires that the running BE be the one you
# intend to boot for the experiment. To deploy into a different BE, mount it
# first (bectl mount <be> <mountpoint>) and pass the mountpoint.
#
# This script does not activate or reboot. It only deploys and verifies.
# It must be run as root (it writes under /boot).

set -eu

# Resolve the source directory (the lua/ dir next to this script).
script_dir=$(cd "$(dirname "$0")" && pwd)
src_dir="${script_dir}/lua"
src_module="${src_dir}/pgsd_bootstrap.lua"
src_adapter="${src_dir}/local.lua.example"

target_root="${1:-}"
boot_lua="${target_root}/boot/lua"

dst_module="${boot_lua}/pgsd_bootstrap.lua"
dst_adapter="${boot_lua}/local.lua"

for f in "$src_module" "$src_adapter"; do
	if [ ! -f "$f" ]; then
		echo "error: source not found: $f" >&2
		exit 1
	fi
done

if [ ! -d "$boot_lua" ]; then
	echo "error: target /boot/lua not found: $boot_lua" >&2
	echo "       (for a non-running BE, bectl mount it first and pass" >&2
	echo "        its mountpoint as the argument)" >&2
	exit 1
fi

echo "Deploying AD-59 loader adapter:"
echo "  module  ${src_module}"
echo "      ->  ${dst_module}"
echo "  adapter ${src_adapter}"
echo "      ->  ${dst_adapter}"

cp "$src_module" "$dst_module"
cp "$src_adapter" "$dst_adapter"

# Verify the deploy: the copied files must be byte-identical to the source.
# cmp exits non-zero (and set -e aborts) on any difference, so a partial or
# failed copy cannot pass silently.
cmp "$src_module" "$dst_module"
cmp "$src_adapter" "$dst_adapter"

echo "OK: both files deployed and verified identical to source."
echo ""
echo "Next: activate the target BE for the experiment boot and reboot,"
echo "watching the physical console for the pre-menu output. The adapter"
echo "pauses (io.getchar) so the output can be read before boot continues."
