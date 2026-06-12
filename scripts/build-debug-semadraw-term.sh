#!/bin/sh
# build-debug-semadraw-term.sh — rebuild semadraw-term in Debug mode and install.
#
# semadraw-term has a build-mode discrepancy tracked as BACKLOG.md AD-14:
# under -Doptimize=ReleaseSafe (install.sh's default) it panics during
# normal terminal operation, with `index N, len M` attributions whose
# `len M` values do not match any plain reading of the source array on
# the reported line. Under -Doptimize=Debug (no inlining, accurate debug
# info) the same input sequence produces a fully-functioning terminal:
# prompt renders, typing reaches the shell, `ls` runs and displays
# output, the operator can type and read normally.
#
# This script provides the operator workaround until AD-14 closes:
# rebuild only semadraw-term in Debug mode and install over the
# ReleaseSafe binary that install.sh produced. The daemons stay
# ReleaseSafe (no known issues there). To restore the ReleaseSafe
# semadraw-term, run install.sh again.
#
# This is a diagnostic build, not a permanent operational state.
# AD-14 sub-stages (lldb on the optimized binary, source UB audit,
# minimal reproducer) are the path to root-cause diagnosis.
#
# Usage:
#   sh scripts/build-debug-semadraw-term.sh

set -eu

if ! TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "error: not in a git repo" >&2
    exit 1
fi
cd "$TOPLEVEL"

echo "=== building semadraw-term in Debug mode ==="
cd semadraw
sudo zig build -Doptimize=Debug -Dvulkan=false -Dx11=false -Dwayland=false -Dbsdinput=false 2>&1 | tail -10
cd ..

echo "=== installing debug binary ==="
sudo cp semadraw/zig-out/bin/semadraw-term /usr/local/bin/semadraw-term.NEW.$$
sudo chmod 755 /usr/local/bin/semadraw-term.NEW.$$
sudo mv /usr/local/bin/semadraw-term.NEW.$$ /usr/local/bin/semadraw-term

echo ""
echo "=== ready ==="
echo "Run:                sudo conscontrol mute on"
echo "Then:               sudo /usr/local/bin/semadraw-term --scale 2"
echo ""
echo "When AD-14 closes (release-mode discrepancy understood and fixed),"
echo "run 'sudo sh install.sh' to restore the ReleaseSafe build."
