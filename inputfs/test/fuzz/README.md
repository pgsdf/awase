# inputfs HID parser fuzz harness

Per `inputfs/docs/adr/0014-hid-fuzzing-scope.md`. This is the
AD-9.2b deliverable: a userspace harness that compiles
`inputfs.c`'s parser surface (extracted to `inputfs_parser.c`
in AD-9.2a) alongside FreeBSD's `dev/hid/hid.c`, and exercises
the locate and extract paths under AddressSanitizer.

The harness exists to find memory-safety bugs in inputfs's
parser-output consumer code: out-of-bounds reads, missing
bounds checks against `hid_locate` outputs, modifier and keys-
array bit-walking issues, and similar. It is NOT testing parse
correctness; "garbage in, garbage out" is acceptable, but
"garbage in, segfault" is the bug we hunt.

## Building

```
cd inputfs/test/fuzz
make
```

This produces `inputfs-fuzz` in the same directory, with
AddressSanitizer linked in (`-fsanitize=address`). The harness
is single-binary; no install step.

## Running

The harness reads a binary fuzz blob from stdin or a file
argument:

```
./inputfs-fuzz < some-blob.bin
./inputfs-fuzz corpus/known-good.bin
```

Exit codes:

- **0**: parsers ran without crashing. AddressSanitizer
  found no faults.
- **non-zero**: a crash, an ASan-detected fault, or an I/O
  error. Inspect stderr for ASan's report.

## Smoke testing

```
make smoke
```

Runs three checks:
1. Empty input (parsers handle a zero-length blob).
2. `corpus/known-good.bin` (the USB HID 1.11 boot-protocol
   mouse descriptor + a 3-byte report).
3. 4 KiB of random data from `/dev/urandom`.

All three should exit 0. A failure means a regression vs.
the verified baseline.

## Wire format of the input blob

```
offset 0..1                              big-endian uint16: rdesc_len
offset 2..1+rdesc_len                    rdesc_len bytes:   HID descriptor
offset 2+rdesc_len..3+rdesc_len          big-endian uint16: report_len
offset 4+rdesc_len..3+rdesc_len+report_len   report_len bytes:  HID report
```

If `report_len` is 0 or the blob ends before the report-length
prefix, only the locate phase runs. A deliberately short blob
is a valid fuzz input: "what does locate do with this
descriptor alone?".

The harness deliberately tolerates malformed wire formats
(short blobs, length prefixes that exceed the remaining
buffer, etc.) without crashing on the wire-format parser
itself. Crashes from the wire-format parser would be harness
bugs, not parser bugs we are testing for.

## What the harness exercises

For each input blob, the harness:

1. Calls `inputfs_pointer_locate(state, rdesc, rdesc_len)`.
2. If the descriptor produced valid pointer locations and a
   report is present, calls
   `inputfs_extract_pointer(state, report, report_len, ...)`.
3. Re-zeroes the parser state and calls
   `inputfs_keyboard_locate(state, rdesc, rdesc_len)`.
4. If the descriptor produced valid keyboard locations and a
   report is present, calls
   `inputfs_extract_keyboard(state, report, report_len, ...)`.

Steps 1-2 and 3-4 are independent. Both run on every blob.

The harness deliberately does NOT call
`inputfs_keyboard_diff_emit`: that function is event-emission
scoped (it calls `inputfs_focus_keyboard_session` and
`inputfs_events_publish`, and reads `sc_state_slot`). It is out
of fuzz scope per ADR 0014. AD-9 hardens the locate and extract
phases; downstream emission is hardened by tests in stage D
verification.

## Corpus entries

Hand-rolled malformed inputs live in `corpus/`. Each entry
is a binary file in the wire format above plus a `.txt`
companion describing what bug class the entry provokes (in
the standard five-field shape: NAME, CATEGORY, TARGETS,
INPUT, EXPECTED BEHAVIOR, EXPECTED FAILURE MODE IF BROKEN).

The corpus is generated declaratively from `gen-corpus.py`,
which is the source of truth. To regenerate after editing
the script:

```
python3 gen-corpus.py
```

To run the harness against every corpus entry (crash-resistance
check from AD-9.3):

```
sh fuzz-verify.sh
```

To run the harness against every corpus entry whose `.txt`
makes a specific output prediction, comparing actual outputs
against expected (output-correctness check from AD-9.4):

```
python3 check-corpus.py
```

The harness's verbose mode (used by `check-corpus.py`) dumps
parser state and extracted values as `key=value` lines on
stdout when `INPUTFS_FUZZ_VERBOSE=1` is set in the
environment. Useful for ad-hoc inspection:

```
INPUTFS_FUZZ_VERBOSE=1 ./inputfs-fuzz corpus/known-good.bin
```

`findings.md` in this directory records what AD-9.4 found
when running the corpus. The summary: one bug fixed
(button-bitmap truncation), and a regression-test entry
(`23-multi-button-mouse`) added to lock the fix in place.

## Updating the vendored hid sources

`vendored/dev/hid/hid.c`, `hid.h`, and `hidquirk.h` are
verbatim copies of FreeBSD's source files. To resync with
upstream:

```
cp /usr/src/sys/dev/hid/hid.c       vendored/dev/hid/hid.c
cp /usr/src/sys/dev/hid/hid.h       vendored/dev/hid/hid.h
cp /usr/src/sys/dev/hid/hidquirk.h  vendored/dev/hid/hidquirk.h
make clean && make smoke
```

If `make smoke` fails after a resync, FreeBSD upstream changed
something the shim does not yet handle. Update `kernel_shim.h`
or `shim_includes/` accordingly. The shim layer is the only
piece that should ever need updating across vendored upgrades.

`hidquirk.c` is deliberately NOT vendored. The harness leaves
hid.c's `hid_test_quirk_p` function pointer at its default
initialiser (`&hid_test_quirk_w`, returns false). This is
correct for the parser path we exercise.

## Files

```
inputfs/test/fuzz/
├── README.md                       this file
├── Makefile                        build rules
├── .gitignore                      excludes inputfs-fuzz, *.o
├── kernel_shim.h                   force-included shim
├── main.c                          harness driver
├── gen-corpus.py                   declarative corpus generator (AD-9.3)
├── fuzz-verify.sh                  crash-resistance runner (AD-9.3)
├── check-corpus.py                 output-correctness runner (AD-9.4)
├── findings.md                     AD-9.4 findings, including the
│                                   button-bitmap-truncation bug
├── shim_includes/
│   ├── opt_hid.h                   empty (suppresses HID_DEBUG)
│   ├── hid_if.h                    11 kobj-method-dispatch macro stubs
│   └── sys/
│       ├── bus.h                   empty stubs (8 files)
│       ├── kdb.h
│       ├── kernel.h
│       ├── malloc.h
│       ├── module.h
│       ├── param.h
│       ├── sysctl.h
│       └── systm.h
├── vendored/
│   └── dev/hid/
│       ├── VENDORED.md             vendoring notes
│       ├── hid.c                   verbatim from FreeBSD
│       ├── hid.h                   verbatim from FreeBSD
│       └── hidquirk.h              verbatim from FreeBSD
└── corpus/                         24 entries (.bin + .txt each)
    ├── known-good.bin              boot-protocol mouse + 3-byte report
    ├── 01-truncated-empty.bin..21-cross-pair-kbd-with-mouse-report.bin
    │                               malformed inputs (AD-9.3)
    ├── 22-baseline-boot-keyboard.bin
    │                               boot-protocol keyboard baseline
    └── 23-multi-button-mouse.bin   AD-9.4 regression test
```

## Caveats

- **The harness is not a coverage-guided fuzzer.** AD-9.3
  populates a hand-rolled corpus targeted at known bug classes.
  Coverage-guided extension (AFL-style) is out of scope per
  ADR 0014.
- **The harness tests a single input per invocation.** It does
  not maintain parser state across calls. State-leak detection
  across extract calls is out of scope per ADR 0014.
- **The harness compiles on Linux, macOS, and FreeBSD.** Linux
  is the main developer environment for AD-9.3 corpus design;
  FreeBSD is the production target. Both should produce
  byte-identical binary behaviour modulo libc differences.
