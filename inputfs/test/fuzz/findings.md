# AD-9.4 findings

Per `inputfs/docs/adr/0014-hid-fuzzing-scope.md`. This document
records what AD-9.4 found when running the AD-9.3 corpus through
the inputfs HID parser and inspecting output values for
correctness.

## Summary

- **23 corpus entries inspected** (the AD-9.3 deliverable).
- **1 bug found and fixed**: `inputfs_extract_pointer` reading
  only the low bit of the button bitmap, silently dropping
  mouse buttons 2 and onward.
- **1 regression test added** (entry `23-multi-button-mouse`)
  to lock in the fix.
- **0 ASan reports** across all corpus runs (crash-resistance
  baseline established by AD-9.3 holds).
- **All 14 output-checkable entries** now produce the values
  their `.txt` companions predict.

## Bug 1: button bitmap truncated to first bit

### Symptoms

Running the harness in verbose mode against
`16-report-truncated.bin` (boot mouse descriptor + 1-byte
report `0x07` representing all three buttons pressed) produced
`out_buttons=0x00000001`. Only the low bit was set, even
though the report explicitly carried `0b00000111`.

The same shape appeared on `18-report-too-long.bin` (boot
mouse with a 1024-byte report of `0xFF`, which has all three
button bits set in byte 0). Again `out_buttons=0x00000001`
where `0x00000007` was expected.

### Root cause

`inputfs_pointer_locate` calls
`hid_locate(rdesc, rdesc_len, HID_USAGE2(HUP_BUTTON, 1), ...)`,
which returns the location of *Button 1 specifically*: a
single bit at the start of the button bitfield. The cached
`p->loc_buttons` therefore has `size = 1`.

The parser also does a separate descriptor walk to count how
many `HUP_BUTTON` usages are present in the input, storing
the result in `p->button_count`. For a boot mouse, this is 3.

`inputfs_extract_pointer` then reads buttons via
`hid_get_udata(buf, len, &p->loc_buttons)`, which reads
`loc_buttons.size` bits at `loc_buttons.pos`. With `size = 1`,
only the first button bit is ever read. The `button_count`
field was populated but unused at extract time.

### Effect on real users

This bug affects every multi-button mouse on UTF systems once
inputfs is the active input path (post-Stage-E cutover, after
AD-2). Right-click (button 2), middle-click (button 3), and
any side buttons would be silently dropped from every report.

Before AD-2, semainputd is still primary, so the bug was
latent. AD-9 was designed to find exactly this class of bug:
a parser issue that becomes load-bearing once Stage E cuts
over. AD-9.4's structured output-value check found it.

### Fix

`inputfs/sys/dev/inputfs/inputfs_parser.c`,
`inputfs_extract_pointer`. Build a temporary `hid_location`
starting at `loc_buttons.pos` with `size = button_count`
(capped implicitly at 32 by `hid_get_udata`). Use that
location to read the full button bitmap from the report.

```c
struct hid_location buttons_loc = p->loc_buttons;
if (p->button_count > 0)
    buttons_loc.size = p->button_count;
*out_buttons = (uint32_t)hid_get_udata(buf, len, &buttons_loc);
```

The fix is local: ten lines in
`inputfs_extract_pointer`'s button block. No interface change;
no caller-side change required. `inputfs.c`'s
`inputfs_extract_pointer` consumer at line 2261 receives the
correct full bitmap and the existing changed-bit iteration
at line 2370 covers all 32 bits already.

### Regression test

Corpus entry `23-multi-button-mouse.bin` declares a 5-button
mouse and provides a report with all five button bits set
(`0x1F`). The `.txt` companion specifies
`out_buttons=0x0000001F` and `button_count=5`. With the bug
present, `out_buttons=0x00000001` and the entry fails.

Entries `16-report-truncated` and `18-report-too-long` also
serve as regression tests; their `.txt` companions specify
`out_buttons=0x00000007` (all three boot-mouse buttons set).

A reverted-fix sanity check during AD-9.4 development
confirmed `check-corpus.py` flags all three entries when the
bug is reintroduced. The test has discriminating power.

## Other entries inspected

The remaining 22 corpus entries produced outputs matching
their `.txt` companions' predictions:

- **Truncated descriptors (1-5)**: locate returns
  `pointer_locations_valid=0` for the deeper truncations;
  for entry 5 (cut at 30 bytes), the buttons location is
  populated but X/Y are not, with `pointer_locations_valid=1`
  because at least one usage was found. Reasonable behavior.
- **Recursive collections (6-8)**: locate returns clean with
  no usages found. The MAXPUSH=4 cap held; no stack overflow,
  no underflow on overpop.
- **Out-of-range usages (9-11)**: locate returns clean with
  no pointer/keyboard usages found. The reserved 4-byte
  usage page (entry 9) and vendor page (entry 10) were
  correctly classified as not-our-device.
- **Lying descriptors (12-14)**: button-count saturation
  at 32 works (entry 12); 32-bit X axis declaration is
  honored (entry 13); 65535-bit field declaration does not
  corrupt position tracking (entry 14).
- **Pathological reports (15-19)**: empty-report early-return
  works (15); truncated-report bounds-clamping works (16);
  ID-mismatch returns 0 with outputs unchanged (17);
  oversized report reads only declared bytes (18);
  sign-extension on `0xFF` produces `-1` correctly (19).
- **Cross-paired (20-21)**: garbage outputs but no crashes
  and no OOB; `hid_get_data` clamps gracefully when the
  cached location lies past the report's end.
- **Baselines (22, 23, known-good)**: real inputs produce
  real outputs.

## What this means for AD-9 closure

AD-9's purpose was to harden the inputfs parser before AD-2
makes it the sole input path. AD-9.4 found one bug that
would have manifested as silently-dropped mouse buttons
once Stage E cut over. That bug is fixed. The 23-entry
corpus, the regression-test entry 23, and the
`check-corpus.py` script collectively form a regression
gate that will catch similar parser-output bugs in the
future.

The crash-resistance baseline established by AD-9.3 (no
ASan reports across all 24 corpus entries) remains intact
after the fix. The parser is, on the evidence of the corpus,
both crash-resistant *and* output-correct on the inputs we
have tested it against.

The corpus is not exhaustive. ADR 0014's open questions Q1
(coverage-guided fuzzing), Q2 (state-leak across calls), and
Q3 (FreeBSD hid.c upstream fuzzing) all remain deferred with
their original reopen criteria. AD-9.4 closes the AD-9
backlog item; further fuzzing work would require a new
proposal.
