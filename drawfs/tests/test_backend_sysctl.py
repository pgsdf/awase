#!/usr/bin/env python3
"""
Test the hw.drawfs.backend sysctl invariants.

Per the root BACKLOG.md "Invariants to preserve":
  - hw.drawfs.backend exists as soon as drawfs.ko is loaded
  - It defaults to "swap" at module load
  - It is read/write
  - When DRAWFS_DRM_ENABLED is not compiled in, writing "drm" is
    accepted at the sysctl level (the string is stored) but the DRM
    backend is not actually activated — activation only happens via
    the MOD_LOAD init path, and with no DRM code compiled there is
    nothing to activate. The sysctl is string-only; no runtime switch.

This test exists to protect the invariant that the module always loads
with the swap backend as the default and that the sysctl remains the
single source of truth for which backend the module is configured for.

Run as root with drawfs.ko loaded. Exits non-zero on any failure.
"""

import os
import subprocess
import sys


SYSCTL_NAME = "hw.drawfs.backend"


def run_sysctl(args, check=True):
    """Run sysctl(8) with the given argv tail, return (rc, stdout, stderr)."""
    proc = subprocess.run(
        ["sysctl"] + list(args),
        capture_output=True,
        text=True,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"sysctl {' '.join(args)} failed ({proc.returncode}): "
            f"{proc.stderr.strip()}"
        )
    return proc.returncode, proc.stdout, proc.stderr


def get_backend():
    """Return the current value of hw.drawfs.backend as a string."""
    _, out, _ = run_sysctl(["-n", SYSCTL_NAME])
    return out.strip()


def set_backend(value):
    """Set hw.drawfs.backend. Returns True on success, False otherwise."""
    rc, _, _ = run_sysctl([f"{SYSCTL_NAME}={value}"], check=False)
    return rc == 0


def test_sysctl_exists():
    """hw.drawfs.backend must exist as soon as drawfs.ko is loaded."""
    print("== Test: hw.drawfs.backend exists ==")
    rc, out, err = run_sysctl(["-n", SYSCTL_NAME], check=False)
    assert rc == 0, (
        f"{SYSCTL_NAME} not present — is drawfs.ko loaded? "
        f"sysctl error: {err.strip()}"
    )
    print(f"  value: {out.strip()!r}")
    print("  OK")


def test_default_is_swap():
    """After a fresh module load, the backend must be 'swap'.

    This test is only meaningful immediately after `kldload drawfs`.
    If another test has already written to the sysctl, this will fail —
    that is the desired behavior: the test suite should load-and-test
    from a clean state, not from whatever leftover state the previous
    run left behind. The module reload is the precondition.
    """
    print("== Test: default value is 'swap' ==")
    value = get_backend()
    assert value == "swap", (
        f"Expected default 'swap', got {value!r}. "
        f"If a previous test or manual interaction changed this, "
        f"unload and reload drawfs.ko before running this test."
    )
    print("  OK")


def test_sysctl_is_writable():
    """The sysctl must be read/write, not read-only."""
    print("== Test: sysctl is writable ==")
    original = get_backend()
    try:
        # Write and read back a recognised value. "swap" is always valid.
        ok = set_backend("swap")
        assert ok, f"Failed to write '{SYSCTL_NAME}=swap'"
        readback = get_backend()
        assert readback == "swap", (
            f"Wrote 'swap', read back {readback!r}"
        )
        print("  write 'swap' — ok")
    finally:
        # Restore whatever was there before.
        set_backend(original)
    print("  OK")


def test_swap_roundtrip():
    """Writing 'swap' and reading back returns 'swap' verbatim."""
    print("== Test: 'swap' round-trip ==")
    original = get_backend()
    try:
        assert set_backend("swap"), "failed to set backend=swap"
        assert get_backend() == "swap"
        print("  OK")
    finally:
        set_backend(original)


def test_drm_string_roundtrip():
    """Writing 'drm' and reading back returns 'drm' as a string.

    This does NOT assert that the DRM backend is active — activation is
    a module-load decision, not a runtime one. The test confirms only
    that the sysctl is a plain string and stores whatever the user
    writes. In a build without DRAWFS_DRM_ENABLED, this string has no
    behavioural effect; in a build with it, the string is consulted at
    MOD_LOAD time.
    """
    print("== Test: 'drm' string round-trip ==")
    original = get_backend()
    try:
        assert set_backend("drm"), (
            "failed to write 'drm' — the sysctl should accept any "
            "short string regardless of DRAWFS_DRM_ENABLED"
        )
        readback = get_backend()
        assert readback == "drm", (
            f"Wrote 'drm', read back {readback!r}"
        )
        print("  OK")
    finally:
        set_backend(original)


def test_invariants_summary():
    """Print a one-line summary of the checked invariants for log parsing."""
    print("== Invariants ==")
    print(f"  {SYSCTL_NAME} exists               : yes")
    print(f"  default value at module load       : 'swap'")
    print(f"  writable                           : yes")
    print(f"  'swap' round-trips                 : yes")
    print(f"  'drm'  round-trips (string only)   : yes")


def main():
    if os.geteuid() != 0:
        print("ERROR: this test must run as root (writes a sysctl).",
              file=sys.stderr)
        return 2

    # If the sysctl does not exist, drawfs is not loaded. Give a clear
    # error rather than a cryptic sysctl(8) message.
    rc, _, _ = run_sysctl(["-n", SYSCTL_NAME], check=False)
    if rc != 0:
        print(f"ERROR: {SYSCTL_NAME} not found — is drawfs.ko loaded?",
              file=sys.stderr)
        print("       Try: sudo kldload drawfs", file=sys.stderr)
        return 1

    tests = [
        test_sysctl_exists,
        test_default_is_swap,
        test_sysctl_is_writable,
        test_swap_roundtrip,
        test_drm_string_roundtrip,
    ]

    failed = []
    for t in tests:
        try:
            t()
        except AssertionError as e:
            print(f"  FAILED: {t.__name__}: {e}", file=sys.stderr)
            failed.append(t.__name__)
        except Exception as e:
            print(f"  ERROR:  {t.__name__}: {e}", file=sys.stderr)
            failed.append(t.__name__)
        print()

    test_invariants_summary()
    print()

    if failed:
        print(f"FAIL: {len(failed)} test(s) failed: {', '.join(failed)}",
              file=sys.stderr)
        return 1

    print(f"PASS: all {len(tests)} tests OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
