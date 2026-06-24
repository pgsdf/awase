#!/bin/sh
# be-reboot-proof.sh  (AD-56 Phase 0 criterion 4: end-to-end BE reboot proof)
#
# Proves the recovery path Phase 0.5 reduction depends on: that a
# non-active boot environment can be selected at the FreeBSD loader menu
# and booted. The loader selection is a HUMAN action at the console; this
# script does only the scriptable halves (arm before, verify after) and
# hands off to the operator in between. It deliberately does NOT
# bectl-activate the target, because that would prove the activate path
# (already proven) while bypassing the manual loader selection that is
# the actual thing under test.
#
# Usage:
#   sudo sh be-reboot-proof.sh arm    TARGET_BE   # before reboot (SSH)
#   <reboot, select TARGET_BE at the loader BE menu by hand, boot it>
#   sudo sh be-reboot-proof.sh verify TARGET_BE   # after reboot (SSH)
#
# State is left in /var/tmp/awase-be-proof/ between the two phases.

set -u
STATE_DIR="/var/tmp/awase-be-proof"
PHASE="${1:-}"
TARGET="${2:-}"

[ "$(id -u)" -ne 0 ] && { echo "run as root: sudo sh $0 ..." >&2; exit 2; }
case "$PHASE" in arm|verify) ;; *)
  echo "usage: $0 arm|verify TARGET_BE" >&2; exit 2;; esac
[ -z "$TARGET" ] && { echo "give the target BE name (e.g. known-good-pre-ad56)" >&2; exit 2; }

active_be() { bectl list -H 2>/dev/null | awk '$2 ~ /N/ {print $1; exit}'; }
root_ds()   { mount | awk '$3 == "/" {print $1; exit}'; }

if [ "$PHASE" = "arm" ]; then
  mkdir -p "$STATE_DIR"
  # Confirm the target exists and is NOT currently active (so the proof is meaningful).
  if ! bectl list -H 2>/dev/null | awk '{print $1}' | grep -qx "$TARGET"; then
    echo "ERROR: BE '$TARGET' does not exist. bectl list:" >&2
    bectl list >&2
    exit 1
  fi
  cur="$(active_be)"
  if [ "$cur" = "$TARGET" ]; then
    echo "ERROR: '$TARGET' is already the active BE. The proof must boot a" >&2
    echo "NON-active BE selected at the loader, or it proves nothing." >&2
    exit 1
  fi

  # Record the before-state and the expected after-state.
  {
    echo "target_be='$TARGET'"
    echo "armed_at='$(date '+%Y-%m-%d %H:%M:%S')'"
    echo "active_before='$cur'"
    echo "root_ds_before='$(root_ds)'"
    echo "kernel_before='$(uname -a)'"
    echo "bootfile_before='$(sysctl -n kern.bootfile 2>/dev/null)'"
  } > "$STATE_DIR/before"

  echo "==== armed: BE reboot proof ===="
  echo "target BE (to select at loader) : $TARGET"
  echo "active BE now                    : $cur"
  echo "root dataset now                 : $(root_ds)"
  echo
  echo "NEXT (operator, at the console):"
  echo "  1. sudo reboot"
  echo "  2. at the FreeBSD loader, open the Boot Environments menu"
  echo "  3. SELECT '$TARGET' by hand (do NOT just let it boot default)"
  echo "  4. boot it"
  echo "  5. back on SSH: sudo sh $0 verify $TARGET"
  echo
  echo "NOTE: '$TARGET' is the never-modified rollback target. Boot in,"
  echo "let verify run, then boot back out. Do NOT write to it (no updates,"
  echo "installs, or edits) while booted into it, or it stops being pristine."
  exit 0
fi

# --- verify phase ---
if [ ! -f "$STATE_DIR/before" ]; then
  echo "ERROR: no armed state in $STATE_DIR. Run 'arm' before rebooting." >&2
  exit 1
fi
. "$STATE_DIR/before"

cur="$(active_be)"
rds="$(root_ds)"
target_ds="$(bectl list -H 2>/dev/null | awk -v t="$TARGET" '$1==t {print}' | head -1)"

echo "==== verify: BE reboot proof ===="
echo "expected target BE : $TARGET"
echo "armed before-active: $active_before   (root was $root_ds_before)"
echo "now-active BE      : $cur"
echo "now-root dataset   : $rds"
echo "kernel before      : $kernel_before"
echo "kernel now         : $(uname -a)"
echo

# The proof: are we running on the TARGET BE's root, not the before BE?
# bectl marks the booted-but-not-persistent BE differently across versions,
# so check the actual root dataset, which is ground truth.
case "$rds" in
  *"$TARGET"*)
    echo "RESULT: PASS. Root is the target BE ($TARGET)."
    echo "The loader booted the manually-selected non-active BE. The"
    echo "recovery path Phase 0.5 reduction depends on is proven on hardware."
    VERDICT=pass
    ;;
  "$root_ds_before")
    echo "RESULT: INCONCLUSIVE. Root is unchanged from before ($root_ds_before)."
    echo "The system likely booted the default BE, not '$TARGET'. Either the"
    echo "loader selection did not take, or default was selected. Re-run the"
    echo "reboot and select '$TARGET' explicitly at the loader BE menu."
    VERDICT=inconclusive
    ;;
  *)
    echo "RESULT: UNEXPECTED. Root ($rds) is neither the target nor the"
    echo "before BE. Inspect manually before trusting recovery."
    VERDICT=unexpected
    ;;
esac
echo

# Restore guidance: confirm whether the persistent boot target is still default.
nr="$(bectl list -H 2>/dev/null | awk '$2 ~ /R/ {print $1; exit}')"
echo "persistent next-boot (R) BE: ${nr:-<none/one-shot>}"
if [ "$nr" = "$active_before" ] || [ -z "$nr" ]; then
  echo "RESTORE: next normal reboot returns to '$active_before' on its own"
  echo "(this was a one-shot loader selection). A plain 'sudo reboot' is enough."
else
  echo "RESTORE: persistent boot is '$nr', not the original '$active_before'."
  echo "Run: sudo bectl activate $active_before   then reboot, to return."
fi

[ "$VERDICT" = pass ] && echo && echo "Criterion 4 reboot proof: COMPLETE."
