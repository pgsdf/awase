# AD-13 inputfs logging discipline verification

Status: Stated, 2026-05-05.

This document is the verification sign-off for AD-13 (inputfs
interrupt-path logging discipline). AD-13.1 added a runtime
sysctl gate for the verbose per-report hex dump; AD-13.2 audited
the rest of `inputfs.c` for hot-path printfs that could fire
under persistent error conditions and applied a once-per-error-state
suppression pattern to five sites.

The verification gaps named in this document are operator-runnable
recipes; this doc records the verification state honestly rather
than under a blanket sign-off.

The AD-13 sub-stages whose work this doc verifies:

- **AD-13.1** runtime sysctl gate for the per-report hex dump
  in `inputfs_intr`. Default off; the formatting and the
  `device_printf` call are both inside the gate, so the
  interrupt-path cost when the sysctl is 0 is a single int
  read.
- **AD-13.2** once-per-error-state log suppression for five
  hot-path `printf` / `device_printf` sites. Pattern mirrors
  the existing `inputfs_focus_logged_absent` from Stage D.1:
  log on entry to error state; clear flag on first success
  after the error.

## 1. AD-13.1 sysctl gate

**Goal:** with the sysctl off (default), no per-report hex-dump
log appears in dmesg under any input activity. With the sysctl
on, every HID report produces one log line. Toggling does not
require a module reload.

### Verified (2026-05-04, bare-metal)

Operator-confirmed across the working semadraw-term run on
2026-05-04: dmesg under default settings contains no
`inputfs: report id=` lines despite continuous keyboard and
mouse activity at the framebuffer. The console-spam symptom
that motivated AD-13 (every keystroke producing a console
write) is closed.

### Recipe (re-verifiable)

```sh
# Confirm default-off
sysctl hw.inputfs.debug_reports
# expect: hw.inputfs.debug_reports: 0

sudo dmesg -c >/dev/null
# move the mouse, type some keys at the framebuffer keyboard
sudo dmesg | grep -c "inputfs: report id="
# expect: 0

# Enable
sudo sysctl hw.inputfs.debug_reports=1
sudo dmesg -c >/dev/null
# move the mouse a bit
sudo dmesg | grep -c "inputfs: report id="
# expect: > 0 (one per HID report received)

# Disable
sudo sysctl hw.inputfs.debug_reports=0
sudo dmesg -c >/dev/null
# move the mouse
sudo dmesg | grep -c "inputfs: report id="
# expect: 0
```

### Not yet verified

- **Interrupt-path cost when gated off.** The claim is that
  the cost is "a single int read" per report, but no
  benchmark has confirmed this. Falsifying would require
  comparing per-report latency under load with the gate
  vs an instrumented build that always logs. Not on the
  critical path; the operational outcome (no console spam)
  is the primary requirement and has been verified.

## 2. AD-13.2 hot-path log suppression

**Goal:** under persistent error conditions, each of the five
hot-path printfs fires exactly once on entry to the error
state, stays silent for the duration of the failure, and fires
again only after a successful operation followed by a new
failure.

The five sites:

1. `inputfs_intr` report truncation (per-softc flag).
2. `inputfs_state_sync_to_file` write failure (file-static).
3. `inputfs_events_sync_to_file` slot write failure (file-static).
4. `inputfs_events_sync_to_file` header write failure (file-static).
5. `inputfs_focus_refresh` read failure (file-static).

### Verified (2026-05-05, code review only)

Pattern correctness was verified by code review: each site
checks the flag, logs and sets only when 0; corresponding
success path resets to 0. The flags are simple int reads/writes
accessed only from a single context (kthread for the file-static
ones; interrupt for the per-softc one), so no locking concerns.
On a healthy system, the flags are 0 and the code paths
execute identically to pre-fix.

### Not yet verified — synthetic error injection

Each site requires a synthetic error condition to confirm the
suppression actually fires once-not-N-times. Recommended
recipes follow; none has been run.

#### 2a. State sync write failure suppression

```sh
# Fill /var/run to ENOSPC
sudo mount -t tmpfs tmpfs /var/run-test
sudo dd if=/dev/zero of=/var/run-test/fillit bs=1m 2>/dev/null
# (alternative: chmod -w /var/run/sema/state to provoke EACCES)

# Capture log baseline
sudo dmesg -c >/dev/null
sleep 5
# Should see exactly one "state vn_rdwr write failed" line,
# not 500 (100 Hz × 5s)
sudo dmesg | grep -c "state vn_rdwr write failed"
# expect: 1

# Restore writability
sudo rm /var/run-test/fillit

# Next successful write clears the flag; the flag's effect on
# a subsequent failure can be confirmed by repeating the cycle.
```

#### 2b. Events slot/header write failure suppression

Same as 2a but observes the `events slot vn_rdwr failed` and
`events header vn_rdwr failed` lines. Both should fire exactly
once per failure-and-recovery cycle.

#### 2c. Focus refresh read failure suppression

The focus file is compositor-written. To provoke a read failure
without affecting other paths: stop semadrawd to remove the
focus file, then re-create it as a zero-byte (or
broken-magic) file:

```sh
sudo service semadraw stop
sudo touch /var/run/sema/focus  # no magic, no header
sudo dmesg -c >/dev/null
sleep 1
sudo dmesg | grep -c "focus vn_rdwr"
# expect: at most 1 (depending on whether the read fails or
#         the magic-validation path fires; the magic path is
#         a separate non-logging branch, so 0 is also acceptable)

# Restore by restarting the daemon stack:
sudo service semadraw start
```

#### 2d. Report truncation suppression

Hardest to provoke synthetically. Requires either a misconfigured
device that emits oversized HID reports, or a kernel-side patch
that synthesises one. Not recommended for routine verification;
the code-review confirmation is the practical level here.

### Outcome interpretation

If any of 2a-2c shows a count higher than 1 (or higher than the
expected value given the test conditions), the suppression
isn't working at that site and AD-13.2 needs a revisit.

If all run as expected, AD-13.2 is operationally verified for
those four sites; site 5 (truncation) is verified by code
review only, which is honest given the difficulty of
synthetic provocation.

## 3. AD-13.3 audit of drawfs, chronofs, and userspace daemons

The AD-13 series scope explicitly extends to "drawfs.c,
chronofs/, and the userspace daemons" via AD-13.3. This is a
discipline sweep, not a regression hunt: the bar is lower
because userland writes go to syslog rather than the kernel
console under proper rc.d redirection, and because chronofs
is a small read-mostly substrate with no per-event surface.

**Audit findings (2026-05-05).**

drawfs kernel module (`drawfs/sys/dev/drawfs/`):

- `drawfs.c` (1351 lines) — five `printf`/`uprintf` calls,
  all in `MOD_LOAD` / `MOD_UNLOAD` / EFI fb attach. One-shot.
  Clean.
- `drawfs_efifb.c` (221 lines) — four `printf` calls in EFI
  framebuffer probe. One-shot. Clean.
- `drawfs_drm.c` (658 lines) — eighteen `printf` calls.
  Seventeen are init-time (display open: GETRESOURCES,
  SETCRTC, ADDFB, dumb-buffer setup). One was hot-path:
  `drawfs_drm_surface_present()` PAGE_FLIP failure
  printf at line 636. **Found and fixed under AD-13.3.**
  See "Fix" below.
- `drawfs_frame.c`, `drawfs_surface.c` — zero `printf` calls.
  Hot-path code disciplined from the start.

chronofs (`chronofs/`):

- All `.zig` files — zero `std.debug.print` calls; no
  hot-path logging surface. Clean.

Userspace daemons:

- `semadraw/src/daemon/semadrawd.zig` — uses `std.log.scoped`
  throughout. Twenty log calls, all on control paths
  (connect/disconnect, surface lifecycle, shutdown). Clean.
- `semadraw/src/backend/inputfs_input.zig` — four log calls,
  all one-shot at startup or on the ring-overrun edge.
  Clean.
- `semadraw/src/backend/drawfs.zig` — `readFrame()` has six
  log calls in error paths. The function is called per
  protocol reply; persistent error states would log per
  reply. **Considered, deferred.** Userland output is
  syslog-routed under rc.d, not kernel-console; the AD-13
  bar (kernel console writes that compete with framebuffer)
  does not apply. Recorded here for completeness, not
  scheduled.
- `semainput/src/device_aggregate.zig` — nine
  `std.debug.print` calls in `writeMappedEvent()`, one per
  semantic event. **Considered, deferred.** This is the
  same hot-path pattern AD-13.2 fixed in inputfs.c, but
  semainputd is being retired by AD-2 Stage E (libsemainput
  reshape, gesture relocation). Fixing the printfs in code
  scheduled for deletion is wasted work; AD-2 supersedes.
- `semaaud/src/main.zig` — four `std.debug.print` calls at
  daemon startup (clock-region published, three socket-listen
  announcements). One-shot. Stylistically should use
  `std.log.scoped` for consistency with semadrawd; tracked
  as cosmetic, not landed under AD-13.3.

**Fix landed (`drawfs/sys/dev/drawfs/drawfs_drm.c`):**

The PAGE_FLIP failure path now mirrors AD-13.2's pattern: a
new `flip_failure_logged` field on `struct drawfs_drm_display`
gates the printf to once per error state, and a successful
flip clears the flag so a subsequent failure logs once again.

Field declaration: `drawfs_drm.h` line 57 (after `flip_pending`).
Initialisation: `drawfs_drm_display_open()`, immediately after
`flip_pending = 0`.
Per-site logic: `drawfs_drm_surface_present()`, both branches
of the `error != 0` check.

The pattern is per-display rather than file-static because
multiple drawfs displays can exist (per the multi-display
direction in DF-3); one display's flip failures should not
suppress logging for another. Mirrors AD-13.2's per-softc
choice for `sc_logged_truncated`.

**Verification:** code review only. Synthetic error injection
for PAGE_FLIP failure requires either a deliberately-broken
DRM driver or programmatic flip-failure injection; neither
mechanism exists in the test harness. The pattern is the
same one AD-13.2 used and is small (twelve added lines plus
one struct field). The discipline gap is acceptable for now;
when DF-3 graduates from skeleton to a runnable DRM/KMS
backend the verification recipe will follow.

## What this verification does not cover

- **Long-running stability.** No 24-hour-or-longer run has
  been done with the gate on under heavy input activity.
  Could in principle exhibit a perf regression that single-shot
  verification would not catch. Out of scope for AD-13 which
  is operationally complete on the symptom-driven motivation.

- **The pattern's race conditions.** The flags are accessed
  from one context per flag, so there are no read-modify-write
  races today. A future change that introduces concurrent
  access (e.g., logging from interrupt context for a
  file-static flag, or kthread access to a per-softc flag)
  would need re-verification with the appropriate locking
  added.

- **Behaviour under module unload/reload during error state.**
  MOD_UNLOAD frees buffers and tears down the kthread; the
  flags are file-static so on next MOD_LOAD they reset to 0
  (BSS zero-init plus the explicit reset in MOD_LOAD).
  Operationally this means an error-suppression flag does
  not survive a module reload, which is the expected
  behaviour. Not formally tested but covered by code review.

## Sign-off

AD-13 is **substantially complete** as of 2026-05-05.

Three of three sub-stages (AD-13.1, AD-13.2, AD-13.3) have
landed. AD-13.1 is operationally verified on bare metal (no
console spam under the gate-off default). AD-13.2 and AD-13.3
are verified by code review only; synthetic error-injection
recipes for AD-13.2 are recorded above as operator-runnable
items. AD-13.3 has no synthetic recipe because the test
harness has no PAGE_FLIP injection mechanism; when DF-3
becomes runnable the recipe can follow.

The audit documented under AD-13.3 also recorded two
deferred findings (semadraw drawfs.zig readFrame error path,
semaaud startup printfs) and one finding superseded by other
work (semainput device_aggregate.zig hot-path printfs, to be
deleted by AD-2 Stage E). None of the deferred findings gate
further AD work; all are recorded so the next discipline
sweep does not re-discover them.

The verification gap named for AD-13.2 and AD-13.3 is a
discipline gap caught by writing this doc rather than a
correctness gap caught by failing tests. The pattern these
sub-stages implement is small and proven (mirrors the existing
`inputfs_focus_logged_absent` since Stage D.1), so the absence
of synthetic verification is acceptable for now; the recipes
above let any operator close the gap when convenient.

## References

- `BACKLOG.md` AD-13 — the logging-discipline work this doc
  verifies. Sub-stages AD-13.1, AD-13.2, AD-13.3 entries.
- `inputfs/sys/dev/inputfs/inputfs.c` — implementation file.
  AD-13.1 gate at line 2269 (`if (inputfs_debug_reports)`).
  AD-13.2 flags declared near line 596; per-site logic at the
  five sites enumerated above.
- `drawfs/sys/dev/drawfs/drawfs_drm.h` — `flip_failure_logged`
  field declared on `struct drawfs_drm_display` at line 57.
- `drawfs/sys/dev/drawfs/drawfs_drm.c` — AD-13.3 fix at
  `drawfs_drm_surface_present()` PAGE_FLIP error path.
- `docs/AD12_VERIFICATION.md` — verification doc whose pattern
  this one mirrors. The cross-component verification doc
  format established 2026-05-05.
- `docs/AWASE_DAEMON_DEPENDENCY_ABSENCE.md` — the AD-12.5 ADR
  that scopes related operational-discipline policy for
  daemon-side error states. AD-13 covers the kernel-side
  analogue for inputfs's logging surface.
