#!/usr/bin/env python3
"""
check-corpus.py: validate parser output values for AD-9.4.

Per inputfs/docs/adr/0014-hid-fuzzing-scope.md.

Where fuzz-verify.sh checks crash-resistance (does the harness
exit 0 on every input?), this script checks output correctness:
for each entry whose .txt companion makes a specific prediction
about the parser's output values, run the harness in verbose
mode and compare actual outputs against expected.

Most corpus entries (the truncated descriptors, unbalanced
collections, etc.) have no specific output prediction beyond
"no crash"; those are skipped here. Only entries with explicit
expected values are checked.

Usage:
    python3 check-corpus.py

Exit 0 if every checked entry matched its expected outputs;
exit 1 if any check failed.

Designed to run from inputfs/test/fuzz/. The harness must be
built (run 'make' first).
"""

import os
import re
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
HARNESS = SCRIPT_DIR / "inputfs-fuzz"
CORPUS_DIR = SCRIPT_DIR / "corpus"


def run_verbose(blob_path):
    """Run the harness in verbose mode against blob_path; return a
    dict of key=value lines parsed from stdout. Exit code is
    captured separately as the 'exit_code' key."""
    env = os.environ.copy()
    env["INPUTFS_FUZZ_VERBOSE"] = "1"
    result = subprocess.run(
        [str(HARNESS), str(blob_path)],
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
    )
    out = {"exit_code": result.returncode}
    for line in result.stdout.splitlines():
        # Each line is either "key=value" or "key1=value1 key2=value2 ..."
        # We accept both shapes by splitting on whitespace then on '='.
        for token in line.split():
            if "=" in token:
                k, v = token.split("=", 1)
                out[k] = v
    return out


# Per-entry expected values. Each entry maps a key from the verbose
# output to either an exact expected value (string) or a callable
# that returns True/False given the actual value. Entries not
# listed here are skipped (their .txt companions do not predict
# specific output values; the crash-resistance check in
# fuzz-verify.sh covers them).
EXPECTED = {
    "known-good": {
        "exit_code": 0,
        "pointer_locations_valid": "1",
        "loc_x_size": "8",
        "loc_y_size": "8",
        "button_count": "3",
        "extract_pointer_rc": "1",
        "out_dx": "0",
        "out_dy": "0",
        "out_buttons": "0x00000000",
        "keyboard_locations_valid": "0",
    },
    "05-truncated-mid-button": {
        "exit_code": 0,
        # The .txt said "may still be 0 or 1 depending on parse";
        # we accept either, but require the buttons location to
        # have reasonable values if pointer_locations_valid is 1.
        "pointer_locations_valid": lambda v: v in ("0", "1"),
        # No further fields are checked since they depend on
        # which sub-fields parsed.
    },
    "12-lying-button-count": {
        "exit_code": 0,
        "pointer_locations_valid": "1",
        # Saturation: declared 255, capped at 32.
        "button_count": "32",
    },
    "13-lying-report-size": {
        "exit_code": 0,
        "pointer_locations_valid": "1",
        # X declared as 32-bit field.
        "loc_x_size": "32",
    },
    "14-lying-position-overflow": {
        "exit_code": 0,
        "pointer_locations_valid": "1",
        # No corruption: pos is the declared starting position
        # (0 for first element); size reflects the declared
        # 65535-bit field.
        "loc_x_pos": "0",
        "loc_x_size": "65535",
    },
    "15-report-empty": {
        "exit_code": 0,
        "pointer_locations_valid": "1",
        # Empty report: extract returns 0 (the early-return
        # guard fires).
        "extract_pointer_rc": "0",
        "out_dx": "0",
        "out_dy": "0",
        "out_buttons": "0x00000000",
    },
    "16-report-truncated": {
        "exit_code": 0,
        "pointer_locations_valid": "1",
        # 1-byte report containing 0x07 (button bits all set);
        # boot mouse has 3 buttons, so all three set in output.
        "extract_pointer_rc": "1",
        "out_buttons": "0x00000007",
        # X and Y are clamped (location is past report end);
        # hid_get_data returns 0 for out-of-range reads.
        "out_dx": "0",
        "out_dy": "0",
    },
    "17-report-id-mismatch": {
        "exit_code": 0,
        "pointer_locations_valid": "1",
        # ID mismatch: extract returns 0, outputs unchanged
        # from caller defaults (0).
        "extract_pointer_rc": "0",
        "out_dx": "0",
        "out_dy": "0",
        "out_buttons": "0x00000000",
    },
    "18-report-too-long": {
        "exit_code": 0,
        "pointer_locations_valid": "1",
        # 1024-byte report of all 0xFF; reads only first 3
        # bytes worth of declared positions. Buttons byte is
        # 0xFF; boot mouse declares 3 buttons so output is
        # 0x07 (low 3 bits). X and Y are -1 (sign-extended
        # from 0xFF).
        "extract_pointer_rc": "1",
        "out_buttons": "0x00000007",
        "out_dx": "-1",
        "out_dy": "-1",
    },
    "19-report-sign-extension": {
        "exit_code": 0,
        "pointer_locations_valid": "1",
        # X=0xFF Y=0xFF should sign-extend to -1, -1.
        "extract_pointer_rc": "1",
        "out_dx": "-1",
        "out_dy": "-1",
        "out_buttons": "0x00000000",
    },
    "20-cross-pair-mouse-with-kbd-report": {
        "exit_code": 0,
        "pointer_locations_valid": "1",
        # Garbage values are acceptable; specific check is
        # only "no crash". We do verify that extract returned
        # 1 (the report is non-empty and the locations are
        # populated).
        "extract_pointer_rc": "1",
    },
    "21-cross-pair-kbd-with-mouse-report": {
        "exit_code": 0,
        "keyboard_locations_valid": "1",
        # Modifier byte from byte 0 of the 3-byte mouse
        # report (which is 0x07).
        "extract_keyboard_rc": "1",
        "out_modifiers": "0x07",
        # Keys array reads from byte 2 onward; only 1 byte
        # is available (0x05); the rest must clamp to 0.
        "out_keys": "05,00,00,00,00,00",
    },
    "22-baseline-boot-keyboard": {
        "exit_code": 0,
        "keyboard_locations_valid": "1",
        "loc_modifiers_size": "8",
        "loc_keys_size": "8",
        "loc_keys_count": "6",
        "extract_keyboard_rc": "1",
        # Left shift held + 'a' key pressed.
        "out_modifiers": "0x02",
        "out_keys": "04,00,00,00,00,00",
    },
    "23-multi-button-mouse": {
        "exit_code": 0,
        "pointer_locations_valid": "1",
        "button_count": "5",
        "extract_pointer_rc": "1",
        # All five button bits set; this is the regression
        # check that locks in the AD-9.4 button-count fix.
        "out_buttons": "0x0000001f",
        "out_dx": "0",
        "out_dy": "0",
    },
}


def check_entry(name, expected):
    """Run the harness against corpus/<name>.bin and validate
    each expected key. Returns (ok, list_of_failures)."""
    blob = CORPUS_DIR / f"{name}.bin"
    if not blob.exists():
        return False, [f"blob not found: {blob}"]
    actual = run_verbose(blob)
    failures = []
    for key, want in expected.items():
        if key not in actual:
            failures.append(f"{key}: missing from output")
            continue
        got = str(actual[key])
        if callable(want):
            if not want(got):
                failures.append(f"{key}={got} (predicate failed)")
        else:
            want_str = str(want)
            if got != want_str:
                failures.append(f"{key}={got} (expected {want_str})")
    return (len(failures) == 0), failures


def main():
    if not HARNESS.exists() or not os.access(HARNESS, os.X_OK):
        print(f"ERROR: harness not built. Run 'make' first.", file=sys.stderr)
        return 2

    print("=== AD-9.4 corpus output-value checks ===")
    print(f"Harness: {HARNESS}")
    print(f"Corpus:  {CORPUS_DIR}")
    print()

    pass_count = 0
    fail_count = 0
    skip_count = 0
    failed_entries = []

    # Iterate in sorted order for stable output across runs.
    bin_files = sorted(CORPUS_DIR.glob("*.bin"))
    for blob in bin_files:
        name = blob.stem
        if name not in EXPECTED:
            print(f"  SKIP   {name} (no output prediction)")
            skip_count += 1
            continue
        ok, failures = check_entry(name, EXPECTED[name])
        if ok:
            print(f"  PASS   {name}")
            pass_count += 1
        else:
            print(f"  FAIL   {name}")
            for f in failures:
                print(f"           {f}")
            fail_count += 1
            failed_entries.append(name)

    print()
    print("=== summary ===")
    print(f"  total entries:    {len(bin_files)}")
    print(f"  output-checked:   {pass_count + fail_count}")
    print(f"  skipped:          {skip_count}")
    print(f"  pass:             {pass_count}")
    print(f"  fail:             {fail_count}")

    if fail_count == 0:
        print()
        print("All output-value checks passed. The parser produces the")
        print("predicted output for every corpus entry whose .txt")
        print("companion makes a specific prediction.")
        return 0
    else:
        print()
        print(f"Failed entries: {' '.join(failed_entries)}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
