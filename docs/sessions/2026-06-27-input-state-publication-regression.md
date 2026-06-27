# Investigation: input state publication regression in default BE (open)

Opened 2026-06-27 from the Delta 3 baseline check, which exonerated AD-56
(see 2026-06-27-delta3-baseline-regression.md). This is an input-stack
investigation, NOT AD-56 work.

## Problem statement

Physical keyboard and mouse do not work at the pgsd-sessiond login screen
in the default BE, while they work in known-good-pre-ad56.

Known-good:
  - BE known-good-pre-ad56 (Jun 21). Physical keyboard and mouse functional.

Known-bad:
  - BE default. Physical input non-functional.
  - Reproduces on both the Delta 1 and Delta 3 kernels (kernel-independent
    within the default BE; not caused by AD-56).
  - Input reaches the kernel: evdev event nodes exist and emit events on
    keypress.
  - inputfs kthread alive; semadrawd holds /dev/inputfs_notify.
  - Published state file /var/run/sema/input/state is 0 bytes despite
    inputfs reporting a ready 11328-byte buffer.

## Candidate components

  - inputfs (kernel module or in-kernel; note the delivery method)
  - semadraw (semadrawd)
  - pgsd-sessiond
  - build/integration changes

## Constraints

  - known-good-pre-ad56 BE is the working reference and the recovery path.
  - The AD-56 Delta 3 suppression experiment stays paused until this is
    resolved.

## Update 2026-06-27 (waypoint; investigation continues)

Further isolation, with care to separate established facts from inference.

Established (facts):
  - inputfs.ko is byte-identical between known-good-pre-ad56 and default
    (cmp of /boot/modules/inputfs.ko, correct path this time). The kernel
    module is NOT the changed component.
  - semadrawd and pgsd-sessiond differ between the BEs (cmp).
  - The D-7 series (Jun 25 to Jun 26, increments 1 to 4 plus tests and
    client library) is the only identified Awase SOURCE change affecting
    semadraw/pgsd-sessiond between the working and broken snapshots (git
    log over those paths). It is therefore the leading source-level
    hypothesis, NOT an established cause. Other classes of difference are
    not ruled out: build flags, install/layout changes, dependency or
    library changes, generated code, or packaging differences could also
    distinguish the two BEs without appearing as a source commit.
  - Region states in the broken BE: events 65600 bytes (correct), focus
    5184 bytes (correct, updating), state 0 bytes (the symptom). The focus
    region size matches between the D-7 writer (FOCUS_SIZE) and the inputfs
    reader (INPUTFS_FOCUS_SIZE), both 5184; D-7 did not break focus layout.
  - Under the tested configuration (the nextboot Delta 1 / kernel.old boot
    noted in the caveat below), cat /dev/input/event3 emitted records on
    keypress, so input reached evdev there. This should be reconfirmed on
    the canonical reference configuration before being treated as general.

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
  1. Reboot into the clean default configuration and use it as the
     reference point for subsequent measurements (experimental
     consistency, not a claim about the configuration itself).
  2. Capture the canonical inventory as part of the record: uname -a,
     sysctl kern.module_path, kldstat -v.
  3. Re-run exactly one experiment there: hw.inputfs.debug_reports=1,
     generate keyboard input, capture dmesg immediately.
  4. Continue tracing whether HID reports reach inputfs at all (the
     report-receipt boundary) before assuming a publication-side cause.

## Update 2026-06-27 (code inspection: eliminate focus gating)

Read the inputfs intake path (inputfs_intr) and the state-dirty machinery.

Eliminated by inspection: focus validity is NOT the gating condition for
state updates. inputfs_intr resolves focus only to tag events with a
routing session_id; the comment is explicit that with no focus "events go
out unrouted", i.e. processing continues. The state-update sites
(inputfs_state_update_pointer, then inputfs_state_mark_dirty at lines 3421
and 3677) are reached unconditionally relative to focus. So the earlier
"no valid focus blocks state publication" idea is falsified for this path
(contingent on the reading being correct).

Leading remaining hypothesis (to confirm experimentally, NOT established):
runtime HID reports are not reaching inputfs_intr in the broken
configuration. If they were, state would be marked dirty and synced, and
the file would be non-zero. But this is one inference removed from the
observations; alternatives that fit equally: inputfs_intr is never called;
is called only at device enumeration, not on runtime reports; is called
but exits before the state update; updates a different state object than
the publisher reads; or mark_dirty runs but the publication thread never
observes it. The debug_reports test distinguishes "never called" from the
rest; an unconditional counter at inputfs_intr entry makes it unequivocal.

Corrected non-evidence: the events region being 65600 bytes is NOT
evidence that inputfs_intr fires. If the event ring is preallocated, the
size only confirms the backing object exists, not that any event was ever
written. The earlier "events full so the mechanism works" reasoning is
withdrawn.

Next experiment (on the reference configuration), collecting one bit:
  1. hw.inputfs.debug_reports=1, press keys, inspect the log immediately.
  2. If no report messages appear, add a single unconditional counter or
     tracepoint at inputfs_intr entry and re-test. Counter increments ->
     reports arrive, investigate downstream; never increments -> reports
     never reach inputfs, investigate registration/attachment.
The tight question: does runtime HID traffic ever enter inputfs_intr in
the reference (clean default) configuration?

## Questions remaining

  - Do HID reports reach inputfs under the reference (clean default)
    configuration?
  - If so, where between report receipt and state publication does
    behavior diverge?
  - If not, where does delivery diverge from the working boot environment?
  - Is the regression attributable to a source change, a build
    configuration, or an installation difference?
