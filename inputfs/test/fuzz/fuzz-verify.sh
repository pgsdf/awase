#!/bin/sh
# fuzz-verify.sh: run the AD-9 fuzz harness against every corpus
# entry and report per-entry pass/fail.
#
# Per inputfs/docs/adr/0014-hid-fuzzing-scope.md.
#
# Usage:
#   sh fuzz-verify.sh
#
# Exit codes:
#   0 if every corpus entry passed (harness exited 0, no ASan
#     reports).
#   1 if any entry failed.
#   2 on a script-level error (harness binary missing, corpus dir
#     missing, etc.).
#
# The script does not rebuild the harness. Run `make` first if
# inputfs-fuzz is missing or stale.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
HARNESS="$SCRIPT_DIR/inputfs-fuzz"
CORPUS_DIR="$SCRIPT_DIR/corpus"

if [ ! -x "$HARNESS" ]; then
    echo "ERROR: harness binary not found at $HARNESS"
    echo "Run 'make' in $SCRIPT_DIR first."
    exit 2
fi

if [ ! -d "$CORPUS_DIR" ]; then
    echo "ERROR: corpus directory not found at $CORPUS_DIR"
    exit 2
fi

# Count entries before we start.
TOTAL=$(ls "$CORPUS_DIR"/*.bin 2>/dev/null | wc -l | tr -d ' ')
if [ "$TOTAL" = "0" ]; then
    echo "ERROR: no .bin files in $CORPUS_DIR"
    echo "Run 'python3 gen-corpus.py' to generate the corpus."
    exit 2
fi

PASS=0
FAIL=0
FAILED_ENTRIES=""

echo "=== AD-9 fuzz corpus verification ==="
echo "Harness: $HARNESS"
echo "Corpus:  $CORPUS_DIR ($TOTAL entries)"
echo

for entry in "$CORPUS_DIR"/*.bin; do
    name=$(basename "$entry" .bin)
    # Run with a 10s timeout via the kernel (most BSDs and Linuxes have
    # `timeout`). Capture stdout+stderr; we only care about exit code.
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 "$HARNESS" "$entry" > /dev/null 2>&1
    else
        "$HARNESS" "$entry" > /dev/null 2>&1
    fi
    rc=$?
    if [ "$rc" = "0" ]; then
        printf "  PASS   %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL   %s (rc=%d)\n" "$name" "$rc"
        FAIL=$((FAIL + 1))
        FAILED_ENTRIES="$FAILED_ENTRIES $name"
    fi
done

echo
echo "=== summary ==="
printf "  total:  %d\n" "$TOTAL"
printf "  pass:   %d\n" "$PASS"
printf "  fail:   %d\n" "$FAIL"

if [ "$FAIL" = "0" ]; then
    echo
    echo "All corpus entries passed. The harness handles every input"
    echo "without crashing under AddressSanitizer. (This does NOT mean"
    echo "the parser is bug-free; it means the corpus has not yet"
    echo "exposed any *crashes*. Run check-corpus.py to verify output"
    echo "values against the predictions in each entry's .txt"
    echo "companion.)"
    exit 0
else
    echo
    echo "Failed entries:$FAILED_ENTRIES"
    echo
    echo "Per-entry detail: re-run the harness against each failed"
    echo "entry and inspect its companion .txt for what bug class"
    echo "the entry was designed to provoke."
    exit 1
fi
