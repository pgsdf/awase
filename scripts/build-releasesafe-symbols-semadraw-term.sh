#!/bin/sh
# build-releasesafe-symbols-semadraw-term.sh — diagnostic build for AD-14.
#
# Standard install.sh produces a stripped ReleaseSafe binary. AD-14
# investigation needs the same optimization (so the panic reproduces)
# but with debug symbols (so lldb can resolve fault addresses to
# source lines).
#
# This script rebuilds only semadraw-term with -Doptimize=ReleaseSafe
# -Dstrip=false and installs over the existing binary. The daemons
# stay ReleaseSafe-stripped (no diagnosis needed there).
#
# Usage:
#   sh scripts/build-releasesafe-symbols-semadraw-term.sh
#
# After diagnosis, run 'sudo sh install.sh' to restore the standard
# stripped binary.
#
# To run under lldb after this:
#   sudo conscontrol mute on
#   sudo lldb /usr/local/bin/semadraw-term
#   (lldb) settings set -- target.run-args --scale 2
#   (lldb) run
#   # type 'ls' on framebuffer keyboard, press Enter
#   # if panic fires, lldb catches SIGABRT
#   (lldb) bt
#   (lldb) frame select 0
#   (lldb) frame variable
#
# See BACKLOG.md AD-14 for context.

set -eu

if ! TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "error: not in a git repo" >&2
    exit 1
fi
cd "$TOPLEVEL"

echo "=== building semadraw-term in ReleaseSafe with symbols ==="
cd semadraw
sudo zig build -Doptimize=ReleaseSafe -Dstrip=false \
    -Dvulkan=false -Dx11=false -Dwayland=false -Dbsdinput=false 2>&1 | tail -10
cd ..

echo "=== installing binary ==="
sudo cp semadraw/zig-out/bin/semadraw-term /usr/local/bin/semadraw-term.NEW.$$
sudo chmod 755 /usr/local/bin/semadraw-term.NEW.$$
sudo mv /usr/local/bin/semadraw-term.NEW.$$ /usr/local/bin/semadraw-term

echo ""
echo "=== verify symbols present ==="
file /usr/local/bin/semadraw-term

echo ""
echo "=== ready ==="
echo "Run lldb /usr/local/bin/semadraw-term"
echo ""
echo "After diagnosis, run 'sudo sh install.sh' to restore stripped binary."
