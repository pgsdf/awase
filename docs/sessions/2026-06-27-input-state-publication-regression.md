
## Update 2026-06-27 (waypoint; investigation continues)

Further isolation, with care to separate established facts from inference.

Established (facts):
  - inputfs.ko is byte-identical between known-good-pre-ad56 and default
    (cmp of /boot/modules/inputfs.ko, correct path this time). The kernel
    module is NOT the changed component.
  - semadrawd and pgsd-sessiond differ between the BEs (cmp).
  - The only awase commits touching semadraw/pgsd-sessiond since the
    known-good snapshot (Jun 21 16:25) are the D-7 set (Jun 25 to Jun 26,
    increments 1 to 4 plus tests and client library). D-7 is therefore the
    only candidate userspace change between working and broken, and is the
    leading hypothesis, NOT a confirmed cause.
  - Region states in the broken BE: events 65600 bytes (correct), focus
    5184 bytes (correct, updating), state 0 bytes (the symptom). The focus
    region size matches between the D-7 writer (FOCUS_SIZE) and the inputfs
    reader (INPUTFS_FOCUS_SIZE), both 5184; D-7 did not break focus layout.
  - Input reaches evdev (cat /dev/input/event3 emits records on keypress).

Inference, explicitly NOT established (candidate models, all fit the
0-byte state file equally):
  - dirty tracking never triggers,
  - publication never runs,
  - publication runs but truncates,
  - publication writes to a different vnode,
  - another component recreates/truncates the file afterward.
  The earlier framing "the state region never goes dirty" is ONE such
  model (the kthread gates inputfs_state_sync_to_file on
  inputfs_state_dirty), not a finding. The empty file is the only fact.

Caveat on the latest observations: they were partly gathered while booted
via nextboot into the Delta 1 kernel (kernel.old), a transitional
configuration that differs from the original normally-booted known-bad
state (HID drivers loaded from /boot/kernel.old, inputfs.ko from
/boot/modules). This is an additional variable, NOT established as an ABI
mismatch (/boot/modules after the kernel dir is normal search behavior).
Conclusions should not be drawn from the transitional boot.

Next steps (reduce variables first):
  1. Reboot into the clean default configuration; treat it as the
     canonical known-bad system.
  2. Capture the canonical inventory as part of the record: uname -a,
     sysctl kern.module_path, kldstat -v.
  3. Re-run exactly one experiment there: hw.inputfs.debug_reports=1,
     generate keyboard input, capture dmesg immediately.
  4. Continue tracing whether HID reports reach inputfs at all (the
     report-receipt boundary) before assuming a publication-side cause.
