#!/bin/sh
# AD-51 guard verification.
#
# Exercises the two install.sh hardening guards without running a
# full install:
#   1. the per-slot exec-target check that runs after the s6 cp loop
#      (a slot named X must exec PREFIX/bin/X), and
#   2. the pre-build dirty-tree warning over s6/.
#
# Operates entirely in a scratch dir under /tmp and reads the repo
# read-only; it touches nothing live and needs no root, so it is
# safe to run on the desktop machine at any time. It mirrors the
# guard logic in install.sh verbatim (the grep pattern and the git
# status check); if those change, change this too.
#
# Expected result: ALL LEGS GREEN. Leg 2 is additionally confirmed
# live by the "verified each slot execs its own binary" line that a
# normal clean install prints.

set -u

PREFIX="/usr/local"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0

# The exact check install.sh runs after the s6 cp loop, factored
# here as a function. Returns nonzero on the first slot whose run
# does not exec its own binary.
verify_slot() {
	for svc_name in semadrawd pgsd-sessiond semasound; do
		if ! grep -q "^exec $PREFIX/bin/$svc_name" "$1/$svc_name/run"; then
			echo "      mismatch: $1/$svc_name/run does not exec $PREFIX/bin/$svc_name"
			return 1
		fi
	done
	return 0
}

# Stage a three-slot tree; semasound is overridden to exec $2, so
# passing "semadrawd" reproduces the AD-50 corruption shape and
# passing "semasound" produces a correct tree.
stage() {
	for s in semadrawd pgsd-sessiond semasound; do
		mkdir -p "$1/$s"
		printf '#!/bin/sh\nexec %s/bin/%s\n' "$PREFIX" "$s" > "$1/$s/run"
	done
	printf '#!/bin/sh\nexec %s/bin/%s\n' "$PREFIX" "$2" > "$1/semasound/run"
}

WORK="$(mktemp -d /tmp/ad51-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "== Leg 1: exec-target guard must ABORT on a mis-slotted run (AD-50 shape)"
stage "$WORK/bad" semadrawd
if verify_slot "$WORK/bad"; then
	echo "   FAIL: guard passed a tree whose semasound slot execs semadrawd"
	FAILS=$((FAILS + 1))
else
	echo "   PASS: guard rejected the mismatch"
fi

echo "== Leg 2: exec-target guard must PASS a correct tree (no false abort)"
stage "$WORK/good" semasound
if verify_slot "$WORK/good"; then
	echo "   PASS: guard accepted the correct tree"
else
	echo "   FAIL: guard rejected a correct tree"
	FAILS=$((FAILS + 1))
fi

echo "== Leg 3: dirty-tree warning logic over s6/"
if command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
	d=$(git -C "$REPO" status --porcelain -- s6/ 2>/dev/null || true)
	if [ -n "$d" ]; then
		echo "   s6/ is dirty now; a real install would print the warning for:"
		echo "$d" | sed 's/^/      /'
		echo "   (this is the warning path firing, not a failure)"
	else
		echo "   PASS: s6/ clean, warning correctly silent"
		echo "   (to watch it fire: touch a tracked s6 file, re-run, then restore)"
	fi
else
	echo "   SKIP: not a git tree"
fi

echo
if [ "$FAILS" -eq 0 ]; then
	echo "== ALL LEGS GREEN. AD-51 guards verified."
else
	echo "== $FAILS leg(s) failed."
	exit 1
fi
