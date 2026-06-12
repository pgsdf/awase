# Stage B.5 verification

Acceptance test for ADR 0010 (Per-Device Role Classification). Runs
in two passes: VM first, bare metal second. Each pass produces a
dmesg transcript and a pass/fail mark for each of four signals. The
B.5 closeout bullet in `BACKLOG.md` is flipped only after both
passes are recorded as passing.

## Preconditions

1. The B.5 patch is applied: `inputfs.c` contains the five
   `INPUTFS_ROLE_*` macros, the `sc_roles` field on the softc, the
   `inputfs_classify_roles` helper, the `inputfs_format_roles`
   helper, and one new `device_printf(dev, "inputfs: roles=%s\n",
   buf)` line at the end of `inputfs_attach`.
2. The module builds cleanly: from `inputfs/sys/modules/inputfs/`,
   `make` returns 0 with no warnings beyond those already accepted
   in the `Wno-` flags.
3. No prior `inputfs.ko` is loaded: `kldstat | grep inputfs` is
   empty before each pass starts.
4. A USB mouse and a USB keyboard are available. They do not need
   to be the same physical devices across passes.

## Pass 1: FreeBSD on Oracle VirtualBox

Host: bare-metal computer running VirtualBox.
Guest: FreeBSD VM with USB pass-through to the guest.

The VM pass exercises three signals: mouse classification (1.1),
mouse motion / B.4 unbroken (1.2), and clean unload (1.3). The
keyboard-classification signal that exists in the bare-metal pass
(2.3) is deliberately not run on the VM. See Signal 1.3 below for
the rationale.

**Known host-side stability concern.** Running this pass has been
observed to cause lockups on the host computer running VirtualBox.
The lockups appear to be triggered by USB pass-through combined
with driver unload activity inside the guest, and they affect the
host (which does not have inputfs loaded) rather than the guest.
This is a host-and-VirtualBox-stack issue, not an inputfs issue.
If the bare-metal pass succeeds, the VM pass adds at most a
second-venue datapoint and is not strictly required. Operators
running this pass should be prepared for the host to lock up and
should save unrelated work first.

### Signal 1.1: mouse classifies as pointer

**Steps:**

1. Pass the USB mouse through to the VM via VirtualBox's
   Devices → USB menu.
2. `sudo make install` from `inputfs/sys/modules/inputfs/` to stage
   the new `inputfs.ko`.
3. `sudo kldload inputfs`.
4. `sudo devctl rescan usbhid1 2>/dev/null || sudo devctl rescan
   hidbus1 2>/dev/null` to bind the mouse to inputfs (use whichever
   bus name your system uses; the workflow from the B.4 screenshots
   used both forms with `||`).
5. `sudo dmesg | grep inputfs | tail -20`.

**Expected output (the kind line will say `mouse` or `pointer`
depending on which Generic Desktop usage the device reports; both
match `INPUTFS_ROLE_POINTER`):**

```
inputfs: Stage B.5 loaded (hidbus HID driver, descriptor fetch, interrupt handler registration, raw report hex logging, role classification)
inputfs0: inputfs: attached HID mouse (vendor=0x...., product=0x....)
inputfs0: inputfs: descriptor <N> bytes, <I> input items, <O> output, <F> feature, depth=<D>
inputfs0: inputfs: report buffer <K> bytes (report_id=0x00), registering interrupt
inputfs0: inputfs: calling hid_intr_start
inputfs0: inputfs: hid_intr_start returned 0
inputfs0: inputfs: roles=pointer
```

(The Stage B.5 banner line is the `printf` in `inputfs_modevent`. If
the patch did not update that string, the line will still say
"Stage B.4 loaded"; that is acceptable for B.5 verification but
should be tracked as a follow-up. The signal under test is the
final `roles=pointer` line.)

**Acceptance:**

- [ ] The `roles=pointer` line is present.
- [ ] The `roles=` line appears after all B.2/B.3/B.4 attach lines,
      not before.
- [ ] The format is exactly `roles=pointer`: no quotes, no
      trailing punctuation, no other role names.

### Signal 1.2: mouse motion still produces raw reports (B.4 unbroken)

**Steps:**

1. With the mouse still attached and inputfs still loaded from
   Signal 1.1, move the mouse for several seconds.
2. `sudo dmesg | grep inputfs | tail -10`.

**Expected output (movement deltas, exactly as captured in the B.4
screenshots):**

```
inputfs0: inputfs: report id=0x00 len=8 data=00 02 00 00 02 00 00 00
inputfs0: inputfs: report id=0x00 len=8 data=00 03 00 00 03 00 00 00
inputfs0: inputfs: report id=0x00 len=8 data=00 01 00 00 01 00 00 00
...
```

**Acceptance:**

- [ ] Multiple `report id=0x...` lines are present from the movement
      window.
- [ ] At least one report has non-zero bytes in the delta positions
      (bytes 1–3 or 5–7 depending on the device's report layout).
- [ ] No errors, warnings, or panics interleaved with the report
      stream.

### Signal 1.3: clean unload

The keyboard-classification signal that originally lived at this
position has been moved to the bare-metal pass (Signal 2.3). The
reason is procedural, not technical: the script flow for that
signal requires unloading inputfs while the mouse is still the
only working input device, then asking the operator to detach the
mouse and attach a keyboard via VirtualBox's host-side menu. With
inputfs unloaded, the VM has no working USB input, so the operator
cannot respond to the script's prompts to continue. Bare metal
does not have this problem because plug/unplug is a host action
and the bare-metal box has separate console input paths
unaffected by the unload.

The keyboard classifier code is identical regardless of venue.
Verification on bare metal alone is sufficient evidence that
`HUG_KEYBOARD` produces `roles=keyboard`; the VM cannot add
diagnostic value to that specific check.

**Steps:**

1. With the mouse still attached and inputfs still loaded from
   Signal 1.2, `sudo kldunload inputfs`.
2. `sudo dmesg | grep inputfs | tail -5`.
3. `kldstat | grep inputfs`.

**Expected output:**

```
inputfs0: inputfs: detached
inputfs: unloaded
```

**Acceptance:**

- [ ] `inputfs0: inputfs: detached` line is present.
- [ ] `inputfs: unloaded` line is present.
- [ ] `kldstat | grep inputfs` returns empty.
- [ ] No warnings, witness complaints, or use-after-free messages
      anywhere in the post-unload dmesg tail.

## Pass 2: bare-metal FreeBSD

Same four signals on a bare-metal FreeBSD machine. No
VirtualBox layer; USB devices plug directly into the host. All
steps and expected outputs are identical to Pass 1, with one
substitution: skip the "pass the device through" step in each
signal's procedure, and physically connect or disconnect the USB
device at the host instead.

The descriptor sizes and report sizes seen in Pass 2 may differ
from Pass 1, since real USB hardware presents different HID
descriptors than VirtualBox's pass-through layer. That is
expected and not a failure mode. The signal under test is always
the `roles=` line and its consistency with the table in ADR 0010
§ Decision 2.

### Signal 2.1: mouse classifies as pointer

[ ] checklist as in 1.1

### Signal 2.2: mouse motion still produces raw reports

[ ] checklist as in 1.2

### Signal 2.3: keyboard classifies as keyboard

[ ] checklist as in 1.3

### Signal 2.4: clean unload

[ ] checklist as in 1.4

## Failure handling

If any signal fails:

1. Do **not** flip the BACKLOG.md status.
2. Capture the full `sudo dmesg | grep inputfs` output from the
   load cycle that produced the failure, plus the boot-time tail
   from `dmesg.boot` if anything earlier looks suspicious.
3. Note the host (VM or bare metal), the device (vendor:product
   from the attach line), and which signal failed.
4. Hand the captured output back for analysis. Most B.5-specific
   failure modes (wrong role bit, wrong format string, line in
   the wrong order) are diagnosable from the dmesg alone.

## Recording

Capture the full dmesg from each pass into a local file:

```
sudo dmesg | grep inputfs > b5-pass1-vm.log
sudo dmesg | grep inputfs > b5-pass2-baremetal.log
```

The closeout bullet in `BACKLOG.md` cites both venues, in the
same form B.2 used: "verified on <mouse vendor:product> and
<keyboard vendor:product> on FreeBSD VirtualBox VM (FreeBSD
host) and on bare-metal FreeBSD." Attach the two log files to
the commit message or paste the relevant excerpts.

## Notes

The verification deliberately exercises one mouse and one keyboard.
ADR 0010 § Stage B.5 Scope limits the classifier to those two
producer roles via `HUG_KEYBOARD`, `HUG_MOUSE`, and `HUG_POINTER`.
Touch, pen, gamepad, and lighting devices are out of scope and
should not be tested against this verification. The empty-role
state (`roles=<none>`) those devices would produce is correct
behavior under ADR 0010 but does not exercise any code that B.5
added that this test doesn't already cover.

The "verified on" venue note in the BACKLOG closeout matters
beyond paperwork. Stage C will need both a VM datapoint (for
reproducibility in development) and a bare-metal datapoint (for
real-hardware behavior), and the B.5 closeout is the natural
place to record the bare-metal re-verification of B.1 through
B.4 as well, since neither B.3 nor B.4 currently has a bare-metal
datapoint in the backlog.
