# 0018 HUP_DIGITIZERS Handling for Win8+ Multi-Touch Touchpads

## Status

Proposed (initial 2026-05-05), amended 2026-05-05 after review of
FreeBSD's `wmt(4)` source: section 3 corrected from "Touchpad Mode
is enabled by Surface/Button Switch (Report ID 12)" to "Touchpad
Mode is enabled by Device Mode (Report ID 11) = 0x03". Section 5's
feature-report-send code corrected accordingly. New section 3a
captures the "inputfs is the exclusive HID consumer" architectural
invariant on which the single-attach pattern depends.

## Context

ADR 0004 fixed the role taxonomy with `touch` as a first-class role
alongside `pointer`, `keyboard`, `pen`, and `lighting`. ADR 0010
(Stage B.5) established the role-bitmask encoding on the softc and
the classifier mechanism that fills it from descriptor walks. The
`shared/INPUT_EVENTS.md` spec defines `touch.touch_down`,
`touch.touch_move`, and `touch.touch_up` event types. Stage D.0a and
D.0b (ADR 0012) deferred touch and pen event generation until
digitizer hardware was available in the lab.

As of 2026-05-05 a multi-touch HID device is identified and
characterized: a HAILUCK USB touchpad (vendor=0x258a, product=0x000c)
on `pgsd-bare-metal-test-machine`. Its 505-byte HID report descriptor
was captured via the `hw.inputfs.debug_descriptor` sysctl
(commit `41e8f74`) and decoded byte-by-byte. The device presents
fully-conformant Microsoft Win8+ Precision Touchpad HID, which is
the same descriptor shape Linux's `hid-multitouch` and FreeBSD's
`wmt(4)` driver target.

This ADR records the design decisions for a HUP_DIGITIZERS parser
that allows inputfs to publish `SOURCE_TOUCH` events from the
HAILUCK device (and any other Win8+-conformant multi-touch HID
device that follows the same usage pattern). It also records
findings from the descriptor decode that constrain the parser's
shape, in particular the "one finger per report" pattern this
device uses.

## Decision

### 1. Verified descriptor structure (HAILUCK 0x258a:0x000c)

The descriptor declares six top-level Application Collections under
the trackpad's HID interface (Interface 1 of the USB composite
device, 505-byte descriptor):

| Report ID | Direction | Usage Page    | Application Usage          | Bytes |
|-----------|-----------|---------------|----------------------------|-------|
| 1         | Input     | Generic Desktop | Mouse                    | 7     |
| 2         | Input     | Generic Desktop | System Control           | 1     |
| 3         | Input     | Consumer        | Consumer Control         | 3     |
| 5         | Feature   | Vendor 0xff00 | (vendor)                   | 5     |
| 6         | Feature   | Vendor 0xff00 | (vendor)                   | 1039  |
| 7         | Input     | Digitizers    | Touch Pad                  | 7     |
| 8         | Feature   | Digitizers    | (capabilities)             | 1     |
| 9         | Input     | Generic Desktop | Wireless Radio Controls  | 1     |
| 10        | Feature   | Vendor 0xff00 | (vendor)                   | 256   |
| 11        | Feature   | Digitizers    | Device Configuration       | 1     |
| 12        | Feature   | Digitizers    | (Surface/Button Switch)    | 1     |
| 13        | Feature   | Digitizers    | (Latency Mode)             | 1     |

Report ID 7 is the multi-touch input report. Its layout:

| Bit offset | Size | Field                | Range    |
|------------|------|----------------------|----------|
| 0          | 1    | Confidence           | 0..1     |
| 1          | 1    | Tip Switch           | 0..1     |
| 2          | 3    | Contact Identifier   | 0..7     |
| 5          | 15   | X                    | 0..1535  |
| 20         | 15   | Y                    | 0..1023  |
| 35         | 16   | Scan Time            | 0..65535 |
| 51         | 4    | Contact Count        | 0..15    |
| 55         | 1    | Button 1 (clickpad)  | 0..1     |

Total: 56 bits = 7 bytes data + 1 byte report ID = 8 bytes,
which matches the 8-byte interrupt endpoint maxPacketSize.

### 2. Critical finding: one finger per report

The descriptor declares **only one Finger collection** per Report ID 7,
not a looped or arrayed finger collection. This means the device
emits **one Finger collection's worth of contact data per report**.
To track multi-finger gestures the host receives a sequence of
Report ID 7 packets, one per active contact, with the Contact Count
field telling the host how many contacts make up the current "frame."

The frame boundary is the convention from Microsoft's Precision
Touchpad spec ("hybrid mode" for low-bandwidth devices): if the
first report in a frame announces Contact Count = N, the host
should expect N reports forming this frame, all sharing the same
scan time (or near-same). The next report after N reports begins
a new frame.

This is a constraint imposed by the HAILUCK's USB low-speed bandwidth
(1.5 Mbps with 8-byte interrupt packets at 10ms intervals). Higher-
bandwidth Win8+ touchpads typically loop the Finger collection
inside one large report (5 fingers × 9 bytes per finger + scan time
+ contact count + button = ~50 bytes per report, requiring 64-byte
or larger interrupt endpoints).

The parser must support both patterns. The HAILUCK's pattern is
"single-finger reports with contact count framing"; future devices
may use "multi-finger reports with looped finger collection." The
parser detects the pattern by examining the descriptor structure
during the locate phase, not at runtime.

### 3. Critical finding: Mouse Mode default

Win8+ touchpads emit Report ID 1 (mouse fallback) by default. The
device only emits Report ID 7 (multi-touch) after the host writes
the Device Mode feature field
(`HID_USAGE2(HUP_DIGITIZERS, HUD_DEVICE_MODE)`, usage 0x52)
with the value `0x03` (Multi-touch Touchpad mode). On the HAILUCK
this field lives in Report ID 11, which is a 1-byte feature report
with the layout:

| Bit offset | Size | Field        | Range  |
|------------|------|--------------|--------|
| 0          | 8    | Device Mode  | 0..10  |

Defined Device Mode values (per Microsoft Precision Touchpad spec):

| Value | Mode                              |
|-------|-----------------------------------|
| 0x00  | Mouse                             |
| 0x02  | Multi-touch Touchscreen           |
| 0x03  | Multi-touch Touchpad              |

The host issues a SET_REPORT(FEATURE) at attach time with Report ID 11
and the located Device Mode field set to `0x03`. This matches what
FreeBSD's `wmt(4)` and `hmt(4)` drivers do, and what Linux's
`hid-multitouch` does. Without this feature-report send, the device
continues to emit only Report ID 1 (mouse data); the parser is inert
in that case.

**Surface Switch and Button Switch (Report ID 12) are NOT the
mode switch.** The earlier draft of this ADR mistakenly named
those as the load-bearing fields for enabling Touchpad Mode. They
are secondary controls under the Device Configuration TLC: Surface
Switch toggles whether contact data is reported once Touchpad Mode
is enabled, and Button Switch toggles whether button events are
reported through the digitizer interface. Both default to enabled
on real hardware, and inputfs leaves them at their defaults. The
single feature-report write to Device Mode is sufficient to put
the device into Multi-touch Touchpad mode.

The Device Configuration TLC (HUP_DIGITIZERS, HUD_CONFIG = 0x0e)
that hosts Device Mode is a separate Application Collection in the
descriptor. FreeBSD's modern `hmt(4)` delegates Device Mode writes
to a sibling driver `hconf(4)` attached to that TLC; inputfs does
NOT follow that pattern. inputfs attaches once at the Mouse TLC
(per ADR 0007's existing match list of HUG_MOUSE / HUG_POINTER /
HUG_KEYBOARD) and writes the feature report directly to the
device's HID interface using `hid_set_report` with Report ID 11.
The wire-level mechanics of feature reports are addressable by
report ID alone, not by TLC; this works because inputfs is the
sole HID consumer for the device (see section 3a below for why
this invariant holds).

### 3a. Architectural invariant: inputfs is the exclusive HID consumer

The single-attach-at-Mouse-TLC design from section 3 depends on
an architectural invariant that should be made explicit:

> **inputfs is the exclusive HID consumer for any device it attaches
> to.** No other driver (hmt, hconf, hms, ums, hkbd, ukbd, hgame,
> hpen, etc.) attaches to the same hidbus child concurrently with
> inputfs.

#### Status amendment, 2026-05-08

The exclusive-consumer invariant above describes a **target end
state**, not the current behaviour. As of 2026-05-08 the bench
(pgsd-bare-metal-test-machine) loads `hkbd.ko` as a kld and
attaches three keyboards (HAILUCK USB touchpad keyboard, Broadcom
Bluetooth keyboard, Apple Aluminum Mini Keyboard) under hkbd.
Each registers a `/dev/kbd*` device which kbdmux aggregates into
`/dev/kbdmux0`, feeding vt(4)'s console keystroke pipeline.
Meanwhile inputfs is also loaded, parsing HID reports for its
own event ring. The two pipelines coexist; neither displaces the
other.

#### Status re-amendment, 2026-05-08 (later same day)

The "coexistence" framing in the amendment immediately above
was based on yesterday's evening observation that hkbd was
loaded *alongside* inputfs. A more careful reading of the
bench dmesg later in the day (during AD-27 trackpad investigation,
which is what produced AD-30) revealed that this is too generous.

The actual current bench state is **exclusion, not coexistence**:

  - **Zero HID devices are attached to inputfs.** dmesg shows
    `hms0`, `hkbd0`, `hms1`, `hsctrl0`, `hcons0`, `hmt0`,
    `hconf0`, `hkbd1`, `hms2`, `hkbd2`, `hcons1` — i.e., every
    TLC of every HID device on the bus is claimed by a legacy
    driver. There are no `inputfs<N>: ... attached` lines at all.
  - **`/var/run/sema/input/state` is 0 bytes.** inputfs's
    kthread starts, opens the file at full size (11328 bytes),
    publishes empty buffers, but with zero device attachments
    it never populates state slots; the writer truncates back
    to 0 (or never extends past the initial truncate-on-create).
    `inputdump state` correctly reports `state region not valid`
    via AD-29's defensive size check.
  - **No input reaches semadrawd.** The cursor pump's StateReader
    rejects the invalid state region; `pumpCursorPosition`
    returns early on every cycle; the cursor sprite stays at its
    initial position; trackpad and mouse are both effectively
    disconnected from the compositor.

The "coexistence" framing was wrong because it described what
the architecture would look like *if* inputfs were also attaching
(just non-exclusively). What actually happens on the current
PGSD-DEBUG kernel is that inputfs is shut out entirely. The
`hidbus → inputfs` path in the earlier amendment's diagram does
not currently exist on this bench; only the
`hidbus → hkbd → kbd → kbdmux → vt(4)` path is active.

This severity gap was missed because the earlier amendment was
written based on the AD-28 closure investigation, which
specifically asked "is hkbd loaded?" (answer: yes) and concluded
"so console keyboard works." Both of those observations were
correct. The unstated and incorrect inference was "and inputfs
is attaching to its share of TLCs alongside hkbd." Inputfs is
attaching to no TLCs. The two-pipeline diagram was aspirational
masquerading as descriptive.

#### Why this matters for §3 and §5

§3's single-attach-at-Mouse-TLC design and §5's feature-report
send at attach time are correctness arguments **conditional on
inputfs attaching at all**. On a kernel that loads the legacy
drivers and does not displace them, inputfs never attaches, the
feature-report send never runs, and the touchpad stays in
Mouse Mode by default. The HUP_DIGITIZERS parser and the
single-attach pattern still describe what would happen *if*
inputfs were the attaching driver; they just describe a
hypothetical on the current bench.

For correctness arguments to apply, AD-30 (or its fix) must
restore inputfs's attachment via one of: option 1 (probe-priority
bump + rescan), option 2 (loader.conf bootstrap), option 3
(re-enforce AD-8's kernel-config discipline), or option 4
(sequenced combination). Until then, this ADR documents an
architecture not in operation on the bench.

#### Why the original "exclusive consumer" framing remains the
target

Even after this re-amendment, the right end state is still the
exclusive-consumer model. The three properties driving the
unification (sharp timing, coherent state, clean device
identity; documented in AD-30's "why this is the right
architectural call" section) require single ownership of the
HID stream. Coexistence is a transitional curiosity; exclusion
is the current bug; exclusivity is the destination.

The path to exclusivity, per AD-30 and the deprecation roadmap:

  - **AD-30 option 3 (short-term)**: re-enforce AD-8's kernel-
    config discipline. Removes the legacy drivers from the
    PGSD kernel image; inputfs has no probe competition; the
    invariant holds by exclusion of alternatives.
  - **AD-30 option 1 (medium-term)**: bump inputfs's probe
    priority and force a hidbus rescan from inputfs's modevent.
    The invariant holds by inputfs winning the probe race
    even on kernels that load the legacy drivers; portability
    across non-PGSD FreeBSD kernels.
  - **AD-10 / AD-11 (long-term)**: retire vt(4) and kbdmux.
    The legacy keyboard pipeline has nowhere to deliver to;
    even if hkbd remains loaded, its path becomes inert. The
    invariant holds by retirement of the alternative consumers.

These three are not mutually exclusive; they layer. Option 3
unblocks bench testing; option 1 makes the invariant portable;
AD-10/AD-11 makes the invariant unconditional. The yesterday-
amendment's "by retiring the alternative consumers" framing
was correct as far as it went, but understated by leaving out
the option-1 portability path and overstated by suggesting
exclusivity was achievable purely through retirement (it isn't,
on kernels that load the legacy drivers and don't displace
them).

#### Recommended reading order

After this re-amendment, the §3a section is layered:

  1. The original §3a invariant statement and rationale
     (still load-bearing as the architectural target).
  2. The 2026-05-08 (evening) amendment describing
     coexistence (still useful as a snapshot of one possible
     intermediate state, though not the current bench state).
  3. This re-amendment (current bench reality and revised
     path-to-target).
  4. The pre-amendment context section.
  5. The original §3a text preserved verbatim at the end.

A reader trying to understand "what does §3a mean today" should
read items 1, 3, 4 first; the evening-of-2026-05-08 amendment
in item 2 is a transient and superseded interpretation.

This means HID reports from a keyboard fan out to two consumers
in the running kernel:

  - `hidbus → hkbd → kbd → kbdmux → vt(4)` (console keystrokes)
  - `hidbus → inputfs → state region + event ring` (UTF compositor)

For HUP_DIGITIZERS-class devices (touchpads, touchscreens), the
exclusive-consumer model is closer to actual behaviour: the
PGSD kernel does not load `hmt`, `hconf`, `wmt`, or `hpen`, so
inputfs is the only attached driver on the touchpad's Mouse TLC
and Configuration TLC. The single-attach pattern's correctness
argument from section 3 still holds for those devices: there is
no other driver writing the Device Mode feature report.

For HUP_KEYBOARD devices the situation is the coexistence model
described above: `hkbd` and inputfs both attach, both consume
HID reports, neither writes feature reports to the device, and
no contention arises in practice. The Win8+ touchpad's keyboard
TLC, if it has one, is read by hkbd as a generic keyboard;
inputfs reads it as one of its keyboard event sources. That
yields double-delivery of the same physical keystrokes, which
is harmless on a console-only system (UTF buffers events that
no one consumes) and a question to resolve when UTF compositor
sessions actually demand focus.

The end state — true exclusive HID consumership — is reached
not by inputfs forcibly displacing the alternative consumers,
but by **retiring the alternative consumers** under the
existing UTF deprecation roadmap:

  - **AD-10** deprecates `vt(4)`'s use of the framebuffer for
    UTF sessions. While AD-10 is in flight, `conscontrol mute`
    suspends vt(4) keystroke ingestion during UTF compositor
    activation and restores it on yield, eliminating the
    double-delivery question for any moment a UTF session is
    active. This is session-management policy, not a kernel
    bridge.
  - **AD-11** replaces `vt(4)` entirely with a UTF-native
    terminal compositor. Once AD-11 lands and vt(4) is gone,
    `kbdmux` has no consumer downstream and hkbd's path
    becomes inert even if the modules remain loaded. The
    invariant becomes true through retirement.

The forced kld-omission approach (AD-8: PGSD omits hkbd, ukbd,
hms, ums, etc.) is the auxiliary path that makes the invariant
true *now* on a kernel build, before AD-10/AD-11 ship. AD-8 is
the bench-side instrument; AD-10/AD-11 are the long-term
structural fix. On a kernel build that *does* load hkbd (which
is the bench's current state), the coexistence model is the
operative one and console keyboard input keeps working.

#### Why the invariant matters when it does hold

When the invariant holds — i.e., when no competing HID driver
attaches to the same hidbus child as inputfs — inputfs's Device
Mode feature-report write at attach time (section 5) is the
only writer to that feature field. No race; no driver-reverts-
mode hazard. This is what lets the single-attach pattern use a
plain `hid_set_report` call without arbitration.

When the invariant does not hold — e.g., on a kernel that loads
hkbd alongside inputfs — section 5's correctness argument for
the touchpad device still applies because hkbd does not write
to HUP_DIGITIZERS feature reports. hkbd only consumes
HUP_KEYBOARD inputs, which inputfs's Mouse TLC attachment does
not touch. So the touchpad-mode toggle remains uncontested even
under coexistence. The exclusive-consumer invariant is the
*sufficient* condition; what is *required* is "no other driver
writes the same feature field," which a careful drivers list
can satisfy without full exclusivity.

#### Pre-amendment context

The original §3a text (preserved below) was written at AD-1
step 4-5 time when the bench was running a kernel build that
actually omitted hkbd. The text accurately described that
build. As the kernel-config discipline drifts across rebuilds
(AD-8 is a discipline note, not enforced by the build system),
the invariant tightens and loosens; the amendment records
which architectural conclusions survive both regimes.

#### Original §3a text (pre-2026-05-08)

This invariant holds today on the PGSD kernel because:

  - Per AD-8, the PGSD kernel configuration explicitly omits hms,
    hkbd, hgame, hcons, hsctrl, ukbd, ums, wmt, hmt, hconf, hpen,
    and the other HID-class drivers superseded by inputfs.
    `usbhid.ko` is also absent from the kernel build (and from
    `/boot/modules/`), so userspace HID character-device access
    via `/dev/usbhid*` is unavailable. Devices therefore have no
    competing kernel-side consumer.
  - inputfs's hidbus probe rule (in `inputfs_devs[]`) matches
    HUG_MOUSE / HUG_POINTER / HUG_KEYBOARD. On a Win8+ touchpad
    with multiple Application Collections, inputfs claims the
    Mouse TLC and the Device Configuration TLC simply has no
    driver attached, leaving the device's feature-report channel
    accessible to inputfs without contention.

If the invariant is ever weakened — by adding a competing HID
driver to the kernel, or by inputfs's match list expanding to
attach to multiple TLCs of the same device — the Device Mode
feature-report write may collide with another driver's writes,
or the Touchpad Mode setting may be reverted by a race. The
single-attach pattern is what makes the simple `hid_set_report`
call safe.

This invariant is consistent with the broader AD-1 architectural
discipline: inputfs owns the HID-to-events translation layer
end-to-end, with no partial ownership across drivers in the
guarantee path.

### 4. Design: parser shape

The parser is a per-device softc state machine driven by Report ID 7
arrivals. Per-contact state is tracked by Contact Identifier (0..7;
the field is 3-bit so up to 8 contacts are addressable, though the
device's actual maximum is read from Report ID 8's Contact Count
Maximum at attach time and is typically 2 or 3 for laptop-class
touchpads).

Per-contact state in the softc:

```
struct inputfs_touch_contact {
    uint8_t  active;          // 1 if contact is currently down
    uint8_t  contact_id;      // device-assigned ID
    int16_t  x;               // last reported X
    int16_t  y;               // last reported Y
    uint16_t scan_time;       // last reported scan time
};

struct inputfs_softc {
    ...
    struct inputfs_touch_contact touch_contacts[INPUTFS_MAX_CONTACTS];
    uint8_t  touch_button;    // last reported clickpad button state
    uint8_t  touch_frame_remaining;  // contacts left in current frame
    uint8_t  touch_max_contacts;     // from Report ID 8 feature read
};
```

`INPUTFS_MAX_CONTACTS` is 8 (the bit width of Contact Identifier).

The interrupt handler dispatches by report ID:

  - Report ID 1 → existing pointer path (legacy mouse fallback;
    fires only if Touchpad Mode failed to enable).
  - Report ID 7 → digitizer parser:
    1. Extract Contact Count, Contact ID, Tip Switch, X, Y,
       Scan Time, Button.
    2. Compare against the contact's previous state in
       `touch_contacts[contact_id]`:
       - Tip Switch was 0, now 1: emit `touch.touch_down`.
       - Tip Switch was 1, still 1: emit `touch.touch_move`.
       - Tip Switch was 1, now 0: emit `touch.touch_up`.
    3. Update `touch_contacts[contact_id]`.
    4. If Button transitions from previous state, emit
       `pointer.button_down` or `pointer.button_up` for the
       clickpad button.
    5. Decrement frame counter; if zero and Contact Count > 0,
       set a new frame counter for the next batch.
  - Other report IDs (2, 3, 9) → existing handlers if applicable;
    otherwise ignored.

### 5. Design: feature-report send at attach time

After `hid_get_report_descr` succeeds and the device classifies as
having `INPUTFS_ROLE_TOUCH`, the attach path locates the Device Mode
feature field via `hid_locate(rdesc, rdesc_len, HID_USAGE2(HUP_DIGITIZERS,
HUD_DEVICE_MODE), hid_feature, 0, ...)`. Locator stores three
things on the parser state: the field location (`hid_location`),
the field's report ID, and the report's full byte length (queried
via `hid_report_size(rdesc, rdesc_len, hid_feature, report_id)`).

The locator's outputs feed a feature-report write at the end of
attach:

```c
/*
 * Touchpad Mode switch. Buffer is rlen bytes including the
 * report ID at byte 0. Zero-init the payload, write Device Mode =
 * 0x03 (Multi-touch Touchpad) into the located field via
 * hid_put_udata.
 */
uint8_t buf[rlen];
memset(buf, 0, rlen);
buf[0] = device_mode_rid;
hid_put_udata(buf + 1, rlen - 1, &device_mode_loc, 0x03);

err = hid_set_report(dev, buf, rlen, HID_FEATURE_REPORT,
                     device_mode_rid);
```

Important detail: **the buffer length is whatever the descriptor
declares for that report, not 1 byte.** On the HAILUCK Report ID 11
is 1 byte of payload + 1 report ID byte = 2 bytes total. Other
devices may declare larger Device Configuration reports that pack
Device Mode alongside other configuration fields; using the located
bit position via `hid_put_udata` rather than `buf[1] = 0x03` keeps
the write correct on those devices and avoids clobbering unrelated
fields.

If `hid_set_report` fails (device returns STALL on the SET_REPORT
control transfer, transport error, device disconnect, or any other
error), inputfs logs a warning and proceeds. The device continues
to emit Report ID 1 (mouse), which the existing pointer parser
handles. The classifier role remains TOUCH for diagnostic purposes;
userspace can observe via the state region that this device is
touch-capable but not yet activated. inputfs's `hw.inputfs.debug_descriptor`
sysctl provides a way to dump the descriptor for post-mortem if needed.

This graceful fallback means the parser must be robust to "no Report
ID 7 ever arrives." That is the existing default behaviour (the
parser's interrupt handler simply isn't invoked), so no extra logic
is needed beyond the warning log.

Surface Switch and Button Switch (Report ID 12) are NOT written by
inputfs. They default to enabled on real hardware, and the Device
Mode write alone is sufficient to enter Touchpad Mode. If a future
device requires explicit Surface/Button Switch enabling, that would
be a separate small extension to this section.

### 6. Design: clock domain for ts_ordering

Each emitted touch event carries a `ts_ordering` timestamp like every
other inputfs event. The descriptor exposes a 16-bit Scan Time field
(Report ID 7, bit offset 35) which the device increments at each
internal scan cycle. This is **not** the same clock domain as the
inputfs kernel monotonic timestamp; the device's scan time is in its
own opaque units (the Unit Exponent and Unit fields suggest 100µs
units, but cross-device variance is significant).

Decision: **inputfs uses kernel monotonic for `ts_ordering` on touch
events**, identical to the pointer and keyboard paths. The device's
Scan Time is stored on the softc per-contact for future use (frame
boundary detection improvements, latency analysis) but not surfaced
in the wire format.

This keeps the touch path consistent with the rest of inputfs (one
clock domain for ordering) and avoids an unbounded reasoning load
about scan-time-vs-monotonic relations across devices.

`ts_sync` follows the existing pattern: stamped from the audio-clock
cache if `clock_valid = 1`, falls through to 0 otherwise. No
digitizer-specific behaviour.

### 7. Out of scope

- **Pen events** (HUP_DIGITIZERS usage 0x02). Pen reports include
  pressure, tilt, and tool-type fields not present in the touch
  parser. Pen support is a separate AD-1 sub-item with its own
  hardware acquisition.
- **In-range without tip-switch** (hover state). The touch parser
  only emits events when Tip Switch transitions or holds. Hover
  reports (in-range high, tip switch low) are silently dropped
  in v1; surface as future work if a use case appears.
- **Pressure and contact area**. The HAILUCK descriptor doesn't
  expose these fields. Devices that do will require parser
  extension; those fields would map to additional `touch.*` event
  payload bytes per `shared/INPUT_EVENTS.md` extension.
- **Touch-screen variant** (HUP_DIGITIZERS usage 0x04). The
  classifier role distinguishes these from touchpads; the parser
  shape is identical but the coordinate transform (mapping device
  units to display pixels) differs. Touch-screen support is a
  separate AD-1 sub-item.
- **Apple's vendor-specific multi-touch protocol**. Different
  parser; tracked as a separate AD-1 sub-item.

### 8. Verification

The parser's correctness is verified at three levels:

1. **Unit (descriptor walker).** The Python descriptor walker in
   `/tmp/hid_walker.py` (used to produce this document's Report
   ID 7 layout table) validates that the descriptor walk is
   correct. The C parser's `inputfs_digitizer_locate` output is
   compared against this oracle for the HAILUCK descriptor.
2. **Functional (interrupt path).** With Touchpad Mode enabled,
   the `hw.inputfs.debug_reports` sysctl (AD-13.1) prints raw
   report bytes to dmesg. The operator performs known-shape
   gestures (one-finger move, two-finger pinch, three-finger
   swipe) and the parser's emitted events are compared against
   expected `touch.touch_down/move/up` sequences.
3. **End-to-end.** Scenarios 7-9 of
   `semadraw/docs/PHASE_2_5_VERIFICATION.md` run against the
   HAILUCK trackpad through the full stack: kernel parser →
   inputfs ring → semadrawd → recogniser → gesture_inspect.
   This is what closes the AD-2a Phase 2.5 multi-touch
   verification deferral.

## Consequences

- inputfs gains support for one new HID class (digitizers,
  touchpad variant) and one new event family (`touch.*`).
- The Stage B classifier (`inputfs_classify_device`) gains a
  TOUCH detection path keyed on usage page 0x0D usage 0x05.
- The interrupt-handler dispatch path gains a Report ID 7 arm
  on devices classified as TOUCH.
- Attach-time work grows by one feature-report send per touch
  device; failure is non-fatal.
- AD-2a Phase 2.5 multi-touch verification (scenarios 7-9)
  becomes runnable.
- AD-1 enters its closeout window: pollable-fd / kqfilter
  remains as latency improvement; Apple multi-touch trackpad
  support remains as a separate parallel sub-item; touch-screen
  support remains future work; pen support remains future work.

## References

- HAILUCK descriptor capture: dmesg from
  `pgsd-bare-metal-test-machine` 2026-05-05, captured via
  `hw.inputfs.debug_descriptor=1`.
- Microsoft "Windows Precision Touchpad" specification (publicly
  available; describes Win8+ HID multi-touch protocol).
- FreeBSD `wmt(4)` driver source (sys/dev/usb/input/wmt.c) as
  prior-art for HUP_DIGITIZERS parsing on FreeBSD.
- Linux `hid-multitouch.c` as prior-art for the cross-vendor
  multi-touch HID quirks.
- `shared/INPUT_EVENTS.md` — `touch.touch_down/move/up` wire
  format.
- ADR 0004 — role taxonomy; `touch` role.
- ADR 0010 — role classification mechanism; `INPUTFS_ROLE_TOUCH`.
- BACKLOG entry "AD-1 sub-item: HUP_DIGITIZERS parser for Win8+
  multi-touch" — implementation plan and step ordering.
