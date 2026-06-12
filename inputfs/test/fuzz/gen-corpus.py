#!/usr/bin/env python3
"""
gen-corpus.py: regenerate the AD-9.3 fuzz corpus from source.

Per inputfs/docs/adr/0014-hid-fuzzing-scope.md.

This script generates every entry under corpus/ from declarative
recipes. Each entry consists of a binary blob (.bin) and a
companion description file (.txt). The .bin files are derivable
artefacts; the canonical description of each test case lives in
this script.

Usage: python3 gen-corpus.py

Outputs go in corpus/. Existing files are overwritten.

The corpus targets the six bug categories named in ADR 0014:

    1. Truncated descriptors
    2. Recursive collections (unbalanced open/close, MAXPUSH overflow)
    3. Out-of-range usages
    4. Lying descriptors (declared sizes inconsistent with reality)
    5. Pathological reports (truncated, oversized, mismatched IDs,
       sign-extension edge cases)
    6. Cross-paired blobs (descriptor and report from different
       device classes)

Plus a small set of valid baseline entries (boot mouse, boot
keyboard) to confirm the harness handles real-world inputs as
expected.

Wire format for the harness blob (see main.c):

    [2 bytes BE rdesc_len][rdesc][2 bytes BE report_len][report]

If report_len is 0 the harness skips the extract phase.
"""

import os
import struct
import sys
from pathlib import Path

CORPUS_DIR = Path(__file__).parent / "corpus"


# -----------------------------------------------------------------
# Reference HID descriptors (USB HID 1.11 spec, Appendix B)
# -----------------------------------------------------------------

# B.2 boot protocol mouse (50 bytes)
BOOT_MOUSE = bytes([
    0x05, 0x01,     # Usage Page (Generic Desktop)
    0x09, 0x02,     # Usage (Mouse)
    0xA1, 0x01,     # Collection (Application)
    0x09, 0x01,     #   Usage (Pointer)
    0xA1, 0x00,     #   Collection (Physical)
    0x05, 0x09,     #     Usage Page (Buttons)
    0x19, 0x01,     #     Usage Minimum (1)
    0x29, 0x03,     #     Usage Maximum (3)
    0x15, 0x00,     #     Logical Minimum (0)
    0x25, 0x01,     #     Logical Maximum (1)
    0x95, 0x03,     #     Report Count (3)
    0x75, 0x01,     #     Report Size (1)
    0x81, 0x02,     #     Input (Data, Variable, Absolute)
    0x95, 0x01,     #     Report Count (1)
    0x75, 0x05,     #     Report Size (5)
    0x81, 0x03,     #     Input (Constant) - padding
    0x05, 0x01,     #     Usage Page (Generic Desktop)
    0x09, 0x30,     #     Usage (X)
    0x09, 0x31,     #     Usage (Y)
    0x15, 0x81,     #     Logical Minimum (-127)
    0x25, 0x7F,     #     Logical Maximum (127)
    0x75, 0x08,     #     Report Size (8)
    0x95, 0x02,     #     Report Count (2)
    0x81, 0x06,     #     Input (Data, Variable, Relative)
    0xC0,           #   End Collection
    0xC0,           # End Collection
])
assert len(BOOT_MOUSE) == 50

# B.1 boot protocol keyboard (62 bytes)
BOOT_KEYBOARD = bytes([
    0x05, 0x01,     # Usage Page (Generic Desktop)
    0x09, 0x06,     # Usage (Keyboard)
    0xA1, 0x01,     # Collection (Application)
    0x05, 0x07,     #   Usage Page (Key Codes)
    0x19, 0xE0,     #   Usage Minimum (224 = LeftCtrl)
    0x29, 0xE7,     #   Usage Maximum (231 = RightGui)
    0x15, 0x00,     #   Logical Minimum (0)
    0x25, 0x01,     #   Logical Maximum (1)
    0x75, 0x01,     #   Report Size (1)
    0x95, 0x08,     #   Report Count (8)
    0x81, 0x02,     #   Input (Data, Variable, Absolute) - modifiers
    0x95, 0x01,     #   Report Count (1)
    0x75, 0x08,     #   Report Size (8)
    0x81, 0x03,     #   Input (Constant) - reserved byte
    0x95, 0x05,     #   Report Count (5)
    0x75, 0x01,     #   Report Size (1)
    0x05, 0x08,     #   Usage Page (LEDs)
    0x19, 0x01,     #   Usage Minimum (1)
    0x29, 0x05,     #   Usage Maximum (5)
    0x91, 0x02,     #   Output (Data, Variable, Absolute) - LEDs
    0x95, 0x01,     #   Report Count (1)
    0x75, 0x03,     #   Report Size (3)
    0x91, 0x03,     #   Output (Constant) - LED padding
    0x95, 0x06,     #   Report Count (6)
    0x75, 0x08,     #   Report Size (8)
    0x15, 0x00,     #   Logical Minimum (0)
    0x25, 0x65,     #   Logical Maximum (101)
    0x05, 0x07,     #   Usage Page (Key Codes)
    0x19, 0x00,     #   Usage Minimum (0)
    0x29, 0x65,     #   Usage Maximum (101)
    0x81, 0x00,     #   Input (Data, Array) - 6 keys
    0xC0,           # End Collection
])
assert len(BOOT_KEYBOARD) == 63


# -----------------------------------------------------------------
# Helper to write an entry
# -----------------------------------------------------------------

def write_entry(name, rdesc, report, description):
    """
    Write corpus/<name>.bin (binary blob) and corpus/<name>.txt
    (description). description should be a multi-line string with the
    standard fields.
    """
    if not isinstance(rdesc, (bytes, bytearray)):
        raise TypeError("rdesc must be bytes")
    if not isinstance(report, (bytes, bytearray)):
        raise TypeError("report must be bytes")
    if len(rdesc) > 0xFFFF:
        raise ValueError(f"{name}: rdesc too long ({len(rdesc)} > 65535)")
    if len(report) > 0xFFFF:
        raise ValueError(f"{name}: report too long ({len(report)} > 65535)")

    blob = struct.pack(">H", len(rdesc)) + bytes(rdesc) + \
           struct.pack(">H", len(report)) + bytes(report)
    bin_path = CORPUS_DIR / f"{name}.bin"
    txt_path = CORPUS_DIR / f"{name}.txt"
    bin_path.write_bytes(blob)
    txt_path.write_text(description.strip() + "\n")


# -----------------------------------------------------------------
# Corpus entries
# -----------------------------------------------------------------

def main():
    CORPUS_DIR.mkdir(exist_ok=True)

    # Preserve the existing AD-9.2b smoke entry by overwriting it
    # with the same content. (The blob is identical to what AD-9.2b
    # ships; this script becomes the source of truth.)
    write_entry(
        "known-good",
        BOOT_MOUSE,
        bytes([0x00, 0x00, 0x00]),
        """
known-good.bin

CATEGORY: baseline
TARGETS: all four parser functions on a real, valid input.
INPUT: USB HID 1.11 boot protocol mouse descriptor (50 bytes,
  Appendix B.2) plus a 3-byte all-zero report (no buttons,
  no movement).
EXPECTED BEHAVIOR: parsers find pointer locations, extract
  zero values from the report, exit 0 with no ASan faults.
EXPECTED FAILURE MODE IF BROKEN: any non-zero exit indicates
  a regression in the most basic supported path.
"""
    )

    # ---------- Category 1: truncated descriptors ----------

    write_entry(
        "01-truncated-empty",
        b"",
        b"",
        """
01-truncated-empty.bin

CATEGORY: 1, truncated descriptor
TARGETS: locate functions' early-return on rdesc_len == 0.
INPUT: zero-length descriptor, zero-length report.
EXPECTED BEHAVIOR: locate functions return immediately with
  *_locations_valid = 0; extract functions are skipped.
EXPECTED FAILURE MODE IF BROKEN: NULL deref or out-of-bounds
  read on the rdesc pointer.
"""
    )

    write_entry(
        "02-truncated-1-byte",
        bytes([0x05]),  # Usage Page item header, no data byte
        b"",
        """
02-truncated-1-byte.bin

CATEGORY: 1, truncated descriptor
TARGETS: hid_get_byte's bounds check when an item header
  promises bSize bytes but the buffer ends.
INPUT: a single 0x05 byte (start of a Usage Page item that
  needs a 1-byte payload, but the payload is missing).
EXPECTED BEHAVIOR: hid_get_byte sees s->p == s->end on the
  next read and returns 0; hid_get_item terminates the parse
  loop. locate functions report no usages found.
EXPECTED FAILURE MODE IF BROKEN: hid_get_byte reads past
  s->end (one-byte OOB read).
"""
    )

    write_entry(
        "03-truncated-mid-item",
        BOOT_MOUSE[:5],  # 0x05 0x01 0x09 0x02 0xA1, item header without value
        b"",
        """
03-truncated-mid-item.bin

CATEGORY: 1, truncated descriptor
TARGETS: hid_get_item state machine when an item with bSize > 1
  is truncated mid-payload.
INPUT: first 5 bytes of the boot mouse descriptor, ending at
  0xA1 (the Collection item header that needs 1 payload byte).
EXPECTED BEHAVIOR: graceful termination, no crash, no usages
  located.
EXPECTED FAILURE MODE IF BROKEN: read of unmapped memory if
  the parser advances s->p past s->end.
"""
    )

    write_entry(
        "04-truncated-mid-collection",
        BOOT_MOUSE[:6],  # ...through Collection (Application) opening
        b"",
        """
04-truncated-mid-collection.bin

CATEGORY: 1, truncated descriptor
TARGETS: parser state at depth 1 with no matching End
  Collection item.
INPUT: first 6 bytes of boot mouse: an open Application
  Collection that is never closed.
EXPECTED BEHAVIOR: parse terminates at end-of-buffer with
  collection depth still 1; no crash, no usages located
  inside the unclosed collection.
EXPECTED FAILURE MODE IF BROKEN: unbalanced state corrupts
  the per-RID position table; pathological loop on
  hid_switch_rid.
"""
    )

    write_entry(
        "05-truncated-mid-button",
        BOOT_MOUSE[:30],  # ...through partial button declarations
        b"",
        """
05-truncated-mid-button.bin

CATEGORY: 1, truncated descriptor
TARGETS: locate phase walking partial button declarations.
INPUT: first 30 bytes of boot mouse, cut mid-button-block
  (Usage Page Button + Usage Min/Max declared, but not all
  of the Logical Min/Max + Report Count + Size + Input).
EXPECTED BEHAVIOR: hid_locate finds Button 1 location with
  partial information; button_count walk terminates without
  finding a complete Input item; pointer_locations_valid
  may still be 0 or 1 depending on which sub-fields parsed.
EXPECTED FAILURE MODE IF BROKEN: button_count walk runs
  past s->end; flags/id outputs uninitialised on hid_locate
  return.
"""
    )

    # ---------- Category 2: recursive / unbalanced collections ----------

    write_entry(
        "06-collection-unclosed",
        bytes([0x05, 0x01, 0xA1, 0x01, 0xA1, 0x01, 0xA1, 0x01,
               0xA1, 0x01, 0xA1, 0x01, 0xA1, 0x01]),
        b"",
        """
06-collection-unclosed.bin

CATEGORY: 2, recursive/unbalanced collections
TARGETS: parser depth tracking when collections open without
  matching close.
INPUT: Usage Page (GenericDesktop), then six Collection
  (Application) opens, no End Collection items.
EXPECTED BEHAVIOR: parser tracks depth up to MAXPUSH=4 then
  caps; further opens return without pushing; parse
  terminates cleanly at end-of-buffer.
EXPECTED FAILURE MODE IF BROKEN: hid_data->cur[] write
  past index MAXPUSH-1 (stack-buffer overflow); collevel
  counter overflow.
"""
    )

    write_entry(
        "07-collection-overpop",
        bytes([0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0]),
        b"",
        """
07-collection-overpop.bin

CATEGORY: 2, recursive/unbalanced collections
TARGETS: parser pop logic when End Collection appears with
  no matching open.
INPUT: eight End Collection items in a row, no opens.
EXPECTED BEHAVIOR: hid_get_item logs "invalid end collection"
  via DPRINTFN and continues; parser terminates without
  underflow.
EXPECTED FAILURE MODE IF BROKEN: pushlevel/collevel
  decrement past zero (signed underflow), array index
  underflow on s->cur[s->pushlevel].
"""
    )

    write_entry(
        "08-collection-overpush",
        bytes([0xA4, 0xA4, 0xA4, 0xA4, 0xA4, 0xA4, 0xA4, 0xA4]),
        b"",
        """
08-collection-overpush.bin

CATEGORY: 2, recursive/unbalanced collections
TARGETS: Push (0xA4) item driving pushlevel past MAXPUSH=4.
INPUT: eight Push items in a row.
EXPECTED BEHAVIOR: parser caps pushlevel at MAXPUSH-1, logs
  "Cannot push item @ N" via DPRINTFN, continues without
  writing past s->cur[].
EXPECTED FAILURE MODE IF BROKEN: stack-buffer overflow
  writing s->cur[5..7] when MAXPUSH=4.
"""
    )

    # ---------- Category 3: out-of-range usages ----------

    write_entry(
        "09-usage-page-reserved",
        bytes([0x07, 0xFF, 0xFF, 0xFF, 0xFF,  # Usage Page 0xFFFFFFFF (long form)
               0x09, 0x01,                     # Usage 1
               0xA1, 0x01,                     # Collection (Application)
               0xC0]),                         # End Collection
        b"",
        """
09-usage-page-reserved.bin

CATEGORY: 3, out-of-range usages
TARGETS: usage page comparison when the page is the maximum
  uint32 value (well past any documented page).
INPUT: a 4-byte Usage Page item with value 0xFFFFFFFF, a
  usage, an empty collection.
EXPECTED BEHAVIOR: hid_locate compares the assembled
  full-usage uint32 against HID_USAGE2(HUP_*, ...) targets
  and finds no match; locate functions return with no
  pointer or keyboard usages found.
EXPECTED FAILURE MODE IF BROKEN: signed overflow in usage
  comparison; misclassification of the descriptor as a
  pointer or keyboard.
"""
    )

    write_entry(
        "10-usage-page-vendor",
        bytes([0x06, 0x00, 0xFF,              # Usage Page 0xFF00 (vendor)
               0x09, 0x01,                     # Usage (vendor-defined)
               0xA1, 0x01,                     # Collection (Application)
               0x75, 0x08, 0x95, 0x40,        # Report Size 8, Report Count 64
               0x81, 0x02,                     # Input (Data, Var, Abs)
               0xC0]),                         # End Collection
        b"",
        """
10-usage-page-vendor.bin

CATEGORY: 3, out-of-range usages
TARGETS: descriptors that are valid HID but contain no
  usages inputfs cares about (vendor-defined HID device).
INPUT: vendor-page descriptor declaring a 64-byte input
  report with no GenericDesktop or Keyboard usages.
EXPECTED BEHAVIOR: locate functions return with
  pointer_locations_valid = 0 and keyboard_locations_valid
  = 0; extract is skipped on a subsequent report.
EXPECTED FAILURE MODE IF BROKEN: hid_locate stores garbage
  in *flags/*id outputs and the locate function uses them.
"""
    )

    write_entry(
        "11-usage-zero",
        bytes([0x05, 0x01,                     # Usage Page (Generic Desktop)
               0x09, 0x00,                     # Usage 0 (undefined)
               0xA1, 0x01,                     # Collection (Application)
               0xC0]),                         # End Collection
        b"",
        """
11-usage-zero.bin

CATEGORY: 3, out-of-range usages
TARGETS: usage 0 (undefined) handling. The HID spec reserves
  usage 0; some devices in the wild emit it.
INPUT: GenericDesktop page with usage 0 and an empty
  application collection.
EXPECTED BEHAVIOR: hid_locate skips the undefined usage,
  locate functions return with no usages found.
EXPECTED FAILURE MODE IF BROKEN: misclassification (usage
  0 might unexpectedly satisfy HID_USAGE2(HUP_X) if
  comparison logic is broken).
"""
    )

    # ---------- Category 4: lying descriptors ----------

    write_entry(
        "12-lying-button-count",
        bytes([0x05, 0x01,                     # Usage Page (Generic Desktop)
               0x09, 0x02,                     # Usage (Mouse)
               0xA1, 0x01,                     # Collection (Application)
               0x05, 0x09,                     # Usage Page (Buttons)
               0x19, 0x01,                     # Usage Min (1)
               0x29, 0xFF,                     # Usage Max (255)
               0x15, 0x00, 0x25, 0x01,         # Logical 0..1
               0x95, 0xFF, 0x75, 0x01,         # Report Count 255, Size 1
               0x81, 0x02,                     # Input (Var)
               0xC0]),                         # End Collection
        b"",
        """
12-lying-button-count.bin

CATEGORY: 4, lying descriptor
TARGETS: button-count walk in inputfs_pointer_locate when
  the descriptor declares 255 buttons (inputfs caps at 32).
INPUT: descriptor with 255 button declarations in a single
  Input item.
EXPECTED BEHAVIOR: button_count saturates at 32 (the cap is
  explicit in inputfs_pointer_locate); pointer_locations_valid
  becomes 1 because Button 1 was located.
EXPECTED FAILURE MODE IF BROKEN: button_count exceeds 32
  (cap not enforced); wire-format byte for buttons truncates
  silently downstream.
"""
    )

    write_entry(
        "13-lying-report-size",
        bytes([0x05, 0x01,                     # Usage Page (Generic Desktop)
               0x09, 0x02,                     # Usage (Mouse)
               0xA1, 0x01,                     # Collection (Application)
               0x09, 0x30,                     # Usage X
               0x15, 0x00, 0x26, 0xFF, 0xFF,   # Logical 0..65535
               0x75, 0x20, 0x95, 0x01,         # Report Size 32, Report Count 1
               0x81, 0x02,                     # Input (Var)
               0xC0]),                         # End Collection
        b"",
        """
13-lying-report-size.bin

CATEGORY: 4, lying descriptor
TARGETS: hid_get_data on a 32-bit field (size > what fits
  in the int32_t result of hid_get_data without
  sign-loss surprises).
INPUT: X axis declared as a single 32-bit field.
EXPECTED BEHAVIOR: locate finds X with size=32; extract
  reads the full 32 bits and casts to int32_t (the cast in
  inputfs_extract_pointer is documented as accepting
  truncation).
EXPECTED FAILURE MODE IF BROKEN: hid_get_data reads past
  the report buffer when the report does not actually
  contain 32 bits at the expected position.
"""
    )

    write_entry(
        "14-lying-position-overflow",
        # Use Output items (4-byte size declarations) to push the bit
        # position high without ever locating an Input usage. We declare
        # giant report sizes that drive the parser's pos counter up.
        bytes([0x05, 0x01,                     # Usage Page (Generic Desktop)
               0x09, 0x02,                     # Usage (Mouse)
               0xA1, 0x01,                     # Collection (Application)
               0x09, 0x30,                     # Usage X
               # Report Size 0xFFFF (largest 2-byte value)
               0x76, 0xFF, 0xFF,
               # Report Count 0x000F = 15
               0x96, 0x0F, 0x00,
               0x81, 0x02,                     # Input (Var) - 15 * 65535 bits
               0xC0]),                         # End Collection
        b"",
        """
14-lying-position-overflow.bin

CATEGORY: 4, lying descriptor
TARGETS: bit-position arithmetic in hid_get_item when the
  cumulative position would push past 32 bits.
INPUT: descriptor declaring an Input field of 65535 bits per
  element with 15 elements (totaling ~983,025 bits).
EXPECTED BEHAVIOR: parser tracks the position via uint32_t;
  even at maximum it cannot overflow within a single
  descriptor of this size. locate returns with X located at
  pos=0 (first element).
EXPECTED FAILURE MODE IF BROKEN: integer overflow in pos
  tracking, position arithmetic in hid_get_data picks up
  garbage state, OOB read on subsequent extract.
"""
    )

    # ---------- Category 5: pathological reports ----------

    write_entry(
        "15-report-empty",
        BOOT_MOUSE,
        b"",
        """
15-report-empty.bin

CATEGORY: 5, pathological report
TARGETS: extract phase early-return on len == 0.
INPUT: valid boot-mouse descriptor; zero-length report.
EXPECTED BEHAVIOR: extract functions return 0 immediately
  via the (len == 0) guard.
EXPECTED FAILURE MODE IF BROKEN: extract proceeds with
  len=0 and hid_get_data reads buf[-1] or similar.
"""
    )

    write_entry(
        "16-report-truncated",
        BOOT_MOUSE,
        bytes([0x07]),  # Just the button-bits byte; X and Y missing.
        """
16-report-truncated.bin

CATEGORY: 5, pathological report
TARGETS: hid_get_data when the located bit-position lies
  beyond the report buffer's end.
INPUT: boot mouse descriptor (which expects a 3-byte report);
  1-byte report containing only the button-bits byte.
EXPECTED BEHAVIOR: extract reads buttons from byte 0 (in
  range), then attempts to read X from byte 1 (out of range).
  hid_get_data must clamp/return 0 rather than read OOB.
EXPECTED FAILURE MODE IF BROKEN: 1- to 7-byte OOB read.
"""
    )

    write_entry(
        "17-report-id-mismatch",
        # Build a descriptor that uses Report ID = 1.
        bytes([0x05, 0x01,                     # Usage Page (Generic Desktop)
               0x09, 0x02,                     # Usage (Mouse)
               0xA1, 0x01,                     # Collection (Application)
               0x85, 0x01,                     # Report ID 1
               0x09, 0x30, 0x09, 0x31,         # Usage X, Y
               0x15, 0x81, 0x25, 0x7F,         # Logical -127..127
               0x75, 0x08, 0x95, 0x02,         # Report Size 8, Count 2
               0x81, 0x06,                     # Input (Var, Rel)
               0xC0]),                         # End Collection
        bytes([0x02, 0x01, 0x01]),  # Report ID 2, doesn't match.
        """
17-report-id-mismatch.bin

CATEGORY: 5, pathological report
TARGETS: inputfs_report_id_matches when the descriptor uses
  Report ID 1 but the report claims ID 2.
INPUT: descriptor declaring Report ID 1; report whose first
  byte is 2.
EXPECTED BEHAVIOR: inputfs_report_id_matches returns 0;
  extract skips the X and Y locations; out_dx / out_dy
  remain at their caller-supplied zero defaults.
EXPECTED FAILURE MODE IF BROKEN: parser proceeds and reads
  X/Y from offsets relative to a non-matching report ID,
  yielding garbage values or worse.
"""
    )

    write_entry(
        "18-report-too-long",
        BOOT_MOUSE,
        bytes([0xFF] * 1024),  # 1024 bytes when descriptor expects 3
        """
18-report-too-long.bin

CATEGORY: 5, pathological report
TARGETS: extract phase tolerance for reports larger than
  the descriptor implies.
INPUT: boot mouse descriptor; 1024-byte report of all 0xFF.
EXPECTED BEHAVIOR: extract reads only the bytes the located
  positions cover (3 bytes); the rest is ignored. No OOB
  access either way.
EXPECTED FAILURE MODE IF BROKEN: extract trusts the report
  length and walks N=1024 bytes; ASan flags none, but a
  downstream consumer might trust a wrong field. Test
  exercises the harness handling, not a known bug.
"""
    )

    write_entry(
        "19-report-sign-extension",
        BOOT_MOUSE,
        bytes([0x00, 0xFF, 0xFF]),  # buttons=0, X=-1, Y=-1
        """
19-report-sign-extension.bin

CATEGORY: 5, pathological report
TARGETS: signed-integer interpretation of pointer deltas.
  X and Y are declared signed (Logical Min -127); 0xFF
  should be -1 after sign extension.
INPUT: boot mouse descriptor; report with no buttons,
  X=0xFF, Y=0xFF.
EXPECTED BEHAVIOR: hid_get_data returns -1 (sign-extended
  from int8); inputfs_extract_pointer's (int32_t) cast
  preserves the sign so out_dx = -1, out_dy = -1.
EXPECTED FAILURE MODE IF BROKEN: missing sign extension
  yields out_dx = 255, out_dy = 255 (wrong direction). Not
  an ASan-detectable bug, but worth keeping in the corpus
  as a regression catch should the cast change.
"""
    )

    # ---------- Category 6: cross-paired blobs ----------

    write_entry(
        "20-cross-pair-mouse-with-kbd-report",
        BOOT_MOUSE,
        # 8-byte boot keyboard report shape: modifier, reserved, 6 keys
        bytes([0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00]),
        """
20-cross-pair-mouse-with-kbd-report.bin

CATEGORY: 6, cross-paired
TARGETS: extract robustness when the report shape doesn't
  match the descriptor's declared format.
INPUT: boot mouse descriptor; 8-byte report shaped like a
  boot keyboard (modifier byte + reserved + 6 key slots).
EXPECTED BEHAVIOR: pointer extract reads 3 bytes worth of
  positioned fields, treats them as button-bits / X / Y;
  values are nonsensical but no OOB occurs (8 bytes is
  larger than 3 bytes).
EXPECTED FAILURE MODE IF BROKEN: report-length validation
  off; some other path reads beyond byte 3.
"""
    )

    write_entry(
        "21-cross-pair-kbd-with-mouse-report",
        BOOT_KEYBOARD,
        bytes([0x07, 0x05, 0x05]),  # 3-byte mouse report shape
        """
21-cross-pair-kbd-with-mouse-report.bin

CATEGORY: 6, cross-paired
TARGETS: keyboard extract when the report is too short to
  contain the modifier byte + 6 keys (boot keyboard expects
  8 bytes; here we give 3).
INPUT: boot keyboard descriptor; 3-byte report shaped like a
  boot mouse (button-bits + X + Y).
EXPECTED BEHAVIOR: extract reads modifier byte from byte 0;
  attempts to read 6 keys starting at byte 2; only 1 byte
  is available there. hid_get_data must clamp gracefully.
EXPECTED FAILURE MODE IF BROKEN: 5-byte OOB read across
  the keys array slots.
"""
    )

    # ---------- Baseline ----------

    write_entry(
        "22-baseline-boot-keyboard",
        BOOT_KEYBOARD,
        # Realistic 8-byte boot keyboard report: shift held, "a" pressed
        bytes([0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00]),
        """
22-baseline-boot-keyboard.bin

CATEGORY: baseline
TARGETS: keyboard locate + extract on a real, valid input.
INPUT: USB HID 1.11 boot keyboard descriptor (63 bytes,
  Appendix B.1) plus an 8-byte report representing left
  shift held with the "a" key (HID usage 0x04) pressed.
EXPECTED BEHAVIOR: keyboard_locate populates loc_modifiers
  and loc_keys; extract returns out_modifiers=0x02 (left
  shift) and out_keys[0]=0x04.
EXPECTED FAILURE MODE IF BROKEN: same as known-good but for
  the keyboard side of the parser; non-zero exit indicates
  regression.
"""
    )

    # ---------- Regression test added during AD-9.4 ----------
    # See findings.md: this entry locks in the fix for the
    # button-count extraction bug. Without the fix, only the
    # low bit of out_buttons ever sets, dropping mouse buttons
    # 2-5 silently.

    # 5-button mouse descriptor: identical to boot mouse but
    # with Report Count 5 (and no padding) for the button block.
    MULTI_BUTTON_MOUSE = bytes([
        0x05, 0x01,     # Usage Page (Generic Desktop)
        0x09, 0x02,     # Usage (Mouse)
        0xA1, 0x01,     # Collection (Application)
        0x09, 0x01,     #   Usage (Pointer)
        0xA1, 0x00,     #   Collection (Physical)
        0x05, 0x09,     #     Usage Page (Buttons)
        0x19, 0x01,     #     Usage Minimum (1)
        0x29, 0x05,     #     Usage Maximum (5)
        0x15, 0x00,     #     Logical Minimum (0)
        0x25, 0x01,     #     Logical Maximum (1)
        0x95, 0x05,     #     Report Count (5)
        0x75, 0x01,     #     Report Size (1)
        0x81, 0x02,     #     Input (Data, Variable, Absolute)
        0x95, 0x01,     #     Report Count (1)
        0x75, 0x03,     #     Report Size (3)
        0x81, 0x03,     #     Input (Constant) - padding
        0x05, 0x01,     #     Usage Page (Generic Desktop)
        0x09, 0x30,     #     Usage (X)
        0x09, 0x31,     #     Usage (Y)
        0x15, 0x81,     #     Logical Minimum (-127)
        0x25, 0x7F,     #     Logical Maximum (127)
        0x75, 0x08,     #     Report Size (8)
        0x95, 0x02,     #     Report Count (2)
        0x81, 0x06,     #     Input (Data, Variable, Relative)
        0xC0,           #   End Collection
        0xC0,           # End Collection
    ])

    write_entry(
        "23-multi-button-mouse",
        MULTI_BUTTON_MOUSE,
        # Report: all 5 buttons pressed (low 5 bits = 0x1F),
        # 3 bits padding, then dx=0, dy=0.
        bytes([0x1F, 0x00, 0x00]),
        """
23-multi-button-mouse.bin

CATEGORY: regression test (AD-9.4)
TARGETS: button-bitmap extraction width. Without the AD-9.4
  fix, only the low bit of out_buttons would ever set,
  silently dropping mouse buttons 2-5 from every report.
INPUT: 5-button mouse descriptor (Report Count 5, Report
  Size 1 for the button block); 3-byte report with all
  five button bits set (0x1F) and zero motion.
EXPECTED BEHAVIOR: pointer_locations_valid=1, button_count=5,
  extract_pointer_rc=1, out_buttons=0x0000001F (all five
  bits set in the bitmap), out_dx=0, out_dy=0.
EXPECTED FAILURE MODE IF BROKEN: out_buttons=0x00000001
  (only button 1 reported, buttons 2-5 silently dropped).
  This is the bug AD-9.4 found and fixed in
  inputfs_extract_pointer's button-extraction path.
"""
    )

    print(f"Generated {len(list(CORPUS_DIR.glob('*.bin')))} corpus entries in {CORPUS_DIR}")


if __name__ == "__main__":
    main()
