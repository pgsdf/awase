# Delta 3 baseline check: input regression isolation (closed)

Date: 2026-06-27. Context: verifying the AD-56 Phase 0.5 Delta 3 (EFI_FB
suppression) baseline before the suppression test, an input regression was
observed (no physical keyboard/mouse at the pgsd-sessiond login screen).
This record closes the question "did AD-56 / Delta 3 cause it?" and hands
off to a separate investigation.

## Objective (met)

Determine whether the AD-56 boot-program work (specifically Delta 3 EFI_FB
suppression) caused the input regression.

## Findings (supported by observation; not root-cause claims)

  - Delta 3 is experimentally exonerated. The regression reproduces on the
    Delta 1 kernel (awase/ad56-phase05-observation, 4f09e9082493) with the
    same default-BE userspace, where the Delta 3 suppression gate is absent
    entirely. A defect present without the suppression code cannot be
    caused by it. (Method: nextboot kernel.old = Delta 1, held userspace
    constant, input still broken.)
  - The regression exists between known-good-pre-ad56 (Jun 21, input works)
    and the current default BE (input broken). It is NOT EFI_FB-related:
    the Delta 3 control arm ran with suppression off, EFI_FB present
    (inventory found=1), drawfs mapping the framebuffer normally.
  - Input reaches the kernel. evdev nodes /dev/input/event0..12 exist and
    cat /dev/input/event3 produces live event records on keypress, so
    device, HID attachment, and the kernel input layer all work. The break
    is above the kernel input layer.
  - The published inputfs state file is unexpectedly empty.
    /var/run/sema/input/state is 0 bytes although inputfs init reports a
    ready 11328-byte state buffer and an opened 11328-byte state file. The
    inputfs kthread ([inputfs_state] pid 217) is alive and semadrawd holds
    /dev/inputfs_notify open, so the pipeline is partly connected. The
    zero-length result means the publication RESULT is wrong; it does not
    by itself identify the mechanism.
  - The input stack differs materially between the two BEs (cmp):
    semadrawd differs, pgsd-sessiond differs, and inputfs is delivered
    differently (no /boot/kernel/inputfs.ko; inputfs.ko lives in
    /boot/modules and is byte-identical between the BEs).

## Conclusion

AD-56 / Delta 3 did not cause the regression. The Delta 3 suppression
experiment is PAUSED and must not resume until physical input is restored,
since the suppression test cannot be cleanly evaluated on a system whose
input is already broken for unrelated reasons. The Delta 3 commit
(fork 78e4ae6f7bc4) and its design remain valid and untouched.

## Handoff

Continues as a separate investigation: see
docs/sessions/2026-06-27-input-state-publication-regression.md.
